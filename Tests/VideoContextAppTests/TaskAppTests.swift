import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

private actor TaskGenerationGate: HTTPDataLoading {
    private(set) var urls: [String] = []
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> HTTPResult {
        urls.append(request.url?.absoluteString ?? "")
        if request.url?.path == "/api/v1/models" {
            return .init(data: Data(#"{"models":[{"key":"vision","display_name":"Vision","type":"llm","format":"mlx","capabilities":{"vision":true},"loaded_instances":[{"id":"vision-loaded","config":{"context_length":32768}}]}]}"#.utf8), statusCode: 200)
        }
        if !entered {
            entered = true; observer?.resume(); observer = nil
            await withCheckedContinuation { release = $0 }
        }
        try Task.checkCancellation()
        return .init(data: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"tasks\":[]}"}}]}"#.utf8), statusCode: 200)
    }
    func waitForInference() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { release?.resume(); release = nil }
}
private actor NoCloudTaskHTTP: HTTPDataLoading {
    private(set) var calls = 0
    func data(for request: URLRequest) async throws -> HTTPResult { calls += 1; throw TaskContextError.invalid("Cloud inference forbidden") }
}

@MainActor
struct TaskAppTests {
    @Test func localGenerationFreezesSettingsAndKeepsUIResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let writer = try VideoContextStore(databaseURL: paths.database)
        let taskProject = try await writer.createFeedbackProject(name: "Task fixture")
        let video = VideoRecord(title: "Local task fixture", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", projectID: taskProject.id)
        try await writer.createVideo(video)
        try await writer.publishArtifacts(videoID: video.id, transcript: [.init(videoID: video.id, start: 0, end: 1, originalText: "Change label")], evidence: [], brief: .init(videoID: video.id, markdown: "Change label"))
        let local = TaskGenerationGate(), cloud = NoCloudTaskHTTP()
        let model = AppModel(cloudHTTP: cloud, localHTTP: local, libraryRoot: root, showsDockActivity: false)
        model.analysisProvider = .lmStudio; model.lmStudioModelID = "vision"; model.lmStudioURL = "http://127.0.0.1:1234"; model.lmStudioUsesToken = false
        model.apiKey = ""; model.credentialState = .missing
        model.selectedProjectID = taskProject.id
        model.selectedVideoID = video.id
        await model.loadLibrary()
        model.generateTasks()
        let work = try #require(model.taskGenerationTask)
        await local.waitForInference()
        #expect(model.activity?.videoID == video.id)
        // MainActor remains available while inference waits. These settings must not affect the captured task.
        model.analysisProvider = .openAI; model.lmStudioModelID = "different-model"
        model.selectedVideoID = "another-recording"
        model.generateTasks()
        #expect(model.activity?.videoID == video.id)
        await local.resume(); await work.value
        #expect(!model.isProcessing)
        #expect(await cloud.calls == 0)
        #expect(await local.urls.allSatisfy { $0.hasPrefix("http://127.0.0.1:1234/") })
        #expect(try await writer.videoSnapshot(id: video.id)?.video.status == .ready)
    }
    @Test func taskCancellationPreservesReadyArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root), local = TaskGenerationGate()
        let writer = try VideoContextStore(databaseURL: paths.database)
        let taskProject = try await writer.createFeedbackProject(name: "Task fixture")
        let video = VideoRecord(title: "Cancel fixture", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", projectID: taskProject.id)
        try await writer.createVideo(video)
        try await writer.publishArtifacts(videoID: video.id, transcript: [.init(videoID: video.id, start: 0, end: 1, originalText: "Change label")], evidence: [], brief: .init(videoID: video.id, markdown: "Change label"))
        let model = AppModel(localHTTP: local, libraryRoot: root, showsDockActivity: false)
        model.analysisProvider = .lmStudio; model.lmStudioModelID = "vision"; model.lmStudioURL = "http://127.0.0.1:1234"; model.lmStudioUsesToken = false
        model.selectedProjectID = taskProject.id
        model.selectedVideoID = video.id
        await model.loadLibrary(); model.generateTasks()
        let work = try #require(model.taskGenerationTask)
        await local.waitForInference(); model.cancelProcessing()
        #expect(model.activity?.isCancelling == true)
        await local.resume(); await work.value
        #expect(!model.isProcessing)
        #expect(model.taskGenerationMessage?.contains("paused") == true)
        #expect(try await writer.videoSnapshot(id: video.id)?.video.status == .ready)
        #expect(try await writer.taskSnapshot(videoID: video.id).proposals.isEmpty)
    }
}
