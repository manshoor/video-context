import Foundation
import GRDB

public enum ProjectDocumentationStoreError: Error, LocalizedError, Equatable, Sendable {
    case schemaUnavailable
    case projectNotFound(String)
    case sourceNotFound(String)
    case revisionNotFound(String)
    case documentNotFound(String)
    case proposalNotFound(String)
    case conflict
    case invalidEvidence(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .schemaUnavailable: "Project documentation is unavailable in this library. Open it once in the current app to apply the additive migration."
        case .projectNotFound(let id): "Project not found: \(id)."
        case .sourceNotFound(let id): "Document source not found: \(id)."
        case .revisionNotFound(let id): "Document source revision not found: \(id)."
        case .documentNotFound(let id): "Project documentation not found: \(id)."
        case .proposalNotFound(let id): "Documentation proposal not found: \(id)."
        case .conflict: "The project documentation changed. Refresh before saving this draft or proposal."
        case .invalidEvidence(let message): message
        case .invalidInput(let message): message
        }
    }
}

public enum ProjectDocumentationReviewDecision: String, Codable, Sendable {
    case accept
    case reject
}

public struct ProjectDocumentationDraft: Codable, Equatable, Sendable {
    public let documentID: String
    public let projectID: String
    public let expectedRevision: Int
    public let title: String
    public let slug: String
    public let markdown: String
    public let sections: [ProjectDocumentationSection]
    public let sourceSignature: String

    public init(documentID: String, projectID: String, expectedRevision: Int, title: String, slug: String, markdown: String, sections: [ProjectDocumentationSection], sourceSignature: String = "") {
        self.documentID = documentID; self.projectID = projectID; self.expectedRevision = expectedRevision; self.title = title; self.slug = slug; self.markdown = markdown; self.sections = sections; self.sourceSignature = sourceSignature
    }
}

/// Read-only namespace used by the MCP and app layers for project-documentation
/// database helpers. The stateful operations remain methods on
/// ``VideoContextStore``; keeping these small forwarding methods here lets
/// callers perform a consistent read inside an existing GRDB transaction.
public enum ProjectDocumentationStore {
    public static func documentationSchemaAvailable(_ database: Database) throws -> Bool {
        try VideoContextStore.documentationSchemaAvailable(database)
    }

    public static func requireDocumentationSchema(_ database: Database) throws {
        try VideoContextStore.requireDocumentationSchema(database)
    }

    public static func requireProject(_ projectID: String, in database: Database) throws {
        try VideoContextStore.requireProject(projectID, in: database)
    }

    public static func projectDocumentationSnapshot(projectID: String, db: Database) throws -> ProjectDocumentationReadSnapshot {
        try VideoContextStore.projectDocumentationSnapshot(projectID: projectID, db: db)
    }

    public static func documentSources(projectID: String, db: Database) throws -> [ProjectDocumentSource] {
        try VideoContextStore.documentSources(projectID: projectID, db: db)
    }

    public static func sourceRevision(sourceID: String, revision: Int? = nil, db: Database) throws -> ProjectDocumentSourceRevision? {
        try VideoContextStore.documentSourceRevision(sourceID: sourceID, revision: revision, db: db)
    }

    public static func validateEvidence(_ references: [ProjectEvidenceReference], projectID: String, database: Database) throws {
        try VideoContextStore.validateEvidence(references, projectID: projectID, database: database)
    }

    public static func locatorExists(_ locator: ProjectDocumentLocator, in revision: ProjectDocumentSourceRevision) -> Bool {
        VideoContextStore.locatorExists(locator, in: revision)
    }
}

private struct DocumentImportJobStart: Sendable {
    let id: String
    let projectID: String
    let sourceKey: String
    let sourcePath: String
    let intakeURL: URL
    let selectedAttachmentURLs: [URL]
    let checkpointURL: URL
    let intakeRelativePath: String
    let attachmentRelativePaths: [String]
    let checkpointRelativePath: String
}

public extension VideoContextStore {
    /// The app registers this method as one additive migration after the existing project schema.
    static func createProjectDocumentationSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE project_document_sources (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                source_key TEXT NOT NULL,
                kind TEXT NOT NULL,
                current_revision INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(project_id, source_key)
            );
            CREATE INDEX project_document_sources_project ON project_document_sources(project_id, updated_at, id);
            CREATE TABLE project_document_source_revisions (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES project_document_sources(id) ON DELETE CASCADE,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                extraction_version TEXT NOT NULL,
                original_relative_path TEXT NOT NULL,
                status TEXT NOT NULL,
                document BLOB NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(source_id, revision)
            );
            CREATE INDEX project_document_source_revisions_hash ON project_document_source_revisions(project_id, content_hash);
            CREATE INDEX project_document_source_revisions_project ON project_document_source_revisions(project_id, source_id, revision);
            CREATE TABLE project_document_import_jobs (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                source_key TEXT NOT NULL,
                source_path TEXT NOT NULL,
                source_id TEXT,
                intake_relative_path TEXT,
                attachment_relative_paths BLOB,
                checkpoint_relative_path TEXT,
                content_hash TEXT,
                status TEXT NOT NULL,
                error TEXT,
                updated_at REAL NOT NULL
            );
            CREATE INDEX project_document_import_jobs_project ON project_document_import_jobs(project_id, status, updated_at, id);
            CREATE TABLE project_documentation (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                slug TEXT NOT NULL,
                title TEXT NOT NULL,
                current_revision INTEGER NOT NULL DEFAULT 0,
                reviewed_revision INTEGER,
                document BLOB NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(project_id, slug)
            );
            CREATE INDEX project_documentation_project ON project_documentation(project_id, updated_at, id);
            CREATE TABLE project_documentation_revisions (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES project_documentation(id) ON DELETE CASCADE,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                document BLOB NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(document_id, revision)
            );
            CREATE INDEX project_documentation_revisions_project ON project_documentation_revisions(project_id, document_id, revision);
            CREATE TABLE project_documentation_proposals (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                document_id TEXT NOT NULL,
                expected_revision INTEGER NOT NULL,
                state TEXT NOT NULL,
                stale INTEGER NOT NULL DEFAULT 0,
                document BLOB NOT NULL,
                diff BLOB NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX project_documentation_proposals_project ON project_documentation_proposals(project_id, state, updated_at, id);
            CREATE TABLE project_decisions (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                document BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX project_decisions_project ON project_decisions(project_id, updated_at, id);
            CREATE TABLE project_question_group_proposals (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES feedback_projects(id) ON DELETE CASCADE,
                state TEXT NOT NULL,
                document BLOB NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX project_question_groups_project ON project_question_group_proposals(project_id, state, updated_at, id);
            """)
        try ensureDocumentImportJobColumns(in: database)
    }

    /// Add columns introduced after the first documentation migration. Root's
    /// migration registers this helper for existing libraries; the CREATE
    /// path above also calls it so temporary libraries use the same schema.
    static func ensureDocumentImportJobColumns(in database: Database) throws {
        guard try database.tableExists("project_document_import_jobs") else { return }
        let columns = Set(try database.columns(in: "project_document_import_jobs").map(\.name))
        if !columns.contains("intake_relative_path") { try database.execute(sql: "ALTER TABLE project_document_import_jobs ADD COLUMN intake_relative_path TEXT") }
        if !columns.contains("attachment_relative_paths") { try database.execute(sql: "ALTER TABLE project_document_import_jobs ADD COLUMN attachment_relative_paths BLOB") }
        if !columns.contains("checkpoint_relative_path") { try database.execute(sql: "ALTER TABLE project_document_import_jobs ADD COLUMN checkpoint_relative_path TEXT") }
        if !columns.contains("content_hash") { try database.execute(sql: "ALTER TABLE project_document_import_jobs ADD COLUMN content_hash TEXT") }
    }

    /// Register this helper from a follow-up migration when opening a library
    /// that already applied productDocumentationV1 before durable intake was
    /// introduced.
    static func migrateProjectDocumentationImportJobs(in database: Database) throws {
        try ensureDocumentImportJobColumns(in: database)
    }

    // MARK: Read helpers

    static func documentationSchemaAvailable(_ database: Database) throws -> Bool {
        try database.tableExists("project_document_sources") &&
        database.tableExists("project_document_source_revisions") &&
        database.tableExists("project_document_import_jobs") &&
        database.tableExists("project_documentation") &&
        database.tableExists("project_documentation_revisions") &&
        database.tableExists("project_documentation_proposals") &&
        database.tableExists("project_decisions") &&
        database.tableExists("project_question_group_proposals")
    }

    static func requireDocumentationSchema(_ database: Database) throws {
        guard try documentationSchemaAvailable(database) else { throw ProjectDocumentationStoreError.schemaUnavailable }
    }

    static func requireProject(_ projectID: String, in database: Database) throws {
        guard try String.fetchOne(database, sql: "SELECT id FROM feedback_projects WHERE id=?", arguments: [projectID]) != nil else {
            throw ProjectDocumentationStoreError.projectNotFound(projectID)
        }
    }

    static func source(from row: Row) -> ProjectDocumentSource {
        .init(id: row["id"], projectID: row["project_id"], name: row["name"], sourceKey: row["source_key"], kind: ProjectDocumentSourceKind(rawValue: row["kind"]) ?? .markdown,
              currentRevision: row["current_revision"], createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    static func sourceRevision(from row: Row) throws -> ProjectDocumentSourceRevision {
        guard let data: Data = row["document"] else { throw ProjectDocumentationStoreError.revisionNotFound(row["id"]) }
        return try JSONDecoder().decode(ProjectDocumentSourceRevision.self, from: data)
    }

    static func sources(projectID: String, database: Database) throws -> [ProjectDocumentSource] {
        guard try documentationSchemaAvailable(database) else { return [] }
        return try Row.fetchAll(database, sql: "SELECT * FROM project_document_sources WHERE project_id=? ORDER BY updated_at DESC,id", arguments: [projectID]).map(source(from:))
    }

    public static func documentSources(projectID: String, db: Database) throws -> [ProjectDocumentSource] {
        try sources(projectID: projectID, database: db)
    }

    static func sourceRevision(sourceID: String, revision: Int?, database: Database) throws -> ProjectDocumentSourceRevision? {
        guard try documentationSchemaAvailable(database) else { return nil }
        let row: Row?
        if let revision {
            row = try Row.fetchOne(database, sql: "SELECT * FROM project_document_source_revisions WHERE source_id=? AND revision=?", arguments: [sourceID, revision])
        } else {
            row = try Row.fetchOne(database, sql: "SELECT * FROM project_document_source_revisions WHERE source_id=? ORDER BY revision DESC LIMIT 1", arguments: [sourceID])
        }
        return try row.map(sourceRevision(from:))
    }

    public static func documentSourceRevision(sourceID: String, revision: Int? = nil, db: Database) throws -> ProjectDocumentSourceRevision? {
        try sourceRevision(sourceID: sourceID, revision: revision, database: db)
    }

    public func listProjectDocumentSources(projectID: String) throws -> [ProjectDocumentSource] {
        try pool.read { database in try Self.sources(projectID: projectID, database: database) }
    }

    public func projectDocumentSource(projectID: String, sourceID: String, revision: Int? = nil) throws -> (ProjectDocumentSource, ProjectDocumentSourceRevision)? {
        try pool.read { database in
            guard try Self.documentationSchemaAvailable(database),
                  let row = try Row.fetchOne(database, sql: "SELECT * FROM project_document_sources WHERE id=? AND project_id=?", arguments: [sourceID, projectID]) else { return nil }
            let source = Self.source(from: row)
            guard let sourceRevision = try Self.sourceRevision(sourceID: sourceID, revision: revision, database: database) else { return nil }
            guard sourceRevision.projectID == projectID else { throw ProjectDocumentationStoreError.invalidEvidence("The source belongs to another project.") }
            return (source, sourceRevision)
        }
    }

    static func documentation(from row: Row) throws -> ProjectDocumentation {
        let data: Data = row["document"]
        return try JSONDecoder().decode(ProjectDocumentation.self, from: data)
    }

    static func documentationRevision(from row: Row) throws -> ProjectDocumentationRevision {
        let data: Data = row["document"]
        return try JSONDecoder().decode(ProjectDocumentationRevision.self, from: data)
    }

    static func documentationRevision(documentID: String, revision: Int, projectID: String, database: Database) throws -> ProjectDocumentationRevision? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM project_documentation_revisions WHERE document_id=? AND project_id=? AND revision=?",
            arguments: [documentID, projectID, revision]
        ) else { return nil }
        return try documentationRevision(from: row)
    }

    static func proposal(from row: Row) throws -> ProjectDocumentationProposal {
        let data: Data = row["document"]
        return try JSONDecoder().decode(ProjectDocumentationProposal.self, from: data)
    }

    static func decision(from row: Row) throws -> ProjectDecision {
        try JSONDecoder().decode(ProjectDecision.self, from: row["document"])
    }

    static func questionGroup(from row: Row) throws -> ProjectQuestionGroupProposal {
        try JSONDecoder().decode(ProjectQuestionGroupProposal.self, from: row["document"])
    }

    public static func projectDocumentationSnapshot(projectID: String, db: Database) throws -> ProjectDocumentationReadSnapshot {
        guard try documentationSchemaAvailable(db) else { return .init(projectID: projectID) }
        let sources = try sources(projectID: projectID, database: db)
        let sourceRevisions = try Data.fetchAll(db, sql: "SELECT document FROM project_document_source_revisions WHERE project_id=? ORDER BY source_id,revision", arguments: [projectID]).compactMap { try? JSONDecoder().decode(ProjectDocumentSourceRevision.self, from: $0) }
        var docs = try Row.fetchAll(db, sql: "SELECT * FROM project_documentation WHERE project_id=? ORDER BY updated_at DESC,id", arguments: [projectID]).map(documentation(from:))
        let revisions = try Row.fetchAll(db, sql: "SELECT * FROM project_documentation_revisions WHERE project_id=? ORDER BY document_id,revision", arguments: [projectID]).map(documentationRevision(from:))
        var proposals = try Row.fetchAll(db, sql: "SELECT * FROM project_documentation_proposals WHERE project_id=? ORDER BY updated_at DESC,id", arguments: [projectID]).map(proposal(from:))
        var decisions = try Row.fetchAll(db, sql: "SELECT * FROM project_decisions WHERE project_id=? ORDER BY updated_at DESC,id", arguments: [projectID]).map(decision(from:))
        for index in decisions.indices {
            decisions[index].evidenceNeedsReview = (try? Self.validateCurrentDocumentationEvidence(decisions[index].evidence, projectID: projectID, db: db)) == nil
        }
        let groups = try Row.fetchAll(db, sql: "SELECT * FROM project_question_group_proposals WHERE project_id=? ORDER BY updated_at DESC,id", arguments: [projectID]).map(questionGroup(from:))
        // Review approval is derived from the evidence currently owned by the
        // project. Keep the stored revision and history intact, but expose a
        // document as pending review as soon as a recording, feedback batch,
        // or document source has moved or changed. This also prevents stale
        // MCP reads from advertising an old approval as current.
        for index in docs.indices where docs[index].reviewedRevision == docs[index].currentRevision {
            if (try? Self.validateCurrentDocumentationEvidence(docs[index].sections.flatMap(\.evidence), projectID: projectID, db: db)) == nil ||
                (try? Self.validateCurrentDocumentationDecisions(docs[index].sections, projectID: projectID, db: db)) == nil {
                docs[index].reviewedRevision = nil
            }
        }
        for index in proposals.indices where proposals[index].state == .pending {
            let document = docs.first(where: { $0.id == proposals[index].documentID })
            let isNewDocument = document == nil && proposals[index].expectedDocumentRevision == 0
            let hasMatchingDocument = document.map { $0.currentRevision == proposals[index].expectedDocumentRevision } ?? false
            guard (isNewDocument || hasMatchingDocument),
                  (try? Self.validateCurrentDocumentationEvidence(proposals[index].evidence + proposals[index].sections.flatMap(\.evidence), projectID: projectID, db: db)) != nil,
                  (try? Self.validateCurrentDocumentationDecisions(proposals[index].sections, projectID: projectID, db: db)) != nil else {
                proposals[index].isStale = true
                continue
            }
        }
        return .init(projectID: projectID, sources: sources, sourceRevisions: sourceRevisions, documentation: docs, revisions: revisions, proposals: proposals, decisions: decisions, questionGroups: groups)
    }

    public func projectDocumentationReadSnapshot(projectID: String) throws -> ProjectDocumentationReadSnapshot {
        try pool.read { try Self.projectDocumentationSnapshot(projectID: projectID, db: $0) }
    }

    public func projectDocumentation(projectID: String, documentID: String? = nil) throws -> ProjectDocumentationSnapshot {
        let snapshot = try projectDocumentationReadSnapshot(projectID: projectID)
        let docs = documentID.map { id in snapshot.documentation.filter { $0.id == id } } ?? snapshot.documentation
        let docIDs = Set(docs.map(\.id))
        return .init(projectID: projectID, documentation: docs, revisions: snapshot.revisions.filter { docIDs.contains($0.documentID) },
                     proposals: documentID == nil ? snapshot.proposals : snapshot.proposals.filter { docIDs.contains($0.documentID) },
                     decisions: snapshot.decisions, questionGroups: snapshot.questionGroups)
    }

    // MARK: Source imports

    public func importDocumentSource(projectID: String, sourceURL: URL, paths: LibraryPaths, selectedAttachments: [URL] = []) throws -> ProjectDocumentImportResult {
        let artifact = try DocumentSourceImporter.inspect(sourceURL, selectedAttachments: selectedAttachments)
        return try persistDocumentImport(projectID: projectID, artifact: artifact, paths: paths)
    }

    /// Runs extraction away from the store actor, then publishes one immutable revision.
    /// The job row makes failures visible and allows the app to offer a retry after restart.
    public func importDocumentSourceAsync(projectID: String, sourceURL: URL, paths: LibraryPaths, selectedAttachments: [URL] = []) async throws -> ProjectDocumentImportResult {
        let start = try beginDocumentImportJob(projectID: projectID, sourceURL: sourceURL, paths: paths, selectedAttachments: selectedAttachments)
        do {
            let extractionTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try DocumentSourceImporter.inspect(start.intakeURL, selectedAttachments: start.selectedAttachmentURLs,
                    checkpointURL: start.checkpointURL, sourceKeyOverride: start.sourceKey)
            }
            let artifact = try await withTaskCancellationHandler(operation: {
                try await extractionTask.value
            }, onCancel: {
                extractionTask.cancel()
            })
            try Task.checkCancellation()
            let result = try persistDocumentImport(projectID: projectID, artifact: artifact, paths: paths)
            try finishDocumentImportJob(id: start.id, status: .completed, sourceID: result.source.id, contentHash: result.revision.contentHash, error: nil)
            cleanupDocumentImportIntake(start, paths: paths)
            return result
        } catch {
            let status: ProjectDocumentImportJobStatus = Task.isCancelled ? .pending : .failed
            try? finishDocumentImportJob(id: start.id, status: status, sourceID: nil, contentHash: nil, error: error.localizedDescription)
            throw error
        }
    }

    /// Resumes durable imports after an app restart. A failed or interrupted
    /// job keeps its intake copy and PDF checkpoints; each job is retried in
    /// order and a failure is recorded while later jobs continue.
    @discardableResult
    public func resumePendingDocumentImports(projectID: String? = nil, paths: LibraryPaths) async -> [ProjectDocumentImportResult] {
        let jobs = (try? pendingDocumentImportJobs(projectID: projectID)) ?? []
        var results: [ProjectDocumentImportResult] = []
        for job in jobs {
            do {
                let intakeURL = job.intakeRelativePath.map(paths.absoluteURL(relativePath:)) ?? URL(fileURLWithPath: job.sourcePath)
                let intakeDirectory = intakeURL.deletingLastPathComponent()
                let attachments = job.attachmentRelativePaths.map { intakeDirectory.appending(path: $0) }
                let checkpoint = job.checkpointRelativePath.map(paths.absoluteURL(relativePath:))
                let extractionTask = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try DocumentSourceImporter.inspect(intakeURL, selectedAttachments: attachments, checkpointURL: checkpoint, sourceKeyOverride: job.sourceKey)
                }
                let artifact = try await withTaskCancellationHandler(operation: {
                    try await extractionTask.value
                }, onCancel: {
                    extractionTask.cancel()
                })
                let result = try persistDocumentImport(projectID: job.projectID, artifact: artifact, paths: paths)
                try finishDocumentImportJob(id: job.id, status: .completed, sourceID: result.source.id, contentHash: result.revision.contentHash, error: nil)
                if let intakeRelativePath = job.intakeRelativePath {
                    cleanupDocumentImportIntake(at: paths.absoluteURL(relativePath: intakeRelativePath).deletingLastPathComponent(), paths: paths)
                }
                results.append(result)
            } catch {
                try? finishDocumentImportJob(id: job.id, status: .failed, sourceID: nil, contentHash: nil, error: error.localizedDescription)
            }
        }
        return results
    }

    private func persistDocumentImport(projectID: String, artifact: ProjectDocumentImportArtifact, paths: LibraryPaths) throws -> ProjectDocumentImportResult {
        return try pool.write { database in
            try Self.requireDocumentationSchema(database)
            try Self.requireProject(projectID, in: database)
            let existing = try Row.fetchOne(database, sql: "SELECT * FROM project_document_sources WHERE project_id=? AND source_key=?", arguments: [projectID, artifact.sourceKey])
                .map(Self.source(from:))
            if let existing,
               let current = try Self.sourceRevision(sourceID: existing.id, revision: existing.currentRevision, database: database),
               current.contentHash == artifact.contentHash {
                return .init(source: existing, revision: current, reusedExistingRevision: true)
            }
            if existing == nil, let reused = try Self.findRevision(projectID: projectID, contentHash: artifact.contentHash, database: database) {
                let source = try Self.fetchSource(id: reused.sourceID, projectID: projectID, database: database)
                return .init(source: source, revision: reused, reusedExistingRevision: true)
            }
            let sourceID = existing?.id ?? "pdocsrc_\(UUID().uuidString.lowercased())"
            let nextRevision = (existing?.currentRevision ?? 0) + 1
            let now = Date.now
            let directory = paths.root.appending(path: "documents", directoryHint: .isDirectory)
                .appending(path: Self.safePathComponent(projectID), directoryHint: .isDirectory)
                .appending(path: Self.safePathComponent(sourceID), directoryHint: .isDirectory)
                .appending(path: "revision-\(nextRevision)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let originalName = Self.safeFilename(artifact.name)
            let originalURL = directory.appending(path: originalName)
            var created: [URL] = [originalURL]
            do {
                try artifact.originalData.write(to: originalURL, options: .atomic)
                var assets = artifact.assets
                for index in assets.indices {
                    guard let payload = artifact.assetPayloads.first(where: { $0.sourcePath == assets[index].sourcePath }), let data = payload.data else { continue }
                    // Keep the Markdown attachment's relative path so a
                    // copied original remains usable in a portable export.
                    // Every component is sanitized and path traversal is
                    // removed before it is joined to the revision folder.
                    let relativeAssetPath = Self.safeRelativeAssetPath(payload.sourcePath, fallback: payload.suggestedFilename)
                    let assetURL = directory.appending(path: relativeAssetPath)
                    try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: assetURL, options: .atomic); created.append(assetURL)
                    assets[index].relativePath = paths.relativePath(for: assetURL)
                    assets[index].status = .copied
                }
                let originalRelativePath = paths.relativePath(for: originalURL)
                let revision = ProjectDocumentSourceRevision(sourceID: sourceID, projectID: projectID, revision: nextRevision,
                    contentHash: artifact.contentHash, extractionVersion: DocumentSourceImporter.extractionVersion,
                    originalRelativePath: originalRelativePath, status: artifact.status, units: artifact.units, assets: assets, errors: artifact.errors, createdAt: now)
                let encoded = try JSONEncoder().encode(revision)
                if existing == nil {
                    try database.execute(sql: "INSERT INTO project_document_sources(id,project_id,name,source_key,kind,current_revision,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                        arguments: [sourceID, projectID, artifact.name, artifact.sourceKey, artifact.kind.rawValue, nextRevision, now.timeIntervalSince1970, now.timeIntervalSince1970])
                } else {
                    try database.execute(sql: "UPDATE project_document_sources SET name=?,kind=?,current_revision=?,updated_at=? WHERE id=? AND project_id=?",
                        arguments: [artifact.name, artifact.kind.rawValue, nextRevision, now.timeIntervalSince1970, sourceID, projectID])
                }
                try database.execute(sql: "INSERT INTO project_document_source_revisions(id,source_id,project_id,revision,content_hash,extraction_version,original_relative_path,status,document,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    arguments: [revision.id, sourceID, projectID, nextRevision, artifact.contentHash, DocumentSourceImporter.extractionVersion, originalRelativePath, artifact.status.rawValue, encoded, now.timeIntervalSince1970])
                let savedSource = try Self.fetchSource(id: sourceID, projectID: projectID, database: database)
                return .init(source: savedSource, revision: revision, reusedExistingRevision: false)
            } catch {
                for url in created { try? FileManager.default.removeItem(at: url) }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }

    public func pendingDocumentImportJobs(projectID: String? = nil) throws -> [ProjectDocumentImportJob] {
        try pool.read { database in
            guard try Self.documentationSchemaAvailable(database) else { return [] }
            let rows: [Row]
            if let projectID {
                rows = try Row.fetchAll(database, sql: "SELECT * FROM project_document_import_jobs WHERE project_id=? AND status IN ('pending','processing','failed') ORDER BY updated_at,id", arguments: [projectID])
            } else {
                rows = try Row.fetchAll(database, sql: "SELECT * FROM project_document_import_jobs WHERE status IN ('pending','processing','failed') ORDER BY updated_at,id")
            }
            return rows.map { row in
                let attachmentPaths: [String] = (row.hasColumn("attachment_relative_paths") ? (row["attachment_relative_paths"] as Data?).flatMap { try? JSONDecoder().decode([String].self, from: $0) } : nil) ?? []
                return .init(id: row["id"], projectID: row["project_id"], sourceKey: row["source_key"], sourcePath: row["source_path"],
                    intakeRelativePath: row.hasColumn("intake_relative_path") ? row["intake_relative_path"] : nil,
                    attachmentRelativePaths: attachmentPaths,
                    checkpointRelativePath: row.hasColumn("checkpoint_relative_path") ? row["checkpoint_relative_path"] : nil,
                    contentHash: row.hasColumn("content_hash") ? row["content_hash"] : nil,
                    sourceID: row["source_id"], status: ProjectDocumentImportJobStatus(rawValue: row["status"]) ?? .failed,
                    error: row["error"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            }
        }
    }

    private func beginDocumentImportJob(projectID: String, sourceURL: URL, paths: LibraryPaths, selectedAttachments: [URL]) throws -> DocumentImportJobStart {
        let source = sourceURL.standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw ProjectDocumentImporterError.unreadableFile(source.lastPathComponent) }
        let kind = try DocumentSourceImporter.sourceKind(for: source)
        let sourceDirectory = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let jobID = "dimport_\(UUID().uuidString.lowercased())"
        let intakeDirectory = paths.root.appending(path: "documents", directoryHint: .isDirectory).appending(path: "_imports", directoryHint: .isDirectory).appending(path: Self.safePathComponent(jobID), directoryHint: .isDirectory)
        let intakeURL = intakeDirectory.appending(path: Self.safeFilename(source.lastPathComponent))
        let checkpointURL = intakeDirectory.appending(path: "checkpoint.json")
        var attachmentURLs: [URL] = []
        var attachmentRelativePaths: [String] = []
        do {
            try FileManager.default.createDirectory(at: intakeDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: intakeURL)
            if kind == .markdown {
                for selected in selectedAttachments {
                    let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(sourceDirectory.path + "/"), FileManager.default.isReadableFile(atPath: resolved.path) else {
                        throw ProjectDocumentationStoreError.invalidInput("Select Markdown attachments from the same folder as the Markdown file.")
                    }
                    let relative = String(resolved.path.dropFirst(sourceDirectory.path.count + 1))
                    let destination = intakeDirectory.appending(path: relative)
                    if attachmentRelativePaths.contains(relative) { continue }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: resolved, to: destination)
                    attachmentURLs.append(destination); attachmentRelativePaths.append(relative)
                }
            }
            let originalData = try Data(contentsOf: source)
            let sourceKey = source.path
            let intakeRelativePath = paths.relativePath(for: intakeURL)
            let checkpointRelativePath = paths.relativePath(for: checkpointURL)
            let encodedAttachments = try JSONEncoder().encode(attachmentRelativePaths)
            try pool.write { database in
                try Self.ensureDocumentImportJobColumns(in: database)
                try Self.requireDocumentationSchema(database); try Self.requireProject(projectID, in: database)
                try database.execute(sql: "INSERT INTO project_document_import_jobs(id,project_id,source_key,source_path,source_id,intake_relative_path,attachment_relative_paths,checkpoint_relative_path,content_hash,status,error,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                    arguments: [jobID, projectID, sourceKey, source.path, nil, intakeRelativePath, encodedAttachments, checkpointRelativePath, DocumentSourceImporter.sha256(originalData), ProjectDocumentImportJobStatus.processing.rawValue, nil, Date.now.timeIntervalSince1970])
            }
            return .init(id: jobID, projectID: projectID, sourceKey: sourceKey, sourcePath: source.path, intakeURL: intakeURL,
                selectedAttachmentURLs: attachmentURLs, checkpointURL: checkpointURL, intakeRelativePath: intakeRelativePath,
                attachmentRelativePaths: attachmentRelativePaths, checkpointRelativePath: checkpointRelativePath)
        } catch {
            try? FileManager.default.removeItem(at: intakeDirectory)
            throw error
        }
    }

    private func finishDocumentImportJob(id: String, status: ProjectDocumentImportJobStatus, sourceID: String?, contentHash: String?, error: String?) throws {
        try pool.write { database in
            guard try Self.documentationSchemaAvailable(database) else { return }
            try Self.ensureDocumentImportJobColumns(in: database)
            try database.execute(sql: "UPDATE project_document_import_jobs SET status=?,source_id=COALESCE(?,source_id),content_hash=COALESCE(?,content_hash),error=?,updated_at=? WHERE id=?",
                arguments: [status.rawValue, sourceID, contentHash, error, Date.now.timeIntervalSince1970, id])
        }
    }

    private func cleanupDocumentImportIntake(_ start: DocumentImportJobStart, paths: LibraryPaths) {
        cleanupDocumentImportIntake(at: start.intakeURL.deletingLastPathComponent(), paths: paths)
    }

    private func cleanupDocumentImportIntake(at directory: URL, paths: LibraryPaths) {
        let root = paths.root.standardizedFileURL.path
        let normalized = directory.standardizedFileURL.path
        guard normalized.hasPrefix(root + "/documents/_imports/") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func findRevision(projectID: String, contentHash: String, database: Database) throws -> ProjectDocumentSourceRevision? {
        guard let row = try Row.fetchOne(database, sql: "SELECT * FROM project_document_source_revisions WHERE project_id=? AND content_hash=? ORDER BY created_at DESC LIMIT 1", arguments: [projectID, contentHash]) else { return nil }
        return try sourceRevision(from: row)
    }

    static func fetchSource(id: String, projectID: String, database: Database) throws -> ProjectDocumentSource {
        guard let row = try Row.fetchOne(database, sql: "SELECT * FROM project_document_sources WHERE id=? AND project_id=?", arguments: [id, projectID]) else { throw ProjectDocumentationStoreError.sourceNotFound(id) }
        return source(from: row)
    }

    static func safePathComponent(_ value: String) -> String {
        let replaced = value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return replaced.isEmpty ? "item" : String(replaced.prefix(100))
    }

    static func safeFilename(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
        return safePathComponent(name)
    }

    static func safeRelativeAssetPath(_ value: String, fallback: String) -> String {
        guard !value.hasPrefix("/"), !value.hasPrefix("\\") else { return safeFilename(fallback) }
        let decoded = value.removingPercentEncoding ?? value
        var components: [String] = []
        for part in decoded.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() } else { return safeFilename(fallback) }
                continue
            }
            let safe = Self.safeFilenameComponent(String(part), fallback: "item")
            if !safe.isEmpty { components.append(safe) }
        }
        return components.isEmpty ? safeFilename(fallback) : components.joined(separator: "/")
    }

    /// Preserve user-visible Markdown attachment names, including spaces and
    /// Unicode, while removing control characters and path separators. The
    /// importer has already enforced same-folder, selected-file containment;
    /// this helper only creates a safe relative destination path.
    static func safeFilenameComponent(_ value: String, fallback: String) -> String {
        let filtered = String(value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "/" && scalar != "\\"
        })
        guard !filtered.isEmpty, filtered != ".", filtered != ".." else { return fallback }
        return String(filtered.prefix(255))
    }

    // MARK: Documentation revisions and proposals

    public func createDocumentationDraft(projectID: String, title: String, slug: String, markdown: String = "", sections: [ProjectDocumentationSection] = [], sourceSignature: String = "") throws -> ProjectDocumentation {
        try saveDocumentationDraft(.init(documentID: "pdoc_\(UUID().uuidString.lowercased())", projectID: projectID, expectedRevision: 0, title: title, slug: slug, markdown: markdown, sections: sections, sourceSignature: sourceSignature))
    }

    public func saveDocumentationDraft(_ draft: ProjectDocumentationDraft) throws -> ProjectDocumentation {
        try pool.write { database in
            try Self.requireDocumentationSchema(database); try Self.requireProject(draft.projectID, in: database)
            try Self.validateDocumentationPayload(title: draft.title, slug: draft.slug, markdown: draft.markdown, sections: draft.sections)
            try Self.validateDecisionOwnership(draft.sections, projectID: draft.projectID, db: database)
            try Self.validateEvidence(draft.sections.flatMap(\.evidence), projectID: draft.projectID, database: database)
            guard let existingRow = try Row.fetchOne(database, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [draft.documentID, draft.projectID]) else {
                guard draft.expectedRevision == 0 else { throw ProjectDocumentationStoreError.conflict }
                let document = ProjectDocumentation(id: draft.documentID, projectID: draft.projectID, title: draft.title, slug: draft.slug, currentRevision: 1, reviewedRevision: nil, markdown: draft.markdown, sections: draft.sections, sourceSignature: draft.sourceSignature)
                try Self.insertDocumentation(document, isManualEdit: true, database: database)
                return document
            }
            let current = try Self.documentation(from: existingRow)
            guard current.currentRevision == draft.expectedRevision else { throw ProjectDocumentationStoreError.conflict }
            var next = current
            next.title = draft.title; next.slug = draft.slug; next.currentRevision += 1; next.reviewedRevision = nil
            next.markdown = draft.markdown; next.sections = draft.sections; next.sourceSignature = draft.sourceSignature; next.updatedAt = .now
            try Self.insertDocumentationRevision(next, isManualEdit: true, database: database)
            try database.execute(sql: "UPDATE project_documentation SET slug=?,title=?,current_revision=?,reviewed_revision=NULL,document=?,updated_at=? WHERE id=? AND project_id=?",
                arguments: [next.slug, next.title, next.currentRevision, try JSONEncoder().encode(next), next.updatedAt.timeIntervalSince1970, next.id, next.projectID])
            return next
        }
    }

    public func proposeDocumentation(_ proposal: ProjectDocumentationProposal, requestID: String? = nil) throws -> ProjectDocumentationProposal {
        try pool.write { database in
            try Self.requireDocumentationSchema(database); try Self.requireProject(proposal.projectID, in: database)
            try Self.validateDocumentationPayload(title: proposal.title, slug: proposal.slug, markdown: proposal.markdown, sections: proposal.sections)
            try Self.validateDecisionOwnership(proposal.sections, projectID: proposal.projectID, db: database)
            let proposalID = requestID.map { "dproposal_\(Self.safePathComponent(proposal.projectID))_\(Self.safePathComponent($0))" } ?? proposal.id
            if let existing = try Row.fetchOne(database, sql: "SELECT * FROM project_documentation_proposals WHERE id=?", arguments: [proposalID]) {
                return try Self.proposal(from: existing)
            }
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [proposal.documentID, proposal.projectID]) else {
                guard proposal.expectedDocumentRevision == 0 else { throw ProjectDocumentationStoreError.documentNotFound(proposal.documentID) }
                // Document IDs are global library identifiers. A proposal
                // for a new document must not be allowed to reuse an ID that
                // already belongs to another project, because the app inbox
                // would otherwise accept an ambiguous document identity.
                guard try Row.fetchOne(database, sql: "SELECT id FROM project_documentation WHERE id=?", arguments: [proposal.documentID]) == nil else {
                    throw ProjectDocumentationStoreError.conflict
                }
                try Self.validateEvidence(proposal.evidence + proposal.sections.flatMap(\.evidence), projectID: proposal.projectID, database: database)
                var saved = proposal
                if proposalID != proposal.id { saved = Self.copyProposal(proposal, id: proposalID) }
                try Self.insertProposal(saved, database: database)
                return saved
            }
            let document = try Self.documentation(from: row)
            guard document.currentRevision == proposal.expectedDocumentRevision else {
                var stale = proposal; stale.isStale = true; stale.updatedAt = .now
                if proposalID != proposal.id { stale = Self.copyProposal(stale, id: proposalID) }
                try Self.insertProposal(stale, database: database)
                return stale
            }
            try Self.validateEvidence(proposal.evidence + proposal.sections.flatMap(\.evidence), projectID: proposal.projectID, database: database)
            var saved = proposal
            if proposalID != proposal.id { saved = Self.copyProposal(proposal, id: proposalID) }
            try Self.insertProposal(saved, database: database)
            return saved
        }
    }

    public func reviewDocumentationProposal(proposalID: String, decision: ProjectDocumentationReviewDecision, expectedDocumentRevision: Int? = nil) throws -> ProjectDocumentationProposal {
        try pool.write { database in
            try Self.requireDocumentationSchema(database)
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM project_documentation_proposals WHERE id=?", arguments: [proposalID]) else { throw ProjectDocumentationStoreError.proposalNotFound(proposalID) }
            var proposal = try Self.proposal(from: row)
            guard proposal.state == .pending else { return proposal }
            if proposal.isStale {
                if decision == .reject {
                    proposal.state = .rejected
                    proposal.updatedAt = .now
                    try Self.updateProposal(proposal, database: database)
                }
                return proposal
            }
            guard let docRow = try Row.fetchOne(database, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [proposal.documentID, proposal.projectID]) else {
                guard proposal.expectedDocumentRevision == 0 else { throw ProjectDocumentationStoreError.documentNotFound(proposal.documentID) }
                if decision == .accept {
                    do {
                        try Self.validateCurrentDocumentationEvidence(proposal.evidence + proposal.sections.flatMap(\.evidence), projectID: proposal.projectID, db: database)
                        try Self.validateCurrentDocumentationDecisions(proposal.sections, projectID: proposal.projectID, db: database)
                    }
                    catch {
                        proposal.isStale = true
                        proposal.updatedAt = .now
                        try Self.updateProposal(proposal, database: database)
                        return proposal
                    }
                    let document = ProjectDocumentation(
                        id: proposal.documentID,
                        projectID: proposal.projectID,
                        title: proposal.title,
                        slug: proposal.slug,
                        currentRevision: 1,
                        reviewedRevision: nil,
                        markdown: proposal.markdown,
                        sections: proposal.sections,
                        sourceSignature: proposal.sourceSignature,
                        updatedAt: .now
                    )
                    try Self.insertDocumentation(document, isManualEdit: false, database: database)
                    proposal.state = .accepted
                } else {
                    proposal.state = .rejected
                }
                proposal.updatedAt = .now
                try Self.updateProposal(proposal, database: database)
                return proposal
            }
            let document = try Self.documentation(from: docRow)
            if let expectedDocumentRevision, expectedDocumentRevision != document.currentRevision { throw ProjectDocumentationStoreError.conflict }
            guard document.currentRevision == proposal.expectedDocumentRevision else { proposal.isStale = true; proposal.updatedAt = .now; try Self.updateProposal(proposal, database: database); return proposal }
            if decision == .accept {
                do {
                    try Self.validateCurrentDocumentationEvidence(proposal.evidence + proposal.sections.flatMap(\.evidence), projectID: proposal.projectID, db: database)
                    try Self.validateCurrentDocumentationDecisions(proposal.sections, projectID: proposal.projectID, db: database)
                }
                catch {
                    proposal.isStale = true; proposal.updatedAt = .now
                    try Self.updateProposal(proposal, database: database)
                    return proposal
                }
                var next = document
                next.title = proposal.title; next.slug = proposal.slug; next.currentRevision += 1; next.reviewedRevision = nil
                next.markdown = proposal.markdown; next.sections = proposal.sections; next.sourceSignature = proposal.sourceSignature; next.updatedAt = .now
                try Self.insertDocumentationRevision(next, isManualEdit: false, database: database)
                try database.execute(sql: "UPDATE project_documentation SET slug=?,title=?,current_revision=?,reviewed_revision=NULL,document=?,updated_at=? WHERE id=? AND project_id=?",
                    arguments: [next.slug, next.title, next.currentRevision, try JSONEncoder().encode(next), next.updatedAt.timeIntervalSince1970, next.id, next.projectID])
                proposal.state = .accepted
            } else { proposal.state = .rejected }
            proposal.updatedAt = .now
            try Self.updateProposal(proposal, database: database)
            return proposal
        }
    }

    public func reviewDocumentation(documentID: String, projectID: String, expectedRevision: Int) throws -> ProjectDocumentation {
        try pool.write { database in
            try Self.requireDocumentationSchema(database)
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [documentID, projectID]) else { throw ProjectDocumentationStoreError.documentNotFound(documentID) }
            var document = try Self.documentation(from: row)
            guard document.currentRevision == expectedRevision else { throw ProjectDocumentationStoreError.conflict }
            try Self.validateCurrentDocumentationEvidence(document.sections.flatMap(\.evidence), projectID: projectID, db: database)
            try Self.validateCurrentDocumentationDecisions(document.sections, projectID: projectID, db: database)
            document.reviewedRevision = document.currentRevision
            document.updatedAt = .now
            try database.execute(sql: "UPDATE project_documentation SET reviewed_revision=?,document=?,updated_at=? WHERE id=? AND project_id=?", arguments: [document.reviewedRevision, try JSONEncoder().encode(document), document.updatedAt.timeIntervalSince1970, documentID, projectID])
            return document
        }
    }

    public func saveProjectDecision(_ decision: ProjectDecision, expectedRevision: Int? = nil) throws -> ProjectDecision {
        try pool.write { database in
            try Self.requireDocumentationSchema(database); try Self.requireProject(decision.projectID, in: database)
            try Self.validateEvidence(decision.evidence, projectID: decision.projectID, database: database)
            if decision.state == .confirmed { try Self.validateCurrentDocumentationEvidence(decision.evidence, projectID: decision.projectID, db: database) }
            if let row = try Row.fetchOne(database, sql: "SELECT * FROM project_decisions WHERE id=? AND project_id=?", arguments: [decision.id, decision.projectID]) {
                let current = try Self.decision(from: row)
                if let expectedRevision, current.revision != expectedRevision { throw ProjectDocumentationStoreError.conflict }
                var next = decision; next.revision = current.revision + 1; next.updatedAt = .now
                try database.execute(sql: "UPDATE project_decisions SET revision=?,document=?,updated_at=? WHERE id=? AND project_id=?", arguments: [next.revision, try JSONEncoder().encode(next), next.updatedAt.timeIntervalSince1970, next.id, next.projectID])
                try Self.invalidateDecisionDependents(next, db: database)
                return next
            }
            guard expectedRevision == nil || expectedRevision == 0 else { throw ProjectDocumentationStoreError.conflict }
            try database.execute(sql: "INSERT INTO project_decisions(id,project_id,revision,document,updated_at) VALUES(?,?,?,?,?)", arguments: [decision.id, decision.projectID, decision.revision, try JSONEncoder().encode(decision), decision.updatedAt.timeIntervalSince1970])
            return decision
        }
    }

    public func saveQuestionGroupProposal(_ group: ProjectQuestionGroupProposal) throws -> ProjectQuestionGroupProposal {
        try pool.write { database in
            try Self.requireDocumentationSchema(database); try Self.requireProject(group.projectID, in: database)
            if let existing = try Row.fetchOne(database, sql: "SELECT project_id FROM project_question_group_proposals WHERE id=?", arguments: [group.id]),
               (existing["project_id"] as String) != group.projectID {
                throw ProjectDocumentationStoreError.conflict
            }
            try database.execute(sql: "INSERT INTO project_question_group_proposals(id,project_id,state,document,created_at,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,document=excluded.document,updated_at=excluded.updated_at",
                arguments: [group.id, group.projectID, group.state.rawValue, try JSONEncoder().encode(group), group.createdAt.timeIntervalSince1970, group.updatedAt.timeIntervalSince1970])
            return group
        }
    }

    // MARK: Evidence ownership and stale detection

    static func validateDocumentationPayload(title: String, slug: String, markdown: String, sections: [ProjectDocumentationSection]) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...300).contains(trimmedTitle.count) else { throw ProjectDocumentationStoreError.invalidInput("Documentation title must contain 1 to 300 characters.") }
        guard (1...200).contains(trimmedSlug.count) else { throw ProjectDocumentationStoreError.invalidInput("Documentation slug must contain 1 to 200 characters.") }
        guard markdown.utf8.count <= 1_000_000 else { throw ProjectDocumentationStoreError.invalidInput("Documentation Markdown is too large to save.") }
        guard sections.count <= 500 else { throw ProjectDocumentationStoreError.invalidInput("Documentation cannot contain more than 500 sections.") }
        var sectionIDs = Set<String>()
        for section in sections {
            guard (1...200).contains(section.id.count), sectionIDs.insert(section.id).inserted else { throw ProjectDocumentationStoreError.invalidInput("Documentation section IDs must be unique and contain 1 to 200 characters.") }
            guard (1...300).contains(section.title.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw ProjectDocumentationStoreError.invalidInput("Documentation section titles must contain 1 to 300 characters.") }
            guard section.body.utf8.count <= 200_000 else { throw ProjectDocumentationStoreError.invalidInput("A documentation section is too large to save.") }
            guard section.evidence.count <= 500, section.decisionIDs.count <= 200 else { throw ProjectDocumentationStoreError.invalidInput("A documentation section contains too many citations or decisions.") }
        }
    }

    static func validateEvidence(_ references: [ProjectEvidenceReference], projectID: String, database: Database) throws {
        for reference in references {
            switch reference {
            case .recording(let videoID, let revision, let timestamp, let evidenceID):
                guard let video = try VideoContextStore.fetchVideo(id: videoID, from: database) else { throw ProjectDocumentationStoreError.invalidEvidence("Recording \(videoID) no longer exists.") }
                guard video.projectID == projectID else { throw ProjectDocumentationStoreError.invalidEvidence("Recording \(videoID) belongs to another project.") }
                guard timestamp.isFinite, timestamp >= 0, timestamp <= video.duration else { throw ProjectDocumentationStoreError.invalidEvidence("Recording timestamp \(timestamp) is outside \(videoID)'s duration.") }
                let transcript = try Self.transcriptSegments(video: video, revision: revision, database: database)
                let evidence = try Self.evidenceItems(video: video, revision: revision, database: database)
                if let evidenceID {
                    let evidenceMatch = evidence.first { $0.id == evidenceID }
                    let transcriptMatch = transcript.first { $0.id == evidenceID }
                    guard evidenceMatch != nil || transcriptMatch != nil else {
                        throw ProjectDocumentationStoreError.invalidEvidence("Recording evidence or transcript segment \(evidenceID) is unavailable at the cited revision.")
                    }
                    if let evidenceMatch {
                        guard abs(evidenceMatch.timestamp - timestamp) < 0.01 else { throw ProjectDocumentationStoreError.invalidEvidence("Recording evidence \(evidenceID) does not match the cited timestamp.") }
                    }
                    if let transcriptMatch {
                        guard timestamp >= transcriptMatch.start - 0.01 && timestamp <= transcriptMatch.end + 0.01 else { throw ProjectDocumentationStoreError.invalidEvidence("Transcript segment \(evidenceID) does not contain the cited timestamp.") }
                    }
                } else {
                    let hasTranscript = transcript.contains { $0.start <= timestamp && $0.end >= timestamp }
                    let hasEvidence = evidence.contains { abs($0.timestamp - timestamp) < 0.01 }
                    guard hasTranscript || hasEvidence else { throw ProjectDocumentationStoreError.invalidEvidence("Recording timestamp \(timestamp) has no transcript or screenshot evidence at the cited revision.") }
                }
            case .feedback(let batchID, let revision, let commentID, let sourceID):
                guard let batch = try Self.feedbackBatch(batchID: batchID, revision: revision, database: database), batch.projectID == projectID else {
                    throw ProjectDocumentationStoreError.invalidEvidence("Feedback batch \(batchID) is not owned by this project.")
                }
                let batchWideSources = Set(batch.batchWideSourceIDs)
                if let commentID {
                    guard let comment = batch.comments.first(where: { $0.id == commentID }) else {
                        throw ProjectDocumentationStoreError.invalidEvidence("Feedback comment \(commentID) no longer exists.")
                    }
                    if let sourceID {
                        let commentSources = Set(comment.sourceIDs).union(batchWideSources)
                        guard commentSources.contains(sourceID), batch.sources.contains(where: { $0.id == sourceID }) else {
                            throw ProjectDocumentationStoreError.invalidEvidence("Feedback source \(sourceID) is not linked to comment \(commentID) or the batch-wide evidence.")
                        }
                    }
                } else if let sourceID {
                    guard batchWideSources.contains(sourceID), batch.sources.contains(where: { $0.id == sourceID }) else {
                        throw ProjectDocumentationStoreError.invalidEvidence("Feedback source \(sourceID) is not batch-wide evidence.")
                    }
                }
            case .document(let sourceID, let revision, let locator):
                guard let source = try Row.fetchOne(database, sql: "SELECT * FROM project_document_sources WHERE id=? AND project_id=?", arguments: [sourceID, projectID]) else { throw ProjectDocumentationStoreError.invalidEvidence("Document source \(sourceID) is not owned by this project.") }
                guard let sourceRevision = try Self.sourceRevision(sourceID: sourceID, revision: revision, database: database) else { throw ProjectDocumentationStoreError.invalidEvidence("Document source revision \(sourceID):r\(revision) no longer exists.") }
                guard sourceRevision.projectID == projectID else { throw ProjectDocumentationStoreError.invalidEvidence("Document source \(sourceID) belongs to another project.") }
                guard sourceRevision.isUsable else { throw ProjectDocumentationStoreError.invalidEvidence("Document source revision \(sourceID):r\(revision) is not readable.") }
                let sourceName: String = source["name"]
                guard Self.locatorExists(locator, in: sourceRevision) else { throw ProjectDocumentationStoreError.invalidEvidence("The evidence locator \(locator.displayValue) is not present in document source \(sourceName).") }
            case .reviewedDocumentation(let documentID, let revision, let sectionID):
                guard let document = try Row.fetchOne(database, sql: "SELECT project_id FROM project_documentation WHERE id=?", arguments: [documentID]),
                      document["project_id"] as String == projectID else {
                    throw ProjectDocumentationStoreError.invalidEvidence("Project documentation \(documentID) is not owned by this project.")
                }
                guard let frozen = try documentationRevision(documentID: documentID, revision: revision, projectID: projectID, database: database) else {
                    throw ProjectDocumentationStoreError.invalidEvidence("Project documentation revision \(documentID):r\(revision) no longer exists.")
                }
                if let sectionID, !frozen.sections.contains(where: { $0.id == sectionID }) {
                    throw ProjectDocumentationStoreError.invalidEvidence("Project documentation section \(sectionID) is unavailable at revision \(revision).")
                }
            }
        }
    }

    static func validateFreshDocumentationEvidence(_ references: [ProjectEvidenceReference], projectID: String, database: Database) throws {
        try validateEvidence(references, projectID: projectID, database: database)
        try validateCurrentDocumentAssets(references, projectID: projectID, database: database)
        for reference in references {
            switch reference {
            case .recording(let videoID, let revision, _, _):
                guard let video = try fetchVideo(id: videoID, from: database), video.revisions == revision else { throw ProjectDocumentationStoreError.invalidEvidence("Recording evidence is stale. Refresh the documentation proposal before reviewing it.") }
            case .feedback(let batchID, let revision, _, _):
                guard let batch = try Self.feedbackBatch(batchID: batchID, revision: revision, database: database), batch.revision == revision else { throw ProjectDocumentationStoreError.invalidEvidence("Feedback evidence is stale. Refresh the documentation proposal before reviewing it.") }
            case .document(let sourceID, let revision, _):
                guard let row = try Row.fetchOne(database, sql: "SELECT current_revision,project_id FROM project_document_sources WHERE id=?", arguments: [sourceID]),
                      (row["project_id"] as String) == projectID,
                      (row["current_revision"] as Int) == revision else { throw ProjectDocumentationStoreError.invalidEvidence("Document evidence is stale. Refresh the documentation proposal before reviewing it.") }
            case .reviewedDocumentation(let documentID, let revision, _):
                guard let row = try Row.fetchOne(database, sql: "SELECT current_revision,reviewed_revision,project_id FROM project_documentation WHERE id=?", arguments: [documentID]),
                      (row["project_id"] as String) == projectID,
                      (row["current_revision"] as Int) == revision,
                      (row["reviewed_revision"] as Int?) == revision else {
                    throw ProjectDocumentationStoreError.invalidEvidence("Reviewed project documentation is stale. Review its current revision before reviewing this work.")
                }
            }
        }
    }

    /// Read a recording artifact at the revision carried by a citation. The
    /// current row is used only when its stage revision matches. Older stages
    /// come from the additive history table, so a later processing run cannot
    /// silently replace a cited screenshot or transcript.
    static func transcriptSegments(video: VideoRecord, revision: ArtifactRevision, database: Database) throws -> [TranscriptSegment] {
        if video.revisions.transcript == revision.transcript {
            return try Row.fetchAll(database, sql: "SELECT * FROM transcript_segments WHERE video_id=? ORDER BY start_time,id", arguments: [video.id]).map(transcript(from:))
        }
        guard try database.tableExists("source_artifact_history"),
              let data = try Data.fetchOne(database, sql: "SELECT artifact_data FROM source_artifact_history WHERE video_id=? AND stage=? AND revision=?", arguments: [video.id, SourceArtifactHistoryStage.transcript.rawValue, revision.transcript]) else {
            throw ProjectDocumentationStoreError.invalidEvidence("Transcript revision \(revision.transcript) for recording \(video.id) is unavailable.")
        }
        guard let values = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else {
            throw ProjectDocumentationStoreError.invalidEvidence("Transcript revision \(revision.transcript) for recording \(video.id) is unreadable.")
        }
        return values
    }

    static func evidenceItems(video: VideoRecord, revision: ArtifactRevision, database: Database) throws -> [EvidenceItem] {
        if video.revisions.evidence == revision.evidence {
            return try Row.fetchAll(database, sql: "SELECT * FROM evidence_items WHERE video_id=? ORDER BY timestamp,id", arguments: [video.id]).map(evidence(from:))
        }
        guard try database.tableExists("source_artifact_history"),
              let data = try Data.fetchOne(database, sql: "SELECT artifact_data FROM source_artifact_history WHERE video_id=? AND stage=? AND revision=?", arguments: [video.id, SourceArtifactHistoryStage.evidence.rawValue, revision.evidence]) else {
            throw ProjectDocumentationStoreError.invalidEvidence("Screenshot revision \(revision.evidence) for recording \(video.id) is unavailable.")
        }
        guard let values = try? JSONDecoder().decode([EvidenceItem].self, from: data) else {
            throw ProjectDocumentationStoreError.invalidEvidence("Screenshot revision \(revision.evidence) for recording \(video.id) is unreadable.")
        }
        return values
    }

    static func feedbackBatch(batchID: String, revision: Int, database: Database) throws -> FeedbackBatch? {
        guard let data = try Data.fetchOne(database, sql: "SELECT document FROM feedback_batches WHERE id=?", arguments: [batchID]),
              let current = try? JSONDecoder().decode(FeedbackBatch.self, from: data) else { return nil }
        if current.revision == revision { return current }
        guard try database.tableExists("feedback_source_history"),
              let historical = try Data.fetchOne(database, sql: "SELECT document FROM feedback_source_history WHERE batch_id=? AND revision=?", arguments: [batchID, revision]) else { return nil }
        return try? JSONDecoder().decode(FeedbackBatch.self, from: historical)
    }

    static func locatorExists(_ locator: ProjectDocumentLocator, in revision: ProjectDocumentSourceRevision) -> Bool {
        switch locator.kind {
        case .pdfPage, .markdownLine, .unit:
            return revision.units.contains { unit in
                if locator.kind == .unit { return locator.value == unit.id }
                return unit.locator.kind == locator.kind &&
                    unit.locator.page == locator.page &&
                    unit.locator.startLine == locator.startLine &&
                    unit.locator.endLine == locator.endLine
            }
        case .heading:
            return revision.units.contains { $0.title == locator.value }
        case .asset:
            return revision.assets.contains { $0.sourcePath == locator.value || $0.relativePath == locator.value }
        }
    }

    /// A document revision can retain a locator for an external, missing, or
    /// failed image so historical evidence remains addressable. Current
    /// review requires the image to have been selected and copied into the
    /// library, with the stored relative path needed by exports and MCP reads.
    static func validateCurrentDocumentAssets(_ references: [ProjectEvidenceReference], projectID: String, database: Database) throws {
        for reference in references {
            guard case .document(let sourceID, let revision, let locator) = reference,
                  locator.kind == .asset else { continue }
            guard let sourceRevision = try sourceRevision(sourceID: sourceID, revision: revision, database: database), sourceRevision.projectID == projectID else {
                throw ProjectDocumentationStoreError.invalidEvidence("Document asset \(locator.displayValue) is unavailable. Select and import the asset again before reviewing this documentation.")
            }
            let asset = sourceRevision.assets.first { $0.sourcePath == locator.value || $0.relativePath == locator.value }
            guard let asset,
                  asset.status == .copied,
                  let relativePath = asset.relativePath,
                  !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectDocumentationStoreError.invalidEvidence("Document asset \(locator.displayValue) is not copied into the project library. Select and import the asset before reviewing this documentation.")
            }
        }
    }

    public func validateEvidenceReference(_ reference: ProjectEvidenceReference, projectID: String) throws -> ProjectEvidenceValidation {
        try pool.read { database in
            try Self.validateEvidence([reference], projectID: projectID, database: database)
            switch reference {
            case .recording(let videoID, let revision, _, _):
                guard let current = try Self.fetchVideo(id: videoID, from: database) else { return .init(reference: reference, status: .missing, message: "Recording no longer exists.") }
                return .init(reference: reference, status: current.revisions == revision ? .valid : .stale, message: current.revisions == revision ? nil : "The recording has newer transcript or evidence revisions.")
            case .feedback(let batchID, let revision, _, _):
                guard let data = try Data.fetchOne(database, sql: "SELECT document FROM feedback_batches WHERE id=?", arguments: [batchID]), let batch = try? JSONDecoder().decode(FeedbackBatch.self, from: data) else { return .init(reference: reference, status: .missing, message: "Feedback batch no longer exists.") }
                return .init(reference: reference, status: batch.revision == revision ? .valid : .stale, message: batch.revision == revision ? nil : "The feedback batch has newer revisions.")
            case .document(let sourceID, let revision, _):
                guard let sourceRevision = try Self.sourceRevision(sourceID: sourceID, revision: revision, database: database),
                      let sourceRow = try Row.fetchOne(database, sql: "SELECT * FROM project_document_sources WHERE id=? AND project_id=?", arguments: [sourceID, projectID]) else {
                    return .init(reference: reference, status: .missing, message: "Document revision no longer exists.")
                }
                let currentRevision: Int = sourceRow["current_revision"]
                if case .document(_, _, let locator) = reference, locator.kind == .asset {
                    let asset = sourceRevision.assets.first { $0.sourcePath == locator.value || $0.relativePath == locator.value }
                    guard let asset else {
                        return .init(reference: reference, status: .missing, message: "The document asset is no longer available.")
                    }
                    guard asset.status == .copied,
                          let relativePath = asset.relativePath,
                          !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return .init(reference: reference, status: .missing, message: asset.error ?? "The document asset was not copied into the project library.")
                    }
                }
                if sourceRevision.status == .failed || !sourceRevision.isUsable {
                    return .init(reference: reference, status: .stale, message: "This source revision failed extraction.")
                }
                guard currentRevision == revision else {
                    return .init(reference: reference, status: .stale, message: "The document source has a newer revision.")
                }
                return .init(reference: reference, status: .valid)
            case .reviewedDocumentation(let documentID, let revision, let sectionID):
                guard let row = try Row.fetchOne(database, sql: "SELECT current_revision,reviewed_revision,project_id FROM project_documentation WHERE id=?", arguments: [documentID]),
                      row["project_id"] as String == projectID,
                      let frozen = try Self.documentationRevision(documentID: documentID, revision: revision, projectID: projectID, database: database) else {
                    return .init(reference: reference, status: .missing, message: "Reviewed project documentation revision no longer exists.")
                }
                if let sectionID, !frozen.sections.contains(where: { $0.id == sectionID }) {
                    return .init(reference: reference, status: .missing, message: "The reviewed project documentation section no longer exists at this revision.")
                }
                let currentRevision: Int = row["current_revision"]
                let reviewedRevision: Int? = row["reviewed_revision"]
                let current = currentRevision == revision && reviewedRevision == revision
                return .init(reference: reference, status: current ? .valid : .stale,
                             message: current ? nil : "The project documentation has a newer or unreviewed revision.")
            }
        }
    }

    // MARK: Private writes

    static func insertDocumentation(_ document: ProjectDocumentation, isManualEdit: Bool, database: Database) throws {
        try database.execute(sql: "INSERT INTO project_documentation(id,project_id,slug,title,current_revision,reviewed_revision,document,updated_at) VALUES(?,?,?,?,?,?,?,?)",
            arguments: [document.id, document.projectID, document.slug, document.title, document.currentRevision, document.reviewedRevision, try JSONEncoder().encode(document), document.updatedAt.timeIntervalSince1970])
        try insertDocumentationRevision(document, isManualEdit: isManualEdit, database: database)
    }

    static func insertDocumentationRevision(_ document: ProjectDocumentation, isManualEdit: Bool, database: Database) throws {
        let revision = ProjectDocumentationRevision(documentID: document.id, projectID: document.projectID, revision: document.currentRevision, title: document.title, slug: document.slug, markdown: document.markdown, sections: document.sections, sourceSignature: document.sourceSignature, isManualEdit: isManualEdit, createdAt: document.updatedAt)
        try database.execute(sql: "INSERT INTO project_documentation_revisions(id,document_id,project_id,revision,document,created_at) VALUES(?,?,?,?,?,?)",
            arguments: [revision.id, document.id, document.projectID, revision.revision, try JSONEncoder().encode(revision), revision.createdAt.timeIntervalSince1970])
    }

    static func insertProposal(_ proposal: ProjectDocumentationProposal, database: Database) throws {
        try database.execute(sql: "INSERT INTO project_documentation_proposals(id,project_id,document_id,expected_revision,state,stale,document,diff,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
            arguments: [proposal.id, proposal.projectID, proposal.documentID, proposal.expectedDocumentRevision, proposal.state.rawValue, proposal.isStale, try JSONEncoder().encode(proposal), try JSONEncoder().encode(proposal.diff), proposal.createdAt.timeIntervalSince1970, proposal.updatedAt.timeIntervalSince1970])
    }

    static func updateProposal(_ proposal: ProjectDocumentationProposal, database: Database) throws {
        try database.execute(sql: "UPDATE project_documentation_proposals SET state=?,stale=?,document=?,updated_at=? WHERE id=? AND project_id=?",
            arguments: [proposal.state.rawValue, proposal.isStale, try JSONEncoder().encode(proposal), proposal.updatedAt.timeIntervalSince1970, proposal.id, proposal.projectID])
    }

    static func copyProposal(_ proposal: ProjectDocumentationProposal, id: String) -> ProjectDocumentationProposal {
        .init(id: id, projectID: proposal.projectID, documentID: proposal.documentID, expectedDocumentRevision: proposal.expectedDocumentRevision, title: proposal.title, slug: proposal.slug, markdown: proposal.markdown, sections: proposal.sections, diff: proposal.diff, sourceSignature: proposal.sourceSignature, evidence: proposal.evidence, state: proposal.state, isStale: proposal.isStale, createdAt: proposal.createdAt, updatedAt: proposal.updatedAt)
    }
}
