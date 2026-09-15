import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct LocalProviderAppTests {
    @Test func pendingTokenSaveDoesNotDiscardNewEdits() async throws {
        let store = SavingTokenGate()
        let model = AppModel(localTokenStore: store, libraryRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), showsDockActivity: false)
        model.editLocalToken("first-token")
        let task = Task { try await model.saveLocalTokenIfEdited() }
        await store.waitForSave()
        model.editLocalToken("new-token")
        await store.release()
        try await task.value
        #expect(model.lmStudioToken == "new-token")
        #expect(model.localTokenEdited)
    }

    @Test func runningProcessingPreventsSpeechAssetReplacement() {
        let model = AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), showsDockActivity: false)
        model.activity = AppActivity(videoID: "vid_test", recordingTitle: "Test", phase: .processing(.transcribing))
        model.downloadSpeechModel()
        #expect(!model.speechDownloadActive)
        #expect(model.speechDownloadTask == nil)
    }

    @Test func localStartupNeverReadsOpenAIKeychain() async throws {
        let keyStore = CountingKeyStore()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(keyStore: keyStore, libraryRoot: root, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .lmStudio
        model.lmStudioUsesToken = false
        await model.loadLibrary(resume: true)
        #expect(await keyStore.loads == 0)
        #expect(model.credentialState == .missing)
        #expect(!model.selectionNeedsOpenAI)
    }

    @Test func lateLocalTokenLoadCannotReplaceAnEnteredToken() async throws {
        let store = TokenGate()
        let model = AppModel(localTokenStore: store,
            libraryRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), showsDockActivity: false)
        let load = Task { await model.loadLocalToken(mode: .nonInteractive) }
        await store.waitForLoad()
        model.editLocalToken("new-token")
        await store.release()
        await load.value
        #expect(model.lmStudioToken == "new-token")
        #expect(model.lmTokenState == .ready)
    }

    @Test func missingSpeechAssetsFailLocallyWithoutCredentialAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let manager = SpeechModelManager(root: root)
        await #expect(throws: LocalProviderError.self) { try await manager.installedAssets() }
    }

    @Test func cachedTranscriptRunsThroughLocalAnalysisWithoutCloudOrSpeechModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let videoURL = root.appending(path: "video.mp4")
        _ = try await ProcessRunner().run(ProcessCommand(executable: "/opt/homebrew/bin/ffmpeg", arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=size=160x120:rate=1:duration=2", "-f", "lavfi", "-i", "sine=duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", videoURL.path
        ]))
        let store = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(title: "Local fixture", source: .localFile, sourceValue: videoURL.path, mediaRelativePath: "video.mp4", status: .incomplete)
        try await store.createVideo(video)
        let segment = TranscriptSegment(videoID: video.id, start: 0, end: 1, originalText: "Change the button label")
        try await store.replaceTranscript(videoID: video.id, segments: [segment])
        try Data([1, 2]).write(to: root.appending(path: "frame.jpg"))
        try await store.replaceEvidence(videoID: video.id, items: [EvidenceItem(videoID: video.id, timestamp: 1, imageRelativePath: "frame.jpg", ocrText: "Save", origin: .automatic)])
        let cloud = ForbiddenCloudClient()
        let local = LocalAppClient()
        let model = AppModel(keyStore: CountingKeyStore(), cloudHTTP: cloud, localHTTP: local, libraryRoot: root, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .lmStudio
        model.lmStudioModelID = "vision"
        model.lmStudioUsesToken = false
        model.credentialState = .missing
        model.ffprobePath = "/opt/homebrew/bin/ffprobe"
        await model.loadLibrary()
        model.beginProcessing(videoID: video.id)
        // Changes during the run must not change the captured provider or model.
        model.analysisProvider = .openAI
        model.lmStudioModelID = "changed-model"
        await model.waitForProcessing()
        let result = try #require(try await store.videoSnapshot(id: video.id))
        #expect(result.video.status == .ready)
        #expect(result.video.id == video.id)
        #expect(result.transcript == [segment])
        #expect(await cloud.calls == 0)
        #expect(await local.analysisModels == ["vision-instance", "vision-instance"])
        #expect(result.apiUsage.allSatisfy { $0.provider == .lmStudio })
    }
}

private actor CountingKeyStore: APIKeyStoring {
    private(set) var loads = 0
    func load(mode: APIKeyAccessMode) async throws -> String? { loads += 1; return nil }
    func save(_ key: String) async throws {}
    func remove() async throws {}
}

private actor TokenGate: APIKeyStoring {
    private var continuation: CheckedContinuation<String?, Never>?
    func load(mode: APIKeyAccessMode) async throws -> String? { await withCheckedContinuation { continuation = $0 } }
    func waitForLoad() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(returning: "old-token"); continuation = nil }
    func save(_ key: String) async throws {}
    func remove() async throws {}
}

private actor ForbiddenCloudClient: HTTPDataLoading {
    private(set) var calls = 0
    func data(for request: URLRequest) async throws -> HTTPResult { calls += 1; throw LocalProviderError.configuration("Unexpected cloud call") }
}

private actor LocalAppClient: HTTPDataLoading {
    private(set) var analysisModels: [String] = []
    func data(for request: URLRequest) async throws -> HTTPResult {
        if request.httpMethod == "POST" {
            let data = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            analysisModels.append(try #require(object["model"] as? String))
            return HTTPResult(data: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"markdown\":\"Change the button [00:00]\"}"}}]}"#.utf8), statusCode: 200)
        }
        return HTTPResult(data: Data(#"{"models":[{"key":"vision","display_name":"Vision","type":"llm","format":"mlx","capabilities":{"vision":true},"loaded_instances":[{"id":"vision-instance","config":{"context_length":32768}}]}]}"#.utf8), statusCode: 200)
    }
}

private actor SavingTokenGate: APIKeyStoring {
    private var continuation: CheckedContinuation<Void, Never>?
    func load(mode: APIKeyAccessMode) async throws -> String? { nil }
    func save(_ key: String) async throws { await withCheckedContinuation { continuation = $0 } }
    func waitForSave() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func remove() async throws {}
}
