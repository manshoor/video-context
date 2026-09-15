import Foundation
import VideoContextCore
import WhisperKit

/// Owns speech assets separately from recording artifacts. A manifest is published only after
/// both the model and tokenizer have been downloaded and the tokenizer can be read locally.
actor SpeechModelManager {
    let root: URL
    init(root: URL) { self.root = root }
    private var manifestURL: URL { root.appending(path: "speech-model.json") }
    struct Assets: Codable, Sendable {
        let modelFolder: URL
        let tokenizerFolder: URL
    }

    func installedAssets() throws -> Assets {
        guard let data = try? Data(contentsOf: manifestURL), let assets = try? JSONDecoder().decode(Assets.self, from: data),
              FileManager.default.fileExists(atPath: assets.modelFolder.appending(path: "AudioEncoder.mlmodelc").path),
              FileManager.default.fileExists(atPath: assets.modelFolder.appending(path: "TextDecoder.mlmodelc").path),
              FileManager.default.fileExists(atPath: assets.tokenizerFolder.appending(path: "tokenizer.json").path),
              FileManager.default.fileExists(atPath: assets.tokenizerFolder.appending(path: "tokenizer_config.json").path) else {
            throw LocalProviderError.configuration("Download the local speech model in Settings before transcribing. Saved transcripts can still be reused.")
        }
        return assets
    }

    func download(progress: @escaping @Sendable (Double?) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(variant: ModelConfiguration.localSpeechModel, downloadBase: root, progressCallback: { value in
            progress(value.totalUnitCount > 0 ? value.fractionCompleted : nil)
        })
        try Task.checkCancellation()
        progress(nil)
        let hub = HubApiWrapper(downloadBase: root)
        _ = try await AutoTokenizerWrapper.from(pretrained: "openai/whisper-large-v3", hubApi: hub)
        let tokenizerFolder = hub.localRepoLocation(HubApiWrapper.Repo(id: "openai/whisper-large-v3"))
        _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
        try Task.checkCancellation()
        let assets = Assets(modelFolder: folder, tokenizerFolder: tokenizerFolder)
        try JSONEncoder().encode(assets).write(to: manifestURL, options: .atomic)
    }
}

/// All SDK state stays inside one worker actor; no model or tokenizer crosses onto the UI actor.
actor LocalWhisperTranscriber: Transcribing {
    private let assets: SpeechModelManager.Assets
    private let store: VideoContextStore?
    private let progress: ProcessingProgressHandler?
    private var kit: WhisperKit?
    init(assets: SpeechModelManager.Assets, store: VideoContextStore? = nil, progress: ProcessingProgressHandler? = nil) {
        self.assets = assets; self.store = store; self.progress = progress
    }

    func transcribe(audioURL: URL, videoID: String, chunkStart: TimeInterval) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        if kit == nil {
            await progress?(.init(stage: .transcribing, detail: "Preparing speech model"))
            // Load the tokenizer using the local-only factory. WhisperKit's convenience loader
            // otherwise falls back to a network download when a local tokenizer is corrupt.
            let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: assets.tokenizerFolder)
            let worker = try await WhisperKit(WhisperKitConfig(model: ModelConfiguration.localSpeechModel,
                modelFolder: assets.modelFolder.path, tokenizerFolder: assets.tokenizerFolder,
                verbose: false, prewarm: false, load: false, download: false))
            worker.tokenizer = try OfflineWhisperTokenizer(tokenizer: tokenizer)
            // The selected Turbo model is multilingual. Preinstalling the tokenizer bypasses
            // the SDK convenience method that ordinarily sets this decoder flag.
            worker.textDecoder.isModelMultilingual = true
            try await worker.loadModels()
            try Task.checkCancellation()
            kit = worker
            await progress?(.init(stage: .transcribing, detail: "Transcribing locally"))
        }
        guard let kit else { throw LocalProviderError.configuration("The local speech model could not be loaded.") }
        let results = try await kit.transcribe(audioPath: audioURL.path,
            decodeOptions: DecodingOptions(task: .transcribe, detectLanguage: true, skipSpecialTokens: true,
                withoutTimestamps: false, concurrentWorkerCount: 1),
            callback: { _ in !Task.isCancelled })
        try Task.checkCancellation()
        let segments = results.flatMap(\.segments).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            TranscriptSegment(videoID: videoID, start: chunkStart + Double($0.start), end: chunkStart + Double($0.end), originalText: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try await store?.recordAPIUsage(APIUsageRecord(videoID: videoID, stage: .transcription,
            model: ModelConfiguration.localSpeechModel, provider: .localWhisper,
            audioSeconds: results.flatMap(\.segments).map { Double($0.end) }.max()))
        return segments
    }

    func releaseResources() async {
        await kit?.unloadModels()
        kit = nil
    }
}
