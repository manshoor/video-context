import Foundation
import GRDB
import Testing
@testable import VideoContextCore

struct ProjectWorkspaceTests {
    private func library() throws -> VideoContextStore {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try VideoContextStore(databaseURL: root.appending(path: "library.sqlite"))
    }

    @Test func projectContainsBothTaskKindsExactlyOnce() async throws {
        let store = try library()
        let project = try await store.createFeedbackProject(name: "Alpha")
        let other = try await store.createFeedbackProject(name: "Beta")
        let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let task = try await store.saveTask(VideoTask(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Recording task")), expectedRevision: nil, expectedSource: video.revisions)
        let batch = try await store.createProjectRequest(projectID: project.id, title: "Request", text: "Fix the preview")
        let comment = try #require(batch.comments.first)
        let feedback = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: comment.id, sourceRevision: batch.revision,
            content: .init(title: "Request task", behavior: "Show preview", checks: [.init(text: "Preview is visible")], sourceIDs: [comment.id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let snapshot = try await store.projectWorkspace(projectID: project.id)
        #expect(Set(snapshot.tasks.map(\.taskID)) == [task.id, feedback.id])
        #expect(snapshot.tasks.count == 2)
        #expect(snapshot.batches.first?.comments.first?.kind == .request)
        #expect(try await store.projectWorkspace(projectID: other.id).tasks.isEmpty)
    }

    @Test func moveFollowsLinkedSourcesAndInvalidatesReview() async throws {
        let store = try library()
        let a = try await store.createFeedbackProject(name: "A")
        let b = try await store.createFeedbackProject(name: "B")
        let video = VideoRecord(title: "Source", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: a.id)
        try await store.createVideo(video)
        let task = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Fix", behavior: "Fix preview", checks: [.init(text: "Preview works")])), expectedRevision: nil, expectedSource: video.revisions)
        try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: task.revision, expectedSource: video.revisions)
        var batch = FeedbackBatch(projectID: a.id, title: "Related", project: a.name, rawText: "Fix preview")
        let source = FeedbackSource(kind: .recording, status: .ready, recordingID: video.id)
        batch.sources = [source]; batch.comments[0].sourceIDs = [source.id]
        try await store.createFeedback(batch)
        let preview = try await store.previewProjectMove(source: .feedback(batch.id), destinationProjectID: b.id)
        #expect(preview.recordings.map(\.id) == [video.id])
        #expect(preview.batches.map(\.id) == [batch.id])
        try await store.moveProjectSources(preview)
        #expect(try await store.projectWorkspace(projectID: a.id).tasks.isEmpty)
        let moved = try await store.taskSnapshot(videoID: video.id)
        #expect(moved.video.projectID == b.id)
        #expect(moved.tasks[0].reviewedRevision == nil)
        #expect(moved.tasks[0].content == task.content)
        #expect(moved.tasks[0].sourceRevision == video.revisions)
        #expect(try await store.feedbackSnapshot(id: batch.id).batch.projectID == b.id)
        await #expect(throws: TaskContextError.conflict) { try await store.moveProjectSources(preview) }
    }

    @Test func rejectsCrossProjectRecordingLinks() async throws {
        let store = try library()
        let a = try await store.createFeedbackProject(name: "A")
        let b = try await store.createFeedbackProject(name: "B")
        let video = VideoRecord(title: "Source", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", projectID: a.id)
        try await store.createVideo(video)
        let batch = FeedbackBatch(videoID: video.id, projectID: b.id, title: "Wrong project", rawText: "Fix preview")
        await #expect(throws: (any Error).self) { try await store.createFeedback(batch) }
        let unassigned = FeedbackBatch(videoID: video.id, title: "Unassigned", rawText: "New link")
        await #expect(throws: (any Error).self) { try await store.createFeedback(unassigned) }
    }
}

extension ProjectWorkspaceTests {
    private func legacyLibrary(conflict: Bool = false, malformed: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try VideoContextStore.createSchema(in: db)
            try VideoContextStore.createTaskSchema(in: db)
            try VideoContextStore.createFeedbackSchema(in: db)
            try VideoContextStore.createFeedbackProjectSchema(in: db)
            try db.execute(sql: "CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")
            for id in ["createLibrary", "addAPIUsage", "addLocalProviderProvenance", "reviewedTasks", "aiUsageRuns", "feedbackBatches", "feedbackProjects"] {
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES(?)", arguments: [id])
            }
            try db.execute(sql: "INSERT INTO videos VALUES('vid_legacy','Legacy','localFile','fixture','original.mp4',5,'ready',NULL,0,0,0,0,0,0,0,0)")
            try db.execute(sql: "INSERT INTO videos VALUES('vid_inbox','Inbox','localFile','fixture','inbox.mp4',5,'ready',NULL,0,0,0,0,0,0,0,0)")
            let task = VideoTask(id: "task_legacy", videoID: "vid_legacy", sourceRevision: .init(), content: .init(title: "Keep wording", behavior: "Keep", checks: [.init(text: "Works")]))
            var reviewed = task; reviewed.reviewedRevision = 1; reviewed.wasReviewed = true
            try VideoContextStore.writeTask(reviewed, db: db)
            for name in conflict ? ["One", "Two"] : ["One"] {
                let project = try VideoContextStore.feedbackProject(named: name, in: db)
                let batch = FeedbackBatch(videoID: "vid_legacy", projectID: project.id, title: name, project: name, rawText: "Keep context")
                let data = malformed ? Data("invalid".utf8) : try JSONEncoder().encode(batch)
                try db.execute(sql: "INSERT INTO feedback_batches VALUES(?,0,?)", arguments: [batch.id, data])
            }
        }
        return url
    }

    @Test func migrationPreservesReviewAndBacksUpOnce() async throws {
        let url = try legacyLibrary()
        let before = try VideoContextStore(databaseURL: url, access: .readOnly)
        #expect(try await before.taskSnapshot(videoID: "vid_legacy").video.projectID == nil)
        let store = try VideoContextStore(databaseURL: url)
        let project = try #require(try await store.listFeedbackProjects().first)
        let workspace = try await store.projectWorkspace(projectID: project.id)
        #expect(workspace.recordings.map(\.id) == ["vid_legacy"])
        #expect(workspace.tasks.first?.reviewed == true)
        #expect(workspace.tasks.first?.revision == 1)
        #expect(try await store.projectWorkspace(projectID: nil).recordings.map(\.id) == ["vid_inbox"])
        _ = try VideoContextStore(databaseURL: url)
        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("before-projects-") && $0.pathExtension == "sqlite" }
        #expect(backups.count == 1)
        let backup = try DatabaseQueue(path: #require(backups.first).path)
        #expect(try await backup.read { try $0.columns(in: "videos").contains { $0.name == "project_id" } } == false)
    }

    @Test func conflictingAssignmentsStayReadableInInbox() async throws {
        let url = try legacyLibrary(conflict: true)
        let store = try VideoContextStore(databaseURL: url)
        let inbox = try await store.projectWorkspace(projectID: nil)
        #expect(inbox.recordings.count == 2)
        #expect(inbox.conflicts.count == 1)
        #expect(inbox.tasks.first?.reviewed == true)
    }

    @Test func failedMigrationRollsBackSchema() throws {
        let url = try legacyLibrary(malformed: true)
        #expect(throws: (any Error).self) { _ = try VideoContextStore(databaseURL: url) }
        let database = try DatabaseQueue(path: url.path)
        #expect(try database.read { try $0.columns(in: "videos").contains { $0.name == "project_id" } } == false)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM video_tasks") } == 1)
    }

    @Test func mixedHandoffChecksEveryScopeAndRejectsMovedTasks() async throws {
        let store = try library()
        let project = try await store.createFeedbackProject(name: "One")
        let other = try await store.createFeedbackProject(name: "Two")
        let video = VideoRecord(title: "Video", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        _ = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Video task")), expectedRevision: nil, expectedSource: video.revisions)
        let batch = try await store.createProjectRequest(projectID: project.id, title: "Request", text: "Improve preview")
        _ = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Feedback task", behavior: "Improve preview", checks: [.init(text: "Works")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let snapshot = try await store.projectWorkspace(projectID: project.id)
        let selected = Set(snapshot.tasks.map(\.reference))
        let text = try ProjectHandoff.message(snapshot: snapshot, selected: selected, mode: .plan)
        #expect(text.contains("get_video_task")); #expect(text.contains("get_feedback_task"))
        #expect(text.contains(video.id)); #expect(text.contains(batch.id))
        #expect(text.contains("transcript=\(video.revisions.transcript), evidence=\(video.revisions.evidence), brief=\(video.revisions.brief)"))
        #expect(throws: TaskContextError.reviewRequired) { try ProjectHandoff.message(snapshot: snapshot, selected: selected, mode: .implement) }
        try await store.validateProjectHandoff(snapshot: snapshot, selected: selected, mode: .plan)
        let move = try await store.previewProjectMove(source: .recording(video.id), destinationProjectID: other.id)
        try await store.moveProjectSources(move)
        await #expect(throws: TaskContextError.conflict) { try await store.validateProjectHandoff(snapshot: snapshot, selected: selected, mode: .plan) }
    }
}

extension ProjectWorkspaceTests {
    @Test func failedBackupLeavesLegacySchemaUntouched() throws {
        let url = try legacyLibrary()
        let pool = try DatabasePool(path: url.path)
        let impossible = url.deletingLastPathComponent().appending(path: "missing-parent/library.sqlite")
        #expect(throws: (any Error).self) { try VideoContextStore.backupBeforeProjectMigration(pool: pool, databaseURL: impossible) }
        #expect(try pool.read { try $0.columns(in: "videos").contains { $0.name == "project_id" } } == false)
    }
    @Test func oldReadOnlyTaskRetrievalNeedsNoProjectMigration() async throws {
        let url = try legacyLibrary()
        let store = try VideoContextStore(databaseURL: url, access: .readOnly)
        let page = try await TaskMCPService(store: store).task(videoID: "vid_legacy", taskID: "task_legacy", expectedRevision: 1)
        #expect(page.blocks.contains { $0.kind == "title" && $0.text == "Keep wording" })
        #expect(page.canImplement)
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try $0.columns(in: "videos").contains { $0.name == "project_id" } } == false)
    }
    @Test func moveRetainsOutdatedProposalsAndAlreadyStaleFeedback() async throws {
        let store = try library()
        let a = try await store.createFeedbackProject(name: "A"), b = try await store.createFeedbackProject(name: "B")
        let video = VideoRecord(title: "Video", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: a.id)
        try await store.createVideo(video)
        let proposal = TaskProposal(videoID: video.id, kind: .addition, sourceRevision: video.revisions, content: .init(title: "Proposed task"), provenance: .init(provider: .lmStudio, model: "fixture"))
        try await store.publishTaskProposals([proposal], videoID: video.id, expectedSource: video.revisions, expectedTasks: [:])
        var batch = FeedbackBatch(videoID: video.id, projectID: a.id, title: "Feedback", project: a.name, rawText: "Fix preview")
        try await store.createFeedback(batch)
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Fix preview", behavior: "Fix", checks: [.init(text: "Works")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        batch.rawText = "Clarified request"
        _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
        let preview = try await store.previewProjectMove(source: .recording(video.id), destinationProjectID: b.id)
        try await store.moveProjectSources(preview)
        let moved = try await store.projectWorkspace(projectID: b.id)
        #expect(moved.proposals.map(\.id) == [proposal.id])
        #expect(moved.proposals.first?.outdated == true)
        #expect(moved.tasks.first { $0.taskID == task.id }?.isStale == true)
        await #expect(throws: TaskContextError.conflict) { try await store.resolveTaskProposal(videoID: video.id, proposalID: proposal.id, apply: true) }
        try await store.resolveTaskProposal(videoID: video.id, proposalID: proposal.id, apply: false)
        #expect(try await store.taskSnapshot(videoID: video.id).proposals.isEmpty)
    }
    @Test func moveRejectsChangedGroupWithoutPartialOwnershipChanges() async throws {
        let store = try library()
        let a = try await store.createFeedbackProject(name: "A"), b = try await store.createFeedbackProject(name: "B")
        let video = VideoRecord(title: "Video", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", status: .ready, projectID: a.id)
        try await store.createVideo(video)
        let preview = try await store.previewProjectMove(source: .recording(video.id), destinationProjectID: b.id)
        let batch = FeedbackBatch(videoID: video.id, projectID: a.id, title: "Added after preview", rawText: "Fix")
        try await store.createFeedback(batch)
        await #expect(throws: TaskContextError.conflict) { try await store.moveProjectSources(preview) }
        #expect(try await store.videoSnapshot(id: video.id)?.video.projectID == a.id)
        #expect(try await store.feedbackSnapshot(id: batch.id).batch.projectID == a.id)
    }
}
