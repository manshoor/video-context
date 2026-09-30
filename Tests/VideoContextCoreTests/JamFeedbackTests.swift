import Foundation
import Testing
@testable import VideoContextCore

struct JamFeedbackTests {
    @Test func legacyFeedbackSourcesDecodeWithoutJamAndKeepTheirIDs() throws {
        let source = FeedbackSource(id: "fsrc_legacy", url: "https://example.test/image.png", kind: .image,
                                    status: .ready, localPath: "feedback/image.png")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        object.removeValue(forKey: "jam")

        let decoded = try JSONDecoder().decode(FeedbackSource.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.id == "fsrc_legacy")
        #expect(decoded.jam == nil)
        #expect(decoded.localPath == "feedback/image.png")
    }

    @Test func savedJamEvidenceKeepsTimestampsFramesProvenanceAndAvailabilityAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let database = paths.database
        var batch = FeedbackBatch(title: "QA", project: "Checkout", rawText: "Blank: https://jam.dev/c/save-me")
        let sourceID = try #require(batch.sources.first?.id)
        let imported = JamImportedEvidence(
            sourceURL: "https://jam.dev/c/save-me", recordingID: "save-me", state: .ready,
            importedAt: Date(timeIntervalSince1970: 1_000),
            items: [
                .init(id: "jam_text", component: .transcript, timestampMilliseconds: 1_250,
                      text: "The page is blank", toolName: "getVideoTranscript"),
                .init(id: "jam_frame", component: .frame, timestampMilliseconds: 1_500,
                      imageData: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg", toolName: "getFrames")
            ],
            availability: [.init(component: .transcript, status: .available, message: "Transcript imported.")]
        )
        batch.sources[0].jam = try JamEvidenceReference.save(imported, batchID: batch.id, sourceID: sourceID, paths: paths)
        batch.sources[0].status = .ready
        do {
            let writer = try VideoContextStore(databaseURL: database)
            let project = try await writer.createFeedbackProject(name: "Checkout")
            batch.projectID = project.id
            try await writer.createFeedback(batch)
        }

        let reader = try VideoContextStore(databaseURL: database, access: .readOnly)
        let saved = try #require(try await reader.feedbackSnapshot(id: batch.id).batch.sources.first?.jam)

        #expect(saved.items.first { $0.id == "jam_text" }?.timestampMilliseconds == 1_250)
        #expect(saved.items.first { $0.id == "jam_text" }?.toolName == "getVideoTranscript")
        let frame = try #require(saved.items.first { $0.id == "jam_frame" })
        #expect(frame.toolName == "getFrames")
        #expect(frame.localPath.map { FileManager.default.fileExists(atPath: paths.absoluteURL(relativePath: $0).path) } == true)
        #expect(saved.availability.first?.status == .available)
    }

    @Test func generationIncludesJamTimestampsFramesAndLimitations() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Checkout")
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Checkout is blank: https://jam.dev/c/generate-me")
        let issueID = try #require(batch.comments.first?.id)
        let sourceID = try #require(batch.sources.first?.id)
        let probe = try modelProbeData()
        let imported = JamImportedEvidence(
            sourceURL: "https://jam.dev/c/generate-me", recordingID: "generate-me", state: .ready,
            items: [
                .init(component: .details, text: #"{"title":"Blank checkout"}"#, toolName: "getDetails"),
                .init(component: .transcript, timestampMilliseconds: 1_200, text: "The checkout is blank",
                      toolName: "getVideoTranscript"),
                .init(component: .consoleErrors, timestampMilliseconds: 1_300, text: "Checkout failed",
                      toolName: "getConsoleLogs"),
                .init(component: .frame, timestampMilliseconds: 1_500, imageData: probe, mimeType: "image/jpeg",
                      toolName: "getFrames")
            ],
            availability: [
                .init(component: .transcript, status: .available, message: "Transcript imported."),
                .init(component: .failedRequests, status: .unavailable, message: "No failed requests were returned.")
            ]
        )
        batch.sources[0].jam = try JamEvidenceReference.save(imported, batchID: batch.id, sourceID: sourceID, paths: paths)
        batch.sources[0].status = .ready
        try await store.createFeedback(batch)
        let output = GeneratedTaskBatch(tasks: [.init(
            targetTaskID: "", title: "Fix blank checkout", behavior: "Show the checkout content",
            requirements: [.init(text: batch.comments[0].text, origin: .feedback, sourceIDs: [issueID])],
            checks: [.init(text: "At 1200ms the checkout content is visible", origin: .interpretation, sourceIDs: [sourceID])],
            questions: [], sourceIDs: [issueID, sourceID], primaryIssueID: issueID
        )])
        let log = JamPromptLog()
        let client = JamTaskClient(output: output, log: log)
        let configuration = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))

        let tasks = try await FeedbackGenerator(client: client, configuration: configuration, credential: "",
                                                paths: paths, store: store)
            .generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let prompt = await log.joined

        #expect(tasks.count == 1)
        #expect(prompt.contains("JAM EVIDENCE"))
        #expect(prompt.contains("1200ms"))
        #expect(prompt.contains("Checkout failed"))
        #expect(prompt.contains("getVideoTranscript"))
        #expect(prompt.contains("No failed requests were returned."))
        #expect(tasks[0].content.checks.contains { $0.text.contains("1200ms") && $0.sourceIDs == [sourceID] })
        #expect(tasks[0].content.questions.contains { !$0.isBlocking && $0.question.contains("No failed requests") })
    }

    @Test func unreadJamEvidenceIsNotAnalyzedAndAddsAReconnectBlocker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Checkout")
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Checkout is blank: https://jam.dev/c/unread")
        let issueID = try #require(batch.comments.first?.id)
        let sourceID = try #require(batch.sources.first?.id)
        batch.sources[0].status = .failed
        batch.sources[0].error = "Reconnect Jam in Settings to import this recording."
        batch.sources[0].jam = .init(
            sourceURL: "https://jam.dev/c/unread", recordingID: "unread", state: .unread, importedAt: .now,
            items: [.init(id: "should-not-read", component: .consoleErrors, text: "PRIVATE UNREAD EVIDENCE",
                          toolName: "getConsoleLogs")],
            availability: [.init(component: .details, status: .failed, message: "Recording was not read.")]
        )
        try await store.createFeedback(batch)
        let output = GeneratedTaskBatch(tasks: [.init(
            targetTaskID: "", title: "Fix blank checkout", behavior: "Show the checkout content",
            requirements: [.init(text: batch.comments[0].text, origin: .feedback, sourceIDs: [issueID])],
            checks: [.init(text: "Checkout content is visible", origin: .interpretation, sourceIDs: [issueID])],
            questions: [], sourceIDs: [issueID], primaryIssueID: issueID
        )])
        let log = JamPromptLog()
        let configuration = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))

        let tasks = try await FeedbackGenerator(client: JamTaskClient(output: output, log: log), configuration: configuration,
                                                credential: "", paths: paths, store: store)
            .generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let prompt = await log.joined

        #expect(prompt.contains("PRIVATE UNREAD EVIDENCE") == false)
        #expect(prompt.contains("JAM RECORDING UNREAD"))
        #expect(tasks[0].content.questions.contains { $0.isBlocking && $0.question.contains("Reconnect Jam in Settings") })
        #expect(tasks[0].content.blockers == 1)
        #expect(tasks[0].content.allSourceIDs.contains(sourceID))
    }

    @Test func repeatedJamReferenceStillProducesOneTaskPerFeedbackIssue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Checkout")
        let jamURL = "https://jam.dev/c/repeated"
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Checkout is blank: \(jamURL)\nRetry button is missing: \(jamURL)")
        let sourceID = try #require(batch.sources.first?.id)
        batch.sources[0].status = .ready
        batch.sources[0].jam = .init(
            sourceURL: jamURL, recordingID: "repeated", state: .ready, importedAt: .now,
            items: [.init(id: "details", component: .details, text: "Two issues in the same recording", toolName: "getDetails")],
            availability: []
        )
        try await store.createFeedback(batch)
        let generated = batch.comments.map { issue in
            GeneratedTask(targetTaskID: "", title: "Fix \(issue.id)", behavior: issue.text,
                          requirements: [.init(text: issue.text, origin: .feedback, sourceIDs: [issue.id])],
                          checks: [.init(text: "Issue is fixed", origin: .interpretation, sourceIDs: [sourceID])],
                          questions: [], sourceIDs: [issue.id, sourceID], primaryIssueID: issue.id)
        }
        let configuration = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))

        let tasks = try await FeedbackGenerator(
            client: JamTaskClient(output: .init(tasks: generated), log: JamPromptLog()),
            configuration: configuration, credential: "", paths: paths, store: store
        ).generate(snapshot: try await store.feedbackSnapshot(id: batch.id))

        #expect(tasks.count == 2)
        #expect(Set(tasks.compactMap(\.issueID)) == Set(batch.comments.map(\.id)))
        #expect(batch.sources.count == 1)
    }

    @Test func partialJamUsesTranscriptAndActionsWithoutClaimingVisualInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Checkout")
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Checkout is blank: https://jam.dev/c/partial")
        let issueID = try #require(batch.comments.first?.id)
        let sourceID = try #require(batch.sources.first?.id)
        batch.sources[0].status = .ready
        batch.sources[0].jam = .init(sourceURL: "https://jam.dev/c/partial", recordingID: "partial", state: .ready,
            importedAt: .now,
            items: [.init(id: "transcript", component: .transcript, timestampMilliseconds: 1_200,
                          text: "Page is blank", toolName: "getVideoTranscript"),
                    .init(id: "actions", component: .userActions, timestampMilliseconds: 1_300,
                          text: "Clicked pay", toolName: "getUserEvents")],
            availability: [.init(component: .transcript, status: .available, message: "Transcript imported."),
                           .init(component: .userActions, status: .available, message: "Actions imported."),
                           .init(component: .frame, status: .unsupported, message: "Hosted recording does not support frames.")])
        try await store.createFeedback(batch)
        let output = GeneratedTaskBatch(tasks: [.init(targetTaskID: "", title: "Fix checkout", behavior: "Show checkout",
            requirements: [.init(text: batch.comments[0].text, origin: .feedback, sourceIDs: [issueID])],
            checks: [.init(text: "At 1200ms checkout loads", origin: .interpretation, sourceIDs: [sourceID])],
            questions: [], sourceIDs: [issueID, sourceID], primaryIssueID: issueID)])
        let log = JamPromptLog()
        let configuration = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "test-model"))
        let tasks = try await FeedbackGenerator(client: JamTaskClient(output: output, log: log), configuration: configuration,
                                                credential: "", paths: paths, store: store)
            .generate(snapshot: try await store.feedbackSnapshot(id: batch.id))
        let prompt = await log.joined
        #expect(tasks.count == 1)
        #expect(prompt.contains("Page is blank") && prompt.contains("Clicked pay"))
        #expect(prompt.contains("No video frames were imported"))
        #expect(prompt.contains("JAM VISUAL LIMITATION"))
    }

    private func modelProbeData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg"))
    }
}

private actor JamPromptLog {
    private var values: [String] = []
    var joined: String { values.joined(separator: "\n") }
    func append(_ value: String) { values.append(value) }
}

private struct JamTaskClient: HTTPDataLoading {
    let output: GeneratedTaskBatch
    let log: JamPromptLog
    func data(for request: URLRequest) async throws -> HTTPResult {
        await log.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let content = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": content]]]
        ])
        return .init(data: body, statusCode: 200)
    }
}
