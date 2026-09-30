import Foundation
import GRDB

extension VideoContextStore {
    static func reconcileFeedbackExclusions(_ next: FeedbackBatch, db: Database) throws {
        guard try db.tableExists("task_generation_exclusions") else { return }
        let keys = try String.fetchAll(db, sql: "SELECT identity_key FROM task_generation_exclusions WHERE source_kind='feedback' AND source_id=?", arguments: [next.id])
        let currentIDs = Set(next.comments.map { "issue:" + $0.id })
        if keys.contains(where: { $0.hasPrefix("issue:") && !currentIDs.contains($0) }) {
            try db.execute(sql: "INSERT OR IGNORE INTO task_generation_exclusions(source_kind,source_id,identity_key,reason,created_at) VALUES('feedback',?,'source-wide',?,?)",
                arguments: [next.id, "A deleted issue no longer has a stable source identity. Reconcile this source before allowing generation again.", Date.now.timeIntervalSince1970])
        }
    }

    static func createFeedbackSourceHistorySchema(in db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS feedback_source_history(batch_id TEXT NOT NULL, revision INTEGER NOT NULL, document BLOB NOT NULL, PRIMARY KEY(batch_id,revision))")
    }

    static func preserveFeedbackSource(_ batch: FeedbackBatch, db: Database) throws {
        guard try db.tableExists("feedback_source_history") else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO feedback_source_history VALUES(?,?,?)", arguments: [batch.id, batch.revision, try JSONEncoder().encode(batch)])
    }

    public func feedbackSourceRevision(batchID: String, revision: Int) throws -> FeedbackBatch {
        try pool.read { db in
            let current = try Self.feedbackBatch(batchID, in: db)
            if current.revision == revision { return current }
            guard try db.tableExists("feedback_source_history"),
                  let data = try Data.fetchOne(db, sql: "SELECT document FROM feedback_source_history WHERE batch_id=? AND revision=?", arguments: [batchID, revision]) else {
                throw TaskContextError.missing("\(batchID) revision \(revision)")
            }
            return try JSONDecoder().decode(FeedbackBatch.self, from: data)
        }
    }
}
