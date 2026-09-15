import Foundation
import Testing
@testable import VideoContextCore

struct ReviewedTaskTests {
    func fixture() async throws -> (VideoContextStore, VideoRecord, VideoTask) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let video = VideoRecord(title: "Shared title", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", status: .ready)
        try await store.createVideo(video)
        let task = VideoTask(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Change label", behavior: "Show Save", checks: [.init(text: "Button reads Save")]))
        return (store, video, try await store.saveTask(task, expectedRevision: nil, expectedSource: video.revisions))
    }
    @Test func reviewAndEdit() async throws {
        let (store, video, task) = try await fixture()
        #expect(!task.canImplement(video))
        try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: task.revision, expectedSource: video.revisions)
        var reviewed = try #require(try await store.taskSnapshot(videoID: video.id).tasks.first)
        #expect(reviewed.canImplement(video))
        reviewed.content.questions.append(.init(question: "Which screen?"))
        let updated = try await store.saveTask(reviewed, expectedRevision: reviewed.revision, expectedSource: video.revisions)
        #expect(!updated.canImplement(video)); #expect(updated.id == task.id)
        await #expect(throws: TaskContextError.reviewRequired) { try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: updated.revision, expectedSource: video.revisions) }
        await #expect(throws: TaskContextError.conflict) { try await store.saveTask(reviewed, expectedRevision: reviewed.revision, expectedSource: video.revisions) }
    }
    @Test func sourceChangesInvalidateReview() async throws {
        let (store, video, task) = try await fixture()
        try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: 1, expectedSource: video.revisions)
        try await store.updateBrief(videoID: video.id, markdown: "Changed requirements")
        let current = try await store.taskSnapshot(videoID: video.id)
        #expect(current.tasks[0].isStale(current.video)); #expect(current.tasks[0].reviewedRevision == nil)
        #expect(current.tasks[0].revision == 3)
    }
    @Test func foreignEvidenceAndProposalsAreRejected() async throws {
        let (store, video, task) = try await fixture()
        var bad = task; bad.content.sourceIDs = ["ev_other_recording"]
        await #expect(throws: (any Error).self) { try await store.saveTask(bad, expectedRevision: 1, expectedSource: video.revisions) }
        let proposal = TaskProposal(videoID: video.id, kind: .modification, taskID: task.id, expectedTaskRevision: 1, sourceRevision: video.revisions, content: .init(title: "Proposed"), provenance: .init(provider: .lmStudio, model: "test"))
        try await store.publishTaskProposals([proposal], videoID: video.id, expectedSource: video.revisions, expectedTasks: [task.id: 1])
        var edit = task; edit.content.title = "User correction"
        _ = try await store.saveTask(edit, expectedRevision: 1, expectedSource: video.revisions)
        await #expect(throws: TaskContextError.conflict) { try await store.resolveTaskProposal(videoID: video.id, proposalID: proposal.id, apply: true) }
        #expect(try await store.taskSnapshot(videoID: video.id).tasks[0].content.title == "User correction")
    }
}

extension ReviewedTaskTests {
    @Test func handoffModesAndExactIsolation() async throws {
        let (store, video, task) = try await fixture()
        let second = VideoRecord(title: video.title, source: .localFile, sourceValue: "fixture", mediaRelativePath: "other.mp4", status: .ready)
        try await store.createVideo(second)
        let context = TaskMCPService(store: store)
        await #expect(throws: (any Error).self) { try await context.task(videoID: second.id, taskID: task.id) }
        await #expect(throws: (any Error).self) { try await context.list(videoID: "vid_unknown") }
        let draft = try await store.taskSnapshot(videoID: video.id)
        for mode in [TaskHandoffMode.plan, .investigate] {
            let message = try TaskHandoff.message(snapshot: draft, selectedIDs: [task.id], mode: mode)
            #expect(message.contains(task.id)); #expect(message.contains(video.id)); #expect(message.contains("expected_revision=1")); #expect(message.contains("Do not modify code"))
        }
        #expect(throws: TaskContextError.reviewRequired) { try TaskHandoff.message(snapshot: draft, selectedIDs: [task.id], mode: .implement) }
        try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: 1, expectedSource: video.revisions)
        let reviewed = try await store.taskSnapshot(videoID: video.id)
        #expect(try TaskHandoff.message(snapshot: reviewed, selectedIDs: [task.id], mode: .implement).contains("expected_revision=2"))
        await #expect(throws: TaskContextError.conflict) { try await context.task(videoID: video.id, taskID: task.id, expectedRevision: 1) }
    }
    @Test func paginationBoundToRevisionAndTask() async throws {
        let (store, video, task) = try await fixture()
        var long = task; long.content.behavior = String(repeating: "Do this step. ", count: 3000) + "FINAL_SENTENCE"
        let value = try await store.saveTask(long, expectedRevision: 1, expectedSource: video.revisions)
        let context = TaskMCPService(store: store)
        let first = try await context.task(videoID: video.id, taskID: task.id)
        let cursor = try #require(first.nextCursor)
        let other = VideoTask(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Other task"))
        _ = try await store.saveTask(other, expectedRevision: nil, expectedSource: video.revisions)
        await #expect(throws: TaskContextError.conflict) { try await context.task(videoID: video.id, taskID: other.id, cursor: cursor) }
        var text = first.blocks.map(\.text).joined(), next = first.nextCursor
        while let current = next {
            let page = try await context.task(videoID: video.id, taskID: task.id, cursor: current)
            text += page.blocks.map(\.text).joined(); next = page.nextCursor
        }
        #expect(text.contains("FINAL_SENTENCE"))
        _ = try await store.saveTask(value, expectedRevision: value.revision, expectedSource: video.revisions)
        await #expect(throws: TaskContextError.conflict) { try await context.task(videoID: video.id, taskID: task.id, cursor: cursor) }
    }
    @Test func nonBlockingRequiresReasonAndAnswersResolveBlockers() {
        var question = TaskQuestion(question: "Which label?")
        #expect(question.unresolved)
        question.isBlocking = false; #expect(question.unresolved)
        question.nonBlockingReason = "Cosmetic detail; preserve existing label"; #expect(!question.unresolved)
        question.isBlocking = true; question.answer = "Use Save"; #expect(!question.unresolved)
    }
    @Test func annotationsAndReorderingPreserveIdentity() async throws {
        let (store, video, task) = try await fixture()
        let second = try await store.saveTask(VideoTask(videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Second"), order: 1), expectedRevision: nil, expectedSource: video.revisions)
        try await store.moveTask(videoID: video.id, taskID: second.id, direction: -1, expectedRevision: 1, expectedSource: video.revisions)
        #expect(try await store.taskSnapshot(videoID: video.id).tasks.map(\.id) == [second.id, task.id])
        var annotation = TaskAnnotation(evidenceID: "ev_1", kind: .rectangle)
        #expect(!annotation.isValid); annotation.text = "Change this"; #expect(annotation.isValid)
        annotation.x = .nan; #expect(!annotation.isValid)
    }
}
