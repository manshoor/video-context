import SwiftUI
import VideoContextCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var copiedLabel: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Processing providers") {
                Picker("Speech transcription", selection: $model.transcriptionProvider) {
                    Text("OpenAI").tag(TranscriptionProvider.openAI)
                    Text("Local Whisper").tag(TranscriptionProvider.localWhisper)
                }
                Picker("Screenshots and coding brief", selection: $model.analysisProvider) {
                    ForEach(AnalysisProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Available analysis providers: OpenAI, LM Studio, Claude, DeepSeek.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.modelConfiguration.processingDescription).font(.caption).foregroundStyle(.secondary)
                effortPicker(title: "Video reasoning", selection: Binding(get: { model.analysisReasoningEffort ?? .medium }, set: { model.analysisReasoningEffort = $0 }), provider: model.analysisProvider)
                Text("Changes apply to future processing. Completed transcripts and screenshots are reused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accuracy profile") {
                Button("Apply accuracy profile", systemImage: "wand.and.stars") {
                    model.applyAccuracyProfile()
                }
                Text("Routes video analysis to Sol high, task and documentation analysis to Astra high, and independent review to Claude Opus high. Speech and feedback preparation settings remain unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Documentation analysis") {
                Toggle("Use video-analysis settings", isOn: Binding(
                    get: { model.documentationAnalysisOverride == nil },
                    set: { same in
                        model.documentationAnalysisOverride = same ? nil : .init(provider: .openAI, modelID: "gpt-6-astra", effort: .high)
                    }
                ))
                if let override = model.documentationAnalysisOverride {
                    Picker("Documentation provider", selection: Binding(
                        get: { model.documentationAnalysisOverride?.provider ?? override.provider },
                        set: { provider in
                            let current = model.documentationAnalysisOverride
                            model.documentationAnalysisOverride = .init(provider: provider, modelID: current?.modelID ?? "", effort: current?.effort ?? .high)
                        }
                    )) {
                        ForEach(AnalysisProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    ProviderModelPicker(title: "Documentation model", provider: override.provider,
                        value: Binding(get: { model.documentationAnalysisOverride?.modelID ?? "" }, set: { model.documentationAnalysisOverride?.modelID = $0 }),
                        models: model.providerModels[override.provider] ?? [])
                    effortPicker(title: "Documentation reasoning", selection: Binding(get: { model.documentationAnalysisOverride?.effort ?? .high }, set: { model.documentationAnalysisOverride?.effort = $0 }), provider: override.provider)
                    modelActions(configuration: model.modelConfiguration.documentationConfiguration)
                }
                Text("Documentation analysis cross-references selected project documents with the original recording evidence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Independent evidence review") {
                Toggle("Enable review", isOn: Binding(
                    get: { model.reviewAnalysisOverride != nil },
                    set: { enabled in
                        model.reviewAnalysisOverride = enabled ? .init(provider: .claude, modelID: "claude-opus-5-5", effort: .high) : nil
                    }
                ))
                if let review = model.reviewAnalysisOverride {
                    Picker("Review provider", selection: Binding(
                        get: { model.reviewAnalysisOverride?.provider ?? review.provider },
                        set: { provider in
                            let current = model.reviewAnalysisOverride
                            model.reviewAnalysisOverride = .init(provider: provider, modelID: current?.modelID ?? "", effort: current?.effort ?? .high)
                        }
                    )) {
                        ForEach(AnalysisProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    ProviderModelPicker(title: "Review model", provider: review.provider,
                        value: Binding(get: { model.reviewAnalysisOverride?.modelID ?? "" }, set: { model.reviewAnalysisOverride?.modelID = $0 }),
                        models: model.providerModels[review.provider] ?? [])
                    effortPicker(title: "Review reasoning", selection: Binding(get: { model.reviewAnalysisOverride?.effort ?? .high }, set: { model.reviewAnalysisOverride?.effort = $0 }), provider: review.provider)
                    if let reviewConfiguration = model.modelConfiguration.reviewConfiguration {
                        modelActions(configuration: reviewConfiguration)
                    }
                }
                Text("Review checks omissions, unsupported claims, contradictions, duplicates, and acceptance checks. Review results require human approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.analysisProvider == .claude || model.analysisProvider == .deepSeek {
                Section("Video analysis model") {
                    ProviderModelPicker(title: "Model", provider: model.analysisProvider, value: videoCloudModel, models: model.providerModels[model.analysisProvider] ?? [])
                    modelActions(configuration: model.modelConfiguration)
                }
            }
            Section("Task generation") {
                Toggle("Use video-analysis settings", isOn: Binding(get: { model.taskAnalysisOverride == nil }, set: { same in
                    model.taskAnalysisOverride = same ? nil : .init(provider: model.analysisProvider, modelID: model.modelConfiguration.selectedAnalysisModel)
                }))
                if model.taskAnalysisOverride != nil {
                    Picker("Task provider", selection: Binding(get: { model.taskAnalysisOverride?.provider ?? model.analysisProvider }, set: { provider in
                        model.taskAnalysisOverride = .init(provider: provider, modelID: "")
                    })) {
                        ForEach(AnalysisProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    ProviderModelPicker(title: "Task model", provider: model.taskConfiguration.analysisProvider,
                        value: Binding(get: { model.taskAnalysisOverride?.modelID ?? "" }, set: { model.taskAnalysisOverride?.modelID = $0 }),
                        models: model.taskConfiguration.analysisProvider == .lmStudio ? model.localModels.map(\.key) : model.providerModels[model.taskConfiguration.analysisProvider] ?? [])
                    effortPicker(title: "Task reasoning", selection: Binding(get: { model.taskAnalysisOverride?.effort ?? .medium }, set: { model.taskAnalysisOverride?.effort = $0 }), provider: model.taskConfiguration.analysisProvider)
                    modelActions(configuration: model.taskConfiguration)
                }
                Text(model.taskProviderLabel).font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback preparation") {
                Toggle("Use analysis settings", isOn: Binding(get: { model.feedbackPreparationOverride == nil }, set: { same in
                    model.feedbackPreparationOverride = same ? nil : .init(provider: model.analysisProvider, modelID: model.modelConfiguration.selectedAnalysisModel)
                }))
                if model.feedbackPreparationOverride != nil {
                    Picker("Preparation provider", selection: Binding(get: { model.feedbackPreparationOverride?.provider ?? model.analysisProvider }, set: { provider in
                        model.feedbackPreparationOverride = .init(provider: provider, modelID: provider == .openAI ? "gpt-6-luna" : "")
                    })) {
                        ForEach(AnalysisProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    ProviderModelPicker(title: "Preparation model", provider: model.modelConfiguration.feedbackPreparationConfiguration.analysisProvider,
                        value: Binding(get: { model.feedbackPreparationOverride?.modelID ?? "" }, set: { model.feedbackPreparationOverride?.modelID = $0 }),
                        models: model.providerModels[model.modelConfiguration.feedbackPreparationConfiguration.analysisProvider] ?? [])
                    effortPicker(title: "Preparation reasoning", selection: Binding(get: { model.feedbackPreparationOverride?.effort ?? .medium }, set: { model.feedbackPreparationOverride?.effort = $0 }), provider: model.modelConfiguration.feedbackPreparationConfiguration.analysisProvider)
                }
                Text("Luna suggestions never merge or remove issues without review.").font(.caption).foregroundStyle(.secondary)
            }
            JamIntegrationSettingsSection(model: model.jamSettings)
            ForEach([AnalysisProvider.claude, .deepSeek].filter {
                $0 == model.analysisProvider ||
                $0 == model.taskConfiguration.analysisProvider ||
                $0 == model.modelConfiguration.feedbackPreparationConfiguration.analysisProvider ||
                $0 == model.documentationAnalysisOverride?.provider ||
                $0 == model.reviewAnalysisOverride?.provider
            }, id: \.self) { provider in
                CloudProviderSettingsSection(model: model, provider: provider)
            }
            if model.checkingCloudProvider || !model.providerCheckMessage.isEmpty {
                Section("Model check") {
                    Text(model.providerCheckMessage).font(.caption).textSelection(.enabled)
                    if model.checkingCloudProvider {
                        ProgressView().controlSize(.small)
                        Button("Cancel model check") { model.providerCheckTask?.cancel() }
                    }
                }
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
            if model.analysisProvider == .lmStudio || model.taskConfiguration.analysisProvider == .lmStudio ||
                model.modelConfiguration.feedbackPreparationConfiguration.analysisProvider == .lmStudio ||
                model.documentationAnalysisOverride?.provider == .lmStudio || model.reviewAnalysisOverride?.provider == .lmStudio {
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
            if model.transcriptionProvider == .openAI || model.analysisProvider == .openAI ||
                model.taskConfiguration.analysisProvider == .openAI ||
                model.modelConfiguration.feedbackPreparationConfiguration.analysisProvider == .openAI ||
                model.documentationAnalysisOverride?.provider == .openAI || model.reviewAnalysisOverride?.provider == .openAI {
            Section("OpenAI") {
                SecureField("API key", text: apiKeyBinding)
                TextField("Transcription model", text: $model.transcriptionModel)
                TextField("Analysis model", text: $model.analysisModel)
                if model.analysisProvider == .openAI { modelActions(configuration: model.modelConfiguration) }
                HStack {
                    if model.credentialState == .loading { ActivityIndicator(fraction: nil) }
                    Label(model.credentialStatusText, systemImage: model.credentialStatusSystemImage)
                        .foregroundStyle(credentialStatusColor)
                    Spacer()
                    if model.shouldOfferCredentialUnlock {
                        Button("Unlock API key") { model.unlockAPIKey() }
                    } else if model.credentialState == .missing {
                        Button("Load saved key") { model.reloadSavedAPIKey() }
                            .disabled(!model.canReloadSavedAPIKey)
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

            DiagnosticsSettingsSection(model: model)

            Section("Agent connections") {
                Text("Each client starts its own local MCP process. The app can be closed after processing finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                configRow(name: "Codex", value: codexConfig)
                configRow(name: "Claude Code", value: jsonConfig)
                configRow(name: "Cursor", value: jsonConfig)
            }

        }
        .formStyle(.grouped)
        .padding(WorkspaceStyle.padding)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Settings", systemImage: "gearshape").font(.title2.bold())
                Text("Processing, providers, and agent connections").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(WorkspaceStyle.padding).background(.bar)
        }
        .disabled(model.isSavingSettings)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.settingsSaveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                HStack {
                    if model.isSavingSettings {
                        ProgressView().controlSize(.small)
                        Text("Saving settings…").foregroundStyle(.secondary)
                    } else if let copiedLabel {
                        Text("Copied \(copiedLabel)").foregroundStyle(.secondary)
                    }
                    Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save settings", systemImage: "checkmark.circle") {
                        Task {
                            if await model.saveSettings() {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isSavingSettings)
                }
            }
            .padding()
            .background(.bar)
        }
        .task { await model.refreshSpeechModelStatus() }
        .task(id: "\(model.transcriptionProvider.rawValue):\(model.analysisProvider.rawValue):\(model.taskConfiguration.analysisProvider.rawValue):\(model.lmStudioUsesToken)") {
            model.loadSettingsCredentials()
        }
    }

    private var videoCloudModel: Binding<String> {
        Binding(get: { model.analysisProvider == .claude ? model.claudeModel : model.deepSeekModel }, set: {
            if model.analysisProvider == .claude { model.claudeModel = $0 } else { model.deepSeekModel = $0 }
        })
    }
    private func modelActions(configuration: ModelConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if configuration.analysisProvider != .lmStudio {
                    Button("Refresh models", systemImage: "arrow.clockwise") { model.startProviderCheck(configuration: configuration, test: false) }
                }
                Button("Test model", systemImage: "checkmark.seal") { model.startProviderCheck(configuration: configuration, test: true) }
                    .disabled(configuration.selectedAnalysisModel.isEmpty)
            }.disabled(model.checkingCloudProvider || model.isProcessing)
            Text(configuration.analysisProvider == .lmStudio ? "Uses a synthetic image only; recording content is not sent." : "Test model makes an API call using a synthetic image. Provider charges may apply. Its tokens appear in AI Usage.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func effortPicker(title: String, selection: Binding<ReasoningEffort>, provider: AnalysisProvider) -> some View {
        if !supportedEfforts(for: provider).isEmpty {
            Picker(title, selection: selection) {
                ForEach(supportedEfforts(for: provider), id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        }
    }

    private func supportedEfforts(for provider: AnalysisProvider) -> [ReasoningEffort] {
        switch provider {
        case .openAI: ReasoningEffort.allCases
        case .claude: [.low, .medium, .high, .max]
        case .lmStudio, .deepSeek: []
        }
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
