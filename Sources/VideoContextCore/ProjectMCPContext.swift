import Foundation
import CryptoKit
import GRDB

/// The item kinds returned by the project-scoped MCP reads. The values are
/// intentionally stable because editors can use them when deciding whether a
/// hit is a task, evidence, or product reference.
public enum MCPProjectItemKind: String, Codable, CaseIterable, Sendable {
    case recording
    case feedback
    case request
    case task
    case documentSource
    case document
    case decision
}

public enum MCPProjectFreshness: String, Codable, CaseIterable, Sendable {
    case current
    case stale
    case missing
    case unavailable
}

public struct MCPProjectSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isInbox: Bool
    public let recordingCount: Int
    public let feedbackBatchCount: Int
    public let taskCount: Int
    public let documentCount: Int
    public let revision: String

    public init(id: String, name: String, isInbox: Bool, recordingCount: Int,
                feedbackBatchCount: Int, taskCount: Int, documentCount: Int,
                revision: String) {
        self.id = id; self.name = name; self.isInbox = isInbox
        self.recordingCount = recordingCount; self.feedbackBatchCount = feedbackBatchCount
        self.taskCount = taskCount; self.documentCount = documentCount; self.revision = revision
    }
}

public struct MCPProjectList: Codable, Equatable, Sendable {
    public let projects: [MCPProjectSummary]
    public let nextCursor: String?

    public init(projects: [MCPProjectSummary], nextCursor: String?) {
        self.projects = projects; self.nextCursor = nextCursor
    }
}

public struct MCPProjectContextItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: MCPProjectItemKind
    public let title: String
    public let summary: String
    public let revision: String
    public let state: String?
    public let freshness: MCPProjectFreshness
    public let citations: [ProjectEvidenceReference]

    public init(id: String, kind: MCPProjectItemKind, title: String, summary: String,
                revision: String, state: String? = nil,
                freshness: MCPProjectFreshness = .current,
                citations: [ProjectEvidenceReference] = []) {
        self.id = id; self.kind = kind; self.title = title; self.summary = summary
        self.revision = revision; self.state = state; self.freshness = freshness; self.citations = citations
    }
}

public struct MCPProjectContextPage: Codable, Equatable, Sendable {
    public let projectID: String
    public let projectName: String
    public let isInbox: Bool
    public let revision: String
    public let items: [MCPProjectContextItem]
    public let conflicts: [String]
    public let nextCursor: String?

    public init(projectID: String, projectName: String, isInbox: Bool, revision: String,
                items: [MCPProjectContextItem], conflicts: [String], nextCursor: String?) {
        self.projectID = projectID; self.projectName = projectName; self.isInbox = isInbox
        self.revision = revision; self.items = items; self.conflicts = conflicts; self.nextCursor = nextCursor
    }
}

public struct MCPProjectSearchHit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: MCPProjectItemKind
    public let title: String
    public let excerpt: String
    public let revision: String
    public let freshness: MCPProjectFreshness
    public let citations: [ProjectEvidenceReference]

    public init(id: String, kind: MCPProjectItemKind, title: String, excerpt: String,
                revision: String, freshness: MCPProjectFreshness,
                citations: [ProjectEvidenceReference] = []) {
        self.id = id; self.kind = kind; self.title = title; self.excerpt = excerpt
        self.revision = revision; self.freshness = freshness; self.citations = citations
    }
}

public struct MCPProjectSearchPage: Codable, Equatable, Sendable {
    public let projectID: String
    public let revision: String
    public let query: String
    public let hits: [MCPProjectSearchHit]
    public let nextCursor: String?

    public init(projectID: String, revision: String, query: String,
                hits: [MCPProjectSearchHit], nextCursor: String?) {
        self.projectID = projectID; self.revision = revision; self.query = query
        self.hits = hits; self.nextCursor = nextCursor
    }
}

public struct MCPProjectDocumentPage: Codable, Equatable, Sendable {
    public let projectID: String
    public let documentID: String
    public let revision: Int
    public let title: String
    public let slug: String
    public let reviewedRevision: Int?
    public let markdown: String
    public let sections: [ProjectDocumentationSection]
    public let citations: [ProjectEvidenceReference]
    public let freshness: MCPProjectFreshness
    public let nextCursor: String?

    public init(projectID: String, documentID: String, revision: Int, title: String,
                slug: String, reviewedRevision: Int?, markdown: String,
                sections: [ProjectDocumentationSection], citations: [ProjectEvidenceReference],
                freshness: MCPProjectFreshness, nextCursor: String?) {
        self.projectID = projectID; self.documentID = documentID; self.revision = revision
        self.title = title; self.slug = slug; self.reviewedRevision = reviewedRevision
        self.markdown = markdown; self.sections = sections; self.citations = citations
        self.freshness = freshness; self.nextCursor = nextCursor
    }
}

public struct MCPProjectEvidenceResult: Codable, Equatable, Sendable {
    public let projectID: String
    public let reference: ProjectEvidenceReference
    public let freshness: MCPProjectFreshness
    public let title: String
    public let locator: String
    public let sourceRevision: String
    public let text: String
    public let imageData: Data?
    public let imageMimeType: String?
    public let error: String?

    public init(projectID: String, reference: ProjectEvidenceReference,
                freshness: MCPProjectFreshness, title: String, locator: String,
                sourceRevision: String, text: String, imageData: Data? = nil,
                imageMimeType: String? = nil, error: String? = nil) {
        self.projectID = projectID; self.reference = reference; self.freshness = freshness
        self.title = title; self.locator = locator; self.sourceRevision = sourceRevision
        self.text = text; self.imageData = imageData; self.imageMimeType = imageMimeType; self.error = error
    }
}

public struct MCPDocumentProposalSubmission: Codable, Equatable, Sendable {
    public let id: String
    public let requestID: String
    public let projectID: String
    public let documentID: String
    public let expectedRevision: Int
    public let acceptedForReview: Bool

    public init(id: String, requestID: String, projectID: String, documentID: String,
                expectedRevision: Int, acceptedForReview: Bool = true) {
        self.id = id; self.requestID = requestID; self.projectID = projectID
        self.documentID = documentID; self.expectedRevision = expectedRevision
        self.acceptedForReview = acceptedForReview
    }
}

/// Read-only project retrieval for MCP clients. The store remains opened
/// read-only by the MCP executable; the one opt-in write goes to the separate
/// local proposal inbox and is reviewed by the app before it can change a
/// document.
public struct ProjectMCPService: Sendable {
    public static let inboxID = "inbox"
    private let store: VideoContextStore

    public init(store: VideoContextStore) { self.store = store }

    public func listProjects(query: String? = nil, cursor: String? = nil, limit: Int = 20) async throws -> MCPProjectList {
        try await store.mcpProjectList(query: query, cursor: cursor, limit: limit)
    }

    public func context(projectID: String, cursor: String? = nil, limit: Int = 30) async throws -> MCPProjectContextPage {
        try await store.mcpProjectContext(projectID: projectID, cursor: cursor, limit: limit)
    }

    public func search(projectID: String, query: String, cursor: String? = nil, limit: Int = 20) async throws -> MCPProjectSearchPage {
        try await store.mcpProjectSearch(projectID: projectID, query: query, cursor: cursor, limit: limit)
    }

    public func document(projectID: String, documentID: String, expectedRevision: Int? = nil,
                         cursor: String? = nil, wordLimit: Int = 1_000) async throws -> MCPProjectDocumentPage {
        try await store.mcpProjectDocument(projectID: projectID, documentID: documentID,
                                           expectedRevision: expectedRevision, cursor: cursor,
                                           wordLimit: wordLimit)
    }

    public func evidence(projectID: String, reference: ProjectEvidenceReference,
                         paths: LibraryPaths) async throws -> MCPProjectEvidenceResult {
        try await store.mcpProjectEvidence(projectID: projectID, reference: reference, paths: paths)
    }

    public func submitDocumentProposal(_ proposal: ProjectDocumentationProposal,
                                       requestID: String, paths: LibraryPaths) async throws -> MCPDocumentProposalSubmission {
        let inbox = try DocumentProposalInbox(url: DocumentProposalInbox.url(in: paths))
        // The inbox is an editor boundary. Keep only the stable document
        // payload that the app imports and derive section IDs from section
        // content instead of carrying provider UUIDs and timestamps through
        // the idempotency check.
        let sections = proposal.sections.enumerated().map { index, section in
            let identity = ProposalSectionIdentity(index: index, order: section.order,
                                                    title: section.title, body: section.body,
                                                    classification: section.classification,
                                                    evidence: section.evidence,
                                                    decisionIDs: section.decisionIDs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = (try? encoder.encode(identity)) ?? Data()
            let id = "section_" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return ProjectDocumentationSection(id: id, order: section.order, title: section.title,
                                               body: section.body, classification: section.classification,
                                               evidence: section.evidence, decisionIDs: section.decisionIDs)
        }
        let payload = DocumentEditorProposalPayload(title: proposal.title, sections: sections, evidence: proposal.evidence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let entry: DocumentProposalInbox.Entry
        if let existing = try await inbox.existing(requestID: requestID) {
            guard existing.projectID == proposal.projectID,
                  existing.documentID == proposal.documentID,
                  existing.expectedRevision == proposal.expectedDocumentRevision,
                  existing.payload == data else {
                throw TaskContextError.invalid("This request ID already belongs to a different proposal. Use a new request ID.")
            }
            entry = existing
        } else {
            try await store.validateMCPDocumentProposal(proposal)
            entry = try await inbox.submit(requestID: requestID, projectID: proposal.projectID,
                                           documentID: proposal.documentID,
                                           expectedRevision: proposal.expectedDocumentRevision,
                                           payload: data)
        }
        return .init(id: entry.id, requestID: entry.requestID, projectID: entry.projectID,
                     documentID: entry.documentID, expectedRevision: entry.expectedRevision)
    }
}

private struct ProposalSectionIdentity: Codable, Sendable {
    let index: Int
    let order: Int
    let title: String
    let body: String
    let classification: ProjectDocumentationClassification
    let evidence: [ProjectEvidenceReference]
    let decisionIDs: [String]
}

private struct ProjectMCPPageCursor: Codable, Sendable {
    let scope: String
    let revision: String
    let offset: Int

    var encoded: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }

    static func offset(_ value: String?, scope: String, revision: String) throws -> Int {
        guard let value else { return 0 }
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.scope == scope, cursor.revision == revision, cursor.offset >= 0 else {
            throw TaskContextError.conflict
        }
        return cursor.offset
    }
}

private struct MCPProjectScope {
    let id: String
    let name: String
    let isInbox: Bool
    let databaseProjectID: String?
}

private extension VideoContextStore {
    static func mcpStableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func mcpScope(projectID: String, db: Database) throws -> MCPProjectScope {
        if projectID == ProjectMCPService.inboxID {
            return .init(id: projectID, name: "Inbox", isInbox: true, databaseProjectID: nil)
        }
        guard try db.tableExists("feedback_projects"),
              let row = try Row.fetchOne(db, sql: "SELECT id,name FROM feedback_projects WHERE id=?", arguments: [projectID]) else {
            throw TaskContextError.missing(projectID)
        }
        return .init(id: projectID, name: row["name"], isInbox: false, databaseProjectID: projectID)
    }

    static func mcpProjectRevision(workspace: ProjectWorkspaceSnapshot,
                                   documentation: ProjectDocumentationReadSnapshot) throws -> String {
        let payload: [String: Any] = [
            "recordings": workspace.recordings.map { [$0.id, $0.revisions.transcript, $0.revisions.evidence, $0.revisions.brief, $0.status.rawValue] },
            "batches": workspace.batches.map { [$0.id, $0.revision] },
            "tasks": workspace.tasks.map { [$0.id.id, $0.revision, $0.archived] },
            "sources": documentation.sources.map { [$0.id, $0.currentRevision] },
            "documents": documentation.documentation.map { [$0.id, $0.currentRevision, $0.reviewedRevision as Any] },
            "decisions": documentation.decisions.map { [$0.id, $0.revision, $0.state.rawValue] }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return mcpStableHash(String(decoding: data, as: UTF8.self))
    }

    static func mcpDocumentationSnapshot(scope: MCPProjectScope, db: Database) throws -> ProjectDocumentationReadSnapshot {
        guard let projectID = scope.databaseProjectID,
              try Self.documentationSchemaAvailable(db) else {
            return .init(projectID: scope.id)
        }
        return try mcpDocumentSnapshot(projectID: projectID, db: db)
    }

    static func mcpDocumentSnapshot(projectID: String, db: Database) throws -> ProjectDocumentationReadSnapshot {
        try Self.projectDocumentationSnapshot(projectID: projectID, db: db)
    }

    static func mcpSummary(scope: MCPProjectScope, workspace: ProjectWorkspaceSnapshot,
                           documentation: ProjectDocumentationReadSnapshot, revision: String) -> MCPProjectSummary {
        .init(id: scope.id, name: scope.name, isInbox: scope.isInbox,
              recordingCount: workspace.recordings.count, feedbackBatchCount: workspace.batches.count,
              taskCount: workspace.tasks.count, documentCount: documentation.documentation.count,
              revision: revision)
    }

    static func mcpWorkspace(scope: MCPProjectScope, db: Database) throws -> (MCPProjectScope, ProjectWorkspaceSnapshot, ProjectDocumentationReadSnapshot, String) {
        let workspace = try Self.projectWorkspace(projectID: scope.databaseProjectID, db: db)
        let documentation = try mcpDocumentationSnapshot(scope: scope, db: db)
        let revision = try mcpProjectRevision(workspace: workspace, documentation: documentation)
        return (scope, workspace, documentation, revision)
    }

    func mcpProjectList(query: String?, cursor: String?, limit: Int) throws -> MCPProjectList {
        guard (1...100).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        return try pool.read { db in
            var scopes: [MCPProjectScope] = []
            if try db.tableExists("feedback_projects") {
                scopes = try Row.fetchAll(db, sql: "SELECT id,name FROM feedback_projects ORDER BY name COLLATE NOCASE,id").map {
                    .init(id: $0["id"], name: $0["name"], isInbox: false, databaseProjectID: $0["id"])
                }
            }
            let hasVideosTable = try db.tableExists("videos")
            let hasProjectOwnershipColumn: Bool
            if hasVideosTable {
                hasProjectOwnershipColumn = try db.columns(in: "videos").contains(where: { $0.name == "project_id" })
            } else {
                hasProjectOwnershipColumn = false
            }
            let hasUnassignedVideo: Bool
            if hasProjectOwnershipColumn {
                hasUnassignedVideo = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos WHERE project_id IS NULL") ?? 0) > 0
            } else {
                // A read-only MCP client must continue to expose old libraries
                // as Inbox content until the app can run the ownership migration.
                hasUnassignedVideo = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0) > 0
            }
            let hasUnassignedBatch: Bool
            if try db.tableExists("feedback_batches") {
                hasUnassignedBatch = try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches")
                    .compactMap { try? JSONDecoder().decode(FeedbackBatch.self, from: $0) }
                    .contains { $0.projectID == nil }
            } else {
                hasUnassignedBatch = false
            }
            let hasInbox = hasUnassignedVideo || hasUnassignedBatch
            if hasInbox { scopes.append(.init(id: ProjectMCPService.inboxID, name: "Inbox", isInbox: true, databaseProjectID: nil)) }
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !trimmed.isEmpty { scopes = scopes.filter { $0.id.lowercased().contains(trimmed) || $0.name.lowercased().contains(trimmed) } }
            var summaries: [MCPProjectSummary] = []
            for scope in scopes {
                let workspace = try Self.projectWorkspace(projectID: scope.databaseProjectID, db: db)
                let documentation = try Self.mcpDocumentationSnapshot(scope: scope, db: db)
                let revision = try Self.mcpProjectRevision(workspace: workspace, documentation: documentation)
                summaries.append(Self.mcpSummary(scope: scope, workspace: workspace, documentation: documentation, revision: revision))
            }
            let signature = Self.mcpStableHash(summaries.map { "\($0.id):\($0.revision)" }.joined(separator: "|"))
            let scope = "projects:\(trimmed)"
            let offset = try ProjectMCPPageCursor.offset(cursor, scope: scope, revision: signature)
            guard offset <= summaries.count else { throw TaskContextError.conflict }
            let end = min(offset + limit, summaries.count)
            return .init(projects: Array(summaries[offset..<end]),
                         nextCursor: end < summaries.count ? ProjectMCPPageCursor(scope: scope, revision: signature, offset: end).encoded : nil)
        }
    }

    static func mcpTaskCitations(_ item: ProjectTaskItem, workspace: ProjectWorkspaceSnapshot,
                                 db: Database) -> [ProjectEvidenceReference] {
        switch item.reference {
        case .recording(let videoID, _):
            guard let video = workspace.recordings.first(where: { $0.id == videoID }),
                  case .recording(let sourceRevision) = item.sourceRevision,
                  let artifacts = try? mcpRecordingArtifacts(video: video, revision: sourceRevision, database: db) else { return [] }
            return item.content.allSourceIDs.sorted().compactMap { sourceID in
                if let segment = artifacts.transcript.first(where: { $0.id == sourceID }) {
                    return .recording(videoID: videoID, sourceRevision: sourceRevision, timestamp: segment.start, evidenceID: sourceID)
                }
                if let evidence = artifacts.evidence.first(where: { $0.id == sourceID }) {
                    return .recording(videoID: videoID, sourceRevision: sourceRevision, timestamp: evidence.timestamp, evidenceID: sourceID)
                }
                return nil
            }
        case .feedback(let batchID, _):
            guard case .feedback(let sourceRevision) = item.sourceRevision else { return [] }
            guard let batch = try? Self.feedbackBatch(batchID: batchID, revision: sourceRevision, database: db) else { return [] }
            return item.content.allSourceIDs.sorted().compactMap { id in
                if batch.comments.contains(where: { $0.id == id }) { return .feedback(batchID: batchID, sourceRevision: sourceRevision, commentID: id, sourceID: nil) }
                if batch.sources.contains(where: { $0.id == id }) { return .feedback(batchID: batchID, sourceRevision: sourceRevision, commentID: nil, sourceID: id) }
                return nil
            }
        }
    }

    static func mcpSourceCitations(_ revision: ProjectDocumentSourceRevision) -> [ProjectEvidenceReference] {
        revision.units.map { .document(sourceID: revision.sourceID, revision: revision.revision, locator: $0.locator) }
    }

    static func mcpContextItems(scope: MCPProjectScope, workspace: ProjectWorkspaceSnapshot,
                                documentation: ProjectDocumentationReadSnapshot, db: Database) -> [MCPProjectContextItem] {
        var items: [MCPProjectContextItem] = []
        for video in workspace.recordings {
            let summary = [video.status.displayName, video.errorMessage].compactMap { $0 }.joined(separator: ": ")
            items.append(.init(id: "recording:\(video.id)", kind: .recording, title: video.title,
                               summary: summary, revision: "transcript:\(video.revisions.transcript),evidence:\(video.revisions.evidence),brief:\(video.revisions.brief)",
                               state: video.status.rawValue, freshness: .current))
        }
        for batch in workspace.batches {
            let hasRequest = batch.comments.contains(where: { $0.kind == .request })
            let summary = batch.rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)
            items.append(.init(id: "feedback:\(batch.id)", kind: hasRequest ? .request : .feedback,
                               title: batch.title, summary: String(summary), revision: "batch:\(batch.revision)",
                               state: hasRequest ? "Request" : "Feedback", freshness: .current))
        }
        for task in workspace.tasks {
            let summary = ([task.content.behavior] + task.content.requirements.map(\.text) + task.content.checks.map(\.text) + task.content.questions.map(\.question)).joined(separator: "\n").prefix(1_000)
            let citations = Array(Set(mcpTaskCitations(task, workspace: workspace, db: db) + task.content.evidenceReferences)).sorted { $0.id < $1.id }
            items.append(.init(id: task.reference.id, kind: .task, title: task.content.title,
                               summary: String(summary), revision: "task:\(task.revision):\(task.sourceSignature)",
                               state: task.state, freshness: task.isStale ? .stale : .current, citations: citations))
        }
        for source in documentation.sources {
            guard let revision = documentation.sourceRevisions.first(where: { $0.sourceID == source.id && $0.revision == source.currentRevision }) else { continue }
            let text = revision.units.map(\.text).joined(separator: "\n").prefix(700)
            items.append(.init(id: "document-source:\(source.id)", kind: .documentSource, title: source.name,
                               summary: String(text), revision: "source:\(revision.revision):\(revision.contentHash)",
                               state: revision.status.rawValue, freshness: revision.isUsable ? .current : .unavailable,
                               citations: mcpSourceCitations(revision)))
        }
        for document in documentation.documentation {
            let citations = document.sections.flatMap(\.evidence)
            let text = (!document.markdown.isEmpty ? document.markdown : document.sections.map(\.body).joined(separator: "\n")).prefix(1_000)
            items.append(.init(id: "document:\(document.id)", kind: .document, title: document.title,
                               summary: String(text), revision: "document:\(document.currentRevision)",
                               state: document.isReviewed ? "Reviewed" : "Needs review",
                               freshness: document.isReviewed ? .current : .stale, citations: citations))
        }
        for decision in documentation.decisions {
            items.append(.init(id: "decision:\(decision.id)", kind: .decision, title: decision.key,
                               summary: "Question: \(decision.question)\nAnswer: \(decision.answer)",
                               revision: "decision:\(decision.revision)", state: decision.state.rawValue,
                               freshness: decision.state == .superseded || decision.evidenceNeedsReview == true ? .stale : .current, citations: decision.evidence))
        }
        return items.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    func mcpProjectContext(projectID: String, cursor: String?, limit: Int) throws -> MCPProjectContextPage {
        guard (1...100).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        return try pool.read { db in
            let scope = try Self.mcpScope(projectID: projectID, db: db)
            let (_, workspace, documentation, revision) = try Self.mcpWorkspace(scope: scope, db: db)
            let items = Self.mcpContextItems(scope: scope, workspace: workspace, documentation: documentation, db: db)
            let offset = try ProjectMCPPageCursor.offset(cursor, scope: "context:\(projectID)", revision: revision)
            guard offset <= items.count else { throw TaskContextError.conflict }
            let end = min(offset + limit, items.count)
            return .init(projectID: projectID, projectName: scope.name, isInbox: scope.isInbox, revision: revision,
                         items: Array(items[offset..<end]), conflicts: workspace.conflicts.map(\.id),
                         nextCursor: end < items.count ? ProjectMCPPageCursor(scope: "context:\(projectID)", revision: revision, offset: end).encoded : nil)
        }
    }

    static func mcpSearchText(for item: MCPProjectContextItem, extra: String = "") -> String {
        [item.title, item.summary, item.kind.rawValue, item.state ?? "", extra,
         item.citations.map(\.id).joined(separator: " ")].joined(separator: " ").lowercased()
    }

    func mcpProjectSearch(projectID: String, query: String, cursor: String?, limit: Int) throws -> MCPProjectSearchPage {
        guard (1...100).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw VideoContextStoreError.emptyQuery }
        return try pool.read { db in
            let scope = try Self.mcpScope(projectID: projectID, db: db)
            let (_, workspace, documentation, revision) = try Self.mcpWorkspace(scope: scope, db: db)
            var base = Self.mcpContextItems(scope: scope, workspace: workspace, documentation: documentation, db: db)
            for video in workspace.recordings {
                let transcript = try Row.fetchAll(db, sql: "SELECT id,start_time,end_time,COALESCE(corrected_text,original_text) AS text FROM transcript_segments WHERE video_id=?", arguments: [video.id])
                for row in transcript {
                    let text: String = row["text"]
                    guard text.localizedCaseInsensitiveContains(query) else { continue }
                    let sourceRevision = video.revisions
                    base.append(.init(id: "transcript:\(row["id"] as String)", kind: .recording, title: video.title,
                                      summary: text, revision: "transcript:\(sourceRevision.transcript)", state: "Transcript",
                                      citations: [.recording(videoID: video.id, sourceRevision: sourceRevision, timestamp: row["start_time"], evidenceID: row["id"]) ]))
                }
                let evidence = try Row.fetchAll(db, sql: "SELECT id,timestamp,ocr_text FROM evidence_items WHERE video_id=?", arguments: [video.id])
                for row in evidence {
                    let text: String = row["ocr_text"]
                    guard text.localizedCaseInsensitiveContains(query) else { continue }
                    base.append(.init(id: "evidence:\(row["id"] as String)", kind: .recording, title: video.title,
                                      summary: text, revision: "evidence:\(video.revisions.evidence)", state: "Screenshot",
                                      citations: [.recording(videoID: video.id, sourceRevision: video.revisions, timestamp: row["timestamp"], evidenceID: row["id"]) ]))
                }
                if let row = try Row.fetchOne(db, sql: "SELECT markdown FROM briefs WHERE video_id=?", arguments: [video.id]) {
                    let text: String = row["markdown"]
                    if text.localizedCaseInsensitiveContains(query) {
                        base.append(.init(id: "brief:\(video.id)", kind: .recording, title: video.title,
                                          summary: text.prefix(1_200).description, revision: "brief:\(video.revisions.brief)", state: "Brief", freshness: video.revisions.isBriefStale ? .stale : .current))
                    }
                }
            }
            for batch in workspace.batches {
                for comment in batch.comments where comment.text.localizedCaseInsensitiveContains(query) {
                    base.append(.init(id: "comment:\(comment.id)", kind: comment.kind == .request ? .request : .feedback,
                                      title: batch.title, summary: comment.text, revision: "batch:\(batch.revision)",
                                      state: comment.kind.rawValue, citations: [.feedback(batchID: batch.id, sourceRevision: batch.revision, commentID: comment.id, sourceID: nil)]))
                }
                for source in batch.sources where source.ocrText.localizedCaseInsensitiveContains(query) {
                    base.append(.init(id: "feedback-source:\(source.id)", kind: .feedback, title: batch.title,
                                      summary: source.ocrText, revision: "batch:\(batch.revision)", state: source.kind.rawValue,
                                      citations: [.feedback(batchID: batch.id, sourceRevision: batch.revision, commentID: nil, sourceID: source.id)]))
                }
            }
            for sourceRevision in documentation.sourceRevisions {
                for unit in sourceRevision.units where unit.text.localizedCaseInsensitiveContains(query) {
                    base.append(.init(id: "document-unit:\(unit.id)", kind: .documentSource, title: documentation.sources.first(where: { $0.id == sourceRevision.sourceID })?.name ?? sourceRevision.sourceID,
                                      summary: unit.text, revision: "source:\(sourceRevision.revision)", state: unit.kind.rawValue,
                                      freshness: documentation.sources.first(where: { $0.id == sourceRevision.sourceID })?.currentRevision == sourceRevision.revision ? .current : .stale,
                                      citations: [.document(sourceID: sourceRevision.sourceID, revision: sourceRevision.revision, locator: unit.locator)]))
                }
            }
            let hits = base.filter { Self.mcpSearchText(for: $0).contains(query.lowercased()) }
                .map { item in
                    MCPProjectSearchHit(id: item.id, kind: item.kind, title: item.title,
                                        excerpt: item.summary, revision: item.revision,
                                        freshness: item.freshness, citations: item.citations)
                }
                .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
            let signature = Self.mcpStableHash(revision + ":" + query.lowercased() + ":" + hits.map(\.id).joined(separator: "|"))
            let offset = try ProjectMCPPageCursor.offset(cursor, scope: "search:\(projectID):\(query.lowercased())", revision: signature)
            guard offset <= hits.count else { throw TaskContextError.conflict }
            let end = min(offset + limit, hits.count)
            return .init(projectID: projectID, revision: revision, query: query,
                         hits: Array(hits[offset..<end]),
                         nextCursor: end < hits.count ? ProjectMCPPageCursor(scope: "search:\(projectID):\(query.lowercased())", revision: signature, offset: end).encoded : nil)
        }
    }

    private static func mcpWordCount(_ text: String) -> Int {
        mcpWordRanges(text).count
    }

    private static func mcpWordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) {
            _, substringRange, _, _ in
            ranges.append(substringRange)
        }
        return ranges
    }

    private static func mcpWordSlice(_ text: String, start: Int, end: Int) -> String {
        let ranges = mcpWordRanges(text)
        guard start < end, start >= 0, start < ranges.count else { return "" }
        let boundedEnd = min(end, ranges.count)
        // Keep delimiters with the adjacent fragment, using the next word's
        // original boundary as the upper edge. This preserves punctuation,
        // Markdown markers, and code syntax without copying delimiters into
        // both neighboring pages.
        let lower = start == 0 ? text.startIndex : ranges[start].lowerBound
        let upper = boundedEnd < ranges.count ? ranges[boundedEnd].lowerBound : text.endIndex
        return String(text[lower..<upper])
    }

    private static func mcpSectionMarkdown(_ section: ProjectDocumentationSection) -> String {
        let citations = section.evidence.map { "- Evidence: `\(ProjectDocumentationFormatting.citationID($0))`" }.joined(separator: "\n")
        return "## \(section.title)\n\n\(section.classification.rawValue)\n\n\(section.body)" + (citations.isEmpty ? "" : "\n\n\(citations)")
    }

    private static func mcpSections(onPage document: ProjectDocumentation, pageStart: Int,
                                    pageEnd: Int) -> [ProjectDocumentationSection] {
        let sections = document.sections.sorted { $0.order < $1.order }
        var cursor = mcpWordCount("# \(document.title)")
        var selected: [ProjectDocumentationSection] = []
        for (index, section) in sections.enumerated() {
            let start = cursor
            let sectionMarkdown = mcpSectionMarkdown(section)
            let end = start + mcpWordCount(sectionMarkdown)
            if start < pageEnd && end > pageStart {
                let localStart = max(0, pageStart - start)
                let localEnd = min(end - start, pageEnd - start)
                let headerWords = mcpWordCount("## \(section.title)\n\n\(section.classification.rawValue)")
                let bodyWords = mcpWordCount(section.body)
                let bodyStart = headerWords
                let bodyEnd = bodyStart + bodyWords
                let bodyStartOnPage = max(localStart, bodyStart)
                let bodyEndOnPage = min(localEnd, bodyEnd)
                let body = mcpWordSlice(section.body,
                                         start: max(0, bodyStartOnPage - bodyStart),
                                         end: max(0, bodyEndOnPage - bodyStart))

                var citationCursor = bodyEnd
                var pageEvidence: [ProjectEvidenceReference] = []
                for evidence in section.evidence {
                    let citationWords = mcpWordCount("- Evidence: `\(ProjectDocumentationFormatting.citationID(evidence))`")
                    if citationCursor >= localStart && citationCursor < localEnd {
                        pageEvidence.append(evidence)
                    }
                    citationCursor += citationWords
                }
                let isComplete = localStart == 0 && localEnd == end - start
                if isComplete {
                    selected.append(section)
                } else {
                    selected.append(.init(id: section.id, order: section.order, title: section.title,
                                          body: body, classification: section.classification,
                                          evidence: pageEvidence, decisionIDs: section.decisionIDs))
                }
            }
            cursor = end
            if index < sections.count - 1 { /* the separator contains no words */ }
        }
        return selected
    }

    func mcpProjectDocument(projectID: String, documentID: String, expectedRevision: Int?,
                            cursor: String?, wordLimit: Int) throws -> MCPProjectDocumentPage {
        return try pool.read { db in
            guard (1...5_000).contains(wordLimit) else { throw VideoContextStoreError.invalidLimit }
            let scope = try Self.mcpScope(projectID: projectID, db: db)
            guard let databaseProjectID = scope.databaseProjectID else { throw TaskContextError.missing(documentID) }
            let documentation = try Self.mcpDocumentSnapshot(projectID: databaseProjectID, db: db)
            guard let document = documentation.documentation.first(where: { $0.id == documentID }) else { throw TaskContextError.missing(documentID) }
            if let expectedRevision, expectedRevision != document.currentRevision { throw TaskContextError.conflict }
            let markdown = document.markdown.isEmpty ? ProjectDocumentationFormatting.markdown(title: document.title, sections: document.sections) : document.markdown
            // The saved Markdown may be a hand-edited summary that omits or
            // rearranges structured sections. Keep returning that exact text,
            // but paginate structured metadata against the canonical section
            // representation so every section and citation remains reachable.
            let structuredMarkdown = ProjectDocumentationFormatting.markdown(title: document.title, sections: document.sections)
            let markdownWords = Self.mcpWordCount(markdown)
            let structuredWords = Self.mcpWordCount(structuredMarkdown)
            let bound = try ProjectMCPPageCursor.offset(cursor, scope: "document:\(projectID):\(documentID)", revision: "\(document.currentRevision)")
            guard bound <= Int.max - wordLimit else { throw TaskContextError.conflict }
            let markdownPage = Self.mcpWordSlice(markdown, start: bound, end: min(bound + wordLimit, markdownWords))
            let pageEnd = min(bound + wordLimit, structuredWords)
            let pageSections = Self.mcpSections(onPage: document, pageStart: bound, pageEnd: pageEnd)
            var seenCitationIDs = Set<String>()
            let pageCitations = pageSections.flatMap(\.evidence).filter { seenCitationIDs.insert($0.id).inserted }
            let maxWords = max(markdownWords, structuredWords)
            let nextOffset = bound + wordLimit < maxWords ? bound + wordLimit : nil
            return .init(projectID: projectID, documentID: document.id, revision: document.currentRevision,
                         title: document.title, slug: document.slug, reviewedRevision: document.reviewedRevision,
                         markdown: markdownPage, sections: pageSections,
                         citations: pageCitations,
                         freshness: document.isReviewed ? .current : .stale,
                         nextCursor: nextOffset.map { ProjectMCPPageCursor(scope: "document:\(projectID):\(documentID)", revision: "\(document.currentRevision)", offset: $0).encoded })
        }
    }

    static func mcpLoadImage(relativePath: String?, paths: LibraryPaths) throws -> (Data, String)? {
        guard let relativePath, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { return nil }
        let url = paths.absoluteURL(relativePath: relativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 30_000_000 else { throw TaskContextError.invalid("Evidence image is too large to return.") }
        return (data, Self.mcpMimeType(url.pathExtension))
    }

    static func mcpMimeType(_ extension: String) -> String {
        switch `extension`.lowercased() {
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        default: "image/jpeg"
        }
    }

    private struct MCPRecordingArtifactSnapshot {
        let transcript: [TranscriptSegment]
        let evidence: [EvidenceItem]
        let brief: BriefDocument?
        let freshness: MCPProjectFreshness
    }

    private static func mcpHistoricalArtifact(videoID: String, stage: SourceArtifactHistoryStage,
                                              revision: Int, database: Database) throws -> Data? {
        guard try database.tableExists("source_artifact_history") else { return nil }
        return try Data.fetchOne(database,
            sql: "SELECT artifact_data FROM source_artifact_history WHERE video_id=? AND stage=? AND revision=?",
            arguments: [videoID, stage.rawValue, revision])
    }

    /// Resolve each artifact independently. A task can cite a transcript from
    /// an older revision while its screenshot came from the current revision;
    /// both must be read from their exact source revision and reported stale.
    private static func mcpRecordingArtifacts(video: VideoRecord, revision: ArtifactRevision,
                                              database: Database) throws -> MCPRecordingArtifactSnapshot {
        guard revision.transcript <= video.revisions.transcript,
              revision.evidence <= video.revisions.evidence,
              revision.brief <= video.revisions.brief else { throw TaskContextError.conflict }

        let transcript: [TranscriptSegment]
        let transcriptWasHistorical: Bool
        if revision.transcript == video.revisions.transcript {
            transcript = try Row.fetchAll(database, sql: "SELECT * FROM transcript_segments WHERE video_id=? ORDER BY start_time,id", arguments: [video.id]).map(Self.transcript(from:))
            transcriptWasHistorical = false
        } else if revision.transcript == 0 {
            transcript = []
            transcriptWasHistorical = true
        } else if let data = try mcpHistoricalArtifact(videoID: video.id, stage: .transcript, revision: revision.transcript, database: database),
                  let decoded = try? JSONDecoder().decode([TranscriptSegment].self, from: data) {
            transcript = decoded
            transcriptWasHistorical = true
        } else {
            throw TaskContextError.missing("\(video.id) transcript revision \(revision.transcript)")
        }

        let evidence: [EvidenceItem]
        let evidenceWasHistorical: Bool
        if revision.evidence == video.revisions.evidence {
            evidence = try Row.fetchAll(database, sql: "SELECT * FROM evidence_items WHERE video_id=? ORDER BY timestamp,id", arguments: [video.id]).map(Self.evidence(from:))
            evidenceWasHistorical = false
        } else if revision.evidence == 0 {
            evidence = []
            evidenceWasHistorical = true
        } else if let data = try mcpHistoricalArtifact(videoID: video.id, stage: .evidence, revision: revision.evidence, database: database),
                  let decoded = try? JSONDecoder().decode([EvidenceItem].self, from: data) {
            evidence = decoded
            evidenceWasHistorical = true
        } else {
            throw TaskContextError.missing("\(video.id) evidence revision \(revision.evidence)")
        }

        let brief: BriefDocument?
        let briefWasHistorical: Bool
        if revision.brief == video.revisions.brief {
            brief = try Row.fetchOne(database, sql: "SELECT * FROM briefs WHERE video_id=?", arguments: [video.id]).map(Self.brief(from:))
            briefWasHistorical = false
        } else if revision.brief == 0 {
            brief = nil
            briefWasHistorical = true
        } else if let data = try mcpHistoricalArtifact(videoID: video.id, stage: .brief, revision: revision.brief, database: database),
                  let decoded = try? JSONDecoder().decode(BriefDocument.self, from: data) {
            brief = decoded
            briefWasHistorical = true
        } else {
            throw TaskContextError.missing("\(video.id) brief revision \(revision.brief)")
        }
        let freshness: MCPProjectFreshness = transcriptWasHistorical || evidenceWasHistorical || briefWasHistorical ? .stale : .current
        return .init(transcript: transcript, evidence: evidence, brief: brief, freshness: freshness)
    }

    func mcpProjectEvidence(projectID: String, reference: ProjectEvidenceReference,
                            paths: LibraryPaths) throws -> MCPProjectEvidenceResult {
        try pool.read { db in
            let scope = try Self.mcpScope(projectID: projectID, db: db)
            let databaseProjectID = scope.databaseProjectID
            let sourceBelongsToScope: (String?) -> Bool = { owner in
                scope.isInbox ? owner == nil : owner == databaseProjectID
            }
            switch reference {
            case .recording(let videoID, let requestedRevision, let timestamp, let evidenceID):
                guard let video = try Self.fetchVideo(id: videoID, from: db), sourceBelongsToScope(video.projectID) else { throw TaskContextError.missing(videoID) }
                guard timestamp.isFinite, timestamp >= 0 else { throw TaskContextError.invalid("Evidence timestamp must be non-negative.") }
                let artifacts = try Self.mcpRecordingArtifacts(video: video, revision: requestedRevision, database: db)
                if let evidenceID {
                    if let item = artifacts.evidence.first(where: { $0.id == evidenceID }) {
                        let image = try Self.mcpLoadImage(relativePath: item.imageRelativePath, paths: paths)
                        return .init(projectID: projectID, reference: reference, freshness: artifacts.freshness, title: video.title,
                                     locator: "timestamp \(item.timestamp)s; evidence \(evidenceID)",
                                     sourceRevision: "transcript:\(requestedRevision.transcript),evidence:\(requestedRevision.evidence),brief:\(requestedRevision.brief)",
                                     text: item.ocrText, imageData: image?.0, imageMimeType: image?.1)
                    }
                    if let segment = artifacts.transcript.first(where: { $0.id == evidenceID }) {
                        return .init(projectID: projectID, reference: reference, freshness: artifacts.freshness, title: video.title,
                                     locator: "timestamp \(segment.start)s; transcript \(evidenceID)",
                                     sourceRevision: "transcript:\(requestedRevision.transcript),evidence:\(requestedRevision.evidence),brief:\(requestedRevision.brief)",
                                     text: segment.correctedText ?? segment.originalText)
                    }
                    throw TaskContextError.missing(evidenceID)
                }
                let text = artifacts.transcript.filter { $0.start <= timestamp && $0.end >= timestamp }
                    .map { $0.correctedText ?? $0.originalText }.joined(separator: " ")
                return .init(projectID: projectID, reference: reference, freshness: artifacts.freshness, title: video.title,
                             locator: "timestamp \(timestamp)s", sourceRevision: "transcript:\(requestedRevision.transcript),evidence:\(requestedRevision.evidence),brief:\(requestedRevision.brief)", text: text)
            case .feedback(let batchID, let requestedRevision, let commentID, let sourceID):
                guard let currentBatch = try? Self.feedbackBatch(batchID, in: db), sourceBelongsToScope(currentBatch.projectID) else { throw TaskContextError.missing(batchID) }
                guard requestedRevision <= currentBatch.revision else { throw TaskContextError.conflict }
                let batch: FeedbackBatch
                let freshness: MCPProjectFreshness
                if requestedRevision == currentBatch.revision {
                    batch = currentBatch; freshness = .current
                } else if requestedRevision > 0,
                          try db.tableExists("feedback_source_history"),
                          let data = try Data.fetchOne(db, sql: "SELECT document FROM feedback_source_history WHERE batch_id=? AND revision=?", arguments: [batchID, requestedRevision]),
                          let historical = try? JSONDecoder().decode(FeedbackBatch.self, from: data) {
                    batch = historical; freshness = .stale
                } else {
                    throw TaskContextError.missing("\(batchID) revision \(requestedRevision)")
                }
                if let commentID {
                    guard let comment = batch.comments.first(where: { $0.id == commentID }) else {
                        throw TaskContextError.missing(commentID)
                    }
                    return .init(projectID: projectID, reference: reference, freshness: freshness, title: batch.title,
                                 locator: "feedback comment \(comment.id)", sourceRevision: "batch:\(batch.revision)", text: comment.text)
                }
                if let sourceID, let source = batch.sources.first(where: { $0.id == sourceID }) {
                    let image = try Self.mcpLoadImage(relativePath: source.localPath, paths: paths)
                    return .init(projectID: projectID, reference: reference, freshness: source.status == .ready ? freshness : .unavailable,
                                 title: batch.title, locator: "feedback source \(source.id)", sourceRevision: "batch:\(batch.revision)",
                                 text: [source.ocrText, source.error ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"),
                                 imageData: image?.0, imageMimeType: image?.1, error: source.error)
                }
                throw TaskContextError.missing(commentID ?? sourceID ?? batchID)
            case .document(let sourceID, let requestedRevision, let locator):
                guard let databaseProjectID else { throw TaskContextError.missing(sourceID) }
                guard let source = try Row.fetchOne(db, sql: "SELECT * FROM project_document_sources WHERE id=? AND project_id=?", arguments: [sourceID, databaseProjectID]),
                      let sourceRevision = try Self.sourceRevision(sourceID: sourceID, revision: requestedRevision, database: db) else { throw TaskContextError.missing(sourceID) }
                guard sourceRevision.projectID == databaseProjectID else { throw TaskContextError.missing(sourceID) }
                guard Self.locatorExists(locator, in: sourceRevision) else { throw TaskContextError.missing(locator.displayValue) }
                let unit = sourceRevision.units.first { unit in
                    if locator.kind == .unit { return locator.value == unit.id }
                    if locator.kind == .heading { return unit.title == locator.value }
                    return unit.locator == locator ||
                        (locator.kind == .pdfPage && unit.locator.kind == .pdfPage && unit.locator.page == locator.page) ||
                        (locator.kind == .markdownLine && unit.locator.kind == .markdownLine && unit.locator.startLine == locator.startLine)
                }
                let sourceName: String = source["name"]
                let text = unit?.text ?? sourceRevision.units.filter { $0.locator == locator }.map(\.text).joined(separator: "\n")
                let pageAssetName = locator.kind == .pdfPage ? "page-\(locator.page ?? 0).png" : nil
                let asset = sourceRevision.assets.first {
                    $0.sourcePath == locator.value || $0.relativePath == locator.value || $0.id == locator.value || $0.sourcePath == pageAssetName
                }
                let image = try Self.mcpLoadImage(relativePath: asset?.relativePath, paths: paths)
                let assetError: String?
                if let asset, asset.status != .copied {
                    assetError = asset.error ?? (asset.status == .external ? "This asset is external and was not copied into the library." : "This asset is unavailable.")
                } else if asset != nil && image == nil {
                    assetError = "The copied asset file is unavailable in the library."
                } else if locator.kind == .pdfPage && asset == nil {
                    assetError = "The rendered page image is unavailable."
                } else {
                    assetError = nil
                }
                let freshness: MCPProjectFreshness = assetError != nil ? .unavailable : sourceRevision.isUsable ? (source["current_revision"] as Int == sourceRevision.revision ? .current : .stale) : .unavailable
                return .init(projectID: projectID, reference: reference, freshness: freshness,
                             title: sourceName, locator: locator.displayValue, sourceRevision: "source:\(sourceRevision.revision):\(sourceRevision.contentHash)",
                             text: text, imageData: image?.0, imageMimeType: image?.1,
                             error: assetError ?? sourceRevision.errors.first?.message)
            case .reviewedDocumentation(let documentID, let requestedRevision, let sectionID):
                guard let databaseProjectID,
                      let row = try Row.fetchOne(db, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [documentID, databaseProjectID]),
                      let revision = try Self.documentationRevision(documentID: documentID, revision: requestedRevision, projectID: databaseProjectID, database: db) else {
                    throw TaskContextError.missing("\(documentID) revision \(requestedRevision)")
                }
                let text: String
                let locator: String
                if let sectionID {
                    guard let section = revision.sections.first(where: { $0.id == sectionID }) else {
                        throw TaskContextError.missing(sectionID)
                    }
                    text = section.body
                    locator = "section \(sectionID): \(section.title)"
                } else {
                    text = revision.markdown.isEmpty
                        ? revision.sections.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }).map { "## \($0.title)\n\n\($0.body)" }.joined(separator: "\n\n")
                        : revision.markdown
                    locator = "complete document"
                }
                let currentRevision: Int = row["current_revision"]
                let reviewedRevision: Int? = row["reviewed_revision"]
                let freshness: MCPProjectFreshness = currentRevision == requestedRevision && reviewedRevision == requestedRevision ? .current : .stale
                return .init(projectID: projectID, reference: reference, freshness: freshness,
                             title: revision.title, locator: locator, sourceRevision: "documentation:\(requestedRevision)", text: text)
            }
        }
    }

    func validateMCPDocumentProposal(_ proposal: ProjectDocumentationProposal) throws {
        try pool.read { db in
            try Self.requireDocumentationSchema(db)
            try Self.requireProject(proposal.projectID, in: db)
            try Self.validateDocumentationPayload(title: proposal.title, slug: proposal.slug, markdown: proposal.markdown, sections: proposal.sections)
            try Self.validateDecisionOwnership(proposal.sections, projectID: proposal.projectID, db: db)
            if proposal.expectedDocumentRevision == 0 {
                guard try Row.fetchOne(db, sql: "SELECT id FROM project_documentation WHERE id=?", arguments: [proposal.documentID]) == nil else {
                    throw TaskContextError.conflict
                }
            } else {
                guard let row = try Row.fetchOne(db, sql: "SELECT current_revision FROM project_documentation WHERE id=? AND project_id=?", arguments: [proposal.documentID, proposal.projectID]),
                      (row["current_revision"] as Int) == proposal.expectedDocumentRevision else { throw TaskContextError.conflict }
            }
            try Self.validateEvidence(proposal.evidence + proposal.sections.flatMap(\.evidence), projectID: proposal.projectID, database: db)
        }
    }
}
