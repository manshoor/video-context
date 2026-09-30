import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct CredentialRecoveryTests {
    @Test(.timeLimit(.minutes(1))) func returningToAppAfterUnlockLoadsSavedKeyWithoutSettings() async throws {
        let store = RecoverableCredentialStore()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(keyStore: store, libraryRoot: root, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .openAI
        await model.loadLibrary(resume: true)
        while model.credentialState == .loading { await Task.yield() }
        #expect(model.credentialState == .accessRequired)
        await store.unlock()
        model.appBecameActive()
        while model.credentialState == .loading { await Task.yield() }
        #expect(model.credentialState == .ready && model.apiKey == "saved-fixture")
        let count = await store.modes.count
        model.appBecameActive()
        await Task.yield()
        #expect(await store.modes.count == count)
        #expect(await store.modes.allSatisfy { $0 == .nonInteractive })
        model.userEditedAPIKey("user-edit")
        model.reloadSavedAPIKey()
        #expect(model.apiKey == "user-edit")
        #expect(!model.canReloadSavedAPIKey)
    }

    @Test func cloudCredentialCanRetryAfterMacUnlockWithoutOverwritingEdits() async throws {
        let store = RecoverableCredentialStore()
        let credential = ProviderCredential(store: store)
        await credential.load(mode: .nonInteractive)
        #expect(credential.state == .accessRequired)
        await store.unlock()
        await credential.load(mode: .nonInteractive, retryAccessRequired: true)
        #expect(credential.ready && credential.value == "saved-fixture")
        credential.edit("new-value")
        await credential.load(mode: .nonInteractive, retryAccessRequired: true)
        #expect(credential.value == "new-value")
        #expect(await store.modes.count == 2)
    }
}

private actor RecoverableCredentialStore: APIKeyStoring {
    private var locked = true
    private(set) var modes: [APIKeyAccessMode] = []
    func unlock() { locked = false }
    func load(mode: APIKeyAccessMode) async throws -> String? {
        modes.append(mode)
        if locked { throw KeychainError.interactionNotAllowed }
        return "saved-fixture"
    }
    func save(_ key: String) async throws {}
    func remove() async throws {}
}
