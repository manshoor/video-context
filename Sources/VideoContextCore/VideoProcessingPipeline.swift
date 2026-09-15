import Foundation

public actor VideoProcessingPipeline {
    private let store: VideoContextStore
    private let paths: LibraryPaths
    private let media: any MediaProcessing
    private let transcriber: any Transcribing
    private let textRecognizer: any TextRecognizing
    private let briefGenerator: any BriefGenerating
    private let progress: ProcessingProgressHandler?
    private let transcriptionIdentity: ProviderIdentity?
    private let analysisIdentity: ProviderIdentity?
    private var activeVideoID: String?
    private var reportedStage: ProcessingStatus?
    private var stageStartedAt = Date()

    public init(
        store: VideoContextStore,
        paths: LibraryPaths,
        media: any MediaProcessing,
        transcriber: any Transcribing,
        textRecognizer: any TextRecognizing,
        briefGenerator: any BriefGenerating,
        progress: ProcessingProgressHandler? = nil,
        transcriptionIdentity: ProviderIdentity? = nil,
        analysisIdentity: ProviderIdentity? = nil
    ) {
        self.store = store
        self.paths = paths
        self.media = media
        self.transcriber = transcriber
        self.textRecognizer = textRecognizer
        self.briefGenerator = briefGenerator
        self.transcriptionIdentity = transcriptionIdentity
        self.analysisIdentity = analysisIdentity
        self.progress = progress
    }

    public func process(videoID: String) async throws {
        guard activeVideoID == nil else { throw MediaProcessingError.processingAlreadyActive }
        activeVideoID = videoID
        defer { activeVideoID = nil }

        do {
            try Task.checkCancellation()
            guard let initial = try await store.videoSnapshot(id: videoID) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            var sourceRevision = initial.video.revisions
            let videoURL = paths.absoluteURL(relativePath: initial.video.mediaRelativePath)

            await report(stage: .inspecting)
            try await store.updateVideo(id: videoID, status: .inspecting)
            let inspection = try await media.inspect(videoURL)
            guard inspection.hasVideo else { throw MediaProcessingError.videoMissing }
            guard inspection.hasAudio else { throw MediaProcessingError.audioMissing }
            var transcript = initial.transcript
            if transcript.isEmpty {
                await report(stage: .extractingAudio)
                try await store.updateVideo(id: videoID, duration: inspection.duration, status: .extractingAudio)
                let silence = try await media.silencePoints(in: videoURL)
                let chunks = try AudioChunkPlanner(maxDuration: 600, overlap: 2).plan(
                    duration: inspection.duration,
                    silencePoints: silence
                )
                let audioFiles = try await media.extractAudio(
                    from: videoURL,
                    chunks: chunks,
                    directory: try paths.chunksDirectory(id: videoID)
                )

                let sortedAudio = audioFiles.sorted(by: { $0.chunk.index < $1.chunk.index })
                await report(stage: .transcribing, completed: 0, total: sortedAudio.count)
                try await store.updateVideo(id: videoID, status: .transcribing)
                for (index, audio) in sortedAudio.enumerated() {
                    try Task.checkCancellation()
                    transcript.append(contentsOf: try await transcriber.transcribe(
                        audioURL: audio.url,
                        videoID: videoID,
                        chunkStart: audio.chunk.start
                    ))
                    await report(stage: .transcribing, completed: index + 1, total: sortedAudio.count)
                }
                transcript = Self.deduplicate(transcript)
                try Task.checkCancellation()
                try await store.replaceTranscript(videoID: videoID, segments: transcript, provenance: transcriptionIdentity)
                sourceRevision.transcript += 1
            } else {
                try await store.updateVideo(id: videoID, duration: inspection.duration)
            }

            await transcriber.releaseResources()
            var evidence = initial.evidence
            if evidence.isEmpty {
                await report(stage: .capturingFrames)
                try await store.updateVideo(id: videoID, status: .capturingFrames)
                let scenes = try await media.sceneChanges(in: videoURL)
                let cues = InstructionCueDetector.timestamps(in: transcript)
                let timestamps = ScreenshotPlanner().timestamps(
                    duration: inspection.duration,
                    sceneChanges: scenes,
                    transcriptCues: cues
                )
                let capturedFrames = try await media.captureFrames(
                    from: videoURL,
                    timestamps: timestamps,
                    directory: try paths.framesDirectory(id: videoID)
                )
                let frames = await FrameSimilarityDeduplicator().deduplicate(
                    capturedFrames,
                    preserving: cues
                )

                try await store.updateVideo(id: videoID, status: .recognizingText)
                evidence = try await recognizeEvidence(videoID: videoID, frames: frames)
                try Task.checkCancellation()
                try await store.replaceEvidence(videoID: videoID, items: evidence, expectedEvidenceRevision: sourceRevision.evidence)
                sourceRevision.evidence += 1
            }

            try Task.checkCancellation()
            try await store.updateVideo(id: videoID, status: .analyzing)
            let brief = try await briefGenerator.generate(
                videoID: videoID,
                transcript: transcript,
                evidence: evidence,
                paths: paths,
                progress: progress
            )
            try Task.checkCancellation()
            try await store.publishBrief(videoID: videoID, brief: brief, provenance: analysisIdentity, expectedRevision: sourceRevision)
        } catch is CancellationError {
            await transcriber.releaseResources()
            try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Processing was cancelled.")
            throw CancellationError()
        } catch {
            await transcriber.releaseResources()
            try? await store.markIncomplete(videoID: videoID, error: error.localizedDescription)
            throw error
        }
    }

    private func recognizeEvidence(videoID: String, frames: [CapturedFrame]) async throws -> [EvidenceItem] {
        let sortedFrames = frames.sorted { $0.timestamp < $1.timestamp }
        await report(stage: .recognizingText, completed: 0, total: sortedFrames.count)
        var items: [EvidenceItem] = []
        for (index, frame) in sortedFrames.enumerated() {
            try Task.checkCancellation()
            let text = try await textRecognizer.recognizeText(in: frame.url)
            items.append(EvidenceItem(
                videoID: videoID,
                timestamp: frame.timestamp,
                imageRelativePath: paths.relativePath(for: frame.url),
                ocrText: text,
                origin: .automatic
            ))
            await report(stage: .recognizingText, completed: index + 1, total: sortedFrames.count)
        }
        return items
    }

    private func report(stage: ProcessingStatus, completed: Int? = nil, total: Int? = nil) async {
        if reportedStage != stage {
            reportedStage = stage
            stageStartedAt = .now
        }
        await progress?(ProcessingProgress(
            stage: stage,
            completed: completed,
            total: total,
            stageStartedAt: stageStartedAt
        ))
    }

    private static func deduplicate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let normalized = normalize(segment.text)
            if let previous = result.last,
               normalize(previous.text) == normalized,
               previous.end >= segment.start {
                continue
            }
            result.append(segment)
        }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
