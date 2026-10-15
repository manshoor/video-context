import Foundation
import ImageIO
import Testing
@testable import VideoContextCore

struct AgentConnectionTests {
    @Test func buildIdentityAndOptionalStamp() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "Example.app/Contents/MacOS/video-context-mcp")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(DiagnosticBuild.metadata(executable: executable).version == "development")
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        var info: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"]
        func save() throws { try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist) }
        try save()
        #expect(DiagnosticBuild.metadata(executable: executable).version == "1.2.3 (42)")
        #expect(DiagnosticBuild.metadata(executable: executable).stamp == nil)
        info["VideoContextBuildDateUTC"] = "2026-10-03T00:00:00Z"
        info["VideoContextMCPBinarySHA256"] = String(repeating: "a", count: 64)
        try save()
        #expect(DiagnosticBuild.metadata(executable: executable).stamp?.binarySHA256 == String(repeating: "a", count: 64))
        info["VideoContextMCPBinarySHA256"] = "invalid"
        try save()
        #expect(DiagnosticBuild.metadata(executable: executable).stamp == nil)
    }

    @Test func codexQuotedEscapesCommentsAndDisabledEntries() {
        let command = "/tmp/a # folder/it's server"
        let config = AgentSetup(executable: command, library: "/tmp/library", ffmpeg: "/tmp/ffmpeg")
        let text = config.configuration(for: .codex) + "\nenabled = false # user setting\n"
        #expect(AgentConfigInspector.parse(text, client: .codex, currentCommand: command).status == .disabled)
        let commented = "[mcp_servers.video-context] # heading\ncommand = \"/tmp/a # folder/it's server\" # trailing\n"
        #expect(AgentConfigInspector.parse(commented, client: .codex, currentCommand: command).status == .matching)
        #expect(AgentConfigInspector.parse("[mcp_servers.other]\ncommand = \"/tmp/server\"", client: .codex, currentCommand: command).status == .missingEntry)
        #expect(AgentConfigInspector.parse("[mcp_servers.video-context]\ncommand = [\"bad\"]", client: .codex, currentCommand: command).status == .unsupportedSyntax)
        #expect(AgentConfigInspector.parse("[mcp_servers.video-context]\ncommand = \"/tmp/x\"\ncommand = \"/tmp/y\"", client: .codex, currentCommand: command).status == .unsupportedSyntax)
        #expect(AgentConfigInspector.parse("[mcp_servers.\"video-context\"]\ncommand = \"/tmp/line\\nquote\\\"slash\\\\server\"", client: .codex, currentCommand: "/tmp/line\nquote\"slash\\server").status == .matching)
    }

    @Test(arguments: [AgentClient.claude, .cursor]) func jsonConfigs(_ client: AgentClient) {
        let setup = AgentSetup(executable: "/tmp/quote\"server", library: "/tmp/library", ffmpeg: "/tmp/ffmpeg")
        #expect(AgentConfigInspector.parse(setup.configuration(for: client), client: client, currentCommand: setup.executable).status == .matching)
        #expect(AgentConfigInspector.parse("{}", client: client, currentCommand: setup.executable).status == .missingEntry)
        #expect(AgentConfigInspector.parse("{", client: client, currentCommand: setup.executable).status == .unsupportedSyntax)
        #expect(AgentConfigInspector.parse(#"{"mcpServers":{"video-context":{"command":"/tmp/old","disabled":true}}}"#, client: client, currentCommand: setup.executable).status == .disabled)
        #expect(AgentConfigInspector.parse(#"{"mcpServers":{"video-context":{"command":"/tmp/old"}}}"#, client: client, currentCommand: setup.executable).status == .different)
    }

    @Test func inspectionIsReadOnlyAndResolvesHomeAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appending(path: "current"), link = root.appending(path: "link"), file = root.appending(path: "config.toml")
        try Data().write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(AgentConfigInspector.inspect(file: file, client: .codex, currentCommand: real.path).status == .missingFile)
        let original = Data("[mcp_servers.video-context]\ncommand = \"~/link\"".utf8)
        try original.write(to: file)
        #expect(AgentConfigInspector.inspect(file: file, client: .codex, currentCommand: real.path, home: root).status == .matching)
        #expect(try Data(contentsOf: file) == original)
        #expect(AgentConfigInspector.inspect(file: root, client: .codex, currentCommand: real.path).status == .unreadableFile)
        let blocked = root.appending(path: "blocked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let blockedFile = blocked.appending(path: "config.toml")
        try original.write(to: blockedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        #expect(AgentConfigInspector.inspect(file: blockedFile, client: .codex, currentCommand: real.path).status == .unreadableFile)
        #expect(AgentConfigInspector.parse("[mcp_servers.video-context]\ncommand = \"relative\"", client: .codex, currentCommand: real.path).status == .unsupportedSyntax)
    }

    @Test func shellCommandsRoundTripWithoutExpansion() throws {
        let setup = AgentSetup(executable: "/tmp/it's a $(exit 19) `exit 20` server", library: "/tmp/lib\n\"folder", ffmpeg: "/tmp/ffmpeg's path")
        #expect(setup.command(for: .claude).hasPrefix("claude mcp add --transport stdio --scope user video-context -- "))
        // Let a harmless shell function capture arguments. No client is launched.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "codex() { printf '%s\\0' \"$@\"; }; " + setup.command(for: .codex)]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) == ["mcp", "add", "video-context", "--", setup.executable, "--library", setup.library, "--ffmpeg", setup.ffmpeg])
    }

    @Test func fixtureIsIsolatedFreshAndContainsNoTextAnswer() async throws {
        let first = try await AgentImageChallenge.create()
        defer { first.remove() }
        let second = try await AgentImageChallenge.create()
        defer { second.remove() }
        #expect(first.paths.root != second.paths.root)
        #expect(first.expectedCode != second.expectedCode)
        #expect(first.expectedCode.count == 8)
        #expect(first.matches("  " + first.expectedCode.lowercased() + "\n"))
        #expect(!first.matches("wrong"))
        let reader = try VideoContextStore(databaseURL: first.paths.database, access: .readOnly)
        let snapshot = try await reader.feedbackSnapshot(id: first.batchID)
        let source = try #require(snapshot.batch.sources.first)
        #expect(source.kind == .image && source.status == .ready && source.ocrText.isEmpty)
        #expect(snapshot.tasks.map(\.id) == [first.taskID])
        #expect(snapshot.batch.revision == first.batchRevision && snapshot.tasks[0].revision == first.taskRevision)
        let metadata = String(decoding: try JSONEncoder().encode(snapshot.batch), as: UTF8.self) + String(decoding: try JSONEncoder().encode(snapshot.tasks), as: UTF8.self)
        #expect(!metadata.contains(first.expectedCode))
        #expect(!first.prompt.contains(first.expectedCode))
        #expect(!first.paths.root.path.contains(first.expectedCode))
        #expect(first.prompt.contains(first.sourceID) && first.prompt.contains(first.taskID))
        let imageURL = first.paths.absoluteURL(relativePath: try #require(source.localPath))
        let image = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(image, 0, nil)?.width == 1200)
        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.paths.root.path))
    }
}
