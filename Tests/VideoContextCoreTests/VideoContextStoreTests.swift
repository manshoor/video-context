import Foundation
import Testing
@testable import VideoContextCore

struct VideoContextStoreTests {
    @Test("API usage is recorded per recording")
    func apiUsageIsRecorded() async throws {
        let fixture = try StoreFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(id: "vid_usage", title: "Usage", source: .localFile, sourceValue: "source.mp4", mediaRelativePath: "video.mp4")
        try await store.createVideo(video)

        try await store.recordAPIUsage(APIUsageRecord(
            videoID: video.id,
            stage: .transcription,
            model: "whisper-1",
            audioSeconds: 91
        ))

        let snapshot = try #require(try await store.videoSnapshot(id: video.id))
        #expect(snapshot.apiUsage.count == 1)
        #expect(snapshot.apiUsage.first?.audioSeconds == 91)
        #expect(snapshot.apiUsage.first?.model == "whisper-1")
    }

    @Test("A retrieval-only store reads an existing library and rejects writes")
    func readOnlyStoreDoesNotOwnWrites() async throws {
        let fixture = try StoreFixture()
        let writer = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(
            id: "vid_readonly",
            title: "Read only",
            source: .localFile,
            sourceValue: "source.mp4",
            mediaRelativePath: "videos/vid_readonly/video.mp4"
        )
        try await writer.createVideo(video)
        let reader = try VideoContextStore(databaseURL: fixture.databaseURL, access: .readOnly)

        #expect(try await reader.videoSnapshot(id: video.id)?.video.title == "Read only")
        await #expect(throws: (any Error).self) {
            try await reader.createVideo(VideoRecord(
                id: "vid_forbidden",
                title: "Forbidden",
                source: .localFile,
                sourceValue: "source.mp4",
                mediaRelativePath: "videos/vid_forbidden/video.mp4"
            ))
        }
    }

    @Test("Publishing artifacts exposes one consistent ready snapshot")
    func publishingArtifactsIsAtomic() async throws {
        let fixture = try StoreFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(
            id: "vid_atomic",
            title: "Checkout walkthrough",
            source: .localFile,
            sourceValue: "/source/walkthrough.mp4",
            mediaRelativePath: "videos/vid_atomic/video.mp4",
            duration: 120,
            status: .analyzing
        )
        try await store.createVideo(video)

        try await store.publishArtifacts(
            videoID: video.id,
            transcript: [
                TranscriptSegment(videoID: video.id, start: 4, end: 9, originalText: "Open checkout settings")
            ],
            evidence: [
                EvidenceItem(videoID: video.id, timestamp: 7, imageRelativePath: "videos/vid_atomic/frames/7.jpg", ocrText: "Payment failed", origin: .automatic)
            ],
            brief: BriefDocument(videoID: video.id, markdown: "# Goal\nFix the checkout failure.")
        )

        let snapshot = try await store.videoSnapshot(id: video.id)
        #expect(snapshot?.video.status == .ready)
        #expect(snapshot?.transcript.map(\.text) == ["Open checkout settings"])
        #expect(snapshot?.evidence.map(\.ocrText) == ["Payment failed"])
        #expect(snapshot?.brief?.markdown.contains("checkout failure") == true)
        #expect(snapshot?.video.revisions.isBriefStale == false)
    }

    @Test("Full-text search returns transcript, OCR, and brief evidence")
    func fullTextSearchCoversAllArtifacts() async throws {
        let fixture = try StoreFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(id: "vid_search", title: "Billing", source: .localFile, sourceValue: "billing.mp4", mediaRelativePath: "videos/vid_search/video.mp4", duration: 80, status: .analyzing)
        try await store.createVideo(video)
        try await store.publishArtifacts(
            videoID: video.id,
            transcript: [TranscriptSegment(videoID: video.id, start: 10, end: 15, originalText: "Click the upgrade button")],
            evidence: [EvidenceItem(videoID: video.id, timestamp: 12, imageRelativePath: "frame.jpg", ocrText: "Upgrade unavailable", origin: .automatic)],
            brief: BriefDocument(videoID: video.id, markdown: "Expected result: the account upgrades immediately.")
        )

        let page = try await store.search(videoID: video.id, query: "upgrade", limit: 10)

        #expect(Set(page.items.map(\.kind)) == [.transcript, .evidence, .brief])
        #expect(page.nextCursor == nil)
    }

    @Test("Search pagination never silently discards later matches")
    func searchPaginationUsesStableCursor() async throws {
        let fixture = try StoreFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(id: "vid_pages", title: "Settings", source: .localFile, sourceValue: "settings.mp4", mediaRelativePath: "video.mp4", duration: 20, status: .analyzing)
        try await store.createVideo(video)
        try await store.publishArtifacts(
            videoID: video.id,
            transcript: (0..<5).map { TranscriptSegment(videoID: video.id, start: Double($0), end: Double($0 + 1), originalText: "settings item \($0)") },
            evidence: [],
            brief: BriefDocument(videoID: video.id, markdown: "No summary match")
        )

        let first = try await store.search(videoID: video.id, query: "settings", limit: 2)
        let second = try await store.search(videoID: video.id, query: "settings", cursor: first.nextCursor, limit: 2)

        #expect(first.items.count == 2)
        #expect(second.items.count == 2)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))))
        #expect(second.nextCursor != nil)
    }

    @Test("Correcting transcript retains original text and marks brief stale")
    func transcriptCorrectionPreservesProvenance() async throws {
        let fixture = try StoreFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(id: "vid_correction", title: "Settings", source: .localFile, sourceValue: "settings.mp4", mediaRelativePath: "video.mp4", duration: 20, status: .analyzing)
        let segment = TranscriptSegment(id: "seg_1", videoID: video.id, start: 1, end: 3, originalText: "Click billings")
        try await store.createVideo(video)
        try await store.publishArtifacts(videoID: video.id, transcript: [segment], evidence: [], brief: BriefDocument(videoID: video.id, markdown: "Click billings."))

        try await store.correctTranscript(segmentID: segment.id, correctedText: "Click Billing")

        let snapshot = try await store.videoSnapshot(id: video.id)
        #expect(snapshot?.transcript.first?.originalText == "Click billings")
        #expect(snapshot?.transcript.first?.text == "Click Billing")
        #expect(snapshot?.transcript.first?.isCorrected == true)
        #expect(snapshot?.video.revisions.isBriefStale == true)
    }

    @Test("Context ID survives corrections, edits, reprocessing, and reopening")
    func contextIDIsPermanent() async throws {
        let fixture = try StoreFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(id: "vid_permanent", title: "Permanent context", source: .localFile, sourceValue: "source.mp4", mediaRelativePath: "videos/vid_permanent/video.mp4", duration: 20, status: .analyzing)
        let segment = TranscriptSegment(id: "seg_permanent", videoID: video.id, start: 1, end: 3, originalText: "Original")
        try await store.createVideo(video)
        try await store.publishArtifacts(
            videoID: video.id,
            transcript: [segment],
            evidence: [EvidenceItem(id: "ev_permanent", videoID: video.id, timestamp: 2, imageRelativePath: "videos/vid_permanent/frames/2.jpg", ocrText: "Original OCR", origin: .automatic)],
            brief: BriefDocument(videoID: video.id, markdown: "Original brief")
        )

        try await store.correctTranscript(segmentID: segment.id, correctedText: "Corrected")
        try await store.updateBrief(videoID: video.id, markdown: "Edited brief")
        try await store.replaceEvidence(videoID: video.id, items: [])
        try await store.updateVideo(id: video.id, status: .inspecting)
        let reopened = try VideoContextStore(databaseURL: fixture.databaseURL)
        let snapshot = try #require(try await reopened.videoSnapshot(id: video.id))

        #expect(snapshot.video.id == "vid_permanent")
        #expect(snapshot.transcript.first?.videoID == "vid_permanent")
        #expect(snapshot.brief?.videoID == "vid_permanent")
        #expect(snapshot.video.status == .inspecting)
    }
}

private struct StoreFixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "library.sqlite")
    }
}
