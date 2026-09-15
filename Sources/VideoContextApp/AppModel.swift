import AppKit
import Foundation
import Observation
import VideoContextCore

@MainActor
@Observable
final class AppModel {
    var videos: [VideoRecord] = []
    var selectedVideoID: String?
    var snapshot: VideoSnapshot?
    var taskLibrary: TaskLibrarySnapshot?
    var taskGenerationMessage: String?
    @ObservationIgnored var taskGenerationTask: Task<Void, Never>?
    var errorMessage: String?
    var processingVideoID: String?
    var seekRequest: SeekRequest?
    var processingProgress: ProcessingProgress?
    var processingElapsedSeconds = 0
    var credentialState: CredentialState = .loading
    var lastCopiedLabel: String?
    var activity: AppActivity? {
        didSet { dockActivity.update(activity) }
    }
    var savingFrameVideoID: String?
    let isUIFixture: Bool

    var ytDLPPath: String
    var ffmpegPath: String
    var ffprobePath: String
    var transcriptionModel: String
    var analysisModel: String
    var apiKey: String
    var transcriptionProvider: TranscriptionProvider
    var analysisProvider: AnalysisProvider
    var lmStudioURL: String
    var lmStudioModelID: String
    var lmStudioUsesToken: Bool
    var lmStudioToken = ""
    var lmTokenState: CredentialState = .missing
    var localModels: [LMStudioModel] = []
    var localConnectionMessage = "Start LM Studio’s server in the Developer tab, then refresh models."
    var checkingLocalModel = false
    var speechModelReady = false
    var speechDownloadActive = false
    var speechDownloadFraction: Double?
    var speechModelMessage = "Download Whisper Large v3 Turbo once to transcribe locally."
    @ObservationIgnored let cloudHTTP: AnyHTTPDataLoader
    @ObservationIgnored let localHTTP: AnyHTTPDataLoader
    @ObservationIgnored let localTokenStore: any APIKeyStoring
    @ObservationIgnored var localTokenEdited = false
    @ObservationIgnored var localTokenRequestID = 0
    @ObservationIgnored var speechDownloadID: UUID?
    @ObservationIgnored var localCheckTask: Task<Void, Never>?
    @ObservationIgnored var speechDownloadTask: Task<Void, Never>?
    @ObservationIgnored var speechModels: SpeechModelManager?

    var modelConfiguration: ModelConfiguration {
        ModelConfiguration(transcriptionModel: transcriptionModel, analysisModel: analysisModel,
            transcriptionProvider: transcriptionProvider, analysisProvider: analysisProvider,
            lmStudio: .init(baseURL: lmStudioURL, modelID: lmStudioModelID))
    }
    var selectionNeedsOpenAI: Bool {
        modelConfiguration.requiresOpenAI(transcriptNeeded: snapshot?.transcript.isEmpty ?? true)
    }

    @ObservationIgnored let paths: LibraryPaths?
    @ObservationIgnored let store: VideoContextStore?
    @ObservationIgnored private let keyStore: any APIKeyStoring
    @ObservationIgnored private let credentialLoader: CredentialLoader
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var credentialLoadTask: Task<Void, Never>?
    @ObservationIgnored private var credentialTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var didAttemptResume = false
    @ObservationIgnored private var credentialRequestID = 0
    @ObservationIgnored private var apiKeyWasEdited = false
    @ObservationIgnored private let dockActivity: DockActivityController
    @ObservationIgnored private let mediaImports: MediaImportOperations
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importRequestID: String?
    @ObservationIgnored private var clipboardTask: Task<Void, Never>?

    init(keyStore: any APIKeyStoring = KeychainAPIKeyStore(), localTokenStore: any APIKeyStoring = KeychainAPIKeyStore(account: "lm-studio-token"),
         cloudHTTP: any HTTPDataLoading = URLSessionHTTPClient(), localHTTP: any HTTPDataLoading = LoopbackHTTPClient(), libraryRoot: URL? = nil,
         mediaImports: MediaImportOperations = .live, showsDockActivity: Bool = true, isUIFixture: Bool = false) {
        self.isUIFixture = isUIFixture
        self.mediaImports = mediaImports
        dockActivity = DockActivityController(enabled: showsDockActivity)
        self.cloudHTTP = AnyHTTPDataLoader(cloudHTTP)
        self.localHTTP = AnyHTTPDataLoader(localHTTP)
        self.localTokenStore = localTokenStore
        self.keyStore = keyStore
        credentialLoader = CredentialLoader(store: keyStore)
        let preferences = StoredPreferences.load()
        ytDLPPath = preferences.toolchain.ytDLP
        ffmpegPath = preferences.toolchain.ffmpeg
        ffprobePath = preferences.toolchain.ffprobe
        transcriptionModel = preferences.models.transcriptionModel
        analysisModel = preferences.models.analysisModel
        transcriptionProvider = preferences.models.transcriptionProvider
        analysisProvider = preferences.models.analysisProvider
        lmStudioURL = preferences.models.lmStudio.baseURL
        lmStudioModelID = preferences.models.lmStudio.modelID
        lmStudioUsesToken = preferences.lmStudioUsesToken ?? false
        apiKey = ""

        var loadedPaths: LibraryPaths?
        var loadedStore: VideoContextStore?
        var loadError: String?
        do {
            let root = libraryRoot ?? (isUIFixture ? FileManager.default.temporaryDirectory.appending(path: "VideoContextUI-\(UUID())") : nil)
            let libraryPaths = try root.map { try LibraryPaths(root: $0) } ?? LibraryPaths.applicationSupport()
            loadedPaths = libraryPaths
            loadedStore = try VideoContextStore(databaseURL: libraryPaths.database)
        } catch {
            loadError = "The local library could not be opened: \(error.localizedDescription)"
        }
        speechModels = loadedPaths.map { SpeechModelManager(root: $0.root.appending(path: "models")) }
        paths = loadedPaths
        store = loadedStore
        errorMessage = loadError
    }

    var isProcessing: Bool { activity != nil }

    var credentialStatusText: String {
        switch credentialState {
        case .loading: "Checking Keychain for the OpenAI API key…"
        case .ready: "OpenAI API key is ready."
        case .missing: "Enter an OpenAI API key before processing."
        case .accessRequired: "Unlock the login Keychain to resume processing."
        case .failed(let message): "API key access failed: \(message)"
        }
    }

    var credentialStatusSystemImage: String {
        switch credentialState {
        case .loading: "key.horizontal"
        case .ready: "checkmark.circle.fill"
        case .missing: "key.slash"
        case .accessRequired: "lock.open"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var shouldOfferCredentialUnlock: Bool {
        switch credentialState {
        case .accessRequired, .failed: true
        default: false
        }
    }

    var dependencyStatus: [(name: String, path: String, available: Bool)] {
        let manager = FileManager.default
        return [
            ("yt-dlp", ytDLPPath, manager.isExecutableFile(atPath: ytDLPPath)),
            ("ffmpeg", ffmpegPath, manager.isExecutableFile(atPath: ffmpegPath)),
            ("ffprobe", ffprobePath, manager.isExecutableFile(atPath: ffprobePath))
        ]
    }

    var mcpExecutablePath: String {
        let ownExecutable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return ownExecutable.deletingLastPathComponent().appending(path: "video-context-mcp").path
    }

    func loadLibrary(resume: Bool = false) async {
        guard let store else { return }
        do {
            videos = try await store.listVideos(limit: 100).items
            if selectedVideoID == nil { selectedVideoID = videos.first?.id }
            await loadSelection()
            if resume, didAttemptResume == false {
                didAttemptResume = true
                if isUIFixture {
                    credentialState = .ready
                    await installUIFixture()
                } else {
                    await refreshSpeechModelStatus()
                    if transcriptionProvider == .openAI || analysisProvider == .openAI {
                        startCredentialLoad(mode: .nonInteractive)
                    } else {
                        credentialState = .missing
                        if !lmStudioUsesToken { resumeFirstIncompleteRecording() }
                    }
                    if lmStudioUsesToken { Task { await loadLocalToken(mode: .nonInteractive) } }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSelection() async {
        guard let store, let selectedVideoID else {
            snapshot = nil
            taskLibrary = nil
            return
        }
        do {
            let loaded = try await store.videoSnapshot(id: selectedVideoID)
            guard self.selectedVideoID == selectedVideoID else { return }
            guard let loaded else { snapshot = nil; taskLibrary = nil; return }
            let tasks = try await store.taskSnapshot(videoID: selectedVideoID)
            guard self.selectedVideoID == selectedVideoID else { return }
            snapshot = loaded
            taskLibrary = tasks
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importLocal(_ source: URL) async {
        guard !isProcessing, let paths, let store else { return }
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        let videoID = VideoRecord(title: "", source: .localFile, sourceValue: "", mediaRelativePath: "").id
        activity = AppActivity(videoID: videoID, recordingTitle: source.deletingPathExtension().lastPathComponent, phase: .copying)
        let task = Task {
          do {
            let destination = try await mediaImports.local(source, videoID, paths)
            let record = VideoRecord(
                id: videoID,
                title: source.deletingPathExtension().lastPathComponent,
                source: .localFile,
                sourceValue: source.path,
                mediaRelativePath: paths.relativePath(for: destination)
            )
            try await store.createVideo(record)
            selectedVideoID = videoID
            await loadLibrary()
            try Task.checkCancellation()
            activity = nil
            beginProcessing(videoID: videoID)
          } catch is CancellationError {
            try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Import stopped. The completed copy is saved; resume when ready.")
            activity = nil
            await loadLibrary()
          } catch {
            activity = nil
            errorMessage = error.localizedDescription
          }
        }
        importTask = task
        importRequestID = videoID
        await task.value
        if importRequestID == videoID { importTask = nil; importRequestID = nil }
    }

    func importOnline(_ value: String) async {
        guard !isProcessing else { return }
        guard let paths, let store,
              let source = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = MediaImportError.unsupportedURL.localizedDescription
            return
        }
        let videoID = VideoRecord(title: "", source: .onlineURL, sourceValue: "", mediaRelativePath: "").id
        let provisionalPath = "videos/\(videoID)/video.mp4"
        let title = source.host.map { "Recording from \($0)" } ?? "Online recording"
        let record = VideoRecord(
            id: videoID,
            title: title,
            source: .onlineURL,
            sourceValue: source.absoluteString,
            mediaRelativePath: provisionalPath
        )
        activity = AppActivity(videoID: videoID, recordingTitle: title, phase: .downloading)
        let task = Task {
          do {
            try await store.createVideo(record)
            selectedVideoID = videoID
            await loadLibrary()
            _ = try await mediaImports.online(source, videoID, paths, ytDLPPath)
            try Task.checkCancellation()
            activity = nil
            beginProcessing(videoID: videoID)
          } catch is CancellationError {
            try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Download cancelled. Import the link again to retry.")
            activity = nil
            await loadLibrary()
          } catch {
            try? await store.updateVideo(id: videoID, status: .failed, errorMessage: error.localizedDescription)
            activity = nil
            errorMessage = error.localizedDescription
            await loadLibrary()
          }
        }
        importTask = task
        importRequestID = videoID
        await task.value
        if importRequestID == videoID { importTask = nil; importRequestID = nil }
    }

    func waitForProcessing() async { await processingTask?.value }

    func beginProcessing(videoID: String) {
        guard !isProcessing, let paths, let store else { return }
        if isUIFixture { startUIFixtureActivity(videoID: videoID); return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard analysisProvider != .openAI || (credentialState == .ready && !key.isEmpty) else {
            errorMessage = "Unlock or enter an OpenAI API key in Settings before processing this recording."
            return
        }
        let toolchain = MediaToolchain(ytDLP: ytDLPPath, ffmpeg: ffmpegPath, ffprobe: ffprobePath)
        let models = modelConfiguration
        let localToken = lmStudioToken
        let needsLocalToken = lmStudioUsesToken
        processingVideoID = videoID
        activity = AppActivity(videoID: videoID, recordingTitle: videos.first(where: { $0.id == videoID })?.title ?? "Recording", phase: .processing(.inspecting))
        processingProgress = nil
        processingElapsedSeconds = 0
        processingTask = Task { [weak self] in
            guard let self else { return }
            let progress: ProcessingProgressHandler = { [weak self] progress in
                await self?.receiveProcessingProgress(progress)
            }
            do {
                guard let initial = try await store.videoSnapshot(id: videoID) else { throw VideoContextStoreError.videoNotFound(videoID) }
                let transcriptNeeded = initial.transcript.isEmpty
                guard !models.requiresOpenAI(transcriptNeeded: transcriptNeeded) || (self.credentialState == .ready && !key.isEmpty) else {
                    throw OpenAIClientError.missingAPIKey
                }
                let cloudClient = APIUsageRecordingClient(base: self.cloudHTTP, store: store, videoID: videoID,
                    transcriptionModel: models.transcriptionModel, analysisModel: models.analysisModel)
                let transcriber: any Transcribing
                if !transcriptNeeded {
                    transcriber = SavedTranscriptOnly()
                } else if models.transcriptionProvider == .localWhisper {
                    guard !self.speechDownloadActive else { throw LocalProviderError.configuration("Wait for the speech model download to finish before transcribing locally.") }
                    guard let manager = self.speechModels else { throw LocalProviderError.configuration("The local model directory is unavailable.") }
                    transcriber = LocalWhisperTranscriber(assets: try await manager.installedAssets(), store: store, progress: progress)
                } else {
                    transcriber = OpenAITranscriber(client: cloudClient, apiKey: key, model: models.transcriptionModel)
                }
                let generator: any BriefGenerating
                var analysisID = models.analysisModel
                if models.analysisProvider == .lmStudio {
                    guard !needsLocalToken || !localToken.isEmpty else { throw LocalProviderError.configuration("Unlock or enter the LM Studio token in Settings.") }
                    await progress(.init(stage: .inspecting, detail: "Checking LM Studio"))
                    let transport = self.localHTTP
                    let instance = try await LMStudioService(client: transport).loadedModel(configuration: models.lmStudio, token: needsLocalToken ? localToken : "")
                    try Task.checkCancellation()
                    var local = models.lmStudio
                    local.modelID = instance.id
                    analysisID = instance.id
                    let client = APIUsageRecordingClient(base: transport, store: store, videoID: videoID,
                        transcriptionModel: models.transcriptionModel, analysisModel: instance.id, provider: .lmStudio)
                    generator = LMStudioBriefGenerator(client: client, configuration: local,
                        token: needsLocalToken ? localToken : "", contextLength: instance.config.contextLength)
                } else {
                    generator = OpenAIBriefGenerator(client: cloudClient, apiKey: key, model: models.analysisModel)
                }
                try Task.checkCancellation()
                let pipeline = VideoProcessingPipeline(store: store, paths: paths,
                    media: FFmpegMediaProcessor(toolchain: toolchain, runner: ProcessRunner()), transcriber: transcriber,
                    textRecognizer: VisionTextRecognizer(), briefGenerator: generator, progress: progress,
                    transcriptionIdentity: ProviderIdentity(provider: models.transcriptionProvider == .localWhisper ? .localWhisper : .openAI,
                        model: models.transcriptionProvider == .localWhisper ? ModelConfiguration.localSpeechModel : models.transcriptionModel),
                    analysisIdentity: ProviderIdentity(provider: models.analysisProvider == .lmStudio ? .lmStudio : .openAI, model: analysisID))
                try await pipeline.process(videoID: videoID)
            } catch is CancellationError {
                try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Processing was cancelled.")
            } catch {
                self.errorMessage = error.localizedDescription
                try? await store.markIncomplete(videoID: videoID, error: error.localizedDescription)
            }
            self.processingVideoID = nil
            self.activity = nil
            self.processingProgress = nil
            self.processingElapsedSeconds = 0
            self.statusTask?.cancel()
            await self.loadLibrary()
        }
        statusTask = Task { [weak self] in
            while let self, self.processingVideoID != nil, Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                if let progress = self.processingProgress {
                    self.processingElapsedSeconds = max(0, Int(Date().timeIntervalSince(progress.stageStartedAt)))
                }
                await self.loadLibrary()
            }
        }
    }

    func cancelProcessing() {
        activity?.isCancelling = true
        taskGenerationTask?.cancel()
        importTask?.cancel()
        processingTask?.cancel()
    }

    func correctTranscript(segmentID: String, text: String) async {
        guard let store else { return }
        do {
            try await store.correctTranscript(segmentID: segmentID, correctedText: text)
            await loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveBrief(_ markdown: String, videoID: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.updateBrief(videoID: videoID, markdown: markdown)
            await loadLibrary()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addManualFrame(at timestamp: TimeInterval) async {
        guard savingFrameVideoID == nil, let store, let paths, let snapshot else { return }
        savingFrameVideoID = snapshot.video.id
        defer { savingFrameVideoID = nil }
        do {
            let videoURL = paths.absoluteURL(relativePath: snapshot.video.mediaRelativePath)
            let frame = try await VideoFrameProvider(ffmpegPath: ffmpegPath).frame(videoURL: videoURL, timestamp: timestamp)
            let directory = try paths.framesDirectory(id: snapshot.video.id)
            let filename = "manual-\(Int((frame.actualTimestamp * 1_000).rounded()))-\(UUID().uuidString).jpg"
            let imageURL = directory.appending(path: filename)
            try frame.data.write(to: imageURL, options: .atomic)
            let ocr = try await VisionTextRecognizer().recognizeText(in: imageURL)
            try await store.addEvidence(EvidenceItem(
                videoID: snapshot.video.id,
                timestamp: frame.actualTimestamp,
                imageRelativePath: paths.relativePath(for: imageURL),
                ocrText: ocr,
                origin: .manual
            ))
            await loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func imageURL(for evidence: EvidenceItem) -> URL? {
        paths?.absoluteURL(relativePath: evidence.imageRelativePath)
    }

    func mediaURL(for video: VideoRecord) -> URL? {
        paths?.absoluteURL(relativePath: video.mediaRelativePath)
    }

    func requestSeek(to timestamp: TimeInterval) {
        seekRequest = SeekRequest(timestamp: timestamp)
    }

    func contextState(for video: VideoRecord) -> AgentHandoffState {
        if let activity, activity.videoID == video.id {
            switch activity.phase {
            case .copying, .downloading: return .importing(stage: activity.phase.title)
            case .processing: break
            }
        }
        return AgentHandoffState.effective(
            video: video,
            isActive: processingVideoID == video.id,
            progress: processingVideoID == video.id ? processingProgress : nil,
            elapsedSeconds: processingVideoID == video.id ? processingElapsedSeconds : 0
        )
    }

    func processingStatusText(for video: VideoRecord) -> String {
        contextState(for: video).description
    }

    func processingProgressText(for video: VideoRecord) -> String? {
        guard processingVideoID == video.id, let progress = processingProgress else { return nil }
        let elapsed = "\(processingElapsedSeconds)s elapsed"
        if let completed = progress.completed, let total = progress.total {
            switch progress.stage {
            case .recognizingText: return "Reading screenshots: \(completed) of \(total) · \(elapsed)"
            case .analyzing: return "Building analysis: \(completed) of \(total) · \(elapsed)"
            case .transcribing: return "Transcribing audio: \(completed) of \(total) · \(elapsed)"
            default: return "\(progress.stage.displayName) · \(completed) of \(total) · \(elapsed)"
            }
        }
        return "\(progress.stage.displayName) · \(elapsed)"
    }

    func copyContextMessage() {
        guard let video = snapshot?.video else { return }
        copy(AgentHandoff.message(video: video, state: contextState(for: video)))
        confirmCopy("Context message copied")
    }

    func copyContextID() {
        guard let id = snapshot?.video.id else { return }
        copy(id)
        confirmCopy("Context ID copied")
    }

    func confirmCopy(_ label: String) {
        clipboardTask?.cancel()
        lastCopiedLabel = label
        clipboardTask = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            lastCopiedLabel = nil
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func userEditedAPIKey(_ value: String) {
        credentialRequestID += 1
        credentialLoadTask?.cancel()
        credentialTimeoutTask?.cancel()
        apiKey = value
        apiKeyWasEdited = true
        credentialState = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .ready
        Task { await credentialLoader.invalidatePendingLoad() }
    }

    func unlockAPIKey() {
        startCredentialLoad(mode: .interactive)
    }

    func saveSettings() async {
        guard !isUIFixture else { return }
        do {
            let toolchain = MediaToolchain(ytDLP: ytDLPPath, ffmpeg: ffmpegPath, ffprobe: ffprobePath)
            let models = modelConfiguration
            StoredPreferences(toolchain: toolchain, models: models, lmStudioUsesToken: lmStudioUsesToken).save()
            do { try await saveLocalTokenIfEdited() }
            catch { errorMessage = "Could not save the LM Studio token: \(error.localizedDescription)"; return }
            switch CredentialSaveAction.resolve(value: apiKey, wasEdited: apiKeyWasEdited) {
            case .none:
                break
            case .remove:
                try await keyStore.remove()
                credentialState = .missing
                apiKeyWasEdited = false
            case .save(let key):
                try await keyStore.save(key)
                apiKey = key
                credentialState = .ready
                apiKeyWasEdited = false
            }
            if (transcriptionProvider == .openAI || analysisProvider == .openAI) && apiKey.isEmpty && !apiKeyWasEdited {
                startCredentialLoad(mode: .nonInteractive)
            }
            resumeFirstIncompleteRecording()
        } catch {
            credentialState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func receiveProcessingProgress(_ progress: ProcessingProgress) {
        processingProgress = progress
        activity?.update(progress)
        processingElapsedSeconds = max(0, Int(Date().timeIntervalSince(progress.stageStartedAt)))
    }

    private func startCredentialLoad(mode: APIKeyAccessMode) {
        guard !isUIFixture else { return }
        credentialRequestID += 1
        let requestID = credentialRequestID
        credentialLoadTask?.cancel()
        credentialTimeoutTask?.cancel()
        credentialState = .loading

        credentialLoadTask = Task { [weak self, credentialLoader] in
            await credentialLoader.invalidatePendingLoad()
            let result = await credentialLoader.load(mode: mode)
            guard let self, self.credentialRequestID == requestID, Task.isCancelled == false else { return }
            self.credentialTimeoutTask?.cancel()
            self.applyCredentialLoadResult(result)
        }

        let timeout: Duration = mode == .nonInteractive ? .seconds(3) : .seconds(30)
        credentialTimeoutTask = Task { [weak self, credentialLoader] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.credentialRequestID == requestID, self.credentialState == .loading else { return }
            self.credentialRequestID += 1
            self.credentialLoadTask?.cancel()
            await credentialLoader.invalidatePendingLoad()
            self.credentialState = .accessRequired
        }
    }

    private func applyCredentialLoadResult(_ result: CredentialLoadResult) {
        switch result {
        case .ready(let key):
            apiKey = key
            apiKeyWasEdited = false
            credentialState = .ready
            resumeFirstIncompleteRecording()
        case .missing:
            credentialState = .missing
        case .accessRequired:
            credentialState = .accessRequired
        case .failed(let message):
            credentialState = .failed(message)
        case .superseded:
            break
        }
    }

    func resumeFirstIncompleteRecording() {
        guard !isProcessing, analysisProvider != .openAI || !apiKey.isEmpty else { return }
        if analysisProvider == .lmStudio && lmStudioUsesToken && lmStudioToken.isEmpty { return }
        let resumable: Set<ProcessingStatus> = [
            .imported, .inspecting, .extractingAudio, .transcribing, .capturingFrames,
            .recognizingText, .analyzing, .incomplete
        ]
        if let video = videos.first(where: { resumable.contains($0.status) }) {
            beginProcessing(videoID: video.id)
        }
    }

    private func installUIFixture() async {
        guard let store, let paths else { return }
        do {
            let mediaURL = paths.root.appending(path: "fixture.mp4")
            let result = try await ProcessRunner().run(.init(executable: ffmpegPath, arguments: [
                "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=960x540:rate=1", "-t", "125", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", mediaURL.path
            ]))
            guard result.status == 0 else { throw MediaImportError.copyFailed(result.text) }
            let frames = try await FFmpegMediaProcessor(toolchain: .init(ytDLP: ytDLPPath, ffmpeg: ffmpegPath, ffprobe: ffprobePath), runner: ProcessRunner()).captureFrames(from: mediaURL, timestamps: [4, 18, 38], directory: try paths.framesDirectory(id: "vid_ui_fixture"))
            let evidence = frames.map { EvidenceItem(videoID: "vid_ui_fixture", timestamp: $0.timestamp, imageRelativePath: paths.relativePath(for: $0.url), ocrText: "Fixture evidence — Payment failed. Try another method.", origin: .automatic) }
            let video = VideoRecord(id: "vid_ui_fixture", title: "Checkout walkthrough — payment errors, confirmation states, and responsive layout", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 125)
            try await store.createVideo(video)
            try await store.publishArtifacts(videoID: video.id, transcript: [
                TranscriptSegment(videoID: video.id, start: 4, end: 12, originalText: "Open checkout and select the saved payment method."),
                TranscriptSegment(videoID: video.id, start: 18, end: 25, originalText: "The error message should explain what happened and let the customer try again."),
                TranscriptSegment(videoID: video.id, start: 38, end: 44, originalText: "Keep the order summary visible while the payment is processing.")
            ], evidence: evidence, brief: BriefDocument(videoID: video.id, markdown: "# Checkout improvements\n## Requested changes\n- **Explicit statement:** Keep the order summary visible. [00:38]\n- Explain payment errors and allow another attempt. [00:18]\n## Steps\n1. Open checkout. [00:04]\n2. Select a payment method.\n3. Submit payment and review the confirmation.\n## Open questions\nThe recording does not specify the retry limit."))
            let other = VideoRecord(id: "vid_ui_other", title: "Navigation and profile settings", source: .onlineURL, sourceValue: "fixture", mediaRelativePath: "other.mp4", duration: 80)
            try await store.createVideo(other)
            selectedVideoID = video.id
            await loadLibrary()
            if CommandLine.arguments.contains("--ui-tasks") {
                let source = try await store.taskSnapshot(videoID: video.id)
                let content = TaskContent(title: "Explain payment errors and allow another attempt", behavior: "Show a useful error and keep the order summary visible.", requirements: [.init(text: "Keep the order summary visible", origin: .recording, sourceIDs: [source.transcript[2].id])], checks: [.init(text: "After a failed payment, the customer can try again", origin: .interpretation, sourceIDs: [source.transcript[1].id])], questions: [.init(question: "How many retries should be allowed?")], sourceIDs: source.evidence.map(\.id))
                _ = try await store.saveTask(VideoTask(videoID: video.id, sourceRevision: source.video.revisions, content: content), expectedRevision: nil, expectedSource: source.video.revisions)
                await loadSelection()
            } else { startUIFixtureActivity(videoID: video.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func startUIFixtureActivity(videoID: String) {
        // Explicit demo mode uses an isolated temporary library and never calls providers.
        processingVideoID = videoID
        activity = AppActivity(videoID: videoID, recordingTitle: videos.first(where: { $0.id == videoID })?.title ?? "Demo recording", phase: .copying)
        processingTask = Task {
            do {
                try await Task.sleep(for: .seconds(4))
                activity?.phase = .downloading
                activity?.startedAt = .now
                try await Task.sleep(for: .seconds(4))
                for stage in [ProcessingStatus.transcribing, .recognizingText, .analyzing] {
                    let startedAt = Date.now
                    for count in 0...12 {
                        receiveProcessingProgress(.init(stage: stage, completed: count, total: 12, stageStartedAt: startedAt))
                        try await Task.sleep(for: .seconds(2))
                    }
                }
            } catch { }
            activity = nil
            processingVideoID = nil
            processingProgress = nil
        }
    }
}

struct SeekRequest: Equatable {
    let id = UUID()
    let timestamp: TimeInterval
}

private struct StoredPreferences: Codable {
    let toolchain: MediaToolchain
    let models: ModelConfiguration
    var lmStudioUsesToken: Bool? = nil

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "VideoContext.preferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(toolchain: .init(), models: .init())
        }
        return value
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "VideoContext.preferences")
    }
}
