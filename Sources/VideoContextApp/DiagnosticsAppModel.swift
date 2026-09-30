import AppKit
import Foundation
import VideoContextCore

extension AppModel {
    func startDiagnostics() async {
        guard !diagnosticsStarted, let diagnostics else { return }
        diagnosticsStarted = true
        await diagnostics.record(.init(diagnosticStartupFailure == nil ? .started : .failed, operation: .lifecycle, error: diagnosticStartupFailure))
        await refreshDiagnostics()
    }
    func refreshDiagnostics() async {
        guard let diagnostics else { return }
        let status = await diagnostics.status()
        diagnosticsEnabled = status.enabled
        diagnosticsExpiry = status.policy?.expiresAt
        diagnosticsHealth = status.failure.map { "Logging unavailable: \($0.category.rawValue). Check free disk space and library access." } ?? "Local capture is available."
        diagnosticExpiryTask?.cancel()
        if status.enabled, let expiry = status.policy?.expiresAt {
            diagnosticExpiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
                await self?.refreshDiagnostics()
            }
        }
        syncDiagnosticHeartbeat()
    }
    func enableDiagnostics() async {
        guard let diagnostics else { return }
        do {
            _ = try await diagnostics.enable()
            await refreshDiagnostics()
            if let scope = diagnosticActivityScope, let activity {
                await diagnostics.record(.init(.stateChanged, operation: scope.operation, operationID: scope.id,
                    context: scope.context, stage: activity.diagnosticStage, completed: activity.completed, total: activity.total,
                    elapsedSeconds: Date().timeIntervalSince(scope.startedAt), alreadyUnderway: true))
            }
        } catch { diagnosticsHealth = "Logging could not start. Check free disk space and library access." }
    }
    func stopDiagnostics() async {
        guard let diagnostics else { return }
        do { try await diagnostics.stop(); await refreshDiagnostics() }
        catch { diagnosticsHealth = "Logging could not be stopped. Check library access; capture still expires automatically." }
    }
    func openDiagnosticsFolder() { if let diagnostics { NSWorkspace.shared.open(diagnostics.root) } }

    func diagnosticScope(_ operation: DiagnosticOperation, videoID: String? = nil, taskID: String? = nil, revision: Int? = nil) -> DiagnosticScope? {
        guard let diagnostics else { return nil }
        let models = operation == .taskGeneration ? taskConfiguration : modelConfiguration
        let provider: InferenceProvider? = [.taskGeneration, .modelCheck].contains(operation) ? models.analysisProvider.identity : nil
        return DiagnosticScope(service: diagnostics, operation: operation,
            context: .init(videoID: videoID, taskID: taskID, revision: revision, provider: provider,
                           model: provider == nil ? nil : models.selectedAnalysisModel))
    }
    func runDiagnosed(_ operation: DiagnosticOperation, videoID: String? = nil, body: () async -> Void) async {
        let scope = diagnosticScope(operation, videoID: videoID)
        if [.processing, .taskGeneration, .importLocal, .importOnline].contains(operation) { diagnosticActivityScope = scope; syncDiagnosticHeartbeat() }
        await DiagnosticTrace.$scope.withValue(scope) {
            await DiagnosticTrace.record(.started)
            await body()
        }
        if diagnosticActivityScope?.id == scope?.id { diagnosticActivityScope = nil; syncDiagnosticHeartbeat() }
        await refreshDiagnostics()
    }
    func recordDiagnosticFailure(_ error: any Error, operation: DiagnosticOperation = .save, videoID: String? = nil, taskID: String? = nil, revision: Int? = nil) async {
        await diagnostics?.record(.init(.failed, operation: operation, context: .init(videoID: videoID, taskID: taskID, revision: revision), error: DiagnosticFailure(error)))
    }
    func diagnosticCredentialChanged(_ state: CredentialState) {
        let value: DiagnosticCredentialState
        switch state {
        case .loading: value = .loading
        case .ready: value = .ready
        case .missing: value = .missing
        case .accessRequired: value = .accessRequired
        case .failed: value = .failed
        }
        let service = diagnostics
        Task { await service?.record(.init(.stateChanged, operation: .credentials, credentialState: value)) }
    }
    func syncDiagnosticHeartbeat() {
        guard diagnosticsEnabled, activity != nil, diagnosticActivityScope != nil else {
            diagnosticHeartbeat?.cancel(); diagnosticHeartbeat = nil; return
        }
        guard diagnosticHeartbeat == nil else { return }
        diagnosticHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let scope = self.diagnosticActivityScope, let activity = self.activity,
                      await scope.service.status().enabled else { self?.diagnosticHeartbeat = nil; return }
                await scope.service.record(.init(.progress, operation: scope.operation, operationID: scope.id,
                    context: scope.context, stage: activity.diagnosticStage, completed: activity.completed, total: activity.total,
                    elapsedSeconds: Date().timeIntervalSince(scope.startedAt)))
                let status = await scope.service.status()
                if status.failure != nil { self.diagnosticsHealth = "Some diagnostic events could not be saved. Check disk space and library access." }
            }
        }
    }
}
private extension AppActivity {
    var diagnosticStage: ProcessingStatus? {
        if case .processing(let stage) = phase { return stage }
        return nil
    }
}
