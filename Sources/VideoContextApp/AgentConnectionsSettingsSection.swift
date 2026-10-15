import SwiftUI
import AppKit
import VideoContextCore

struct AgentConnectionsSettingsSection: View {
    let model: AppModel
    @Bindable var connections: AgentConnectionsModel
    @State private var copied: String?
    private var executable: URL { URL(fileURLWithPath: model.mcpExecutablePath) }
    private var setup: AgentSetup? {
        model.paths.map { AgentSetup(executable: executable.path, library: $0.root.path, ffmpeg: model.ffmpegPath) }
    }

    var body: some View {
        Section("Agent connections") {
            Text("Each client starts its own MCP process. These checks read only the user config files; project overrides and already-running client processes may differ.")
                .font(.caption).foregroundStyle(.secondary)
            labeledValue("MCP executable", executable.path)
            labeledValue("Build", connections.build?.version ?? "Checking…")
            if let stamp = connections.build?.stamp {
                labeledValue("Built (UTC)", stamp.dateUTC)
                labeledValue("Stamped MCP SHA-256", stamp.binarySHA256)
                if let hash = connections.binaryHash, hash != stamp.binarySHA256 {
                    Text("The executable differs from its build stamp.").foregroundStyle(.orange)
                }
            } else { Text("Stamp unavailable").font(.caption).foregroundStyle(.secondary) }
            labeledValue("Library", model.paths?.root.path ?? "Unavailable")
            Button("Refresh user-config checks", systemImage: "arrow.clockwise") {
                Task { await connections.refresh(executable: executable) }
            }
            ForEach(AgentClient.allCases) { client in
                DisclosureGroup("\(client.label) — user config") {
                    labeledValue("File", client.configURL().path)
                    Text(connections.checks[client]?.status.label ?? "Checking…").font(.callout)
                    if let command = connections.checks[client]?.command { labeledValue("Configured command", command) }
                    if let setup { setupRows(setup, client: client) }
                }
            }
        }
        Section("Image connection test") {
            Text("Creates a temporary library with a fresh code in image pixels and empty OCR. The server self-test uses no model or plan quota. Agent image checks are manual.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(connections.challenge == nil ? "Start image test" : "New image test", systemImage: "photo.badge.checkmark") {
                    Task { await connections.start(executable: executable, ffmpeg: model.ffmpegPath) }
                }.disabled(connections.busy)
                if connections.busy { ProgressView().controlSize(.small); Text("Checking server…").font(.caption) }
                if connections.challenge != nil || connections.busy {
                    Button("End test") { Task { await connections.endTest() } }
                }
            }
            if let result = connections.serverResult {
                resultRow("Server returned an image", passed: result.imageReturned)
                resultRow("Instructions received", passed: result.instructionsReceived)
            }
            if let message = connections.message { Text(message).font(.callout).foregroundStyle(.orange) }
            if let challenge = connections.challenge {
                Text("Manual client confirmation").font(.headline)
                Text("Add the separate video-context-test entry, then restart that client's MCP connection. Ask it to read the image using the copied prompt. Paste its answer below. A server pass alone does not verify a client.")
                    .font(.caption).foregroundStyle(.secondary)
                copyRow("Evidence prompt", value: challenge.prompt)
                ForEach(AgentClient.allCases, id: \.self) { client in
                    DisclosureGroup(client.label) {
                        let temporary = AgentSetup(executable: executable.path, library: challenge.paths.root.path, ffmpeg: model.ffmpegPath, alias: "video-context-test")
                        setupRows(temporary, client: client)
                        TextField("Code returned by \(client.label)", text: Binding(get: { connections.answers[client] ?? "" }, set: {
                            connections.answers[client] = $0; connections.confirmations[client] = nil
                        }))
                        HStack {
                            Button("Compare code") { Task { await connections.compare(client, executable: executable) } }
                                .disabled(connections.busy || (connections.answers[client] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let passed = connections.confirmations[client] {
                                resultRow(passed ? "Code matches" : "Code does not match", passed: passed)
                            } else { Text("Unverified").foregroundStyle(.secondary) }
                        }
                        if client == .cursor {
                            Text("After testing, remove only mcpServers.video-context-test from ~/.cursor/mcp.json, then restart its MCP connection.").font(.caption)
                        } else {
                            copyRow("Remove temporary entry", value: temporary.removalCommand(for: client))
                            Text("Then restart the client's MCP connection.").font(.caption)
                        }
                    }
                    .id("manual-\(client.id)")
                }
                Text("End test, a new run, or app exit deletes this temporary library. Remove the test entries afterward. Results are kept only in memory; an executable change clears confirmations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let copied { Text("Copied \(copied)").font(.caption).foregroundStyle(.secondary) }
        }
        .task { await connections.refresh(executable: executable) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await connections.refresh(executable: executable) }
        }
    }
    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
    private func resultRow(_ title: String, passed: Bool) -> some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(passed ? .green : .orange).font(.callout)
    }
    private func setupRows(_ setup: AgentSetup, client: AgentClient) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if client != .cursor { copyRow("Setup command", value: setup.command(for: client)) }
            copyRow("Configuration", value: setup.configuration(for: client))
            Text(client == .codex ? "Merge the displayed section into the user config." : "Merge this entry into mcpServers; preserve other entries.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func copyRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Copy \(label.lowercased())", systemImage: "doc.on.doc") { model.copy(value); copied = label }
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
