import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import VideoContextCore

struct TaskFrameTests {
    @Test func annotationImageIsBoundedCroppedAndNonDestructive() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let url = paths.root.appending(path: "frame.jpg")
        let output = try await ProcessRunner().run(.init(executable: "/opt/homebrew/bin/ffmpeg", arguments: ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=blue:size=640x480", "-frames:v", "1", url.path]))
        #expect(output.status == 0)
        let original = try Data(contentsOf: url)
        let store = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(title: "Annotation", source: .localFile, sourceValue: "fixture", mediaRelativePath: "video.mp4", duration: 10)
        try await store.createVideo(video)
        let evidence = EvidenceItem(videoID: video.id, timestamp: 3, imageRelativePath: "frame.jpg", ocrText: "Original label", origin: .manual)
        try await store.publishArtifacts(videoID: video.id, transcript: [], evidence: [evidence], brief: .init(videoID: video.id, markdown: "Change label"))
        let snapshot = try await store.taskSnapshot(videoID: video.id)
        var annotation = TaskAnnotation(evidenceID: evidence.id, kind: .rectangle)
        annotation.text = "Use the new label"; annotation.x = 0.1; annotation.y = 0.1; annotation.width = 0.3; annotation.height = 0.3
        let draft = VideoTask(videoID: video.id, sourceRevision: snapshot.video.revisions, content: .init(title: "Label", behavior: "Change", checks: [.init(text: "New label shown")], sourceIDs: [evidence.id], annotations: [annotation]))
        let task = try await store.saveTask(draft, expectedRevision: nil, expectedSource: snapshot.video.revisions)
        let service = TaskMCPService(store: store)
        let rendered = try await service.frame(videoID: video.id, taskID: task.id, evidenceID: evidence.id, expectedRevision: 1, paths: paths)
        if let directory = ProcessInfo.processInfo.environment["VIDEO_CONTEXT_FRAME_REVIEW_DIR"] {
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try rendered.image.write(to: destination.appending(path: "annotated-frame.jpg"))
        }
        #expect(rendered.image != original); #expect(rendered.image.count < 4_000_000)
        #expect(rendered.metadata.annotations[0].text == annotation.text)
        let crop = try await service.frame(videoID: video.id, taskID: task.id, evidenceID: evidence.id, crop: .init(x: 0, y: 0, width: 0.5, height: 0.5), paths: paths)
        let source = try #require(CGImageSourceCreateWithData(crop.image as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320); #expect(image.height == 240)
        #expect(try Data(contentsOf: url) == original)
        #expect(try await store.taskSnapshot(videoID: video.id).evidence[0].ocrText == "Original label")
        try await store.reviewTask(videoID: video.id, taskID: task.id, expectedRevision: task.revision, expectedSource: snapshot.video.revisions)
        var reviewed = try #require(try await store.taskSnapshot(videoID: video.id).tasks.first)
        reviewed.content.annotations[0].text = "Corrected annotation"
        let updated = try await store.saveTask(reviewed, expectedRevision: reviewed.revision, expectedSource: snapshot.video.revisions)
        #expect(!updated.canImplement(snapshot.video))
        await #expect(throws: TaskContextError.conflict) { try await service.frame(videoID: video.id, taskID: task.id, evidenceID: evidence.id, expectedRevision: 1, paths: paths) }
    }
}
