import Foundation
import Testing
@testable import VideoContextCore

struct MCPContextServiceTests {
    @Test("Brief retrieval returns at most 500 words and a continuation cursor")
    func briefRetrievalIsBounded() async throws {
        let fixture = try await MCPFixture(videoID: "vid_brief")
        let words = (0..<520).map { "word\($0)" }.joined(separator: " ")
        try await fixture.store.publishArtifacts(
            videoID: fixture.videoID,
            transcript: [],
            evidence: [],
            brief: BriefDocument(videoID: fixture.videoID, markdown: words)
        )
        _ = try await fixture.store.saveAudioCoverage(videoID: fixture.videoID, hasAudio: false, duration: 30)
        let service = MCPContextService(store: fixture.store)

        let first = try await service.brief(videoID: fixture.videoID)
        let second = try await service.brief(videoID: fixture.videoID, cursor: first.nextCursor)

        #expect(first.markdown.split(whereSeparator: \Character.isWhitespace).count == 500)
        #expect(first.nextCursor != nil)
        #expect(second.markdown.split(whereSeparator: \Character.isWhitespace).count == 20)
        #expect(second.nextCursor == nil)
        #expect(first.revisions.isBriefStale == false)
        #expect(first.audioCoverage?.status == .silent)
        #expect(first.audioCoverage?.hasAudio == false)
        #expect(first.audioCoverage?.duration == 30)
    }

    @Test("Segment retrieval returns transcript and screenshot evidence in the same time range")
    func segmentRetrievalKeepsEvidenceTogether() async throws {
        let fixture = try await MCPFixture(videoID: "vid_segment")
        try await fixture.store.publishArtifacts(
            videoID: fixture.videoID,
            transcript: [
                TranscriptSegment(videoID: fixture.videoID, start: 2, end: 5, originalText: "Before"),
                TranscriptSegment(videoID: fixture.videoID, start: 10, end: 14, originalText: "Payment failed")
            ],
            evidence: [
                EvidenceItem(videoID: fixture.videoID, timestamp: 12, imageRelativePath: "frames/12.jpg", ocrText: "Card declined", origin: .automatic)
            ],
            brief: BriefDocument(videoID: fixture.videoID, markdown: "Failure")
        )
        let service = MCPContextService(store: fixture.store)

        let context = try await service.segment(videoID: fixture.videoID, start: 9, end: 15)

        #expect(context.transcript.items.map(\.text) == ["Payment failed"])
        #expect(context.evidence.map(\.ocrText) == ["Card declined"])
        #expect(context.start == 9)
        #expect(context.end == 15)
    }

    @Test("Unknown recordings return a specific retrieval error")
    func unknownVideoReturnsSpecificError() async throws {
        let fixture = try await MCPFixture(videoID: "vid_exists")
        let service = MCPContextService(store: fixture.store)

        await #expect(throws: VideoContextStoreError.videoNotFound("vid_missing")) {
            _ = try await service.brief(videoID: "vid_missing")
        }
    }

    @Test("Unavailable brief reports the exact recording status")
    func unavailableBriefReportsStatus() async throws {
        let fixture = try await MCPFixture(videoID: "vid_processing")
        let service = MCPContextService(store: fixture.store)

        do {
            _ = try await service.brief(videoID: fixture.videoID)
            Issue.record("Expected the unavailable brief to throw.")
        } catch {
            #expect(error.localizedDescription == "The coding brief is not available for recording vid_processing. Current status: Building brief.")
        }
    }

    @Test("Context ID scopes retrieval to one of two same-titled recordings")
    func contextIDScopesEveryRetrieval() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextScopeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "library.sqlite"))
        let alpha = VideoRecord(id: "vid_alpha", title: "Shared walkthrough", source: .localFile, sourceValue: "alpha.mp4", mediaRelativePath: "videos/vid_alpha/video.mp4", duration: 30, status: .analyzing)
        let beta = VideoRecord(id: "vid_beta", title: "Shared walkthrough", source: .localFile, sourceValue: "beta.mp4", mediaRelativePath: "videos/vid_beta/video.mp4", duration: 30, status: .analyzing)
        try await store.createVideo(alpha)
        try await store.createVideo(beta)
        try await store.publishArtifacts(
            videoID: alpha.id,
            transcript: [TranscriptSegment(id: "seg_alpha", videoID: alpha.id, start: 1, end: 4, originalText: "Shared alpha transcript")],
            evidence: [EvidenceItem(id: "ev_alpha", videoID: alpha.id, timestamp: 2, imageRelativePath: "videos/vid_alpha/frames/2.jpg", ocrText: "Shared alpha OCR", origin: .automatic)],
            brief: BriefDocument(videoID: alpha.id, markdown: "Shared alpha brief")
        )
        try await store.publishArtifacts(
            videoID: beta.id,
            transcript: [TranscriptSegment(id: "seg_beta", videoID: beta.id, start: 1, end: 4, originalText: "Shared beta transcript")],
            evidence: [EvidenceItem(id: "ev_beta", videoID: beta.id, timestamp: 2, imageRelativePath: "videos/vid_beta/frames/2.jpg", ocrText: "Shared beta OCR", origin: .automatic)],
            brief: BriefDocument(videoID: beta.id, markdown: "Shared beta brief")
        )
        let service = MCPContextService(store: store)

        let brief = try await service.brief(videoID: alpha.id)
        let search = try await service.search(videoID: alpha.id, query: "shared")
        let segment = try await service.segment(videoID: alpha.id, start: 0, end: 5)
        let unmatched = try await service.search(videoID: alpha.id, query: "beta")

        #expect(brief.video.id == alpha.id)
        #expect(brief.markdown == "Shared alpha brief")
        #expect(Set(search.items.map(\.id)) == ["seg_alpha", "ev_alpha", "vid_alpha"])
        #expect(segment.videoID == alpha.id)
        #expect(segment.transcript.items.map(\.id) == ["seg_alpha"])
        #expect(segment.evidence.map(\.id) == ["ev_alpha"])
        #expect(unmatched.items.isEmpty)
    }

    @Test("Every scoped retrieval rejects an unknown Context ID")
    func scopedRetrievalRejectsUnknownContextID() async throws {
        let fixture = try await MCPFixture(videoID: "vid_exists")
        let service = MCPContextService(store: fixture.store)

        await #expect(throws: VideoContextStoreError.videoNotFound("vid_missing")) {
            _ = try await service.search(videoID: "vid_missing", query: "anything")
        }
        await #expect(throws: VideoContextStoreError.videoNotFound("vid_missing")) {
            _ = try await service.segment(videoID: "vid_missing", start: 0, end: 1)
        }
    }
}

private struct MCPFixture {
    let videoID: String
    let store: VideoContextStore

    init(videoID: String) async throws {
        self.videoID = videoID
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextMCPTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try VideoContextStore(databaseURL: root.appending(path: "library.sqlite"))
        let video = VideoRecord(id: videoID, title: "Fixture", source: .localFile, sourceValue: "fixture.mp4", mediaRelativePath: "video.mp4", duration: 30, status: .analyzing)
        try await store.createVideo(video)
    }
}
