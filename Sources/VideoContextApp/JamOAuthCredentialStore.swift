import Foundation
import MCP
import Synchronization

final class JamOAuthCredentialStore: TokenStorage, Sendable, CustomStringConvertible {
    static let tokenAccount = "jam-oauth-token"
    static let registrationAccount = "jam-oauth-client-registration"

    private struct State: Sendable {
        var token: OAuthAccessToken?
        var clientID: String?
        var persistenceError: JamConnectionError?
    }

    private let secrets: any JamSecretStoring
    private let state: Mutex<State>

    init(secrets: any JamSecretStoring = KeychainJamSecretStore()) {
        self.secrets = secrets
        var token: OAuthAccessToken?
        var clientID: String?
        var persistenceError: JamConnectionError?
        do {
            if let data = try secrets.read(account: Self.tokenAccount) {
                token = try JSONDecoder().decode(OAuthAccessToken.self, from: data)
            }
            if let data = try secrets.read(account: Self.registrationAccount) {
                clientID = String(data: data, encoding: .utf8)
            }
        } catch {
            persistenceError = .credentialPersistenceFailed
        }
        state = Mutex(.init(token: token, clientID: clientID, persistenceError: persistenceError))
    }

    var persistenceError: JamConnectionError? { state.withLock { $0.persistenceError } }
    var clientID: String? { state.withLock { $0.clientID } }
    var description: String {
        state.withLock { "Jam OAuth credentials (token: \($0.token == nil ? "missing" : "stored"), registration: \($0.clientID == nil ? "missing" : "stored"))" }
    }

    func save(_ token: OAuthAccessToken) {
        state.withLock { value in
            value.token = token
            if let clientID = token.clientID, !clientID.isEmpty { value.clientID = clientID }
            do {
                try secrets.write(try JSONEncoder().encode(token), account: Self.tokenAccount)
                if let clientID = value.clientID {
                    try secrets.write(Data(clientID.utf8), account: Self.registrationAccount)
                }
                value.persistenceError = nil
            } catch {
                value.persistenceError = .credentialPersistenceFailed
            }
        }
    }

    func load() -> OAuthAccessToken? { state.withLock { $0.token } }

    func usableToken(now: Date = .now) -> OAuthAccessToken? {
        state.withLock { token in
            guard let value = token.token, !value.isExpired(now: now) else { return nil }
            return value
        }
    }

    func clear() {
        state.withLock { value in
            value.token = nil
            do {
                try secrets.delete(account: Self.tokenAccount)
                value.persistenceError = nil
            } catch {
                value.persistenceError = .credentialPersistenceFailed
            }
        }
    }

    func removeAll() {
        state.withLock { value in
            value.token = nil
            value.clientID = nil
            var failed = false
            do { try secrets.delete(account: Self.tokenAccount) } catch { failed = true }
            do { try secrets.delete(account: Self.registrationAccount) } catch { failed = true }
            value.persistenceError = failed ? .credentialPersistenceFailed : nil
        }
    }
}
