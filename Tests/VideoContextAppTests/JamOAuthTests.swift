import Foundation
import MCP
import Synchronization
import Testing
@testable import VideoContextApp

struct JamOAuthTests {
    @Test func typedArgumentsSurviveTheSerializedMCPRequest() throws {
        let arguments = JamMCPValueCodec.toMCP([
            "overview": .bool(true), "count": .int(3),
            "times": .array([.int(1), .double(2.5)]), "logLevel": .string("error")
        ])
        let request = CallTool.Parameters(name: "getFrames", arguments: arguments)
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require(json["arguments"] as? [String: Any])
        #expect(encoded["overview"] as? Bool == true)
        #expect(encoded["count"] as? Int == 3)
        #expect((encoded["times"] as? [Double]) == [1, 2.5])
        #expect(encoded["logLevel"] as? String == "error")
        #expect(JamMCPValueCodec.fromMCP(.object(arguments)) == .object([
            "overview": .bool(true), "count": .int(3),
            "times": .array([.int(1), .double(2.5)]), "logLevel": .string("error")
        ]))
    }
    @Test func fixedEndpointAndReadOnlyScopeCannotBeUpgradedByTheServer() throws {
        #expect(JamOAuthPolicy.endpoint == URL(string: "https://mcp.jam.dev/mcp")!)
        #expect(JamOAuthPolicy.authorizationServer == URL(string: "https://api.jam.dev")!)
        #expect(JamOAuthPolicy.scope == "mcp:read")

        let selector = JamReadOnlyScopeSelector()
        #expect(selector.selectScopes(
            challengeScope: "mcp:write",
            scopesSupported: ["mcp:read", "mcp:write"]
        ) == Set(["mcp:read"]))
        #expect(selector.serialize(Set(["mcp:write", "mcp:read"])) == "mcp:read")
    }

    @Test func configurationUsesAuthorizationCodeAndPublicClientRegistration() throws {
        let redirect = URL(string: "http://127.0.0.1:54321/callback")!
        let configuration = JamOAuthPolicy.configuration(
            redirectURI: redirect,
            clientID: nil,
            delegate: JamAuthorizationDelegate(
                browser: RecordingBrowser(),
                callback: StubCallback(redirectURI: redirect, result: .failure(CancellationError()))
            )
        )

        switch configuration.grantType {
        case .authorizationCode: break
        case .clientCredentials: Issue.record("Jam must use the authorization-code flow.")
        }
        switch configuration.authentication {
        case .none(let clientID): #expect(clientID.isEmpty)
        default: Issue.record("Jam must dynamically register as a public client.")
        }
        #expect(configuration.authorizationRedirectURI == redirect)
        #expect(configuration.clientName == "Video Context")
    }

    @Test func sdkPKCEAndCallbackStateValidationRejectTampering() throws {
        let verifier = PKCE.makeVerifier()
        let challenge = try PKCE.makeChallenge(from: verifier)
        #expect(verifier != challenge)
        #expect(challenge.contains("=") == false)

        let expected = URL(string: "http://127.0.0.1:54321/callback")!
        let redirect = URL(string: "http://127.0.0.1:54321/callback?code=code-1&state=wrong")!
        #expect(throws: OAuthAuthorizationError.self) {
            try OAuthAuthorizationCodeFlow().extractCode(
                from: redirect,
                expectedRedirectURI: expected,
                expectedState: "expected"
            )
        }
    }

    @Test func browserCancellationStopsAuthorization() async throws {
        let redirect = URL(string: "http://127.0.0.1:54321/callback")!
        let browser = RecordingBrowser()
        let delegate = JamAuthorizationDelegate(
            browser: browser,
            callback: StubCallback(redirectURI: redirect, result: .failure(CancellationError()))
        )
        let authorizationURL = URL(string: "https://api.jam.dev/oauth/authorize?scope=mcp%3Aread")!

        await #expect(throws: CancellationError.self) {
            try await delegate.presentAuthorizationURL(authorizationURL)
        }
        #expect(await browser.opened == [authorizationURL])
    }

    @Test(.timeLimit(.minutes(1))) func temporaryLoopbackCallbackReturnsOnlyTheRedirectURL() async throws {
        let callback = try await JamLoopbackCallbackServer.start()
        let receive = Task { try await callback.receiveRedirect() }
        var components = try #require(URLComponents(url: callback.redirectURI, resolvingAgainstBaseURL: false))
        components.queryItems = [
            .init(name: "code", value: "private+code/="),
            .init(name: "state", value: "expected-state")
        ]
        let requestURL = try #require(components.url)

        let (body, response) = try await URLSession.shared.data(from: requestURL)
        let redirect = try await receive.value

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(redirect == requestURL)
        #expect(String(decoding: body, as: UTF8.self).contains("private+code/=") == false)
        #expect(String(decoding: body, as: UTF8.self).contains("expected-state") == false)
    }

    @Test func tokensAndClientRegistrationPersistWithoutLeakingIntoDescriptions() throws {
        let secrets = MemoryJamSecrets()
        let storage = JamOAuthCredentialStore(secrets: secrets)
        let token = OAuthAccessToken(
            value: "access-secret",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            scopes: ["mcp:read"],
            authorizationServer: JamOAuthPolicy.authorizationServer,
            refreshToken: "refresh-secret",
            clientID: "registered-client"
        )

        storage.save(token)

        #expect(storage.persistenceError == nil)
        #expect(storage.load()?.value == "access-secret")
        #expect(storage.clientID == "registered-client")
        #expect(secrets.accounts == Set([JamOAuthCredentialStore.tokenAccount, JamOAuthCredentialStore.registrationAccount]))
        #expect(String(describing: storage).contains("access-secret") == false)
        #expect(String(describing: storage).contains("refresh-secret") == false)
    }

    @Test func expiredTokenIsUnavailableButKeepsRegistrationForRefresh() throws {
        let storage = JamOAuthCredentialStore(secrets: MemoryJamSecrets())
        storage.save(.init(
            value: "expired",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 100),
            scopes: ["mcp:read"],
            authorizationServer: JamOAuthPolicy.authorizationServer,
            refreshToken: "refresh",
            clientID: "registered-client"
        ))

        #expect(storage.usableToken(now: Date(timeIntervalSince1970: 1_000)) == nil)
        #expect(storage.clientID == "registered-client")
    }

    @Test func keychainFailurePreventsAConnectedResult() async throws {
        let secrets = MemoryJamSecrets(writeError: SecretFailure.denied)
        let storage = JamOAuthCredentialStore(secrets: secrets)
        let remote = StubJamRemote(storage: storage, result: .success(["getDetails"]))
        let service = JamConnectionService(storage: storage, remote: remote, revoker: RecordingRevoker())

        await #expect(throws: JamConnectionError.credentialPersistenceFailed) {
            try await service.connect(interactive: true)
        }
        #expect(await service.status == .disconnected)
        #expect(storage.load() == nil)
        #expect(storage.clientID == nil)
    }

    @Test func refreshFailureRequiresReconnectAndRedactsProviderSecrets() async throws {
        let storage = JamOAuthCredentialStore(secrets: MemoryJamSecrets())
        storage.save(.init(
            value: "access-secret",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 100),
            scopes: ["mcp:read"],
            authorizationServer: JamOAuthPolicy.authorizationServer,
            refreshToken: "refresh-secret",
            clientID: "registered-client"
        ))
        let remote = StubJamRemote(
            storage: storage,
            result: .failure(JamConnectionError.authorizationRequired)
        )
        let service = JamConnectionService(storage: storage, remote: remote, revoker: RecordingRevoker())

        await #expect(throws: JamConnectionError.authorizationRequired) {
            try await service.connect(interactive: false)
        }
        #expect(await service.status == .reconnectRequired)
        #expect(await service.status.message.contains("access-secret") == false)
        #expect(await service.status.message.contains("refresh-secret") == false)
    }

    @Test func broaderThanReadOnlyGrantIsRejectedAndRemoved() async throws {
        let storage = JamOAuthCredentialStore(secrets: MemoryJamSecrets())
        let remote = StubJamRemote(
            storage: storage,
            result: .success(["getDetails"]),
            grantedScopes: ["mcp:read", "mcp:write"]
        )
        let service = JamConnectionService(storage: storage, remote: remote, revoker: RecordingRevoker())

        await #expect(throws: JamConnectionError.unsafeScope) {
            try await service.connect(interactive: true)
        }
        #expect(await service.status == .disconnected)
        #expect(storage.load() == nil)
        #expect(storage.clientID == nil)
    }

    @Test func disconnectRevokesAndRemovesCredentialsButNotImportedEvidence() async throws {
        let storage = JamOAuthCredentialStore(secrets: MemoryJamSecrets())
        let token = OAuthAccessToken(
            value: "access-secret",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            scopes: ["mcp:read"],
            authorizationServer: JamOAuthPolicy.authorizationServer,
            refreshToken: "refresh-secret",
            clientID: "registered-client"
        )
        storage.save(token)
        let remote = StubJamRemote(storage: storage, result: .success(["getDetails"]))
        let revoker = RecordingRevoker()
        let service = JamConnectionService(storage: storage, remote: remote, revoker: revoker)
        _ = try await service.connect(interactive: false)

        try await service.disconnect()

        #expect(await service.status == .disconnected)
        #expect(storage.load() == nil)
        #expect(storage.clientID == nil)
        #expect(await revoker.revoked == ["refresh-secret"])
        #expect(await remote.disconnectCount == 1)
    }
}

private actor RecordingBrowser: JamBrowserOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) async throws { opened.append(url) }
}

private struct StubCallback: JamAuthorizationCallbackReceiving {
    let redirectURI: URL
    let result: Result<URL, any Error>
    func receiveRedirect() async throws -> URL { try result.get() }
    func cancel() async {}
}

private enum SecretFailure: Error { case denied }

private final class MemoryJamSecrets: JamSecretStoring, Sendable {
    private struct State: Sendable {
        var values: [String: Data] = [:]
    }
    private let state = Mutex(State())
    private let writeError: (any Error & Sendable)?
    init(writeError: (any Error & Sendable)? = nil) { self.writeError = writeError }
    var accounts: Set<String> { state.withLock { Set($0.values.keys) } }
    func read(account: String) throws -> Data? { state.withLock { $0.values[account] } }
    func write(_ data: Data, account: String) throws {
        if let writeError { throw writeError }
        state.withLock { $0.values[account] = data }
    }
    func delete(account: String) throws { state.withLock { _ = $0.values.removeValue(forKey: account) } }
}

private actor StubJamRemote: JamRemoteConnecting {
    let storage: JamOAuthCredentialStore
    let result: Result<Set<String>, any Error & Sendable>
    let grantedScopes: Set<String>
    private(set) var disconnectCount = 0
    init(
        storage: JamOAuthCredentialStore,
        result: Result<Set<String>, any Error & Sendable>,
        grantedScopes: Set<String> = ["mcp:read"]
    ) {
        self.storage = storage
        self.result = result
        self.grantedScopes = grantedScopes
    }
    func connect(interactive: Bool) async throws -> Set<String> {
        if storage.load() == nil {
            storage.save(.init(
                value: "new-access",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                scopes: grantedScopes,
                authorizationServer: JamOAuthPolicy.authorizationServer,
                refreshToken: "new-refresh",
                clientID: "new-client"
            ))
        }
        return try result.get()
    }
    func disconnect() async { disconnectCount += 1 }
}

private actor RecordingRevoker: JamTokenRevoking {
    private(set) var revoked: [String] = []
    func revoke(_ token: String) async throws { revoked.append(token) }
}
