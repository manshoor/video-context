import Foundation
import Vision

public struct FrameSimilarityDeduplicator: Sendable {
    public let similarityThreshold: Float
    public let cueTolerance: TimeInterval

    public init(similarityThreshold: Float = 0.08, cueTolerance: TimeInterval = 1) {
        self.similarityThreshold = similarityThreshold
        self.cueTolerance = cueTolerance
    }

    @concurrent
    public func deduplicate(
        _ frames: [CapturedFrame],
        preserving transcriptCueTimestamps: [TimeInterval]
    ) async -> [CapturedFrame] {
        var kept: [(frame: CapturedFrame, feature: VNFeaturePrintObservation?)] = []
        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            let protected = transcriptCueTimestamps.contains { abs($0 - frame.timestamp) <= cueTolerance }
            let feature = try? featurePrint(for: frame.url)
            let duplicatesPriorFrame = feature.map { candidate in
                kept.contains { prior in
                    guard let existing = prior.feature else { return false }
                    var distance: Float = 1
                    try? candidate.computeDistance(&distance, to: existing)
                    return distance < similarityThreshold
                }
            } ?? false

            if protected || duplicatesPriorFrame == false {
                kept.append((frame, feature))
            }
        }
        return kept.map(\.frame)
    }

    private func featurePrint(for url: URL) throws -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url)
        try handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}
