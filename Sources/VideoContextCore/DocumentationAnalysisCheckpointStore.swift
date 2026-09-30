import Foundation
import GRDB

public struct DocumentationAnalysisCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public let projectID: String
    public let key: String
    public let requestID: String
    public let state: ProcessingCheckpointState
    public let result: Data?
    public let error: String?
    public var id: String { projectID + ":" + key }
}

public extension VideoContextStore {
    static func createDocumentationAnalysisCheckpointSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS documentation_analysis_checkpoints(
                project_id TEXT NOT NULL REFERENCES feedback_projects(id),
                cache_key TEXT NOT NULL,
                request_id TEXT NOT NULL,
                state TEXT NOT NULL,
                result BLOB,
                error TEXT,
                updated_at REAL NOT NULL,
                PRIMARY KEY(project_id,cache_key)
            );
            """)
    }
    func documentationAnalysisCheckpoints(projectID: String) throws -> [DocumentationAnalysisCheckpoint] {
        try pool.read { db in
            guard try db.tableExists("documentation_analysis_checkpoints") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT * FROM documentation_analysis_checkpoints WHERE project_id=? ORDER BY updated_at", arguments: [projectID]).map(Self.documentationAnalysisCheckpoint(from:))
        }
    }
    private static func documentationAnalysisCheckpoint(from row: Row) -> DocumentationAnalysisCheckpoint {
        .init(projectID: row["project_id"], key: row["cache_key"], requestID: row["request_id"], state: ProcessingCheckpointState(rawValue: row["state"]) ?? .unknown, result: row["result"], error: row["error"])
    }
    func beginDocumentationAnalysis(projectID: String, key: String) throws -> DocumentationAnalysisCheckpoint {
        try pool.write { db in
            try Self.requireProject(projectID, in: db)
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM documentation_analysis_checkpoints WHERE project_id=? AND cache_key=?", arguments: [projectID, key]) {
                let previous = Self.documentationAnalysisCheckpoint(from: row)
                if previous.state == .completed { return previous }
                guard previous.state == .failed else {
                    throw TaskContextError.invalid("Analysis has an uncertain provider result. Reconcile it in the project before allowing a retry.")
                }
            }
            let request = UUID().uuidString
            try db.execute(sql: "INSERT INTO documentation_analysis_checkpoints(project_id,cache_key,request_id,state,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(project_id,cache_key) DO UPDATE SET request_id=excluded.request_id,state=excluded.state,result=NULL,error=NULL,updated_at=excluded.updated_at",
                arguments: [projectID, key, request, ProcessingCheckpointState.running.rawValue, Date.now.timeIntervalSince1970])
            return .init(projectID: projectID, key: key, requestID: request, state: .running, result: nil, error: nil)
        }
    }
    func completeDocumentationAnalysis(_ checkpoint: DocumentationAnalysisCheckpoint, result: Data) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE documentation_analysis_checkpoints SET state=?,result=?,error=NULL,updated_at=? WHERE project_id=? AND cache_key=? AND request_id=? AND state=?",
                arguments: [ProcessingCheckpointState.completed.rawValue, result, Date.now.timeIntervalSince1970, checkpoint.projectID, checkpoint.key, checkpoint.requestID, ProcessingCheckpointState.running.rawValue])
            guard db.changesCount == 1 else { throw TaskContextError.conflict }
        }
    }
    func failDocumentationAnalysis(_ checkpoint: DocumentationAnalysisCheckpoint, error: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE documentation_analysis_checkpoints SET state=?,error=?,updated_at=? WHERE project_id=? AND cache_key=? AND request_id=? AND state=?",
                arguments: [ProcessingCheckpointState.unknown.rawValue, error, Date.now.timeIntervalSince1970, checkpoint.projectID, checkpoint.key, checkpoint.requestID, ProcessingCheckpointState.running.rawValue])
        }
    }
    /// The provider returned a response, but it could not be accepted. An
    /// explicit later run may retry; this is distinct from an unknown outcome.
    func rejectDocumentationAnalysis(_ checkpoint: DocumentationAnalysisCheckpoint, error: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE documentation_analysis_checkpoints SET state=?,result=NULL,error=?,updated_at=? WHERE project_id=? AND cache_key=? AND request_id=? AND state=?",
                arguments: [ProcessingCheckpointState.failed.rawValue, error, Date.now.timeIntervalSince1970, checkpoint.projectID, checkpoint.key, checkpoint.requestID, ProcessingCheckpointState.running.rawValue])
        }
    }
    func resetDocumentationAnalysis(_ checkpoint: DocumentationAnalysisCheckpoint) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE documentation_analysis_checkpoints SET state=?,result=NULL,error=NULL,request_id=?,updated_at=? WHERE project_id=? AND cache_key=? AND request_id=? AND state IN ('running','unknown')",
                arguments: [ProcessingCheckpointState.failed.rawValue, UUID().uuidString, Date.now.timeIntervalSince1970, checkpoint.projectID, checkpoint.key, checkpoint.requestID])
            guard db.changesCount == 1 else { throw TaskContextError.conflict }
        }
    }
}
