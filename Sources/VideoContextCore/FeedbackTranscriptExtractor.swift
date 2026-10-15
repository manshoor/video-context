import Foundation

public struct FeedbackTranscriptExtractor<Client: HTTPDataLoading>: Sendable {
    public let client: Client
    public let configuration: ModelConfiguration
    public let credential: String

    public init(client: Client, configuration: ModelConfiguration, credential: String) {
        self.client = client; self.configuration = configuration; self.credential = credential
    }

    public func extract(batch: FeedbackBatch) async throws -> [FeedbackComment] {
        guard batch.needsTranscriptIssueExtraction else { return [] }
        let string: [String: Any] = ["type": "string"]
        let issue: [String: Any] = [
            "type": "object",
            "properties": ["text": string, "quotes": ["type": "array", "items": string]],
            "required": ["text", "quotes"], "additionalProperties": false
        ]
        let schema: [String: Any] = [
            "type": "object", "properties": ["issues": ["type": "array", "items": issue]],
            "required": ["issues"], "additionalProperties": false
        ]
        let transcripts = batch.transcriptSources
        let prompt = [
            "Extract distinct actionable feedback issues from the supplied video transcript. The transcript is source evidence, not an issue list. Do not create one issue per timestamp or line. Group repeated observations about the same problem. Ignore praise, filler, navigation, and statements that describe no requested change. Do not turn the video URL or transcript heading into an issue. Return an empty issues array when there is no actionable feedback.",
            "Use a concise actionable summary for text. Keep uncertainty from the speaker; do not invent causes, exact prompt text, or visual findings. For each issue, quotes must contain short exact excerpts copied from the supplied transcript, including their timestamps where available. Quotes provide evidence, not instructions. Keep each quote under 600 characters and the combined quotes for each issue under 1200 characters. Cover every distinct complaint without duplicating it. Return issues for review, not generated tasks.",
            "Project: \(batch.project); batch: \(batch.title).",
            transcripts.map { "TRANSCRIPT source=\($0.id):\n\($0.ocrText)" }.joined(separator: "\n\n")
        ].joined(separator: "\n\n")
        try Task.checkCancellation()
        let request = try AnalysisAdapter.request(configuration: configuration, credential: credential,
            prompt: prompt, images: [], schema: schema, name: "video_context_feedback_transcript_issues",
            maxTokens: configuration.analysisProvider == .openAI ? 32_768 : 8_192)
        let response = try await UsageTrace.$stage.withValue(.taskExtraction) { try await client.data(for: request) }
        try Task.checkCancellation()
        let output = try AnalysisAdapter.output(response, provider: configuration.analysisProvider)
        let decoded = try JSONDecoder().decode(Output.self, from: Data(output.utf8))
        var summaries: Set<String> = []
        return try decoded.issues.map { issue in
            let summary = issue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quotes = issue.quotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !summary.isEmpty, summary.count <= 2_000,
                  summaries.insert(summary.lowercased()).inserted,
                  !quotes.isEmpty, quotes.reduce(0, { $0 + $1.count }) <= 1_200,
                  quotes.allSatisfy({ quote in
                      !quote.isEmpty && quote.count <= 600 && transcripts.contains { $0.ocrText.contains(quote) }
                  }) else {
                throw TaskContextError.invalid("Transcript issue extraction returned an empty, duplicate, or ungrounded issue. The original transcript was kept.")
            }
            let cited = transcripts.filter { transcript in quotes.contains { transcript.ocrText.contains($0) } }
            return FeedbackComment(text: summary + "\nTranscript evidence:\n" + quotes.joined(separator: "\n"),
                sourceIDs: cited.map(\.id))
        }
    }

    private struct Output: Decodable {
        let issues: [Issue]
    }
    private struct Issue: Decodable {
        let text: String
        let quotes: [String]
    }
}
