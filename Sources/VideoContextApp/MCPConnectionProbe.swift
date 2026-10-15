import Foundation
import Darwin
import ImageIO
import MCP
import System
import VideoContextCore

struct ServerConnectionResult: Equatable, Sendable {
    let imageReturned: Bool
    let instructionsReceived: Bool
}

/// Owns only the server it launches. Never launches a coding agent.
@MainActor final class MCPConnectionProbe {
    enum Failure: Error, Equatable { case timeout, alreadyRunning }
    private var child: ProbeChild?
    private(set) var instructionsReceived = false
    var childIsRunning: Bool { child?.isRunning == true }

    func run(executable: URL, challenge: AgentImageChallenge, ffmpeg: String,
             timeout: Duration = .seconds(15)) async throws -> ServerConnectionResult {
        try Task.checkCancellation()
        guard !childIsRunning else { throw Failure.alreadyRunning }
        instructionsReceived = false
        let owned = ProbeChild()
        child = owned
        // Build our own argv; CommandLine.arguments must never reach the child.
        try owned.launch(executable: executable, arguments: ["--library", challenge.paths.root.path, "--ffmpeg", ffmpeg])
        let client = Client(name: "video-context-connection-check", version: DiagnosticBuild.current)
        let transport = StdioTransport(input: FileDescriptor(rawValue: owned.output.fileHandleForReading.fileDescriptor),
                                       output: FileDescriptor(rawValue: owned.input.fileHandleForWriting.fileDescriptor))
        do {
            let result = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ServerConnectionResult.self) { group in
                    group.addTask { try await self.exchange(client: client, transport: transport, challenge: challenge) }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw Failure.timeout
                    }
                    do {
                        let result = try await group.next()!
                        group.cancelAll()
                        await client.disconnect()
                        await owned.stop()
                        try Task.checkCancellation()
                        return result
                    } catch {
                        group.cancelAll()
                        // Disconnect resumes SDK continuations before leaving the group.
                        await client.disconnect()
                        await owned.stop()
                        throw error
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    await client.disconnect()
                    await owned.stop()
                }
            }
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func exchange(client: Client, transport: StdioTransport, challenge: AgentImageChallenge) async throws -> ServerConnectionResult {
        try Task.checkCancellation()
        let initialization = try await client.connect(transport: transport)
        try Task.checkCancellation()
        let instructions = !(initialization.instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        instructionsReceived = instructions
        let arguments: [String: Value] = ["batch_id": .string(challenge.batchID), "task_id": .string(challenge.taskID),
            "source_id": .string(challenge.sourceID), "expected_batch_revision": .int(challenge.batchRevision),
            "expected_revision": .int(challenge.taskRevision)]
        let response = try await client.callTool(name: "get_feedback_evidence", arguments: arguments)
        try Task.checkCancellation()
        return .init(imageReturned: response.isError != true && Self.containsNativeImage(response.content), instructionsReceived: instructions)
    }

    nonisolated static func containsNativeImage(_ content: [Tool.Content]) -> Bool {
        content.contains { block in
            guard case let .image(encoded, mimeType, _, _) = block, mimeType.hasPrefix("image/"),
                  let data = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        }
    }
}

@MainActor private final class ProbeChild {
    let process = Process()
    let input = Pipe(), output = Pipe(), error = Pipe()
    private var cleanup: Task<Void, Never>?
    var isRunning: Bool { process.isRunning }

    func launch(executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        // Discard stderr on its own pipe. It cannot block protocol stdout or leak
        // image payloads into diagnostics. The readability callback is off-main.
        error.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do { try process.run() }
        catch { closeHandles(); throw error }
        // These ends belong to the child. Keeping parent copies would prevent EOF.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
    }
    func stop() async {
        if let cleanup { await cleanup.value; return }
        // An unstructured task is deliberately not cancelled with the probe;
        // cleanup must still wait responsively and stop our owned child.
        let task = Task { @MainActor in
            try? input.fileHandleForWriting.close()
            await waitForExit(for: .seconds(1))
            if process.isRunning { process.terminate() }
            await waitForExit(for: .seconds(2))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
            closeHandles()
        }
        cleanup = task
        await task.value
    }
    private func waitForExit(for duration: Duration) async {
        let clock = ContinuousClock(), end = clock.now + duration
        while process.isRunning && clock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
    }
    private func closeHandles() {
        error.fileHandleForReading.readabilityHandler = nil
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                       output.fileHandleForWriting, error.fileHandleForReading, error.fileHandleForWriting] { try? handle.close() }
    }
}
