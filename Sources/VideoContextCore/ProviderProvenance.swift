import Foundation

public enum InferenceProvider: String, Codable, Sendable {
    case openAI, lmStudio, localWhisper
    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .lmStudio: "LM Studio (local)"
        case .localWhisper: "Whisper (local)"
        }
    }
}

public struct ProviderIdentity: Codable, Equatable, Sendable {
    public let provider: InferenceProvider
    public let model: String
    public init(provider: InferenceProvider, model: String) { self.provider = provider; self.model = model }
}

public struct ArtifactProvenance: Codable, Equatable, Sendable {
    public let stage: APIUsageStage
    public let revision: Int
    public let identity: ProviderIdentity
}
