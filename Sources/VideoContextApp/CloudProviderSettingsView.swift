import SwiftUI
import VideoContextCore

struct CloudProviderSettingsSection: View {
    @Bindable var model: AppModel
    let provider: AnalysisProvider
    private var credential: ProviderCredential { provider == .claude ? model.claudeCredential : model.deepSeekCredential }
    var body: some View {
        Section(provider.label) {
            SecureField("\(provider.label) API key", text: Binding(get: { credential.value }, set: { credential.edit($0) }))
            HStack {
                if credential.state == .loading { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(credential.ready ? .green : .secondary)
                Spacer()
                Button("Unlock \(provider.label) key") { Task { await model.loadProviderCredential(provider, mode: .interactive) } }
            }
            Text("Saved separately in macOS Keychain. Selecting this provider sends transcript passages and selected screenshots to \(provider.label).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var status: String {
        switch credential.state {
        case .loading: "Checking Keychain…"
        case .ready: "API key is ready."
        case .missing: "Enter an API key."
        case .accessRequired: "Unlock Keychain to load the saved key."
        case .failed: "Keychain access failed. Unlock the key or enter it again."
        }
    }
}

struct ProviderModelPicker: View {
    let title: String
    let provider: AnalysisProvider
    @Binding var value: String
    let models: [String]
    var body: some View {
        VStack(alignment: .leading) {
            if !models.isEmpty {
                Picker(title, selection: $value) {
                    Text("Choose a model").tag("")
                    if !value.isEmpty && !models.contains(value) { Text(value).tag(value) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField(models.isEmpty ? title : "Model ID", text: $value)
            if provider == .deepSeek { Text("Use deepseek-flash for screenshot evidence.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
