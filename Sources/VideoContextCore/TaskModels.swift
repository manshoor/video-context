import Foundation

public enum TaskOrigin: String, Codable, CaseIterable, Sendable {
    case recording, interpretation, user
    public var label: String {
        switch self { case .recording: "Recording statement"; case .interpretation: "AI interpretation/suggestion"; case .user: "User clarification" }
    }
}

public struct TaskStatement: Codable, Equatable, Sendable, Identifiable {
    public var id = "item_\(UUID().uuidString.lowercased())"
    public var text: String
    public var origin: TaskOrigin
    public var sourceIDs: [String]
    public init(text: String, origin: TaskOrigin = .user, sourceIDs: [String] = []) {
        self.text = text; self.origin = origin; self.sourceIDs = sourceIDs
    }
}

public struct TaskQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id = "question_\(UUID().uuidString.lowercased())"
    public var question: String
    public var answer = ""
    public var isBlocking = true
    public var nonBlockingReason = ""
    public var disagreement = ""
    public var sourceIDs: [String] = []
    public var unresolved: Bool { answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isBlocking || nonBlockingReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    public init(question: String, sourceIDs: [String] = []) { self.question = question; self.sourceIDs = sourceIDs }
}

public enum TaskAnnotationKind: String, Codable, CaseIterable, Sendable { case rectangle, arrow, note }
public struct TaskAnnotation: Codable, Equatable, Sendable, Identifiable {
    public var id = "annotation_\(UUID().uuidString.lowercased())"
    public var evidenceID: String
    public var kind: TaskAnnotationKind
    public var x: Double = 0.15
    public var y: Double = 0.15
    public var width: Double = 0.35
    public var height: Double = 0.2
    public var text = ""
    public var flipHorizontal: Bool?
    public var flipVertical: Bool?
    public init(evidenceID: String, kind: TaskAnnotationKind) { self.evidenceID = evidenceID; self.kind = kind }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct TaskContent: Codable, Equatable, Sendable {
    public var title: String
    public var behavior: String
    public var requirements: [TaskStatement]
    public var checks: [TaskStatement]
    public var questions: [TaskQuestion]
    public var sourceIDs: [String]
    public var annotations: [TaskAnnotation]
    public init(title: String = "New task", behavior: String = "", requirements: [TaskStatement] = [], checks: [TaskStatement] = [], questions: [TaskQuestion] = [], sourceIDs: [String] = [], annotations: [TaskAnnotation] = []) {
        self.title = title; self.behavior = behavior; self.requirements = requirements; self.checks = checks
        self.questions = questions; self.sourceIDs = sourceIDs; self.annotations = annotations
    }
    public var allSourceIDs: Set<String> { Set(sourceIDs + requirements.flatMap(\.sourceIDs) + checks.flatMap(\.sourceIDs) + questions.flatMap(\.sourceIDs) + annotations.map(\.evidenceID)) }
    public var blockers: Int { questions.filter(\.unresolved).count }
}

public struct VideoTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoID: String
    public var revision: Int
    public var sourceRevision: ArtifactRevision
    public var content: TaskContent
    public var generatedOriginal: TaskContent?
    public var reviewedRevision: Int?
    public var wasReviewed: Bool
    public var archived: Bool
    public var order: Int
    public var provenance: ProviderIdentity?
    public init(id: String = "task_\(UUID().uuidString.lowercased())", videoID: String, sourceRevision: ArtifactRevision, content: TaskContent, order: Int = 0, provenance: ProviderIdentity? = nil) {
        self.id = id; self.videoID = videoID; self.sourceRevision = sourceRevision; self.content = content
        self.order = order; self.provenance = provenance; revision = 1; reviewedRevision = nil; archived = false; wasReviewed = false
        generatedOriginal = provenance == nil ? nil : content
    }
    public func isStale(_ video: VideoRecord) -> Bool { sourceRevision != video.revisions || video.revisions.isBriefStale }
    public func state(_ video: VideoRecord) -> String {
        if archived { return "Archived" }
        if isStale(video) { return "Needs review" }
        if reviewedRevision == revision { return "Reviewed" }
        return wasReviewed ? "Needs review" : "Draft"
    }
    public func canImplement(_ video: VideoRecord) -> Bool {
        !archived && !isStale(video) && video.status == .ready && reviewedRevision == revision && content.blockers == 0
    }
}

public struct TaskLibrarySnapshot: Codable, Sendable {
    public let video: VideoRecord
    public let tasks: [VideoTask]
    public let transcript: [TranscriptSegment]
    public let evidence: [EvidenceItem]
    public let proposals: [TaskProposal]
    public var signature: String { "\(video.revisions.transcript):\(video.revisions.evidence):\(video.revisions.brief):" + tasks.map { "\($0.id):\($0.revision):\($0.order)" }.joined(separator: ",") }
}

public enum TaskProposalKind: String, Codable, Sendable { case addition, modification, archive }
public struct TaskProposal: Codable, Equatable, Sendable, Identifiable {
    public var id = "proposal_\(UUID().uuidString.lowercased())"
    public let videoID: String
    public let kind: TaskProposalKind
    public let taskID: String?
    public let expectedTaskRevision: Int?
    public let sourceRevision: ArtifactRevision
    public let content: TaskContent?
    public let provenance: ProviderIdentity
    public init(videoID: String, kind: TaskProposalKind, taskID: String? = nil, expectedTaskRevision: Int? = nil, sourceRevision: ArtifactRevision, content: TaskContent? = nil, provenance: ProviderIdentity) {
        self.videoID = videoID; self.kind = kind; self.taskID = taskID; self.expectedTaskRevision = expectedTaskRevision
        self.sourceRevision = sourceRevision; self.content = content; self.provenance = provenance
    }
}

public enum TaskContextError: Error, LocalizedError, Equatable {
    case invalid(String), conflict, missing(String), reviewRequired
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): text
        case .conflict: "The task or its evidence changed. Refresh and request an updated handoff; saved edits were preserved."
        case .missing(let id): "Task context unavailable for exact ID \(id). No substitute was selected."
        case .reviewRequired: "Review current tasks and resolve blocking questions before an Implement handoff."
        }
    }
}
