import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct FeedbackTranscriptAppTests {
    static let raw = "transcript\n0:01 The layout looks good.\n0:13 The hooks do not match my prompt.\n0:27 These hooks need fixing."

    @Test func preparationSavesReviewedIssuesWithoutCreatingTasksOrReplacingEvidence() async throws {
        let fixture = try await fixture(client: TranscriptResponse())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.model.prepareFeedback(batchID: fixture.batch.id)
        let snapshot = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(snapshot.batch.comments.count == 1)
        #expect(snapshot.batch.comments[0].text.hasPrefix("Restore the approved hooks"))
        #expect(snapshot.batch.sources == fixture.batch.sources)
        #expect(snapshot.batch.rawText == Self.raw)
        #expect(snapshot.tasks.isEmpty)
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.model.feedbackProgress?.contains("Review or edit") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateExtractionCannotOverwriteEditedFeedback() async throws {
        let client = HeldTranscriptResponse()
        let fixture = try await fixture(client: client)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparing = Task { await fixture.model.prepareFeedback(batchID: fixture.batch.id) }
        await client.waitForRequest()
        var edited = fixture.batch
        edited.title = "My corrected review"
        edited.comments = [.init(text: "Keep my manually reviewed issue", sourceIDs: edited.sources.map(\.id))]
        _ = try await fixture.store.updateFeedback(edited, expectedRevision: edited.revision)
        await client.release()
        await preparing.value
        let snapshot = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(snapshot.batch.title == edited.title)
        #expect(snapshot.batch.comments == edited.comments)
        #expect(snapshot.batch.sources == fixture.batch.sources)
        #expect(snapshot.tasks.isEmpty)
        #expect(fixture.model.errorMessage == TaskContextError.conflict.localizedDescription)
    }

    @Test func taskGenerationRequiresExtractedIssues() async throws {
        let fixture = try await fixture(client: TranscriptResponse())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectedProjectID = fixture.batch.projectID
        fixture.model.feedbackSnapshot = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        fixture.model.generateFeedbackTasks()
        #expect(fixture.model.feedbackGenerationTask == nil)
        #expect(fixture.model.errorMessage == "Extract and review issues from the transcript before generating tasks.")
        #expect(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.isEmpty)
    }

    private func fixture(client: any HTTPDataLoading) async throws -> (model: AppModel, store: VideoContextStore, batch: FeedbackBatch, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "feedback-transcript-app-\(UUID())")
        let model = AppModel(localHTTP: client, libraryRoot: root, showsDockActivity: false)
        model.feedbackPreparationOverride = .init(provider: .lmStudio, modelID: "fixture")
        model.lmStudioUsesToken = false
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Dentistry")
        let batch = FeedbackBatch(projectID: project.id, title: "Review", rawText: Self.raw)
        try await store.createFeedback(batch)
        return (model, store, batch, root)
    }
}

private struct TranscriptResponse: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("video_context_feedback_transcript_issues"))
        let output = #"{"issues":[{"text":"Restore the approved hooks","quotes":["0:13 The hooks do not match my prompt."]}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": output]]]])
        return .init(data: data, statusCode: 200)
    }
}

private actor HeldTranscriptResponse: HTTPDataLoading {
    private var continuation: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> HTTPResult {
        await withCheckedContinuation { continuation = $0 }
        return try await TranscriptResponse().data(for: request)
    }
    func waitForRequest() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
