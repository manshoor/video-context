import Foundation
import Testing
import MCP
import VideoContextCore
@testable import VideoContextApp

// These launch real processes and exercise Foundation's shared pipe callbacks.
// Serialize them so process-start contention cannot masquerade as a timeout.
@Suite(.serialized) @MainActor struct AgentConnectionAppTests {
    @Test func sdkReadsTheBuiltServerWithoutChangingFixtureDatabase() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appending(path: ".build/debug/video-context-mcp")
        let challenge = try await AgentImageChallenge.create()
        defer { challenge.remove() }
        let before = try Data(contentsOf: challenge.paths.database)
        let probe = MCPConnectionProbe()
        let result = try await probe.run(executable: executable, challenge: challenge, ffmpeg: "/opt/homebrew/bin/ffmpeg")
        #expect(result.imageReturned && result.instructionsReceived)
        #expect(!probe.childIsRunning)
        #expect(try Data(contentsOf: challenge.paths.database) == before)
    }

    @Test(arguments: ["image", "text", "invalidImage", "noInstructions", "toolError"])
    func sdkResultsAreIndependent(_ mode: String) async throws {
        let challenge = try await AgentImageChallenge.create()
        defer { challenge.remove() }
        let executable = try mockServer(in: challenge.paths.root, mode: mode)
        let probe = MCPConnectionProbe()
        let result = try await probe.run(executable: executable, challenge: challenge, ffmpeg: "/tmp/ffmpeg")
        #expect(result.imageReturned == (mode == "image" || mode == "noInstructions"))
        #expect(result.instructionsReceived == (mode != "noInstructions"))
        #expect(!probe.childIsRunning)
        #expect(FileManager.default.fileExists(atPath: challenge.paths.database.path))
    }

    @Test func launchAndProtocolFailureCleanUp() async throws {
        let challenge = try await AgentImageChallenge.create()
        defer { challenge.remove() }
        let probe = MCPConnectionProbe()
        await #expect(throws: (any Error).self) {
            try await probe.run(executable: challenge.paths.root.appending(path: "missing"), challenge: challenge, ffmpeg: "/tmp/ffmpeg")
        }
        #expect(!probe.childIsRunning)
        let executable = try mockServer(in: challenge.paths.root, mode: "protocolError")
        do {
            _ = try await probe.run(executable: executable, challenge: challenge, ffmpeg: "/tmp/ffmpeg")
            Issue.record("Expected an initialization protocol error")
        } catch { #expect(!(error is MCPConnectionProbe.Failure)) }
        #expect(!probe.childIsRunning)
    }

    @Test func timeoutForceStopsOnlyItsChild() async throws {
        let challenge = try await AgentImageChallenge.create()
        defer { challenge.remove() }
        let executable = try mockServer(in: challenge.paths.root, mode: "ignoreTermination")
        let probe = MCPConnectionProbe(), clock = ContinuousClock(), start = clock.now
        let work = Task { try await probe.run(executable: executable, challenge: challenge, ffmpeg: "/tmp/ffmpeg", timeout: .seconds(6)) }
        try await waitForReady(in: challenge.paths.root)
        await #expect(throws: MCPConnectionProbe.Failure.timeout) { try await work.value }
        #expect(clock.now - start >= .seconds(9))
        #expect(clock.now - start < .seconds(12))
        #expect(!probe.childIsRunning)
    }

    @Test func cancellationStopsTheChildAndReturns() async throws {
        let challenge = try await AgentImageChallenge.create()
        defer { challenge.remove() }
        let executable = try mockServer(in: challenge.paths.root, mode: "hang")
        let probe = MCPConnectionProbe()
        let work = Task { try await probe.run(executable: executable, challenge: challenge, ffmpeg: "/tmp/ffmpeg") }
        try await waitForReady(in: challenge.paths.root)
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(!probe.childIsRunning)
    }

    private func waitForReady(in root: URL) async throws {
        let clock = ContinuousClock(), deadline = clock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: root.appending(path: "ready").path) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "ready").path))
    }

    @Test func obsoleteResultsAndBinaryChangesInvalidateConfirmations() async throws {
        let challenge = try await AgentImageChallenge.create()
        defer { challenge.remove() }
        let model = AgentConnectionsModel()
        let first = model.beginRun(binaryHash: "first")
        let current = model.beginRun(binaryHash: "second")
        #expect(!model.publish(challenge: challenge, result: .init(imageReturned: true, instructionsReceived: true), runID: first))
        #expect(model.challenge == nil)
        #expect(model.publish(challenge: challenge, result: .init(imageReturned: true, instructionsReceived: true), runID: current))
        model.answers[.codex] = "anything"
        model.invalidateIfBinaryChanged("third")
        #expect(model.challenge == nil && model.answers.isEmpty && model.serverResult == nil)
        #expect(!model.publish(challenge: challenge, result: .init(imageReturned: true, instructionsReceived: true), runID: current))
    }

    private func mockServer(in root: URL, mode: String) throws -> URL {
        let file = root.appending(path: "mock-server")
        let script = """
        #!/usr/bin/python3
        import sys, json, base64, pathlib, signal, time
        mode = '\(mode)'
        assert sys.argv[1:] == ['--library', '\(root.path)', '--ffmpeg', '/tmp/ffmpeg']
        if mode == 'ignoreTermination':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if mode in ['hang', 'ignoreTermination']:
            pathlib.Path('\(root.path)/ready').touch()
            while True: time.sleep(1)
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            if mode == 'protocolError':
                print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32603,'message':'fixture failure'}}), flush=True)
                continue
            if request['method'] == 'initialize':
                sys.stderr.write('drained stderr\\n' * 10000); sys.stderr.flush()
                result = {'protocolVersion':request['params']['protocolVersion'], 'capabilities':{'tools':{}}, 'serverInfo':{'name':'test','version':'development'}}
                if mode != 'noInstructions': result['instructions'] = 'Read the MCP image.'
            else:
                image = next(pathlib.Path('\(root.path)').glob('feedback/*/challenge.png'))
                data = base64.b64encode(image.read_bytes()).decode() if mode != 'invalidImage' else base64.b64encode(b'not an image').decode()
                content = [{'type':'image','data':data,'mimeType':'image/png'}]
                if mode == 'text': content = [{'type':'text','text':'https://example.com/image.png'}]
                result = {'content':content,'isError':mode == 'toolError'}
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}), flush=True)
        """
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}
