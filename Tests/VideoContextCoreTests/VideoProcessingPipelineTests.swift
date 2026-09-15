import Foundation
import Testing
@testable import VideoContextCore

struct VideoProcessingPipelineTests {
    @Test func correctionsDuringGenerationCannotPublishAnApparentlyCurrentBrief() async throws {
        let fixture = try PipelineFixture()
        let store = try VideoContextStore(databaseURL: fixture.paths.database)
        let mediaURL = try fixture.makeMedia(videoID: "vid_edit_during_analysis")
        let video = VideoRecord(id: "vid_edit_during_analysis", title: "Corrections", source: .localFile, sourceValue: mediaURL.path, mediaRelativePath: fixture.paths.relativePath(for: mediaURL))
        try await store.createVideo(video)
        let pipeline = VideoProcessingPipeline(store: store, paths: fixture.paths, media: FixtureMediaProcessor(),
            transcriber: FixtureTranscriber(), textRecognizer: FixtureTextRecognizer(),
            briefGenerator: EditingBriefGenerator(store: store))
        await #expect(throws: (any Error).self) { try await pipeline.process(videoID: video.id) }
        let snapshot = try #require(try await store.videoSnapshot(id: video.id))
        #expect(snapshot.brief?.markdown == "User correction while processing")
        #expect(snapshot.transcript.first?.text == "The corrected requirement")
    }

    @Test("OCR runs one frame at a time in timestamp order and reports progress")
    func ocrIsSequentialAndReportsProgress() async throws {
        let fixture = try PipelineFixture()
        let store = try VideoContextStore(databaseURL: fixture.paths.database)
        let mediaURL = try fixture.makeMedia(videoID: "vid_ocr")
        let video = VideoRecord(id: "vid_ocr", title: "OCR", source: .localFile, sourceValue: mediaURL.path, mediaRelativePath: fixture.paths.relativePath(for: mediaURL))
        try await store.createVideo(video)
        let probe = OCRConcurrencyProbe()
        let recorder = ProgressRecorder()
        let pipeline = VideoProcessingPipeline(
            store: store,
            paths: fixture.paths,
            media: FixtureMediaProcessor(),
            transcriber: FixtureTranscriber(),
            textRecognizer: ProbedTextRecognizer(probe: probe),
            briefGenerator: FixtureBriefGenerator(),
            progress: { await recorder.record($0) }
        )

        try await pipeline.process(videoID: video.id)

        let observation = await probe.observation()
        let ocrProgress = await recorder.values().filter { $0.stage == .recognizingText }
        #expect(observation.maximumConcurrent == 1)
        #expect(observation.filenames == ["0.jpg", "1.jpg"])
        #expect(ocrProgress.map(\.completed) == [0, 1, 2])
        #expect(ocrProgress.allSatisfy { $0.total == 2 })
    }

    @Test("A processing run publishes timestamped context and a current brief")
    func processingRunPublishesContext() async throws {
        let fixture = try PipelineFixture()
        let store = try VideoContextStore(databaseURL: fixture.paths.database)
        let mediaURL = try fixture.makeMedia(videoID: "vid_pipeline")
        let video = VideoRecord(id: "vid_pipeline", title: "Checkout", source: .localFile, sourceValue: mediaURL.path, mediaRelativePath: fixture.paths.relativePath(for: mediaURL))
        try await store.createVideo(video)
        let pipeline = VideoProcessingPipeline(
            store: store,
            paths: fixture.paths,
            media: FixtureMediaProcessor(),
            transcriber: FixtureTranscriber(),
            textRecognizer: FixtureTextRecognizer(),
            briefGenerator: FixtureBriefGenerator()
        )

        try await pipeline.process(videoID: video.id)

        let snapshot = try #require(try await store.videoSnapshot(id: video.id))
        #expect(snapshot.video.status == .ready)
        #expect(snapshot.video.duration == 650)
        #expect(snapshot.transcript.map(\.text) == ["Open checkout", "Click submit"])
        #expect(snapshot.evidence.map(\.ocrText) == ["Payment failed", "Submit"])
        #expect(snapshot.brief?.markdown.contains("Explicit statement") == true)
        #expect(snapshot.video.revisions.isBriefStale == false)
    }

    @Test("A late provider failure preserves completed transcript and evidence")
    func lateFailurePreservesCheckpoints() async throws {
        let fixture = try PipelineFixture()
        let store = try VideoContextStore(databaseURL: fixture.paths.database)
        let mediaURL = try fixture.makeMedia(videoID: "vid_failure")
        let video = VideoRecord(id: "vid_failure", title: "Checkout", source: .localFile, sourceValue: mediaURL.path, mediaRelativePath: fixture.paths.relativePath(for: mediaURL))
        try await store.createVideo(video)
        let pipeline = VideoProcessingPipeline(
            store: store,
            paths: fixture.paths,
            media: FixtureMediaProcessor(),
            transcriber: FixtureTranscriber(),
            textRecognizer: FixtureTextRecognizer(),
            briefGenerator: FailingBriefGenerator()
        )

        await #expect(throws: FixtureFailure.self) {
            try await pipeline.process(videoID: video.id)
        }

        let snapshot = try #require(try await store.videoSnapshot(id: video.id))
        #expect(snapshot.video.status == .incomplete)
        #expect(snapshot.transcript.isEmpty == false)
        #expect(snapshot.evidence.isEmpty == false)
        #expect(snapshot.brief == nil)
        #expect(snapshot.video.errorMessage?.contains("brief failed") == true)
    }

    @Test("Restart resumes from completed transcript and evidence checkpoints")
    func restartUsesCompletedCheckpoints() async throws {
        let fixture = try PipelineFixture()
        let store = try VideoContextStore(databaseURL: fixture.paths.database)
        let mediaURL = try fixture.makeMedia(videoID: "vid_resume")
        let video = VideoRecord(
            id: "vid_resume",
            title: "Resume",
            source: .localFile,
            sourceValue: mediaURL.path,
            mediaRelativePath: fixture.paths.relativePath(for: mediaURL),
            duration: 12,
            status: .incomplete
        )
        try await store.createVideo(video)
        try await store.replaceTranscript(
            videoID: video.id,
            segments: [TranscriptSegment(videoID: video.id, start: 1, end: 3, originalText: "Keep this transcript")]
        )
        try await store.replaceEvidence(
            videoID: video.id,
            items: [EvidenceItem(videoID: video.id, timestamp: 2, imageRelativePath: "saved.jpg", ocrText: "Saved evidence", origin: .automatic)]
        )
        let pipeline = VideoProcessingPipeline(
            store: store,
            paths: fixture.paths,
            media: ResumeMediaProcessor(),
            transcriber: FailingTranscriber(),
            textRecognizer: FailingTextRecognizer(),
            briefGenerator: FixtureBriefGenerator()
        )

        try await pipeline.process(videoID: video.id)

        let snapshot = try #require(try await store.videoSnapshot(id: video.id))
        #expect(snapshot.video.status == .ready)
        #expect(snapshot.transcript.map(\.text) == ["Keep this transcript"])
        #expect(snapshot.evidence.map(\.ocrText) == ["Saved evidence"])
    }

    @Test("Cancellation persists a recoverable recording state")
    func cancellationIsPersisted() async throws {
        let fixture = try PipelineFixture()
        let store = try VideoContextStore(databaseURL: fixture.paths.database)
        let mediaURL = try fixture.makeMedia(videoID: "vid_cancel")
        let video = VideoRecord(id: "vid_cancel", title: "Cancel", source: .localFile, sourceValue: mediaURL.path, mediaRelativePath: fixture.paths.relativePath(for: mediaURL))
        try await store.createVideo(video)
        let pipeline = VideoProcessingPipeline(
            store: store,
            paths: fixture.paths,
            media: SlowMediaProcessor(),
            transcriber: FailingTranscriber(),
            textRecognizer: FailingTextRecognizer(),
            briefGenerator: FailingBriefGenerator()
        )
        let task = Task { try await pipeline.process(videoID: video.id) }
        try await Task.sleep(for: .milliseconds(20))

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let snapshot = try #require(try await store.videoSnapshot(id: video.id))
        #expect(snapshot.video.status == .cancelled)
        #expect(snapshot.video.errorMessage == "Processing was cancelled.")
    }
}

private struct PipelineFixture {
    let root: URL
    let paths: LibraryPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = try LibraryPaths(root: root)
    }

    func makeMedia(videoID: String) throws -> URL {
        let url = try paths.videoDirectory(id: videoID).appending(path: "video.mp4")
        try Data("fixture".utf8).write(to: url)
        return url
    }
}

private struct FixtureMediaProcessor: MediaProcessing {
    func inspect(_ videoURL: URL) async throws -> MediaInspection {
        MediaInspection(duration: 650, hasVideo: true, hasAudio: true)
    }

    func silencePoints(in videoURL: URL) async throws -> [TimeInterval] { [31] }
    func sceneChanges(in videoURL: URL) async throws -> [TimeInterval] { [8] }

    func extractAudio(from videoURL: URL, chunks: [AudioChunk], directory: URL) async throws -> [AudioChunkFile] {
        try chunks.map { chunk in
            let url = directory.appending(path: "\(chunk.index).m4a")
            try Data("audio".utf8).write(to: url)
            return AudioChunkFile(chunk: chunk, url: url)
        }
    }

    func captureFrames(from videoURL: URL, timestamps: [TimeInterval], directory: URL) async throws -> [CapturedFrame] {
        try Array(timestamps.prefix(2)).enumerated().map { index, timestamp in
            let url = directory.appending(path: "\(index).jpg")
            try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            return CapturedFrame(timestamp: timestamp, url: url)
        }
    }
}

private struct FixtureTranscriber: Transcribing {
    func transcribe(audioURL: URL, videoID: String, chunkStart: TimeInterval) async throws -> [TranscriptSegment] {
        if chunkStart == 0 {
            return [TranscriptSegment(videoID: videoID, start: 1, end: 5, originalText: "Open checkout")]
        }
        return [TranscriptSegment(videoID: videoID, start: chunkStart + 1, end: chunkStart + 5, originalText: "Click submit")]
    }
}

private struct FixtureTextRecognizer: TextRecognizing {
    func recognizeText(in imageURL: URL) async throws -> String {
        imageURL.lastPathComponent == "0.jpg" ? "Payment failed" : "Submit"
    }
}

private actor OCRConcurrencyProbe {
    private var active = 0
    private var maximum = 0
    private var filenames: [String] = []

    func begin(_ filename: String) {
        active += 1
        maximum = max(maximum, active)
        filenames.append(filename)
    }

    func end() { active -= 1 }

    func observation() -> (maximumConcurrent: Int, filenames: [String]) {
        (maximum, filenames)
    }
}

private struct ProbedTextRecognizer: TextRecognizing {
    let probe: OCRConcurrencyProbe

    func recognizeText(in imageURL: URL) async throws -> String {
        await probe.begin(imageURL.lastPathComponent)
        await Task.yield()
        await probe.end()
        return imageURL.lastPathComponent
    }
}

private actor ProgressRecorder {
    private var recorded: [ProcessingProgress] = []

    func record(_ progress: ProcessingProgress) { recorded.append(progress) }
    func values() -> [ProcessingProgress] { recorded }
}

private struct FixtureBriefGenerator: BriefGenerating {
    func generate(
        videoID: String,
        transcript: [TranscriptSegment],
        evidence: [EvidenceItem],
        paths: LibraryPaths,
        progress: ProcessingProgressHandler?
    ) async throws -> BriefDocument {
        BriefDocument(videoID: videoID, markdown: "# Goal\nExplicit statement: fix checkout. [00:01]")
    }
}

private enum FixtureFailure: Error, LocalizedError {
    case failed
    var errorDescription: String? { "brief failed" }
}

private struct FailingBriefGenerator: BriefGenerating {
    func generate(
        videoID: String,
        transcript: [TranscriptSegment],
        evidence: [EvidenceItem],
        paths: LibraryPaths,
        progress: ProcessingProgressHandler?
    ) async throws -> BriefDocument {
        throw FixtureFailure.failed
    }
}

private struct ResumeMediaProcessor: MediaProcessing {
    func inspect(_ videoURL: URL) async throws -> MediaInspection {
        MediaInspection(duration: 12, hasVideo: true, hasAudio: true)
    }
    func silencePoints(in videoURL: URL) async throws -> [TimeInterval] { throw FixtureFailure.failed }
    func sceneChanges(in videoURL: URL) async throws -> [TimeInterval] { throw FixtureFailure.failed }
    func extractAudio(from videoURL: URL, chunks: [AudioChunk], directory: URL) async throws -> [AudioChunkFile] { throw FixtureFailure.failed }
    func captureFrames(from videoURL: URL, timestamps: [TimeInterval], directory: URL) async throws -> [CapturedFrame] { throw FixtureFailure.failed }
}

private struct FailingTranscriber: Transcribing {
    func transcribe(audioURL: URL, videoID: String, chunkStart: TimeInterval) async throws -> [TranscriptSegment] {
        throw FixtureFailure.failed
    }
}

private struct FailingTextRecognizer: TextRecognizing {
    func recognizeText(in imageURL: URL) async throws -> String { throw FixtureFailure.failed }
}

private struct SlowMediaProcessor: MediaProcessing {
    func inspect(_ videoURL: URL) async throws -> MediaInspection {
        try await Task.sleep(for: .seconds(30))
        return MediaInspection(duration: 10, hasVideo: true, hasAudio: true)
    }
    func silencePoints(in videoURL: URL) async throws -> [TimeInterval] { [] }
    func sceneChanges(in videoURL: URL) async throws -> [TimeInterval] { [] }
    func extractAudio(from videoURL: URL, chunks: [AudioChunk], directory: URL) async throws -> [AudioChunkFile] { [] }
    func captureFrames(from videoURL: URL, timestamps: [TimeInterval], directory: URL) async throws -> [CapturedFrame] { [] }
}

private struct EditingBriefGenerator: BriefGenerating {
    let store: VideoContextStore
    func generate(videoID: String, transcript: [TranscriptSegment], evidence: [EvidenceItem], paths: LibraryPaths,
                  progress: ProcessingProgressHandler?) async throws -> BriefDocument {
        try await store.correctTranscript(segmentID: transcript[0].id, correctedText: "The corrected requirement")
        try await store.updateBrief(videoID: videoID, markdown: "User correction while processing")
        return BriefDocument(videoID: videoID, markdown: "Outdated provider output")
    }
}
