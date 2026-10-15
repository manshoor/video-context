import Foundation
import CryptoKit
import Observation
import VideoContextCore

@MainActor @Observable final class AgentConnectionsModel {
    var checks: [AgentClient: AgentConfigCheck] = [:]
    var build: DiagnosticBuildMetadata?
    var binaryHash: String?
    var challenge: AgentImageChallenge?
    var serverResult: ServerConnectionResult?
    var message: String?
    var busy = false
    var answers: [AgentClient: String] = [:]
    var confirmations: [AgentClient: Bool] = [:]
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var startRequestID = UUID()
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var runBinaryHash: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?

    @discardableResult func refresh(executable: URL) async -> Bool {
        let id = UUID()
        refreshID = id
        let identity = await Self.inspect(executable: executable)
        guard id == refreshID, !Task.isCancelled else { return false }
        build = identity.build; binaryHash = identity.hash; checks = identity.checks
        invalidateIfBinaryChanged(identity.hash)
        return true
    }
    @concurrent private static func inspect(executable: URL) async -> (build: DiagnosticBuildMetadata, hash: String?, checks: [AgentClient: AgentConfigCheck]) {
        let checks = Dictionary(uniqueKeysWithValues: AgentClient.allCases.map {
            ($0, AgentConfigInspector.inspect(file: $0.configURL(), client: $0, currentCommand: executable.path))
        })
        return (DiagnosticBuild.metadata(executable: executable), await hash(executable), checks)
    }
    @concurrent private static func hash(_ executable: URL) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
    @discardableResult func beginRun(binaryHash: String?) -> UUID {
        runID = UUID()
        work?.cancel()
        let previous = work, previousCleanup = cleanup, oldChallenge = challenge
        work = nil; challenge = nil; serverResult = nil; answers = [:]; confirmations = [:]; message = nil; busy = false
        runBinaryHash = binaryHash
        cleanup = Task {
            await previousCleanup?.value
            await previous?.value
            oldChallenge?.remove()
        }
        return runID
    }
    @discardableResult func publish(challenge: AgentImageChallenge, result: ServerConnectionResult, runID: UUID) -> Bool {
        guard runID == self.runID else { return false }
        self.challenge = challenge; serverResult = result; busy = false
        return true
    }
    func invalidateIfBinaryChanged(_ hash: String?) {
        guard runBinaryHash != nil, hash != runBinaryHash else { return }
        beginRun(binaryHash: nil)
        message = "The executable changed or is unavailable. Start a new image test."
    }
    func start(executable: URL, ffmpeg: String) async {
        let requestID = UUID()
        startRequestID = requestID
        busy = true
        let refreshed = await refresh(executable: executable)
        guard requestID == startRequestID, !Task.isCancelled else { return }
        guard refreshed, let binaryHash else { busy = false; message = "MCP executable unavailable. Refresh and try again."; return }
        let id = beginRun(binaryHash: binaryHash), pendingCleanup = cleanup
        busy = true
        work = Task {
            await pendingCleanup?.value
            var fixture: AgentImageChallenge?
            let probe = MCPConnectionProbe()
            do {
                let created = try await AgentImageChallenge.create()
                fixture = created
                guard id == runID, !Task.isCancelled else { created.remove(); return }
                challenge = created
                let result = try await probe.run(executable: executable, challenge: created, ffmpeg: ffmpeg)
                guard id == runID, !Task.isCancelled else { created.remove(); return }
                let currentHash = await Self.hash(executable)
                guard id == runID, !Task.isCancelled else { created.remove(); return }
                guard currentHash == binaryHash else { invalidateIfBinaryChanged(currentHash); return }
                _ = publish(challenge: created, result: result, runID: id)
            } catch {
                guard id == runID, !Task.isCancelled else { fixture?.remove(); return }
                serverResult = .init(imageReturned: false, instructionsReceived: probe.instructionsReceived)
                busy = false
                if (error as? MCPConnectionProbe.Failure) == .timeout { message = "Server check timed out after 15 seconds." }
                else { message = "Server check failed to launch or complete the MCP exchange." }
            }
        }
    }
    func compare(_ client: AgentClient, executable: URL) async {
        let id = runID, answer = answers[client] ?? ""
        await refresh(executable: executable)
        guard id == runID, let challenge, answer == (answers[client] ?? "") else { return }
        confirmations[client] = challenge.matches(answer)
    }
    func endTest() async {
        startRequestID = UUID()
        beginRun(binaryHash: nil)
        await cleanup?.value
    }
}
