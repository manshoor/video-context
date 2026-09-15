import Foundation

public struct LocalAnalysisBatch: Sendable {
    public var transcript: [TranscriptSegment] = []
    public var evidence: [EvidenceItem] = []
}

public enum LocalAnalysisBatchPlanner {
    /// UTF-8 bytes give a conservative text budget without assuming English tokenization.
    public static func pieces(_ text: String, budget: Int) -> [String] {
        let budget = max(256, budget)
        var pieces: [String] = [], current = "", bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > budget && !current.isEmpty { pieces.append(current); current = ""; bytes = 0 }
            current.append(character); bytes += size
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [""] : pieces
    }

    public static func batches(transcript: [TranscriptSegment], evidence: [EvidenceItem], textBudget: Int = 16_000, maxFrames: Int = 2) -> [LocalAnalysisBatch] {
        let budget = max(512, textBudget)
        var events: [(time: Double, segment: TranscriptSegment?, frame: EvidenceItem?)] = []
        for segment in transcript {
            for text in pieces(segment.text, budget: budget - 256) {
                events.append((segment.start, TranscriptSegment(id: segment.id, videoID: segment.videoID, start: segment.start, end: segment.end, originalText: text), nil))
            }
        }
        for frame in evidence {
            for text in pieces(frame.ocrText, budget: budget - 256) {
                var part = frame; part.ocrText = text
                events.append((frame.timestamp, nil, part))
            }
        }
        events.sort { $0.time < $1.time }
        var result: [LocalAnalysisBatch] = [], current = LocalAnalysisBatch(), bytes = 0
        for event in events {
            let size = (event.segment?.text ?? event.frame?.ocrText ?? "").utf8.count + 128
            if bytes > 0 && (bytes + size > budget || (event.frame != nil && current.evidence.count >= max(1, maxFrames))) {
                result.append(current); current = .init(); bytes = 0
            }
            if let segment = event.segment { current.transcript.append(segment) }
            if let frame = event.frame { current.evidence.append(frame) }
            bytes += size
        }
        if bytes > 0 { result.append(current) }
        return result
    }
}
