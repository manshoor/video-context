import Foundation
import GRDB
import Testing
@testable import VideoContextCore

struct TaskDeletionTests {
    private func library() throws -> VideoContextStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "video-context-deletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try VideoContextStore(databaseURL: root.appending(path: "library.sqlite"))
    }

    private func ensureDeletionSchema(_ store: VideoContextStore) async throws {
        try await store.pool.write { db in
            try VideoContextStore.createTaskDeletionSchema(in: db)
        }
    }

    private func generatedRecordingTask(video: VideoRecord, sourceID: String, title: String = "Generated task") -> VideoTask {
        let content = TaskContent(title: title, behavior: "Show the updated state",
                                  requirements: [.init(text: "The state is visible", origin: .recording, sourceIDs: [sourceID])],
                                  checks: [.init(text: "The state is visible", origin: .recording, sourceIDs: [sourceID])],
                                  sourceIDs: [sourceID])
        return VideoTask(videoID: video.id, sourceRevision: video.revisions, content: content,
                         provenance: .init(provider: .lmStudio, model: "fixture"))
    }

    @Test func permanentlyDeletesRecordingTaskAndBlocksRegenerationUntilReset() async throws {
        let store = try library()
        try await ensureDeletionSchema(store)
        let project = try await store.createFeedbackProject(name: "Deletion project")
        let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture",
                                mediaRelativePath: "recording.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let segment = TranscriptSegment(videoID: video.id, start: 1, end: 2, originalText: "Show the state")
        try await store.replaceTranscript(videoID: video.id, segments: [segment])
        var currentVideo = try #require(try await store.videoSnapshot(id: video.id)?.video)
        try await store.publishBrief(videoID: video.id, brief: .init(videoID: video.id, markdown: "Fixture brief"),
                                     expectedRevision: currentVideo.revisions)
        currentVideo = try #require(try await store.videoSnapshot(id: video.id)?.video)
        let deleted = try await store.saveTask(generatedRecordingTask(video: currentVideo, sourceID: segment.id),
                                               expectedRevision: nil, expectedSource: currentVideo.revisions)
        let remaining = try await store.saveTask(.init(videoID: video.id, sourceRevision: currentVideo.revisions,
                                                        content: .init(title: "Keep this task")),
                                                 expectedRevision: nil, expectedSource: currentVideo.revisions)
        let epoch = try await store.taskGenerationEpoch(source: .recording(video.id))
        let usageRun = try await store.startUsageRun(.init(videoID: video.id, operation: .taskGeneration,
            provider: .lmStudio, model: "fixture", fingerprint: "fixture"))
        var usageAttempt = UsageAttempt(runID: usageRun.id, stage: .taskExtraction, provider: .lmStudio, requestedModel: "fixture")
        usageAttempt.outcome = .completed
        try await store.saveUsageAttempt(usageAttempt)
        try await store.saveTaskCache(key: "deleted-recording-cache", data: Data("Generated task".utf8),
                                      source: .recording(video.id), expectedEpoch: epoch)
        try await store.recordUsageCache(key: "deleted-recording-cache", runID: usageRun.id, reused: false)
        let proposal = TaskProposal(videoID: video.id, kind: .modification, taskID: deleted.id,
                                    expectedTaskRevision: deleted.revision, sourceRevision: currentVideo.revisions,
                                    content: .init(title: "Proposed deleted task"),
                                    provenance: .init(provider: .lmStudio, model: "fixture"))
        try await store.publishTaskProposals([proposal], videoID: video.id, expectedSource: currentVideo.revisions,
                                             expectedTasks: [deleted.id: deleted.revision, remaining.id: remaining.revision],
                                             expectedGenerationEpoch: epoch)

        let preview = try await store.previewProjectTaskDeletion(projectID: project.id,
            selected: [.recording(videoID: video.id, taskID: deleted.id)])
        #expect(preview.tasks.count == 1)
        #expect(preview.tasks[0].title == "Generated task")
        #expect(preview.tasks[0].reviewed == false)
        try await store.deleteProjectTasks(preview)

        let after = try await store.taskSnapshot(videoID: video.id)
        #expect(after.tasks.map(\.id) == [remaining.id])
        let lateArchive = TaskProposal(videoID: video.id, kind: .archive, taskID: remaining.id, expectedTaskRevision: remaining.revision,
            sourceRevision: currentVideo.revisions, provenance: .init(provider: .lmStudio, model: "fixture"))
        try await store.publishTaskProposals([lateArchive], videoID: video.id, expectedSource: currentVideo.revisions,
            expectedTasks: [remaining.id: remaining.revision], expectedGenerationEpoch: epoch + 1)
        #expect(try await store.taskSnapshot(videoID: video.id).proposals.isEmpty)
        #expect(after.video.id == video.id)
        #expect(try await store.taskCache(key: "deleted-recording-cache") == nil)
        #expect(try await store.taskGenerationExclusions(source: .recording(video.id)).count == 1)
        #expect(try await store.taskGenerationExclusions(source: .recording(video.id))[0].identityKey == "source-wide")
        #expect(try await store.taskGenerationExclusions(source: .recording(video.id))[0].reason.contains("reconciliation"))
        #expect(try await store.taskGenerationEpoch(source: .recording(video.id)) == epoch + 1)
        await #expect(throws: TaskContextError.conflict) {
            try await store.saveTask(deleted, expectedRevision: nil, expectedSource: currentVideo.revisions)
        }
        await #expect(throws: TaskContextError.conflict) {
            try await store.saveTaskCache(key: "late-cache", data: Data(), source: .recording(video.id), expectedEpoch: epoch)
        }
        let blockedContent = generatedRecordingTask(video: currentVideo, sourceID: segment.id, title: "Would return").content
        try await store.publishTaskProposals([.init(videoID: video.id, kind: .addition,
            sourceRevision: currentVideo.revisions, content: blockedContent,
            provenance: .init(provider: .lmStudio, model: "fixture"))],
            videoID: video.id, expectedSource: currentVideo.revisions,
            expectedTasks: [remaining.id: remaining.revision], expectedGenerationEpoch: epoch + 1)
        #expect(try await store.taskSnapshot(videoID: video.id).proposals.isEmpty)
        try await store.resetTaskGenerationExclusions(source: .recording(video.id), projectID: project.id)
        #expect(try await store.taskGenerationExclusions(source: .recording(video.id)).isEmpty)
        #expect(try await store.taskGenerationEpoch(source: .recording(video.id)) == epoch + 2)

        let counts = try await store.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_history WHERE task_id=?", arguments: [deleted.id]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_proposals WHERE id=?", arguments: [proposal.id]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_deletion_tombstones WHERE task_id=?", arguments: [deleted.id]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_runs WHERE id=?", arguments: [usageRun.id]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_attempts WHERE run_id=?", arguments: [usageRun.id]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_generation_cache WHERE cache_key=?", arguments: ["deleted-recording-cache"]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_cache_origins WHERE cache_key=?", arguments: ["deleted-recording-cache"]) ?? -1,
                try Data.fetchAll(db, sql: "SELECT document FROM usage_runs WHERE id=? UNION ALL SELECT document FROM usage_attempts WHERE run_id=?", arguments: [usageRun.id, usageRun.id])
            )
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 1)
        #expect(counts.3 == 1)
        #expect(counts.4 == 1)
        #expect(counts.5 == 0)
        #expect(counts.6 == 0)
        #expect(counts.7.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("Generated task") })
    }

    @Test func permanentlyDeletesFeedbackTaskButPreservesBatchAndComment() async throws {
        let store = try library()
        try await ensureDeletionSchema(store)
        let project = try await store.createFeedbackProject(name: "Feedback deletion")
        let batch = try await store.createProjectRequest(projectID: project.id, title: "Request", text: "Fix the preview")
        let comment = try #require(batch.comments.first)
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: comment.id,
            sourceRevision: batch.revision,
            content: .init(title: "Preview task", behavior: "Fix preview",
                            checks: [.init(text: "Preview works")], sourceIDs: [comment.id])),
            expectedRevision: nil, expectedBatchRevision: batch.revision)
        let preview = try await store.previewProjectTaskDeletion(projectID: project.id,
            selected: [.feedback(batchID: batch.id, taskID: task.id)])
        #expect(preview.tasks[0].expectedSourceRevision == .feedback(batch.revision))
        try await store.deleteProjectTasks(preview)

        let after = try await store.feedbackSnapshot(id: batch.id)
        #expect(after.batch.id == batch.id)
        #expect(after.batch.comments.contains(where: { $0.id == comment.id && $0.text == "Fix the preview" }))
        #expect(after.tasks.isEmpty)
        #expect(try await store.taskGenerationExclusions(source: .feedback(batch.id)).map(\.identityKey) == ["issue:\(comment.id)"])
        await #expect(throws: TaskContextError.conflict) {
            try await store.saveFeedbackTask(task, expectedRevision: nil, expectedBatchRevision: batch.revision)
        }
        try await store.resetTaskGenerationExclusions(source: .feedback(batch.id), projectID: project.id)
        let resetEpoch = try await store.taskGenerationEpoch(source: .feedback(batch.id))
        let regenerated = FeedbackTask(id: task.id, batchID: batch.id, issueID: comment.id,
            sourceRevision: batch.revision,
            content: .init(title: "Regenerated preview task", behavior: "Fix preview",
                            checks: [.init(text: "Preview works")], sourceIDs: [comment.id]),
            provenance: .init(provider: .lmStudio, model: "fixture"))
        try await store.publishFeedbackGeneration(batchID: batch.id, expectedRevision: batch.revision,
            expectedTasks: [:], generated: [regenerated], expectedGenerationEpoch: resetEpoch)
        let regeneratedSnapshot = try await store.feedbackSnapshot(id: batch.id)
        #expect(regeneratedSnapshot.tasks.count == 1)
        #expect(regeneratedSnapshot.tasks[0].id != task.id)
        let historyCount = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feedback_task_history WHERE task_id=?", arguments: [task.id]) ?? -1
        }
        #expect(historyCount == 0)
    }

    @Test func staleMultiTaskPreviewRollsBackWithoutPartialDeletion() async throws {
        let store = try library()
        try await ensureDeletionSchema(store)
        let project = try await store.createFeedbackProject(name: "Stale preview")
        let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture",
                                mediaRelativePath: "recording.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let first = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions,
            content: .init(title: "First")), expectedRevision: nil, expectedSource: video.revisions)
        let second = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions,
            content: .init(title: "Second")), expectedRevision: nil, expectedSource: video.revisions)
        let preview = try await store.previewProjectTaskDeletion(projectID: project.id,
            selected: [.recording(videoID: video.id, taskID: first.id), .recording(videoID: video.id, taskID: second.id)])
        var edit = first
        edit.content.title = "Edited first"
        _ = try await store.saveTask(edit, expectedRevision: first.revision, expectedSource: video.revisions)
        await #expect(throws: TaskContextError.conflict) { try await store.deleteProjectTasks(preview) }
        #expect(try await store.taskSnapshot(videoID: video.id).tasks.map(\.id).sorted() == [first.id, second.id].sorted())
    }

    @Test func reidentifiedDeletedFeedbackRequiresReconciliationBeforePublishing() async throws {
        let store = try library(), project = try await store.createFeedbackProject(name: "Reconciliation")
        let batch = try await store.createProjectRequest(projectID: project.id, title: "Request", text: "Fix preview")
        let oldComment = batch.comments[0]
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: oldComment.id, sourceRevision: batch.revision,
            content: .init(title: "Preview", behavior: "Fix preview", checks: [.init(text: "Visible")], sourceIDs: [oldComment.id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let preview = try await store.previewProjectTaskDeletion(projectID: project.id, selected: [.feedback(batchID: batch.id, taskID: task.id)])
        try await store.deleteProjectTasks(preview)
        var changed = batch; changed.comments = [.init(text: "Fix preview", kind: .request)]
        let saved = try await store.updateFeedback(changed, expectedRevision: batch.revision)
        #expect(try await store.taskGenerationExclusions(source: .feedback(batch.id)).contains { $0.identityKey == "source-wide" })
        let proposed = FeedbackTask(batchID: batch.id, issueID: saved.comments[0].id, sourceRevision: saved.revision,
            content: .init(title: "Preview again", behavior: "Fix preview", checks: [.init(text: "Visible")], sourceIDs: [saved.comments[0].id]))
        try await store.publishFeedbackGeneration(batchID: batch.id, expectedRevision: saved.revision, expectedTasks: [:], generated: [proposed])
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks.isEmpty)
        #expect(try await store.feedbackSourceRevision(batchID: batch.id, revision: batch.revision).comments[0].id == oldComment.id)
    }

    @Test(arguments: ["recording", "feedback", "request"], ["active", "reviewed", "archived"])
    func deletesEveryTaskKindAndState(kind: String, state: String) async throws {
        let store = try library(), project = try await store.createFeedbackProject(name: "Delete \(kind) \(state)")
        let reference: ProjectTaskReference
        if kind == "recording" {
            let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", status: .ready, projectID: project.id)
            try await store.createVideo(video)
            var task = try await store.saveTask(.init(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Task", behavior: "Visible", checks: [.init(text: "Visible")])), expectedRevision: nil, expectedSource: video.revisions)
            if state == "reviewed" { try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: task.revision, expectedSource: video.revisions) }
            if state == "archived" { task.archived = true; _ = try await store.saveTask(task, expectedRevision: task.revision, expectedSource: video.revisions) }
            reference = .recording(videoID: video.id, taskID: task.id)
        } else {
            var batch = FeedbackBatch(projectID: project.id, title: "Source", project: project.name, rawText: "Show preview")
            batch.comments[0].kind = kind == "request" ? .request : .feedback
            try await store.createFeedback(batch)
            var task = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: batch.comments[0].id, sourceRevision: batch.revision,
                content: .init(title: "Task", behavior: "Visible", checks: [.init(text: "Visible")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
            if state == "reviewed" { try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision, expectedTaskRevisions: [task.id: task.revision]) }
            if state == "archived" { task.archived = true; _ = try await store.saveFeedbackTask(task, expectedRevision: task.revision, expectedBatchRevision: batch.revision) }
            reference = .feedback(batchID: batch.id, taskID: task.id)
        }
        let preview = try await store.previewProjectTaskDeletion(projectID: project.id, selected: [reference])
        #expect(preview.tasks[0].archived == (state == "archived"))
        #expect(preview.tasks[0].reviewed == (state == "reviewed"))
        try await store.deleteProjectTasks(preview)
        #expect(try await store.projectWorkspace(projectID: project.id).tasks.isEmpty)
    }

    @Test func databaseFailureRollsBackTasksAndDeletionLedgers() async throws {
        let store = try library(), project = try await store.createFeedbackProject(name: "Rollback")
        let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        for id in ["task_rollback_first", "task_rollback_second"] {
            _ = try await store.saveTask(.init(id: id, videoID: video.id, sourceRevision: video.revisions, content: .init(title: id)), expectedRevision: nil, expectedSource: video.revisions)
        }
        let refs = Set(["task_rollback_first", "task_rollback_second"].map { ProjectTaskReference.recording(videoID: video.id, taskID: $0) })
        let preview = try await store.previewProjectTaskDeletion(projectID: project.id, selected: refs)
        try await store.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER controlled_delete_failure BEFORE DELETE ON video_tasks WHEN OLD.id='task_rollback_second' BEGIN SELECT RAISE(ABORT,'controlled deletion failure'); END")
        }
        await #expect(throws: (any Error).self) { try await store.deleteProjectTasks(preview) }
        #expect(try await store.taskSnapshot(videoID: video.id).tasks.count == 2)
        #expect(try await store.taskGenerationExclusions(source: .recording(video.id)).isEmpty)
        #expect(try await store.taskGenerationEpoch(source: .recording(video.id)) == 0)
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task_deletion_tombstones") } == 0)
    }

    @Test func deletingOneFeedbackIssuePreservesAnUnrelatedProposal() async throws {
        let store = try library(), project = try await store.createFeedbackProject(name: "Independent issues")
        var batch = FeedbackBatch(projectID: project.id, title: "Feedback", project: project.name, rawText: "Fix preview. Fix receipt.")
        batch.comments = [.init(text: "Fix preview"), .init(text: "Fix receipt")]
        try await store.createFeedback(batch)
        var tasks: [FeedbackTask] = []
        for comment in batch.comments {
            tasks.append(try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: comment.id, sourceRevision: batch.revision,
                content: .init(title: comment.text, behavior: comment.text, checks: [.init(text: "Works")], sourceIDs: [comment.id])), expectedRevision: nil, expectedBatchRevision: batch.revision))
        }
        let generated = tasks.map { task in
            var next = task; next.content.behavior += " with clear guidance"; return next
        }
        try await store.publishFeedbackGeneration(batchID: batch.id, expectedRevision: batch.revision,
            expectedTasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.revision) }), generated: generated)
        let preview = try await store.previewProjectTaskDeletion(projectID: project.id, selected: [.feedback(batchID: batch.id, taskID: tasks[0].id)])
        try await store.deleteProjectTasks(preview)
        let remaining = try await store.feedbackSnapshot(id: batch.id)
        #expect(remaining.proposals.count == 1)
        let proposal = try #require(remaining.proposals.first)
        #expect(proposal.taskID == tasks[1].id)
        try await store.resolveFeedbackProposal(batchID: batch.id, proposalID: proposal.id, apply: true)
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks[0].content.behavior.contains("clear guidance"))
    }

    @Test func deletingRecordingTaskKeepsUnrelatedSourceWideProposalOutdated() async throws {
        let store = try library()
        try await ensureDeletionSchema(store)
        let project = try await store.createFeedbackProject(name: "Recording proposal preservation")
        let video = VideoRecord(title: "Recording", source: .localFile, sourceValue: "fixture",
                                mediaRelativePath: "recording.mp4", status: .ready, projectID: project.id)
        try await store.createVideo(video)
        let segment = TranscriptSegment(videoID: video.id, start: 1, end: 2, originalText: "Show the state")
        try await store.replaceTranscript(videoID: video.id, segments: [segment])
        var currentVideo = try #require(try await store.videoSnapshot(id: video.id)?.video)
        try await store.publishBrief(videoID: video.id, brief: .init(videoID: video.id, markdown: "Fixture brief"),
                                     expectedRevision: currentVideo.revisions)
        currentVideo = try #require(try await store.videoSnapshot(id: video.id)?.video)
        let target = try await store.saveTask(generatedRecordingTask(video: currentVideo, sourceID: segment.id, title: "Target task"),
                                              expectedRevision: nil, expectedSource: currentVideo.revisions)
        let unrelated = try await store.saveTask(generatedRecordingTask(video: currentVideo, sourceID: segment.id, title: "Unrelated task"),
                                                  expectedRevision: nil, expectedSource: currentVideo.revisions)
        let targetProposal = TaskProposal(videoID: video.id, kind: .modification, taskID: target.id,
                                          expectedTaskRevision: target.revision, sourceRevision: currentVideo.revisions,
                                          content: .init(title: "Target proposal"), provenance: .init(provider: .lmStudio, model: "fixture"))
        let unrelatedProposal = TaskProposal(videoID: video.id, kind: .modification, taskID: unrelated.id,
                                             expectedTaskRevision: unrelated.revision, sourceRevision: currentVideo.revisions,
                                             content: .init(title: "Unrelated proposal"), provenance: .init(provider: .lmStudio, model: "fixture"))
        try await store.publishTaskProposals([targetProposal, unrelatedProposal], videoID: video.id,
                                             expectedSource: currentVideo.revisions,
                                             expectedTasks: [target.id: target.revision, unrelated.id: unrelated.revision])

        let preview = try await store.previewProjectTaskDeletion(projectID: project.id,
            selected: [.recording(videoID: video.id, taskID: target.id)])
        try await store.deleteProjectTasks(preview)

        let remaining = try await store.taskSnapshot(videoID: video.id)
        #expect(remaining.proposals.map(\.id) == [unrelatedProposal.id])
        await #expect(throws: TaskContextError.conflict) {
            try await store.resolveTaskProposal(videoID: video.id, proposalID: unrelatedProposal.id, apply: true)
        }
    }

    @Test func deletingFeedbackTaskWithoutIssueIDKeepsUnrelatedSourceWideProposalOutdated() async throws {
        let store = try library()
        try await ensureDeletionSchema(store)
        let project = try await store.createFeedbackProject(name: "Ambiguous feedback proposal preservation")
        var batch = FeedbackBatch(projectID: project.id, title: "Feedback", project: project.name, rawText: "Fix preview. Fix receipt.")
        batch.comments = [.init(text: "Fix preview"), .init(text: "Fix receipt")]
        try await store.createFeedback(batch)
        let targetContent = TaskContent(title: "Target task", behavior: "Fix the preview",
                                        checks: [.init(text: "Preview works")], sourceIDs: [batch.comments[0].id])
        let unrelatedContent = TaskContent(title: "Unrelated task", behavior: "Fix the receipt",
                                           checks: [.init(text: "Receipt works")], sourceIDs: [batch.comments[1].id])
        let target = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: nil, sourceRevision: batch.revision,
                                                            content: targetContent), expectedRevision: nil,
                                                      expectedBatchRevision: batch.revision)
        let unrelated = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: nil, sourceRevision: batch.revision,
                                                               content: unrelatedContent), expectedRevision: nil,
                                                         expectedBatchRevision: batch.revision)
        var targetReplacement = targetContent
        targetReplacement.title = "Target proposal"
        var unrelatedReplacement = unrelatedContent
        unrelatedReplacement.title = "Unrelated proposal"
        let targetProposal = try await store.prepareFeedbackTaskConsolidation(batchID: batch.id, taskID: target.id,
            expectedBatchRevision: batch.revision, expectedTaskRevision: target.revision,
            replacement: targetReplacement)
        let unrelatedProposal = try await store.prepareFeedbackTaskConsolidation(batchID: batch.id, taskID: unrelated.id,
            expectedBatchRevision: batch.revision, expectedTaskRevision: unrelated.revision,
            replacement: unrelatedReplacement)

        let preview = try await store.previewProjectTaskDeletion(projectID: project.id,
            selected: [.feedback(batchID: batch.id, taskID: target.id)])
        try await store.deleteProjectTasks(preview)

        let remaining = try await store.feedbackSnapshot(id: batch.id)
        #expect(remaining.proposals.map(\.id) == [unrelatedProposal.id])
        await #expect(throws: TaskContextError.conflict) {
            try await store.resolveFeedbackProposal(batchID: batch.id, proposalID: unrelatedProposal.id, apply: true)
        }
        #expect(!remaining.proposals.contains { $0.id == targetProposal.id })
    }
}
