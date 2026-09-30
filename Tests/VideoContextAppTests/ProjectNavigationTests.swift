import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct ProjectNavigationTests {
    private func model() -> AppModel {
        AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: "project-navigation-\(UUID())"), showsDockActivity: false)
    }
    @Test func delayedLoadCannotReplaceNewProject() async throws {
        let model = model()
        let store = try #require(model.store)
        let a = try await store.createFeedbackProject(name: "A")
        let b = try await store.createFeedbackProject(name: "B")
        let gate = ProjectLoadGate()
        model.projectWorkspaceLoader = { id in
            let value = try await store.projectWorkspace(projectID: id)
            if id == a.id { await gate.hold() }
            return value
        }
        model.workspaceLocation = .init(root: .project(a.id))
        let first = Task { await model.loadSelection() }
        await gate.waitForStart()
        model.workspaceLocation = .init(root: .project(b.id))
        await model.loadSelection()
        await gate.release()
        await first.value
        #expect(model.projectWorkspace?.project?.id == b.id)
        #expect(model.selectedProjectID == b.id)
    }
    @Test func requestStartsInProjectAndDoesNotGenerateAutomatically() async throws {
        let model = model()
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Requests")
        model.workspaceLocation = .init(root: .project(project.id))
        #expect(await model.createProjectTaskRequest(projectID: project.id, title: "New request", text: "Fix preview"))
        await model.workspaceLoadTask?.value
        let batch = try #require(model.feedbackSnapshot?.batch)
        #expect(batch.projectID == project.id)
        #expect(batch.videoID == nil)
        #expect(batch.comments[0].kind == .request)
        #expect(model.feedbackGenerationTask == nil)
        #expect(model.projectWorkspace?.tasks.isEmpty == true)
    }
    @Test func saveConflictKeepsDraftAndPendingNavigation() async throws {
        let model = model()
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Edits")
        let video = VideoRecord(title: "Video", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let task = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Original")), expectedRevision: nil, expectedSource: video.revisions)
        model.workspaceLocation = .init(root: .project(project.id), task: .recording(videoID: video.id, taskID: task.id))
        await model.loadSelection()
        let draft = try #require(model.taskDraft)
        draft.content.title = "My unsaved wording"
        var external = task; external.content.title = "Concurrent change"
        _ = try await store.saveTask(external, expectedRevision: task.revision, expectedSource: video.revisions)
        await model.loadSelection()
        #expect(model.taskDraft === draft)
        #expect(draft.content.title == "My unsaved wording")
        model.requestNavigation(.init())
        #expect(model.showUnsavedTaskAlert)
        #expect(model.selectedProjectID == project.id)
        await model.resolvePendingNavigation(save: true)
        #expect(model.selectedProjectID == project.id)
        #expect(draft.error != nil)
        #expect(draft.dirty)
        await model.resolvePendingNavigation(save: false)
        await model.workspaceLoadTask?.value
        #expect(model.selectedProjectID == nil)
        #expect(try await store.taskSnapshot(videoID: video.id).tasks[0].content.title == "Concurrent change")
    }
    @Test func importKeepsCapturedProjectWhenNavigationChanges() async throws {
        let gate = ProjectLoadGate()
        let model = AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            mediaImports: .init(local: { _, id, paths in await gate.hold(); return paths.root.appending(path: id + ".mp4") }, online: { _, id, paths, _ in paths.root.appending(path: id + ".mp4") }), showsDockActivity: false)
        let store = try #require(model.store)
        let a = try await store.createFeedbackProject(name: "A"), b = try await store.createFeedbackProject(name: "B")
        model.workspaceLocation = .init(root: .project(a.id))
        let job = Task { await model.importLocal(URL(fileURLWithPath: "/tmp/example.mp4")) }
        await gate.waitForStart()
        model.requestNavigation(.init(root: .project(b.id)))
        await gate.release()
        let id = try #require(await job.value)
        await model.workspaceLoadTask?.value
        #expect(try await store.videoSnapshot(id: id)?.video.projectID == a.id)
        #expect(model.selectedProjectID == b.id)
        #expect(model.selectedVideoID == nil)
    }
    @Test func importWithoutProjectDoesNotCreateRecording() async throws {
        let model = model()
        #expect(await model.importLocal(URL(fileURLWithPath: "/tmp/example.mp4")) == nil)
        #expect(model.errorMessage?.contains("Choose a project") == true)
        #expect(try await #require(model.store).listVideos().items.isEmpty)
    }
    @Test func feedbackAttachmentKeepsBatchProjectDuringNavigation() async throws {
        let gate = ProjectLoadGate()
        let model = AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            mediaImports: .init(local: { _, id, paths in await gate.hold(); return paths.root.appending(path: id + ".mp4") }, online: { _, id, paths, _ in paths.root.appending(path: id + ".mp4") }), showsDockActivity: false)
        model.transcriptionProvider = .openAI; model.analysisProvider = .openAI
        let store = try #require(model.store)
        let a = try await store.createFeedbackProject(name: "Attachment owner"), b = try await store.createFeedbackProject(name: "Other project")
        let batch = try await store.createProjectRequest(projectID: a.id, title: "Request", text: "Use this recording")
        model.workspaceLocation = .init(root: .project(a.id), section: .feedback, feedbackID: batch.id)
        let job = Task { await model.addFeedbackAttachments([URL(fileURLWithPath: "/tmp/attachment.mp4")], batchID: batch.id, commentID: batch.comments[0].id) }
        await gate.waitForStart()
        #expect(model.projectMoveBlocked)
        model.requestNavigation(.init(root: .project(b.id)))
        await gate.release(); await job.value
        await model.workspaceLoadTask?.value
        let videos = try await store.projectWorkspace(projectID: a.id).recordings
        #expect(videos.count == 1)
        #expect(videos.first?.projectID == a.id)
        #expect(try await store.feedbackSnapshot(id: batch.id).batch.projectID == a.id)
        #expect(model.selectedProjectID == b.id)
        #expect(model.feedbackSnapshot == nil)
        // No processing credentials are provided; attachment failure must not redirect the saved import.
        #expect(model.errorMessage != nil)
    }
}

private actor ProjectLoadGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

extension ProjectNavigationTests {
    @Test func sourceNavigationFollowsOwnerAndRetainsReturnRoute() async throws {
        let model = model()
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Task project")
        let owner = try await store.createFeedbackProject(name: "Legacy source owner")
        let video = VideoRecord(title: "Referenced recording", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: owner.id)
        try await store.createVideo(video)
        let origin = WorkspaceLocation(root: .project(project.id))
        model.workspaceLocation = origin
        await model.loadSelection()
        model.openProjectSource(.recording(video.id), timestamp: 18)
        await model.sourceNavigationTask?.value
        await model.workspaceLoadTask?.value
        #expect(model.selectedProjectID == owner.id)
        #expect(model.snapshot?.video.id == video.id)
        #expect(model.sourceReturnLocation == origin)
        #expect(model.seekRequest?.videoID == video.id)
        #expect(model.seekRequest?.timestamp == 18)
        model.requestNavigation(origin)
        await model.workspaceLoadTask?.value
        #expect(model.selectedProjectID == project.id)
        #expect(model.sourceReturnLocation == nil)
    }
    @Test func childNavigationRetainsTheProjectWorkspace() async throws {
        let model = model()
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Navigation")
        model.workspaceLocation = .init(root: .project(project.id))
        await model.loadSelection()
        var child = model.workspaceLocation; child.section = .recordings
        model.requestNavigation(child)
        #expect(model.projectWorkspace?.project?.id == project.id)
        await model.workspaceLoadTask?.value
        model.requestNavigation(.init())
        #expect(model.projectWorkspace == nil)
        await model.workspaceLoadTask?.value
    }
    @Test func archiveAndRestorePreserveStaleFeedbackEvidence() async throws {
        let model = model()
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Archive")
        var batch = try await store.createProjectRequest(projectID: project.id, title: "Request", text: "Fix preview")
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Task", behavior: "Fix preview", checks: [.init(text: "Preview works")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        batch.title = "Changed source"
        batch = try await store.updateFeedback(batch, expectedRevision: batch.revision)
        model.workspaceLocation = .init(root: .project(project.id), task: .feedback(batchID: batch.id, taskID: task.id))
        await model.loadSelection()
        let draft = try #require(model.taskDraft)
        draft.archived = true
        #expect(await model.saveProjectTask())
        var saved = try await store.feedbackSnapshot(id: batch.id).tasks[0]
        #expect(saved.archived)
        #expect(saved.sourceRevision == task.sourceRevision)
        draft.archived = false
        #expect(await model.saveProjectTask())
        saved = try await store.feedbackSnapshot(id: batch.id).tasks[0]
        #expect(!saved.archived)
        #expect(saved.sourceRevision == task.sourceRevision)
        #expect(model.projectWorkspace?.tasks.first?.isStale == true)
    }
    @Test func fixtureConnectionsAndGenerationRemainIsolated() async throws {
        let model = AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), showsDockActivity: false, isUIFixture: true)
        await model.jamSettings.restoreConnection()
        #expect(!model.jamSettings.isConnected)
        model.generateTasks()
        #expect(model.taskGenerationTask == nil)
        #expect(model.errorMessage?.contains("demo library") == true)
        model.errorMessage = nil
        model.generateFeedbackTasks()
        #expect(model.feedbackGenerationTask == nil)
        #expect(model.errorMessage?.contains("demo library") == true)
        await model.prepareFeedback(batchID: "fixture")
        #expect(model.feedbackProgress?.contains("demo library") == true)
    }
    @Test func taskDetailsOnlyExposeTheirOwnSource() async throws {
        let model = model()
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Sources")
        let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let task = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Recording task")), expectedRevision: nil, expectedSource: video.revisions)
        _ = try await store.createProjectRequest(projectID: project.id, title: "Unrelated request", text: "Different requirement")
        model.workspaceLocation = .init(root: .project(project.id), task: .recording(videoID: video.id, taskID: task.id))
        await model.loadSelection()
        #expect(model.taskDraft?.recording?.video.id == video.id)
        #expect(model.taskDraft?.feedback == nil)
    }
}
