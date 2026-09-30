import Foundation

public struct UsageQuery: Sendable {
    public var videoID: String?
    public var runID: String?
    public var provider: InferenceProvider?
    public var model: String?
    public var operation: UsageOperation?
    public var since: Date?
    public init(videoID: String? = nil, runID: String? = nil, provider: InferenceProvider? = nil, model: String? = nil, operation: UsageOperation? = nil, since: Date? = nil) {
        self.videoID = videoID; self.runID = runID; self.provider = provider; self.model = model; self.operation = operation; self.since = since
    }
    public func filter(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        let attempts = snapshot.attempts.filter { (provider == nil || $0.provider == provider) && (model == nil || $0.requestedModel == model || $0.resolvedModel == model) }
        let matchingRunIDs = Set(attempts.map(\.runID))
        let runs = snapshot.runs.filter { run in
            (videoID == nil || run.videoID == videoID) && (runID == nil || run.id == runID) && (operation == nil || run.operation == operation) &&
            (since == nil || run.startedAt >= since!) && ((provider == nil && model == nil) || matchingRunIDs.contains(run.id) ||
                (snapshot.attempts.allSatisfy { $0.runID != run.id } && (provider == nil || run.provider == provider) && (model == nil || run.model == model)))
        }
        let ids = Set(runs.map(\.id))
        var result = UsageSnapshot(runs: runs, attempts: attempts.filter { ids.contains($0.runID) }, recordingTitles: snapshot.recordingTitles)
        result.feedbackTitles = snapshot.feedbackTitles
        return result
    }
}
public extension UsageAttempt {
    var usesAudioAccounting: Bool { stage == .transcription && tokens.input == nil && tokens.output == nil && tokens.total == nil }
}
public extension UsageOperation {
    var label: String { switch self { case .processing: "Video processing"; case .taskGeneration: "Task generation"; case .documentationGeneration: "Documentation generation"; case .modelTest: "Model test"; case .earlierUsage: "Earlier usage — run details unavailable" } }
}
public extension UsageStage {
    var label: String { switch self { case .transcription: "Transcription"; case .analysis: "Screenshot and brief analysis"; case .taskExtraction: "Task extraction"; case .taskConsolidation: "Task consolidation"; case .evidenceReview: "Evidence review"; case .modelTest: "Model test" } }
}
public extension UsageOutcome {
    var label: String { switch self { case .running: "Running"; case .completed: "Completed"; case .failed: "Failed"; case .cancelled: "Cancelled"; case .interrupted: "Interrupted"; case .responseReceived: "Response received" } }
}
