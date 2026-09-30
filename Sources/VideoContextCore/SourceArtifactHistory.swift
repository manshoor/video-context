import Foundation
import CryptoKit
import GRDB

public enum SourceArtifactHistoryStage: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case transcript
    case evidence
    case brief
}

/// A previous source artifact retained before a replace or publish operation.
/// The payload is the exact JSON representation of the artifact at that
/// revision, so later documentation can cite an old source without relying on
/// the current transcript or brief.
public struct SourceArtifactHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoID: String
    public let stage: SourceArtifactHistoryStage
    public let revision: Int
    public let artifactData: Data
    public let artifactHash: String
    public let createdAt: Date

    public init(
        id: String = "history_\(UUID().uuidString.lowercased())",
        videoID: String,
        stage: SourceArtifactHistoryStage,
        revision: Int,
        artifactData: Data,
        createdAt: Date = .now
    ) {
        self.id = id
        self.videoID = videoID
        self.stage = stage
        self.revision = revision
        self.artifactData = artifactData
        self.artifactHash = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
        self.createdAt = createdAt
    }
}

extension VideoContextStore {
    /// Register this schema from the same additive migration as processing
    /// recovery. The helper remains independent from the publish methods so a
    /// migration can be applied before any new artifact is written.
    public static func createSourceArtifactHistorySchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS source_artifact_history (
                id TEXT PRIMARY KEY,
                video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                stage TEXT NOT NULL,
                revision INTEGER NOT NULL,
                artifact_data BLOB NOT NULL,
                artifact_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(video_id, stage, revision)
            );
            CREATE INDEX IF NOT EXISTS source_artifact_history_video_stage_revision
                ON source_artifact_history(video_id, stage, revision DESC, created_at DESC);
            """)
    }

    /// Capture the current artifact before the owning store operation replaces
    /// it. Call this inside the same write transaction as the replacement.
    public static func captureHistory(
        db: Database,
        videoID: String,
        stage: SourceArtifactHistoryStage,
        revision: Int,
        artifactData: Data,
        createdAt: Date = .now
    ) throws {
        guard try db.tableExists("source_artifact_history") else { return }
        let entry = SourceArtifactHistoryEntry(
            videoID: videoID,
            stage: stage,
            revision: revision,
            artifactData: artifactData,
            createdAt: createdAt
        )
        try db.execute(
            sql: "INSERT OR IGNORE INTO source_artifact_history (id, video_id, stage, revision, artifact_data, artifact_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [entry.id, entry.videoID, entry.stage.rawValue, entry.revision, entry.artifactData, entry.artifactHash, entry.createdAt.timeIntervalSince1970]
        )
    }

    public func sourceArtifactHistory(
        videoID: String,
        stage: SourceArtifactHistoryStage? = nil,
        limit: Int = 100
    ) throws -> [SourceArtifactHistoryEntry] {
        guard (1...500).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        return try pool.read { database in
            guard try database.tableExists("source_artifact_history") else { return [] }
            let rows: [Row]
            if let stage {
                rows = try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM source_artifact_history WHERE video_id = ? AND stage = ? ORDER BY revision DESC, created_at DESC LIMIT ?",
                    arguments: [videoID, stage.rawValue, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM source_artifact_history WHERE video_id = ? ORDER BY revision DESC, created_at DESC LIMIT ?",
                    arguments: [videoID, limit]
                )
            }
            return rows.map(Self.sourceArtifactHistory(from:))
        }
    }
}

private extension VideoContextStore {
    static func sourceArtifactHistory(from row: Row) -> SourceArtifactHistoryEntry {
        SourceArtifactHistoryEntry(
            id: row["id"],
            videoID: row["video_id"],
            stage: SourceArtifactHistoryStage(rawValue: row["stage"]) ?? .brief,
            revision: row["revision"],
            artifactData: row["artifact_data"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }
}
