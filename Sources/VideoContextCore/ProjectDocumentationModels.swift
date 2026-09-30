import Foundation

// MARK: - Imported project sources

public enum ProjectDocumentSourceKind: String, Codable, CaseIterable, Sendable {
    case markdown
    case pdf
    case image
}

public enum ProjectDocumentSourceStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case ready
    case partial
    case failed
}

public enum ProjectDocumentImportJobStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

public struct ProjectDocumentImportJob: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let projectID: String
    public let sourceKey: String
    public let sourcePath: String
    /// Durable intake copy used after the source URL is no longer available.
    public var intakeRelativePath: String?
    /// Selected Markdown attachments copied into the same intake tree.
    public var attachmentRelativePaths: [String]
    /// A PDF checkpoint containing completed pages and their extracted data.
    public var checkpointRelativePath: String?
    public var contentHash: String?
    public var sourceID: String?
    public var status: ProjectDocumentImportJobStatus
    public var error: String?
    public var updatedAt: Date

    public init(id: String = "dimport_\(UUID().uuidString.lowercased())", projectID: String, sourceKey: String, sourcePath: String, intakeRelativePath: String? = nil, attachmentRelativePaths: [String] = [], checkpointRelativePath: String? = nil, contentHash: String? = nil, sourceID: String? = nil, status: ProjectDocumentImportJobStatus = .pending, error: String? = nil, updatedAt: Date = .now) {
        self.id = id; self.projectID = projectID; self.sourceKey = sourceKey; self.sourcePath = sourcePath; self.intakeRelativePath = intakeRelativePath; self.attachmentRelativePaths = attachmentRelativePaths; self.checkpointRelativePath = checkpointRelativePath; self.contentHash = contentHash; self.sourceID = sourceID; self.status = status; self.error = error; self.updatedAt = updatedAt
    }
}

public enum ProjectDocumentUnitKind: String, Codable, CaseIterable, Sendable {
    case page
    case heading
    case paragraph
    case list
    case table
    case code
    case image
}

public enum ProjectDocumentAssetStatus: String, Codable, CaseIterable, Sendable {
    case copied
    case external
    case missing
    case failed
}

public struct ProjectDocumentLocator: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pdfPage
        case markdownLine
        case heading
        case asset
        case unit
    }

    public let kind: Kind
    public let page: Int?
    public let startLine: Int?
    public let endLine: Int?
    public let value: String?

    public init(pdfPage: Int) {
        kind = .pdfPage; page = pdfPage; startLine = nil; endLine = nil; value = nil
    }

    public init(markdownLine startLine: Int, endLine: Int? = nil) {
        kind = .markdownLine; page = nil; self.startLine = startLine; self.endLine = endLine ?? startLine; value = nil
    }

    public init(heading: String) {
        kind = .heading; page = nil; startLine = nil; endLine = nil; value = heading
    }

    public init(asset: String) {
        kind = .asset; page = nil; startLine = nil; endLine = nil; value = asset
    }

    public init(unit: String) {
        kind = .unit; page = nil; startLine = nil; endLine = nil; value = unit
    }

    public var displayValue: String {
        switch kind {
        case .pdfPage: "page \(page ?? 0)"
        case .markdownLine: "lines \(startLine ?? 0)-\(endLine ?? startLine ?? 0)"
        case .heading: value ?? "heading"
        case .asset: value ?? "asset"
        case .unit: value ?? "unit"
        }
    }

    /// Stable locator components for evidence IDs and export manifests. Keep
    /// this independent of Swift's synthesized `String(describing:)` output.
    public var stableKey: String {
        [kind.rawValue, String(page ?? 0), String(startLine ?? 0), String(endLine ?? 0), value ?? ""].joined(separator: "|")
    }
}

public struct ProjectDocumentExtractionUnit: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let ordinal: Int
    public let kind: ProjectDocumentUnitKind
    public let locator: ProjectDocumentLocator
    public let title: String?
    public let text: String

    public init(
        id: String = "unit_\(UUID().uuidString.lowercased())",
        ordinal: Int,
        kind: ProjectDocumentUnitKind,
        locator: ProjectDocumentLocator,
        title: String? = nil,
        text: String
    ) {
        self.id = id; self.ordinal = ordinal; self.kind = kind; self.locator = locator; self.title = title; self.text = text
    }
}

public struct ProjectDocumentAsset: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sourcePath: String
    public var relativePath: String?
    public let contentHash: String?
    public var status: ProjectDocumentAssetStatus
    public var error: String?

    public init(
        id: String = "asset_\(UUID().uuidString.lowercased())",
        sourcePath: String,
        relativePath: String? = nil,
        contentHash: String? = nil,
        status: ProjectDocumentAssetStatus = .missing,
        error: String? = nil
    ) {
        self.id = id; self.sourcePath = sourcePath; self.relativePath = relativePath; self.contentHash = contentHash
        self.status = status; self.error = error
    }
}

public struct ProjectDocumentImportError: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let locator: ProjectDocumentLocator?
    public let message: String
    public let isFatal: Bool

    public init(id: String = "error_\(UUID().uuidString.lowercased())", locator: ProjectDocumentLocator? = nil, message: String, isFatal: Bool = false) {
        self.id = id; self.locator = locator; self.message = message; self.isFatal = isFatal
    }
}

public struct ProjectDocumentSource: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let projectID: String
    public let name: String
    /// The canonical path or import key used to detect a changed copy of the same file.
    public let sourceKey: String
    public let kind: ProjectDocumentSourceKind
    public let currentRevision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = "pdocsrc_\(UUID().uuidString.lowercased())",
        projectID: String,
        name: String,
        sourceKey: String,
        kind: ProjectDocumentSourceKind,
        currentRevision: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id; self.projectID = projectID; self.name = name; self.sourceKey = sourceKey; self.kind = kind
        self.currentRevision = currentRevision; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ProjectDocumentSourceRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let projectID: String
    public let revision: Int
    public let contentHash: String
    public let extractionVersion: String
    public let originalRelativePath: String
    public let status: ProjectDocumentSourceStatus
    public let units: [ProjectDocumentExtractionUnit]
    public let assets: [ProjectDocumentAsset]
    public let errors: [ProjectDocumentImportError]
    public let createdAt: Date

    public init(
        id: String? = nil,
        sourceID: String,
        projectID: String,
        revision: Int,
        contentHash: String,
        extractionVersion: String = "1",
        originalRelativePath: String,
        status: ProjectDocumentSourceStatus,
        units: [ProjectDocumentExtractionUnit],
        assets: [ProjectDocumentAsset] = [],
        errors: [ProjectDocumentImportError] = [],
        createdAt: Date = .now
    ) {
        self.id = id ?? "\(sourceID):r\(revision)"; self.sourceID = sourceID; self.projectID = projectID; self.revision = revision
        self.contentHash = contentHash; self.extractionVersion = extractionVersion; self.originalRelativePath = originalRelativePath
        self.status = status; self.units = units; self.assets = assets; self.errors = errors; self.createdAt = createdAt
    }

    public var isUsable: Bool { status == .ready || status == .partial }
}

public struct ProjectDocumentImportResult: Codable, Equatable, Sendable {
    public let source: ProjectDocumentSource
    public let revision: ProjectDocumentSourceRevision
    public let reusedExistingRevision: Bool

    public init(source: ProjectDocumentSource, revision: ProjectDocumentSourceRevision, reusedExistingRevision: Bool) {
        self.source = source; self.revision = revision; self.reusedExistingRevision = reusedExistingRevision
    }
}

// MARK: - Evidence and reviewed documentation

public enum ProjectDocumentationClassification: String, Codable, CaseIterable, Sendable {
    case observed
    case requested
    case confirmedDecision
    case interpretation
    case unresolved
}

public enum ProjectEvidenceReference: Codable, Hashable, Sendable, Identifiable {
    case recording(videoID: String, sourceRevision: ArtifactRevision, timestamp: TimeInterval, evidenceID: String?)
    case feedback(batchID: String, sourceRevision: Int, commentID: String?, sourceID: String?)
    case document(sourceID: String, revision: Int, locator: ProjectDocumentLocator)
    /// A section (or the complete body when `sectionID` is nil) from one
    /// frozen, reviewed project-documentation revision.
    case reviewedDocumentation(documentID: String, revision: Int, sectionID: String?)

    public var id: String {
        switch self {
        case .recording(let videoID, let revision, let timestamp, let evidenceID):
            return "recording:\(videoID):\(revision.transcript):\(revision.evidence):\(revision.brief):\(timestamp):\(evidenceID ?? "")"
        case .feedback(let batchID, let revision, let commentID, let sourceID):
            return "feedback:\(batchID):\(revision):\(commentID ?? ""):\(sourceID ?? "")"
        case .document(let sourceID, let revision, let locator):
            return "document:\(sourceID):\(revision):\(locator.stableKey)"
        case .reviewedDocumentation(let documentID, let revision, let sectionID):
            return "reviewed-documentation:\(documentID):\(revision):\(sectionID ?? "")"
        }
    }

    public var sourceID: String {
        switch self {
        case .recording(let id, _, _, _): "recording:\(id)"
        case .feedback(let id, _, _, _): "feedback:\(id)"
        case .document(let id, _, _): "document:\(id)"
        case .reviewedDocumentation(let id, _, _): "documentation:\(id)"
        }
    }
}

public enum ProjectEvidenceReferenceStatus: String, Codable, Sendable {
    case valid
    case stale
    case missing
}

public struct ProjectEvidenceValidation: Codable, Equatable, Sendable {
    public let reference: ProjectEvidenceReference
    public let status: ProjectEvidenceReferenceStatus
    public let message: String?

    public init(reference: ProjectEvidenceReference, status: ProjectEvidenceReferenceStatus, message: String? = nil) {
        self.reference = reference; self.status = status; self.message = message
    }
}

public struct ProjectDocumentationSection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var order: Int
    public var title: String
    public var body: String
    public var classification: ProjectDocumentationClassification
    public var evidence: [ProjectEvidenceReference]
    public var decisionIDs: [String]

    public init(
        id: String = "section_\(UUID().uuidString.lowercased())",
        order: Int = 0,
        title: String,
        body: String,
        classification: ProjectDocumentationClassification = .interpretation,
        evidence: [ProjectEvidenceReference] = [],
        decisionIDs: [String] = []
    ) {
        self.id = id; self.order = order; self.title = title; self.body = body; self.classification = classification
        self.evidence = evidence; self.decisionIDs = decisionIDs
    }
}

public struct ProjectDocumentationRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let documentID: String
    public let projectID: String
    public let revision: Int
    public let title: String
    public let slug: String
    public let markdown: String
    public let sections: [ProjectDocumentationSection]
    public let sourceSignature: String
    public let isManualEdit: Bool
    public let createdAt: Date

    public init(
        id: String? = nil,
        documentID: String,
        projectID: String,
        revision: Int,
        title: String,
        slug: String,
        markdown: String,
        sections: [ProjectDocumentationSection],
        sourceSignature: String = "",
        isManualEdit: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id ?? "\(documentID):r\(revision)"; self.documentID = documentID; self.projectID = projectID; self.revision = revision
        self.title = title; self.slug = slug; self.markdown = markdown; self.sections = sections; self.sourceSignature = sourceSignature
        self.isManualEdit = isManualEdit; self.createdAt = createdAt
    }
}

public struct ProjectDocumentation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let projectID: String
    public var title: String
    public var slug: String
    public var currentRevision: Int
    public var reviewedRevision: Int?
    public var markdown: String
    public var sections: [ProjectDocumentationSection]
    public var sourceSignature: String
    public var updatedAt: Date

    public init(
        id: String = "pdoc_\(UUID().uuidString.lowercased())",
        projectID: String,
        title: String,
        slug: String,
        currentRevision: Int = 0,
        reviewedRevision: Int? = nil,
        markdown: String = "",
        sections: [ProjectDocumentationSection] = [],
        sourceSignature: String = "",
        updatedAt: Date = .now
    ) {
        self.id = id; self.projectID = projectID; self.title = title; self.slug = slug; self.currentRevision = currentRevision; self.reviewedRevision = reviewedRevision
        self.markdown = markdown; self.sections = sections; self.sourceSignature = sourceSignature; self.updatedAt = updatedAt
    }

    public var isReviewed: Bool { currentRevision > 0 && reviewedRevision == currentRevision }
}

public struct ProjectDocumentationDiff: Codable, Equatable, Sendable {
    public let addedSectionIDs: [String]
    public let changedSectionIDs: [String]
    public let removedSectionIDs: [String]

    public init(addedSectionIDs: [String] = [], changedSectionIDs: [String] = [], removedSectionIDs: [String] = []) {
        self.addedSectionIDs = addedSectionIDs; self.changedSectionIDs = changedSectionIDs; self.removedSectionIDs = removedSectionIDs
    }

    public var isEmpty: Bool { addedSectionIDs.isEmpty && changedSectionIDs.isEmpty && removedSectionIDs.isEmpty }
}

public enum ProjectDocumentationProposalState: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected
}

public struct ProjectDocumentationProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let projectID: String
    public let documentID: String
    public let expectedDocumentRevision: Int
    public let title: String
    public let slug: String
    public let markdown: String
    public let sections: [ProjectDocumentationSection]
    public let diff: ProjectDocumentationDiff
    public let sourceSignature: String
    public let evidence: [ProjectEvidenceReference]
    public var state: ProjectDocumentationProposalState
    public var isStale: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = "dproposal_\(UUID().uuidString.lowercased())",
        projectID: String,
        documentID: String,
        expectedDocumentRevision: Int,
        title: String,
        slug: String,
        markdown: String,
        sections: [ProjectDocumentationSection],
        diff: ProjectDocumentationDiff,
        sourceSignature: String = "",
        evidence: [ProjectEvidenceReference] = [],
        state: ProjectDocumentationProposalState = .pending,
        isStale: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id; self.projectID = projectID; self.documentID = documentID; self.expectedDocumentRevision = expectedDocumentRevision
        self.title = title; self.slug = slug; self.markdown = markdown; self.sections = sections; self.diff = diff
        self.sourceSignature = sourceSignature; self.evidence = evidence; self.state = state; self.isStale = isStale
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ProjectDocumentationSnapshot: Codable, Equatable, Sendable {
    public let projectID: String
    public let documentation: [ProjectDocumentation]
    public let revisions: [ProjectDocumentationRevision]
    public let proposals: [ProjectDocumentationProposal]
    public let decisions: [ProjectDecision]
    public let questionGroups: [ProjectQuestionGroupProposal]

    public init(
        projectID: String = "",
        documentation: [ProjectDocumentation] = [],
        revisions: [ProjectDocumentationRevision] = [],
        proposals: [ProjectDocumentationProposal] = [],
        decisions: [ProjectDecision] = [],
        questionGroups: [ProjectQuestionGroupProposal] = []
    ) {
        self.projectID = projectID; self.documentation = documentation; self.revisions = revisions; self.proposals = proposals; self.decisions = decisions; self.questionGroups = questionGroups
    }
}

/// A project-scoped read assembled from one database snapshot for MCP and the app.
public struct ProjectDocumentationReadSnapshot: Codable, Equatable, Sendable {
    public let projectID: String
    public let sources: [ProjectDocumentSource]
    public let sourceRevisions: [ProjectDocumentSourceRevision]
    public let documentation: [ProjectDocumentation]
    public let revisions: [ProjectDocumentationRevision]
    public let proposals: [ProjectDocumentationProposal]
    public let decisions: [ProjectDecision]
    public let questionGroups: [ProjectQuestionGroupProposal]

    public init(
        projectID: String,
        sources: [ProjectDocumentSource] = [],
        sourceRevisions: [ProjectDocumentSourceRevision] = [],
        documentation: [ProjectDocumentation] = [],
        revisions: [ProjectDocumentationRevision] = [],
        proposals: [ProjectDocumentationProposal] = [],
        decisions: [ProjectDecision] = [],
        questionGroups: [ProjectQuestionGroupProposal] = []
    ) {
        self.projectID = projectID; self.sources = sources; self.sourceRevisions = sourceRevisions; self.documentation = documentation
        self.revisions = revisions; self.proposals = proposals; self.decisions = decisions; self.questionGroups = questionGroups
    }
}

// MARK: - Shared decisions and question reuse

public enum ProjectDecisionState: String, Codable, CaseIterable, Sendable {
    case confirmed
    case unresolved
    case superseded
}

public struct ProjectDecision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let projectID: String
    public var key: String
    public var question: String
    public var answer: String
    public var aliases: [String]
    public var evidence: [ProjectEvidenceReference]
    public var evidenceNeedsReview: Bool?
    public var state: ProjectDecisionState
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: String = "decision_\(UUID().uuidString.lowercased())",
        projectID: String,
        key: String,
        question: String,
        answer: String = "",
        aliases: [String] = [],
        evidence: [ProjectEvidenceReference] = [],
        state: ProjectDecisionState = .unresolved,
        revision: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id; self.projectID = projectID; self.key = key; self.question = question; self.answer = answer; self.aliases = aliases
        self.evidence = evidence; self.state = state; self.revision = revision; self.updatedAt = updatedAt
    }
}

public struct ProjectQuestionGroupProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let projectID: String
    public let normalizedQuestion: String
    public let questionIDs: [String]
    public let taskIDs: [ProjectTaskReference]
    public let suggestedDecisionID: String?
    public var expectedTaskRevisions: [String: Int]?
    public var state: ProjectDocumentationProposalState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = "qgroup_\(UUID().uuidString.lowercased())",
        projectID: String,
        normalizedQuestion: String,
        questionIDs: [String] = [],
        taskIDs: [ProjectTaskReference] = [],
        suggestedDecisionID: String? = nil,
        state: ProjectDocumentationProposalState = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id; self.projectID = projectID; self.normalizedQuestion = normalizedQuestion; self.questionIDs = questionIDs; self.taskIDs = taskIDs
        self.suggestedDecisionID = suggestedDecisionID; self.state = state; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

// MARK: - Generation contracts

public struct ProjectDocumentationGenerationSource: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: String
    public let revision: String
    public let text: String
    public let evidence: [ProjectEvidenceReference]
    public let imageRelativePaths: [String]
    /// Evidence references for each visual attachment.  This is optional so
    /// callers that construct legacy generation inputs remain compatible; the
    /// generator labels attachments without an explicit mapping as unmapped.
    public let imageEvidence: [String: [ProjectEvidenceReference]]?

    public init(id: String, title: String, kind: String, revision: String, text: String, evidence: [ProjectEvidenceReference] = [], imageRelativePaths: [String] = [], imageEvidence: [String: [ProjectEvidenceReference]]? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.revision = revision; self.text = text; self.evidence = evidence; self.imageRelativePaths = imageRelativePaths; self.imageEvidence = imageEvidence
    }
}

public struct ProjectDocumentationGenerationInput: Codable, Equatable, Sendable {
    public let projectID: String
    public let projectName: String
    public let requestedTitle: String
    public let sources: [ProjectDocumentationGenerationSource]
    public let textBudget: Int
    public var targetDocumentID: String?

    public init(projectID: String, projectName: String, requestedTitle: String, sources: [ProjectDocumentationGenerationSource], textBudget: Int = 48_000, targetDocumentID: String? = nil) {
        self.projectID = projectID; self.projectName = projectName; self.requestedTitle = requestedTitle; self.sources = sources; self.textBudget = max(4_096, textBudget)
        self.targetDocumentID = targetDocumentID
    }
}

public struct ProjectDocumentationGenerationResult: Codable, Equatable, Sendable {
    public let title: String
    public let sections: [ProjectDocumentationSection]
    public let sourceIDsCovered: [String]
    public let sourceIDsOmitted: [String]
    public let unresolvedQuestions: [String]
    public let sourceSignature: String

    public init(title: String, sections: [ProjectDocumentationSection], sourceIDsCovered: [String], sourceIDsOmitted: [String] = [], unresolvedQuestions: [String] = [], sourceSignature: String = "") {
        self.title = title; self.sections = sections; self.sourceIDsCovered = sourceIDsCovered; self.sourceIDsOmitted = sourceIDsOmitted
        self.unresolvedQuestions = unresolvedQuestions; self.sourceSignature = sourceSignature
    }
}
