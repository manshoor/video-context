import Foundation
import GRDB

/// Editors may append proposals here; the canonical library remains read-only to MCP.
public actor DocumentProposalInbox {
    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public let id: String
        public let requestID: String
        public let projectID: String
        public let documentID: String
        public let expectedRevision: Int
        public let payload: Data
        public let createdAt: Date
        public var imported: Bool
    }

    private let database: DatabaseQueue
    public static func url(in paths: LibraryPaths) -> URL { paths.root.appending(path: "document-proposal-inbox.sqlite") }

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_proposal_inbox (
                    id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
                    project_id TEXT NOT NULL, document_id TEXT NOT NULL,
                    expected_revision INTEGER NOT NULL, payload BLOB NOT NULL,
                    created_at REAL NOT NULL, imported INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS document_proposal_inbox_project ON document_proposal_inbox(project_id, imported);
                """)
        }
    }

    public func submit(requestID: String, projectID: String, documentID: String, expectedRevision: Int, payload: Data) throws -> Entry {
        guard !requestID.isEmpty, requestID.count <= 128, !requestID.contains(where: { $0.isNewline }),
              !projectID.isEmpty, projectID.count <= 256, !documentID.isEmpty, documentID.count <= 256,
              expectedRevision >= 0, !payload.isEmpty, payload.count <= 1_048_576 else {
            throw TaskContextError.invalid("Supply a request ID, exact document revision (zero for a new document), and a proposal no larger than 1 MiB.")
        }
        return try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM document_proposal_inbox WHERE request_id=?", arguments: [requestID]) {
                let existing = Self.entry(row)
                guard existing.projectID == projectID, existing.documentID == documentID,
                      existing.expectedRevision == expectedRevision, existing.payload == payload else {
                    throw TaskContextError.invalid("This request ID already belongs to a different proposal. Use a new request ID.")
                }
                return existing
            }
            let entry = Entry(id: "editor_proposal_\(UUID().uuidString.lowercased())", requestID: requestID,
                projectID: projectID, documentID: documentID, expectedRevision: expectedRevision,
                payload: payload, createdAt: .now, imported: false)
            try db.execute(sql: "INSERT INTO document_proposal_inbox VALUES(?,?,?,?,?,?,?,0)", arguments: [entry.id, requestID, projectID, documentID, expectedRevision, payload, entry.createdAt.timeIntervalSince1970])
            // Return the stored timestamp so an idempotent retry is exactly identical.
            return Self.entry(try Row.fetchOne(db, sql: "SELECT * FROM document_proposal_inbox WHERE id=?", arguments: [entry.id])!)
        }
    }

    /// Read an existing request before validating the current canonical
    /// document. Idempotent retries must be able to return their original
    /// receipt after the app has accepted the proposal and advanced the
    /// document revision.
    public func existing(requestID: String) throws -> Entry? {
        guard !requestID.isEmpty else { return nil }
        return try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM document_proposal_inbox WHERE request_id=?", arguments: [requestID]).map(Self.entry)
        }
    }

    public func pending(projectID: String) throws -> [Entry] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM document_proposal_inbox WHERE project_id=? AND imported=0 ORDER BY created_at,id", arguments: [projectID]).map(Self.entry)
        }
    }

    public func markImported(id: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE document_proposal_inbox SET imported=1 WHERE id=?", arguments: [id])
        }
    }

    private static func entry(_ row: Row) -> Entry {
        Entry(id: row["id"], requestID: row["request_id"], projectID: row["project_id"], documentID: row["document_id"],
              expectedRevision: row["expected_revision"], payload: row["payload"], createdAt: Date(timeIntervalSince1970: row["created_at"]), imported: row["imported"])
    }
}
