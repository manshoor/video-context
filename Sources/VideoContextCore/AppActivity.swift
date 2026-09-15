import Foundation

/// Transient work owned by the app, never inferred from a persisted stage.
public struct AppActivity: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case copying, downloading
        case processing(ProcessingStatus)

        public var title: String {
            switch self {
            case .copying: "Copying recording"
            case .downloading: "Downloading recording"
            case .processing(let stage): stage.displayName
            }
        }
    }

    public let videoID: String
    public let recordingTitle: String
    public var phase: Phase
    public var completed: Int?
    public var total: Int?
    public var startedAt: Date
    public var detail: String?
    public var title: String { detail ?? phase.title }
    public var isCancelling = false

    public init(videoID: String, recordingTitle: String, phase: Phase, startedAt: Date = .now) {
        self.videoID = videoID
        self.recordingTitle = recordingTitle
        self.phase = phase
        self.startedAt = startedAt
    }

    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public mutating func update(_ progress: ProcessingProgress) {
        detail = progress.detail
        phase = .processing(progress.stage)
        completed = progress.completed
        total = progress.total
        startedAt = progress.stageStartedAt
    }
}

/// Source refreshes cannot replace an unsaved edit.
public struct BriefEditorState: Equatable, Sendable {
    public private(set) var source: String
    public var draft: String
    public private(set) var isEditing = false

    public init(source: String) { self.source = source; draft = source }
    public mutating func begin() { draft = source; isEditing = true }
    public mutating func refresh(_ value: String) {
        source = value
        if !isEditing { draft = value }
    }
    public mutating func cancel() { draft = source; isEditing = false }
    public mutating func saved(_ value: String) {
        source = value
        if draft == value { isEditing = false }
    }
}
