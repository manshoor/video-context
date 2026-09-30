import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct JamRetryTests {
    @Test func readyPartialJamCanRetryFramesWithoutChangingItsSourceOrTasks() async throws {
        let fixture = try await makeFixture()
        let client = RetryFixtureJamClient(mode: .success)
        let model = AppModel(libraryRoot: fixture.root, showsDockActivity: false, jamController: client)

        await model.retryJamEvidence(batchID: fixture.batch.id, sourceID: fixture.source.id)

        let snapshot = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        let source = try #require(snapshot.batch.sources.first)
        #expect(model.errorMessage == nil)
        #expect(snapshot.batch.revision == fixture.batch.revision + 1)
        #expect(snapshot.batch.rawText == fixture.batch.rawText)
        #expect(snapshot.tasks.isEmpty)
        #expect(source.id == fixture.source.id && source.url == fixture.source.url)
        #expect(source.jam?.items.contains { $0.id == "old-transcript" } == true)
        #expect(source.jam?.items.contains { $0.id == "old-actions" } == true)
        let frame = try #require(source.jam?.items.first { $0.component == .frame })
        #expect(frame.localPath != nil)
        #expect(frame.importedAt != nil && frame.importedAt != source.jam?.importedAt)
        #expect(source.jam?.lastAttemptAt != nil)
    }

    @Test func failedRetryRetainsPreviouslySavedEvidence() async throws {
        let fixture = try await makeFixture()
        let model = AppModel(libraryRoot: fixture.root, showsDockActivity: false,
                             jamController: RetryFixtureJamClient(mode: .frameFailure))
        await model.retryJamEvidence(batchID: fixture.batch.id, sourceID: fixture.source.id)
        let source = try #require(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).batch.sources.first)
        #expect(source.status == .ready)
        #expect(source.presentationStatus == "Partially imported")
        #expect(source.jam?.items.contains { $0.id == "old-actions" } == true)
        #expect(source.jam?.items.contains { $0.id == "old-transcript" } == true)
        #expect(source.jam?.items.contains { $0.component == .frame } == false)
        #expect(source.jam?.lastAttemptAvailability?.first { $0.component == .frame }?.message.contains("overview must be boolean") == true)
    }

    @Test func authorizationFailureRecordsLatestAttemptWithoutErasingEvidence() async throws {
        let fixture = try await makeFixture()
        let model = AppModel(libraryRoot: fixture.root, showsDockActivity: false,
                             jamController: RetryFixtureJamClient(mode: .authorizationFailure))
        await model.retryJamEvidence(batchID: fixture.batch.id, sourceID: fixture.source.id)
        let source = try #require(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).batch.sources.first)
        #expect(source.status == .ready)
        #expect(source.jam?.items == fixture.source.jam?.items)
        #expect(source.jam?.lastAttemptAt != nil)
        #expect(source.jam?.lastAttemptAvailability?.first?.message.contains("Reconnect Jam") == true)
        #expect(model.errorMessage?.contains("Reconnect Jam") == true)
    }

    @Test func cancelledAndStaleRetriesDoNotReplaceEvidence() async throws {
        let fixture = try await makeFixture()
        let client = RetryFixtureJamClient(mode: .gated)
        let model = AppModel(libraryRoot: fixture.root, showsDockActivity: false, jamController: client)
        let cancelled = Task { await model.retryJamEvidence(batchID: fixture.batch.id, sourceID: fixture.source.id) }
        await client.waitForFrames()
        #expect(model.feedbackBusy)
        cancelled.cancel()
        await client.releaseFrames()
        await cancelled.value
        let afterCancel = try await fixture.store.feedbackSnapshot(id: fixture.batch.id).batch
        #expect(afterCancel.revision == fixture.batch.revision)
        #expect(afterCancel.sources.first?.jam == fixture.source.jam)

        let stale = Task { await model.retryJamEvidence(batchID: fixture.batch.id, sourceID: fixture.source.id) }
        await client.waitForFrames(count: 2)
        var edit = try await fixture.store.feedbackSnapshot(id: fixture.batch.id).batch
        edit.sources[0].url = "https://jam.dev/c/changed"
        _ = try await fixture.store.updateFeedback(edit, expectedRevision: edit.revision)
        await client.releaseFrames()
        await stale.value
        let afterEdit = try await fixture.store.feedbackSnapshot(id: fixture.batch.id).batch
        #expect(afterEdit.revision == fixture.batch.revision + 1)
        #expect(afterEdit.sources.first?.url == "https://jam.dev/c/changed")
        #expect(afterEdit.sources.first?.jam == fixture.source.jam)
    }

    private func makeFixture() async throws -> (root: URL, store: VideoContextStore, batch: FeedbackBatch, source: FeedbackSource) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Fixture")
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Blank checkout: https://jam.dev/c/retry-fixture")
        batch.sources[0].status = .ready
        batch.sources[0].jam = .init(sourceURL: "https://jam.dev/c/retry-fixture", recordingID: "retry-fixture",
            state: .ready, importedAt: Date(timeIntervalSince1970: 100),
            items: [.init(id: "old-transcript", component: .transcript, text: "Blank screen", toolName: "getVideoTranscript"),
                    .init(id: "old-actions", component: .userActions, text: "Clicked pay", toolName: "getUserEvents")],
            availability: [.init(component: .details, status: .available, message: "Details imported."),
                           .init(component: .transcript, status: .available, message: "Transcript imported."),
                           .init(component: .userActions, status: .available, message: "Actions imported."),
                           .init(component: .frame, status: .unavailable, message: "Frames missing.")])
        try await store.createFeedback(batch)
        return (root, store, batch, batch.sources[0])
    }
}

private actor RetryFixtureJamClient: JamConnectionControlling, JamToolCalling {
    enum Mode: Sendable { case success, frameFailure, gated, authorizationFailure }
    let mode: Mode
    private var frameCalls = 0
    private var gate: CheckedContinuation<Void, Never>?
    init(mode: Mode) { self.mode = mode }
    func connect(interactive: Bool) async throws -> Set<String> { ["getDetails", "getFrames"] }
    func disconnect() async throws {}
    func hasStoredCredentials() -> Bool { true }
    func listTools() async throws -> [JamToolDescriptor] {
        if case .authorizationFailure = mode { throw JamConnectionError.authorizationRequired }
        return ["getDetails", "getVideoTranscript", "getFrames", "getUserEvents"].map {
            .init(name: $0, inputProperties: ["jamUrl", "overview"])
        }
    }
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        switch name {
        case "getDetails": return .text(#"{"title":"Checkout"}"#)
        case "getFrames":
            frameCalls += 1
            if case .gated = mode { await withCheckedContinuation { gate = $0 } }
            if case .frameFailure = mode {
                return .init(content: [.text("Invalid arguments: overview must be boolean")], isError: true)
            }
            return .init(content: [.text("t=1200"), .image(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")])
        default: return .init(content: [.text("Unavailable")], isError: true)
        }
    }
    func waitForFrames(count: Int = 1) async {
        while frameCalls < count || (mode.isGated && gate == nil) { await Task.yield() }
    }
    func releaseFrames() { gate?.resume(); gate = nil }
}

private extension RetryFixtureJamClient.Mode {
    var isGated: Bool { if case .gated = self { true } else { false } }
}
