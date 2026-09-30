import Foundation
import Testing
@testable import VideoContextCore

struct SavedTaskReviewRecoveryTests {
    @Test("An answered edit in awaiting state is sent to the saved-task reviewer")
    func answeredAwaitingEditReachesReviewer() async throws {
        let fixture = try await SavedReviewRecoveryFixture.make()
        let original = try #require(try await fixture.store.taskSnapshot(videoID: fixture.videoID).tasks.first)
        var edit = original
        edit.content.questions[0].answer = "Keep the preview visible after checkout."
        let answered = try await fixture.store.saveTask(
            edit,
            expectedRevision: original.revision,
            expectedSource: fixture.sourceRevision
        )
        #expect(answered.content.evidenceReview?.status == .awaitingReview)
        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: fixture.projectID, paths: fixture.paths))
        #expect(context.existingTasks.contains { $0.id == answered.id && $0.revision == answered.revision })
        let http = SavedReviewRecoveryHTTP(response: #"{"findings":[],"visualObservations":[]}"#)
        let reviewer = TaskEvidenceReviewer(
            client: AnyHTTPDataLoader(http),
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "fixture")),
            credential: ""
        )

        try await SavedTaskEvidenceReview.review(
            reference: .recording(videoID: fixture.videoID, taskID: answered.id),
            expectedRevision: answered.revision,
            store: fixture.store,
            paths: fixture.paths,
            projectContext: context,
            reviewer: reviewer
        )

        let bodies = await http.requestBodies
        #expect(bodies.count == 1)
        #expect(bodies[0].contains("Keep the preview visible after checkout."))
        let saved = try #require(try await fixture.store.taskSnapshot(videoID: fixture.videoID).tasks.first)
        #expect(saved.content.questions[0].answer == "Keep the preview visible after checkout.")
        #expect(saved.content.evidenceReview?.status == .passed)
    }

    @Test("An unknown saved-review outcome is not submitted again after awaiting state increments the task revision")
    func unknownOutcomeSurvivesAwaitingRevision() async throws {
        let fixture = try await SavedReviewRecoveryFixture.make()
        let first = try #require(try await fixture.store.taskSnapshot(videoID: fixture.videoID).tasks.first)
        let firstContext = try #require(try await fixture.store.projectAnalysisContext(projectID: fixture.projectID, paths: fixture.paths))
        #expect(firstContext.existingTasks.contains { $0.id == first.id && $0.revision == first.revision })
        let http = SavedReviewUnknownOutcomeHTTP()
        let reviewer = TaskEvidenceReviewer(
            client: AnyHTTPDataLoader(http),
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "fixture")),
            credential: ""
        )

        await #expect(throws: (any Error).self) {
            try await SavedTaskEvidenceReview.review(
                reference: .recording(videoID: fixture.videoID, taskID: first.id),
                expectedRevision: first.revision,
                store: fixture.store,
                paths: fixture.paths,
                projectContext: firstContext,
                reviewer: reviewer
            )
        }
        let awaiting = try #require(try await fixture.store.taskSnapshot(videoID: fixture.videoID).tasks.first)
        #expect(awaiting.revision == first.revision + 1)
        #expect(awaiting.content.evidenceReview?.status == .awaitingReview)
        let refreshedContext = try #require(try await fixture.store.projectAnalysisContext(projectID: fixture.projectID, paths: fixture.paths))
        #expect(refreshedContext.existingTasks.contains { $0.id == awaiting.id && $0.revision == awaiting.revision })

        await #expect(throws: (any Error).self) {
            try await SavedTaskEvidenceReview.review(
                reference: .recording(videoID: fixture.videoID, taskID: awaiting.id),
                expectedRevision: awaiting.revision,
                store: fixture.store,
                paths: fixture.paths,
                projectContext: refreshedContext,
                reviewer: reviewer
            )
        }
        #expect(await http.requestCount == 1)
        let checkpoints = try await fixture.store.documentationAnalysisCheckpoints(projectID: fixture.projectID)
        #expect(checkpoints.count == 1)
        #expect(checkpoints.first?.state == .unknown)
    }
}

private struct SavedReviewRecoveryFixture {
    let paths: LibraryPaths
    let store: VideoContextStore
    let projectID: String
    let videoID: String
    let sourceRevision: ArtifactRevision

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedTaskReviewRecoveryTests-\(UUID())", directoryHint: .isDirectory)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Saved review recovery")
        let video = VideoRecord(
            id: "saved-review-recovery-video",
            title: "Checkout review",
            source: .localFile,
            sourceValue: "fixture",
            mediaRelativePath: "videos/saved-review-recovery-video/original.mov",
            duration: 10,
            status: .ready,
            projectID: project.id
        )
        try await store.createVideo(video)
        let mediaURL = paths.absoluteURL(relativePath: video.mediaRelativePath)
        try FileManager.default.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: mediaURL)
        try await store.publishArtifacts(
            videoID: video.id,
            transcript: [.init(id: "saved-review-recovery-segment", videoID: video.id, start: 1, end: 3, originalText: "Keep the preview visible.")],
            evidence: [],
            brief: .init(videoID: video.id, markdown: "")
        )
        let current = try await store.taskSnapshot(videoID: video.id)
        var question = TaskQuestion(question: "Should the preview remain visible?", sourceIDs: ["saved-review-recovery-segment"])
        question.category = .productDecision
        let awaiting = TaskEvidenceReview(
            status: .awaitingReview,
            sourceFingerprint: "previous-review",
            promptVersion: "fixture",
            errorMessage: "Answer changed after the earlier review."
        )
        let content = TaskContent(
            title: "Keep checkout preview",
            behavior: "Keep the preview visible during checkout.",
            requirements: [.init(text: "Keep the preview visible.", origin: .recording, sourceIDs: ["saved-review-recovery-segment"])],
            checks: [.init(text: "Preview remains visible.", origin: .interpretation, sourceIDs: ["saved-review-recovery-segment"])],
            questions: [question],
            sourceIDs: ["saved-review-recovery-segment"],
            evidenceReview: awaiting
        )
        _ = try await store.saveTask(
            .init(id: "saved-review-recovery-task", videoID: video.id, sourceRevision: current.video.revisions, content: content),
            expectedRevision: nil,
            expectedSource: current.video.revisions
        )
        try await store.saveProjectAnalysisSelection(projectID: project.id, selection: .init(recordingIDs: [video.id]))
        return .init(paths: paths, store: store, projectID: project.id, videoID: video.id, sourceRevision: current.video.revisions)
    }
}

private actor SavedReviewRecoveryHTTP: HTTPDataLoading {
    let response: String
    private(set) var requestBodies: [String] = []

    init(response: String) { self.response = response }

    func data(for request: URLRequest) async throws -> HTTPResult {
        requestBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let payload: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": response]]]]
        return .init(data: try JSONSerialization.data(withJSONObject: payload), statusCode: 200)
    }
}

private actor SavedReviewUnknownOutcomeHTTP: HTTPDataLoading {
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> HTTPResult {
        requestCount += 1
        throw LocalProviderError.unavailable("fixture transport lost the provider result")
    }
}
