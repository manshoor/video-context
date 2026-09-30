import Foundation

private struct FeedbackPreparationOutput: Codable {
    let suggestions: [FeedbackPreparationSuggestion]
}

public struct FeedbackPreparer<Client: HTTPDataLoading>: Sendable {
    public let client: Client
    public let configuration: ModelConfiguration
    public let credential: String
    public let paths: LibraryPaths

    public init(client: Client, configuration: ModelConfiguration, credential: String, paths: LibraryPaths) {
        self.client = client; self.configuration = configuration; self.credential = credential; self.paths = paths
    }

    public func suggest(batch: FeedbackBatch) async throws -> [FeedbackPreparationSuggestion] {
        let issues = batch.comments
        guard !issues.isEmpty else { return [] }
        let string: [String: Any] = ["type": "string"]
        let suggestion: [String: Any] = [
            "type": "object",
            "properties": ["issueID": string, "joinWithPrevious": ["type": "boolean"],
                           "sharedInstruction": ["type": "boolean"], "sourceIDs": ["type": "array", "items": string],
                           "duplicateOfIssueID": string],
            "required": ["issueID", "joinWithPrevious", "sharedInstruction", "sourceIDs", "duplicateOfIssueID"],
            "additionalProperties": false
        ]
        let schema: [String: Any] = ["type": "object", "properties": ["suggestions": ["type": "array", "items": suggestion]],
                                     "required": ["suggestions"], "additionalProperties": false]
        var results: [FeedbackPreparationSuggestion] = []
        for start in stride(from: 0, to: issues.count, by: 12) {
            try Task.checkCancellation()
            let chunk = Array(issues[start..<min(start + 12, issues.count)])
            let issueIDs = Set(chunk.map(\.id))
            let sourceIDs = Set(batch.sources.map(\.id))
            let lines = [
                "Suggest issue grouping, shared instructions, likely duplicate issues, and evidence association. This is advice only: do not remove, merge, or rewrite issues. Return one suggestion for every issueID. Use empty duplicateOfIssueID when there is no likely duplicate. Source IDs must be from the supplied evidence.",
                "Project \(batch.project); batch \(batch.title).",
                "All issues for duplicate context:\n" + issues.map { "\($0.id): \($0.text)" }.joined(separator: "\n"),
                "FOCUS ISSUES:\n" + chunk.map { "\($0.id) lines \($0.lineNumbers): \($0.text); linked \($0.sourceIDs)" }.joined(separator: "\n"),
                "Evidence:\n" + batch.sources.map { "\($0.id): \($0.filename ?? $0.url ?? "attachment"); kind=\($0.kind.rawValue); OCR=\($0.ocrText)" }.joined(separator: "\n")
            ]
            var images: [Data] = []
            for source in batch.sources where source.kind == .image && source.status == .ready {
                guard let path = source.localPath else { continue }
                images.append(try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: path), annotations: []))
                if images.count == 2 { break }
            }
            let request = try AnalysisAdapter.request(configuration: configuration, credential: credential,
                prompt: lines.joined(separator: "\n"), images: images, schema: schema,
                name: "video_context_feedback_preparation", maxTokens: configuration.analysisProvider == .openAI ? 32_768 : 8_192)
            let response = try await UsageTrace.$stage.withValue(.taskExtraction) { try await client.data(for: request) }
            let output = try AnalysisAdapter.output(response, provider: configuration.analysisProvider)
            let decoded = try JSONDecoder().decode(FeedbackPreparationOutput.self, from: Data(output.utf8))
            guard decoded.suggestions.count == chunk.count,
                  Set(decoded.suggestions.map(\.issueID)) == issueIDs,
                  decoded.suggestions.allSatisfy({ suggestion in
                      Set(suggestion.sourceIDs).isSubset(of: sourceIDs) &&
                      (suggestion.duplicateOfIssueID.isEmpty || issues.contains(where: { $0.id == suggestion.duplicateOfIssueID }))
                  }) else {
                throw TaskContextError.invalid("Preparation returned incomplete or invalid issue suggestions.")
            }
            results += decoded.suggestions
        }
        return results
    }
}
