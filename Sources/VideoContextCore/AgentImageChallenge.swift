import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// A disposable library. The answer exists only in memory and in the image pixels.
public struct AgentImageChallenge: Sendable {
    public let paths: LibraryPaths
    public let batchID: String
    public let batchRevision: Int
    public let taskID: String
    public let taskRevision: Int
    public let sourceID: String
    let expectedCode: String

    @concurrent public static func create() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextConnection-\(UUID())", directoryHint: .isDirectory)
        do {
            try Task.checkCancellation()
            let paths = try LibraryPaths(root: root)
            let store = try VideoContextStore(databaseURL: paths.database)
            let project = try await store.createFeedbackProject(name: "Agent connection test")
            var batch = FeedbackBatch(projectID: project.id, title: "MCP image check", project: project.name, rawText: "Read the code in the attached image.")
            let imageURL = try paths.feedbackDirectory(id: batch.id).appending(path: "challenge.png")
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let code = String((0..<8).map { _ in alphabet.randomElement()! })
            try render(code, at: imageURL)
            let source = FeedbackSource(kind: .image, status: .ready, localPath: paths.relativePath(for: imageURL), filename: "challenge.png", ocrText: "")
            batch.sources = [source]
            batch.comments[0].sourceIDs = [source.id]
            try await store.createFeedback(batch)
            let statement = TaskStatement(text: "Read the attached image.", origin: .feedback, sourceIDs: [source.id])
            let task = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision,
                content: .init(title: "MCP image check", behavior: "Read the code from image pixels.", requirements: [statement], checks: [statement], sourceIDs: [source.id])),
                expectedRevision: nil, expectedBatchRevision: batch.revision)
            try Task.checkCancellation()
            return .init(paths: paths, batchID: batch.id, batchRevision: batch.revision, taskID: task.id, taskRevision: task.revision, sourceID: source.id, expectedCode: code)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    public func matches(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == expectedCode
    }
    public var evidenceArguments: [String: String] {
        ["batch_id": batchID, "task_id": taskID, "source_id": sourceID,
         "expected_batch_revision": String(batchRevision), "expected_revision": String(taskRevision)]
    }
    public var prompt: String {
        """
        Use only the video-context-test MCP connection. Call get_feedback_evidence with:
        batch_id: \(batchID)
        task_id: \(taskID)
        source_id: \(sourceID)
        expected_batch_revision: \(batchRevision)
        expected_revision: \(taskRevision)
        Read the eight-character code from the native MCP image. Do not inspect local files or use OCR metadata. Return only the code.
        """
    }
    public func remove() { try? FileManager.default.removeItem(at: paths.root) }

    private static func render(_ code: String, at url: URL) throws {
        guard let context = CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VideoFrameError.frameUnavailable }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 145, nil)
        let text = NSAttributedString(string: code, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (1200 - width) / 2, y: 150)
        CTLineDraw(line, context)
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw VideoFrameError.frameUnavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VideoFrameError.frameUnavailable }
    }
}
