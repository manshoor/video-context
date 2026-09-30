import Foundation

public enum TaskEvidenceReviewStatus: String, Codable, Sendable {
    case awaitingReview
    case passed
    case findings
    case failed
}

public enum TaskAnalysisSourceKind: String, Codable, Sendable {
    case reviewedDocumentation
    case importedDocument
    case recording
    case confirmedDecision
}

public struct TaskAnalysisSourceManifestEntry: Codable, Equatable, Sendable, Identifiable {
    public let kind: TaskAnalysisSourceKind
    public let sourceID: String
    public let revision: String
    public var id: String { "\(kind.rawValue):\(sourceID):\(revision)" }

    public init(kind: TaskAnalysisSourceKind, sourceID: String, revision: String) {
        self.kind = kind
        self.sourceID = sourceID
        self.revision = revision
    }
}

public enum TaskEvidenceReviewFindingKind: String, Codable, CaseIterable, Sendable {
    case omission
    case unsupportedClaim
    case contradiction
    case duplicate
    case missingAcceptanceCheck
    case invalidCitation
}

public struct TaskEvidenceReviewFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: TaskEvidenceReviewFindingKind
    public let message: String
    public let blocking: Bool
    public let evidence: [ProjectEvidenceReference]
    public let conflictingEvidence: [ProjectEvidenceReference]

    public init(
        id: String = "review_finding_\(UUID().uuidString.lowercased())",
        kind: TaskEvidenceReviewFindingKind,
        message: String,
        blocking: Bool,
        evidence: [ProjectEvidenceReference] = [],
        conflictingEvidence: [ProjectEvidenceReference] = []
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.blocking = blocking
        self.evidence = evidence
        self.conflictingEvidence = conflictingEvidence
    }
}

public enum TaskVisualEvidenceAssessment: String, Codable, Sendable {
    case consistent
    case discrepancy
    case unreadable
}

public struct TaskVisualEvidenceObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let evidence: ProjectEvidenceReference
    public let visualInterpretation: String
    public let extractedOCR: String
    public let assessment: TaskVisualEvidenceAssessment

    public init(
        id: String = "visual_observation_\(UUID().uuidString.lowercased())",
        evidence: ProjectEvidenceReference,
        visualInterpretation: String,
        extractedOCR: String,
        assessment: TaskVisualEvidenceAssessment
    ) {
        self.id = id
        self.evidence = evidence
        self.visualInterpretation = visualInterpretation
        self.extractedOCR = extractedOCR
        self.assessment = assessment
    }
}

public struct TaskEvidenceReview: Codable, Equatable, Sendable {
    public var status: TaskEvidenceReviewStatus
    public var findings: [TaskEvidenceReviewFinding]
    public var reviewer: ProviderIdentity?
    public var sourceFingerprint: String
    public var promptVersion: String
    public var errorMessage: String?
    public var reviewedAt: Date?

    public init(
        status: TaskEvidenceReviewStatus,
        findings: [TaskEvidenceReviewFinding] = [],
        reviewer: ProviderIdentity? = nil,
        sourceFingerprint: String,
        promptVersion: String,
        errorMessage: String? = nil,
        reviewedAt: Date? = nil
    ) {
        self.status = status
        self.findings = findings
        self.reviewer = reviewer
        self.sourceFingerprint = sourceFingerprint
        self.promptVersion = promptVersion
        self.errorMessage = errorMessage
        self.reviewedAt = reviewedAt
    }
}

public struct TaskEvidenceReviewBatch: Sendable {
    public let text: String
    public let images: [Data]
    public let evidence: [ProjectEvidenceReference]
    /// Apple Vision (or another deterministic extraction stage) OCR keyed by
    /// the exact image evidence reference. Reviewer output never overwrites it.
    public let authoritativeOCR: [String: String]

    public init(text: String, images: [Data] = [], evidence: [ProjectEvidenceReference] = [],
                authoritativeOCR: [String: String] = [:]) {
        self.text = text
        self.images = images
        self.evidence = evidence
        self.authoritativeOCR = authoritativeOCR
    }
}
