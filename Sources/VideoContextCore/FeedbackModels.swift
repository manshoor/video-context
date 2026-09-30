import Foundation

public enum FeedbackReviewer: String, Codable, CaseIterable, Sendable { case unspecified, qa, manager }
public enum FeedbackIssueKind: String, Codable, CaseIterable, Sendable { case feedback, request }
public enum FeedbackSourceKind: String, Codable, Sendable { case comment, link, image, video, recording, jam, document }
public enum FeedbackSourceStatus: String, Codable, Sendable { case pending, ready, failed }

public struct FeedbackProject: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public init(id: String = "fproj_\(UUID().uuidString.lowercased())", name: String) {
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FeedbackPreparationSuggestion: Codable, Equatable, Sendable, Identifiable {
    public let issueID: String
    public let joinWithPrevious: Bool
    public let sharedInstruction: Bool
    public let sourceIDs: [String]
    public let duplicateOfIssueID: String
    public var id: String { issueID }
}

public struct FeedbackSource: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var url: String?
    public var kind: FeedbackSourceKind
    public var status: FeedbackSourceStatus
    public var localPath: String?
    public var recordingID: String?
    public var resolvedURL: String?
    public var filename: String?
    public var ocrText: String
    public var error: String?
    public var jam: JamEvidenceReference?
    public var documentID: String?
    public var documentRevision: Int?
    public var documentSectionIDs: [String]?
    public var presentationStatus: String {
        guard kind == .jam, let jam else { return status.rawValue.capitalized }
        guard jam.state == .ready else { return "Unread" }
        let complete = JamEvidenceComponent.allCases.allSatisfy { component in
            jam.availability.first(where: { $0.component == component })?.status == .available
        }
        return complete ? "Imported" : "Partially imported"
    }
    public init(id: String = "fsrc_\(UUID().uuidString.lowercased())", url: String? = nil, kind: FeedbackSourceKind = .link,
                status: FeedbackSourceStatus = .pending, localPath: String? = nil, recordingID: String? = nil,
                filename: String? = nil, ocrText: String = "", error: String? = nil, jam: JamEvidenceReference? = nil) {
        self.id = id; self.url = url; self.kind = kind; self.status = status
        self.localPath = localPath; self.recordingID = recordingID; self.ocrText = ocrText; self.error = error
        self.resolvedURL = nil; self.filename = filename
        self.jam = jam
    }
}

public struct FeedbackComment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var text: String
    public var reviewer: FeedbackReviewer
    public var sourceIDs: [String]
    public var isShared: Bool
    public var kind: FeedbackIssueKind
    public var lineNumbers: [Int]
    public var sharedTargetIDs: [String]
    public init(id: String = "fcom_\(UUID().uuidString.lowercased())", text: String, reviewer: FeedbackReviewer = .unspecified,
                sourceIDs: [String] = [], isShared: Bool = false, kind: FeedbackIssueKind = .feedback,
                lineNumbers: [Int] = [], sharedTargetIDs: [String] = []) {
        self.id = id; self.text = text; self.reviewer = reviewer; self.sourceIDs = sourceIDs; self.isShared = isShared
        self.kind = kind; self.lineNumbers = lineNumbers; self.sharedTargetIDs = sharedTargetIDs
    }
    private enum CodingKeys: String, CodingKey { case id, text, reviewer, sourceIDs, isShared, kind, lineNumbers, sharedTargetIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        reviewer = try c.decode(FeedbackReviewer.self, forKey: .reviewer)
        sourceIDs = try c.decode([String].self, forKey: .sourceIDs)
        isShared = try c.decode(Bool.self, forKey: .isShared)
        kind = try c.decodeIfPresent(FeedbackIssueKind.self, forKey: .kind) ?? .feedback
        lineNumbers = try c.decodeIfPresent([Int].self, forKey: .lineNumbers) ?? []
        sharedTargetIDs = try c.decodeIfPresent([String].self, forKey: .sharedTargetIDs) ?? []
    }
}

public struct FeedbackBatch: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    // Optional only so batches saved by older app versions can be attached to a recording.
    public var videoID: String?
    public var projectID: String?
    public var title: String
    public var project: String
    public var rawText: String
    public var revision: Int
    public var comments: [FeedbackComment]
    public var sources: [FeedbackSource]
    public var batchWideSourceIDs: [String] = []
    public var preparationSuggestions: [FeedbackPreparationSuggestion] = []
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = "fb_\(UUID().uuidString.lowercased())", videoID: String? = nil, projectID: String? = nil,
                title: String, project: String = "", rawText: String) {
        self.id = id; self.videoID = videoID; self.projectID = projectID; self.title = title; self.project = project; self.rawText = rawText
        revision = 1; createdAt = .now; updatedAt = .now
        let parsed = Self.parse(rawText)
        comments = parsed.0; sources = parsed.1
    }

    private enum CodingKeys: String, CodingKey {
        case id, videoID, projectID, title, project, rawText, revision, comments, sources, batchWideSourceIDs,
             preparationSuggestions, createdAt, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        videoID = try c.decodeIfPresent(String.self, forKey: .videoID)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        title = try c.decode(String.self, forKey: .title)
        project = try c.decode(String.self, forKey: .project)
        rawText = try c.decode(String.self, forKey: .rawText)
        revision = try c.decode(Int.self, forKey: .revision)
        comments = try c.decode([FeedbackComment].self, forKey: .comments)
        sources = try c.decode([FeedbackSource].self, forKey: .sources)
        batchWideSourceIDs = try c.decodeIfPresent([String].self, forKey: .batchWideSourceIDs) ?? []
        preparationSuggestions = try c.decodeIfPresent([FeedbackPreparationSuggestion].self, forKey: .preparationSuggestions) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public static func parse(_ raw: String) -> ([FeedbackComment], [FeedbackSource]) {
        let expression = try! NSRegularExpression(pattern: #"https?://[^\s<>)\]]+"#, options: [.caseInsensitive])
        var sources: [FeedbackSource] = [], comments: [FeedbackComment] = []
        for (offset, line) in raw.components(separatedBy: .newlines).enumerated() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let ns = text as NSString
            let links = expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            }
            var ids: [String] = []
            for link in links {
                if let source = sources.first(where: { $0.url == link }) { ids.append(source.id) }
                else {
                    let kind: FeedbackSourceKind = URL(string: link).flatMap(JamLink.init(url:)) == nil ? .link : .jam
                    let source = FeedbackSource(url: link, kind: kind)
                    ids.append(source.id); sources.append(source)
                }
            }
            let remaining = text.replacingOccurrences(of: #"\[[^\]]*\]\(https?://[^)]+\)|https?://[^\s<>)\]]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if remaining.isEmpty, !ids.isEmpty, !comments.isEmpty {
                comments[comments.count - 1].sourceIDs = Array(Set(comments[comments.count - 1].sourceIDs + ids)).sorted()
                comments[comments.count - 1].lineNumbers.append(offset + 1)
            } else {
                comments.append(.init(text: text, sourceIDs: Array(Set(ids)).sorted(), lineNumbers: [offset + 1]))
            }
        }
        return (comments, sources)
    }

    public mutating func addUnassignedLocalSources(named filenames: [String]) -> [FeedbackSource] {
        let added = filenames.map { FeedbackSource(kind: $0.lowercased().hasSuffix(".mp4") ? .video : .image, filename: $0) }
        sources.append(contentsOf: added)
        return added
    }

    public var unassignedSourceIDs: [String] {
        let assigned = Set(comments.flatMap(\.sourceIDs) + batchWideSourceIDs)
        return sources.map(\.id).filter { !assigned.contains($0) }
    }

    @discardableResult public mutating func addLocalSources(named filenames: [String], to commentID: String? = nil) -> [FeedbackSource] {
        let indices = comments.indices.filter { commentID == nil || comments[$0].id == commentID }
        guard !indices.isEmpty else { return [] }
        let added = filenames.map { name in
            FeedbackSource(kind: name.lowercased().hasSuffix(".mp4") ? .video : .image, filename: name)
        }
        sources.append(contentsOf: added)
        for index in indices { comments[index].sourceIDs.append(contentsOf: added.map(\.id)) }
        return added
    }
}

public struct FeedbackTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let batchID: String
    public var issueID: String?
    public var revision: Int
    public var sourceRevision: Int
    public var content: TaskContent
    public var generationRunID: String?
    public var generatedOriginal: TaskContent?
    public var approvedRevision: Int?
    public var archived: Bool
    public var provenance: ProviderIdentity?
    /// Transient source-freshness result populated by store reads.
    public var analysisIsStale: Bool?
    public var isApproved: Bool { !archived && approvedRevision == revision }
    public func canImplement(in batch: FeedbackBatch) -> Bool {
        isApproved && sourceRevision == batch.revision && analysisIsStale != true &&
            content.blockers == 0 && !content.checks.isEmpty &&
            !(content.evidenceReview.map { [.awaitingReview, .failed].contains($0.status) } ?? false)
    }
    public init(id: String = "ftask_\(UUID().uuidString.lowercased())", batchID: String, issueID: String? = nil,
                sourceRevision: Int, content: TaskContent, provenance: ProviderIdentity? = nil) {
        self.id = id; self.batchID = batchID; self.sourceRevision = sourceRevision; self.content = content
        self.issueID = issueID
        self.provenance = provenance; revision = 1; approvedRevision = nil; archived = false
        analysisIsStale = nil
        generatedOriginal = provenance == nil ? nil : content
    }
}

public struct FeedbackTaskProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let batchID: String
    public let taskID: String
    public let expectedRevision: Int
    public let sourceRevision: Int
    public let content: TaskContent
    public let preserveGeneratedOriginal: Bool?
    public init(id: String = "fproposal_\(UUID().uuidString.lowercased())", batchID: String, taskID: String,
                expectedRevision: Int, sourceRevision: Int, content: TaskContent,
                preserveGeneratedOriginal: Bool? = nil) {
        self.id = id; self.batchID = batchID; self.taskID = taskID; self.expectedRevision = expectedRevision
        self.sourceRevision = sourceRevision; self.content = content
        self.preserveGeneratedOriginal = preserveGeneratedOriginal
    }
}

public struct FeedbackSnapshot: Sendable {
    public var batch: FeedbackBatch
    public var tasks: [FeedbackTask]
    public var proposals: [FeedbackTaskProposal]
}
