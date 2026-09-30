import Foundation
import GRDB

extension VideoContextStore {
    static func preserveCurrentArtifacts(videoID: String, stages: [SourceArtifactHistoryStage], db: Database) throws {
        guard try db.tableExists("source_artifact_history"), let video = try fetchVideo(id: videoID, from: db) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for stage in stages {
            let data: Data
            let revision: Int
            switch stage {
            case .transcript:
                revision = video.revisions.transcript
                let values = try Row.fetchAll(db, sql: "SELECT * FROM transcript_segments WHERE video_id=? ORDER BY start_time,id", arguments: [videoID]).map(transcript(from:))
                data = try encoder.encode(values)
            case .evidence:
                revision = video.revisions.evidence
                let values = try Row.fetchAll(db, sql: "SELECT * FROM evidence_items WHERE video_id=? ORDER BY timestamp,id", arguments: [videoID]).map(evidence(from:))
                data = try encoder.encode(values)
            case .brief:
                revision = video.revisions.brief
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM briefs WHERE video_id=?", arguments: [videoID]) else { continue }
                data = try encoder.encode(brief(from: row))
            }
            guard revision > 0 else { continue }
            try captureHistory(db: db, videoID: videoID, stage: stage, revision: revision, artifactData: data)
        }
    }
}
