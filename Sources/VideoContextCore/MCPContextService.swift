import Foundation

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

    public func brief(videoID: String, cursor: String? = nil, wordLimit: Int = 500) async throws -> MCPBriefPage {
        guard let snapshot = try await store.videoSnapshot(id: videoID) else {
            throw VideoContextStoreError.videoNotFound(videoID)
        }
        guard let brief = snapshot.brief else {
            throw VideoContextStoreError.briefUnavailable(videoID, snapshot.video.status)
        }
        let page = try TextPaginator.page(brief.markdown, cursor: cursor, wordLimit: wordLimit)
        return MCPBriefPage(
            video: VideoSummary(video: snapshot.video),
            markdown: page.text,
            revisions: snapshot.video.revisions,
            isStale: snapshot.video.revisions.isBriefStale,
            nextCursor: page.nextCursor
        )
    }

    public func search(videoID: String, query: String, cursor: String? = nil, limit: Int = 20) async throws -> Page<SearchHit> {
        try await store.search(videoID: videoID, query: query, cursor: cursor, limit: limit)
    }

    public func segment(
        videoID: String,
        start: TimeInterval,
        end: TimeInterval,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> MCPSegmentContext {
        guard start >= 0, end >= start else { throw VideoContextStoreError.invalidTimeRange }
        guard let snapshot = try await store.videoSnapshot(id: videoID) else {
            throw VideoContextStoreError.videoNotFound(videoID)
        }
        async let transcriptPage = store.segment(videoID: videoID, start: start, end: end, cursor: cursor, limit: limit)
        async let evidenceItems = store.evidence(videoID: videoID, from: start, through: end)
        return try await MCPSegmentContext(
            videoID: videoID,
            artifactRevision: snapshot.video.revisions,
            start: start,
            end: end,
            transcript: transcriptPage,
            evidence: evidenceItems
        )
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
