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
            // Persist the inspection result before branching into audio or
            // visual processing. This makes silent recordings explicit to the
            // workspace and MCP readers, and keeps that fact available after a
            // restart even when later provider work fails.
            _ = try await store.saveAudioCoverage(
                videoID: videoID,
                hasAudio: inspection.hasAudio,
                duration: inspection.duration
            )
            var transcript = initial.transcript
            if transcript.isEmpty && inspection.hasAudio {
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
                    let itemKey = "chunk-\(audio.chunk.index)"
                    let fingerprint = ProcessingFingerprint.make([
                        "transcript", videoID, itemKey,
                        String(format: "%.6f", audio.chunk.start),
                        String(format: "%.6f", audio.chunk.end),
                        String(format: "%.6f", audio.chunk.contentStart),
                        audio.url.path
                    ])
                    if let checkpoint = try await store.processingCheckpoint(
                        videoID: videoID, stage: .transcriptChunk, itemKey: itemKey, inputFingerprint: fingerprint
                    ), checkpoint.state == .completed, checkpoint.inputFingerprint == fingerprint {
                        if let saved = try? checkpoint.decodeOutput(TranscriptCheckpointOutput.self) {
                            transcript.append(contentsOf: saved.segments)
                            await report(stage: .transcribing, completed: index + 1, total: sortedAudio.count)
                            continue
                        }
                        try? await store.resetProcessingCheckpoint(videoID: videoID, stage: .transcriptChunk, itemKey: itemKey)
                    }
                    let started = try await store.beginProcessingCheckpoint(
                        videoID: videoID, stage: .transcriptChunk, itemKey: itemKey, inputFingerprint: fingerprint,
                        provider: transcriptionIdentity?.provider.rawValue, model: transcriptionIdentity?.model
                    )
                    do {
                        let segments = try await transcriber.transcribe(
                            audioURL: audio.url,
                            videoID: videoID,
                            chunkStart: audio.chunk.start
                        )
                        if started != nil {
                            try await store.completeProcessingCheckpoint(
                                videoID: videoID, stage: .transcriptChunk, itemKey: itemKey,
                                inputFingerprint: fingerprint,
                                outputData: try ProcessingCheckpoint.encodeOutput(TranscriptCheckpointOutput(segments: segments)),
                                expectedRequestID: started?.requestID
                            )
                        }
                        transcript.append(contentsOf: segments)
                    } catch is CancellationError {
                        if started != nil {
                            try? await store.failProcessingCheckpoint(
                                videoID: videoID, stage: .transcriptChunk, itemKey: itemKey,
                                errorMessage: "Transcription was cancelled before the chunk completed.", unknownOutcome: false,
                                expectedRequestID: started?.requestID
                            )
                        }
                        throw CancellationError()
                    } catch {
                        if started != nil {
                            try? await store.failProcessingCheckpoint(
                                videoID: videoID, stage: .transcriptChunk, itemKey: itemKey,
                                errorMessage: error.localizedDescription, unknownOutcome: true,
                                expectedRequestID: started?.requestID
                            )
                        }
                        throw error
                    }
                    await report(stage: .transcribing, completed: index + 1, total: sortedAudio.count)
                }
                transcript = Self.deduplicate(transcript)
                try Task.checkCancellation()
                try await store.replaceTranscript(videoID: videoID, segments: transcript, provenance: transcriptionIdentity)
                sourceRevision.transcript += 1
                await UsageTrace.cache(key: "transcript:\(videoID):\(sourceRevision.transcript)", reused: false)
            } else if transcript.isEmpty && !inspection.hasAudio {
                // Silent screen recordings still contain visual evidence. They
                // skip transcription and continue through frame/OCR analysis.
                await report(stage: .capturingFrames)
                try await store.updateVideo(id: videoID, duration: inspection.duration, status: .capturingFrames)
            } else {
                await UsageTrace.cache(key: "transcript:\(videoID):\(sourceRevision.transcript)", reused: true)
                await DiagnosticTrace.record(.checkpointReused, stage: .transcribing, completed: transcript.count, total: transcript.count)
                try await store.updateVideo(id: videoID, duration: inspection.duration)
            }

            await transcriber.releaseResources()
            var evidence = initial.evidence
            if !evidence.isEmpty { await UsageTrace.cache(key: "evidence:\(videoID):\(sourceRevision.evidence)", reused: true); await DiagnosticTrace.record(.checkpointReused, stage: .recognizingText, completed: evidence.count, total: evidence.count) }
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
                // Each evidence input gets an immutable capture directory. A
                // later run therefore cannot overwrite the image path cited
                // by an older brief or documentation revision.
                let captureKey = ProcessingFingerprint.make([
                    "frames", videoID,
                    String(sourceRevision.transcript), String(sourceRevision.evidence),
                    timestamps.map { String(format: "%.6f", $0) }.joined(separator: ",")
                ])
                let captureDirectory = try paths.framesDirectory(id: videoID)
                    .appending(path: "run-\(captureKey.prefix(24))", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
                var capturedFrames: [CapturedFrame] = []
                var missingTimestamps: [TimeInterval] = []
                for requestedTimestamp in timestamps {
                    let itemKey = Self.frameCaptureItemKey(requestedTimestamp)
                    let fingerprint = Self.frameCaptureFingerprint(
                        videoID: videoID,
                        captureKey: captureKey,
                        requestedTimestamp: requestedTimestamp
                    )
                    if let checkpoint = try await store.processingCheckpoint(
                        videoID: videoID, stage: .frameCapture, itemKey: itemKey, inputFingerprint: fingerprint
                    ) {
                        switch checkpoint.state {
                        case .running, .unknown:
                            throw ProcessingRecoveryError.unknownOutcome(videoID: videoID, stage: .frameCapture, itemKey: itemKey)
                        case .completed:
                            // A completed checkpoint with a different capture
                            // fingerprint belongs to an older source revision
                            // or timestamp plan. Keep its immutable file for
                            // historical evidence, but capture this input again.
                            if checkpoint.inputFingerprint == fingerprint,
                               let output = try? checkpoint.decodeOutput(FrameCaptureCheckpointOutput.self) {
                                let url = paths.absoluteURL(relativePath: output.imageRelativePath)
                                if FileManager.default.fileExists(atPath: url.path) {
                                    capturedFrames.append(CapturedFrame(
                                        timestamp: output.measuredTimestamp,
                                        url: url,
                                        requestedTimestamp: output.requestedTimestamp
                                    ))
                                    continue
                                }
                            }
                            try? await store.resetProcessingCheckpoint(videoID: videoID, stage: .frameCapture, itemKey: itemKey)
                        case .failed:
                            break
                        }
                    }
                    missingTimestamps.append(requestedTimestamp)
                }
                if !missingTimestamps.isEmpty {
                    let persistFrame: @Sendable (CapturedFrame) async throws -> Void = { [self] frame in
                        try await self.persistFrameCaptureCheckpoint(
                            videoID: videoID,
                            captureKey: captureKey,
                            frame: frame
                        )
                    }
                    let newlyCaptured: [CapturedFrame]
                    if let incremental = media as? any IncrementalFrameCapturing {
                        newlyCaptured = try await incremental.captureFrames(
                            from: videoURL,
                            timestamps: missingTimestamps,
                            directory: captureDirectory,
                            onFrame: persistFrame
                        )
                    } else {
                        newlyCaptured = try await media.captureFrames(
                            from: videoURL,
                            timestamps: missingTimestamps,
                            directory: captureDirectory
                        )
                        // Legacy processors return only after the complete
                        // batch. Persist their completed frames before OCR;
                        // incremental processors persist each frame as it is
                        // produced above.
                        for frame in newlyCaptured {
                            try await persistFrame(frame)
                        }
                    }
                    capturedFrames.append(contentsOf: newlyCaptured)
                }
                let frames = await FrameSimilarityDeduplicator().deduplicate(
                    capturedFrames,
                    preserving: cues
                )

                try await store.updateVideo(id: videoID, status: .recognizingText)
                evidence = try await recognizeEvidence(videoID: videoID, frames: frames)
                try Task.checkCancellation()
                try await store.replaceEvidence(videoID: videoID, items: evidence, expectedEvidenceRevision: sourceRevision.evidence)
                sourceRevision.evidence += 1
                await UsageTrace.cache(key: "evidence:\(videoID):\(sourceRevision.evidence)", reused: false)
            }

            try Task.checkCancellation()
            await report(stage: .analyzing)
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
            await DiagnosticTrace.record(.cancelled, stage: reportedStage)
            await transcriber.releaseResources()
            try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Processing was cancelled.")
            throw CancellationError()
        } catch {
            await DiagnosticTrace.record(.failed, stage: reportedStage, error: error)
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
            let imageRelativePath = paths.relativePath(for: frame.url)
            let fingerprint = ProcessingFingerprint.make([
                "ocr", videoID,
                String(format: "%.6f", frame.requestedTimestamp),
                imageRelativePath
            ])
            let itemKey = "frame-\(fingerprint.prefix(24))"
            if let checkpoint = try await store.processingCheckpoint(
                videoID: videoID, stage: .ocrFrame, itemKey: itemKey, inputFingerprint: fingerprint
            ), checkpoint.state == .completed, checkpoint.inputFingerprint == fingerprint,
               let saved = try? checkpoint.decodeOutput(OCRCheckpointOutput.self),
               FileManager.default.fileExists(atPath: paths.absoluteURL(relativePath: saved.imageRelativePath).path) {
                items.append(EvidenceItem(
                    id: saved.evidenceID,
                    videoID: videoID,
                    requestedTimestamp: saved.requestedTimestamp,
                    timestamp: saved.timestamp,
                    imageRelativePath: saved.imageRelativePath,
                    ocrText: saved.ocrText,
                    origin: .automatic
                ))
                await report(stage: .recognizingText, completed: index + 1, total: sortedFrames.count)
                continue
            }
            if let checkpoint = try await store.processingCheckpoint(
                videoID: videoID, stage: .ocrFrame, itemKey: itemKey, inputFingerprint: fingerprint
            ), checkpoint.state == .completed, checkpoint.inputFingerprint == fingerprint {
                try? await store.resetProcessingCheckpoint(videoID: videoID, stage: .ocrFrame, itemKey: itemKey)
            }
            let started = try await store.beginProcessingCheckpoint(
                videoID: videoID, stage: .ocrFrame, itemKey: itemKey, inputFingerprint: fingerprint
            )
            do {
                let text = try await textRecognizer.recognizeText(in: frame.url)
                let evidenceID = "ev_\(fingerprint.prefix(32))"
                let output = OCRCheckpointOutput(
                    evidenceID: evidenceID, requestedTimestamp: frame.requestedTimestamp, timestamp: frame.timestamp,
                    imageRelativePath: imageRelativePath, ocrText: text
                )
                if started != nil {
                    try await store.completeProcessingCheckpoint(
                        videoID: videoID, stage: .ocrFrame, itemKey: itemKey,
                        inputFingerprint: fingerprint,
                        outputData: try ProcessingCheckpoint.encodeOutput(output),
                        expectedRequestID: started?.requestID
                    )
                }
                items.append(EvidenceItem(
                    id: evidenceID, videoID: videoID, requestedTimestamp: frame.requestedTimestamp, timestamp: frame.timestamp,
                    imageRelativePath: imageRelativePath, ocrText: text, origin: .automatic
                ))
            } catch is CancellationError {
                if started != nil {
                    try? await store.failProcessingCheckpoint(
                        videoID: videoID, stage: .ocrFrame, itemKey: itemKey,
                        errorMessage: "Screen text recognition was cancelled before the frame completed.", unknownOutcome: false,
                        expectedRequestID: started?.requestID
                    )
                }
                throw CancellationError()
            } catch {
                if started != nil {
                    try? await store.failProcessingCheckpoint(
                        videoID: videoID, stage: .ocrFrame, itemKey: itemKey,
                        errorMessage: error.localizedDescription, unknownOutcome: false,
                        expectedRequestID: started?.requestID
                    )
                }
                throw error
            }
            await report(stage: .recognizingText, completed: index + 1, total: sortedFrames.count)
        }
        return items
    }

    private func persistFrameCaptureCheckpoint(
        videoID: String,
        captureKey: String,
        frame: CapturedFrame
    ) async throws {
        let requestedTimestamp = frame.requestedTimestamp
        let itemKey = Self.frameCaptureItemKey(requestedTimestamp)
        let fingerprint = Self.frameCaptureFingerprint(
            videoID: videoID,
            captureKey: captureKey,
            requestedTimestamp: requestedTimestamp
        )
        guard let started = try await store.beginProcessingCheckpoint(
            videoID: videoID,
            stage: .frameCapture,
            itemKey: itemKey,
            inputFingerprint: fingerprint
        ), started.state == .running else { return }
        let output = FrameCaptureCheckpointOutput(
            requestedTimestamp: requestedTimestamp,
            measuredTimestamp: frame.timestamp,
            imageRelativePath: paths.relativePath(for: frame.url)
        )
        try await store.completeProcessingCheckpoint(
            videoID: videoID,
            stage: .frameCapture,
            itemKey: itemKey,
            inputFingerprint: fingerprint,
            outputData: try ProcessingCheckpoint.encodeOutput(output),
            expectedRequestID: started.requestID
        )
    }

    private func report(stage: ProcessingStatus, completed: Int? = nil, total: Int? = nil) async {
        if let scope = DiagnosticTrace.scope {
            let identity = stage == .transcribing ? transcriptionIdentity : stage == .analyzing ? analysisIdentity : nil
            await scope.service.record(.init(.stateChanged, operation: scope.operation, operationID: scope.id,
                context: .init(videoID: activeVideoID, provider: identity?.provider, model: identity?.model),
                stage: stage, completed: completed, total: total, elapsedSeconds: Date().timeIntervalSince(stageStartedAt)))
        }
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

    private static func frameCaptureItemKey(_ requestedTimestamp: TimeInterval) -> String {
        "requested-\(String(format: "%.6f", requestedTimestamp))"
    }

    private static func frameCaptureFingerprint(videoID: String, captureKey: String, requestedTimestamp: TimeInterval) -> String {
        ProcessingFingerprint.make([
            "frame-capture", videoID, captureKey,
            String(format: "%.6f", requestedTimestamp)
        ])
    }
}
