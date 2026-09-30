import Foundation
import GRDB

public struct VideoSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let duration: TimeInterval
    public let status: ProcessingStatus
    public let errorMessage: String?
    public let revisions: ArtifactRevision
    public let briefIsStale: Bool

    public init(video: VideoRecord) {
        id = video.id
        title = video.title
        duration = video.duration
        status = video.status
        errorMessage = video.errorMessage
        revisions = video.revisions
        briefIsStale = video.revisions.isBriefStale
    }
}

public struct MCPBriefPage: Codable, Equatable, Sendable {
    public let video: VideoSummary
    public let markdown: String
    public let revisions: ArtifactRevision
    public let isStale: Bool
    /// Media inspection is independent from transcript availability. This
    /// lets an editor distinguish a silent recording from missing processing.
    public let audioCoverage: AudioCoverage?
    public let nextCursor: String?
}

public struct MCPSegmentContext: Codable, Equatable, Sendable {
    public let videoID: String
    public let artifactRevision: ArtifactRevision
    public let start: TimeInterval
    public let end: TimeInterval
    public let transcript: Page<TranscriptSegment>
    public let evidence: [EvidenceItem]
}

public struct MCPContextService: Sendable {
    private let store: VideoContextStore

    public init(store: VideoContextStore) {
        self.store = store
    }

    public func videos(query: String? = nil, cursor: String? = nil, limit: Int = 20) async throws -> Page<VideoSummary> {
        let page = try await store.listVideos(query: query, cursor: cursor, limit: limit)
        return Page(items: page.items.map(VideoSummary.init(video:)), nextCursor: page.nextCursor)
    }

    /// Returns the persisted media inspection result for a recording. This is
    /// intentionally a separate read so clients can distinguish a silent
    /// recording from a transcript that has not been processed yet.
    public func audioCoverage(videoID: String) async throws -> AudioCoverage? {
        try await store.audioCoverage(videoID: videoID)
    }

    public func brief(videoID: String, cursor: String? = nil, wordLimit: Int = 500) async throws -> MCPBriefPage {
        let read = try await store.revisionBoundBrief(videoID: videoID, cursor: cursor, wordLimit: wordLimit)
        return MCPBriefPage(video: VideoSummary(video: read.video), markdown: read.markdown,
                            revisions: read.video.revisions, isStale: read.video.revisions.isBriefStale,
                            audioCoverage: read.audioCoverage, nextCursor: read.nextCursor)
    }

    public func search(videoID: String, query: String, cursor: String? = nil, limit: Int = 20) async throws -> Page<SearchHit> {
        try await store.revisionBoundSearch(videoID: videoID, query: query, cursor: cursor, limit: limit)
    }

    public func segment(
        videoID: String,
        start: TimeInterval,
        end: TimeInterval,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> MCPSegmentContext {
        let read = try await store.revisionBoundSegment(videoID: videoID, start: start, end: end, cursor: cursor, limit: limit)
        return MCPSegmentContext(videoID: videoID, artifactRevision: read.revisions, start: start, end: end,
                                 transcript: read.transcript, evidence: read.evidence)
    }
}

private struct MCPBriefRead: Sendable {
    let video: VideoRecord
    let markdown: String
    let audioCoverage: AudioCoverage?
    let nextCursor: String?
}

private struct MCPSegmentRead: Sendable {
    let revisions: ArtifactRevision
    let transcript: Page<TranscriptSegment>
    let evidence: [EvidenceItem]
}

/// These reads deliberately keep the video revision and the returned rows in
/// one SQLite read transaction. A client cannot receive a cursor or segment
/// page that was assembled across two different recording revisions.
extension VideoContextStore {
    fileprivate func revisionBoundBrief(videoID: String, cursor: String?, wordLimit: Int) throws -> MCPBriefRead {
        try pool.read { database in
            guard let video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM briefs WHERE video_id = ?", arguments: [videoID]) else {
                throw VideoContextStoreError.briefUnavailable(videoID, video.status)
            }
            let brief = Self.brief(from: row)
            let audioCoverage: AudioCoverage?
            if try database.tableExists("video_audio_coverage"),
               let row = try Row.fetchOne(database, sql: "SELECT * FROM video_audio_coverage WHERE video_id = ?", arguments: [videoID]) {
                let storedHasAudio: Int? = row["has_audio"]
                let storedDuration: TimeInterval = row["duration"]
                audioCoverage = AudioCoverage(
                    videoID: row["video_id"],
                    status: AudioCoverageStatus(rawValue: row["status"] ?? "unknown") ?? .unknown,
                    hasAudio: storedHasAudio.map { $0 != 0 },
                    duration: max(0, storedDuration),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            } else {
                audioCoverage = nil
            }
            let scope = "brief:\(videoID)"
            let bound = try RevisionBoundCursor.decode(cursor, scope: scope, revisions: video.revisions)
            let oldCursor = bound.offset == 0 ? nil : PaginationCursor(offset: bound.offset).encoded
            let page = try TextPaginator.page(brief.markdown, cursor: oldCursor, wordLimit: wordLimit)
            let next: String?
            if let pageCursor = page.nextCursor, let offset = PaginationCursor(encoded: pageCursor)?.offset {
                next = RevisionBoundCursor(scope: scope, revisions: video.revisions, offset: offset).encoded
            } else {
                next = nil
            }
            return MCPBriefRead(video: video, markdown: page.text, audioCoverage: audioCoverage, nextCursor: next)
        }
    }

    fileprivate func revisionBoundSearch(videoID: String, query: String, cursor: String?, limit: Int) throws -> Page<SearchHit> {
        guard (1...100).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VideoContextStoreError.emptyQuery }
        return try pool.read { database in
            guard let video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            let scope = "search:\(videoID):\(trimmed)"
            let bound = try RevisionBoundCursor.decode(cursor, scope: scope, revisions: video.revisions)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT ref_id, kind, text, start_time, end_time
                    FROM search_index
                    WHERE search_index MATCH ? AND video_id = ?
                    ORDER BY bm25(search_index), rowid
                    LIMIT ? OFFSET ?
                    """,
                arguments: [Self.ftsQuery(trimmed), videoID, limit + 1, bound.offset]
            )
            let hasMore = rows.count > limit
            let hits = rows.prefix(limit).compactMap(Self.searchHit(from:))
            let next = hasMore ? RevisionBoundCursor(scope: scope, revisions: video.revisions, offset: bound.offset + limit).encoded : nil
            return Page(items: Array(hits), nextCursor: next)
        }
    }

    fileprivate func revisionBoundSegment(videoID: String, start: TimeInterval, end: TimeInterval, cursor: String?, limit: Int) throws -> MCPSegmentRead {
        guard start >= 0, end >= start else { throw VideoContextStoreError.invalidTimeRange }
        guard (1...100).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        return try pool.read { database in
            guard let video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            let scope = "segment:\(videoID):\(String(format: "%.6f", start)):\(String(format: "%.6f", end))"
            let bound = try RevisionBoundCursor.decode(cursor, scope: scope, revisions: video.revisions)
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM transcript_segments WHERE video_id = ? AND end_time >= ? AND start_time <= ? ORDER BY start_time, id LIMIT ? OFFSET ?",
                arguments: [videoID, start, end, limit + 1, bound.offset]
            )
            let hasMore = rows.count > limit
            let transcript = Page(
                items: Array(rows.prefix(limit).map(Self.transcript(from:))),
                nextCursor: hasMore ? RevisionBoundCursor(scope: scope, revisions: video.revisions, offset: bound.offset + limit).encoded : nil
            )
            let evidence = try Row.fetchAll(
                database,
                sql: "SELECT * FROM evidence_items WHERE video_id = ? AND timestamp BETWEEN ? AND ? ORDER BY timestamp, id",
                arguments: [videoID, start, end]
            ).map(Self.evidence(from:))
            return MCPSegmentRead(revisions: video.revisions, transcript: transcript, evidence: evidence)
        }
    }
}

public enum TextPaginator {
    public static func page(_ text: String, cursor: String?, wordLimit: Int) throws -> (text: String, nextCursor: String?) {
        guard wordLimit > 0, wordLimit <= 5_000 else { throw VideoContextStoreError.invalidLimit }
        let offset: Int
        if let cursor {
            guard let decoded = PaginationCursor(encoded: cursor) else { throw VideoContextStoreError.invalidCursor }
            offset = decoded.offset
        } else {
            offset = 0
        }
        let words = text.rangesOfWords()
        guard offset < words.count else { return ("", nil) }
        let end = min(offset + wordLimit, words.count)
        let slice = text[words[offset].lowerBound..<words[end - 1].upperBound]
        return (String(slice), end < words.count ? PaginationCursor(offset: end).encoded : nil)
    }
}

private extension String {
    func rangesOfWords() -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        enumerateSubstrings(in: startIndex..<endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}
