import Foundation

public enum TranscriptionProvider: String, Codable, Sendable, CaseIterable {
    case openAI, localWhisper
}

public enum AnalysisProvider: String, Codable, Sendable, CaseIterable {
    case openAI, lmStudio
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
    public static let localSpeechModel = "openai_whisper-large-v3-v20240930_626MB"

    public init(transcriptionModel: String = "whisper-1", analysisModel: String = "gpt-5.6-terra",
                transcriptionProvider: TranscriptionProvider = .openAI, analysisProvider: AnalysisProvider = .openAI,
                lmStudio: LMStudioConfiguration = .init()) {
        self.transcriptionModel = transcriptionModel
        self.analysisModel = analysisModel
        self.transcriptionProvider = transcriptionProvider
        self.analysisProvider = analysisProvider
        self.lmStudio = lmStudio
    }

    private enum CodingKeys: String, CodingKey { case transcriptionModel, analysisModel, transcriptionProvider, analysisProvider, lmStudio }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? "whisper-1"
        analysisModel = try c.decodeIfPresent(String.self, forKey: .analysisModel) ?? "gpt-5.6-terra"
        transcriptionProvider = try c.decodeIfPresent(TranscriptionProvider.self, forKey: .transcriptionProvider) ?? .openAI
        analysisProvider = try c.decodeIfPresent(AnalysisProvider.self, forKey: .analysisProvider) ?? .openAI
        lmStudio = try c.decodeIfPresent(LMStudioConfiguration.self, forKey: .lmStudio) ?? .init()
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
        }
    }
}

public enum LocalProviderError: Error, LocalizedError, Equatable {
    case configuration(String), unavailable(String), invalidOutput, truncated, contextLength
    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .unavailable(let message): message
        case .invalidOutput: "LM Studio returned invalid or empty structured output. Test the selected vision model in Settings."
        case .truncated: "LM Studio stopped before completing its response. Reduce the batch size or increase the loaded context window."
        case .contextLength: "The evidence exceeds the loaded LM Studio context window. Load the model with a 32K context window and retry."
        }
    }
}
