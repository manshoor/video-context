import Foundation
import VideoContextCore

extension AppModel {
    func applyAccuracyProfile() {
        analysisProvider = .openAI
        analysisModel = "gpt-6-sol"
        analysisReasoningEffort = .high
        taskAnalysisOverride = .init(provider: .openAI, modelID: "gpt-6-astra", effort: .high)
        documentationAnalysisOverride = .init(provider: .openAI, modelID: "gpt-6-astra", effort: .high)
        reviewAnalysisOverride = .init(provider: .claude, modelID: "claude-opus-5-5", effort: .high)
    }

    func credentialValue(for provider: AnalysisProvider) -> String {
        switch provider {
        case .openAI: apiKey
        case .lmStudio: lmStudioUsesToken ? lmStudioToken : ""
        case .claude: claudeCredential.value
        case .deepSeek: deepSeekCredential.value
        }
    }
    func credentialReady(for provider: AnalysisProvider) -> Bool {
        switch provider {
        case .openAI: credentialState == .ready && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lmStudio: !lmStudioUsesToken || (lmTokenState == .ready && !lmStudioToken.isEmpty)
        case .claude: claudeCredential.ready
        case .deepSeek: deepSeekCredential.ready
        }
    }
    func loadProviderCredential(_ provider: AnalysisProvider, mode: APIKeyAccessMode, retryAccessRequired: Bool = false) async {
        guard !isUIFixture else { return }
        let credential = provider == .claude ? claudeCredential : deepSeekCredential
        await credential.load(mode: mode, retryAccessRequired: retryAccessRequired)
        diagnosticCredentialChanged(credential.state)
        if credential.ready { resumeFirstIncompleteRecording() }
    }
    func transport(for provider: AnalysisProvider) -> AnyHTTPDataLoader {
        if provider == .lmStudio { return localHTTP }
        if provider == .openAI { return cloudHTTP }
        return AnyHTTPDataLoader(DiagnosticHTTPClient(base: providerHTTP, provider: provider.identity))
    }
    var taskConfiguration: ModelConfiguration { modelConfiguration.taskConfiguration }
    func startProviderCheck(configuration: ModelConfiguration, test: Bool) {
        guard !checkingCloudProvider, !isProcessing, !isUIFixture else { return }
        let provider = configuration.analysisProvider, key = credentialValue(for: configuration.analysisProvider)
        guard credentialReady(for: provider) else { providerCheckMessage = "Enter or unlock the \(provider.label) key first."; return }
        checkingCloudProvider = true
        providerCheckMessage = test ? "Testing image input and structured output…" : "Loading available models…"
        providerCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkingCloudProvider = false; self.providerCheckTask = nil }
            do {
                if test {
                    try await self.withUsageRun(operation: .modelTest, videoID: nil, configuration: configuration) {
                        let url = Bundle.main.url(forResource: "ModelProbe", withExtension: "jpg") ?? Bundle.module.url(forResource: "ModelProbe", withExtension: "jpg")!
                        var resolved = configuration
                        if provider == .lmStudio {
                            let instance = try await LMStudioService(client: self.localHTTP).loadedModel(configuration: configuration.lmStudio, token: key)
                            resolved.lmStudio.modelID = instance.id
                        }
                        let client = UsageRecordingClient(base: self.transport(for: provider), provider: provider.identity, model: configuration.selectedAnalysisModel, stage: .modelTest)
                        let request = try AnalysisAdapter.request(configuration: resolved, credential: key,
                            prompt: "Read the code printed in this image. Return only that code in the markdown field.", images: [Data(contentsOf: url)], maxTokens: 2048)
                        let output = try AnalysisAdapter.markdown(try await client.data(for: request), provider: provider)
                        guard output.contains("VC-TEST-42") else { throw LocalProviderError.configuration("The model returned structured output but did not read the test image correctly.") }
                        try Task.checkCancellation()
                    }
                    self.providerCheckMessage = "\(provider.label) · \(configuration.selectedAnalysisModel): image input and structured output passed."
                } else {
                    let url: String
                    switch provider {
                    case .claude: url = "https://api.anthropic.com/v1/models"
                    case .deepSeek: url = "https://api.deepseek.com/models"
                    case .openAI: url = "https://api.openai.com/v1/models"
                    case .lmStudio: throw LocalProviderError.configuration("Use Refresh models in the LM Studio section.")
                    }
                    var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 30
                    if provider == .claude { request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
                    else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                    let result = try await self.transport(for: provider).data(for: request)
                    guard (200..<300).contains(result.statusCode), let root = try JSONSerialization.jsonObject(with: result.data) as? [String: Any], let rows = root["data"] as? [[String: Any]] else { throw LocalProviderError.unavailable("Could not list \(provider.label) models. Check credentials and availability.") }
                    let ids = rows.compactMap { $0["id"] as? String }.filter { provider != .deepSeek || ["deepseek-flash", "deepseek-v4-flash-vision-exp"].contains($0) }.sorted()
                    self.providerModels[provider] = ids
                    self.providerCheckMessage = ids.isEmpty ? "No compatible models were listed. Check this account’s model access." : "Available models loaded. Test the selected model before using recording evidence."
                }
            } catch { self.providerCheckMessage = Task.isCancelled ? "Model check cancelled." : error.localizedDescription }
        }
    }
}
