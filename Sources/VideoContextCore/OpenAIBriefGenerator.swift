import Foundation

public struct OpenAIBriefGenerator<Client: HTTPDataLoading>: BriefGenerating, Sendable {
    private let client: Client
    private let apiKey: String
    private let model: String
    private let reasoningEffort: ReasoningEffort?
    private let evidenceBatchSize: Int
    private let checkpointStore: VideoContextStore?

    public init(
        client: Client,
        apiKey: String,
        model: String,
        reasoningEffort: ReasoningEffort? = nil,
        evidenceBatchSize: Int = 6,
        checkpointStore: VideoContextStore? = nil
    ) {
        self.client = client
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.evidenceBatchSize = max(1, evidenceBatchSize)
        self.checkpointStore = checkpointStore
    }

    @concurrent
    public func generate(
        videoID: String,
        transcript: [TranscriptSegment],
        evidence: [EvidenceItem],
        paths: LibraryPaths,
        progress: ProcessingProgressHandler? = nil
    ) async throws -> BriefDocument {
        guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw OpenAIClientError.missingAPIKey
        }
        let batches = makeBatches(transcript: transcript, evidence: evidence)
        let total = batches.count + 1
        let startedAt = Date()
        await progress?(ProcessingProgress(stage: .analyzing, completed: 0, total: total, stageStartedAt: startedAt))
        var analyses: [String] = []
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let prompt = BriefPromptBuilder.batchPrompt(transcript: batch.transcript, evidence: batch.evidence)
            let fingerprint = ProcessingFingerprint.make([
                "openai", model, prompt,
                batch.transcript.map { "\($0.id):\($0.start):\($0.end):\($0.text)" }.joined(separator: "\u{1e}"),
                batch.evidence.map { "\($0.id):\($0.timestamp):\($0.imageRelativePath):\($0.ocrText)" }.joined(separator: "\u{1e}"),
                reasoningEffort?.rawValue ?? "none"
            ])
            let itemKey = "batch-\(index)"
            if let checkpointStore,
               let checkpoint = try await checkpointStore.processingCheckpoint(
                   videoID: videoID, stage: .analysisBatch, itemKey: itemKey, inputFingerprint: fingerprint
               ), checkpoint.state == .completed, checkpoint.inputFingerprint == fingerprint,
               let saved = try? checkpoint.decodeOutput(AnalysisCheckpointOutput.self) {
                analyses.append(saved.markdown)
                await progress?(ProcessingProgress(stage: .analyzing, completed: index + 1, total: total, stageStartedAt: startedAt, detail: "Resumed saved analysis"))
                continue
            }
            if let checkpointStore,
               let checkpoint = try await checkpointStore.processingCheckpoint(
                   videoID: videoID, stage: .analysisBatch, itemKey: itemKey, inputFingerprint: fingerprint
               ), checkpoint.state == .completed {
                try? await checkpointStore.resetProcessingCheckpoint(videoID: videoID, stage: .analysisBatch, itemKey: itemKey)
            }
            let started = try await checkpointStore?.beginProcessingCheckpoint(
                videoID: videoID, stage: .analysisBatch, itemKey: itemKey, inputFingerprint: fingerprint,
                provider: InferenceProvider.openAI.rawValue, model: model
            )
            var providerRequestStarted = false
            do {
                let images = try batch.evidence.map { try Data(contentsOf: paths.absoluteURL(relativePath: $0.imageRelativePath)) }
                providerRequestStarted = true
                let markdown = try await requestText(prompt: prompt, images: images)
                if let checkpointStore, started != nil {
                    try await checkpointStore.completeProcessingCheckpoint(
                        videoID: videoID, stage: .analysisBatch, itemKey: itemKey, inputFingerprint: fingerprint,
                        outputData: try ProcessingCheckpoint.encodeOutput(AnalysisCheckpointOutput(markdown: markdown)),
                        expectedRequestID: started?.requestID
                    )
                }
                analyses.append(markdown)
            } catch is CancellationError {
                if let checkpointStore, started != nil {
                    try? await checkpointStore.failProcessingCheckpoint(
                        videoID: videoID, stage: .analysisBatch, itemKey: itemKey,
                        errorMessage: "Analysis was cancelled before the batch completed.", unknownOutcome: false,
                        expectedRequestID: started?.requestID
                    )
                }
                throw CancellationError()
            } catch {
                if let checkpointStore, started != nil {
                    try? await checkpointStore.failProcessingCheckpoint(
                        videoID: videoID, stage: .analysisBatch, itemKey: itemKey,
                        errorMessage: error.localizedDescription, unknownOutcome: providerRequestStarted,
                        expectedRequestID: started?.requestID
                    )
                }
                throw error
            }
            await progress?(ProcessingProgress(stage: .analyzing, completed: index + 1, total: total, stageStartedAt: startedAt))
        }
        try Task.checkCancellation()
        let finalPrompt = BriefPromptBuilder.finalPrompt(batchAnalyses: analyses)
        let finalFingerprint = ProcessingFingerprint.make(["openai-final", model, reasoningEffort?.rawValue ?? "none", finalPrompt])
        let finalItemKey = "final"
        let final: String
        if let checkpointStore,
           let checkpoint = try await checkpointStore.processingCheckpoint(
               videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey, inputFingerprint: finalFingerprint
           ), checkpoint.state == .completed, checkpoint.inputFingerprint == finalFingerprint,
           let saved = try? checkpoint.decodeOutput(AnalysisCheckpointOutput.self) {
            final = saved.markdown
        } else {
            if let checkpointStore,
               let checkpoint = try await checkpointStore.processingCheckpoint(
                   videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey, inputFingerprint: finalFingerprint
               ), checkpoint.state == .completed {
                try? await checkpointStore.resetProcessingCheckpoint(videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey)
            }
            let started = try await checkpointStore?.beginProcessingCheckpoint(
                videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey, inputFingerprint: finalFingerprint,
                provider: InferenceProvider.openAI.rawValue, model: model
            )
            var providerRequestStarted = false
            do {
                providerRequestStarted = true
                final = try await requestText(prompt: finalPrompt, images: [])
                if let checkpointStore, started != nil {
                    try await checkpointStore.completeProcessingCheckpoint(
                        videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey, inputFingerprint: finalFingerprint,
                        outputData: try ProcessingCheckpoint.encodeOutput(AnalysisCheckpointOutput(markdown: final)),
                        expectedRequestID: started?.requestID
                    )
                }
            } catch is CancellationError {
                if let checkpointStore, started != nil {
                    try? await checkpointStore.failProcessingCheckpoint(
                        videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey,
                        errorMessage: "Analysis was cancelled before the final brief completed.", unknownOutcome: false,
                        expectedRequestID: started?.requestID
                    )
                }
                throw CancellationError()
            } catch {
                if let checkpointStore, started != nil {
                    try? await checkpointStore.failProcessingCheckpoint(
                        videoID: videoID, stage: .analysisFinal, itemKey: finalItemKey,
                        errorMessage: error.localizedDescription, unknownOutcome: providerRequestStarted,
                        expectedRequestID: started?.requestID
                    )
                }
                throw error
            }
        }
        await progress?(ProcessingProgress(stage: .analyzing, completed: total, total: total, stageStartedAt: startedAt))
        return BriefDocument(videoID: videoID, markdown: final)
    }

    private func requestText(prompt: String, images: [Data]) async throws -> String {
        let request = try OpenAIRequestBuilder.analysis(apiKey: apiKey, model: model, prompt: prompt, images: images, reasoningEffort: reasoningEffort)
        let response = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIClientError.provider(
                status: response.statusCode,
                message: OpenAIResponseDecoder.errorMessage(from: response.data) ?? "Unknown provider error"
            )
        }
        let output = try OpenAIResponseDecoder.outputText(from: response.data)
        return OpenAIResponseDecoder.markdown(fromStructuredOutput: output) ?? output
    }

    private func makeBatches(transcript: [TranscriptSegment], evidence: [EvidenceItem]) -> [LocalAnalysisBatch] {
        LocalAnalysisBatchPlanner.batches(transcript: transcript, evidence: evidence, textBudget: 32_000, maxFrames: evidenceBatchSize)
    }
}
