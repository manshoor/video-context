import Foundation
import GRDB

/// The result of media inspection that is useful even when a recording has no
/// transcript. Keeping this separate from `VideoRecord` makes the field
/// additive for old libraries and lets inspection publish the result before
/// transcription, frame capture, or provider analysis begins.
public enum AudioCoverageStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case unknown
    case present
    case silent
    case unavailable
}

public struct AudioCoverage: Codable, Equatable, Sendable {
    public let videoID: String
    public let status: AudioCoverageStatus
    public let hasAudio: Bool?
    public let duration: TimeInterval
    public let updatedAt: Date

    public init(
        videoID: String,
        status: AudioCoverageStatus = .unknown,
        hasAudio: Bool? = nil,
        duration: TimeInterval = 0,
        updatedAt: Date = .now
    ) {
        self.videoID = videoID
        self.status = status
        self.hasAudio = hasAudio
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

extension VideoContextStore {
    /// Register this table with the library migrator. The table is deliberately
    /// independent of `videos` columns so read-only clients and pre-migration
    /// libraries can keep reading recordings while the additive migration is
    /// pending.
    public static func createAudioCoverageSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS video_audio_coverage (
                video_id TEXT PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
                status TEXT NOT NULL,
                has_audio INTEGER,
                duration REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS video_audio_coverage_status
                ON video_audio_coverage(status, updated_at DESC);
            """)
    }

    /// Persist the media inspection result. A missing table is treated as a
    /// pre-migration library and returns nil without affecting processing.
    @discardableResult
    public func saveAudioCoverage(
        videoID: String,
        hasAudio: Bool?,
        duration: TimeInterval,
        status: AudioCoverageStatus? = nil
    ) throws -> AudioCoverage? {
        try pool.write { database in
            guard try database.tableExists("video_audio_coverage") else { return nil }
            guard try Self.fetchVideo(id: videoID, from: database) != nil else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            let resolvedStatus = status ?? {
                switch hasAudio {
                case .some(true): return .present
                case .some(false): return .silent
                case .none: return .unknown
                }
            }()
            let storedTimestamp = Date.now.timeIntervalSince1970
            try database.execute(
                sql: """
                    INSERT INTO video_audio_coverage(video_id, status, has_audio, duration, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(video_id) DO UPDATE SET
                        status = excluded.status,
                        has_audio = excluded.has_audio,
                        duration = excluded.duration,
                        updated_at = excluded.updated_at
                    """,
                arguments: [videoID, resolvedStatus.rawValue, hasAudio, max(0, duration), storedTimestamp]
            )
            return AudioCoverage(videoID: videoID, status: resolvedStatus, hasAudio: hasAudio,
                                 duration: max(0, duration), updatedAt: Date(timeIntervalSince1970: storedTimestamp))
        }
    }

    /// Returns nil for an old library that has not received the additive
    /// migration or for a recording that has not yet been inspected.
    public func audioCoverage(videoID: String) throws -> AudioCoverage? {
        try pool.read { database in
            guard try database.tableExists("video_audio_coverage") else { return nil }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM video_audio_coverage WHERE video_id = ?",
                arguments: [videoID]
            ) else { return nil }
            let storedHasAudio: Int? = row["has_audio"]
            let storedDuration: TimeInterval = row["duration"]
            return AudioCoverage(
                videoID: row["video_id"],
                status: AudioCoverageStatus(rawValue: row["status"] ?? "unknown") ?? .unknown,
                hasAudio: storedHasAudio.map { $0 != 0 },
                duration: max(0, storedDuration),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }
}
