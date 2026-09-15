import Foundation

public enum VideoSource: String, Codable, Sendable, CaseIterable {
    case localFile
    case onlineURL
}

public enum ProcessingStatus: String, Codable, Sendable, CaseIterable {
    case imported
    case inspecting
    case extractingAudio
    case transcribing
    case capturingFrames
    case recognizingText
    case analyzing
    case ready
    case incomplete
    case failed
    case cancelled
}

public struct VideoRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public let source: VideoSource
    public let sourceValue: String
    public var mediaRelativePath: String
    public var duration: TimeInterval
    public var status: ProcessingStatus
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revisions: ArtifactRevision
    public var estimatedCostUSD: Double

    public init(
        id: String = "vid_\(UUID().uuidString.lowercased())",
        title: String,
        source: VideoSource,
        sourceValue: String,
        mediaRelativePath: String,
        duration: TimeInterval = 0,
        status: ProcessingStatus = .imported,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        revisions: ArtifactRevision = .init(),
        estimatedCostUSD: Double = 0
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.sourceValue = sourceValue
        self.mediaRelativePath = mediaRelativePath
        self.duration = duration
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revisions = revisions
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoID: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let originalText: String
    public var correctedText: String?

    public var text: String { correctedText ?? originalText }
    public var isCorrected: Bool { correctedText != nil }

    public init(
        id: String = "seg_\(UUID().uuidString.lowercased())",
        videoID: String,
        start: TimeInterval,
        end: TimeInterval,
        originalText: String,
        correctedText: String? = nil
    ) {
        self.id = id
        self.videoID = videoID
        self.start = start
        self.end = end
        self.originalText = originalText
        self.correctedText = correctedText
    }
}

public enum EvidenceOrigin: String, Codable, Sendable {
    case automatic
    case manual
}

public struct EvidenceItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoID: String
    public let timestamp: TimeInterval
    public let imageRelativePath: String
    public var ocrText: String
    public let origin: EvidenceOrigin

    public init(
        id: String = "ev_\(UUID().uuidString.lowercased())",
        videoID: String,
        timestamp: TimeInterval,
        imageRelativePath: String,
        ocrText: String = "",
        origin: EvidenceOrigin
    ) {
        self.id = id
        self.videoID = videoID
        self.timestamp = timestamp
        self.imageRelativePath = imageRelativePath
        self.ocrText = ocrText
        self.origin = origin
    }
}

public struct BriefDocument: Codable, Equatable, Sendable {
    public let videoID: String
    public var markdown: String
    public var isUserEdited: Bool

    public init(videoID: String, markdown: String, isUserEdited: Bool = false) {
        self.videoID = videoID
        self.markdown = markdown
        self.isUserEdited = isUserEdited
    }
}

public enum APIUsageStage: String, Codable, Sendable {
    case transcription
    case analysis
    case taskGeneration
}

public struct APIUsageRecord: Codable, Equatable, Sendable, Identifiable {
    public let provider: InferenceProvider
    public let id: String
    public let videoID: String
    public let stage: APIUsageStage
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let audioSeconds: Double?
    public let createdAt: Date

    public init(
        id: String = "usage_\(UUID().uuidString.lowercased())",
        videoID: String,
        stage: APIUsageStage,
        model: String,
        provider: InferenceProvider = .openAI,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        audioSeconds: Double? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.videoID = videoID
        self.provider = provider
        self.stage = stage
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.audioSeconds = audioSeconds
        self.createdAt = createdAt
    }
}

public struct VideoSnapshot: Codable, Equatable, Sendable {
    public let video: VideoRecord
    public let transcript: [TranscriptSegment]
    public let evidence: [EvidenceItem]
    public let brief: BriefDocument?
    public let apiUsage: [APIUsageRecord]
    public var provenance: [ArtifactProvenance] = []
}

public enum SearchHitKind: String, Codable, Hashable, Sendable {
    case transcript
    case evidence
    case brief
}

public struct SearchHit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: SearchHitKind
    public let text: String
    public let start: TimeInterval?
    public let end: TimeInterval?
}

public struct Page<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let items: [Element]
    public let nextCursor: String?

    public init(items: [Element], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum VideoContextStoreError: Error, LocalizedError, Equatable {
    case videoNotFound(String)
    case transcriptSegmentNotFound(String)
    case invalidCursor
    case invalidLimit
    case emptyQuery
    case briefUnavailable(String, ProcessingStatus)
    case invalidTimeRange

    public var errorDescription: String? {
        switch self {
        case .videoNotFound(let id): "Recording not found: \(id)"
        case .transcriptSegmentNotFound(let id): "Transcript segment not found: \(id)"
        case .invalidCursor: "The continuation cursor is invalid."
        case .invalidLimit: "The page limit must be between 1 and 100."
        case .emptyQuery: "Enter text to search for."
        case .briefUnavailable(let id, let status):
            "The coding brief is not available for recording \(id). Current status: \(status.displayName)."
        case .invalidTimeRange: "The time range must start at zero or later and end after it starts."
        }
    }
}
