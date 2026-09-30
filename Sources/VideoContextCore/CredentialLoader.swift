import Foundation

public enum APIKeyAccessMode: Equatable, Sendable {
    case nonInteractive
    case interactive
}

public protocol APIKeyStoring: Sendable {
    func load(mode: APIKeyAccessMode) async throws -> String?
    func save(_ key: String) async throws
    func remove() async throws
}

public enum CredentialState: Equatable, Sendable {
    case loading
    case ready
    case missing
    case accessRequired
    case failed(String)
}

public enum CredentialLoadResult: Equatable, Sendable {
    case ready(String)
    case missing
    case accessRequired
    case failed(String)
    case superseded
}

public enum CredentialSaveAction: Equatable, Sendable {
    case none
    case save(String)
    case remove

    public static func resolve(value: String, wasEdited: Bool) -> Self {
        guard wasEdited else { return .none }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? .remove : .save(key)
    }
}

public actor CredentialLoader {
    private let store: any APIKeyStoring
    private var generation = 0

    public init(store: any APIKeyStoring) {
        self.store = store
    }

    public func load(mode: APIKeyAccessMode) async -> CredentialLoadResult {
        generation += 1
        let requestGeneration = generation
        do {
            let key = try await SavedCredentialLookup.load(from: store, mode: mode)
            guard requestGeneration == generation else { return .superseded }
            guard let key, key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return .missing
            }
            return .ready(key)
        } catch KeychainError.interactionNotAllowed {
            await DiagnosticTrace.record(.failed, error: KeychainError.interactionNotAllowed)
            guard requestGeneration == generation else { return .superseded }
            return .accessRequired
        } catch {
            await DiagnosticTrace.record(.failed, error: error)
            guard requestGeneration == generation else { return .superseded }
            return .failed(error.localizedDescription)
        }
    }

    public func invalidatePendingLoad() {
        generation += 1
    }
}

/// A missing result immediately after launch/unlock can be temporary. Retry once,
/// without prompting; permission failures still require the explicit unlock action.
public enum SavedCredentialLookup {
    public static func load(from store: any APIKeyStoring, mode: APIKeyAccessMode) async throws -> String? {
        let first = try await store.load(mode: mode)
        guard first == nil, mode == .nonInteractive else { return first }
        try await Task.sleep(for: .milliseconds(350))
        return try await store.load(mode: mode)
    }
}
