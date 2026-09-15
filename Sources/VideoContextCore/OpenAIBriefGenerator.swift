import Foundation

public struct OpenAIBriefGenerator<Client: HTTPDataLoading>: BriefGenerating, Sendable {
    private let client: Client
    private let apiKey: String
    private let model: String
    private let evidenceBatchSize: Int

    public init(client: Client, apiKey: String, model: String, evidenceBatchSize: Int = 6) {
        self.client = client
        self.apiKey = apiKey
        self.model = model
        self.evidenceBatchSize = max(1, evidenceBatchSize)
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
            let images = try batch.evidence.map { try Data(contentsOf: paths.absoluteURL(relativePath: $0.imageRelativePath)) }
            let prompt = BriefPromptBuilder.batchPrompt(transcript: batch.transcript, evidence: batch.evidence)
            analyses.append(try await requestText(prompt: prompt, images: images))
            await progress?(ProcessingProgress(stage: .analyzing, completed: index + 1, total: total, stageStartedAt: startedAt))
        }
        try Task.checkCancellation()
        let final = try await requestText(prompt: BriefPromptBuilder.finalPrompt(batchAnalyses: analyses), images: [])
        await progress?(ProcessingProgress(stage: .analyzing, completed: total, total: total, stageStartedAt: startedAt))
        return BriefDocument(videoID: videoID, markdown: final)
    }

    private func requestText(prompt: String, images: [Data]) async throws -> String {
        let request = try OpenAIRequestBuilder.analysis(apiKey: apiKey, model: model, prompt: prompt, images: images)
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
