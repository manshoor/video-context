import Foundation
import Testing
@testable import VideoContextCore

struct FeedbackGenerationReliabilityTests {
    @Test func sixIssuesKeepOneTaskEachWithSharedInstructionsAndCrossIssueCitations() async throws {
        let fixture = try await fixture(issueCount: 6, includeSharedInstruction: true)
        let shared = try #require(fixture.batch.comments.last)
        let expected = fixture.batch.comments.filter { $0.isShared == false }.map(\.id)
        let client = FeedbackReliabilityClient(issueIDs: expected, sharedID: shared.id, mode: .valid)

        let tasks = try await generator(client: client, fixture: fixture)
            .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))

        #expect(tasks.count == 6)
        #expect(tasks.compactMap(\.issueID).sorted() == expected.sorted())
        #expect(Set(tasks.compactMap(\.issueID)).count == 6)
        #expect(tasks.allSatisfy { task in
            task.content.requirements.contains { $0.text == shared.text && $0.sourceIDs.contains(shared.id) }
        })
        #expect(tasks.allSatisfy { task in
            task.content.allSourceIDs.contains { expected.contains($0) && $0 != task.issueID }
        })
        #expect(await client.requestCount == 3)
    }

    @Test func omittedIssueReportsExpectedReturnedMissingAndDuplicateIDs() async throws {
        let fixture = try await fixture(issueCount: 2)
        let expected = fixture.batch.comments.map(\.id)
        let client = FeedbackReliabilityClient(issueIDs: expected, mode: .omitLast)

        do {
            _ = try await generator(client: client, fixture: fixture)
                .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
            Issue.record("Expected omitted task identity to stop generation.")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Expected issue IDs: \(expected.joined(separator: ", "))"))
            #expect(message.contains("Returned primary issue IDs: \(expected[0])"))
            #expect(message.contains("Missing issue IDs: \(expected[1])"))
            #expect(message.contains("Duplicate issue IDs: none"))
        }
        #expect(await client.requestCount == 2)
        #expect(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.isEmpty)
    }

    @Test func duplicateIssueReportsTheDuplicateAndMissingIdentity() async throws {
        let fixture = try await fixture(issueCount: 2)
        let expected = fixture.batch.comments.map(\.id)
        let client = FeedbackReliabilityClient(issueIDs: expected, mode: .duplicateFirst)

        do {
            _ = try await generator(client: client, fixture: fixture)
                .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
            Issue.record("Expected duplicate task identity to stop generation.")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Expected issue IDs: \(expected.joined(separator: ", "))"))
            #expect(message.contains("Returned primary issue IDs: \(expected[0]), \(expected[0])"))
            #expect(message.contains("Missing issue IDs: \(expected[1])"))
            #expect(message.contains("Duplicate issue IDs: \(expected[0])"))
        }
        #expect(await client.requestCount == 2)
        #expect(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.isEmpty)
    }

    @Test func oneInvalidGroupGetsOneRecoveryWithoutRegeneratingValidatedGroups() async throws {
        let fixture = try await fixture(issueCount: 6)
        let expected = fixture.batch.comments.map(\.id)
        let client = FeedbackReliabilityClient(issueIDs: expected, mode: .recoverSecondGroup)

        let tasks = try await generator(client: client, fixture: fixture)
            .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
        let counts = await client.requestsByFocus

        #expect(tasks.count == 6)
        #expect(counts[Array(expected[0...1])] == 1)
        #expect(counts[Array(expected[2...3])] == 2)
        #expect(counts[Array(expected[4...5])] == 1)
        #expect(await client.requestCount == 4)
    }

    @Test func feedbackSchemaRequiresPrimaryIssueIDFromTheExpectedSet() throws {
        let expected = ["fcom_one", "fcom_two"]
        let request = try TaskGenerationSchema.request(
            provider: .lmStudio,
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")),
            credential: "", prompt: "feedback", images: [], allowedSourceIDs: expected,
            instructions: "fixture", feedback: true, primaryIssueIDs: expected
        )
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        let schema = try #require(jsonSchema["schema"] as? [String: Any])
        let rootProperties = try #require(schema["properties"] as? [String: Any])
        let tasks = try #require(rootProperties["tasks"] as? [String: Any])
        let item = try #require(tasks["items"] as? [String: Any])
        let properties = try #require(item["properties"] as? [String: Any])
        let primary = try #require(properties["primaryIssueID"] as? [String: Any])
        let required = try #require(item["required"] as? [String])

        #expect(primary["enum"] as? [String] == expected.sorted())
        #expect(required.contains("primaryIssueID"))
    }

    @Test(arguments: FeedbackContentFailureCase.allCases)
    func contentValidationNamesIssueFieldAndCategory(_ testCase: FeedbackContentFailureCase) async throws {
        let fixture = try await fixture(issueCount: 1)
        let issueID = try #require(fixture.batch.comments.first?.id)
        let client = FeedbackContentValidationClient(issueID: issueID, mode: .failure(testCase))

        do {
            _ = try await generator(client: client, fixture: fixture)
                .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
            Issue.record("Expected \(testCase.rawValue) to reject the generated feedback task.")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains(issueID))
            #expect(message.contains(testCase.fieldPath))
            #expect(message.contains(testCase.category))
            if testCase.category == "unexpectedSourceIDs" {
                #expect(message.contains(FeedbackContentFailureCase.unexpectedSourceID))
            }
        }

        let requestBodies = await client.requestBodies
        #expect(requestBodies.count == 2)
        let recovery = try #require(requestBodies.last)
        #expect(recovery.contains(issueID))
        #expect(recovery.contains(testCase.fieldPath))
        #expect(recovery.contains(testCase.category))
        #expect(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.isEmpty)
    }

    @Test func feedbackSchemaMatchesLocalContentValidationAndPermittedTargets() async throws {
        let fixture = try await fixture(issueCount: 1)
        let issueID = try #require(fixture.batch.comments.first?.id)
        let existing = try await fixture.store.saveFeedbackTask(
            .init(batchID: fixture.batch.id, issueID: issueID, sourceRevision: fixture.batch.revision,
                  content: .init(title: "Existing", behavior: "Existing behavior",
                                 requirements: [.init(text: "Existing requirement", origin: .feedback, sourceIDs: [issueID])],
                                 checks: [.init(text: "Existing check", origin: .interpretation, sourceIDs: [issueID])],
                                 sourceIDs: [issueID])),
            expectedRevision: nil, expectedBatchRevision: fixture.batch.revision
        )
        let client = FeedbackContentValidationClient(issueID: issueID, mode: .valid(targetTaskID: existing.id))

        _ = try await generator(client: client, fixture: fixture)
            .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))

        let body = try #require(await client.requestBodies.first)
        let schema = try responseSchema(in: body)
        let taskProperties = try #require(schema["properties"] as? [String: Any])
        let tasks = try #require(taskProperties["tasks"] as? [String: Any])
        let task = try #require(tasks["items"] as? [String: Any])
        let properties = try #require(task["properties"] as? [String: Any])
        let target = try #require(properties["targetTaskID"] as? [String: Any])
        let title = try #require(properties["title"] as? [String: Any])
        let behavior = try #require(properties["behavior"] as? [String: Any])
        let citations = try #require(properties["sourceIDs"] as? [String: Any])
        let requirements = try #require(properties["requirements"] as? [String: Any])
        let statement = try #require(requirements["items"] as? [String: Any])
        let statementProperties = try #require(statement["properties"] as? [String: Any])
        let statementText = try #require(statementProperties["text"] as? [String: Any])
        let statementCitations = try #require(statementProperties["sourceIDs"] as? [String: Any])
        let questions = try #require(properties["questions"] as? [String: Any])
        let question = try #require(questions["items"] as? [String: Any])
        let questionProperties = try #require(question["properties"] as? [String: Any])

        #expect(target["enum"] as? [String] == ["", existing.id].sorted())
        #expect(title["minLength"] as? Int == 1)
        #expect(title["maxLength"] as? Int == 200)
        #expect(behavior["minLength"] as? Int == 1)
        #expect(citations["minItems"] as? Int == 1)
        #expect(statementText["minLength"] as? Int == 1)
        #expect(statementCitations["minItems"] as? Int == 1)
        #expect((questionProperties["question"] as? [String: Any])?["minLength"] as? Int == 1)
        #expect((questionProperties["sourceIDs"] as? [String: Any])?["minItems"] as? Int == 1)
    }

    @Test func failedValidationPersistsOnlyABoundedSafeDiagnosticSummary() async throws {
        let fixture = try await fixture(issueCount: 1, issueTextPrefix: "PRIVATE EVIDENCE TEXT")
        let issueID = try #require(fixture.batch.comments.first?.id)
        let client = FeedbackContentValidationClient(issueID: issueID, mode: .manyMissingCheckCitations(count: 40))
        let run = try await fixture.store.startUsageRun(.init(videoID: nil, operation: .taskGeneration,
            provider: .lmStudio, model: "test-model", feedbackBatchID: fixture.batch.id))
        let session = UsageSession(runID: run.id, store: fixture.store)

        do {
            _ = try await UsageTrace.$session.withValue(session) {
                try await FeedbackGenerator(client: client,
                    configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")),
                    credential: "PRIVATE-CREDENTIAL", paths: fixture.paths, store: fixture.store)
                    .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
            }
            Issue.record("Expected missing check citations to stop generation.")
        } catch {
            try await fixture.store.finishUsageRun(id: run.id, outcome: .failed)
        }

        let saved = try #require(try await fixture.store.usageSnapshot().runs.first { $0.id == run.id })
        let encoded = try JSONEncoder().encode(saved)
        let document = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let diagnostics = try #require(document["feedbackValidationDiagnostics"] as? [[String: Any]])
        #expect(diagnostics.count == 32)
        #expect(document["feedbackValidationDiagnosticsTruncated"] as? Bool == true)
        #expect(diagnostics.allSatisfy { $0["primaryIssueID"] as? String == issueID })
        #expect(diagnostics.allSatisfy { $0["category"] as? String == "missingCitations" })
        #expect(diagnostics.allSatisfy { ($0["fieldPath"] as? String)?.contains(".checks[") == true })
        let persisted = String(decoding: encoded, as: UTF8.self)
        #expect(persisted.contains("PRIVATE-CREDENTIAL") == false)
        #expect(persisted.contains("PRIVATE EVIDENCE TEXT") == false)
        #expect(try await fixture.store.feedbackSnapshot(id: fixture.batch.id).tasks.isEmpty)
    }

    @Test func failedValidationPreservesSavedAttachmentAndPublishesNothing() async throws {
        let fixture = try await fixture(issueCount: 1)
        var batch = try await fixture.store.feedbackSnapshot(id: fixture.batch.id).batch
        let directory = try fixture.paths.feedbackDirectory(id: batch.id)
        let attachmentURL = directory.appending(path: "saved-attachment.jpg")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(contentsOf: repository.appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg")).write(to: attachmentURL)
        let source = FeedbackSource(kind: .image, status: .ready,
            localPath: fixture.paths.relativePath(for: attachmentURL), filename: "saved-attachment.jpg")
        batch.sources.append(source)
        batch.comments[0].sourceIDs.append(source.id)
        batch = try await fixture.store.updateFeedback(batch, expectedRevision: batch.revision)
        let issueID = try #require(batch.comments.first?.id)
        let client = FeedbackContentValidationClient(issueID: issueID, allowedSourceID: source.id, mode: .failure(.emptyTitle))

        do {
            _ = try await generator(client: client, fixture: fixture)
                .generate(snapshot: try await fixture.store.feedbackSnapshot(id: fixture.batch.id))
            Issue.record("Expected empty title validation to stop generation.")
        } catch { }

        let saved = try await fixture.store.feedbackSnapshot(id: fixture.batch.id)
        let savedSource = try #require(saved.batch.sources.first { $0.id == source.id })
        #expect(saved.tasks.isEmpty)
        #expect(saved.proposals.isEmpty)
        #expect(savedSource.localPath == source.localPath)
        #expect(FileManager.default.fileExists(atPath: attachmentURL.path))
    }

    private func fixture(issueCount: Int, includeSharedInstruction: Bool = false,
                         issueTextPrefix: String = "Independent issue") async throws -> ReliabilityFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Reliability")
        let issues = (1...issueCount).map { "\(issueTextPrefix) \($0)" }
        let lines = includeSharedInstruction ? issues + ["Use the shared product convention"] : issues
        var batch = FeedbackBatch(projectID: project.id, title: "Reliability", project: project.name,
                                  rawText: lines.joined(separator: "\n"))
        if includeSharedInstruction { batch.comments[batch.comments.count - 1].isShared = true }
        try await store.createFeedback(batch)
        return .init(paths: paths, store: store, batch: batch)
    }

    private func generator(client: FeedbackReliabilityClient, fixture: ReliabilityFixture) -> FeedbackGenerator<FeedbackReliabilityClient> {
        .init(client: client,
              configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")),
              credential: "", paths: fixture.paths, store: fixture.store)
    }

    private func generator(client: FeedbackContentValidationClient, fixture: ReliabilityFixture) -> FeedbackGenerator<FeedbackContentValidationClient> {
        .init(client: client,
              configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model")),
              credential: "", paths: fixture.paths, store: fixture.store)
    }

    private func responseSchema(in body: String) throws -> [String: Any] {
        let data = Data(body.utf8)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let responseFormat = try #require(payload["response_format"] as? [String: Any])
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        return try #require(jsonSchema["schema"] as? [String: Any])
    }
}

private struct ReliabilityFixture {
    let paths: LibraryPaths
    let store: VideoContextStore
    let batch: FeedbackBatch
}

private actor FeedbackReliabilityClient: HTTPDataLoading {
    enum Mode: Sendable { case valid, omitLast, duplicateFirst, recoverSecondGroup }

    let issueIDs: [String]
    let sharedID: String?
    let mode: Mode
    private(set) var requestsByFocus: [[String]: Int] = [:]
    var requestCount: Int { requestsByFocus.values.reduce(0, +) }

    init(issueIDs: [String], sharedID: String? = nil, mode: Mode) {
        self.issueIDs = issueIDs
        self.sharedID = sharedID
        self.mode = mode
    }

    func data(for request: URLRequest) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let focus = issueIDs.filter { body.contains("FOCUS COMMENT \($0)") }
        requestsByFocus[focus, default: 0] += 1
        let attempt = requestsByFocus[focus, default: 0]
        let selected: [(primary: String, citations: [String])]
        switch mode {
        case .valid:
            selected = validTasks(focus)
        case .omitLast:
            selected = validTasks(Array(focus.dropLast()))
        case .duplicateFirst:
            selected = focus.isEmpty ? [] : focus.map { _ in (focus[0], focus) }
        case .recoverSecondGroup:
            if focus == Array(issueIDs[2...3]), attempt == 1 { selected = validTasks(Array(focus.dropLast())) }
            else { selected = validTasks(focus) }
        }
        return try response(tasks: selected)
    }

    private func validTasks(_ focus: [String]) -> [(primary: String, citations: [String])] {
        focus.map { primary in
            var citations = focus
            if let sharedID { citations.append(sharedID) }
            return (primary, citations)
        }
    }

    private func response(tasks: [(primary: String, citations: [String])]) throws -> HTTPResult {
        let values: [[String: Any]] = tasks.map { task in
            [
                "primaryIssueID": task.primary,
                "targetTaskID": "",
                "title": "Fix \(task.primary)",
                "behavior": "Resolve \(task.primary) independently",
                "requirements": [["text": "Resolve the reported issue", "origin": "feedback", "sourceIDs": [task.primary]]],
                "checks": [["text": "The issue is resolved", "origin": "interpretation", "sourceIDs": task.citations]],
                "questions": [],
                "sourceIDs": task.citations
            ]
        }
        let output = try JSONSerialization.data(withJSONObject: ["tasks": values], options: [.sortedKeys])
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]]
        ])
        return .init(data: body, statusCode: 200)
    }
}

enum FeedbackContentFailureCase: String, CaseIterable, Sendable {
    case invalidTargetTaskID, emptyTitle, titleTooLong, emptyBehavior, missingChecks, missingTaskCitations, unexpectedTaskSourceIDs
    case emptyRequirementText, invalidRequirementOrigin, missingRequirementCitations, unexpectedRequirementSourceIDs
    case emptyCheckText, invalidCheckOrigin, missingCheckCitations, unexpectedCheckSourceIDs
    case emptyQuestion, missingQuestionCitations, unexpectedQuestionSourceIDs

    static let unexpectedSourceID = "fsrc_00000000-0000-0000-0000-000000000001"

    var fieldPath: String {
        switch self {
        case .invalidTargetTaskID: "tasks[0].targetTaskID"
        case .emptyTitle, .titleTooLong: "tasks[0].title"
        case .emptyBehavior: "tasks[0].behavior"
        case .missingChecks: "tasks[0].checks"
        case .missingTaskCitations, .unexpectedTaskSourceIDs: "tasks[0].sourceIDs"
        case .emptyRequirementText: "tasks[0].requirements[0].text"
        case .invalidRequirementOrigin: "tasks[0].requirements[0].origin"
        case .missingRequirementCitations, .unexpectedRequirementSourceIDs: "tasks[0].requirements[0].sourceIDs"
        case .emptyCheckText: "tasks[0].checks[0].text"
        case .invalidCheckOrigin: "tasks[0].checks[0].origin"
        case .missingCheckCitations, .unexpectedCheckSourceIDs: "tasks[0].checks[0].sourceIDs"
        case .emptyQuestion: "tasks[0].questions[0].question"
        case .missingQuestionCitations, .unexpectedQuestionSourceIDs: "tasks[0].questions[0].sourceIDs"
        }
    }

    var category: String {
        switch self {
        case .invalidTargetTaskID: "invalidTargetTaskID"
        case .emptyTitle, .emptyBehavior, .emptyRequirementText, .emptyCheckText, .emptyQuestion: "emptyValue"
        case .titleTooLong: "valueTooLong"
        case .missingChecks: "missingItems"
        case .missingTaskCitations, .missingRequirementCitations, .missingCheckCitations, .missingQuestionCitations: "missingCitations"
        case .unexpectedTaskSourceIDs, .unexpectedRequirementSourceIDs, .unexpectedCheckSourceIDs, .unexpectedQuestionSourceIDs: "unexpectedSourceIDs"
        case .invalidRequirementOrigin, .invalidCheckOrigin: "invalidOrigin"
        }
    }
}

private actor FeedbackContentValidationClient: HTTPDataLoading {
    enum Mode: Sendable {
        case failure(FeedbackContentFailureCase)
        case manyMissingCheckCitations(count: Int)
        case valid(targetTaskID: String)
    }

    let issueID: String
    let allowedSourceID: String?
    let mode: Mode
    private(set) var requestBodies: [String] = []

    init(issueID: String, allowedSourceID: String? = nil, mode: Mode) {
        self.issueID = issueID; self.allowedSourceID = allowedSourceID; self.mode = mode
    }

    func data(for request: URLRequest) async throws -> HTTPResult {
        requestBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let tasks: [[String: Any]]
        switch mode {
        case .failure(let testCase): tasks = [task(failure: testCase)]
        case .manyMissingCheckCitations(let count):
            var value = task()
            value["checks"] = (0..<count).map { ["text": "Check \($0)", "origin": "interpretation", "sourceIDs": []] as [String: Any] }
            tasks = [value]
        case .valid(let targetTaskID):
            var value = task(); value["targetTaskID"] = targetTaskID; tasks = [value]
        }
        return try response(tasks: tasks)
    }

    private func task(failure: FeedbackContentFailureCase? = nil) -> [String: Any] {
        let citation = allowedSourceID ?? issueID
        var requirement: [String: Any] = ["text": "Requirement", "origin": "feedback", "sourceIDs": [citation]]
        var check: [String: Any] = ["text": "Check", "origin": "interpretation", "sourceIDs": [citation]]
        var question: [String: Any] = ["question": "Question", "sourceIDs": [citation]]
        var value: [String: Any] = [
            "primaryIssueID": issueID, "targetTaskID": "", "title": "Title", "behavior": "Behavior",
            "requirements": [requirement], "checks": [check], "questions": [question], "sourceIDs": [citation]
        ]
        switch failure {
        case .invalidTargetTaskID: value["targetTaskID"] = "ftask_00000000-0000-0000-0000-000000000001"
        case .emptyTitle: value["title"] = ""
        case .titleTooLong: value["title"] = String(repeating: "x", count: 201)
        case .emptyBehavior: value["behavior"] = ""
        case .missingChecks: value["checks"] = []
        case .missingTaskCitations: value["sourceIDs"] = []
        case .unexpectedTaskSourceIDs: value["sourceIDs"] = [Self.unexpected]
        case .emptyRequirementText: requirement["text"] = ""; value["requirements"] = [requirement]
        case .invalidRequirementOrigin: requirement["origin"] = "recording"; value["requirements"] = [requirement]
        case .missingRequirementCitations: requirement["sourceIDs"] = []; value["requirements"] = [requirement]
        case .unexpectedRequirementSourceIDs: requirement["sourceIDs"] = [Self.unexpected]; value["requirements"] = [requirement]
        case .emptyCheckText: check["text"] = ""; value["checks"] = [check]
        case .invalidCheckOrigin: check["origin"] = "recording"; value["checks"] = [check]
        case .missingCheckCitations: check["sourceIDs"] = []; value["checks"] = [check]
        case .unexpectedCheckSourceIDs: check["sourceIDs"] = [Self.unexpected]; value["checks"] = [check]
        case .emptyQuestion: question["question"] = ""; value["questions"] = [question]
        case .missingQuestionCitations: question["sourceIDs"] = []; value["questions"] = [question]
        case .unexpectedQuestionSourceIDs: question["sourceIDs"] = [Self.unexpected]; value["questions"] = [question]
        case nil: break
        }
        return value
    }

    private func response(tasks: [[String: Any]]) throws -> HTTPResult {
        let output = try JSONSerialization.data(withJSONObject: ["tasks": tasks], options: [.sortedKeys])
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]]
        ])
        return .init(data: body, statusCode: 200)
    }

    private static let unexpected = FeedbackContentFailureCase.unexpectedSourceID
}
