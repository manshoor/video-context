import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct FeedbackAttachmentTests {
    @Test func localImageIsSavedAndLinkedToItsComment() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextFeedback-").appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(title: "Fixture recording", source: .localFile,
                                sourceValue: "fixture.mp4", mediaRelativePath: "fixture.mp4")
        try await store.createVideo(video)
        let batch = FeedbackBatch(videoID: video.id, title: "QA", rawText: "Preview is blank")
        try await store.createFeedback(batch)

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg")
        let image = root.appending(path: "preview.jpg")
        try FileManager.default.copyItem(at: fixture, to: image)

        let model = AppModel(libraryRoot: root, showsDockActivity: false)
        model.selectedVideoID = video.id
        await model.loadFeedback(for: video.id)
        await model.addFeedbackAttachments([image], batchID: batch.id, commentID: batch.comments[0].id)

        let saved = try await store.feedbackSnapshot(id: batch.id).batch
        let source = try #require(saved.sources.first)
        #expect(model.errorMessage == nil)
        #expect(source.filename == "preview.jpg")
        #expect(source.kind == .image && source.status == .ready)
        #expect(saved.comments[0].sourceIDs.contains(source.id))
        let localPath = try #require(source.localPath)
        #expect(FileManager.default.fileExists(atPath: paths.absoluteURL(relativePath: localPath).path))
    }

    @Test func recordingAttachmentKeepsItsLinkWhenProcessingCannotStart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextFeedbackEarlyFailure-\(UUID().uuidString)")
        let model = AppModel(libraryRoot: root, mediaImports: MediaImportOperations(
            local: { _, id, paths in
                let destination = paths.root.appending(path: "videos/\(id)/video.mp4")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: destination)
                return destination
            },
            online: { _, _, _, _ in throw MediaImportError.downloadFailed("unused") }
        ), showsDockActivity: false)
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Early failure")
        let batch = FeedbackBatch(projectID: project.id, title: "Recording attachment", rawText: "The checkout recording failed early.")
        // Add a local MP4 source after parsing so the fixture uses the same
        // attachment path as the production composer.
        var attachedBatch = batch
        let added = attachedBatch.addUnassignedLocalSources(named: ["checkout.mp4"])
        try await store.createFeedback(attachedBatch)
        model.credentialState = .missing

        await model.attachFeedbackFile(
            URL(fileURLWithPath: "/tmp/checkout.mp4"),
            batchID: attachedBatch.id,
            sourceID: try #require(added.first?.id)
        )

        let saved = try await store.feedbackSnapshot(id: attachedBatch.id).batch
        let savedSource = try #require(saved.sources.first)
        let recovery = try #require(try await store.feedbackImportRecovery(batchID: attachedBatch.id, sourceID: savedSource.id))
        #expect(savedSource.recordingID != nil)
        #expect(savedSource.status == .failed)
        #expect(recovery.recordingID == savedSource.recordingID)
        #expect(recovery.phase == .failed)
        #expect((try await store.videoSnapshot(id: savedSource.recordingID!))?.video.projectID == project.id)
    }

    @Test func startupRecoveryDoesNotResubmitUnknownProviderWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextFeedbackRecovery-\(UUID().uuidString)")
        let model = AppModel(libraryRoot: root, showsDockActivity: false)
        let store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Recovery")
        let video = VideoRecord(
            title: "Interrupted recording",
            source: .localFile,
            sourceValue: "fixture.mp4",
            mediaRelativePath: "videos/recovery/video.mp4",
            status: .incomplete,
            projectID: project.id
        )
        try await store.createVideo(video)
        var batch = FeedbackBatch(projectID: project.id, title: "Recovery attachment", rawText: "The provider response was interrupted.")
        let source = FeedbackSource(kind: .recording, status: .pending, recordingID: video.id)
        batch.sources = [source]
        batch.batchWideSourceIDs = [source.id]
        try await store.createFeedback(batch)
        _ = try await store.beginFeedbackImport(
            batchID: batch.id,
            sourceID: source.id,
            projectID: project.id,
            filename: "interrupted.mp4"
        )
        _ = try await store.updateFeedbackImport(batchID: batch.id, sourceID: source.id, phase: .processing, recordingID: video.id)
        _ = try await store.beginProcessingCheckpoint(
            videoID: video.id,
            stage: .analysisBatch,
            itemKey: "batch-0",
            inputFingerprint: "unknown",
            provider: "openAI",
            model: "gpt",
            requestID: "request-unknown"
        )
        try await store.failProcessingCheckpoint(
            videoID: video.id,
            stage: .analysisBatch,
            itemKey: "batch-0",
            errorMessage: "response lost",
            unknownOutcome: true
        )

        model.credentialState = .missing
        await model.recoverFeedbackImports()

        let checkpoints = try await store.processingCheckpoints(videoID: video.id)
        #expect(checkpoints.first?.state == .unknown)
        let recovered = try #require(try await store.feedbackImportRecovery(batchID: batch.id, sourceID: source.id))
        #expect(recovered.phase == .processing)
        #expect(recovered.errorMessage?.contains("uncertain") == true)
        let savedSource = try #require(try await store.feedbackSnapshot(id: batch.id).batch.sources.first)
        #expect(savedSource.recordingID == video.id)
        #expect(savedSource.status == .failed)
    }
}
