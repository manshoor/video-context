import Foundation
import GRDB

public struct DiagnosticRecordingMetadata: Codable, Sendable {
    public let context: DiagnosticContext
    public let status: ProcessingStatus
    public let revisions: ArtifactRevision
    public let transcriptSegments: Int
    public let screenshots: Int
    public let hasBrief: Bool
    public let taskCount: Int
    public let proposalCount: Int
    public let providers: [DiagnosticContext]
}
extension VideoContextStore {
    /// All selected recordings and their counts come from one read transaction, never library documents.
    public func diagnosticMetadata(videoID: String? = nil) throws -> [DiagnosticRecordingMetadata] {
        try pool.read { db in
            let ids = try String.fetchAll(db, sql: videoID == nil ? "SELECT id FROM videos ORDER BY id" : "SELECT id FROM videos WHERE id = ?", arguments: videoID.map { [$0] } ?? [])
            return try ids.compactMap { id in
                guard let video = try Self.fetchVideo(id: id, from: db) else { return nil }
                func count(_ table: String) throws -> Int {
                    guard try db.tableExists(table) else { return 0 }
                    return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE video_id = ?", arguments: [id]) ?? 0
                }
                let rows = try db.tableExists("artifact_provenance") ? Row.fetchAll(db, sql: "SELECT provider, model FROM artifact_provenance WHERE video_id = ?", arguments: [id]) : []
                let providers = rows.map { DiagnosticContext(provider: InferenceProvider(rawValue: $0["provider"]), model: $0["model"]) }
                return try .init(context: .init(videoID: id), status: video.status, revisions: video.revisions,
                    transcriptSegments: count("transcript_segments"), screenshots: count("evidence_items"), hasBrief: count("briefs") > 0,
                    taskCount: count("video_tasks"), proposalCount: count("task_proposals"), providers: providers)
            }
        }
    }
}
