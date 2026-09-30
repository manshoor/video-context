import Foundation
import Observation

@MainActor
@Observable
final class JamSettingsModel {
    private(set) var status: JamConnectionStatus = .disconnected
    private(set) var message = JamConnectionStatus.disconnected.message
    private(set) var availableTools: Set<String> = []
    private(set) var isWorking = false
    @ObservationIgnored private let controller: any JamConnectionControlling
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(controller: any JamConnectionControlling) {
        self.controller = controller
    }

    var isConnected: Bool { status == .connected }

    func startConnect() {
        guard operation == nil, isWorking == false else { return }
        operation = Task { [weak self] in
            await self?.connect()
            self?.operation = nil
        }
    }

    func startReconnect() {
        guard operation == nil, isWorking == false else { return }
        operation = Task { [weak self] in
            await self?.reconnect()
            self?.operation = nil
        }
    }

    func cancelOperation() {
        operation?.cancel()
        operation = nil
    }

    func connect() async {
        await performConnect(interactive: true)
    }

    func reconnect() async {
        await performConnect(interactive: true)
    }

    func restoreConnection() async {
        guard await controller.hasStoredCredentials() else { return }
        await performConnect(interactive: false)
    }

    func disconnect() async {
        guard isWorking == false else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await controller.disconnect()
            availableTools = []
            status = .disconnected
            message = JamConnectionStatus.disconnected.message
        } catch let error as JamConnectionError {
            availableTools = []
            status = .disconnected
            message = error.localizedDescription
        } catch {
            availableTools = []
            status = .disconnected
            message = JamConnectionError.connectionFailed.localizedDescription
        }
    }

    private func performConnect(interactive: Bool) async {
        guard isWorking == false else { return }
        isWorking = true
        status = .connecting
        message = JamConnectionStatus.connecting.message
        defer { isWorking = false }
        do {
            let tools = try await controller.connect(interactive: interactive)
            try Task.checkCancellation()
            availableTools = tools
            status = .connected
            message = JamConnectionStatus.connected.message
        } catch is CancellationError {
            availableTools = []
            status = .disconnected
            message = "Jam connection was cancelled."
        } catch let error as JamConnectionError {
            availableTools = []
            status = error == .authorizationRequired ? .reconnectRequired : .disconnected
            message = error.localizedDescription
        } catch {
            availableTools = []
            status = .failed
            message = JamConnectionError.connectionFailed.localizedDescription
        }
    }
}

enum JamLiveConnection {
    static func makeService() -> JamConnectionService {
        let storage = JamOAuthCredentialStore()
        return JamConnectionService(
            storage: storage,
            remote: JamSDKRemoteClient(storage: storage),
            revoker: JamOAuthRevoker(storage: storage)
        )
    }
}
