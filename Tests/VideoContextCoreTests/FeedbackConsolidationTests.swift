import Foundation
import GRDB
import Testing
@testable import VideoContextCore

struct FeedbackConsolidationTests {
    @Test func fifteenEvidencePassesBecomeOneConciseTaskWithoutLosingFactsOrCitations() async throws {
        let fixture = try await generationFixture(sourceCount: 29)
        let issue = try #require(fixture.batch.comments.first)
        let client = FifteenPassConsolidationClient(issueID: issue.id, sourceIDs: fixture.batch.sources.map(\.id))
        let generator = FeedbackGenerator(client: client,
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")),
            credential: "", paths: fixture.paths, store: fixture.store)

        let generated = try await generator.generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
        let task = try #require(generated.first)

        #expect(generated.count == 1)
        #expect(task.content.behavior == "Upload the selected files while progress remains visible.")
        #expect(task.content.requirements.map(\.text) == [
            issue.text,
            "Keep upload progress visible until completion.",
            "Cancellation keeps every completed upload."
        ])
        #expect(task.content.checks.map(\.text) == ["Progress stays visible and completed uploads survive cancellation."])
        #expect(task.content.questions.map(\.question) == ["Should cancellation stop only pending uploads?"])
        #expect(task.content.requirements.filter { $0.text == issue.text }.count == 1)
        #expect(task.content.allSourceIDs == Set([issue.id] + fixture.batch.sources.map(\.id)))
        #expect(await client.extractionCount == 15)
        #expect(await client.consolidationCount == 2)
    }

    @Test func contradictionsStayDistinctAndProduceAnUnresolvedQuestion() async throws {
        let first = "fcom_00000000-0000-0000-0000-000000000001"
        let second = "fsrc_00000000-0000-0000-0000-000000000002"
        let content = TaskContent(title: "Upload selection", behavior: "Upload files",
            requirements: [
                .init(text: "Upload only selected files.", origin: .feedback, sourceIDs: [first]),
                .init(text: "Upload every file in the folder.", origin: .feedback, sourceIDs: [second])
            ], checks: [.init(text: "Uploads finish.", origin: .interpretation, sourceIDs: [first, second])],
            sourceIDs: [first, second])
        let client = StaticConsolidationClient(plan: .init(
            title: "Upload selection", behavior: "Upload files after the selection rule is resolved.",
            requirements: [
                .init(members: [0], text: "Upload only selected files."),
                .init(members: [1], text: "Upload every file in the folder.")
            ], checks: [.init(members: [0], text: "Uploads finish.")], questions: [],
            additionalQuestions: [.init(question: "Should the upload include only selected files or every file in the folder?", sourceIDs: [first, second])]
        ))

        let replacement = try await FeedbackContentConsolidator(client: client,
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")), credential: "")
            .consolidate(content: content, generatedOriginal: content)

        #expect(replacement.requirements.map(\.text) == content.requirements.map(\.text))
        let question = try #require(replacement.questions.first)
        #expect(question.unresolved)
        #expect(Set(question.sourceIDs) == Set([first, second]))
    }

    @Test func savedTaskConsolidationIsReviewableAndPreservesUserStateHistoryAndEvidence() async throws {
        let fixture = try await storedTaskFixture()
        var task = fixture.task
        let original = task.content
        task.content.title = "My edited upload title"
        task.content.behavior = "My edited upload behavior"
        task.content.requirements.append(.init(text: "Keep my manual retry rule.", origin: .user, sourceIDs: [fixture.sourceID]))
        task.content.questions[0].answer = "Only pending files"
        task.content.annotations = [.init(evidenceID: fixture.sourceID, kind: .note)]
        task.content.annotations[0].text = "Keep this annotation"
        task = try await fixture.store.saveFeedbackTask(task, expectedRevision: task.revision,
                                                        expectedBatchRevision: fixture.batch.revision)
        try await fixture.store.approveFeedbackTasks(batchID: fixture.batch.id,
            expectedBatchRevision: fixture.batch.revision, expectedTaskRevisions: [task.id: task.revision])
        task = try #require(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.first)
        #expect(task.isApproved)

        let client = StaticConsolidationClient(plan: .init(
            title: task.content.title, behavior: task.content.behavior,
            requirements: [
                .init(members: [0, 1], text: "Keep upload progress visible."),
                .init(members: [2], text: "Keep my manual retry rule.")
            ], checks: [.init(members: [0, 1], text: "Upload progress remains visible.")],
            questions: [.init(members: [0, 1], text: "Which uploads should cancellation stop?")],
            additionalQuestions: []
        ))
        let replacement = try await FeedbackContentConsolidator(client: client,
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")), credential: "")
            .consolidate(content: task.content, generatedOriginal: original)
        let proposal = try await fixture.store.prepareFeedbackTaskConsolidation(batchID: fixture.batch.id,
            taskID: task.id, expectedBatchRevision: fixture.batch.revision, expectedTaskRevision: task.revision,
            replacement: replacement)

        let beforeApply = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(beforeApply.tasks[0] == task)
        #expect(beforeApply.proposals.map(\.id) == [proposal.id])
        #expect(proposal.content.requirements.count == 2)
        #expect(proposal.content.checks.count == 1)
        #expect(proposal.content.questions.count == 1)
        #expect(proposal.content.title == "My edited upload title")
        #expect(proposal.content.behavior == "My edited upload behavior")
        #expect(proposal.content.questions[0].answer == "Only pending files")
        #expect(proposal.content.annotations == task.content.annotations)
        #expect(proposal.content.allSourceIDs == task.content.allSourceIDs)

        try await fixture.store.resolveFeedbackProposal(batchID: fixture.batch.id, proposalID: proposal.id, apply: true)
        let applied = try #require(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.first)
        #expect(applied.id == task.id)
        #expect(applied.isApproved == false)
        #expect(applied.content.questions[0].answer == "Only pending files")
        #expect(applied.content.requirements.contains { $0.text == "Keep my manual retry rule." && $0.origin == .user })
        #expect(applied.content.annotations == task.content.annotations)
        #expect(applied.generatedOriginal == original)
        let database = try DatabaseQueue(path: fixture.paths.database.path)
        let taskID = task.id
        let historyCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feedback_task_history WHERE task_id=?", arguments: [taskID])
        }
        #expect(historyCount == 4)
    }

    @Test func removalRestorationAndStaleBulkRemovalAreAtomic() async throws {
        let fixture = try await removalFixture(taskCount: 2)
        let revisions = Dictionary(uniqueKeysWithValues: fixture.tasks.map { ($0.id, $0.revision) })
        try await fixture.store.setFeedbackTasksArchived(batchID: fixture.batch.id,
            expectedBatchRevision: fixture.batch.revision, expectedTaskRevisions: revisions, archived: true)
        var snapshot = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(snapshot.tasks.allSatisfy { $0.archived })
        #expect(snapshot.tasks.allSatisfy { $0.approvedRevision == nil && $0.revision == 2 })

        let removedRevisions = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.revision) })
        try await fixture.store.setFeedbackTasksArchived(batchID: fixture.batch.id,
            expectedBatchRevision: fixture.batch.revision, expectedTaskRevisions: removedRevisions, archived: false)
        snapshot = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(snapshot.tasks.allSatisfy { $0.archived == false && $0.revision == 3 })

        let stale = [snapshot.tasks[0].id: snapshot.tasks[0].revision, snapshot.tasks[1].id: snapshot.tasks[1].revision - 1]
        await #expect(throws: TaskContextError.conflict) {
            try await fixture.store.setFeedbackTasksArchived(batchID: fixture.batch.id,
                expectedBatchRevision: fixture.batch.revision, expectedTaskRevisions: stale, archived: true)
        }
        let unchanged = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(unchanged.tasks.allSatisfy { $0.archived == false && $0.revision == 3 })
    }

    @Test func regenerationDoesNotRecreateOrReactivateRemovedIssue() async throws {
        let fixture = try await removalFixture(taskCount: 1)
        let task = try #require(fixture.tasks.first)
        try await fixture.store.setFeedbackTasksArchived(batchID: fixture.batch.id,
            expectedBatchRevision: fixture.batch.revision, expectedTaskRevisions: [task.id: task.revision], archived: true)
        let removed = try #require(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.first)
        var regenerated = FeedbackTask(id: task.id, batchID: fixture.batch.id, issueID: task.issueID,
            sourceRevision: fixture.batch.revision, content: task.content, provenance: task.provenance)
        regenerated.content.behavior = "A regenerated replacement that must not reactivate the task."

        try await fixture.store.publishFeedbackGeneration(batchID: fixture.batch.id,
            expectedRevision: fixture.batch.revision, expectedTasks: [removed.id: removed.revision], generated: [regenerated])

        let saved = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        #expect(saved.tasks.count == 1)
        #expect(saved.tasks[0] == removed)
        #expect(saved.proposals.isEmpty)
        #expect(throws: (any Error).self) {
            try FeedbackHandoff.message(snapshot: saved, selected: [removed.id], mode: .plan)
        }
    }

    @Test func regenerationSkipsRemovedIssuesBeforeCallingTheModel() async throws {
        let fixture = try await removalFixture(taskCount: 2)
        let removedTask = fixture.tasks[0]
        let activeTask = fixture.tasks[1]
        try await fixture.store.setFeedbackTasksArchived(batchID: fixture.batch.id,
            expectedBatchRevision: fixture.batch.revision,
            expectedTaskRevisions: [removedTask.id: removedTask.revision], archived: true)
        let activeIssueID = try #require(activeTask.issueID)
        let client = ArchiveAwareGenerationClient(activeIssueID: activeIssueID,
            removedIssueID: try #require(removedTask.issueID))
        let generator = FeedbackGenerator(client: client,
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")),
            credential: "", paths: fixture.paths, store: fixture.store)

        let generated = try await generator.generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
        let saved = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)

        #expect(generated.compactMap(\.issueID) == [activeIssueID])
        #expect(await client.requestCount == 1)
        #expect(saved.tasks.first(where: { $0.id == removedTask.id })?.archived == true)
        #expect(saved.tasks.count == 2)
    }

    private func generationFixture(sourceCount: Int) async throws -> GenerationFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Consolidation")
        var batch = FeedbackBatch(projectID: project.id, title: "Duplicate passes", project: project.name,
                                  rawText: "Uploads repeat the same task content")
        let image = try paths.feedbackDirectory(id: batch.id).appending(path: "fixture.jpg")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(contentsOf: repository.appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg")).write(to: image)
        batch.sources = (0..<sourceCount).map { _ in
            FeedbackSource(kind: .image, status: .ready, localPath: paths.relativePath(for: image), filename: "fixture.jpg")
        }
        batch.comments[0].sourceIDs = batch.sources.map(\.id)
        try await store.createFeedback(batch)
        return .init(paths: paths, store: store, batch: batch)
    }

    private func storedTaskFixture() async throws -> StoredTaskFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Consolidation")
        var batch = FeedbackBatch(projectID: project.id, title: "Saved task", project: project.name,
                                  rawText: "Keep upload progress visible")
        let source = FeedbackSource(url: "https://example.invalid/evidence", kind: .image, status: .ready)
        batch.sources.append(source); batch.comments[0].sourceIDs.append(source.id)
        try await store.createFeedback(batch)
        let issueID = try #require(batch.comments.first?.id)
        let question = TaskQuestion(question: "Which uploads should cancellation stop?", sourceIDs: [issueID])
        var duplicate = TaskQuestion(question: "Which uploads should cancellation stop?", sourceIDs: [source.id])
        duplicate.answer = "Only pending files"
        let content = TaskContent(title: "Upload progress", behavior: "Show progress.\nKeep the progress bar visible.",
            requirements: [
                .init(text: "Show upload progress.", origin: .feedback, sourceIDs: [issueID]),
                .init(text: "Keep the upload progress visible.", origin: .interpretation, sourceIDs: [source.id])
            ], checks: [
                .init(text: "Progress is visible.", origin: .interpretation, sourceIDs: [issueID]),
                .init(text: "The progress indicator remains on screen.", origin: .interpretation, sourceIDs: [source.id])
            ], questions: [question, duplicate], sourceIDs: [issueID, source.id])
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: issueID,
            sourceRevision: batch.revision, content: content, provenance: .init(provider: .lmStudio, model: "test-model")),
            expectedRevision: nil, expectedBatchRevision: batch.revision)
        return .init(paths: paths, store: store, batch: batch, task: task, sourceID: source.id)
    }

    private func removalFixture(taskCount: Int) async throws -> RemovalFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Removal")
        let raw = (0..<taskCount).map { "Issue \($0)" }.joined(separator: "\n")
        let batch = FeedbackBatch(projectID: project.id, title: "Removal", project: project.name, rawText: raw)
        try await store.createFeedback(batch)
        var tasks: [FeedbackTask] = []
        for issue in batch.comments {
            let content = TaskContent(title: issue.text, behavior: "Resolve \(issue.text)",
                requirements: [.init(text: issue.text, origin: .feedback, sourceIDs: [issue.id])],
                checks: [.init(text: "Resolved", origin: .interpretation, sourceIDs: [issue.id])], sourceIDs: [issue.id])
            tasks.append(try await store.saveFeedbackTask(.init(id: "ftask_\(issue.id.dropFirst(5))", batchID: batch.id,
                issueID: issue.id, sourceRevision: batch.revision, content: content,
                provenance: .init(provider: .lmStudio, model: "test-model")), expectedRevision: nil,
                expectedBatchRevision: batch.revision))
        }
        return .init(paths: paths, store: store, batch: batch, tasks: tasks)
    }
}

private struct GenerationFixture { let paths: LibraryPaths; let store: VideoContextStore; let batch: FeedbackBatch }
private struct StoredTaskFixture { let paths: LibraryPaths; let store: VideoContextStore; let batch: FeedbackBatch; let task: FeedbackTask; let sourceID: String }
private struct RemovalFixture { let paths: LibraryPaths; let store: VideoContextStore; let batch: FeedbackBatch; let tasks: [FeedbackTask] }

private actor StaticConsolidationClient: HTTPDataLoading {
    let plan: FeedbackConsolidationPlan
    init(plan: FeedbackConsolidationPlan) { self.plan = plan }
    func data(for request: URLRequest) async throws -> HTTPResult { try lmStudioResponse(plan) }
}

private actor FifteenPassConsolidationClient: HTTPDataLoading {
    let issueID: String
    let sourceIDs: [String]
    private(set) var extractionCount = 0
    private(set) var consolidationCount = 0
    init(issueID: String, sourceIDs: [String]) { self.issueID = issueID; self.sourceIDs = sourceIDs }

    func data(for request: URLRequest) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if body.contains("video_context_feedback_consolidation") {
            consolidationCount += 1
            if consolidationCount == 1 {
                return try lmStudioResponse(FeedbackConsolidationPlan(
                    title: "Upload selected files", behavior: "Upload selected files.",
                    requirements: [.init(members: [0], text: "Uploads repeat the same task content")],
                    checks: [], questions: [], additionalQuestions: []))
            }
            let progress = stride(from: 1, through: 29, by: 2).map { $0 }
            let cancellation = stride(from: 2, through: 30, by: 2).map { $0 }
            return try lmStudioResponse(FeedbackConsolidationPlan(
                title: "Upload selected files", behavior: "Upload the selected files while progress remains visible.",
                requirements: [
                    .init(members: [0], text: "Uploads repeat the same task content"),
                    .init(members: progress, text: "Keep upload progress visible until completion."),
                    .init(members: cancellation, text: "Cancellation keeps every completed upload.")
                ], checks: [.init(members: Array(0..<15), text: "Progress stays visible and completed uploads survive cancellation.")],
                questions: [.init(members: Array(0..<15), text: "Should cancellation stop only pending uploads?")],
                additionalQuestions: []))
        }
        extractionCount += 1
        let pass = extractionCount
        let lower = (pass - 1) * 2
        let citations = [issueID] + Array(sourceIDs.dropFirst(lower).prefix(2))
        let visible = ["Keep progress visible", "Do not hide upload progress", "Leave the progress indicator on screen"][pass % 3]
        let cancellation = ["Keep completed uploads on cancel", "Cancellation must retain finished uploads", "Do not lose already uploaded files"][pass % 3]
        let task = GeneratedTask(targetTaskID: "", title: "Upload progress pass \(pass)",
            behavior: "Pass \(pass): upload selected files and show progress.",
            requirements: [
                .init(text: visible, origin: .interpretation, sourceIDs: citations),
                .init(text: cancellation, origin: .interpretation, sourceIDs: citations)
            ], checks: [.init(text: "Progress remains visible and completed uploads remain saved", origin: .interpretation, sourceIDs: citations)],
            questions: [.init(question: "Which pending uploads should cancellation stop?", sourceIDs: citations)],
            sourceIDs: citations, primaryIssueID: issueID)
        return try lmStudioResponse(GeneratedTaskBatch(tasks: [task]))
    }
}

private actor ArchiveAwareGenerationClient: HTTPDataLoading {
    let activeIssueID: String
    let removedIssueID: String
    private(set) var requestCount = 0
    init(activeIssueID: String, removedIssueID: String) {
        self.activeIssueID = activeIssueID; self.removedIssueID = removedIssueID
    }
    func data(for request: URLRequest) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard body.contains("FOCUS COMMENT \(activeIssueID)"),
              !body.contains("FOCUS COMMENT \(removedIssueID)") else {
            throw TaskContextError.invalid("Removed issues must not be sent as generation targets.")
        }
        requestCount += 1
        let task = GeneratedTask(targetTaskID: "", title: "Resolve active issue", behavior: "Resolve the active issue.",
            requirements: [.init(text: "Resolve the active issue.", origin: .feedback, sourceIDs: [activeIssueID])],
            checks: [.init(text: "The active issue is resolved.", origin: .interpretation, sourceIDs: [activeIssueID])],
            questions: [], sourceIDs: [activeIssueID], primaryIssueID: activeIssueID)
        return try lmStudioResponse(GeneratedTaskBatch(tasks: [task]))
    }
}

private func lmStudioResponse<T: Encodable>(_ value: T) throws -> HTTPResult {
    let output = try JSONEncoder().encode(value)
    let body = try JSONSerialization.data(withJSONObject: [
        "choices": [["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]]
    ])
    return .init(data: body, statusCode: 200)
}
