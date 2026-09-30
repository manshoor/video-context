import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct ImportActivityTests {
    @Test func linkedEvidenceImportKeepsTheSelectedRecording() async throws {
        let gate = ImportGate()
        let model = try await modelWith(gate: gate)
        model.selectedVideoID = "vid_parent"
        let job = Task { await model.importOnline("https://example.com/evidence.mp4", selectImported: false) }
        await gate.waitForStart()
        #expect(model.selectedVideoID == "vid_parent")
        await gate.release()
        let importedID = try #require(await job.value)
        #expect(importedID != "vid_parent")
        #expect(model.selectedVideoID == "vid_parent")
    }
    @Test func localImportShowsWorkRejectsOverlapAndStopsAfterCancellation() async throws {
        let gate = ImportGate()
        let model = try await modelWith(gate: gate)
        let importTask = Task { await model.importLocal(URL(fileURLWithPath: "/tmp/example.mp4")) }
        await gate.waitForStart()
        #expect(model.activity?.phase == .copying)
        #expect(model.isProcessing)
        model.selectedVideoID = "another-recording"
        let originalID = model.activity?.videoID
        await model.importLocal(URL(fileURLWithPath: "/tmp/second.mp4"))
        #expect(await gate.calls == 1)
        #expect(model.activity?.videoID == originalID)
        model.cancelProcessing()
        #expect(model.activity?.isCancelling == true)
        // An uncancellable copy must keep showing work until it really ends.
        #expect(model.isProcessing)
        await gate.release()
        await importTask.value
        #expect(model.activity == nil)
        #expect(model.processingVideoID == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func failedDownloadClearsActivityAndPreservesItsRecording() async throws {
        let gate = ImportGate(fails: true)
        let model = try await modelWith(gate: gate)
        let task = Task { await model.importOnline("https://example.com/video.mp4") }
        await gate.waitForStart()
        #expect(model.activity?.phase == .downloading)
        let id = model.activity?.videoID
        await gate.release()
        await task.value
        #expect(!model.isProcessing)
        #expect(model.videos.first?.id == id)
        #expect(model.videos.first?.status == .failed)
        #expect(model.errorMessage != nil)
    }

    @Test func completedImportWithMissingCredentialsDoesNotShowProcessing() async throws {
        let gate = ImportGate()
        let model = try await modelWith(gate: gate)
        model.credentialState = .missing
        let task = Task { await model.importLocal(URL(fileURLWithPath: "/tmp/example.mp4")) }
        await gate.waitForStart()
        await gate.release()
        await task.value
        #expect(!model.isProcessing)
        #expect(model.processingVideoID == nil)
        #expect(model.videos.count == 1)
        #expect(model.errorMessage?.contains("API key") == true)
    }

    private func modelWith(gate: ImportGate) async throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextImportTests-\(UUID())")
        let model = AppModel(libraryRoot: root, mediaImports: MediaImportOperations(
            local: { _, id, paths in try await gate.run(destination: paths.root.appending(path: "\(id).mp4")) },
            online: { _, id, paths, _ in try await gate.run(destination: paths.root.appending(path: "\(id).mp4")) }
        ), showsDockActivity: false)
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Import test")
        model.selectedProjectID = project.id
        return model
    }

    @Test func cancellingDuringUninterruptibleCopyKeepsImportedMediaPaused() async throws {
        let gate = ImportGate(checksCancellation: false)
        let model = try await modelWith(gate: gate)
        let task = Task { await model.importLocal(URL(fileURLWithPath: "/tmp/example.mp4")) }
        await gate.waitForStart()
        let id = model.activity?.videoID
        model.cancelProcessing()
        await gate.release()
        await task.value
        #expect(model.videos.first?.id == id)
        #expect(model.videos.first?.status == .cancelled)
        #expect(!model.isProcessing)
        #expect(model.processingVideoID == nil)
    }
}

private actor ImportGate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    let fails: Bool
    let checksCancellation: Bool
    init(fails: Bool = false, checksCancellation: Bool = true) {
        self.fails = fails
        self.checksCancellation = checksCancellation
    }
    func run(destination: URL) async throws -> URL {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        if checksCancellation { try Task.checkCancellation() }
        if fails { throw MediaImportError.downloadFailed("Fixture download failure") }
        return destination
    }
    func waitForStart() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
