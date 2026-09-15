import Foundation

public struct PaginationCursor: Codable, Equatable, Sendable {
    public let offset: Int

    public init(offset: Int) {
        self.offset = max(0, offset)
    }

    public init?(encoded: String) {
        guard
            let data = Data(base64Encoded: encoded),
            let decoded = try? JSONDecoder().decode(Self.self, from: data),
            decoded.offset >= 0
        else { return nil }
        self = decoded
    }

    public var encoded: String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }
}

public struct ArtifactRevision: Codable, Equatable, Sendable {
    public var transcript: Int
    public var evidence: Int
    public var brief: Int
    public var briefSourceTranscript: Int
    public var briefSourceEvidence: Int

    public init(
        transcript: Int = 0,
        evidence: Int = 0,
        brief: Int = 0,
        briefSourceTranscript: Int = 0,
        briefSourceEvidence: Int = 0
    ) {
        self.transcript = transcript
        self.evidence = evidence
        self.brief = brief
        self.briefSourceTranscript = briefSourceTranscript
        self.briefSourceEvidence = briefSourceEvidence
    }

    public var isBriefStale: Bool {
        briefSourceTranscript != transcript || briefSourceEvidence != evidence
    }

    public func afterTranscriptCorrection() -> Self {
        var next = self
        next.transcript += 1
        return next
    }

    public func afterEvidenceCorrection() -> Self {
        var next = self
        next.evidence += 1
        return next
    }

    public func afterBriefRegeneration() -> Self {
        var next = self
        next.brief += 1
        next.briefSourceTranscript = transcript
        next.briefSourceEvidence = evidence
        return next
    }
}

public enum AgentHandoff {
    public static func message(video: VideoRecord, state: AgentHandoffState) -> String {
        """
        I’ve recorded a walkthrough for this task in Video Context. Use the `video-context` MCP server to understand the requested changes and inspect the supporting evidence.

        **Recording:** \(video.title)  
        **Context ID:** `\(video.id)`  
        **Status when copied:** \(state.description)

        Start by calling `get_video_brief` with `video_id="\(video.id)"`. Then use `search_video`, `get_video_segment`, and `get_video_frame` with that same ID to inspect relevant transcript passages and screenshots. Follow continuation cursors when present.

        Keep this task scoped to this exact Context ID. Do not call `list_videos`, search by title to choose another recording, or switch recordings unless I explicitly ask.

        If processing is incomplete or the brief is stale, clearly identify what is missing and use available evidence cautiously. Report unavailable evidence instead of guessing. Check the evidence before implementing changes.

        If the MCP tools are unavailable, ask me to connect the Video Context MCP server.
        """
    }
}

public enum AgentHandoffState: Equatable, Sendable {
    case ready
    case importing(stage: String)
    case active(stage: ProcessingStatus, completed: Int?, total: Int?, elapsedSeconds: Int)
    case paused(stage: ProcessingStatus)
    case failed(message: String)
    case stale

    public var description: String {
        switch self {
        case .ready:
            "Ready"
        case .importing(let stage):
            "Importing: \(stage)"
        case .active(let stage, let completed, let total, let elapsedSeconds):
            if let completed, let total {
                "Processing: \(stage.displayName) (\(completed) of \(total), \(elapsedSeconds)s elapsed)"
            } else {
                "Processing: \(stage.displayName) (\(elapsedSeconds)s elapsed)"
            }
        case .paused(let stage):
            "Paused at \(stage.displayName)"
        case .failed(let message):
            "Failed: \(message)"
        case .stale:
            "Ready with a stale coding brief"
        }
    }

    public static func effective(
        video: VideoRecord,
        isActive: Bool,
        progress: ProcessingProgress?,
        elapsedSeconds: Int
    ) -> Self {
        if isActive {
            let stage = progress?.stage ?? video.status
            return .active(
                stage: stage,
                completed: progress?.completed,
                total: progress?.total,
                elapsedSeconds: max(0, elapsedSeconds)
            )
        }
        switch video.status {
        case .ready:
            return video.revisions.isBriefStale ? AgentHandoffState.stale : AgentHandoffState.ready
        case .failed, .incomplete:
            return .failed(message: video.errorMessage ?? video.status.displayName)
        case .cancelled:
            return .paused(stage: video.status)
        default:
            return .paused(stage: video.status)
        }
    }
}
