import Foundation

public struct TranscriptSlice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: String = UUID().uuidString, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    public static func == (lhs: TranscriptSlice, rhs: TranscriptSlice) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end && lhs.text == rhs.text
    }
}

public struct ChunkTranscript: Codable, Equatable, Sendable {
    public let chunkStart: TimeInterval
    public let segments: [TranscriptSlice]

    public init(chunkStart: TimeInterval, segments: [TranscriptSlice]) {
        self.chunkStart = chunkStart
        self.segments = segments
    }
}

public enum TranscriptMerger {
    public static func merge(_ chunks: [ChunkTranscript]) -> [TranscriptSlice] {
        var result: [TranscriptSlice] = []
        for chunk in chunks.sorted(by: { $0.chunkStart < $1.chunkStart }) {
            for segment in chunk.segments {
                let absolute = TranscriptSlice(
                    start: chunk.chunkStart + segment.start,
                    end: chunk.chunkStart + segment.end,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard absolute.text.isEmpty == false else { continue }
                if let duplicate = result.last(where: {
                    normalized($0.text) == normalized(absolute.text) && $0.end >= absolute.start
                }) {
                    if absolute.end > duplicate.end, let index = result.lastIndex(where: { $0.id == duplicate.id }) {
                        result[index].end = absolute.end
                    }
                    continue
                }
                result.append(absolute)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
