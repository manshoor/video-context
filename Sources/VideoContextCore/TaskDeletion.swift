import Foundation
import CryptoKit
import GRDB

/// The source kind used by the deletion ledger. This is deliberately separate
/// from `ProjectSourceReference` so the SQLite representation remains stable
/// if the workspace gains more source types later.
public enum TaskDeletionSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case recording
    case feedback

    init(source: ProjectSourceReference) {
        switch source {
        case .recording: self = .recording
        case .feedback: self = .feedback
        }
    }
}

/// The revision of the source that was shown to the user before deletion.
/// Recordings have three artifact revisions; feedback has one batch revision.
public enum TaskDeletionSourceRevision: Codable, Equatable, Sendable {
    case recording(ArtifactRevision)
    case feedback(Int)
}

public struct TaskGenerationExclusion: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let sourceKind: TaskDeletionSourceKind
    public let sourceID: String
    /// A stable issue/evidence identity. It never uses the task title.
    public let identityKey: String
    public let reason: String
    public let createdAt: Date

    public var id: String { "\(sourceKind.rawValue):\(sourceID):\(identityKey)" }

    init(sourceKind: TaskDeletionSourceKind, sourceID: String, identityKey: String,
         reason: String, createdAt: Date = .now) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.identityKey = identityKey
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct TaskDeletionPreview: Codable, Equatable, Sendable, Identifiable {
    public let reference: ProjectTaskReference
    public let title: String
    public let expectedRevision: Int
    public let expectedSourceRevision: TaskDeletionSourceRevision
    public let archived: Bool
    public let reviewed: Bool
    public let exclusion: TaskGenerationExclusion

    public var id: String { reference.id }
}

public struct ProjectTaskDeletionPreview: Codable, Equatable, Sendable {
    public let projectID: String?
    public let tasks: [TaskDeletionPreview]
    public let signature: String

    public var isEmpty: Bool { tasks.isEmpty }
}

extension VideoContextStore {
    /// Schema for permanent task deletion. The migration intentionally uses
    /// source IDs instead of foreign keys because Inbox/legacy libraries can
    /// contain sources whose project ownership has not migrated yet.
    static func createTaskDeletionSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS task_deletion_tombstones(
                task_id TEXT PRIMARY KEY,
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                identity_key TEXT NOT NULL,
                deleted_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS task_deletion_tombstones_source
                ON task_deletion_tombstones(source_kind, source_id);
            CREATE TABLE IF NOT EXISTS task_generation_exclusions(
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                identity_key TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY(source_kind, source_id, identity_key)
            );
            CREATE INDEX IF NOT EXISTS task_generation_exclusions_source
                ON task_generation_exclusions(source_kind, source_id);
            CREATE TABLE IF NOT EXISTS task_generation_epochs(
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                PRIMARY KEY(source_kind, source_id)
            );
            CREATE TABLE IF NOT EXISTS task_generation_cache_sources(
                cache_key TEXT PRIMARY KEY,
                source_kind TEXT NOT NULL,
                source_id TEXT NOT NULL,
                epoch INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS task_generation_cache_sources_source
                ON task_generation_cache_sources(source_kind, source_id);
            """)
    }

    // MARK: Stable generation identities

    /// Recording tasks did not historically carry a stable issue or
    /// requirement ID. An evidence hash is unsafe here: a later generator can
    /// cite a subset, a different frame, or a newer source revision and still
    /// recreate the deleted requirement. Keep the exclusion source-wide until
    /// the user explicitly reconciles the source with Allow generation again.
    static func recordingGenerationIdentity(_ content: TaskContent,
                                            generatedOriginal: TaskContent? = nil) -> String {
        _ = content
        _ = generatedOriginal
        return "source-wide"
    }

    static func feedbackGenerationIdentity(issueID: String?, content: TaskContent) -> String {
        if let issueID, !issueID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "issue:\(issueID)"
        }
        // Feedback batches without a stable issue ID are ambiguous. Evidence
        // hashes can change when a comment is edited or a source is replaced,
        // so keep the source-wide gate until the user explicitly reconciles it.
        _ = content
        return "source-wide"
    }

    static func taskGenerationIdentity(_ task: VideoTask) -> String {
        recordingGenerationIdentity(task.content, generatedOriginal: task.generatedOriginal)
    }

    static func taskGenerationIdentity(_ task: FeedbackTask) -> String {
        feedbackGenerationIdentity(issueID: task.issueID,
                                   content: task.generatedOriginal ?? task.content)
    }

    // MARK: Source ownership and rows

    private static func sourceValues(_ source: ProjectSourceReference) -> (TaskDeletionSourceKind, String) {
        switch source {
        case .recording(let id): (.recording, id)
        case .feedback(let id): (.feedback, id)
        }
    }

    private static func projectIDColumnExists(in db: Database) throws -> Bool {
        guard try db.tableExists("videos") else { return false }
        return try db.columns(in: "videos").contains(where: { $0.name == "project_id" })
    }

    private static func verifyProjectOwnership(projectID: String?, source: ProjectSourceReference,
                                               db: Database) throws {
        switch source {
        case .recording(let videoID):
            guard let video = try fetchVideo(id: videoID, from: db) else { throw TaskContextError.missing(videoID) }
            guard try projectIDColumnExists(in: db) || projectID == nil else {
                throw TaskContextError.invalid("Project ownership migration is required before deleting a project task.")
            }
            if try projectIDColumnExists(in: db) {
                guard video.projectID == projectID else { throw TaskContextError.conflict }
            }
        case .feedback(let batchID):
            let batch = try feedbackBatch(batchID, in: db)
            guard batch.projectID == projectID else { throw TaskContextError.conflict }
        }
    }

    private static func taskDeletionPreview(projectID: String?, reference: ProjectTaskReference,
                                             db: Database) throws -> TaskDeletionPreview {
        try verifyProjectOwnership(projectID: projectID, source: reference.source, db: db)
        switch reference {
        case .recording(let videoID, let taskID):
            guard let video = try fetchVideo(id: videoID, from: db),
                  let task = try fetchTasks(videoID: videoID, db: db).first(where: { $0.id == taskID }) else {
                throw TaskContextError.missing(taskID)
            }
            return .init(reference: reference, title: task.content.title,
                         expectedRevision: task.revision,
                         expectedSourceRevision: .recording(video.revisions),
                         archived: task.archived,
                         reviewed: task.reviewedRevision == task.revision,
                         exclusion: .init(sourceKind: .recording, sourceID: videoID,
                                          identityKey: taskGenerationIdentity(task),
                                          reason: "Source needs reconciliation before generation can publish another task. Choose Allow generation again after resolving the deleted task."))
        case .feedback(let batchID, let taskID):
            let batch = try feedbackBatch(batchID, in: db)
            guard let task = try feedbackTasks(batchID, in: db).first(where: { $0.id == taskID }) else {
                throw TaskContextError.missing(taskID)
            }
            return .init(reference: reference, title: task.content.title,
                         expectedRevision: task.revision,
                         expectedSourceRevision: .feedback(batch.revision),
                         archived: task.archived,
                         reviewed: task.approvedRevision == task.revision,
                         exclusion: .init(sourceKind: .feedback, sourceID: batchID,
                                          identityKey: taskGenerationIdentity(task),
                                          reason: "Task was permanently deleted."))
        }
    }

    private static func deletionSignature(projectID: String?, tasks: [TaskDeletionPreview]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(ProjectTaskDeletionPreviewPayload(
            projectID: projectID,
            tasks: tasks.sorted { $0.id < $1.id }.map {
                .init(reference: $0.reference, title: $0.title, expectedRevision: $0.expectedRevision,
                      expectedSourceRevision: $0.expectedSourceRevision, archived: $0.archived,
                      reviewed: $0.reviewed, identityKey: $0.exclusion.identityKey)
            }))
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private struct ProjectTaskDeletionPreviewPayload: Codable, Sendable {
        let projectID: String?
        let tasks: [TaskDeletionSignatureItem]
    }

    private struct TaskDeletionSignatureItem: Codable, Sendable {
        let reference: ProjectTaskReference
        let title: String
        let expectedRevision: Int
        let expectedSourceRevision: TaskDeletionSourceRevision
        let archived: Bool
        let reviewed: Bool
        let identityKey: String
    }

    public func previewProjectTaskDeletion(projectID: String?, selected: Set<ProjectTaskReference>) throws -> ProjectTaskDeletionPreview {
        guard !selected.isEmpty else { throw TaskContextError.invalid("Select at least one task to delete.") }
        return try pool.read { db in
            let tasks = try selected.map { try Self.taskDeletionPreview(projectID: projectID, reference: $0, db: db) }
            return try .init(projectID: projectID, tasks: tasks.sorted { $0.id < $1.id },
                             signature: Self.deletionSignature(projectID: projectID, tasks: tasks))
        }
    }

    public func previewTaskDeletion(projectID: String?, reference: ProjectTaskReference) throws -> TaskDeletionPreview {
        try pool.read { try Self.taskDeletionPreview(projectID: projectID, reference: reference, db: $0) }
    }

    private static func taskMatches(_ preview: TaskDeletionPreview, db: Database) throws -> Bool {
        switch preview.reference {
        case .recording(let videoID, let taskID):
            guard let video = try fetchVideo(id: videoID, from: db),
                  case .recording(let sourceRevision) = preview.expectedSourceRevision,
                  video.revisions == sourceRevision,
                  let task = try fetchTasks(videoID: videoID, db: db).first(where: { $0.id == taskID }) else { return false }
            return task.revision == preview.expectedRevision && taskGenerationIdentity(task) == preview.exclusion.identityKey
        case .feedback(let batchID, let taskID):
            guard let batch = try? feedbackBatch(batchID, in: db),
                  case .feedback(let sourceRevision) = preview.expectedSourceRevision,
                  batch.revision == sourceRevision,
                  let task = try feedbackTasks(batchID, in: db).first(where: { $0.id == taskID }) else { return false }
            return task.revision == preview.expectedRevision && taskGenerationIdentity(task) == preview.exclusion.identityKey
        }
    }

    static func isTaskDeleted(_ taskID: String, db: Database) throws -> Bool {
        guard try db.tableExists("task_deletion_tombstones") else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task_deletion_tombstones WHERE task_id=?)", arguments: [taskID]) ?? false
    }

    static func taskGenerationEpoch(source: ProjectSourceReference, db: Database) throws -> Int {
        guard try db.tableExists("task_generation_epochs") else { return 0 }
        let values = sourceValues(source)
        return try Int.fetchOne(db, sql: "SELECT epoch FROM task_generation_epochs WHERE source_kind=? AND source_id=?",
                                arguments: [values.0.rawValue, values.1]) ?? 0
    }

    public func taskGenerationEpoch(source: ProjectSourceReference) throws -> Int {
        try pool.read { try Self.taskGenerationEpoch(source: source, db: $0) }
    }

    private static func advanceTaskGenerationEpoch(source: ProjectSourceReference, db: Database) throws {
        guard try db.tableExists("task_generation_epochs") else { return }
        let values = sourceValues(source)
        try db.execute(sql: """
            INSERT INTO task_generation_epochs(source_kind,source_id,epoch) VALUES(?,?,1)
            ON CONFLICT(source_kind,source_id) DO UPDATE SET epoch=task_generation_epochs.epoch+1
            """, arguments: [values.0.rawValue, values.1])
    }

    static func assertTaskGenerationEpoch(source: ProjectSourceReference, expected: Int?, db: Database) throws {
        guard let expected else { return }
        guard try taskGenerationEpoch(source: source, db: db) == expected else { throw TaskContextError.conflict }
    }

    static func generationExclusionExists(source: ProjectSourceReference, identityKey: String, db: Database) throws -> Bool {
        guard try db.tableExists("task_generation_exclusions") else { return false }
        let values = sourceValues(source)
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task_generation_exclusions WHERE source_kind=? AND source_id=? AND identity_key IN (?, 'source-wide'))",
                                 arguments: [values.0.rawValue, values.1, identityKey]) ?? false
    }

    public func taskGenerationExclusions(source: ProjectSourceReference) throws -> [TaskGenerationExclusion] {
        try pool.read { db in
            guard try db.tableExists("task_generation_exclusions") else { return [] }
            let values = Self.sourceValues(source)
            return try Row.fetchAll(db, sql: "SELECT source_kind,source_id,identity_key,reason,created_at FROM task_generation_exclusions WHERE source_kind=? AND source_id=? ORDER BY created_at,identity_key",
                                    arguments: [values.0.rawValue, values.1]).map { row in
                .init(sourceKind: TaskDeletionSourceKind(rawValue: row["source_kind"]) ?? values.0,
                      sourceID: row["source_id"], identityKey: row["identity_key"], reason: row["reason"],
                      createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }

    public func resetTaskGenerationExclusions(source: ProjectSourceReference, projectID: String? = nil) throws {
        try pool.write { db in
            try Self.verifyProjectOwnership(projectID: projectID, source: source, db: db)
            if try db.tableExists("task_generation_exclusions") {
                let values = Self.sourceValues(source)
                try db.execute(sql: "DELETE FROM task_generation_exclusions WHERE source_kind=? AND source_id=?",
                               arguments: [values.0.rawValue, values.1])
            }
            try Self.advanceTaskGenerationEpoch(source: source, db: db)
        }
    }

    // MARK: Permanent deletion

    private static func deleteGenerationCache(source: ProjectSourceReference, db: Database) throws {
        guard try db.tableExists("task_generation_cache") else { return }
        let values = sourceValues(source)
        if try db.tableExists("task_generation_cache_sources") {
            try db.execute(sql: "DELETE FROM task_generation_cache WHERE cache_key IN (SELECT cache_key FROM task_generation_cache_sources WHERE source_kind=? AND source_id=?)",
                           arguments: [values.0.rawValue, values.1])
            try db.execute(sql: "DELETE FROM task_generation_cache_sources WHERE source_kind=? AND source_id=?",
                           arguments: [values.0.rawValue, values.1])
        }
        // Caches written by an older build have no source mapping. Usage runs
        // retain accounting, while their cache payloads are safe to remove for
        // the deleted source.
        guard try db.tableExists("usage_cache_origins"), try db.tableExists("usage_runs") else { return }
        let rows = try Row.fetchAll(db, sql: "SELECT id,document FROM usage_runs")
        let runIDs = rows.compactMap { row -> String? in
            guard let data: Data = row["document"], let run = try? JSONDecoder().decode(UsageRun.self, from: data) else { return nil }
            switch source {
            case .recording(let id): return run.videoID == id ? run.id : nil
            case .feedback(let id): return run.feedbackBatchID == id ? run.id : nil
            }
        }
        guard !runIDs.isEmpty else { return }
        let marks = Array(repeating: "?", count: runIDs.count).joined(separator: ",")
        let args = StatementArguments(runIDs)
        try db.execute(sql: "DELETE FROM task_generation_cache WHERE cache_key IN (SELECT cache_key FROM usage_cache_origins WHERE run_id IN (\(marks)))", arguments: args)
        try db.execute(sql: "DELETE FROM usage_cache_origins WHERE run_id IN (\(marks))", arguments: args)
    }

    private static func insertDeletionLedger(_ preview: TaskDeletionPreview, db: Database) throws {
        guard try db.tableExists("task_deletion_tombstones") else { return }
        let exclusion = preview.exclusion
        try db.execute(sql: "INSERT INTO task_deletion_tombstones(task_id,source_kind,source_id,identity_key,deleted_at) VALUES(?,?,?,?,?)",
                       arguments: [preview.reference.taskID, exclusion.sourceKind.rawValue, exclusion.sourceID,
                                    exclusion.identityKey, Date.now.timeIntervalSince1970])
        guard try db.tableExists("task_generation_exclusions") else { return }
        try db.execute(sql: "INSERT INTO task_generation_exclusions(source_kind,source_id,identity_key,reason,created_at) VALUES(?,?,?,?,?) ON CONFLICT(source_kind,source_id,identity_key) DO UPDATE SET reason=excluded.reason",
                       arguments: [exclusion.sourceKind.rawValue, exclusion.sourceID, exclusion.identityKey,
                                    exclusion.reason, exclusion.createdAt.timeIntervalSince1970])
    }

    private static func deleteRelatedProposals(_ preview: TaskDeletionPreview, db: Database) throws {
        switch preview.reference {
        case .recording(let videoID, let taskID):
            guard try db.tableExists("task_proposals") else { return }
            let rows = try Row.fetchAll(db, sql: "SELECT id,document FROM task_proposals WHERE video_id=?", arguments: [videoID])
            for row in rows {
                guard let data: Data = row["document"], let proposal = try? JSONDecoder().decode(TaskProposal.self, from: data) else { continue }
                let key = proposal.content.map { recordingGenerationIdentity($0) }
                // A source-wide generation gate does not identify every
                // proposal as belonging to this task. Keep ambiguous and
                // unrelated proposals as outdated for reconciliation.
                let sameStableIdentity = preview.exclusion.identityKey != "source-wide" && key == preview.exclusion.identityKey
                if proposal.taskID == taskID || sameStableIdentity {
                    try db.execute(sql: "DELETE FROM task_proposals WHERE id=?", arguments: [proposal.id])
                }
            }
        case .feedback(let batchID, let taskID):
            guard try db.tableExists("feedback_proposals") else { return }
            let tasks = try feedbackTasks(batchID, in: db)
            let rows = try Row.fetchAll(db, sql: "SELECT id,document FROM feedback_proposals WHERE batch_id=?", arguments: [batchID])
            for row in rows {
                guard let data: Data = row["document"], let proposal = try? JSONDecoder().decode(FeedbackTaskProposal.self, from: data) else { continue }
                let issueID = tasks.first(where: { $0.id == proposal.taskID })?.issueID
                let sameStableIdentity = preview.exclusion.identityKey != "source-wide" && feedbackGenerationIdentity(issueID: issueID, content: proposal.content) == preview.exclusion.identityKey
                if proposal.taskID == taskID || sameStableIdentity {
                    try db.execute(sql: "DELETE FROM feedback_proposals WHERE id=?", arguments: [proposal.id])
                }
            }
        }
    }

    private static func markSourceProposalsOutdated(source: ProjectSourceReference, db: Database) throws {
        guard try db.tableExists("project_outdated_proposals") else { return }
        switch source {
        case .recording(let videoID):
            guard try db.tableExists("task_proposals") else { return }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM task_proposals WHERE video_id=?", arguments: [videoID])
            for id in ids { try db.execute(sql: "INSERT OR IGNORE INTO project_outdated_proposals(id) VALUES(?)", arguments: [id]) }
        case .feedback(let batchID):
            guard try db.tableExists("feedback_proposals") else { return }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM feedback_proposals WHERE batch_id=?", arguments: [batchID])
            for id in ids { try db.execute(sql: "INSERT OR IGNORE INTO project_outdated_proposals(id) VALUES(?)", arguments: [id]) }
        }
    }

    private static func deleteQuestionGroupProposals(for reference: ProjectTaskReference,
                                                     db: Database) throws {
        guard try db.tableExists("project_question_group_proposals") else { return }
        let rows = try Row.fetchAll(db, sql: "SELECT id,document FROM project_question_group_proposals")
        for row in rows {
            guard let data: Data = row["document"],
                  let group = try? JSONDecoder().decode(ProjectQuestionGroupProposal.self, from: data),
                  group.taskIDs.contains(reference) else { continue }
            try db.execute(sql: "DELETE FROM project_question_group_proposals WHERE id=?", arguments: [group.id])
        }
    }

    private static func deleteTask(_ preview: TaskDeletionPreview, db: Database) throws {
        guard try taskMatches(preview, db: db) else { throw TaskContextError.conflict }
        guard !(try isTaskDeleted(preview.reference.taskID, db: db)) else { throw TaskContextError.conflict }
        if preview.exclusion.identityKey == "source-wide" {
            try markSourceProposalsOutdated(source: preview.reference.source, db: db)
        }
        try deleteQuestionGroupProposals(for: preview.reference, db: db)
        try deleteRelatedProposals(preview, db: db)
        switch preview.reference {
        case .recording(let videoID, let taskID):
            try db.execute(sql: "DELETE FROM video_tasks WHERE video_id=? AND id=?", arguments: [videoID, taskID])
            if try db.tableExists("task_history") {
                try db.execute(sql: "DELETE FROM task_history WHERE task_id=?", arguments: [taskID])
            }
        case .feedback(let batchID, let taskID):
            try db.execute(sql: "DELETE FROM feedback_tasks WHERE batch_id=? AND id=?", arguments: [batchID, taskID])
            if try db.tableExists("feedback_task_history") {
                try db.execute(sql: "DELETE FROM feedback_task_history WHERE task_id=?", arguments: [taskID])
            }
        }
        try insertDeletionLedger(preview, db: db)
        try deleteGenerationCache(source: preview.reference.source, db: db)
        try advanceTaskGenerationEpoch(source: preview.reference.source, db: db)
    }

    public func deleteProjectTasks(_ preview: ProjectTaskDeletionPreview) throws {
        guard !preview.tasks.isEmpty else { throw TaskContextError.invalid("Select at least one task to delete.") }
        try pool.write { db in
            let current = try preview.tasks.map {
                try Self.taskDeletionPreview(projectID: preview.projectID, reference: $0.reference, db: db)
            }
            guard try Self.deletionSignature(projectID: preview.projectID, tasks: current) == preview.signature,
                  current.map(\.id).sorted() == preview.tasks.map(\.id).sorted() else { throw TaskContextError.conflict }
            for item in preview.tasks.sorted(by: { $0.id < $1.id }) {
                try Self.verifyProjectOwnership(projectID: preview.projectID, source: item.reference.source, db: db)
                try Self.deleteTask(item, db: db)
            }
        }
    }

    public func deleteProjectTask(projectID: String?, reference: ProjectTaskReference,
                                  expectedRevision: Int, expectedSourceRevision: TaskDeletionSourceRevision) throws {
        let preview = try previewTaskDeletion(projectID: projectID, reference: reference)
        guard preview.expectedRevision == expectedRevision,
              preview.expectedSourceRevision == expectedSourceRevision else { throw TaskContextError.conflict }
        let selected = ProjectTaskDeletionPreview(projectID: projectID, tasks: [preview],
                                                   signature: try Self.deletionSignature(projectID: projectID, tasks: [preview]))
        try deleteProjectTasks(selected)
    }

    // MARK: Guarded task cache

    public func taskCache(key: String, source: ProjectSourceReference? = nil,
                          expectedEpoch: Int? = nil) throws -> Data? {
        try pool.read { db in
            if let source { try Self.assertTaskGenerationEpoch(source: source, expected: expectedEpoch, db: db) }
            return try Data.fetchOne(db, sql: "SELECT document FROM task_generation_cache WHERE cache_key = ?", arguments: [key])
        }
    }

    public func saveTaskCache(key: String, data: Data, source: ProjectSourceReference? = nil,
                              expectedEpoch: Int? = nil) throws {
        try pool.write { db in
            if let source {
                try Self.assertTaskGenerationEpoch(source: source, expected: expectedEpoch, db: db)
            }
            try db.execute(sql: "INSERT INTO task_generation_cache VALUES(?, ?) ON CONFLICT(cache_key) DO UPDATE SET document=excluded.document", arguments: [key, data])
            if let source, let expectedEpoch, try db.tableExists("task_generation_cache_sources") {
                let values = Self.sourceValues(source)
                try db.execute(sql: "INSERT INTO task_generation_cache_sources(cache_key,source_kind,source_id,epoch) VALUES(?,?,?,?) ON CONFLICT(cache_key) DO UPDATE SET source_kind=excluded.source_kind,source_id=excluded.source_id,epoch=excluded.epoch",
                               arguments: [key, values.0.rawValue, values.1, expectedEpoch])
            }
        }
    }
}
