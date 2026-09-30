import Foundation
import GRDB

public enum FeedbackImportPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case accepted
    case downloading
    case copied
    case processing
    case completed
    case failed
}

/// Durable ownership and progress for a feedback attachment. The project is
/// captured at import start so a later workspace switch cannot redirect the
/// resulting recording.
public struct FeedbackImportRecovery: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let batchID: String
    public let sourceID: String
    public let projectID: String?
    public let sourceURL: String?
    public let filename: String?
    public var recordingID: String?
    public var phase: FeedbackImportPhase
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String? = nil,
        batchID: String,
        sourceID: String,
        projectID: String?,
        sourceURL: String? = nil,
        filename: String? = nil,
        recordingID: String? = nil,
        phase: FeedbackImportPhase = .accepted,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id ?? Self.makeID(batchID: batchID, sourceID: sourceID)
        self.batchID = batchID
        self.sourceID = sourceID
        self.projectID = projectID
        self.sourceURL = sourceURL
        self.filename = filename
        self.recordingID = recordingID
        self.phase = phase
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeID(batchID: String, sourceID: String) -> String {
        "feedback-import:\(batchID):\(sourceID)"
    }
}

extension VideoContextStore {
    /// Register this schema in the same migration as the other recovery
    /// tables. It deliberately does not foreign-key the JSON feedback batch:
    /// recovery rows must survive a partially written attachment update so the
    /// app can explain and resume it.
    public static func createFeedbackImportRecoverySchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS feedback_import_recovery (
                id TEXT PRIMARY KEY,
                batch_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                project_id TEXT,
                source_url TEXT,
                filename TEXT,
                recording_id TEXT,
                phase TEXT NOT NULL,
                error_message TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(batch_id, source_id)
            );
            CREATE INDEX IF NOT EXISTS feedback_import_recovery_project
                ON feedback_import_recovery(project_id, phase, updated_at DESC);
            CREATE INDEX IF NOT EXISTS feedback_import_recovery_recording
                ON feedback_import_recovery(recording_id);
            """)
    }

    @discardableResult
    public func beginFeedbackImport(
        batchID: String,
        sourceID: String,
        projectID: String?,
        sourceURL: String? = nil,
        filename: String? = nil
    ) throws -> FeedbackImportRecovery? {
        try pool.write { database in
            guard try database.tableExists("feedback_import_recovery") else { return nil }
            if let existing = try Row.fetchOne(
                database,
                sql: "SELECT * FROM feedback_import_recovery WHERE batch_id = ? AND source_id = ?",
                arguments: [batchID, sourceID]
            ).map(Self.feedbackImportRecovery(from:)) {
                // The first project assignment is authoritative. A retry must
                // not silently move an attachment to a newly selected project.
                guard existing.projectID == projectID else {
                    throw TaskContextError.conflict
                }
                return existing
            }
            let value = FeedbackImportRecovery(batchID: batchID, sourceID: sourceID, projectID: projectID, sourceURL: sourceURL, filename: filename)
            try Self.writeFeedbackImportRecovery(value, into: database)
            return value
        }
    }

    @discardableResult
    public func updateFeedbackImport(
        batchID: String,
        sourceID: String,
        phase: FeedbackImportPhase,
        recordingID: String? = nil,
        errorMessage: String? = nil
    ) throws -> FeedbackImportRecovery? {
        try pool.write { database in
            guard try database.tableExists("feedback_import_recovery") else { return nil }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM feedback_import_recovery WHERE batch_id = ? AND source_id = ?",
                arguments: [batchID, sourceID]
            ) else { return nil }
            var value = Self.feedbackImportRecovery(from: row)
            if let recordingID, let existingRecordingID = value.recordingID, recordingID != existingRecordingID {
                // A retry must continue the captured import. Replacing the
                // recording would leave the feedback source pointing at a
                // result from a different import operation.
                throw TaskContextError.conflict
            }
            value.recordingID = recordingID ?? value.recordingID
            value.phase = phase
            value.errorMessage = errorMessage
            value.updatedAt = .now
            try Self.writeFeedbackImportRecovery(value, into: database)
            return value
        }
    }

    public func feedbackImportRecovery(batchID: String, sourceID: String) throws -> FeedbackImportRecovery? {
        try pool.read { database in
            guard try database.tableExists("feedback_import_recovery") else { return nil }
            return try Row.fetchOne(
                database,
                sql: "SELECT * FROM feedback_import_recovery WHERE batch_id = ? AND source_id = ?",
                arguments: [batchID, sourceID]
            ).map(Self.feedbackImportRecovery(from:))
        }
    }

    public func feedbackImportRecoveries(projectID: String? = nil, limit: Int = 100) throws -> [FeedbackImportRecovery] {
        guard (1...500).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        return try pool.read { database in
            guard try database.tableExists("feedback_import_recovery") else { return [] }
            if let projectID {
                return try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM feedback_import_recovery WHERE project_id = ? ORDER BY updated_at DESC LIMIT ?",
                    arguments: [projectID, limit]
                ).map(Self.feedbackImportRecovery(from:))
            }
            return try Row.fetchAll(
                database,
                sql: "SELECT * FROM feedback_import_recovery ORDER BY updated_at DESC LIMIT ?",
                arguments: [limit]
            ).map(Self.feedbackImportRecovery(from:))
        }
    }
}

private extension VideoContextStore {
    static func writeFeedbackImportRecovery(_ value: FeedbackImportRecovery, into database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO feedback_import_recovery
                    (id, batch_id, source_id, project_id, source_url, filename, recording_id, phase, error_message, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(batch_id, source_id) DO UPDATE SET
                    recording_id = excluded.recording_id,
                    phase = excluded.phase,
                    error_message = excluded.error_message,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                value.id, value.batchID, value.sourceID, value.projectID, value.sourceURL, value.filename,
                value.recordingID, value.phase.rawValue, value.errorMessage,
                value.createdAt.timeIntervalSince1970, value.updatedAt.timeIntervalSince1970
            ]
        )
    }

    static func feedbackImportRecovery(from row: Row) -> FeedbackImportRecovery {
        FeedbackImportRecovery(
            id: row["id"], batchID: row["batch_id"], sourceID: row["source_id"], projectID: row["project_id"],
            sourceURL: row["source_url"], filename: row["filename"], recordingID: row["recording_id"],
            phase: FeedbackImportPhase(rawValue: row["phase"]) ?? .failed,
            errorMessage: row["error_message"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }
}
