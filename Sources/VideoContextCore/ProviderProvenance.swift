import Foundation

public enum InferenceProvider: String, Codable, Sendable {
    case openAI, lmStudio, localWhisper, claude, deepSeek
    public var isLocal: Bool { self == .lmStudio || self == .localWhisper }
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .lmStudio: "LM Studio (local)"
        case .localWhisper: "Whisper (local)"
        }
    }
}

public struct ProviderIdentity: Codable, Equatable, Sendable {
    public let provider: InferenceProvider
    public let model: String
    public let effort: ReasoningEffort?
    public init(provider: InferenceProvider, model: String, effort: ReasoningEffort? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }
    private enum CodingKeys: String, CodingKey { case provider, model, effort }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(InferenceProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
    }
}

public struct ArtifactProvenance: Codable, Equatable, Sendable {
    public let stage: APIUsageStage
    public let revision: Int
    public let identity: ProviderIdentity
}
