import Foundation

public struct ProcessingProgress: Equatable, Sendable {
    public let detail: String?
    public let stage: ProcessingStatus
    public let completed: Int?
    public let total: Int?
    public let stageStartedAt: Date

    public init(
        stage: ProcessingStatus,
        completed: Int? = nil,
        total: Int? = nil,
        stageStartedAt: Date = .now,
        detail: String? = nil
    ) {
        self.detail = detail
        self.stage = stage
        self.completed = completed
        self.total = total
        self.stageStartedAt = stageStartedAt
    }
}

public typealias ProcessingProgressHandler = @Sendable (ProcessingProgress) async -> Void

public extension ProcessingStatus {
    var displayName: String {
        switch self {
        case .imported: "Imported"
        case .inspecting: "Inspecting"
        case .extractingAudio: "Extracting audio"
        case .transcribing: "Transcribing"
        case .capturingFrames: "Capturing frames"
        case .recognizingText: "Reading screen text"
        case .analyzing: "Building brief"
        case .ready: "Ready"
        case .incomplete: "Incomplete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
