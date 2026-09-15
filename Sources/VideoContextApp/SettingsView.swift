import SwiftUI
import VideoContextCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var copiedLabel: String?

    var body: some View {
        Form {
            Section("Processing providers") {
                Picker("Speech transcription", selection: $model.transcriptionProvider) {
                    Text("OpenAI").tag(TranscriptionProvider.openAI)
                    Text("Local Whisper").tag(TranscriptionProvider.localWhisper)
                }
                Picker("Screenshots and coding brief", selection: $model.analysisProvider) {
                    Text("OpenAI").tag(AnalysisProvider.openAI)
                    Text("LM Studio · Local").tag(AnalysisProvider.lmStudio)
                }
                Text(model.modelConfiguration.processingDescription).font(.caption).foregroundStyle(.secondary)
                Text("Changes apply to future processing. Completed transcripts and screenshots are reused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.transcriptionProvider == .localWhisper {
                Section("Local speech model") {
                    Label("Whisper Large v3 Turbo", systemImage: "waveform")
                    Text(model.speechModelMessage).font(.caption).textSelection(.enabled)
                    if model.speechDownloadActive {
                        if let fraction = model.speechDownloadFraction { ProgressView(value: fraction) }
                        else { ProgressView().controlSize(.small) }
                        Button("Cancel download", systemImage: "xmark.circle") { model.speechDownloadTask?.cancel() }
                    } else {
                        Button(model.speechModelReady ? "Download model again" : "Download speech model", systemImage: "arrow.down.circle") { model.downloadSpeechModel() }
                            .disabled(model.isProcessing)
                    }
                    Text("One-time model and tokenizer download. Recording audio stays on this Mac. Model preparation may take longer on first use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.analysisProvider == .lmStudio {
                Section("LM Studio") {
                    TextField("Server address", text: $model.lmStudioURL)
                    Picker("Vision model", selection: $model.lmStudioModelID) {
                        Text("Choose a vision model").tag("")
                        if !model.lmStudioModelID.isEmpty && !model.localModels.contains(where: { $0.key == model.lmStudioModelID }) {
                            Text(model.lmStudioModelID).tag(model.lmStudioModelID)
                        }
                        ForEach(model.localModels) { item in
                            Text("\(item.displayName) · \(item.loadedInstances.isEmpty ? "Not loaded" : "Loaded")").tag(item.key)
                        }
                    }
                    Toggle("Server requires a token", isOn: $model.lmStudioUsesToken)
                    if model.lmStudioUsesToken {
                        SecureField("LM Studio token", text: Binding(get: { model.lmStudioToken }, set: { model.editLocalToken($0) }))
                        HStack {
                            Text(model.lmTokenState == .ready ? "Local token is ready" : "Enter or unlock your local token").font(.caption)
                            if model.lmTokenState == .loading { ProgressView().controlSize(.small) }
                            Button("Unlock token") { Task { await model.loadLocalToken(mode: .interactive) } }
                        }
                    }
                    HStack {
                        Button("Refresh models", systemImage: "arrow.clockwise") { model.startLocalModelCheck(testImage: false) }
                        Button("Test model", systemImage: "checkmark.seal") { model.startLocalModelCheck(testImage: true) }
                            .disabled(model.lmStudioModelID.isEmpty)
                        if model.checkingLocalModel { ProgressView().controlSize(.small) }
                    }.disabled(model.checkingLocalModel)
                    if model.checkingLocalModel {
                        Button("Cancel model check", systemImage: "xmark.circle") { model.localCheckTask?.cancel() }
                    }
                    Text(model.localConnectionMessage).font(.caption).textSelection(.enabled)
                    Text("Recommended for this Mac: Qwen3.8 27B MLX 4-bit with 32K context and low reasoning effort. Smaller alternative: Gemma 4 12B QAT. Download and load models in LM Studio’s Developer tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.transcriptionProvider == .openAI || model.analysisProvider == .openAI {
            Section("OpenAI") {
                SecureField("API key", text: apiKeyBinding)
                TextField("Transcription model", text: $model.transcriptionModel)
                TextField("Analysis model", text: $model.analysisModel)
                HStack {
                    if model.credentialState == .loading { ActivityIndicator(fraction: nil) }
                    Label(model.credentialStatusText, systemImage: model.credentialStatusSystemImage)
                        .foregroundStyle(credentialStatusColor)
                    Spacer()
                    if model.shouldOfferCredentialUnlock {
                        Button("Unlock API key") { model.unlockAPIKey() }
                    }
                }
                Text("The key is stored in macOS Keychain. Audio chunks and selected screenshots are sent to OpenAI during processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            }

            Section("Media tools") {
                TextField("yt-dlp", text: $model.ytDLPPath)
                TextField("ffmpeg", text: $model.ffmpegPath)
                TextField("ffprobe", text: $model.ffprobePath)
                ForEach(model.dependencyStatus, id: \.name) { dependency in
                    Label(
                        dependency.available ? "\(dependency.name) is available" : "\(dependency.name) is missing at \(dependency.path)",
                        systemImage: dependency.available ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(dependency.available ? .green : .red)
                }
            }

            Section("Agent connections") {
                Text("Each client starts its own local MCP process. The app can be closed after processing finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                configRow(name: "Codex", value: codexConfig)
                configRow(name: "Claude Code", value: jsonConfig)
                configRow(name: "Cursor", value: jsonConfig)
            }

            HStack {
                if let copiedLabel { Text("Copied \(copiedLabel)").foregroundStyle(.secondary) }
                Spacer()
                Button("Save settings", systemImage: "checkmark.circle") { Task { await model.saveSettings() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await model.refreshSpeechModelStatus() }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { model.apiKey },
            set: { model.userEditedAPIKey($0) }
        )
    }

    private var credentialStatusColor: Color {
        switch model.credentialState {
        case .ready: .green
        case .loading: .secondary
        case .missing, .accessRequired, .failed: .orange
        }
    }

    private func configRow(name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Button("Copy configuration", systemImage: "doc.on.doc") {
                    model.copy(value)
                    copiedLabel = name
                }
            }
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(5)
        }
    }

    private var codexConfig: String {
        """
        [mcp_servers.video-context]
        command = "\(model.mcpExecutablePath)"
        args = ["--ffmpeg", "\(model.ffmpegPath)"]
        """
    }

    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "video-context": {
              "command": "\(model.mcpExecutablePath)",
              "args": ["--ffmpeg", "\(model.ffmpegPath)"]
            }
          }
        }
        """
    }
}
