import Foundation
import GRDB
import Testing
@testable import VideoContextCore

struct ProductDocumentationMigrationTests {
    private static func removeDocumentationSchema(_ db: Database) throws {
        for table in ["project_documentation_proposals", "project_documentation_revisions", "project_documentation", "project_document_source_revisions", "project_document_import_jobs", "project_document_sources", "project_question_group_proposals", "project_decisions", "feedback_source_history"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('productDocumentationV1','productDocumentationRecoveryV1')")
    }
    @Test func upgradeBackupAndRepeatedStartupPreserveExistingLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "documentation-migration-\(UUID())")
        let paths = try LibraryPaths(root: root)
        let initial = try VideoContextStore(databaseURL: paths.database)
        let project = try await initial.createFeedbackProject(name: "Keep project")
        let batch = try await initial.createProjectRequest(projectID: project.id, title: "Keep request", text: "Keep source content")
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in try Self.removeDocumentationSchema(db) }
        let migrated = try VideoContextStore(databaseURL: paths.database)
        #expect(try await migrated.feedbackSnapshot(id: batch.id).batch == batch)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("before-documentation-") && $0.pathExtension == "sqlite" }
        #expect(backups.count == 1)
        let backup = try VideoContextStore(databaseURL: #require(backups.first), access: .readOnly)
        #expect(try await backup.feedbackSnapshot(id: batch.id).batch == batch)
        _ = try VideoContextStore(databaseURL: paths.database)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("before-documentation-") && $0.pathExtension == "sqlite" }.count == 1)
    }

    @Test func migrationFailureRollsBackAndReadOnlyLibraryStillWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "documentation-rollback-\(UUID())")
        let paths = try LibraryPaths(root: root), initial = try VideoContextStore(databaseURL: paths.database)
        let project = try await initial.createFeedbackProject(name: "Original")
        let batch = try await initial.createProjectRequest(projectID: project.id, title: "Original request", text: "Never lose this")
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try Self.removeDocumentationSchema(db)
            try db.execute(sql: "DROP TABLE task_deletion_tombstones")
            try db.execute(sql: "CREATE TRIGGER reject_documentation_migration BEFORE INSERT ON grdb_migrations WHEN NEW.identifier='productDocumentationV1' BEGIN SELECT RAISE(ABORT,'controlled migration failure'); END")
        }
        #expect(throws: (any Error).self) { try VideoContextStore(databaseURL: paths.database) }
        #expect(try await queue.read { try $0.tableExists("task_deletion_tombstones") } == false)
        let readable = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        #expect(try await readable.feedbackSnapshot(id: batch.id).batch.rawText == "Never lose this")
    }

    @Test func earlyDocumentationLibraryReceivesRecoveryColumnsAndTables() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "documentation-recovery-upgrade-\(UUID())")
        let paths = try LibraryPaths(root: root), initial = try VideoContextStore(databaseURL: paths.database)
        let project = try await initial.createFeedbackProject(name: "Early documentation")
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='productDocumentationRecoveryV1'")
            for table in ["processing_checkpoints", "video_audio_coverage", "feedback_source_history", "documentation_analysis_checkpoints"] {
                try db.execute(sql: "DROP TABLE \(table)")
            }
            try db.execute(sql: "ALTER TABLE evidence_items DROP COLUMN requested_timestamp")
        }
        let migrated = try VideoContextStore(databaseURL: paths.database)
        #expect(try await migrated.projectDocumentation(projectID: project.id).documentation.isEmpty)
        #expect(try await queue.read { try $0.columns(in: "evidence_items").contains { $0.name == "requested_timestamp" } })
        #expect(try await queue.read { try $0.tableExists("video_audio_coverage") })
        #expect(try await queue.read { try $0.tableExists("feedback_source_history") })
        #expect(try await queue.read { try $0.tableExists("documentation_analysis_checkpoints") })
    }
}
