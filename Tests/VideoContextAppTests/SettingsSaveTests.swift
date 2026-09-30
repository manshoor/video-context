import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct SettingsSaveTests {
    @Test func localSettingsSaveConfirmsAndPersistsWithoutKeychainAccess() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsSaveTests-\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removeObject(forKey: "VideoContext.preferences"); try? FileManager.default.removeItem(at: root) }
        let credentials = SettingsCredentials()
        let model = AppModel(keyStore: credentials, localTokenStore: credentials, libraryRoot: root,
                             preferencesDefaults: defaults, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .lmStudio
        model.lmStudioModelID = "saved-vision-model"
        #expect(await model.saveSettings())
        #expect(model.settingsSaved)
        #expect(!model.isSavingSettings)
        #expect(model.settingsSaveError == nil)
        #expect(await credentials.calls == 0)
        let reopened = AppModel(libraryRoot: root, preferencesDefaults: defaults, showsDockActivity: false)
        #expect(reopened.analysisProvider == .lmStudio)
        #expect(reopened.lmStudioModelID == "saved-vision-model")
    }

    @Test(arguments: [false, true]) func credentialFailureKeepsSettingsOpenAndAllowsRetry(localToken: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsSaveTests-\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removeObject(forKey: "VideoContext.preferences"); try? FileManager.default.removeItem(at: root) }
        let credentials = SettingsCredentials(fails: true)
        let model = AppModel(keyStore: credentials, localTokenStore: credentials, libraryRoot: root,
                             preferencesDefaults: defaults, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .lmStudio
        if localToken { model.editLocalToken("test-token") }
        else { model.userEditedAPIKey("test-key") }
        #expect(await model.saveSettings() == false)
        #expect(!model.settingsSaved)
        #expect(!model.isSavingSettings)
        #expect(model.settingsSaveError != nil)
        #expect(defaults.data(forKey: "VideoContext.preferences") == nil)
        // A corrected Keychain failure should clear the error and permit closing.
        await credentials.allowSave()
        #expect(await model.saveSettings())
        #expect(model.settingsSaved)
        #expect(model.settingsSaveError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func slowSaveShowsProgressAndRejectsDuplicateSave() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsSaveTests-\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removeObject(forKey: "VideoContext.preferences"); try? FileManager.default.removeItem(at: root) }
        let credentials = SettingsSaveGate()
        let model = AppModel(localTokenStore: credentials, libraryRoot: root,
                             preferencesDefaults: defaults, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .lmStudio
        model.editLocalToken("test-token")
        let save = Task { await model.saveSettings() }
        await credentials.waitForSave()
        #expect(model.isSavingSettings)
        #expect(!model.settingsSaved)
        #expect(await model.saveSettings() == false)
        #expect(await credentials.calls == 1)
        await credentials.release()
        #expect(await save.value)
        #expect(!model.isSavingSettings)
        #expect(model.settingsSaved)
    }
}

private actor SettingsCredentials: APIKeyStoring {
    var fails: Bool
    private(set) var calls = 0
    init(fails: Bool = false) { self.fails = fails }
    func allowSave() { fails = false }
    func load(mode: APIKeyAccessMode) async throws -> String? { calls += 1; return nil }
    func save(_ key: String) async throws {
        calls += 1
        if fails { throw CocoaError(.fileWriteNoPermission) }
    }
    func remove() async throws { try await save("") }
}

private actor SettingsSaveGate: APIKeyStoring {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func load(mode: APIKeyAccessMode) async throws -> String? { nil }
    func save(_ key: String) async throws {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func remove() async throws { try await save("") }
    func waitForSave() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
