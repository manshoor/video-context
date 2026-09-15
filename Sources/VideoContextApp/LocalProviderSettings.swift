import Foundation
import VideoContextCore

extension AppModel {
    func refreshSpeechModelStatus() async {
        guard let speechModels else { return }
        speechModelReady = (try? await speechModels.installedAssets()) != nil
        if speechModelReady { speechModelMessage = "Whisper Large v3 Turbo is downloaded and ready for local preparation." }
    }

    func downloadSpeechModel() {
        guard !isUIFixture, !isProcessing, !speechDownloadActive, let speechModels else { return }
        let downloadID = UUID()
        speechDownloadID = downloadID
        speechDownloadActive = true
        speechDownloadFraction = nil
        speechModelMessage = "Downloading Whisper Large v3 Turbo…"
        speechDownloadTask = Task { [weak self] in
            guard let owner = self else { return }
            do {
                try await speechModels.download { fraction in
                    Task { @MainActor [weak owner] in
                        guard let owner, owner.speechDownloadActive, owner.speechDownloadID == downloadID else { return }
                        owner.speechDownloadFraction = fraction
                    }
                }
                try Task.checkCancellation()
                await self?.refreshSpeechModelStatus()
            } catch is CancellationError {
                self?.speechModelMessage = "Speech model download stopped. Download again to finish setup."
            } catch {
                self?.speechModelMessage = "Speech model download failed: \(error.localizedDescription)"
            }
            self?.speechDownloadID = nil
            self?.speechDownloadActive = false
            self?.speechDownloadFraction = nil
            self?.speechDownloadTask = nil
        }
    }

    func editLocalToken(_ value: String) {
        localTokenRequestID += 1
        localTokenEdited = true
        lmStudioToken = value
        lmTokenState = value.isEmpty ? .missing : .ready
    }

    func saveLocalTokenIfEdited() async throws {
        guard localTokenEdited else { return }
        let id = localTokenRequestID
        let value = lmStudioToken
        do {
            if value.isEmpty { try await localTokenStore.remove() }
            else { try await localTokenStore.save(value) }
            guard id == localTokenRequestID else { return }
            localTokenEdited = false
            lmTokenState = value.isEmpty ? .missing : .ready
        } catch {
            if id == localTokenRequestID { lmTokenState = .failed(error.localizedDescription) }
            throw error
        }
    }

    func loadLocalToken(mode: APIKeyAccessMode) async {
        guard !isUIFixture else { return }
        localTokenRequestID += 1
        let id = localTokenRequestID
        lmTokenState = .loading
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: mode == .nonInteractive ? .seconds(3) : .seconds(30)) }
            catch { return }
            guard let self, self.localTokenRequestID == id else { return }
            self.localTokenRequestID += 1
            self.lmTokenState = .accessRequired
        }
        defer { timeout.cancel() }
        do {
            let token = try await localTokenStore.load(mode: mode)
            guard id == localTokenRequestID, !Task.isCancelled else { return }
            lmStudioToken = token ?? ""
            lmTokenState = lmStudioToken.isEmpty ? .missing : .ready
            if lmTokenState == .ready { resumeFirstIncompleteRecording() }
        } catch {
            guard id == localTokenRequestID else { return }
            lmTokenState = .accessRequired
        }
    }

    func startLocalModelCheck(testImage: Bool) {
        guard localCheckTask == nil else { return }
        localCheckTask = Task { [weak self] in
            await self?.checkLocalModel(testImage: testImage)
            self?.localCheckTask = nil
        }
    }

    func checkLocalModel(testImage: Bool) async {
        guard !checkingLocalModel, !isUIFixture else { return }
        let configuration = modelConfiguration.lmStudio
        let token = lmStudioUsesToken ? lmStudioToken : ""
        guard !lmStudioUsesToken || !token.isEmpty else {
            localConnectionMessage = "Enter or unlock the LM Studio token first."
            return
        }
        checkingLocalModel = true
        defer { checkingLocalModel = false }
        localConnectionMessage = testImage ? "Testing image reading and structured output…" : "Checking LM Studio…"
        do {
            let transport = localHTTP
            let service = LMStudioService(client: transport)
            let models = try await service.models(configuration: configuration, token: token)
            guard configuration == modelConfiguration.lmStudio, token == (lmStudioUsesToken ? lmStudioToken : "") else { localConnectionMessage = "Settings changed. Refresh models again."; return }
            localModels = models.filter(\.supportsVision)
            if testImage {
                let instance = try await service.loadedModel(configuration: configuration, token: token)
                var loaded = configuration; loaded.modelID = instance.id
                guard let imageURL = Bundle.main.url(forResource: "ModelProbe", withExtension: "jpg") ?? Bundle.module.url(forResource: "ModelProbe", withExtension: "jpg") else {
                    throw LocalProviderError.configuration("The bundled model-test image is missing. Rebuild the application.")
                }
                let request = try LMStudioRequestBuilder.analysis(configuration: loaded, token: token,
                    prompt: "Read the code printed in this image. Return only that code in the markdown field.", images: [Data(contentsOf: imageURL)], maxTokens: 2_048)
                let result = try await transport.data(for: request)
                try LMStudioResponseDecoder.validate(result)
                let markdown = try LMStudioResponseDecoder.markdown(result.data)
                guard markdown.contains("VC-TEST-42") else { throw LocalProviderError.configuration("The model returned JSON but did not read the test image correctly. Try another vision model.") }
                guard configuration == modelConfiguration.lmStudio else { localConnectionMessage = "Settings changed. Test the selected model again."; return }
                localConnectionMessage = "Image input and structured output passed · \(instance.config.contextLength.formatted()) token context."
            } else {
                localConnectionMessage = localModels.isEmpty ? "No vision models found. Download and load Qwen3.8 27B or Gemma 4 12B QAT in LM Studio." : "Found \(localModels.count) vision models. Select a loaded model, then test it."
            }
        } catch {
            if Task.isCancelled { localConnectionMessage = "Model check cancelled." }
            else if configuration == modelConfiguration.lmStudio { localConnectionMessage = error.localizedDescription }
        }
    }
}
