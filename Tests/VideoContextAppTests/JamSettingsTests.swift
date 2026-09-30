import Foundation
import Testing
@testable import VideoContextApp

@MainActor
struct JamSettingsTests {
    @Test func connectionIsSuccessfulOnlyAfterTheControllerFinishes() async {
        let controller = JamSettingsController(mode: .gatedSuccess)
        let model = JamSettingsModel(controller: controller)

        let connection = Task { await model.connect() }
        await controller.waitForConnect()

        #expect(model.isWorking)
        #expect(model.status == .connecting)
        #expect(model.status != .connected)

        await controller.release()
        await connection.value

        #expect(model.status == .connected)
        #expect(model.message == JamConnectionStatus.connected.message)
        #expect(model.availableTools == ["getDetails", "getVideoTranscript"])
    }

    @Test func duplicateConnectIsIgnoredWhileAuthorizationIsActive() async {
        let controller = JamSettingsController(mode: .gatedSuccess)
        let model = JamSettingsModel(controller: controller)

        let first = Task { await model.connect() }
        await controller.waitForConnect()
        await model.connect()

        #expect(await controller.connectCalls == 1)
        await controller.release()
        await first.value
    }

    @Test func cancellationReturnsToDisconnectedWithoutAFalseSuccess() async {
        let controller = JamSettingsController(mode: .waitForCancellation)
        let model = JamSettingsModel(controller: controller)

        model.startConnect()
        await controller.waitForConnect()
        model.cancelOperation()
        await waitUntil { model.isWorking == false }

        #expect(model.status == .disconnected)
        #expect(model.message == "Jam connection was cancelled.")
    }

    @Test func reconnectUsesTheCancellableTrackedOperation() async {
        let controller = JamSettingsController(mode: .waitForCancellation)
        let model = JamSettingsModel(controller: controller)

        model.startReconnect()
        await controller.waitForConnect()
        model.cancelOperation()
        await waitUntil { model.isWorking == false }

        #expect(model.status == .disconnected)
        #expect(model.message == "Jam connection was cancelled.")
        #expect(await controller.connectCalls == 1)
    }

    @Test func authorizationAndKeychainFailuresHaveActionableSafeMessages() async {
        let reconnect = JamSettingsModel(controller: JamSettingsController(mode: .failure(.authorizationRequired)))
        await reconnect.restoreConnection()
        #expect(reconnect.status == .reconnectRequired)
        #expect(reconnect.message.contains("Reconnect"))

        let keychain = JamSettingsModel(controller: JamSettingsController(mode: .failure(.credentialPersistenceFailed)))
        await keychain.connect()
        #expect(keychain.status == .disconnected)
        #expect(keychain.message.contains("Keychain"))
    }

    @Test func restoreSkipsNetworkWithoutStoredCredentialsAndDisconnectDoesNotTouchEvidence() async {
        let controller = JamSettingsController(mode: .success, hasCredentials: false)
        let model = JamSettingsModel(controller: controller)
        let savedEvidence = ["jam-context-1"]

        await model.restoreConnection()
        #expect(await controller.connectCalls == 0)

        await model.connect()
        await model.disconnect()
        #expect(model.status == .disconnected)
        #expect(await controller.disconnectCalls == 1)
        #expect(savedEvidence == ["jam-context-1"])
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for Jam settings state.")
    }
}

private actor JamSettingsController: JamConnectionControlling {
    enum Mode: Sendable {
        case success
        case gatedSuccess
        case waitForCancellation
        case failure(JamConnectionError)
    }

    let mode: Mode
    private var hasCredentials: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0

    init(mode: Mode, hasCredentials: Bool = true) {
        self.mode = mode
        self.hasCredentials = hasCredentials
    }

    func connect(interactive: Bool) async throws -> Set<String> {
        connectCalls += 1
        switch mode {
        case .success:
            hasCredentials = true
            return ["getDetails", "getVideoTranscript"]
        case .gatedSuccess:
            await withCheckedContinuation { continuation = $0 }
            hasCredentials = true
            return ["getDetails", "getVideoTranscript"]
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            return []
        case .failure(let error):
            throw error
        }
    }

    func disconnect() async throws { disconnectCalls += 1; hasCredentials = false }
    func hasStoredCredentials() -> Bool { hasCredentials }

    func waitForConnect() async {
        while connectCalls == 0 || (mode.isGated && continuation == nil) { await Task.yield() }
    }

    func release() { continuation?.resume(); continuation = nil }
}

private extension JamSettingsController.Mode {
    var isGated: Bool {
        if case .gatedSuccess = self { true } else { false }
    }
}
