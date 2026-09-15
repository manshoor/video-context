import Foundation
import Vision

public struct VisionTextRecognizer: TextRecognizing, Sendable {
    public init() {}

    @concurrent
    public func recognizeText(in imageURL: URL) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: imageURL)
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
