import Foundation

public enum ProjectSourceReference: Codable, Hashable, Sendable, Identifiable {
    case recording(String)
    case feedback(String)
    public var id: String { switch self { case .recording(let id): "recording:\(id)"; case .feedback(let id): "feedback:\(id)" } }
}

public enum ProjectTaskReference: Codable, Hashable, Sendable, Identifiable {
    case recording(videoID: String, taskID: String)
    case feedback(batchID: String, taskID: String)
    public var taskID: String { switch self { case .recording(_, let id), .feedback(_, let id): id } }
    public var source: ProjectSourceReference { switch self { case .recording(let id, _): .recording(id); case .feedback(let id, _): .feedback(id) } }
    public var id: String { "\(source.id):\(taskID)" }
}

/// The source revision captured by a task when it was created or generated.
///
/// Workspace items also expose a current source signature for handoff
/// eligibility. Keeping this separate lets read-only context retrieval cite
/// the exact historical source revision used by a stale task instead of
/// silently pointing at the current source.
public enum ProjectTaskSourceRevision: Codable, Equatable, Sendable {
    case recording(ArtifactRevision)
    case feedback(Int)
}

public struct ProjectTaskItem: Sendable, Identifiable {
    public let reference: ProjectTaskReference
    public let sourceTitle: String
    public let origin: String
    public let content: TaskContent
    public let revision: Int
    public let archived: Bool
    public let canImplement: Bool
    public let isStale: Bool
    public let reviewed: Bool
    public let sourceSignature: String
    public let sourceRevision: ProjectTaskSourceRevision
    public var id: ProjectTaskReference { reference }
    public var taskID: String { reference.taskID }
    public var state: String { archived ? "Archived" : canImplement ? "Ready for handoff" : reviewed && !isStale ? "Reviewed" : "Needs review" }
    public var openQuestions: Int { content.questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }

    init(task: VideoTask, video: VideoRecord) {
        reference = .recording(videoID: video.id, taskID: task.id)
        sourceTitle = video.title; origin = task.generatedOriginal == nil ? "Manual task" : "Recording"
        content = task.content; revision = task.revision; archived = task.archived
        canImplement = task.canImplement(video); isStale = task.isStale(video); reviewed = task.reviewedRevision == task.revision
        sourceRevision = .recording(task.sourceRevision)
        sourceSignature = "\(video.projectID ?? ""):\(video.revisions):\(video.status)"
    }
    init(task: FeedbackTask, batch: FeedbackBatch) {
        reference = .feedback(batchID: batch.id, taskID: task.id)
        sourceTitle = batch.title
        origin = batch.comments.first(where: { $0.id == task.issueID })?.kind == .request ? "Request" : "Feedback"
        content = task.content; revision = task.revision; archived = task.archived
        canImplement = task.canImplement(in: batch)
        isStale = task.sourceRevision != batch.revision || task.analysisIsStale == true
        reviewed = task.isApproved
        sourceRevision = .feedback(task.sourceRevision)
        sourceSignature = "\(batch.projectID ?? ""):\(batch.revision)"
    }
}

public struct ProjectProposalItem: Sendable, Identifiable {
    public let id: String
    public let source: ProjectSourceReference
    public let sourceTitle: String
    public let content: TaskContent?
    public let outdated: Bool
    public let recording: TaskProposal?
    public let feedback: FeedbackTaskProposal?
    public var title: String { content?.title ?? "Archive task" }
}

public struct ProjectWorkspaceSnapshot: Sendable {
    public let project: FeedbackProject?
    public let recordings: [VideoRecord]
    public let batches: [FeedbackBatch]
    public let tasks: [ProjectTaskItem]
    public let proposals: [ProjectProposalItem]
    public let conflicts: [ProjectSourceReference]
}

public struct ProjectMovePreview: Sendable, Identifiable {
    public let source: ProjectSourceReference
    public let destination: FeedbackProject
    public let recordings: [VideoRecord]
    public let batches: [FeedbackBatch]
    public let tasks: [ProjectTaskItem]
    public let signature: String
    public var affectedDocumentation: [ProjectDocumentation] = []
    public var affectedDecisions: [ProjectDecision] = []
    public var blockedReason: String?
    public var id: String { source.id + destination.id }
}

public enum ProjectTaskFilter: String, CaseIterable, Sendable {
    case all = "All", needsReview = "Needs review", questions = "Open questions", ready = "Ready for handoff"
    public func includes(_ task: ProjectTaskItem) -> Bool {
        switch self {
        case .all: true
        case .needsReview: !task.reviewed || task.isStale
        case .questions: task.openQuestions > 0
        case .ready: task.canImplement
        }
    }
}
