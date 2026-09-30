import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct DiagnosticsAppTests {
    @Test func captureStartsMidImportAndFollowsOriginalContextAfterSelectionChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostics-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DiagnosticImportGate()
        let model = AppModel(libraryRoot: root, mediaImports: .init(local: { _, _, _ in try await gate.run() }, online: { _, _, _, _ in try await gate.run() }), showsDockActivity: false)
        let importProject = try await #require(model.store).createFeedbackProject(name: "Diagnostics import")
        model.selectedProjectID = importProject.id
        let job = Task { await model.importOnline("https://example.com/private-recording") }
        await gate.waitForStart()
        let id = try #require(model.activity?.videoID)
        #expect(!model.diagnosticsEnabled)
        await model.enableDiagnostics()
        #expect(model.diagnosticsEnabled)
        #expect(model.diagnosticHeartbeat != nil)
        model.selectedVideoID = "vid_\(UUID())"
        model.cancelProcessing()
        await gate.release()
        await job.value
        #expect(model.diagnosticHeartbeat == nil)
        let service = try #require(model.diagnostics)
        let events = try await service.events(since: .distantPast)
        #expect(events.contains { $0.entry.alreadyUnderway && $0.entry.context.videoID == id })
        #expect(events.contains { $0.event == .cancelled && $0.entry.context.videoID == id })
        #expect(!events.contains { $0.entry.context.videoID == model.selectedVideoID && $0.entry.context.videoID != id })
        await model.stopDiagnostics()
        #expect(model.diagnosticExpiryTask?.isCancelled == true)
        #expect(!model.diagnosticsEnabled)
    }
    @Test func failedSaveAndReviewRecordSafeErrorMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostics-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root, showsDockActivity: false)
        await model.enableDiagnostics()
        let id = "vid_\(UUID())"
        let task = VideoTask(videoID: id, sourceRevision: .init(), content: .init(title: "PRIVATE TASK"))
        await model.reviewVideoTask(task, source: .init())
        let events = try await #require(model.diagnostics).events(since: .distantPast)
        #expect(events.contains { $0.entry.operation == .review && $0.entry.context.taskID == task.id && $0.entry.error != nil })
        #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("PRIVATE TASK"))
        await model.stopDiagnostics()
    }
}
private actor DiagnosticImportGate {
    var continuation: CheckedContinuation<Void, Never>?
    func run() async throws -> URL {
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        throw MediaImportError.downloadFailed("PRIVATE RAW OUTPUT")
    }
    func waitForStart() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

extension DiagnosticsAppTests {
    @Test func taskProviderFailureIsLoggedWithoutChangingReadyRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostics-task-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let taskProject = try await store.createFeedbackProject(name: "Task fixture")
        let video = VideoRecord(title: "PRIVATE_RECORDING", source: .localFile, sourceValue: "private", mediaRelativePath: "video.mp4", projectID: taskProject.id)
        try await store.createVideo(video)
        try await store.publishArtifacts(videoID: video.id, transcript: [.init(videoID: video.id, start: 0, end: 1, originalText: "PRIVATE_RECORDING")], evidence: [], brief: .init(videoID: video.id, markdown: "PRIVATE_RECORDING"))
        let mock = DiagnosticTaskFailureHTTP()
        let model = AppModel(cloudHTTP: mock, localHTTP: mock, libraryRoot: root, showsDockActivity: false)
        model.analysisProvider = .lmStudio; model.lmStudioModelID = "vision"
        model.lmStudioURL = "http://127.0.0.1:1234"; model.lmStudioUsesToken = false
        model.apiKey = ""; model.credentialState = .missing
        model.selectedProjectID = taskProject.id
        model.selectedVideoID = video.id
        await model.loadLibrary(); await model.enableDiagnostics()
        model.generateTasks()
        let work = try #require(model.taskGenerationTask)
        await work.value
        let service = try #require(model.diagnostics)
        let events = try await service.events(since: .distantPast)
        #expect(events.contains { $0.event == .failed && $0.entry.operation == .taskGeneration && $0.entry.context.videoID == video.id })
        #expect(events.contains { $0.entry.error?.code == 503 })
        #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("PRIVATE_RECORDING"))
        #expect(try await store.videoSnapshot(id: video.id)?.video.status == .ready)
        #expect(!model.isProcessing)
        await model.stopDiagnostics()
    }
}
private struct DiagnosticTaskFailureHTTP: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult {
        #expect(request.url?.host == "127.0.0.1")
        if request.url?.path == "/api/v1/models" {
            return .init(data: Data(#"{"models":[{"key":"vision","display_name":"Vision","type":"llm","format":"mlx","capabilities":{"vision":true},"loaded_instances":[{"id":"vision-loaded","config":{"context_length":32768}}]}]}"#.utf8), statusCode: 200)
        }
        return .init(data: Data(#"{"error":{"message":"PRIVATE_RECORDING"}}"#.utf8), statusCode: 503)
    }
}
