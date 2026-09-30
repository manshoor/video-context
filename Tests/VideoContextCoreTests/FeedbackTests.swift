import Foundation
import Testing
@testable import VideoContextCore

struct FeedbackTests {
    @Test func uploadedMediaIsLinkedToFeedbackAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "test.sqlite")
        var batch = FeedbackBatch(videoID: "vid_fixture", title: "QA", rawText: "Preview is blank\nPackage never finishes")
        let added = batch.addLocalSources(named: ["preview.png", "run.mp4"])
        #expect(added.map(\.kind) == [.image, .video])
        #expect(added.map(\.filename) == ["preview.png", "run.mp4"])
        #expect(batch.comments.allSatisfy { $0.sourceIDs.suffix(2) == added.map(\.id)[...] })
        do {
            let writer = try VideoContextStore(databaseURL: database)
            try await saveBatch(batch, in: writer)
        }
        let reader = try VideoContextStore(databaseURL: database, access: .readOnly)
        let saved = try await reader.feedbackSnapshot(id: batch.id).batch
        #expect(saved.sources == batch.sources)
        #expect(saved.comments == batch.comments)
    }

    @Test func mediaCanBeLinkedToOneCommentAndInvalidatesApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "QA", rawText: "Preview is blank\nPackage never finishes")
        try await saveBatch(batch, in: store)
        let firstID = try #require(batch.comments.first?.id)
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision,
            content: content(firstID)), expectedRevision: nil, expectedBatchRevision: batch.revision)
        try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision,
            expectedTaskRevisions: [task.id: task.revision])
        var draft = batch
        let added = draft.addLocalSources(named: ["preview.webp"], to: firstID)
        #expect(draft.comments[0].sourceIDs.contains(added[0].id))
        #expect(!draft.comments[1].sourceIDs.contains(added[0].id))
        let updated = try await store.updateFeedback(draft, expectedRevision: batch.revision)
        let snapshot = try await store.feedbackSnapshot(id: batch.id)
        #expect(updated.revision == batch.revision + 1)
        #expect(!snapshot.tasks[0].isApproved)
    }

    func saveBatch(_ batch: FeedbackBatch, in store: VideoContextStore) async throws {
        let videoID = try #require(batch.videoID)
        let projectID: String?
        if let id = batch.projectID { projectID = id }
        else if !batch.project.isEmpty { projectID = try await store.createFeedbackProject(name: batch.project).id }
        else { projectID = nil }
        if try await store.videoSnapshot(id: videoID) == nil {
            try await store.createVideo(.init(id: videoID, title: "Fixture recording", source: .localFile,
                                              sourceValue: "fixture.mp4", mediaRelativePath: "fixture.mp4", projectID: projectID))
        }
        try await store.createFeedback(batch)
    }
    @Test func feedbackListsOnlyTheSelectedRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let project = try await store.createFeedbackProject(name: "Ideolab")
        let firstVideo = VideoRecord(title: "First recording", source: .localFile, sourceValue: "first.mp4", mediaRelativePath: "first.mp4", projectID: project.id)
        let secondVideo = VideoRecord(title: "Second recording", source: .localFile, sourceValue: "second.mp4", mediaRelativePath: "second.mp4", projectID: project.id)
        try await store.createVideo(firstVideo)
        try await store.createVideo(secondVideo)
        let first = FeedbackBatch(videoID: firstVideo.id, title: "QA", project: "Ideolab", rawText: "Preview is broken")
        let second = FeedbackBatch(videoID: secondVideo.id, title: "Manager", project: "Ideolab", rawText: "Show success")
        try await store.createFeedback(first)
        try await store.createFeedback(second)
        #expect(try await store.listFeedback(videoID: firstVideo.id).map(\.id) == [first.id])
        #expect(try await store.listFeedback(videoID: secondVideo.id).map(\.id) == [second.id])
        #expect(try await store.listFeedback(videoID: "vid_missing").isEmpty)
        let context = try await FeedbackMCPService(store: store).batch(id: first.id, expectedRevision: first.revision)
        #expect(context.blocks.contains { $0.kind == "recording_context" && $0.text == firstVideo.id })
        let sourceID = try #require(first.comments.first?.id)
        let task = FeedbackTask(batchID: first.id, sourceRevision: first.revision, content: content(sourceID))
        let handoff = try FeedbackHandoff.message(snapshot: .init(batch: first, tasks: [task], proposals: []),
                                                  selected: [task.id], mode: .plan)
        #expect(handoff.contains("Recording Context ID: `\(firstVideo.id)`"))
    }
    @Test func olderUnassignedFeedbackCanBeAttachedWithoutLosingItsID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let video = VideoRecord(title: "Existing recording", source: .localFile, sourceValue: "recording.mp4", mediaRelativePath: "recording.mp4")
        try await store.createVideo(video)
        let batch = FeedbackBatch(videoID: video.id, title: "Earlier feedback", rawText: "Fix preview")
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        document.removeValue(forKey: "videoID")
        let legacyData = try JSONSerialization.data(withJSONObject: document)
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO feedback_batches(id,updated_at,document) VALUES(?,?,?)",
                           arguments: [batch.id, batch.updatedAt.timeIntervalSince1970, legacyData])
        }
        #expect(try await store.listFeedback(videoID: video.id).isEmpty)
        #expect(try await store.listUnassignedFeedback().map(\.id) == [batch.id])
        let attached = try await store.attachFeedback(batch.id, toVideoID: video.id, expectedRevision: batch.revision)
        #expect(attached.id == batch.id)
        #expect(attached.videoID == video.id)
        #expect(attached.revision == batch.revision + 1)
        #expect(try await store.listFeedback(videoID: video.id).map(\.id) == [batch.id])
        #expect(try await store.listUnassignedFeedback().isEmpty)
    }
    struct MockTaskClient: HTTPDataLoading {
        let result: GeneratedTaskBatch
        func data(for request: URLRequest) async throws -> HTTPResult {
            let content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
            return .init(data: body, statusCode: 200)
        }
    }
    struct GroupedMockTaskClient: HTTPDataLoading {
        let firstID: String
        let allIDs: [String]
        let recordingID: String
        let first: GeneratedTaskBatch
        let second: GeneratedTaskBatch
        func data(for request: URLRequest) async throws -> HTTPResult {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            guard allIDs.allSatisfy(body.contains), body.contains("Recording Context ID: \(recordingID)") else {
                throw TaskContextError.invalid("Each generation request must include the complete feedback context.")
            }
            let selected = body.contains("FOCUS COMMENT \(firstID)") ? first : second
            return try await MockTaskClient(result: selected).data(for: request)
        }
    }
    struct StubMediaClient: HTTPDataLoading {
        let response: HTTPResult
        func data(for request: URLRequest) async throws -> HTTPResult { response }
    }
    struct MockPreparationClient: HTTPDataLoading {
        let suggestions: [FeedbackPreparationSuggestion]
        func data(for request: URLRequest) async throws -> HTTPResult {
            let payload = try JSONEncoder().encode(["suggestions": suggestions])
            let result = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: payload, as: UTF8.self)]]]])
            return .init(data: result, statusCode: 200)
        }
    }
    actor PromptLog {
        var prompts: [String] = []
        func append(_ prompt: String) { prompts.append(prompt) }
        func joined() -> String { prompts.joined(separator: "\n") }
        func count() -> Int { prompts.count }
    }
    struct FrameClient: HTTPDataLoading {
        let log: PromptLog
        let task: GeneratedTaskBatch
        func data(for request: URLRequest) async throws -> HTTPResult {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("video_context_feedback_consolidation") {
                let plan = FeedbackConsolidationPlan(title: "Fix preview", behavior: "Show a working preview.",
                    requirements: [
                        .init(members: [0], text: "Preview is blank"),
                        .init(members: [1, 2], text: "Preview works")
                    ], checks: [.init(members: [0, 1], text: "Preview renders")], questions: [],
                    additionalQuestions: [])
                let content = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
                let response = try JSONSerialization.data(withJSONObject: [
                    "choices": [["finish_reason": "stop", "message": ["content": content]]]
                ])
                return .init(data: response, statusCode: 200)
            }
            await log.append(body)
            return try await MockTaskClient(result: task).data(for: request)
        }
    }

    func content(_ sourceID: String, title: String = "Fix preview") -> TaskContent {
        .init(title: title, behavior: "Show a working preview", requirements: [.init(text: "Preview works", origin: .feedback, sourceIDs: [sourceID])],
              checks: [.init(text: "Preview renders", origin: .interpretation, sourceIDs: [sourceID])], sourceIDs: [sourceID])
    }

    func generated(_ sourceID: String) -> GeneratedTaskBatch {
        .init(tasks: [.init(targetTaskID: "", title: "Fix preview", behavior: "Show a working preview",
                            requirements: [.init(text: "Preview works", origin: .feedback, sourceIDs: [sourceID])],
                            checks: [.init(text: "Preview renders", origin: .interpretation, sourceIDs: [sourceID])],
                            questions: [], sourceIDs: [sourceID], primaryIssueID: sourceID)])
    }
    @Test func parserKeepsEveryCommentAndItsLinks() {
        let text = """
        Preview is not working: [https://app.screencast.com/RJsQKgmLW1w3M](https://app.screencast.com/RJsQKgmLW1w3M)

        My last 2 runs came up blank: https://app.screencast.com/b1nr220UDmwHP

        You need to look at all the other things in ideolab and have this match
        """
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "QA", project: "Ideolab", rawText: text)
        #expect(batch.comments.count == 3)
        #expect(batch.sources.count == 2)
        #expect(batch.comments[0].sourceIDs.count == 1)
        #expect(batch.comments[1].sourceIDs.count == 1)
        #expect(batch.comments[2].sourceIDs.isEmpty)
        #expect(batch.comments[2].text.contains("ideolab"))
    }

    @Test func longListKeepsTextIssuesSeparateAndAttachesLinkOnlyLines() {
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "Queue", rawText: """
        Preview is blank
        https://app.screencast.com/preview
        Package does not finish
        Runs are empty
        """)
        #expect(batch.comments.count == 3)
        #expect(batch.comments.map(\.isShared) == [false, false, false])
        #expect(batch.comments[0].sourceIDs == [batch.sources[0].id])
        #expect(batch.comments[1].sourceIDs.isEmpty)
        #expect(batch.comments[0].lineNumbers == [1, 2])
    }

    @Test func projectOnlyBatchHasStableScopeAndCursorHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let project = try await store.createFeedbackProject(name: "Ideolab")
        let batch = FeedbackBatch(projectID: project.id, title: "Queue", project: project.name, rawText: "Preview is blank")
        try await store.createFeedback(batch)
        #expect(try await store.listFeedback(projectID: project.id).map(\.id) == [batch.id])
        let page = try await FeedbackMCPService(store: store).batch(id: batch.id, expectedRevision: batch.revision)
        #expect(page.projectID == project.id)
        let sourceID = try #require(batch.comments.first?.id)
        let task = FeedbackTask(batchID: batch.id, sourceRevision: batch.revision, content: content(sourceID))
        let handoff = try FeedbackHandoff.message(snapshot: .init(batch: batch, tasks: [task], proposals: []), selected: [task.id], mode: .plan)
        #expect(handoff.contains("Project Context ID: `\(project.id)`"))
    }

    @Test func preparationOnlySuggestsChangesAndKeepsEveryIssue() async throws {
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "Queue", rawText: "Preview is blank\nPreview fails again")
        let first = try #require(batch.comments.first)
        let second = try #require(batch.comments.last)
        let suggestion = FeedbackPreparationSuggestion(issueID: first.id, joinWithPrevious: false,
            sharedInstruction: false, sourceIDs: [], duplicateOfIssueID: "")
        let duplicate = FeedbackPreparationSuggestion(issueID: second.id, joinWithPrevious: false,
            sharedInstruction: false, sourceIDs: [], duplicateOfIssueID: first.id)
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))
        let results = try await FeedbackPreparer(client: MockPreparationClient(suggestions: [suggestion, duplicate]),
            configuration: config, credential: "", paths: paths).suggest(batch: batch)
        #expect(results.count == 2)
        #expect(results[1].duplicateOfIssueID == first.id)
        #expect(batch.comments.count == 2)
    }

    @Test func openAITaskRequestUsesSelectedReasoningEffort() throws {
        let config = ModelConfiguration(analysisProvider: .openAI,
            taskAnalysisOverride: .init(provider: .openAI, modelID: "gpt-6-sol", effort: .medium),
            feedbackPreparationOverride: .init(provider: .openAI, modelID: "gpt-6-luna", effort: .max))
        let task = try AnalysisAdapter.request(configuration: config.taskConfiguration, credential: "fixture-key", prompt: "Test", images: [])
        let prep = try AnalysisAdapter.request(configuration: config.feedbackPreparationConfiguration, credential: "fixture-key", prompt: "Test", images: [])
        let taskBody = try #require(task.httpBody)
        let prepBody = try #require(prep.httpBody)
        let taskPayload = try #require(JSONSerialization.jsonObject(with: taskBody) as? [String: Any])
        let prepPayload = try #require(JSONSerialization.jsonObject(with: prepBody) as? [String: Any])
        #expect(taskPayload["model"] as? String == "gpt-6-sol")
        #expect((taskPayload["reasoning"] as? [String: String])?["effort"] == "medium")
        #expect(prepPayload["model"] as? String == "gpt-6-luna")
        #expect((prepPayload["reasoning"] as? [String: String])?["effort"] == "max")
    }

    @Test func generationKeepsDistinctIssuesWithMatchingTitles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Ideolab")
        let batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Preview is blank\nPreview is blank after rerun")
        try await store.createFeedback(batch)
        let items = batch.comments.map { comment in
            GeneratedTask(targetTaskID: "", title: "Fix preview", behavior: comment.text,
                          requirements: [.init(text: comment.text, origin: .feedback, sourceIDs: [comment.id])],
                          checks: [.init(text: "Preview renders", origin: .interpretation, sourceIDs: [comment.id])],
                          questions: [], sourceIDs: [comment.id], primaryIssueID: comment.id)
        }
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))
        _ = try await FeedbackGenerator(client: MockTaskClient(result: .init(tasks: items)), configuration: config,
                                        credential: "", paths: paths, store: store)
            .generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let tasks = try await store.feedbackSnapshot(id: batch.id).tasks
        #expect(tasks.count == 2)
        #expect(Set(tasks.compactMap(\.issueID)) == Set(batch.comments.map(\.id)))
    }

    @Test func linkedVideoSendsEverySavedFrameInBoundedPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Ideolab")
        let video = VideoRecord(title: "Preview clip", source: .localFile, sourceValue: "clip.mp4", mediaRelativePath: "clip.mp4", projectID: project.id)
        try await store.createVideo(video)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let jpeg = try Data(contentsOf: repo.appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg"))
        var frames: [EvidenceItem] = []
        for index in 0..<3 {
            let url = root.appending(path: "frame-\(index).jpg")
            try jpeg.write(to: url)
            frames.append(.init(videoID: video.id, timestamp: Double(index), imageRelativePath: paths.relativePath(for: url), origin: .automatic))
        }
        try await store.publishArtifacts(videoID: video.id, transcript: [], evidence: frames,
                                         brief: .init(videoID: video.id, markdown: "Preview fails"))
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name, rawText: "Preview is blank")
        let issueID = try #require(batch.comments.first?.id)
        let source = FeedbackSource(kind: .recording, status: .ready, recordingID: video.id)
        batch.sources.append(source); batch.comments[0].sourceIDs.append(source.id)
        try await store.createFeedback(batch)
        let log = PromptLog()
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))
        _ = try await FeedbackGenerator(client: FrameClient(log: log, task: generated(issueID)), configuration: config,
                                        credential: "", paths: paths, store: store)
            .generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let requestBodies = await log.joined()
        #expect(await log.count() == 2)
        #expect(frames.allSatisfy { requestBodies.contains($0.id) })
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks.count == 1)
    }

    @Test func approvalRequiresCurrentEvidenceAndNoBlockers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "QA", project: "Ideolab", rawText: "Preview is broken")
        try await saveBatch(batch, in: store)
        let source = try #require(batch.comments.first)
        let content = TaskContent(title: "Fix preview", behavior: "Preview renders", requirements: [.init(text: source.text, origin: .feedback, sourceIDs: [source.id])], checks: [.init(text: "Preview renders", origin: .interpretation, sourceIDs: [source.id])], sourceIDs: [source.id])
        let draft = FeedbackTask(batchID: batch.id, sourceRevision: batch.revision, content: content)
        try await store.publishFeedbackGeneration(batchID: batch.id, expectedRevision: batch.revision, expectedTasks: [:], generated: [draft])
        let saved = try #require(try await store.feedbackSnapshot(id: batch.id).tasks.first)
        try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision, expectedTaskRevisions: [saved.id: saved.revision])
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks[0].isApproved)
        var edited = batch
        edited.rawText = "Preview is broken after every run"
        try await store.updateFeedback(edited, expectedRevision: batch.revision)
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks[0].isApproved == false)
    }

    @Test func screencastEscapedMetadataSelectsOriginalImage() throws {
        let embedded = #"{"Media":{"ContentType":"Image","ContentUrl":"https://cdn.screencast.com/uploads/example/capture.png?sig=abc"}}"#
        let html = "<script>Object.freeze('{\\u0022Media\\u0022:{\\u0022ContentType\\u0022:\\u0022Video\\u0022,\\u0022ContentUrl\\u0022:\\u0022https://cdn.screencast.com/other.mp4\\u0022}}'); window.getPwcConfig = function() { return Object.freeze('" +
            embedded.replacingOccurrences(of: "\"", with: "\\u0022") + "'); };</script>"
        let media = try ScreencastMedia.parse(html)
        #expect(media.kind == .image)
        #expect(media.url.path == "/uploads/example/capture.png")
    }

    @Test func generatedDraftPreservesUserEditsOnRetryAndBlocksMissingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        var batch = FeedbackBatch(videoID: "vid_fixture", title: "QA", rawText: "Preview broken: https://app.screencast.com/example")
        let comment = try #require(batch.comments.first)
        let source = try #require(batch.sources.first)
        batch.sources[0].status = .failed
        batch.sources[0].error = "Unavailable"
        try await saveBatch(batch, in: store)
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))
        let generator = FeedbackGenerator(client: MockTaskClient(result: generated(comment.id)), configuration: config,
                                          credential: "", paths: paths, store: store)
        _ = try await generator.generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        var task = try #require(try await store.feedbackSnapshot(id: batch.id).tasks.first)
        #expect(task.content.blockers == 1)
        #expect(task.content.allSourceIDs.contains(source.id))
        task.content.behavior = "My reviewed wording"
        task = try await store.saveFeedbackTask(task, expectedRevision: task.revision, expectedBatchRevision: batch.revision)
        _ = try await generator.generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let latest = try await store.feedbackSnapshot(id: batch.id)
        #expect(latest.tasks.count == 1)
        #expect(latest.tasks[0].id == task.id)
        #expect(latest.tasks[0].content.behavior == "My reviewed wording")
        #expect(latest.proposals.isEmpty)
    }

    @Test func mcpRejectsOtherBatchesAndOldRevisions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let first = FeedbackBatch(videoID: "vid_fixture", title: "First", rawText: "Preview broken")
        let second = FeedbackBatch(videoID: "vid_fixture", title: "Second", rawText: "Preview broken")
        try await saveBatch(first, in: store); try await saveBatch(second, in: store)
        let id = try #require(first.comments.first?.id)
        let task = try await store.saveFeedbackTask(.init(batchID: first.id, sourceRevision: first.revision, content: content(id)),
                                                    expectedRevision: nil, expectedBatchRevision: first.revision)
        let mcp = FeedbackMCPService(store: store)
        let page = try await mcp.task(batchID: first.id, taskID: task.id, expectedBatchRevision: first.revision, expectedRevision: task.revision)
        #expect(page.blocks.contains { $0.kind == "requirement" })
        await #expect(throws: (any Error).self) {
            try await mcp.task(batchID: second.id, taskID: task.id, expectedBatchRevision: second.revision, expectedRevision: task.revision)
        }
        var draft = first; draft.comments[0].text = "Preview broken again"
        _ = try await store.updateFeedback(draft, expectedRevision: first.revision)
        await #expect(throws: TaskContextError.conflict) {
            try await mcp.task(batchID: first.id, taskID: task.id, expectedBatchRevision: first.revision, expectedRevision: task.revision)
        }
    }

    @Test func suppliedFeedbackKeepsFourIssuesAndSharedIdeolabInstruction() async throws {
        let raw = """
        preview is not working: https://app.screencast.com/RJsQKgmLW1w3M
        My last 2 runs came up blank: https://app.screencast.com/b1nr220UDmwHP
        This is not an option, it has to make them all every time: https://app.screencast.com/EWWbhcxMA1v05
        When the package DOES complete, it should have the little confetti go ff, there should be a success message and it should exit the wizard: https://app.screencast.com/y3WhpmwgaM1my
        You need to look at all the other things in ideolab and have this match
        """
        var batch = FeedbackBatch(videoID: "vid_fixture", title: "QA and manager", project: "Ideolab", rawText: raw)
        #expect(batch.comments.count == 5)
        #expect(batch.sources.count == 4)
        batch.comments[4].isShared = true
        let shared = batch.comments[4]
        #expect(shared.sourceIDs.isEmpty)
        for index in batch.sources.indices { batch.sources[index].status = .failed }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        try await saveBatch(batch, in: store)
        let titles = ["Fix preview", "Fix blank runs", "Generate every output", "Complete package wizard"]
        let checks = ["Preview displays", "Runs contain results", "Every output is made", "Confetti, success message, and wizard exit"]
        let generated: [GeneratedTask] = (0..<4).map { index in
            let comment = batch.comments[index]
            return .init(targetTaskID: "", title: titles[index], behavior: checks[index],
                         requirements: [
                            .init(text: comment.text, origin: .feedback, sourceIDs: [comment.id]),
                            .init(text: shared.text, origin: .feedback, sourceIDs: [shared.id])
                         ], checks: [.init(text: checks[index], origin: .interpretation, sourceIDs: [comment.id])],
                         questions: [], sourceIDs: [comment.id, shared.id], primaryIssueID: comment.id)
        }
        let client = GroupedMockTaskClient(firstID: batch.comments[0].id, allIDs: batch.comments.map(\.id), recordingID: "vid_fixture",
                                           first: .init(tasks: Array(generated[0..<2])), second: .init(tasks: Array(generated[2..<4])))
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))
        _ = try await FeedbackGenerator(client: client, configuration: config, credential: "", paths: paths, store: store)
            .generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let saved = try await store.feedbackSnapshot(id: batch.id)
        #expect(saved.tasks.count == 4)
        #expect(Set(saved.tasks.map(\.content.title)) == Set(titles))
        #expect(saved.tasks.allSatisfy { $0.content.requirements.contains(where: { $0.text == shared.text }) })
        #expect(saved.tasks.allSatisfy { $0.content.blockers == 1 })
        #expect(saved.tasks.flatMap(\.content.checks).contains { $0.text == checks[3] })
    }

    @Test func mediaResolverRoutesVideoAndRejectsUnavailableShares() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let source = FeedbackSource(url: "https://app.screencast.com/sample")
        let videoJSON = #"{"Media":{"ContentType":"Video","ContentUrl":"https://cdn.screencast.com/uploads/example/video.mp4?sig=abc"}}"#
        let html = "<script>window.getPwcConfig = function() { return Object.freeze('" + videoJSON.replacingOccurrences(of: "\"", with: "\\u0022") + "'); };</script>"
        let resolved = try await FeedbackMediaResolver(client: StubMediaClient(response: .init(data: Data(html.utf8), statusCode: 200)))
            .resolve(source, batchID: "fb_test", paths: paths)
        #expect(resolved.kind == .video)
        #expect(resolved.url == source.url)
        #expect(resolved.resolvedURL?.contains("video.mp4") == true)
        await #expect(throws: (any Error).self) {
            try await FeedbackMediaResolver(client: StubMediaClient(response: .init(data: Data(), statusCode: 403)))
                .resolve(source, batchID: "fb_test", paths: paths)
        }
        #expect(throws: (any Error).self) { try ScreencastMedia.parse("<html>no media</html>") }
    }

    @Test func savedFeedbackAndReviewedTaskSurviveStoreRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "Manager", project: "Ideolab", rawText: "Show success")
        let sourceID = try #require(batch.comments.first?.id)
        let taskID: String
        do {
            let store = try VideoContextStore(databaseURL: url)
            try await saveBatch(batch, in: store)
            let task = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: content(sourceID)),
                                                        expectedRevision: nil, expectedBatchRevision: batch.revision)
            try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision,
                                                 expectedTaskRevisions: [task.id: task.revision])
            taskID = task.id
        }
        let reader = try VideoContextStore(databaseURL: url, access: .readOnly)
        let retrieved = try await FeedbackMCPService(store: reader).task(batchID: batch.id, taskID: taskID,
            expectedBatchRevision: batch.revision, expectedRevision: 2)
        #expect(retrieved.blocks.contains { $0.kind == "state" && $0.text.contains("approved=true") })
        #expect(try await reader.feedbackSnapshot(id: batch.id).batch.rawText == "Show success")
    }

    @Test func bulkApprovalIsAtomicWhenOneTaskHasABlockingQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "QA", rawText: "Preview is broken")
        try await saveBatch(batch, in: store)
        let sourceID = try #require(batch.comments.first?.id)
        let first = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision,
            content: content(sourceID, title: "Fix preview")), expectedRevision: nil, expectedBatchRevision: batch.revision)
        var blockedContent = content(sourceID, title: "Fix package")
        blockedContent.questions = [.init(question: "Which package output is required?", sourceIDs: [sourceID])]
        let blocked = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision,
            content: blockedContent), expectedRevision: nil, expectedBatchRevision: batch.revision)
        await #expect(throws: TaskContextError.reviewRequired) {
            try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision,
                expectedTaskRevisions: [first.id: first.revision, blocked.id: blocked.revision])
        }
        let current = try await store.feedbackSnapshot(id: batch.id)
        #expect(current.tasks.allSatisfy { !$0.isApproved && $0.revision == 1 })
        var resolved = blocked
        resolved.content.questions[0].answer = "All outputs"
        resolved = try await store.saveFeedbackTask(resolved, expectedRevision: blocked.revision, expectedBatchRevision: batch.revision)
        try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision,
            expectedTaskRevisions: [first.id: first.revision, resolved.id: resolved.revision])
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks.allSatisfy(\.isApproved))
    }

    @Test func paginationAndPublicationRejectChangedRevisions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VideoContextStore(databaseURL: root.appending(path: "test.sqlite"))
        let batch = FeedbackBatch(videoID: "vid_fixture", title: "Manager", rawText: "Make all outputs")
        try await saveBatch(batch, in: store)
        let sourceID = try #require(batch.comments.first?.id)
        for index in 0..<16 {
            _ = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision,
                content: content(sourceID, title: "Output \(index)")), expectedRevision: nil, expectedBatchRevision: batch.revision)
        }
        let service = FeedbackMCPService(store: store)
        let first = try await service.list(batchID: batch.id, expectedRevision: batch.revision)
        #expect(first.tasks.count == 15)
        let cursor = try #require(first.nextCursor)
        let second = try await service.list(batchID: batch.id, expectedRevision: batch.revision, cursor: cursor)
        #expect(second.tasks.count == 1)
        #expect(second.nextCursor == nil)
        let current = try await store.feedbackSnapshot(id: batch.id)
        var changed = try #require(current.tasks.first)
        changed.content.behavior = "Reviewed output behavior"
        _ = try await store.saveFeedbackTask(changed, expectedRevision: changed.revision, expectedBatchRevision: batch.revision)
        await #expect(throws: TaskContextError.conflict) {
            try await service.list(batchID: batch.id, expectedRevision: batch.revision, cursor: cursor)
        }
        await #expect(throws: TaskContextError.conflict) {
            try await store.publishFeedbackGeneration(batchID: batch.id, expectedRevision: batch.revision,
                expectedTasks: Dictionary(uniqueKeysWithValues: current.tasks.map { ($0.id, $0.revision) }), generated: [])
        }
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks.count == 16)
    }
}
