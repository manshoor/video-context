import Foundation

public struct AudioChunkFile: Equatable, Sendable {
    public let chunk: AudioChunk
    public let url: URL

    public init(chunk: AudioChunk, url: URL) {
        self.chunk = chunk
        self.url = url
    }
}

public struct CapturedFrame: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let requestedTimestamp: TimeInterval
    public let url: URL

    public init(timestamp: TimeInterval, url: URL, requestedTimestamp: TimeInterval? = nil) {
        self.timestamp = timestamp
        self.requestedTimestamp = requestedTimestamp ?? timestamp
        self.url = url
    }
}

public protocol MediaProcessing: Sendable {
    func inspect(_ videoURL: URL) async throws -> MediaInspection
    func silencePoints(in videoURL: URL) async throws -> [TimeInterval]
    func sceneChanges(in videoURL: URL) async throws -> [TimeInterval]
    func extractAudio(from videoURL: URL, chunks: [AudioChunk], directory: URL) async throws -> [AudioChunkFile]
    func captureFrames(from videoURL: URL, timestamps: [TimeInterval], directory: URL) async throws -> [CapturedFrame]
}

/// Optional streaming support for media processors that can publish each
/// completed frame before the entire capture batch finishes. The pipeline uses
/// this to persist a frame checkpoint immediately, so an interrupted batch can
/// resume from the first uncaptured timestamp.
public protocol IncrementalFrameCapturing: Sendable {
    func captureFrames(
        from videoURL: URL,
        timestamps: [TimeInterval],
        directory: URL,
        onFrame: @escaping @Sendable (CapturedFrame) async throws -> Void
    ) async throws -> [CapturedFrame]
}

public protocol Transcribing: Sendable {
    func releaseResources() async
    func transcribe(audioURL: URL, videoID: String, chunkStart: TimeInterval) async throws -> [TranscriptSegment]
}

public protocol TextRecognizing: Sendable {
    func recognizeText(in imageURL: URL) async throws -> String
}

public protocol BriefGenerating: Sendable {
    func generate(
        videoID: String,
        transcript: [TranscriptSegment],
        evidence: [EvidenceItem],
        paths: LibraryPaths,
        progress: ProcessingProgressHandler?
    ) async throws -> BriefDocument
}

public extension Transcribing {
    func releaseResources() async {}
}

public struct SavedTranscriptOnly: Transcribing {
    public init() {}
    public func transcribe(audioURL: URL, videoID: String, chunkStart: TimeInterval) async throws -> [TranscriptSegment] {
        throw LocalProviderError.configuration("The saved transcript is unavailable. Choose a transcription provider in Settings.")
    }
}
