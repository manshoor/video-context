import Foundation
import Testing
@testable import VideoContextCore

struct SavedTaskEvidenceReviewTests {
    @Test("Saved review preserves authored task content and clears approval")
    func preservesContent() async throws {
        let fixture = try await fixture()
        let original = try #require(try await fixture.store.taskSnapshot(videoID: fixture.video.id).tasks.first)
        let http = SavedReviewHTTP(result: #"{"findings":[],"visualObservations":[]}"#)
        let reviewer = TaskEvidenceReviewer(client: AnyHTTPDataLoader(http), configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")), credential: "")

        try await SavedTaskEvidenceReview.review(reference: .recording(videoID: fixture.video.id, taskID: original.id), expectedRevision: original.revision,
                                                 store: fixture.store, paths: fixture.paths, projectContext: nil, reviewer: reviewer)

        let saved = try #require(try await fixture.store.taskSnapshot(videoID: fixture.video.id).tasks.first)
        #expect(saved.content.title == original.content.title)
        #expect(saved.content.behavior == original.content.behavior)
        #expect(saved.content.requirements == original.content.requirements)
        #expect(saved.content.checks == original.content.checks)
        #expect(saved.content.questions == original.content.questions)
        #expect(saved.content.questions.first?.answer == "Keep my answer")
        #expect(saved.content.evidenceReview?.status == .passed)
        #expect(saved.reviewedRevision == nil)
        #expect(await http.requests.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("Keep my answer") })
    }

    @Test("Failed saved review persists awaiting state")
    func failurePersistsAwaiting() async throws {
        let fixture = try await fixture()
        let task = try #require(try await fixture.store.taskSnapshot(videoID: fixture.video.id).tasks.first)
        let reviewer = TaskEvidenceReviewer(client: AnyHTTPDataLoader(SavedReviewHTTP(result: nil)), configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")), credential: "")

        await #expect(throws: (any Error).self) {
            try await SavedTaskEvidenceReview.review(reference: .recording(videoID: fixture.video.id, taskID: task.id), expectedRevision: task.revision,
                                                     store: fixture.store, paths: fixture.paths, projectContext: nil, reviewer: reviewer)
        }
        let saved = try #require(try await fixture.store.taskSnapshot(videoID: fixture.video.id).tasks.first)
        #expect(saved.content.evidenceReview?.status == .awaitingReview)
        #expect(saved.content.evidenceReview?.errorMessage != nil)
    }

    @Test("Saved review rejects a changed task revision")
    func revisionGuard() async throws {
        let fixture = try await fixture()
        let task = try #require(try await fixture.store.taskSnapshot(videoID: fixture.video.id).tasks.first)
        let reviewer = TaskEvidenceReviewer(client: AnyHTTPDataLoader(SavedReviewHTTP(result: #"{"findings":[],"visualObservations":[]}"#)), configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")), credential: "")

        await #expect(throws: TaskContextError.conflict) {
            try await SavedTaskEvidenceReview.review(reference: .recording(videoID: fixture.video.id, taskID: task.id), expectedRevision: task.revision + 1,
                                                     store: fixture.store, paths: fixture.paths, projectContext: nil, reviewer: reviewer)
        }
    }

    private struct Fixture {
        let paths: LibraryPaths
        let store: VideoContextStore
        let video: VideoRecord
    }

    private func fixture() async throws -> Fixture {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "SavedReview-\(UUID().uuidString)"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(id: "saved-review-video", title: "Review", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 20)
        try await store.createVideo(video)
        try await store.publishArtifacts(videoID: video.id, transcript: [.init(id: "saved-review-segment", videoID: video.id, start: 1, end: 2, originalText: "Keep this requirement")], evidence: [], brief: .init(videoID: video.id, markdown: "Brief"))
        let current = try #require(try await store.videoSnapshot(id: video.id)).video
        var question = TaskQuestion(question: "Keep this answer", sourceIDs: [])
        question.answer = "Keep my answer"
        let content = TaskContent(title: "Authored title", behavior: "Keep authored behavior", requirements: [.init(text: "Keep this requirement", origin: .recording, sourceIDs: ["saved-review-segment"])], checks: [.init(text: "Check authored behavior", origin: .user)], questions: [question], sourceIDs: ["saved-review-segment"])
        _ = try await store.saveTask(.init(videoID: video.id, sourceRevision: current.revisions, content: content), expectedRevision: nil, expectedSource: current.revisions)
        return Fixture(paths: paths, store: store, video: video)
    }
}

private actor SavedReviewHTTP: HTTPDataLoading {
    let result: String?
    private(set) var requests: [URLRequest] = []
    init(result: String?) { self.result = result }
    func data(for request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard let result else { throw LocalProviderError.unavailable("fixture provider failed") }
        let payload: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": result]]]]
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: payload), statusCode: 200)
    }
}
