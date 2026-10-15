import Foundation
import Testing
@testable import VideoContextCore

struct FeedbackTranscriptTests {
    static let loom = "https://www.loom.com/share/6ad8b2b3a35e411b9c0c1dd28c5e877a"
    static let transcript = """
    0:01 Down before I forget. Um, so we did the 10 based on the dentistry, and this is a really good image, and this is a good layout of that.
    0:13 Um I don't think this is a good hook, so I don't know what happened to my hooks.
    0:49 I don't know about that. But the post reads a little clunky.
    1:11 I don't know why this image is right here, it should be it's 16 by 9, so why you know, why is it crunched up like that?
    1:24 It's kind of AI slop. It's fine. I don't know why it's not one by one, though, when they're all supposed to be one by one.
    1:46 What is this? These are terrible. This is the same image as this.
    2:17 No wonder it looks that way. Oh, that's a zoomed-in cutoff image. Look at that. So they're using images twice.
    2:52 I don't know why. My prompts have like bullet points and stuff in them and emoji. In them, there's no emojis here, so I don't know what happened.
    3:36 If I was to go into brand identity, website website research, oops, brand. In identity, and go to brand gallery.
    3:50 Two men smiling and talking. So that's in there, that's in there, that's in there. No wonder it looks so authentic.
    4:22 What is happening? Why is this taking 20 minutes to do 10 things?
    4:30 I'm not so worried about it, but it's gonna take a developer to do it right.
    """

    @Test(arguments: [false, true])
    func transcriptPassagesAreEvidenceRatherThanIssues(inline: Bool) throws {
        let transcript = inline ? Self.transcript.replacingOccurrences(of: "\n", with: " ") : Self.transcript
        let raw = Self.loom + "\n\nvideo transcript\n" + transcript
        let batch = FeedbackBatch(projectID: "project", title: "David Review", rawText: raw)
        #expect(batch.comments.isEmpty)
        let source = try #require(batch.sources.first { $0.kind.rawValue == "transcript" })
        #expect(source.ocrText == transcript)
        #expect(source.status == .ready)
        #expect(batch.sources.filter { $0.url == Self.loom }.count == 1)
        #expect(Set(batch.batchWideSourceIDs) == Set(batch.sources.map(\.id)))
        #expect(batch.unassignedSourceIDs.isEmpty)
        #expect(batch.rawText == raw)
    }

    @Test func timestampedTranscriptWithoutHeadingIsRecognized() throws {
        let batch = FeedbackBatch(projectID: "project", title: "Review", rawText: Self.loom + "\n" + Self.transcript)
        #expect(batch.comments.isEmpty)
        #expect(batch.sources.contains { $0.kind.rawValue == "transcript" && $0.ocrText == Self.transcript })
    }

    @Test func ordinaryIssuesAndTheirLinksKeepTheirExistingMeaning() {
        let raw = "Preview is blank\n" + Self.loom + "\nPackage never finishes"
        let batch = FeedbackBatch(projectID: "project", title: "QA", rawText: raw)
        #expect(batch.comments.map(\.text) == ["Preview is blank", "Package never finishes"])
        #expect(batch.comments[0].sourceIDs == batch.sources.map(\.id))
        #expect(batch.batchWideSourceIDs.isEmpty)
        let mentionedTimes = FeedbackBatch(projectID: "project", title: "QA", rawText: "The preview fails at 0:13 and 0:27 when clicked.\nKeep the draft")
        #expect(mentionedTimes.comments.count == 2)
        #expect(mentionedTimes.transcriptSources.isEmpty)
    }

    @Test func suppliedIssuesBeforeTranscriptRemainIssues() {
        let batch = FeedbackBatch(projectID: "project", title: "QA", rawText: "Fix duplicated gallery images\n" + Self.loom + "\ntranscript\n" + Self.transcript)
        #expect(batch.comments.map(\.text) == ["Fix duplicated gallery images"])
        #expect(batch.sources.contains { $0.kind.rawValue == "transcript" })
    }

    @Test func transcriptEvidenceSurvivesRestartBeforeAnyIssueExists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "feedback-transcript-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Dentistry")
        let batch = FeedbackBatch(projectID: project.id, title: "Review", rawText: Self.loom + "\ntranscript\n" + Self.transcript)
        try await store.createFeedback(batch)
        let reader = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        let snapshot = try await reader.feedbackSnapshot(id: batch.id)
        #expect(snapshot.batch == batch)
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.batch.needsTranscriptIssueExtraction)
    }

    @Test func legacyTranscriptReparsePreservesImportedMediaAndOriginalText() throws {
        let raw = Self.loom + "\n\nvideo transcript\n" + Self.transcript
        var batch = FeedbackBatch(projectID: "project", title: "David Review", rawText: raw)
        var recording = try #require(batch.sources.first { $0.url == Self.loom })
        recording.kind = .recording; recording.recordingID = "existing-recording"
        let image = FeedbackSource(kind: .image, status: .ready, localPath: "feedback/preview.png", filename: "preview.png")
        batch.sources = [recording, image]
        batch.comments = raw.components(separatedBy: "\n").filter { !$0.isEmpty }.map { .init(text: $0) }
        batch.comments[0].sourceIDs = [recording.id]
        batch.batchWideSourceIDs = [image.id]
        #expect(batch.canReparseTranscript)
        batch.reparseOriginalText()
        #expect(batch.comments.isEmpty)
        #expect(batch.rawText == raw)
        #expect(batch.sources.contains(recording))
        #expect(batch.sources.contains(image))
        #expect(Set(batch.batchWideSourceIDs) == Set(batch.sources.map(\.id)))
        #expect(batch.needsTranscriptIssueExtraction)
        let transcriptID = try #require(batch.transcriptSources.first?.id)
        batch.rawText = raw.replacingOccurrences(of: "good layout", with: "great layout")
        batch.reparseOriginalText()
        #expect(batch.transcriptSources.first?.id == transcriptID)
        #expect(batch.transcriptSources.first?.ocrText.contains("great layout") == true)
        #expect(batch.sources.count == 3)
    }

    @Test func extractedIssuesAreGroundedAndGenerateTasksWithoutCopyingTheWholeTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "feedback-transcript-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Dentistry")
        var batch = FeedbackBatch(projectID: project.id, title: "Review", rawText: Self.transcript)
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "fixture"))
        let issues = try await FeedbackTranscriptExtractor(client: TranscriptClient(), configuration: config, credential: "")
            .extract(batch: batch)
        #expect(issues.count == 2)
        let transcriptID = try #require(batch.transcriptSources.first?.id)
        #expect(issues.allSatisfy { $0.sourceIDs == [transcriptID] })
        #expect(issues.map(\.text).contains { $0.contains("1:46 What is this?") })
        #expect(batch.comments.isEmpty)
        batch.comments = issues
        try await store.createFeedback(batch)
        let snapshot = try await store.feedbackSnapshot(id: batch.id)
        #expect(snapshot.tasks.isEmpty)
        let generated = GeneratedTaskBatch(tasks: issues.map { issue in
            .init(targetTaskID: "", title: issue.text.components(separatedBy: "\n")[0], behavior: "Address the reviewed complaint.",
                  requirements: [.init(text: "Address the reviewed complaint", origin: .feedback, sourceIDs: [issue.id, transcriptID])],
                  checks: [.init(text: "Verify the complaint is resolved", origin: .interpretation, sourceIDs: [issue.id, transcriptID])],
                  questions: [], sourceIDs: [issue.id, transcriptID], primaryIssueID: issue.id)
        })
        let tasks = try await FeedbackGenerator(client: FeedbackTests.MockTaskClient(result: generated),
            configuration: config, credential: "", paths: paths, store: store).generate(snapshot: snapshot)
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.content.requirements.allSatisfy { $0.text != Self.transcript } })
        #expect(tasks.allSatisfy { $0.content.allSourceIDs.contains(transcriptID) })
        let task = try #require(tasks.first)
        let evidence = try await FeedbackMCPService(store: store).evidence(batchID: batch.id, taskID: task.id,
            sourceID: transcriptID, expectedBatchRevision: batch.revision, expectedRevision: task.revision, paths: paths)
        #expect(evidence.metadata.kind == .transcript)
        #expect(evidence.metadata.ocrText == Self.transcript)
    }

    @Test(arguments: ["fabricated quote", ""])
    func fabricatedOrEmptyTranscriptQuotesAreRejected(quote: String) async throws {
        let batch = FeedbackBatch(projectID: "project", title: "Review", rawText: Self.transcript)
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "fixture"))
        await #expect(throws: TaskContextError.self) {
            try await FeedbackTranscriptExtractor(client: TranscriptClient(invalidQuote: quote), configuration: config, credential: "")
                .extract(batch: batch)
        }
        #expect(batch.comments.isEmpty)
        #expect(batch.transcriptSources.first?.ocrText == Self.transcript)
    }

    private struct TranscriptClient: HTTPDataLoading {
        var invalidQuote: String?
        func data(for request: URLRequest) async throws -> HTTPResult {
            let body = try #require(request.httpBody)
            let requestJSON = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(requestJSON["messages"] as? [[String: Any]])
            let contents = try #require(messages.last?["content"] as? [[String: Any]])
            let prompt = contents.compactMap { $0["text"] as? String }.joined(separator: "\n")
            #expect(prompt.contains(FeedbackTranscriptTests.transcript))
            #expect(prompt.contains("Do not create one issue per timestamp or line"))
            #expect(prompt.contains("Ignore praise, filler, navigation"))
            let quote = invalidQuote ?? "1:46 What is this? These are terrible. This is the same image as this."
            let issues = [
                ["text": "Avoid duplicate gallery images", "quotes": [quote]],
                ["text": "Restore the prompt's bullets and emojis", "quotes": ["2:52 I don't know why. My prompts have like bullet points and stuff in them and emoji."]]
            ] as [[String: Any]]
            let output = try JSONSerialization.data(withJSONObject: ["issues": issues])
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]]])
            return .init(data: response, statusCode: 200)
        }
    }
}
