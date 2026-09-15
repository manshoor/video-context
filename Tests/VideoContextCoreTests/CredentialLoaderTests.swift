import Foundation
import LocalAuthentication
import Security
import Testing
@testable import VideoContextCore

struct CredentialLoaderTests {
    @Test("A missing authentication-context entitlement falls back to the login Keychain query")
    func missingEntitlementFallsBackToLoginKeychainQuery() throws {
        let context = LAContext()
        var queries: [[String: Any]] = []

        let data = try KeychainAPIKeyStore.read(
            service: "test.video-context",
            account: "test-key",
            context: context,
            failAuthenticationUI: true
        ) { query, result in
            queries.append(query as NSDictionary as? [String: Any] ?? [:])
            if queries.count == 1 {
                return errSecMissingEntitlement
            }
            result?.pointee = Data("stored-key".utf8) as CFData
            return errSecSuccess
        }

        #expect(data == Data("stored-key".utf8))
        #expect(queries.count == 2)
        #expect(queries[0][kSecUseAuthenticationContext as String] != nil)
        #expect(queries[1][kSecUseAuthenticationContext as String] == nil)
        #expect(queries[1][kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
    }

    @Test("An untouched empty API key does not remove the stored credential")
    func untouchedEmptyKeyDoesNothing() {
        #expect(CredentialSaveAction.resolve(value: "", wasEdited: false) == .none)
        #expect(CredentialSaveAction.resolve(value: "", wasEdited: true) == .remove)
        #expect(CredentialSaveAction.resolve(value: "  secret-key  ", wasEdited: true) == .save("secret-key"))
    }

    @Test("Noninteractive credential access reports that user interaction is required")
    func deniedNoninteractiveLoadRequiresAccess() async {
        let loader = CredentialLoader(store: StubAPIKeyStore(loadResult: .failure(KeychainError.interactionNotAllowed)))

        let result = await loader.load(mode: .nonInteractive)

        #expect(result == .accessRequired)
    }

    @Test("A missing credential is reported without an error")
    func missingCredentialIsReported() async {
        let loader = CredentialLoader(store: StubAPIKeyStore(loadResult: .success(nil)))

        let result = await loader.load(mode: .nonInteractive)

        #expect(result == .missing)
    }

    @Test("A delayed credential result cannot replace newer user input")
    func delayedLoadIsSuperseded() async {
        let store = DeferredAPIKeyStore()
        let loader = CredentialLoader(store: store)
        let loadTask = Task { await loader.load(mode: .nonInteractive) }
        await store.waitUntilLoadStarts()

        await loader.invalidatePendingLoad()
        await store.finish(with: "old-key")

        #expect(await loadTask.value == .superseded)
    }
}

private struct StubAPIKeyStore: APIKeyStoring {
    let loadResult: Result<String?, any Error>

    func load(mode: APIKeyAccessMode) async throws -> String? {
        try loadResult.get()
    }

    func save(_ key: String) async throws {}
    func remove() async throws {}
}

private actor DeferredAPIKeyStore: APIKeyStoring {
    private var didStart = false
    private var continuation: CheckedContinuation<String?, Never>?

    func load(mode: APIKeyAccessMode) async throws -> String? {
        didStart = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func save(_ key: String) async throws {}
    func remove() async throws {}

    func waitUntilLoadStarts() async {
        while didStart == false { await Task.yield() }
    }

    func finish(with key: String?) {
        continuation?.resume(returning: key)
        continuation = nil
    }
}
