import Foundation

public enum TranscriptionProvider: String, Codable, Sendable, CaseIterable {
    case openAI, localWhisper
}

public enum AnalysisProvider: String, Codable, Sendable, CaseIterable {
    case openAI, lmStudio, claude, deepSeek
    public var identity: InferenceProvider {
        switch self { case .openAI: .openAI; case .lmStudio: .lmStudio; case .claude: .claude; case .deepSeek: .deepSeek }
    }
    public var label: String { identity.displayName }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high, xhigh, max
}

public struct AnalysisSelection: Codable, Equatable, Sendable {
    public var provider: AnalysisProvider
    public var modelID: String
    public var effort: ReasoningEffort
    public init(provider: AnalysisProvider, modelID: String, effort: ReasoningEffort = .medium) {
        self.provider = provider; self.modelID = modelID; self.effort = effort
    }
    private enum CodingKeys: String, CodingKey { case provider, modelID, effort }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(AnalysisProvider.self, forKey: .provider)
        modelID = try c.decode(String.self, forKey: .modelID)
        effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort) ?? .medium
    }
}

public struct LMStudioConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var modelID: String
    public init(baseURL: String = "http://127.0.0.1:1234", modelID: String = "") {
        self.baseURL = baseURL
        self.modelID = modelID
    }

    public func validatedURL() throws -> URL {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(parts.path), let url = parts.url else {
            throw LocalProviderError.configuration("Use a loopback LM Studio address, such as http://127.0.0.1:1234.")
        }
        var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        origin.path = ""
        return origin.url!
    }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var transcriptionModel: String
    public var analysisModel: String
    public var transcriptionProvider: TranscriptionProvider
    public var analysisProvider: AnalysisProvider
    public var lmStudio: LMStudioConfiguration
    public var claudeModel = ""
    public var deepSeekModel = ""
    public var taskAnalysisOverride: AnalysisSelection?
    public var feedbackPreparationOverride: AnalysisSelection?
    public var documentationAnalysisOverride: AnalysisSelection?
    public var reviewAnalysisOverride: AnalysisSelection?
    public var reasoningEffort: ReasoningEffort?
    public static let localSpeechModel = "openai_whisper-large-v3-v20240930_626MB"

    public init(transcriptionModel: String = "whisper-1", analysisModel: String = "gpt-5.6-terra",
                transcriptionProvider: TranscriptionProvider = .openAI, analysisProvider: AnalysisProvider = .openAI,
                lmStudio: LMStudioConfiguration = .init(), claudeModel: String = "", deepSeekModel: String = "",
                taskAnalysisOverride: AnalysisSelection? = nil, feedbackPreparationOverride: AnalysisSelection? = nil,
                documentationAnalysisOverride: AnalysisSelection? = nil, reviewAnalysisOverride: AnalysisSelection? = nil,
                reasoningEffort: ReasoningEffort? = nil) {
        self.transcriptionModel = transcriptionModel
        self.analysisModel = analysisModel
        self.transcriptionProvider = transcriptionProvider
        self.analysisProvider = analysisProvider
        self.lmStudio = lmStudio
        self.claudeModel = claudeModel; self.deepSeekModel = deepSeekModel; self.taskAnalysisOverride = taskAnalysisOverride
        self.feedbackPreparationOverride = feedbackPreparationOverride
        self.documentationAnalysisOverride = documentationAnalysisOverride
        self.reviewAnalysisOverride = reviewAnalysisOverride
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey { case transcriptionModel, analysisModel, transcriptionProvider, analysisProvider, lmStudio, claudeModel, deepSeekModel, taskAnalysisOverride, feedbackPreparationOverride, documentationAnalysisOverride, reviewAnalysisOverride, reasoningEffort }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? "whisper-1"
        analysisModel = try c.decodeIfPresent(String.self, forKey: .analysisModel) ?? "gpt-5.6-terra"
        transcriptionProvider = try c.decodeIfPresent(TranscriptionProvider.self, forKey: .transcriptionProvider) ?? .openAI
        analysisProvider = try c.decodeIfPresent(AnalysisProvider.self, forKey: .analysisProvider) ?? .openAI
        lmStudio = try c.decodeIfPresent(LMStudioConfiguration.self, forKey: .lmStudio) ?? .init()
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? ""
        deepSeekModel = try c.decodeIfPresent(String.self, forKey: .deepSeekModel) ?? ""
        taskAnalysisOverride = try c.decodeIfPresent(AnalysisSelection.self, forKey: .taskAnalysisOverride)
        feedbackPreparationOverride = try c.decodeIfPresent(AnalysisSelection.self, forKey: .feedbackPreparationOverride)
        documentationAnalysisOverride = try c.decodeIfPresent(AnalysisSelection.self, forKey: .documentationAnalysisOverride)
        reviewAnalysisOverride = try c.decodeIfPresent(AnalysisSelection.self, forKey: .reviewAnalysisOverride)
        reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
    }

    public var selectedAnalysisModel: String {
        switch analysisProvider { case .openAI: analysisModel; case .lmStudio: lmStudio.modelID; case .claude: claudeModel; case .deepSeek: deepSeekModel }
    }
    public var analysisIdentity: ProviderIdentity { .init(provider: analysisProvider.identity, model: selectedAnalysisModel, effort: reasoningEffort) }
    public var taskConfiguration: ModelConfiguration {
        var copy = self
        if let selection = taskAnalysisOverride {
            copy.analysisProvider = selection.provider
            copy.reasoningEffort = [.openAI, .claude].contains(selection.provider) ? selection.effort : nil
            switch selection.provider {
            case .openAI: copy.analysisModel = selection.modelID
            case .lmStudio: copy.lmStudio.modelID = selection.modelID
            case .claude: copy.claudeModel = selection.modelID
            case .deepSeek: copy.deepSeekModel = selection.modelID
            }
        }
        copy.taskAnalysisOverride = nil
        return copy
    }
    public var feedbackPreparationConfiguration: ModelConfiguration {
        var copy = self
        if let selection = feedbackPreparationOverride {
            copy.analysisProvider = selection.provider
            copy.reasoningEffort = [.openAI, .claude].contains(selection.provider) ? selection.effort : nil
            switch selection.provider {
            case .openAI: copy.analysisModel = selection.modelID
            case .lmStudio: copy.lmStudio.modelID = selection.modelID
            case .claude: copy.claudeModel = selection.modelID
            case .deepSeek: copy.deepSeekModel = selection.modelID
            }
        }
        copy.feedbackPreparationOverride = nil
        return copy
    }
    /// Uses the base analysis settings unless documentation has an explicit selection.
    public var documentationConfiguration: ModelConfiguration {
        configuration(applying: documentationAnalysisOverride)
    }

    /// Returns nil when independent review is disabled.
    public var reviewConfiguration: ModelConfiguration? {
        guard reviewAnalysisOverride != nil else { return nil }
        return configuration(applying: reviewAnalysisOverride)
    }

    public var accuracyProfileEnabled: Bool {
        documentationAnalysisOverride != nil && reviewAnalysisOverride != nil
    }

    /// Opt-in routing profile for evidence-grounded analysis.
    public mutating func applyAccuracyProfile() {
        analysisProvider = .openAI
        analysisModel = "gpt-6-sol"
        reasoningEffort = .high
        taskAnalysisOverride = .init(provider: .openAI, modelID: "gpt-6-astra", effort: .high)
        documentationAnalysisOverride = .init(provider: .openAI, modelID: "gpt-6-astra", effort: .high)
        reviewAnalysisOverride = .init(provider: .claude, modelID: "claude-opus-5-5", effort: .high)
    }

    private func configuration(applying selection: AnalysisSelection?) -> ModelConfiguration {
        var copy = self
        guard let selection else { return copy }
        copy.analysisProvider = selection.provider
        copy.reasoningEffort = [.openAI, .claude].contains(selection.provider) ? selection.effort : nil
        switch selection.provider {
        case .openAI: copy.analysisModel = selection.modelID
        case .lmStudio: copy.lmStudio.modelID = selection.modelID
        case .claude: copy.claudeModel = selection.modelID
        case .deepSeek: copy.deepSeekModel = selection.modelID
        }
        copy.taskAnalysisOverride = nil
        copy.feedbackPreparationOverride = nil
        copy.documentationAnalysisOverride = nil
        copy.reviewAnalysisOverride = nil
        return copy
    }
    public var analysisDescription: String {
        "\(analysisProvider.label) · \(selectedAnalysisModel.isEmpty ? "Choose a model" : selectedAnalysisModel) · " + (analysisProvider == .lmStudio ? "local" : "sends transcript and selected screenshots to \(analysisProvider.label)")
    }

    public func requiresOpenAI(transcriptNeeded: Bool) -> Bool {
        analysisProvider == .openAI || (transcriptNeeded && transcriptionProvider == .openAI)
    }

    public var processingDescription: String {
        switch (transcriptionProvider, analysisProvider) {
        case (.localWhisper, .lmStudio): "Local · Speech, screenshots, and briefs stay on this Mac."
        case (.openAI, .openAI): "OpenAI · Audio and selected screenshots are sent to OpenAI."
        case (.openAI, .lmStudio): "Mixed · Audio goes to OpenAI; screenshot analysis and briefs run locally."
        case (.localWhisper, .openAI): "Mixed · Speech runs locally; transcript and selected screenshots go to OpenAI."
        default: "\(transcriptionProvider == .localWhisper ? "Speech runs locally" : "Audio goes to OpenAI"); transcript and selected screenshots go to \(analysisProvider.label)."
        }
    }
}

public enum LocalProviderError: Error, LocalizedError, Equatable {
    case configuration(String), unavailable(String), invalidOutput, truncated, contextLength
    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .unavailable(let message): message
        case .invalidOutput: "The analysis provider returned invalid or empty structured output. Test the selected vision model in Settings."
        case .truncated: "The analysis provider stopped before completing its response. Reduce the batch size or increase the model context window."
        case .contextLength: "The evidence exceeds the model context window. Use a larger context window or smaller batches and retry."
        }
    }
}
