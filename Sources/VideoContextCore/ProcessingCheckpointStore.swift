import Foundation
import CryptoKit
import GRDB

/// The unit of work represented by a durable processing checkpoint.
public enum ProcessingCheckpointStage: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case transcriptChunk
    case frameCapture
    case ocrFrame
    case analysisBatch
    case analysisFinal
}

public enum ProcessingCheckpointState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case running
    case completed
    case failed
    case unknown
}

/// A persisted unit of work. `outputData` is JSON encoded by the caller so the
/// checkpoint store can remain independent of provider and media types.
public struct ProcessingCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let videoID: String
    public let stage: ProcessingCheckpointStage
    public let itemKey: String
    public let inputFingerprint: String
    public var state: ProcessingCheckpointState
    public var outputData: Data?
    public var provider: String?
    public var model: String?
    public var requestID: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String? = nil,
        videoID: String,
        stage: ProcessingCheckpointStage,
        itemKey: String,
        inputFingerprint: String,
        state: ProcessingCheckpointState = .running,
        outputData: Data? = nil,
        provider: String? = nil,
        model: String? = nil,
        requestID: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id ?? Self.makeID(videoID: videoID, stage: stage, itemKey: itemKey)
        self.videoID = videoID
        self.stage = stage
        self.itemKey = itemKey
        self.inputFingerprint = inputFingerprint
        self.state = state
        self.outputData = outputData
        self.provider = provider
        self.model = model
        self.requestID = requestID
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeID(videoID: String, stage: ProcessingCheckpointStage, itemKey: String) -> String {
        "checkpoint:\(videoID):\(stage.rawValue):\(itemKey)"
    }
}

public struct TranscriptCheckpointOutput: Codable, Equatable, Sendable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }
}

public struct OCRCheckpointOutput: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let requestedTimestamp: TimeInterval?
    public let timestamp: TimeInterval
    public let imageRelativePath: String
    public let ocrText: String

    public init(evidenceID: String, requestedTimestamp: TimeInterval? = nil, timestamp: TimeInterval, imageRelativePath: String, ocrText: String) {
        self.evidenceID = evidenceID
        self.requestedTimestamp = requestedTimestamp
        self.timestamp = timestamp
        self.imageRelativePath = imageRelativePath
        self.ocrText = ocrText
    }
}

public struct FrameCaptureCheckpointOutput: Codable, Equatable, Sendable {
    public let requestedTimestamp: TimeInterval
    public let measuredTimestamp: TimeInterval
    public let imageRelativePath: String

    public init(requestedTimestamp: TimeInterval, measuredTimestamp: TimeInterval, imageRelativePath: String) {
        self.requestedTimestamp = requestedTimestamp
        self.measuredTimestamp = measuredTimestamp
        self.imageRelativePath = imageRelativePath
    }
}

public struct AnalysisCheckpointOutput: Codable, Equatable, Sendable {
    public let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }
}

public enum ProcessingRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case unknownOutcome(videoID: String, stage: ProcessingCheckpointStage, itemKey: String)
    case inputChanged(videoID: String, stage: ProcessingCheckpointStage, itemKey: String)
    case missingCheckpoint(videoID: String, stage: ProcessingCheckpointStage, itemKey: String)

    public var errorDescription: String? {
        switch self {
        case .unknownOutcome(let videoID, let stage, let itemKey):
            "The processing result for \(stage.rawValue) \(itemKey) in recording \(videoID) is unknown. Reconcile it before retrying so the provider is not called twice."
        case .inputChanged(let videoID, let stage, let itemKey):
            "The input for \(stage.rawValue) \(itemKey) in recording \(videoID) changed while it was being processed."
        case .missingCheckpoint(let videoID, let stage, let itemKey):
            "The processing checkpoint for \(stage.rawValue) \(itemKey) in recording \(videoID) is missing."
        }
    }
}

public enum ProcessingFingerprint {
    public static func make(_ parts: [String]) -> String {
        let data = Data(parts.joined(separator: "\u{1f}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func make<T: Encodable>(_ value: T, salt: String = "") throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return make([salt, String(decoding: try encoder.encode(value), as: UTF8.self)])
    }
}

extension ProcessingCheckpoint {
    public func decodeOutput<T: Decodable>(_ type: T.Type) throws -> T {
        guard let outputData else {
            throw ProcessingRecoveryError.missingCheckpoint(videoID: videoID, stage: stage, itemKey: itemKey)
        }
        return try JSONDecoder().decode(type, from: outputData)
    }

    public static func encodeOutput<T: Encodable>(_ output: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(output)
    }
}

extension VideoContextStore {
    /// Register this schema from the library migrator after the existing
    /// project and feedback migrations. It intentionally uses `IF NOT EXISTS`
    /// so a repaired library can safely run the migration once more.
    public static func createProcessingRecoverySchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS processing_checkpoints (
                id TEXT PRIMARY KEY,
                video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                stage TEXT NOT NULL,
                item_key TEXT NOT NULL,
                input_fingerprint TEXT NOT NULL,
                state TEXT NOT NULL,
                output_data BLOB,
                provider TEXT,
                model TEXT,
                request_id TEXT,
                error_message TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(video_id, stage, item_key)
            );
            CREATE INDEX IF NOT EXISTS processing_checkpoints_video_state
                ON processing_checkpoints(video_id, state, stage, item_key);
            CREATE INDEX IF NOT EXISTS processing_checkpoints_request
                ON processing_checkpoints(request_id);
            """)
    }

    /// Returns nil for a pre-migration library. This keeps read-only MCP and
    /// existing recordings usable until the application performs its additive
    /// migration.
    public func processingCheckpoint(
        videoID: String,
        stage: ProcessingCheckpointStage,
        itemKey: String,
        inputFingerprint: String
    ) throws -> ProcessingCheckpoint? {
        try pool.read { database in
            guard try database.tableExists("processing_checkpoints") else { return nil }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM processing_checkpoints WHERE video_id = ? AND stage = ? AND item_key = ?",
                arguments: [videoID, stage.rawValue, itemKey]
            ) else { return nil }
            let value = Self.processingCheckpoint(from: row)
            // Completed results with a changed input are safely replaceable. A
            // running/unknown result must still be reconciled first.
            if value.inputFingerprint != inputFingerprint,
               value.state == .running || value.state == .unknown {
                throw ProcessingRecoveryError.inputChanged(videoID: videoID, stage: stage, itemKey: itemKey)
            }
            return value
        }
    }

    /// Starts a checkpoint. A running or unknown request is never silently
    /// retried, which prevents duplicate provider work after a lost response.
    @discardableResult
    public func beginProcessingCheckpoint(
        videoID: String,
        stage: ProcessingCheckpointStage,
        itemKey: String,
        inputFingerprint: String,
        provider: String? = nil,
        model: String? = nil,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ProcessingCheckpoint? {
        try pool.write { database in
            guard try database.tableExists("processing_checkpoints") else { return nil }
            let current = try Row.fetchOne(
                database,
                sql: "SELECT * FROM processing_checkpoints WHERE video_id = ? AND stage = ? AND item_key = ?",
                arguments: [videoID, stage.rawValue, itemKey]
            ).map(Self.processingCheckpoint(from:))
            if let current {
                if current.inputFingerprint != inputFingerprint {
                    guard current.state == .completed || current.state == .failed else {
                        throw ProcessingRecoveryError.inputChanged(videoID: videoID, stage: stage, itemKey: itemKey)
                    }
                } else {
                    switch current.state {
                    case .running, .unknown:
                        throw ProcessingRecoveryError.unknownOutcome(videoID: videoID, stage: stage, itemKey: itemKey)
                    case .completed:
                        return current
                    case .failed:
                        break
                    }
                }
            }
            let now = Date.now
            let value = ProcessingCheckpoint(
                id: ProcessingCheckpoint.makeID(videoID: videoID, stage: stage, itemKey: itemKey),
                videoID: videoID,
                stage: stage,
                itemKey: itemKey,
                inputFingerprint: inputFingerprint,
                state: .running,
                provider: provider,
                model: model,
                requestID: requestID,
                createdAt: current?.createdAt ?? now,
                updatedAt: now
            )
            try Self.writeProcessingCheckpoint(value, into: database)
            return value
        }
    }

    public func completeProcessingCheckpoint(
        videoID: String,
        stage: ProcessingCheckpointStage,
        itemKey: String,
        inputFingerprint: String,
        outputData: Data,
        expectedRequestID: String? = nil
    ) throws {
        try pool.write { database in
            guard try database.tableExists("processing_checkpoints") else { return }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM processing_checkpoints WHERE video_id = ? AND stage = ? AND item_key = ?",
                arguments: [videoID, stage.rawValue, itemKey]
            ) else { throw ProcessingRecoveryError.missingCheckpoint(videoID: videoID, stage: stage, itemKey: itemKey) }
            let current = Self.processingCheckpoint(from: row)
            guard current.inputFingerprint == inputFingerprint else {
                throw ProcessingRecoveryError.inputChanged(videoID: videoID, stage: stage, itemKey: itemKey)
            }
            guard current.state == .running,
                  expectedRequestID == nil || current.requestID == expectedRequestID else {
                throw ProcessingRecoveryError.unknownOutcome(videoID: videoID, stage: stage, itemKey: itemKey)
            }
            try database.execute(
                sql: "UPDATE processing_checkpoints SET state = ?, output_data = ?, error_message = NULL, updated_at = ? WHERE id = ?",
                arguments: [ProcessingCheckpointState.completed.rawValue, outputData, Date.now.timeIntervalSince1970, current.id]
            )
        }
    }

    /// `unknownOutcome` is used for provider calls whose request may have
    /// reached the provider even though the response was lost. Local OCR and
    /// deterministic failures can use `false` and remain retryable.
    public func failProcessingCheckpoint(
        videoID: String,
        stage: ProcessingCheckpointStage,
        itemKey: String,
        errorMessage: String,
        unknownOutcome: Bool,
        expectedRequestID: String? = nil
    ) throws {
        try pool.write { database in
            guard try database.tableExists("processing_checkpoints") else { return }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM processing_checkpoints WHERE video_id = ? AND stage = ? AND item_key = ?",
                arguments: [videoID, stage.rawValue, itemKey]
            ) else { throw ProcessingRecoveryError.missingCheckpoint(videoID: videoID, stage: stage, itemKey: itemKey) }
            let current = Self.processingCheckpoint(from: row)
            guard current.state == .running,
                  expectedRequestID == nil || current.requestID == expectedRequestID else {
                throw ProcessingRecoveryError.unknownOutcome(videoID: videoID, stage: stage, itemKey: itemKey)
            }
            let state: ProcessingCheckpointState = unknownOutcome ? .unknown : .failed
            try database.execute(
                sql: "UPDATE processing_checkpoints SET state = ?, error_message = ?, updated_at = ? WHERE video_id = ? AND stage = ? AND item_key = ?",
                arguments: [state.rawValue, errorMessage, Date.now.timeIntervalSince1970, videoID, stage.rawValue, itemKey]
            )
        }
    }

    /// Explicit reconciliation is required before a request marked unknown
    /// can be attempted again.
    public func resetProcessingCheckpoint(
        videoID: String,
        stage: ProcessingCheckpointStage,
        itemKey: String,
        expectedRequestID: String? = nil
    ) throws {
        try pool.write { database in
            guard try database.tableExists("processing_checkpoints") else { return }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM processing_checkpoints WHERE video_id = ? AND stage = ? AND item_key = ?",
                arguments: [videoID, stage.rawValue, itemKey]
            ) else { throw ProcessingRecoveryError.missingCheckpoint(videoID: videoID, stage: stage, itemKey: itemKey) }
            let current = Self.processingCheckpoint(from: row)
            if let expectedRequestID, current.requestID != expectedRequestID {
                throw ProcessingRecoveryError.unknownOutcome(videoID: videoID, stage: stage, itemKey: itemKey)
            }
            try database.execute(
                sql: "UPDATE processing_checkpoints SET state = ?, output_data = NULL, error_message = NULL, request_id = NULL, updated_at = ? WHERE id = ?",
                arguments: [ProcessingCheckpointState.failed.rawValue, Date.now.timeIntervalSince1970, current.id]
            )
        }
    }

    public func processingCheckpoints(videoID: String) throws -> [ProcessingCheckpoint] {
        try pool.read { database in
            guard try database.tableExists("processing_checkpoints") else { return [] }
            return try Row.fetchAll(
                database,
                sql: "SELECT * FROM processing_checkpoints WHERE video_id = ? ORDER BY stage, item_key",
                arguments: [videoID]
            ).map(Self.processingCheckpoint(from:))
        }
    }

    public func clearProcessingCheckpoints(videoID: String) throws {
        try pool.write { database in
            guard try database.tableExists("processing_checkpoints") else { return }
            try database.execute(sql: "DELETE FROM processing_checkpoints WHERE video_id = ?", arguments: [videoID])
        }
    }
}

private extension VideoContextStore {
    static func writeProcessingCheckpoint(_ value: ProcessingCheckpoint, into database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO processing_checkpoints
                    (id, video_id, stage, item_key, input_fingerprint, state, output_data, provider, model, request_id, error_message, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(video_id, stage, item_key) DO UPDATE SET
                    id = excluded.id,
                    input_fingerprint = excluded.input_fingerprint,
                    state = excluded.state,
                    output_data = excluded.output_data,
                    provider = excluded.provider,
                    model = excluded.model,
                    request_id = excluded.request_id,
                    error_message = excluded.error_message,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                value.id, value.videoID, value.stage.rawValue, value.itemKey,
                value.inputFingerprint, value.state.rawValue, value.outputData,
                value.provider, value.model, value.requestID, value.errorMessage,
                value.createdAt.timeIntervalSince1970, value.updatedAt.timeIntervalSince1970
            ]
        )
    }

    static func processingCheckpoint(from row: Row) -> ProcessingCheckpoint {
        ProcessingCheckpoint(
            id: row["id"], videoID: row["video_id"],
            stage: ProcessingCheckpointStage(rawValue: row["stage"]) ?? .analysisBatch,
            itemKey: row["item_key"], inputFingerprint: row["input_fingerprint"],
            state: ProcessingCheckpointState(rawValue: row["state"]) ?? .failed,
            outputData: row["output_data"], provider: row["provider"], model: row["model"],
            requestID: row["request_id"], errorMessage: row["error_message"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }
}
