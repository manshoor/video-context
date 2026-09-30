import Foundation
import Testing
@testable import VideoContextCore

struct JamMCPTests {
    @Test func jamContextRequiresExactScopeAndPaginatesTextFramesAndAvailability() async throws {
        let fixture = try await makeFixture()
        let service = FeedbackMCPService(store: fixture.store)
        var cursor: String?
        var blocks: [FeedbackJamContextBlock] = []
        var imageIDs: [String] = []

        repeat {
            let result = try await service.jamContext(
                batchID: fixture.batch.id, taskID: fixture.task.id, sourceID: fixture.source.id,
                expectedBatchRevision: fixture.batch.revision, expectedRevision: fixture.task.revision,
                cursor: cursor, paths: fixture.paths
            )
            #expect(result.page.batchID == fixture.batch.id)
            #expect(result.page.taskID == fixture.task.id)
            #expect(result.page.sourceID == fixture.source.id)
            blocks += result.page.blocks
            imageIDs += result.images.map(\.itemID)
            cursor = result.page.nextCursor
        } while cursor != nil

        #expect(blocks.contains { $0.component == .transcript && $0.timestampMilliseconds == 1_250 && $0.toolName == "getVideoTranscript" })
        #expect(blocks.first { $0.component == .transcript }?.evidenceImportedAt == Date(timeIntervalSince1970: 1_000))
        #expect(blocks.contains { $0.kind == "availability" && $0.text.contains("microphone audio") })
        #expect(blocks.contains { $0.kind == "retry_availability" && $0.component == .frame && $0.text.contains("hosted recording") })
        #expect(imageIDs == ["jam_frame"])
        #expect(blocks.count > 3)

        await #expect(throws: TaskContextError.self) {
            try await service.jamContext(batchID: "wrong", taskID: fixture.task.id, sourceID: fixture.source.id,
                expectedBatchRevision: fixture.batch.revision, expectedRevision: fixture.task.revision, paths: fixture.paths)
        }
        await #expect(throws: TaskContextError.conflict) {
            try await service.jamContext(batchID: fixture.batch.id, taskID: fixture.task.id, sourceID: fixture.source.id,
                expectedBatchRevision: fixture.batch.revision + 1, expectedRevision: fixture.task.revision, paths: fixture.paths)
        }
        await #expect(throws: TaskContextError.conflict) {
            try await service.jamContext(batchID: fixture.batch.id, taskID: fixture.task.id, sourceID: "other",
                expectedBatchRevision: fixture.batch.revision, expectedRevision: fixture.task.revision, paths: fixture.paths)
        }
    }

    @Test func feedbackEvidenceMetadataSummarizesJamWithoutSecretsOrExcludedHTTPData() async throws {
        let fixture = try await makeFixture()
        let result = try await FeedbackMCPService(store: fixture.store).evidence(
            batchID: fixture.batch.id, taskID: fixture.task.id, sourceID: fixture.source.id,
            expectedBatchRevision: fixture.batch.revision, expectedRevision: fixture.task.revision, paths: fixture.paths
        )
        let jam = try #require(result.metadata.jam)
        let encoded = String(decoding: try JSONEncoder().encode(result.metadata), as: UTF8.self)

        #expect(jam.state == .ready)
        #expect(jam.itemCount == fixture.source.jam?.items.count)
        #expect(jam.tools == ["getFrames", "getNetworkRequests", "getVideoTranscript"])
        #expect(jam.availability.contains { $0.component == .transcript })
        #expect(jam.lastAttemptAt == Date(timeIntervalSince1970: 1_100))
        #expect(jam.lastAttemptAvailability?.first?.component == .frame)
        #expect(result.metadata.presentationStatus == "Partially imported")
        #expect(encoded.localizedCaseInsensitiveContains("authorization") == false)
        #expect(encoded.localizedCaseInsensitiveContains("requestBody") == false)
        #expect(encoded.contains("access-secret") == false)
    }

    @Test func handoffRequiresCursorToRetrieveJamContextWithExactRevisions() async throws {
        let fixture = try await makeFixture()
        let message = try FeedbackHandoff.message(
            snapshot: .init(batch: fixture.batch, tasks: [fixture.task], proposals: []),
            selected: [fixture.task.id], mode: .plan
        )

        #expect(message.contains("get_feedback_jam_context"))
        #expect(message.contains("batch_id=\"\(fixture.batch.id)\""))
        #expect(message.contains("task_id=\"\(fixture.task.id)\""))
        #expect(message.contains("source_id"))
        #expect(message.contains("Follow every continuation cursor"))
        #expect(message.contains("Cursor will not need Jam credentials"))
    }

    private func makeFixture() async throws -> JamMCPFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Checkout")
        var batch = FeedbackBatch(projectID: project.id, title: "QA", project: project.name,
                                  rawText: "Checkout is blank: https://jam.dev/c/mcp")
        let issueID = try #require(batch.comments.first?.id)
        let sourceID = try #require(batch.sources.first?.id)
        let directory = try paths.feedbackDirectory(id: batch.id)
        let frameURL = directory.appending(path: "jam-frame.jpg")
        try modelProbeData().write(to: frameURL)
        let longTranscript = (0..<420).map { "[1250ms] Transcript line \($0)" }.joined(separator: "\n")
        batch.sources[0].status = .ready
        batch.sources[0].jam = .init(
            sourceURL: "https://jam.dev/c/mcp", recordingID: "mcp", state: .ready,
            importedAt: Date(timeIntervalSince1970: 1_000),
            items: [
                .init(id: "jam_transcript", component: .transcript, timestampMilliseconds: 1_250,
                      text: longTranscript, toolName: "getVideoTranscript"),
                .init(id: "jam_request", component: .failedRequests, timestampMilliseconds: 1_500,
                      text: #"[{"method":"POST","statusCode":422,"url":"https://shop.test/pay"}]"#,
                      toolName: "getNetworkRequests"),
                .init(id: "jam_frame", component: .frame, timestampMilliseconds: 1_750,
                      localPath: paths.relativePath(for: frameURL), mimeType: "image/jpeg", toolName: "getFrames")
            ],
            availability: [
                .init(component: .transcript, status: .available, message: "Transcript imported."),
                .init(component: .consoleErrors, status: .unavailable, message: "Console errors require microphone audio or supported capture data.")
            ],
            lastAttemptAt: Date(timeIntervalSince1970: 1_100),
            lastAttemptAvailability: [.init(component: .frame, status: .unsupported,
                                            message: "Frames unavailable for this hosted recording.")]
        )
        try await store.createFeedback(batch)
        let content = TaskContent(
            title: "Fix checkout", behavior: "Show checkout content",
            requirements: [.init(text: batch.comments[0].text, origin: .feedback, sourceIDs: [issueID])],
            checks: [.init(text: "Checkout is visible", origin: .interpretation, sourceIDs: [sourceID])],
            sourceIDs: [issueID, sourceID]
        )
        let task = try await store.saveFeedbackTask(
            .init(batchID: batch.id, issueID: issueID, sourceRevision: batch.revision, content: content),
            expectedRevision: nil, expectedBatchRevision: batch.revision
        )
        return .init(paths: paths, store: store, batch: batch, source: batch.sources[0], task: task)
    }

    private func modelProbeData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg"))
    }
}

private struct JamMCPFixture {
    let paths: LibraryPaths
    let store: VideoContextStore
    let batch: FeedbackBatch
    let source: FeedbackSource
    let task: FeedbackTask
}
