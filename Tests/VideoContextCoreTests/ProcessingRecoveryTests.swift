import Foundation
import Testing
@testable import VideoContextCore

struct ProcessingRecoveryTests {
    @Test("A completed checkpoint is reused and a lost provider result is blocked")
    func checkpointLifecycleProtectsUnknownResults() async throws {
        let fixture = try RecoveryFixture()
        let store = try VideoContextStore(databaseURL: fixture.database)
        let video = VideoRecord(id: "vid_recovery", title: "Recovery", source: .localFile,
                                sourceValue: "fixture.mp4", mediaRelativePath: "videos/vid_recovery/video.mp4")
        try await store.createVideo(video)

        let first = try await store.beginProcessingCheckpoint(
            videoID: video.id, stage: .transcriptChunk, itemKey: "chunk-0", inputFingerprint: "input",
            provider: "openAI", model: "whisper-1", requestID: "request-1"
        )
        #expect(first?.state == .running)
        try await store.completeProcessingCheckpoint(
            videoID: video.id, stage: .transcriptChunk, itemKey: "chunk-0", inputFingerprint: "input",
            outputData: try ProcessingCheckpoint.encodeOutput(TranscriptCheckpointOutput(segments: []))
        )
        let completed = try await store.processingCheckpoint(
            videoID: video.id, stage: .transcriptChunk, itemKey: "chunk-0", inputFingerprint: "input"
        )
        #expect(completed?.state == .completed)
        #expect(try completed?.decodeOutput(TranscriptCheckpointOutput.self).segments.isEmpty == true)

        let second = try await store.beginProcessingCheckpoint(
            videoID: video.id, stage: .analysisBatch, itemKey: "batch-0", inputFingerprint: "analysis",
            provider: "openAI", model: "gpt", requestID: "request-2"
        )
        #expect(second?.requestID == "request-2")
        try await store.failProcessingCheckpoint(
            videoID: video.id, stage: .analysisBatch, itemKey: "batch-0",
            errorMessage: "The response was lost.", unknownOutcome: true
        )
        await #expect(throws: ProcessingRecoveryError.unknownOutcome(
            videoID: video.id, stage: .analysisBatch, itemKey: "batch-0"
        )) {
            _ = try await store.beginProcessingCheckpoint(
                videoID: video.id, stage: .analysisBatch, itemKey: "batch-0", inputFingerprint: "analysis",
                provider: "openAI", model: "gpt", requestID: "request-3"
            )
        }
        try await store.resetProcessingCheckpoint(
            videoID: video.id, stage: .analysisBatch, itemKey: "batch-0", expectedRequestID: "request-2"
        )
        let retry = try await store.beginProcessingCheckpoint(
            videoID: video.id, stage: .analysisBatch, itemKey: "batch-0", inputFingerprint: "analysis",
            provider: "openAI", model: "gpt", requestID: "request-3"
        )
        #expect(retry?.requestID == "request-3")
        await #expect(throws: ProcessingRecoveryError.unknownOutcome(
            videoID: video.id, stage: .analysisBatch, itemKey: "batch-0"
        )) {
            try await store.completeProcessingCheckpoint(
                videoID: video.id, stage: .analysisBatch, itemKey: "batch-0", inputFingerprint: "analysis",
                outputData: try ProcessingCheckpoint.encodeOutput(AnalysisCheckpointOutput(markdown: "late")),
                expectedRequestID: "request-2"
            )
        }
    }

    @Test("Media inspection persists silent and audible coverage")
    func audioCoveragePersistsInspectionResult() async throws {
        let fixture = try RecoveryFixture()
        let store = try VideoContextStore(databaseURL: fixture.database)
        let video = VideoRecord(id: "vid_audio_coverage", title: "Silent capture", source: .localFile,
                                sourceValue: "fixture.mp4", mediaRelativePath: "videos/vid_audio_coverage/video.mp4")
        try await store.createVideo(video)

        let silent = try await store.saveAudioCoverage(videoID: video.id, hasAudio: false, duration: 42)
        #expect(silent?.status == .silent)
        #expect(silent?.hasAudio == false)
        #expect(silent?.duration == 42)
        #expect(try await store.audioCoverage(videoID: video.id) == silent)

        let audible = try await store.saveAudioCoverage(videoID: video.id, hasAudio: true, duration: 48)
        #expect(audible?.status == .present)
        #expect(audible?.hasAudio == true)
        let persistedAudible = try #require(try await store.audioCoverage(videoID: video.id))
        #expect(persistedAudible.videoID == video.id)
        #expect(persistedAudible.status == .present)
        #expect(persistedAudible.hasAudio == true)
        #expect(persistedAudible.duration == 48)
    }

    @Test("Evidence preserves requested and measured frame timestamps")
    func evidencePersistsRequestedAndMeasuredTimestamps() async throws {
        let fixture = try RecoveryFixture()
        let store = try VideoContextStore(databaseURL: fixture.database)
        let video = VideoRecord(id: "vid_timestamp", title: "Measured frame", source: .localFile,
                                sourceValue: "fixture.mp4", mediaRelativePath: "videos/vid_timestamp/video.mp4")
        try await store.createVideo(video)
        let evidence = EvidenceItem(
            id: "evidence_timestamp", videoID: video.id, requestedTimestamp: 9.5, timestamp: 9.734,
            imageRelativePath: "videos/vid_timestamp/frames/run/frame.jpg", ocrText: "Visible", origin: .automatic
        )
        try await store.replaceEvidence(videoID: video.id, items: [evidence])

        let saved = try #require(try await store.videoSnapshot(id: video.id)?.evidence.first)
        #expect(saved.requestedTimestamp == 9.5)
        #expect(saved.timestamp == 9.734)
    }

    @Test("Revision-bound cursors reject an updated recording")
    func cursorBindsToArtifactRevision() async throws {
        let fixture = try RecoveryFixture()
        let store = try VideoContextStore(databaseURL: fixture.database)
        let video = VideoRecord(id: "vid_cursor", title: "Cursor", source: .localFile,
                                sourceValue: "fixture.mp4", mediaRelativePath: "videos/vid_cursor/video.mp4")
        try await store.createVideo(video)
        try await store.publishArtifacts(
            videoID: video.id,
            transcript: [
                TranscriptSegment(id: "seg_cursor_0", videoID: video.id, start: 0, end: 1, originalText: "one"),
                TranscriptSegment(id: "seg_cursor_1", videoID: video.id, start: 1, end: 2, originalText: "two")
            ],
            evidence: [], brief: BriefDocument(videoID: video.id, markdown: "brief")
        )
        let service = MCPContextService(store: store)
        let first = try await service.segment(videoID: video.id, start: 0, end: 2, limit: 1)
        let cursor = try #require(first.transcript.nextCursor)
        try await store.correctTranscript(segmentID: "seg_cursor_0", correctedText: "changed")
        await #expect(throws: VideoContextStoreError.invalidCursor) {
            _ = try await service.segment(videoID: video.id, start: 0, end: 2, cursor: cursor, limit: 1)
        }
    }

    @Test("Frame timestamp parser returns the measured PTS")
    func parsesMeasuredFrameTimestamp() {
        #expect(FFmpegOutputParser.firstFrameTimestamp("[Parsed_showinfo] n:0 pts_time:1.23456") == 1.23456)
        #expect(FFmpegOutputParser.firstFrameTimestamp("no frame metadata") == nil)
    }

    @Test("Replacing artifacts retains the previous revision payload")
    func sourceArtifactHistoryCapturesBeforeReplacement() async throws {
        let fixture = try RecoveryFixture()
        let store = try VideoContextStore(databaseURL: fixture.database)
        let video = VideoRecord(id: "vid_history", title: "History", source: .localFile,
                                sourceValue: "fixture.mp4", mediaRelativePath: "videos/vid_history/video.mp4")
        try await store.createVideo(video)
        try await store.publishArtifacts(
            videoID: video.id,
            transcript: [TranscriptSegment(id: "history_old", videoID: video.id, start: 0, end: 1, originalText: "old")],
            evidence: [EvidenceItem(id: "evidence_old", videoID: video.id, timestamp: 0.5, imageRelativePath: "videos/vid_history/frames/run-old/frame.jpg", origin: .automatic)],
            brief: BriefDocument(videoID: video.id, markdown: "old brief")
        )
        try await store.replaceTranscript(
            videoID: video.id,
            segments: [TranscriptSegment(id: "history_new", videoID: video.id, start: 0, end: 1, originalText: "new")]
        )
        let history = try await store.sourceArtifactHistory(videoID: video.id)
        let transcriptEntry = try #require(history.first(where: { $0.stage == .transcript }))
        let oldSegments = try JSONDecoder().decode([TranscriptSegment].self, from: transcriptEntry.artifactData)
        #expect(transcriptEntry.revision == 1)
        #expect(oldSegments.map(\.id) == ["history_old"])
    }

    @Test("Feedback import recovery keeps the captured project and recording link")
    func feedbackImportRecoveryPersistsOwnership() async throws {
        let fixture = try RecoveryFixture()
        let store = try VideoContextStore(databaseURL: fixture.database)
        let project = try await store.createFeedbackProject(name: "Checkout")
        let created = try await store.beginFeedbackImport(
            batchID: "batch-1", sourceID: "source-1", projectID: project.id,
            sourceURL: "https://example.test/recording.mp4", filename: "recording.mp4"
        )
        #expect(created?.projectID == project.id)
        _ = try await store.updateFeedbackImport(batchID: "batch-1", sourceID: "source-1", phase: .processing, recordingID: "vid-linked")
        _ = try await store.updateFeedbackImport(batchID: "batch-1", sourceID: "source-1", phase: .failed, recordingID: "vid-linked", errorMessage: "processing failed")
        let recovery = try await store.feedbackImportRecovery(batchID: "batch-1", sourceID: "source-1")
        #expect(recovery?.projectID == project.id)
        #expect(recovery?.recordingID == "vid-linked")
        #expect(recovery?.phase == .failed)
        await #expect(throws: TaskContextError.conflict) {
            _ = try await store.updateFeedbackImport(
                batchID: "batch-1", sourceID: "source-1", phase: .processing, recordingID: "different-recording"
            )
        }
    }
}

private struct RecoveryFixture {
    let root: URL
    let database: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appending(path: "library.sqlite")
    }
}
