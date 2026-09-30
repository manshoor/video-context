import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoContextCore

struct ProjectDocumentationGenerationImageTests {
    @Test("Documentation generation bounds image batches and sends valid JPEG data")
    func imageBatchesAreBoundedAndNormalized() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "VideoContextDocumentationImages-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        var imagePaths: [String] = []
        for index in 0..<9 {
            let relativePath = "documents/image-\(index).png"
            let url = paths.absoluteURL(relativePath: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makePNG(seed: index).write(to: url)
            imagePaths.append(relativePath)
        }

        let revision = ArtifactRevision(transcript: 1, evidence: 1, brief: 1)
        let evidence = (0..<9).map { index in
            ProjectEvidenceReference.recording(
                videoID: "video-1",
                sourceRevision: revision,
                timestamp: TimeInterval(index),
                evidenceID: "frame-\(index)"
            )
        }
        var imageEvidence: [String: [ProjectEvidenceReference]] = [:]
        for (path, reference) in zip(imagePaths, evidence) {
            imageEvidence[path] = [reference]
        }
        let response = try documentationResponse(
            evidenceID: evidence[0].id,
            sourceID: "recording:video-1"
        )
        let client = DocumentationImageRequestStub(response: .init(data: Data(response.utf8), statusCode: 200))
        let generator = ProjectDocumentationGenerator(
            client: client,
            configuration: .init(analysisModel: "vision", analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")),
            credential: "",
            paths: paths
        )
        let input = ProjectDocumentationGenerationInput(
            projectID: "project-1",
            projectName: "Checkout",
            requestedTitle: "Checkout documentation",
            sources: [
                .init(
                    id: "recording:video-1",
                    title: "Checkout recording",
                    kind: "recording",
                    revision: "r1",
                    text: "The preview remains visible.",
                    evidence: evidence,
                    imageRelativePaths: imagePaths,
                    imageEvidence: imageEvidence
                )
            ],
            textBudget: 4_096
        )

        let generated = try await generator.generate(input: input)
        #expect(generated.sourceIDsCovered == ["recording:video-1"])

        let requests = await client.requests
        #expect(requests.count == 3)
        let imageURLs = try requests.flatMap(Self.imageURLs(in:))
        #expect(imageURLs.count == 9)
        #expect(Set(imageURLs).count == 9)
        let imageCounts = try requests.map { try Self.imageURLs(in: $0).count }
        #expect(imageCounts.allSatisfy { $0 <= 4 })
        for imageURL in imageURLs {
            let value = try #require(imageURL.split(separator: ",", maxSplits: 1).last.map(String.init))
            let jpeg = try #require(Data(base64Encoded: value))
            #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
            #expect(CGImageSourceCreateWithData(jpeg as CFData, nil) != nil)
        }

        let firstPrompt = try Self.text(in: requests[0])
        #expect(firstPrompt.contains("Image 1"))
        #expect(firstPrompt.contains("image-0.png"))
        #expect(firstPrompt.contains("frame-0"))
    }

    @Test("Unavailable images do not consume visual ordinals or lose evidence mapping")
    func missingImageDoesNotShiftVisualEvidenceLabels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "VideoContextDocumentationMissingImage-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        let validPath = "documents/valid.png"
        let validURL = paths.absoluteURL(relativePath: validPath)
        try FileManager.default.createDirectory(at: validURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePNG(seed: 7).write(to: validURL)

        let revision = ArtifactRevision(transcript: 1, evidence: 1, brief: 1)
        let missingEvidence = ProjectEvidenceReference.recording(
            videoID: "video-2", sourceRevision: revision, timestamp: 1, evidenceID: "missing-frame"
        )
        let validEvidence = ProjectEvidenceReference.recording(
            videoID: "video-2", sourceRevision: revision, timestamp: 2, evidenceID: "valid-frame"
        )
        let response = try documentationResponse(evidenceID: validEvidence.id, sourceID: "recording:video-2")
        let client = DocumentationImageRequestStub(response: .init(data: Data(response.utf8), statusCode: 200))
        let generator = ProjectDocumentationGenerator(
            client: client,
            configuration: .init(analysisModel: "vision", analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")),
            credential: "",
            paths: paths
        )
        let input = ProjectDocumentationGenerationInput(
            projectID: "project-2",
            projectName: "Checkout",
            requestedTitle: "Checkout documentation",
            sources: [
                .init(
                    id: "recording:video-2",
                    title: "Checkout recording",
                    kind: "recording",
                    revision: "r1",
                    text: "The valid frame shows the preview.",
                    evidence: [missingEvidence, validEvidence],
                    imageRelativePaths: ["documents/missing.png", validPath],
                    imageEvidence: [
                        "documents/missing.png": [missingEvidence],
                        validPath: [validEvidence]
                    ]
                )
            ],
            textBudget: 4_096
        )

        _ = try await generator.generate(input: input)
        let requests = await client.requests
        let request = try #require(requests.first)
        let prompt = try Self.text(in: request)
        #expect(prompt.contains("Image unavailable for visual review | path: documents/missing.png | matching evidence IDs: \(missingEvidence.id)"))
        #expect(prompt.contains("Image 1 | path: \(validPath) | matching evidence IDs: \(validEvidence.id)"))
        #expect(!prompt.contains("Image 1 | path: documents/missing.png"))
    }

    private static func imageURLs(in request: URLRequest) throws -> [String] {
        let body = try #require(request.httpBody)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        return content.compactMap { item in
            guard item["type"] as? String == "image_url",
                  let image = item["image_url"] as? [String: Any] else { return nil }
            return image["url"] as? String
        }
    }

    private static func text(in request: URLRequest) throws -> String {
        let body = try #require(request.httpBody)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

private actor DocumentationImageRequestStub: HTTPDataLoading {
    let response: HTTPResult
    private(set) var requests: [URLRequest] = []

    init(response: HTTPResult) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        return response
    }
}

private func documentationResponse(evidenceID: String, sourceID: String) throws -> String {
    let payload: [String: Any] = [
        "title": "Checkout",
        "sections": [[
            "title": "Preview",
            "body": "The preview remains visible.",
            "classification": "observed",
            "evidenceIDs": [evidenceID],
            "sourceIDs": [sourceID]
        ]]
    ]
    let payloadText = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    let envelope: [String: Any] = [
        "choices": [[
            "finish_reason": "stop",
            "message": ["content": payloadText]
        ]]
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
}

private func makePNG(seed: Int) throws -> Data {
    let width = 32
    let height = 32
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "ProjectDocumentationGenerationImageTests", code: 1)
    }
    let red = CGFloat((seed * 37) % 255) / 255
    let green = CGFloat((seed * 71) % 255) / 255
    let blue = CGFloat((seed * 109) % 255) / 255
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "ProjectDocumentationGenerationImageTests", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ProjectDocumentationGenerationImageTests", code: 3)
    }
    return data as Data
}
