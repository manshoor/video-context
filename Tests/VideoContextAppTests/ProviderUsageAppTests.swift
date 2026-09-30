import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct ProviderUsageAppTests {
    @Test func upgradesKeepSettingsAndTaskOverrideIsIndependent() throws {
        let old = Data(#"{"transcriptionModel":"whisper-1","analysisModel":"existing","analysisProvider":"lmStudio","transcriptionProvider":"localWhisper","lmStudio":{"baseURL":"http://127.0.0.1:1234","modelID":"vision"}}"#.utf8)
        var config = try JSONDecoder().decode(ModelConfiguration.self, from: old)
        #expect(config.taskAnalysisOverride == nil)
        #expect(config.taskConfiguration.analysisProvider == .lmStudio)
        config.taskAnalysisOverride = .init(provider: .claude, modelID: "claude-fixture")
        #expect(config.analysisProvider == .lmStudio && config.lmStudio.modelID == "vision")
        #expect(config.taskConfiguration.analysisProvider == .claude && config.taskConfiguration.selectedAnalysisModel == "claude-fixture")
        #expect(!config.requiresOpenAI(transcriptNeeded: true))
    }

    @Test(.timeLimit(.minutes(1))) func providerCredentialLateLoadCannotReplaceAnEdit() async throws {
        let gate = UsageCredentialGate()
        let credential = ProviderCredential(store: gate)
        let task = Task { await credential.load(mode: .nonInteractive) }
        await gate.waitForLoad()
        credential.edit("new-key")
        await gate.release()
        await task.value
        #expect(credential.value == "new-key" && credential.edited && credential.ready)
        try await credential.saveIfEdited()
        #expect(await gate.saved == ["new-key"])
        #expect(!credential.edited)
    }

    @Test func untouchedEmptyCredentialDoesNotDeleteAndDenialIsVisible() async throws {
        let store = DeniedProviderCredential()
        let credential = ProviderCredential(store: store)
        try await credential.saveIfEdited()
        #expect(await store.removes == 0)
        await credential.load(mode: .nonInteractive)
        #expect(credential.state == .accessRequired)
    }

    @Test func failedOutputRetainsReportedRunUsageAndPreservesReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(cloudHTTP: InvalidClaudeOutput(), libraryRoot: root, showsDockActivity: false)
        let store = try #require(model.store)
        let taskProject = try await store.createFeedbackProject(name: "Task fixture")
        let video = VideoRecord(title: "Usage fixture", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", projectID: taskProject.id)
        try await store.createVideo(video)
        try await store.publishArtifacts(videoID: video.id, transcript: [.init(videoID: video.id, start: 0, end: 1, originalText: "Change label")], evidence: [], brief: .init(videoID: video.id, markdown: "Change label"))
        model.analysisProvider = .lmStudio
        model.taskAnalysisOverride = .init(provider: .claude, modelID: "claude-fixture")
        model.claudeCredential.edit("fixture-key")
        model.selectedProjectID = taskProject.id
        model.selectedVideoID = video.id
        await model.loadLibrary()
        model.generateTasks()
        let task = try #require(model.taskGenerationTask)
        model.taskAnalysisOverride = .init(provider: .deepSeek, modelID: "deepseek-flash")
        await task.value
        let usage = try await store.usageSnapshot()
        #expect(usage.runs.count == 1)
        #expect(usage.runs[0].provider == .claude && usage.runs[0].outcome == .failed)
        #expect(usage.attempts[0].tokens.total == 25)
        #expect(try await store.videoSnapshot(id: video.id)?.video.status == .ready)
        #expect(try await store.taskSnapshot(videoID: video.id).proposals.isEmpty)
    }
}

private actor UsageCredentialGate: APIKeyStoring {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var saved: [String] = []
    func load(mode: APIKeyAccessMode) async throws -> String? { await withCheckedContinuation { continuation = $0 } }
    func save(_ key: String) async throws { saved.append(key) }
    func remove() async throws {}
    func waitForLoad() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(returning: "old-key"); continuation = nil }
}
private actor DeniedProviderCredential: APIKeyStoring {
    private(set) var removes = 0
    func load(mode: APIKeyAccessMode) async throws -> String? { throw KeychainError.interactionNotAllowed }
    func save(_ key: String) async throws {}
    func remove() async throws { removes += 1 }
}
private struct InvalidClaudeOutput: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult {
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
        return .init(data: Data(#"{"model":"claude-fixture","stop_reason":"end_turn","content":[{"type":"text","text":"invalid JSON"}],"usage":{"input_tokens":20,"output_tokens":5}}"#.utf8), statusCode: 200)
    }
}
