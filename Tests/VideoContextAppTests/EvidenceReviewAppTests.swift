import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct EvidenceReviewAppTests {
    @Test func failedReviewKeepsEditorOnPersistedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EvidenceReviewFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(localHTTP: FailingEvidenceReviewHTTP(), libraryRoot: root, showsDockActivity: false)
        model.reviewAnalysisOverride = .init(provider: .lmStudio, modelID: "fixture")
        model.lmStudioUsesToken = false
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Recovery")
        let video = VideoRecord(title: "Original", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        try await store.publishArtifacts(videoID: video.id,
            transcript: [.init(videoID: video.id, start: 0, end: 2, originalText: "Show the preview")], evidence: [],
            brief: .init(videoID: video.id, markdown: "Show the preview"))
        let source = try #require(try await store.videoSnapshot(id: video.id)).video.revisions
        let content = TaskContent(title: "Task", behavior: "Show the preview", checks: [.init(text: "Preview opens")],
            evidenceReview: .init(status: .awaitingReview, sourceFingerprint: "fixture", promptVersion: "test"))
        let task = try await store.saveTask(.init(videoID: video.id, sourceRevision: source, content: content), expectedRevision: nil, expectedSource: source)
        model.workspaceLocation = .init(root: .project(project.id), task: .recording(videoID: video.id, taskID: task.id))
        await model.loadSelection()
        let draft = try #require(model.taskDraft)
        await model.reviewSavedProjectTaskEvidence()
        let latest = try #require(try await store.taskSnapshot(videoID: video.id).tasks.first)
        #expect(latest.revision > task.revision)
        #expect(draft.revision == latest.revision)
        #expect(draft.content == latest.content)
        #expect(draft.savedContent == latest.content)
        #expect(draft.error != nil)
        #expect(!draft.dirty)
    }

    @Test func editingReviewedTaskShowsPersistedAwaitingReviewState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EvidenceReviewAppTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root, showsDockActivity: false)
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Review edits")
        let video = VideoRecord(title: "Original", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let content = TaskContent(title: "Task", behavior: "Show the preview", checks: [.init(text: "Preview opens", origin: .interpretation)],
            evidenceReview: .init(status: .passed, sourceFingerprint: "fixture", promptVersion: "test"))
        let task = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions, content: content), expectedRevision: nil, expectedSource: video.revisions)
        model.workspaceLocation = .init(root: .project(project.id), task: .recording(videoID: video.id, taskID: task.id))
        await model.loadSelection()
        let draft = try #require(model.taskDraft)
        #expect(draft.canReview)
        draft.content.behavior = "Show the revised preview"
        #expect(await model.saveProjectTask())
        #expect(draft.content.evidenceReview?.status == .awaitingReview)
        #expect(draft.savedContent == draft.content)
        #expect(!draft.dirty)
        #expect(!draft.canReview)
    }
}

private struct FailingEvidenceReviewHTTP: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult { throw URLError(.networkConnectionLost) }
}
