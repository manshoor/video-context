import AppKit
import Foundation
import Observation
import VideoContextCore

@MainActor
@Observable
final class AppModel {
    var videos: [VideoRecord] = []
    var feedbackProjects: [FeedbackProject] = []
    var workspaceLocation = WorkspaceLocation()
    var projectWorkspace: ProjectWorkspaceSnapshot?
    var taskDraft: ProjectTaskDraft?
    var taskDeletion: TaskDeletionPresentation?
    @ObservationIgnored var taskDeleter: (@Sendable (ProjectTaskDeletionPreview) async throws -> Void)?
    var documentation = ProjectDocumentationSnapshot()
    var documentationSources: [ProjectDocumentSource] = []
    var documentationInboxIssues: [DocumentationInboxIssue] = []
    var documentationSourceRevision: ProjectDocumentSourceRevision?
    var documentationDraft: DocumentationDraft?
    var documentationEvidenceLocator: ProjectDocumentLocator?
    var documentationEvidence: ProjectEvidenceReference?
    var libraryReadOnlyReason: String?
    var documentationBusy = false
    var documentationProgress: String?
    var documentationGenerationSources: [ProjectDocumentationGenerationSource] = []
    @ObservationIgnored var documentationTask: Task<Void, Never>?
    @ObservationIgnored var documentationSaver: (@Sendable (ProjectDocumentation) async throws -> ProjectDocumentation)?
    var pendingNavigation: WorkspaceLocation?
    var sourceReturnLocation: WorkspaceLocation?
    var pendingSourceTimestamp: Double?
    var focusedFeedbackCommentID: String?
    var showUnsavedTaskAlert = false
    var workspaceLoadError: String?
    @ObservationIgnored var workspaceLoadTask: Task<Void, Never>?
    @ObservationIgnored var sourceNavigationTask: Task<Void, Never>?
    @ObservationIgnored var workspaceLoadID = UUID()
    @ObservationIgnored var projectWorkspaceLoader: (@Sendable (String?) async throws -> ProjectWorkspaceSnapshot)?
    var selectedVideoID: String? {
        get {
            if case .recording(let id, _) = workspaceLocation.task { return id }
            return workspaceLocation.recordingID
        }
        set { workspaceLocation.recordingID = newValue }
    }
    var selectedProjectID: String? {
        get { workspaceLocation.projectID }
        set { workspaceLocation.root = newValue.map(WorkspaceLocation.Root.project) ?? .inbox }
    }
    var snapshot: VideoSnapshot?
    var taskLibrary: TaskLibrarySnapshot?
    var feedbackBatches: [FeedbackBatch] = []
    var unassignedFeedbackBatches: [FeedbackBatch] = []
    var feedbackScopeVideoID: String?
    var feedbackScopeProjectID: String?
    var selectedFeedbackID: String? {
        get {
            if case .feedback(let id, _) = workspaceLocation.task { return id }
            return workspaceLocation.feedbackID
        }
        set { workspaceLocation.feedbackID = newValue }
    }
    var feedbackSnapshot: FeedbackSnapshot?
    var feedbackCreationBusy = false
    var sourceWorkCount = 0
    var editingFeedbackIDs: Set<String> = []
    var feedbackBusy = false
    var feedbackProgress: String?
    @ObservationIgnored var feedbackGenerationTask: Task<Void, Never>?
    var taskGenerationMessage: String?
    var taskGenerationVideoID: String?
    @ObservationIgnored var taskGenerationTask: Task<Void, Never>?
    var diagnosticsEnabled = false
    var diagnosticsExpiry: Date?
    var diagnosticsHealth = "Logging is off."
    @ObservationIgnored let diagnostics: DiagnosticsService?
    @ObservationIgnored var diagnosticsStarted = false
    @ObservationIgnored var diagnosticStartupFailure: DiagnosticFailure?
    @ObservationIgnored var diagnosticExpiryTask: Task<Void, Never>?
    @ObservationIgnored var diagnosticHeartbeat: Task<Void, Never>?
    @ObservationIgnored var diagnosticActivityScope: DiagnosticScope?
    var errorMessage: String?
    var isSavingSettings = false
    var settingsSaveError: String?
    var settingsSaved = false
    var usagePresentation: UsagePresentation?
    var usageRevision = 0
    var usageStorageError: String?
    var claudeModel: String
    var deepSeekModel: String
    var taskAnalysisOverride: AnalysisSelection? { didSet { taskDefaultInherited = false } }
    var feedbackPreparationOverride: AnalysisSelection? { didSet { preparationDefaultInherited = false } }
    var documentationAnalysisOverride: AnalysisSelection?
    var reviewAnalysisOverride: AnalysisSelection?
    var analysisReasoningEffort: ReasoningEffort?
    var projectAnalysisWarnings: [String] = []
    @ObservationIgnored var taskDefaultInherited = false
    @ObservationIgnored var preparationDefaultInherited = false
    let claudeCredential: ProviderCredential
    let deepSeekCredential: ProviderCredential
    var providerModels: [AnalysisProvider: [String]] = [:]
    var providerCheckMessage = ""
    var checkingCloudProvider = false
    @ObservationIgnored var providerCheckTask: Task<Void, Never>?
    @ObservationIgnored let providerHTTP: AnyHTTPDataLoader
    var processingVideoID: String?
    var seekRequest: SeekRequest?
    var processingProgress: ProcessingProgress?
    var processingElapsedSeconds = 0
    var credentialState: CredentialState = .loading { didSet { diagnosticCredentialChanged(credentialState) } }
    var lastCopiedLabel: String?
    var activity: AppActivity? {
        didSet { dockActivity.update(activity); syncDiagnosticHeartbeat() }
    }
    var savingFrameVideoID: String?
    let isUIFixture: Bool
    let jamSettings: JamSettingsModel
    @ObservationIgnored let jamTools: any JamToolCalling

    var ytDLPPath: String
    var ffmpegPath: String
    var ffprobePath: String
    var transcriptionModel: String
    var analysisModel: String
    var apiKey: String
    var transcriptionProvider: TranscriptionProvider
    var analysisProvider: AnalysisProvider {
        didSet {
            if analysisProvider != .openAI {
                if taskDefaultInherited { taskAnalysisOverride = nil }
                if preparationDefaultInherited { feedbackPreparationOverride = nil }
            }
        }
    }
    var lmStudioURL: String
    var lmStudioModelID: String
    var lmStudioUsesToken: Bool
    var lmStudioToken = ""
    var lmTokenState: CredentialState = .missing { didSet { diagnosticCredentialChanged(lmTokenState) } }
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
        var configuration = ModelConfiguration(transcriptionModel: transcriptionModel, analysisModel: analysisModel,
            transcriptionProvider: transcriptionProvider, analysisProvider: analysisProvider,
            lmStudio: .init(baseURL: lmStudioURL, modelID: lmStudioModelID), claudeModel: claudeModel, deepSeekModel: deepSeekModel,
            taskAnalysisOverride: taskAnalysisOverride, feedbackPreparationOverride: feedbackPreparationOverride)
        configuration.reasoningEffort = [.openAI, .claude].contains(analysisProvider) ? analysisReasoningEffort : nil
        configuration.documentationAnalysisOverride = documentationAnalysisOverride
        configuration.reviewAnalysisOverride = reviewAnalysisOverride
        return configuration
    }
    var selectedAnalysisProviders: Set<AnalysisProvider> {
        let configuration = modelConfiguration
        return Set([configuration.analysisProvider, configuration.taskConfiguration.analysisProvider,
                    configuration.feedbackPreparationConfiguration.analysisProvider,
                    configuration.documentationConfiguration.analysisProvider] +
                   [configuration.reviewConfiguration?.analysisProvider].compactMap { $0 })
    }
    var selectionNeedsOpenAI: Bool {
        modelConfiguration.requiresOpenAI(transcriptNeeded: snapshot?.transcript.isEmpty ?? true)
    }

    @ObservationIgnored let paths: LibraryPaths?
    @ObservationIgnored let store: VideoContextStore?
    @ObservationIgnored private let preferencesDefaults: UserDefaults
    @ObservationIgnored private let keyStore: any APIKeyStoring
    @ObservationIgnored private let credentialLoader: CredentialLoader
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackRecoveryRunning = false
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
         claudeKeyStore: any APIKeyStoring = KeychainAPIKeyStore(account: "claude-api-key"), deepSeekKeyStore: any APIKeyStoring = KeychainAPIKeyStore(account: "deepseek-api-key"),
         cloudHTTP: any HTTPDataLoading = URLSessionHTTPClient(), localHTTP: any HTTPDataLoading = LoopbackHTTPClient(), libraryRoot: URL? = nil,
         mediaImports: MediaImportOperations = .live, preferencesDefaults: UserDefaults = .standard, showsDockActivity: Bool = true, isUIFixture: Bool = false,
         jamController: (any JamConnectionControlling)? = nil) {
        self.isUIFixture = isUIFixture
        if let jamController {
            jamSettings = JamSettingsModel(controller: jamController)
            jamTools = (jamController as? any JamToolCalling) ?? UnavailableJamToolClient()
        } else if isUIFixture {
            jamSettings = JamSettingsModel(controller: FixtureJamConnection())
            jamTools = UnavailableJamToolClient()
        } else {
            let jamService = JamLiveConnection.makeService()
            jamSettings = JamSettingsModel(controller: jamService)
            jamTools = jamService
        }
        self.mediaImports = mediaImports
        dockActivity = DockActivityController(enabled: showsDockActivity)
        self.cloudHTTP = AnyHTTPDataLoader(DiagnosticHTTPClient(base: AnyHTTPDataLoader(cloudHTTP), provider: .openAI))
        self.localHTTP = AnyHTTPDataLoader(DiagnosticHTTPClient(base: AnyHTTPDataLoader(localHTTP), provider: .lmStudio))
        providerHTTP = AnyHTTPDataLoader(cloudHTTP)
        claudeCredential = ProviderCredential(store: claudeKeyStore); deepSeekCredential = ProviderCredential(store: deepSeekKeyStore)
        self.localTokenStore = localTokenStore
        self.keyStore = keyStore
        credentialLoader = CredentialLoader(store: keyStore)
        self.preferencesDefaults = preferencesDefaults
        let preferences = StoredPreferences.load(from: preferencesDefaults)
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
        claudeModel = preferences.models.claudeModel
        deepSeekModel = preferences.models.deepSeekModel
        documentationAnalysisOverride = preferences.models.documentationAnalysisOverride
        reviewAnalysisOverride = preferences.models.reviewAnalysisOverride
        analysisReasoningEffort = preferences.models.reasoningEffort
        taskAnalysisOverride = preferences.taskUsesAnalysisSettings == true ? nil : preferences.models.taskAnalysisOverride ??
            (preferences.models.analysisProvider == .openAI ? .init(provider: .openAI, modelID: "gpt-6-sol", effort: .medium) : nil)
        feedbackPreparationOverride = preferences.preparationUsesAnalysisSettings == true ? nil : preferences.models.feedbackPreparationOverride ??
            (preferences.models.analysisProvider == .openAI ? .init(provider: .openAI, modelID: "gpt-6-luna", effort: .medium) : nil)
        taskDefaultInherited = preferences.taskDefaultInherited ??
            (preferences.taskUsesAnalysisSettings != true && preferences.models.taskAnalysisOverride == nil && preferences.models.analysisProvider == .openAI)
        preparationDefaultInherited = preferences.preparationDefaultInherited ??
            (preferences.preparationUsesAnalysisSettings != true && preferences.models.feedbackPreparationOverride == nil && preferences.models.analysisProvider == .openAI)
        apiKey = ""

        var loadedPaths: LibraryPaths?
        var loadedStore: VideoContextStore?
        var loadError: String?
        var loadFailure: DiagnosticFailure?
        do {
            let root = libraryRoot ?? (isUIFixture ? FileManager.default.temporaryDirectory.appending(path: "VideoContextUI-\(UUID())") : nil)
            let libraryPaths = try root.map { try LibraryPaths(root: $0) } ?? LibraryPaths.applicationSupport()
            loadedPaths = libraryPaths
            loadedStore = try VideoContextStore(databaseURL: libraryPaths.database)
        } catch {
            loadFailure = DiagnosticFailure(error)
            loadError = "The local library could not be opened: \(error.localizedDescription)"
            if let loadedPaths, let readable = try? VideoContextStore(databaseURL: loadedPaths.database, access: .readOnly) {
                loadedStore = readable
                libraryReadOnlyReason = "Library upgrade could not finish. Your existing library is open for reading. Check free disk space and library permissions, then restart. \(error.localizedDescription)"
                loadError = nil
            }
        }
        speechModels = loadedPaths.map { SpeechModelManager(root: $0.root.appending(path: "models")) }
        diagnostics = loadedPaths.map { .library($0, component: .app) }
        paths = loadedPaths
        store = loadedStore
        diagnosticStartupFailure = loadFailure
        errorMessage = loadError
    }

    var isProcessing: Bool { activity != nil || checkingCloudProvider || checkingLocalModel }

    var credentialStatusText: String {
        switch credentialState {
        case .loading: "Checking Keychain for the OpenAI API key…"
        case .ready: "OpenAI API key is ready."
        case .missing: "No OpenAI key was loaded. Try Load saved key before entering it again."
        case .accessRequired: "Allow Keychain access to load the saved key; you do not need to enter it again."
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
        if resume {
            await startDiagnostics()
            do { try await store?.recoverInterruptedUsageRuns() }
            catch { usageStorageError = "Could not reconcile interrupted AI usage. Accounting may be incomplete." }
        }
        guard let store else { return }
        do {
            videos = try await store.listVideos(limit: 100).items
            feedbackProjects = try await store.listFeedbackProjects()
            if resume, selectedVideoID == nil, selectedProjectID == nil, let first = feedbackProjects.first {
                workspaceLocation.root = .project(first.id)
            }
            await loadSelection()
            if resume, didAttemptResume == false {
                didAttemptResume = true
                if isUIFixture {
                    credentialState = .ready
                    await installUIFixture()
                } else if libraryReadOnlyReason == nil {
                    if let paths { _ = await store.resumePendingDocumentImports(paths: paths) }
                    await recoverFeedbackImports()
                    await refreshSpeechModelStatus()
                    if transcriptionProvider == .openAI || selectedAnalysisProviders.contains(.openAI) {
                        startCredentialLoad(mode: .nonInteractive)
                    } else {
                        credentialState = .missing
                        if !lmStudioUsesToken { resumeFirstIncompleteRecording() }
                    }
                    if lmStudioUsesToken { Task { await loadLocalToken(mode: .nonInteractive) } }
                    for provider in selectedAnalysisProviders where provider == .claude || provider == .deepSeek {
                        Task { await loadProviderCredential(provider, mode: .nonInteractive) }
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSelection() async { await loadProjectSelection() }

    @discardableResult func importLocal(_ source: URL, selectImported: Bool = true, projectID: String? = nil, onImported: (@MainActor @Sendable (String) async throws -> Void)? = nil) async -> String? {
        guard libraryReadOnlyReason == nil else { errorMessage = libraryReadOnlyReason; return nil }
        guard !isProcessing, let paths, let store else { return nil }
        guard let destinationProjectID = projectID ?? selectedProjectID else {
            errorMessage = "Choose a project before importing a recording."; return nil
        }
        let importLocation = workspaceLocation
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        let videoID = VideoRecord(title: "", source: .localFile, sourceValue: "", mediaRelativePath: "").id
        activity = AppActivity(videoID: videoID, recordingTitle: source.deletingPathExtension().lastPathComponent, phase: .copying)
        let task = Task {
            await runDiagnosed(.importLocal, videoID: videoID) {
                do {
                  let destination = try await mediaImports.local(source, videoID, paths)
                  let record = VideoRecord(
                      id: videoID,
                      title: source.deletingPathExtension().lastPathComponent,
                      source: .localFile,
                      sourceValue: source.path,
                      mediaRelativePath: paths.relativePath(for: destination), projectID: destinationProjectID
                  )
                  try await store.createVideo(record)
                  try await onImported?(videoID)
                  if selectImported && workspaceLocation == importLocation {
                      workspaceLocation.section = .recordings; workspaceLocation.recordingID = videoID; workspaceLocation.task = nil
                  }
                  await loadLibrary()
                  try Task.checkCancellation()
                  activity = nil
                  beginProcessing(videoID: videoID)
                  await DiagnosticTrace.record(.completed)
                } catch is CancellationError {
                  await DiagnosticTrace.record(.cancelled)
                  try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Import stopped. The completed copy is saved; resume when ready.")
                  activity = nil
                  await loadLibrary()
                } catch {
                  await DiagnosticTrace.record(.failed, error: error)
                  activity = nil
                  errorMessage = error.localizedDescription
                }
            }
        }
        importTask = task
        importRequestID = videoID
        await task.value
        if importRequestID == videoID { importTask = nil; importRequestID = nil }
        return videoID
    }

    @discardableResult func importOnline(_ value: String, selectImported: Bool = true, projectID: String? = nil, onImported: (@MainActor @Sendable (String) async throws -> Void)? = nil) async -> String? {
        guard libraryReadOnlyReason == nil else { errorMessage = libraryReadOnlyReason; return nil }
        guard !isProcessing else { return nil }
        guard let paths, let store,
              let source = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = MediaImportError.unsupportedURL.localizedDescription
            return nil
        }
        guard let destinationProjectID = projectID ?? selectedProjectID else {
            errorMessage = "Choose a project before importing a recording."; return nil
        }
        let importLocation = workspaceLocation
        let videoID = VideoRecord(title: "", source: .onlineURL, sourceValue: "", mediaRelativePath: "").id
        let provisionalPath = "videos/\(videoID)/video.mp4"
        let title = source.host.map { "Recording from \($0)" } ?? "Online recording"
        let record = VideoRecord(
            id: videoID,
            title: title,
            source: .onlineURL,
            sourceValue: source.absoluteString,
            mediaRelativePath: provisionalPath, projectID: destinationProjectID
        )
        activity = AppActivity(videoID: videoID, recordingTitle: title, phase: .downloading)
        let task = Task {
            await runDiagnosed(.importOnline, videoID: videoID) {
                do {
                  try await store.createVideo(record)
                  try await onImported?(videoID)
                  if selectImported && workspaceLocation == importLocation {
                      workspaceLocation.section = .recordings; workspaceLocation.recordingID = videoID; workspaceLocation.task = nil
                  }
                  await loadLibrary()
                  _ = try await mediaImports.online(source, videoID, paths, ytDLPPath)
                  try Task.checkCancellation()
                  activity = nil
                  beginProcessing(videoID: videoID)
                  await DiagnosticTrace.record(.completed)
                } catch is CancellationError {
                  await DiagnosticTrace.record(.cancelled)
                  try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Download cancelled. Import the link again to retry.")
                  activity = nil
                  await loadLibrary()
                } catch {
                  await DiagnosticTrace.record(.failed, error: error)
                  try? await store.updateVideo(id: videoID, status: .failed, errorMessage: error.localizedDescription)
                  activity = nil
                  errorMessage = error.localizedDescription
                  await loadLibrary()
                }
            }
        }
        importTask = task
        importRequestID = videoID
        await task.value
        if importRequestID == videoID { importTask = nil; importRequestID = nil }
        return videoID
    }

    func waitForProcessing() async { await processingTask?.value }

    func beginProcessing(videoID: String) {
        guard libraryReadOnlyReason == nil else { errorMessage = libraryReadOnlyReason; return }
        guard !isProcessing, !checkingCloudProvider, let paths, let store else { return }
        if isUIFixture { startUIFixtureActivity(videoID: videoID); return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credentialReady(for: analysisProvider) else {
            errorMessage = "Unlock or enter the \(analysisProvider.label) API key or local token in Settings before processing this recording."
            Task { await recordDiagnosticFailure(OpenAIClientError.missingAPIKey, operation: .processing, videoID: videoID) }
            return
        }
        let toolchain = MediaToolchain(ytDLP: ytDLPPath, ffmpeg: ffmpegPath, ffprobe: ffprobePath)
        let models = modelConfiguration
        let analysisCredential = credentialValue(for: models.analysisProvider)
        let openAIReady = credentialState == .ready
        let localToken = lmStudioToken
        let needsLocalToken = lmStudioUsesToken
        processingVideoID = videoID
        activity = AppActivity(videoID: videoID, recordingTitle: videos.first(where: { $0.id == videoID })?.title ?? "Recording", phase: .processing(.inspecting))
        processingProgress = nil
        processingElapsedSeconds = 0
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runDiagnosed(.processing, videoID: videoID) {
                let progress: ProcessingProgressHandler = { [weak self] progress in
                    await self?.receiveProcessingProgress(progress)
                }
                do {
                    guard let initial = try await store.videoSnapshot(id: videoID) else { throw VideoContextStoreError.videoNotFound(videoID) }
                    let media = FFmpegMediaProcessor(toolchain: toolchain, runner: ProcessRunner())
                    let inspection = try await media.inspect(paths.absoluteURL(relativePath: initial.video.mediaRelativePath))
                    let transcriptNeeded = initial.transcript.isEmpty && inspection.hasAudio
                    guard !models.requiresOpenAI(transcriptNeeded: transcriptNeeded) || (openAIReady && !key.isEmpty) else {
                        throw OpenAIClientError.missingAPIKey
                    }
                    try await self.withUsageRun(operation: .processing, videoID: videoID, configuration: models, source: initial.video.revisions) {
                        let cloudClient = UsageRecordingClient(base: self.cloudHTTP, provider: .openAI, model: models.transcriptionModel, stage: .transcription)
                        let transcriber: any Transcribing
                        if !transcriptNeeded { transcriber = SavedTranscriptOnly() }
                        else if models.transcriptionProvider == .localWhisper {
                            guard !self.speechDownloadActive else { throw LocalProviderError.configuration("Wait for the speech model download to finish before transcribing locally.") }
                            guard let manager = self.speechModels else { throw LocalProviderError.configuration("The local model directory is unavailable.") }
                            transcriber = LocalWhisperTranscriber(assets: try await manager.installedAssets(), store: store, progress: progress)
                        } else {
                            transcriber = OpenAITranscriber(client: cloudClient, apiKey: key, model: models.transcriptionModel)
                        }
                        var resolved = models
                        var contextLength = 32_768
                        if models.analysisProvider == .lmStudio {
                            guard !needsLocalToken || !localToken.isEmpty else { throw LocalProviderError.configuration("Unlock or enter the LM Studio token in Settings.") }
                            await progress(.init(stage: .inspecting, detail: "Checking LM Studio"))
                            let instance = try await LMStudioService(client: self.localHTTP).loadedModel(configuration: models.lmStudio, token: analysisCredential)
                            resolved.lmStudio.modelID = instance.id; contextLength = instance.config.contextLength
                        }
                        let client = UsageRecordingClient(base: self.transport(for: models.analysisProvider), provider: models.analysisProvider.identity, model: models.selectedAnalysisModel, stage: .analysis)
                        let generator: any BriefGenerating
                        if models.analysisProvider == .openAI {
                            generator = OpenAIBriefGenerator(client: client, apiKey: analysisCredential, model: models.analysisModel,
                                reasoningEffort: models.reasoningEffort, checkpointStore: store)
                        } else {
                            generator = StructuredBriefGenerator(client: client, configuration: resolved, credential: analysisCredential, contextLength: contextLength, checkpointStore: store)
                        }
                        try Task.checkCancellation()
                        let pipeline = VideoProcessingPipeline(store: store, paths: paths,
                            media: FFmpegMediaProcessor(toolchain: toolchain, runner: ProcessRunner()), transcriber: transcriber,
                            textRecognizer: VisionTextRecognizer(), briefGenerator: generator, progress: progress,
                            transcriptionIdentity: ProviderIdentity(provider: models.transcriptionProvider == .localWhisper ? .localWhisper : .openAI,
                                model: models.transcriptionProvider == .localWhisper ? ModelConfiguration.localSpeechModel : models.transcriptionModel),
                            analysisIdentity: resolved.analysisIdentity)
                        try await pipeline.process(videoID: videoID)
                    }
                    await DiagnosticTrace.record(.completed)
                } catch is CancellationError {
                    await DiagnosticTrace.record(.cancelled)
                    try? await store.updateVideo(id: videoID, status: .cancelled, errorMessage: "Processing was cancelled.")
                } catch {
                    await DiagnosticTrace.record(.failed, error: error)
                    self.errorMessage = error.localizedDescription
                    try? await store.markIncomplete(videoID: videoID, error: error.localizedDescription)
                }
                self.processingVideoID = nil
                self.activity = nil
                self.processingProgress = nil
                self.processingElapsedSeconds = 0
                self.statusTask?.cancel()
                await self.loadLibrary()
                if !self.feedbackRecoveryRunning {
                    self.feedbackRecoveryRunning = true
                    await self.recoverFeedbackImports()
                    self.feedbackRecoveryRunning = false
                }
            }
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
            await recordDiagnosticFailure(error, videoID: selectedVideoID)
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
            await recordDiagnosticFailure(error, videoID: videoID)
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
            await recordDiagnosticFailure(error, videoID: snapshot.video.id)
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
        seekRequest = SeekRequest(timestamp: timestamp, videoID: selectedVideoID)
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

    @discardableResult
    func saveSettings() async -> Bool {
        guard !isSavingSettings else { return false }
        isSavingSettings = true
        settingsSaveError = nil
        settingsSaved = false
        defer { isSavingSettings = false }
        guard !isUIFixture else { settingsSaved = true; return true }
        do {
            let toolchain = MediaToolchain(ytDLP: ytDLPPath, ffmpeg: ffmpegPath, ffprobe: ffprobePath)
            var models = modelConfiguration
            models.reasoningEffort = analysisReasoningEffort
            let preferences = StoredPreferences(toolchain: toolchain, models: models, lmStudioUsesToken: lmStudioUsesToken,
                                                taskUsesAnalysisSettings: taskAnalysisOverride == nil,
                                                preparationUsesAnalysisSettings: feedbackPreparationOverride == nil,
                                                taskDefaultInherited: taskDefaultInherited,
                                                preparationDefaultInherited: preparationDefaultInherited)
            do { try await saveLocalTokenIfEdited() }
            catch {
                settingsSaveError = "Could not save the LM Studio token: \(error.localizedDescription). Check Keychain access and try again."
                await recordDiagnosticFailure(error, operation: .credentials)
                return false
            }
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
            for (label, credential) in [("Claude", claudeCredential), ("DeepSeek", deepSeekCredential)] {
                do { try await credential.saveIfEdited() }
                catch {
                    settingsSaveError = "Could not save the \(label) API key: \(error.localizedDescription). Check Keychain access and try again."
                    await recordDiagnosticFailure(error, operation: .credentials); return false
                }
            }
            try preferences.save(to: preferencesDefaults)
            if (transcriptionProvider == .openAI || selectedAnalysisProviders.contains(.openAI)) && apiKey.isEmpty && !apiKeyWasEdited {
                startCredentialLoad(mode: .nonInteractive)
            }
            resumeFirstIncompleteRecording()
            settingsSaved = true
            return true
        } catch {
            credentialState = .failed(error.localizedDescription)
            settingsSaveError = "Could not save settings: \(error.localizedDescription). Check Keychain access and try again."
            await recordDiagnosticFailure(error, operation: .credentials)
            return false
        }
    }

    private func receiveProcessingProgress(_ progress: ProcessingProgress) async {
        let changed = processingProgress?.stage != progress.stage || processingProgress?.completed != progress.completed
        if progress.stage == .analyzing {
            await DiagnosticTrace.record(changed ? .stateChanged : .progress, stage: progress.stage, completed: progress.completed, total: progress.total)
        }
        processingProgress = progress
        activity?.update(progress)
        processingElapsedSeconds = max(0, Int(Date().timeIntervalSince(progress.stageStartedAt)))
    }

    func appBecameActive() {
        guard didAttemptResume else { return }
        loadSettingsCredentials(retryAccessRequired: true)
    }

    func reloadSavedAPIKey() {
        guard !apiKeyWasEdited else { return }
        startCredentialLoad(mode: .nonInteractive)
    }

    var canReloadSavedAPIKey: Bool { !apiKeyWasEdited && credentialState != .loading }

    func loadSettingsCredentials(retryAccessRequired: Bool = false) {
        guard !isUIFixture else { return }
        let providers = selectedAnalysisProviders
        if (transcriptionProvider == .openAI || providers.contains(.openAI)), apiKey.isEmpty, !apiKeyWasEdited,
           credentialState != .ready,
           (credentialState != .loading || credentialLoadTask == nil),
           (credentialState != .accessRequired || retryAccessRequired) {
            startCredentialLoad(mode: .nonInteractive)
        }
        if providers.contains(.lmStudio), lmStudioUsesToken, !localTokenEdited,
           lmTokenState != .ready, lmTokenState != .loading,
           (lmTokenState != .accessRequired || retryAccessRequired) {
            Task { await loadLocalToken(mode: .nonInteractive) }
        }
        for provider in providers where provider == .claude || provider == .deepSeek {
            Task { await loadProviderCredential(provider, mode: .nonInteractive, retryAccessRequired: retryAccessRequired) }
        }
    }

    private func startCredentialLoad(mode: APIKeyAccessMode) {
        guard !isUIFixture else { return }
        if mode == .nonInteractive && credentialState == .loading && credentialLoadTask != nil { return }
        credentialRequestID += 1
        let requestID = credentialRequestID
        credentialLoadTask?.cancel()
        credentialTimeoutTask?.cancel()
        credentialState = .loading

        credentialLoadTask = Task { [weak self, credentialLoader] in
            await credentialLoader.invalidatePendingLoad()
            let scope = self?.diagnosticScope(.credentials)
            let result = await DiagnosticTrace.$scope.withValue(scope) { await credentialLoader.load(mode: mode) }
            guard let self, self.credentialRequestID == requestID, Task.isCancelled == false else { return }
            self.credentialTimeoutTask?.cancel()
            self.credentialLoadTask = nil
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
            self.credentialLoadTask = nil
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
        guard !isProcessing, credentialReady(for: analysisProvider) else { return }
        if analysisProvider == .lmStudio && lmStudioUsesToken && lmStudioToken.isEmpty { return }
        guard !feedbackRecoveryRunning else { return }
        feedbackRecoveryRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.feedbackRecoveryRunning = false }
            await self.recoverFeedbackImports()
            guard !self.isProcessing, let store = self.store else { return }
            let resumable: Set<ProcessingStatus> = [
                .imported, .inspecting, .extractingAudio, .transcribing, .capturingFrames,
                .recognizingText, .analyzing, .incomplete
            ]
            for video in self.videos where resumable.contains(video.status) {
                // A running or unknown checkpoint may represent provider work
                // whose response was lost. Do not submit it again on startup.
                guard let checkpoints = try? await store.processingCheckpoints(videoID: video.id),
                      !checkpoints.contains(where: { $0.state == .running || $0.state == .unknown }) else {
                    continue
                }
                guard !self.isProcessing else { return }
                self.beginProcessing(videoID: video.id)
                return
            }
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
            let project = try await store.createFeedbackProject(name: "Checkout")
            let otherProject = try await store.createFeedbackProject(name: "Account")
            let video = VideoRecord(id: "vid_ui_fixture", title: "Checkout walkthrough — payment errors, confirmation states, and responsive layout", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 125, projectID: project.id)
            try await store.createVideo(video)
            try await store.publishArtifacts(videoID: video.id, transcript: [
                TranscriptSegment(videoID: video.id, start: 4, end: 12, originalText: "Open checkout and select the saved payment method."),
                TranscriptSegment(videoID: video.id, start: 18, end: 25, originalText: "The error message should explain what happened and let the customer try again."),
                TranscriptSegment(videoID: video.id, start: 38, end: 44, originalText: "Keep the order summary visible while the payment is processing.")
            ], evidence: evidence, brief: BriefDocument(videoID: video.id, markdown: "# Checkout improvements\n## Requested changes\n- **Explicit statement:** Keep the order summary visible. [00:38]\n- Explain payment errors and allow another attempt. [00:18]\n## Steps\n1. Open checkout. [00:04]\n2. Select a payment method.\n3. Submit payment and review the confirmation.\n## Open questions\nThe recording does not specify the retry limit."))
            let other = VideoRecord(id: "vid_ui_other", title: "Navigation and profile settings", source: .onlineURL, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 80, status: .ready, projectID: otherProject.id)
            try await store.createVideo(other)
            workspaceLocation = .init(root: .project(project.id))
            await loadLibrary()
            let fixtureRunID = try await installUsageFixture(videoID: video.id)
            if CommandLine.arguments.contains("--ui-tasks") {
                let source = try await store.taskSnapshot(videoID: video.id)
                let content = TaskContent(title: "Explain payment errors and allow another attempt", behavior: "Show a useful error and keep the order summary visible.", requirements: [.init(text: "Keep the order summary visible", origin: .recording, sourceIDs: [source.transcript[2].id])], checks: [.init(text: "After a failed payment, the customer can try again", origin: .interpretation, sourceIDs: [source.transcript[1].id])], questions: [.init(question: "How many retries should be allowed?")], sourceIDs: source.evidence.map(\.id))
                if CommandLine.arguments.contains("--ui-task-proposals") {
                    let provenance = ProviderIdentity(provider: .lmStudio, model: "fixture")
                    let proposals = [content, TaskContent(title: "Keep the order summary visible", behavior: "Keep the summary visible during payment.")].map {
                        var proposal = TaskProposal(videoID: video.id, kind: .addition, sourceRevision: source.video.revisions, content: $0, provenance: provenance)
                        proposal.generationRunID = fixtureRunID
                        return proposal
                    }
                    try await store.publishTaskProposals(proposals, videoID: video.id, expectedSource: source.video.revisions, expectedTasks: [:])
                    taskGenerationMessage = "2 proposed changes. Review them before applying."
                } else {
                _ = try await store.saveTask(VideoTask(videoID: video.id, sourceRevision: source.video.revisions, content: content), expectedRevision: nil, expectedSource: source.video.revisions)
                }
                await loadSelection()
            }
            try await installProjectWorkspaceFixture(videoID: video.id, projectID: project.id)
            await loadLibrary()
            if CommandLine.arguments.contains("--ui-processing") { startUIFixtureActivity(videoID: video.id) }
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
                        await receiveProcessingProgress(.init(stage: stage, completed: count, total: 12, stageStartedAt: startedAt))
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
    let videoID: String?
}

private struct StoredPreferences: Codable {
    let toolchain: MediaToolchain
    let models: ModelConfiguration
    var lmStudioUsesToken: Bool? = nil
    var taskUsesAnalysisSettings: Bool? = nil
    var preparationUsesAnalysisSettings: Bool? = nil
    var taskDefaultInherited: Bool? = nil
    var preparationDefaultInherited: Bool? = nil

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "VideoContext.preferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(toolchain: .init(), models: .init())
        }
        return value
    }

    func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "VideoContext.preferences")
    }
}
