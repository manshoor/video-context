import Foundation
import VideoContextCore

enum JamConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnectRequired
    case failed

    var message: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting to Jam…"
        case .connected: "Connected with read-only access"
        case .reconnectRequired: "Jam authorization expired. Reconnect to continue importing evidence."
        case .failed: "Jam could not connect. Try again."
        }
    }
}

enum JamConnectionError: Error, LocalizedError, Equatable, Sendable {
    case authorizationRequired
    case credentialPersistenceFailed
    case unsafeScope
    case connectionFailed
    case revocationFailed

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: "Reconnect Jam to continue."
        case .credentialPersistenceFailed: "Jam credentials could not be saved in macOS Keychain."
        case .unsafeScope: "Jam did not grant the required read-only access."
        case .connectionFailed: "Jam could not connect. Try again."
        case .revocationFailed: "Jam disconnected locally, but remote token revocation could not be confirmed."
        }
    }
}

protocol JamConnectionControlling: Sendable {
    func connect(interactive: Bool) async throws -> Set<String>
    func disconnect() async throws
    func hasStoredCredentials() async -> Bool
}

protocol JamRemoteConnecting: Sendable {
    func connect(interactive: Bool) async throws -> Set<String>
    func disconnect() async
}

protocol JamTokenRevoking: Sendable {
    func revoke(_ token: String) async throws
}

actor JamConnectionService: JamConnectionControlling, JamToolCalling {
    private let storage: JamOAuthCredentialStore
    private let remote: any JamRemoteConnecting
    private let revoker: any JamTokenRevoking
    private(set) var status: JamConnectionStatus = .disconnected
    private(set) var availableTools: Set<String> = []

    init(storage: JamOAuthCredentialStore, remote: any JamRemoteConnecting, revoker: any JamTokenRevoking) {
        self.storage = storage
        self.remote = remote
        self.revoker = revoker
    }

    @discardableResult
    func connect(interactive: Bool) async throws -> Set<String> {
        status = .connecting
        do {
            let tools = try await remote.connect(interactive: interactive)
            guard storage.persistenceError == nil else {
                await remote.disconnect()
                storage.removeAll()
                status = .disconnected
                throw JamConnectionError.credentialPersistenceFailed
            }
            guard let token = storage.load(), token.scopes == Set([JamOAuthPolicy.scope]) else {
                await remote.disconnect()
                storage.removeAll()
                status = .disconnected
                throw JamConnectionError.unsafeScope
            }
            availableTools = tools
            status = .connected
            return tools
        } catch let error as JamConnectionError {
            availableTools = []
            status = error == .authorizationRequired ? .reconnectRequired : .disconnected
            throw error
        } catch is CancellationError {
            availableTools = []
            status = .disconnected
            throw CancellationError()
        } catch {
            availableTools = []
            status = .failed
            throw JamConnectionError.connectionFailed
        }
    }

    func disconnect() async throws {
        let token = storage.load()
        await remote.disconnect()
        availableTools = []
        status = .disconnected
        guard let value = token?.refreshToken ?? token?.value else {
            storage.removeAll()
            return
        }
        do {
            try await revoker.revoke(value)
        } catch {
            storage.removeAll()
            throw JamConnectionError.revocationFailed
        }
        storage.removeAll()
    }

    func hasStoredCredentials() -> Bool { storage.load() != nil }

    func listTools() async throws -> [JamToolDescriptor] {
        if status != .connected { _ = try await connect(interactive: false) }
        guard let tools = remote as? any JamToolCalling else { throw JamConnectionError.connectionFailed }
        return try await tools.listTools()
    }

    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        guard status == .connected else { throw JamConnectionError.authorizationRequired }
        guard JamReadToolPolicy.allowedTools.contains(name), let tools = remote as? any JamToolCalling else {
            throw JamConnectionError.connectionFailed
        }
        return try await tools.callTool(name: name, arguments: arguments)
    }
}
