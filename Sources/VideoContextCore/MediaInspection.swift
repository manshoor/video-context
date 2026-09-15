import Foundation

public struct MediaInspection: Equatable, Sendable {
    public let duration: TimeInterval
    public let hasVideo: Bool
    public let hasAudio: Bool

    public init(duration: TimeInterval, hasVideo: Bool, hasAudio: Bool) {
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    public static func decode(_ data: Data) throws -> Self {
        struct Probe: Decodable {
            struct Format: Decodable { let duration: String? }
            struct Stream: Decodable { let codecType: String
                enum CodingKeys: String, CodingKey { case codecType = "codec_type" }
            }
            let format: Format
            let streams: [Stream]
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              let value = probe.format.duration.flatMap(TimeInterval.init) else {
            throw MediaProcessingError.invalidMedia("ffprobe did not return a valid duration.")
        }
        return Self(
            duration: value,
            hasVideo: probe.streams.contains { $0.codecType == "video" },
            hasAudio: probe.streams.contains { $0.codecType == "audio" }
        )
    }
}

public enum InstructionCueDetector {
    private static let terms = [
        "click", "open", "select", "choose", "change", "fix", "error", "issue",
        "here", "this", "should", "expected", "button", "field", "page"
    ]

    public static func timestamps(in segments: [TranscriptSegment]) -> [TimeInterval] {
        segments.compactMap { segment in
            let words = Set(segment.text.lowercased().split { $0.isLetter == false }.map(String.init))
            return terms.contains(where: words.contains) ? segment.start : nil
        }
    }
}

public enum MediaProcessingError: Error, LocalizedError, Equatable {
    case dependencyMissing(String)
    case invalidMedia(String)
    case audioMissing
    case videoMissing
    case commandFailed(String)
    case fileTooLarge(Int64)
    case processingAlreadyActive

    public var errorDescription: String? {
        switch self {
        case .dependencyMissing(let name): "\(name) is not available. Check its path in Settings."
        case .invalidMedia(let reason): "The recording is invalid: \(reason)"
        case .audioMissing: "The recording has no audio track to transcribe."
        case .videoMissing: "The recording has no video track."
        case .commandFailed(let message): message
        case .fileTooLarge(let bytes): "The audio chunk is \(bytes) bytes, above the 25 MB API limit."
        case .processingAlreadyActive: "Another recording is already processing."
        }
    }
}
