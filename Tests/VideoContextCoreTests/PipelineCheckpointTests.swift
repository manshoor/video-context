import Foundation
import Testing
@testable import VideoContextCore

struct PipelineCheckpointTests {
    @Test("Transcript and evidence checkpoints survive a later failed stage")
    func completedCheckpointsSurviveFailure() async throws {
        let fixture = try CheckpointFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL)
        let video = VideoRecord(id: "vid_checkpoint", title: "Flow", source: .localFile, sourceValue: "flow.mp4", mediaRelativePath: "video.mp4", duration: 10)
        try await store.createVideo(video)

        try await store.replaceTranscript(
            videoID: video.id,
            segments: [TranscriptSegment(videoID: video.id, start: 0, end: 2, originalText: "Open the form")]
        )
        try await store.replaceEvidence(
            videoID: video.id,
            items: [EvidenceItem(videoID: video.id, timestamp: 1, imageRelativePath: "1.jpg", ocrText: "Submit", origin: .automatic)]
        )
        try await store.markIncomplete(videoID: video.id, error: "Brief generation failed")

        let snapshot = try await store.videoSnapshot(id: video.id)
        #expect(snapshot?.video.status == .incomplete)
        #expect(snapshot?.transcript.count == 1)
        #expect(snapshot?.evidence.count == 1)
        #expect(snapshot?.brief == nil)
        #expect(snapshot?.video.errorMessage == "Brief generation failed")
    }
}

private struct CheckpointFixture {
    let databaseURL: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextCheckpointTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "library.sqlite")
    }
}
