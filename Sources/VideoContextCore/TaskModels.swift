import Foundation

public enum TaskOrigin: String, Codable, CaseIterable, Sendable {
    case recording, feedback, request, interpretation, user
    public var label: String {
        switch self { case .recording: "Recording statement"; case .feedback: "Feedback statement"; case .request: "Separate request"; case .interpretation: "AI interpretation/suggestion"; case .user: "User clarification" }
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

public enum TaskQuestionCategory: String, Codable, CaseIterable, Sendable { case productDecision, investigation, missingEvidence }

public struct TaskQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id = "question_\(UUID().uuidString.lowercased())"
    public var question: String
    public var answer = ""
    public var isBlocking = true
    public var nonBlockingReason = ""
    public var disagreement = ""
    public var sourceIDs: [String] = []
    public var category: TaskQuestionCategory?
    public var sharedDecisionID: String?
    public var sharedDecisionRevision: Int?
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
    /// Revision-aware citations frozen when analysis ran. `sourceIDs` remains
    /// the compatibility field for recording and feedback evidence IDs.
    public var evidenceReferences: [ProjectEvidenceReference]
    public var evidenceReview: TaskEvidenceReview?
    public var visualEvidenceObservations: [TaskVisualEvidenceObservation]
    public var analysisSourceManifest: [TaskAnalysisSourceManifestEntry]
    public var dependencyTaskIDs: [String]
    public var analysisSourceFingerprint: String?
    public init(title: String = "New task", behavior: String = "", requirements: [TaskStatement] = [], checks: [TaskStatement] = [], questions: [TaskQuestion] = [], sourceIDs: [String] = [], annotations: [TaskAnnotation] = [], evidenceReferences: [ProjectEvidenceReference] = [], evidenceReview: TaskEvidenceReview? = nil, visualEvidenceObservations: [TaskVisualEvidenceObservation] = [], analysisSourceManifest: [TaskAnalysisSourceManifestEntry] = [], dependencyTaskIDs: [String] = [], analysisSourceFingerprint: String? = nil) {
        self.title = title; self.behavior = behavior; self.requirements = requirements; self.checks = checks
        self.questions = questions; self.sourceIDs = sourceIDs; self.annotations = annotations
        self.evidenceReferences = evidenceReferences; self.evidenceReview = evidenceReview
        self.visualEvidenceObservations = visualEvidenceObservations
        self.analysisSourceManifest = analysisSourceManifest
        self.dependencyTaskIDs = dependencyTaskIDs; self.analysisSourceFingerprint = analysisSourceFingerprint
    }
    public var allSourceIDs: Set<String> { Set(sourceIDs + requirements.flatMap(\.sourceIDs) + checks.flatMap(\.sourceIDs) + questions.flatMap(\.sourceIDs) + annotations.map(\.evidenceID)) }
    public var blockers: Int { questions.filter(\.unresolved).count }

    private enum CodingKeys: String, CodingKey {
        case title, behavior, requirements, checks, questions, sourceIDs, annotations, evidenceReferences,
             evidenceReview, visualEvidenceObservations, analysisSourceManifest, dependencyTaskIDs, analysisSourceFingerprint
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        behavior = try c.decode(String.self, forKey: .behavior)
        requirements = try c.decode([TaskStatement].self, forKey: .requirements)
        checks = try c.decode([TaskStatement].self, forKey: .checks)
        questions = try c.decode([TaskQuestion].self, forKey: .questions)
        sourceIDs = try c.decode([String].self, forKey: .sourceIDs)
        annotations = try c.decodeIfPresent([TaskAnnotation].self, forKey: .annotations) ?? []
        evidenceReferences = try c.decodeIfPresent([ProjectEvidenceReference].self, forKey: .evidenceReferences) ?? []
        evidenceReview = try c.decodeIfPresent(TaskEvidenceReview.self, forKey: .evidenceReview)
        visualEvidenceObservations = try c.decodeIfPresent([TaskVisualEvidenceObservation].self, forKey: .visualEvidenceObservations) ?? []
        analysisSourceManifest = try c.decodeIfPresent([TaskAnalysisSourceManifestEntry].self, forKey: .analysisSourceManifest) ?? []
        dependencyTaskIDs = try c.decodeIfPresent([String].self, forKey: .dependencyTaskIDs) ?? []
        analysisSourceFingerprint = try c.decodeIfPresent(String.self, forKey: .analysisSourceFingerprint)
    }
}

public struct VideoTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoID: String
    public var revision: Int
    public var sourceRevision: ArtifactRevision
    public var content: TaskContent
    public var generationRunID: String?
    public var generatedOriginal: TaskContent?
    public var reviewedRevision: Int?
    public var wasReviewed: Bool
    public var archived: Bool
    public var order: Int
    public var provenance: ProviderIdentity?
    /// Transient source-freshness result populated by store reads. Nil keeps
    /// older serialized tasks compatible.
    public var analysisIsStale: Bool?
    public init(id: String = "task_\(UUID().uuidString.lowercased())", videoID: String, sourceRevision: ArtifactRevision, content: TaskContent, order: Int = 0, provenance: ProviderIdentity? = nil) {
        self.id = id; self.videoID = videoID; self.sourceRevision = sourceRevision; self.content = content
        self.order = order; self.provenance = provenance; revision = 1; reviewedRevision = nil; archived = false; wasReviewed = false
        analysisIsStale = nil
        generatedOriginal = provenance == nil ? nil : content
    }
    public func isStale(_ video: VideoRecord) -> Bool { sourceRevision != video.revisions || video.revisions.isBriefStale || analysisIsStale == true }
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
    public var generationRunID: String?
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
