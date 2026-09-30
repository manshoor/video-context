import Foundation
import GRDB

extension VideoContextStore {
    static func backupBeforeProductDocumentationMigration(pool: DatabasePool, databaseURL: URL) throws {
        let needed = try pool.read { db in
            guard try db.tableExists("videos") else { return false }
            guard try db.tableExists("grdb_migrations") else { return true }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier='productDocumentationRecoveryV1')") != true
        }
        guard needed else { return }
        let backupURL = databaseURL.appendingPathExtension("before-documentation-\(UUID().uuidString).sqlite")
        let destination = try DatabaseQueue(path: backupURL.path)
        try pool.backup(to: destination)
        // A backup must be readable as one file without SQLite WAL sidecars.
        try destination.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=DELETE")
        }
    }
}
