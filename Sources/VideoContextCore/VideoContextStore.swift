import Foundation
import GRDB

public enum VideoContextStoreAccess: Sendable {
    case readWrite
    case readOnly
}

public actor VideoContextStore {
    let pool: DatabasePool

    public init(databaseURL: URL, access: VideoContextStoreAccess = .readWrite) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.readonly = access == .readOnly
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        if access == .readWrite {
            try Self.backupBeforeProjectMigration(pool: pool, databaseURL: databaseURL)
            try Self.backupBeforeProductDocumentationMigration(pool: pool, databaseURL: databaseURL)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("createLibrary") { database in
                try Self.createSchema(in: database)
            }
            migrator.registerMigration("addAPIUsage") { database in
                try database.execute(sql: """
                    CREATE TABLE api_usage (
                        id TEXT PRIMARY KEY,
                        video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                        stage TEXT NOT NULL,
                        model TEXT NOT NULL,
                        input_tokens INTEGER,
                        output_tokens INTEGER,
                        total_tokens INTEGER,
                        audio_seconds REAL,
                        created_at REAL NOT NULL
                    );
                    CREATE INDEX api_usage_video_time ON api_usage(video_id, created_at);
                    """)
            }
            migrator.registerMigration("addLocalProviderProvenance") { database in
                try database.execute(sql: """
                    ALTER TABLE api_usage ADD COLUMN provider TEXT NOT NULL DEFAULT 'openAI';
                    CREATE TABLE artifact_provenance (
                        video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                        stage TEXT NOT NULL, revision INTEGER NOT NULL,
                        provider TEXT NOT NULL, model TEXT NOT NULL,
                        PRIMARY KEY(video_id, stage, revision)
                    );
                    """)
            }
            migrator.registerMigration("reviewedTasks") { try Self.createTaskSchema(in: $0) }
            migrator.registerMigration("aiUsageRuns") { try Self.createUsageSchema(in: $0) }
            migrator.registerMigration("feedbackBatches") { try Self.createFeedbackSchema(in: $0) }
            migrator.registerMigration("feedbackProjects") { try Self.createFeedbackProjectSchema(in: $0) }
            migrator.registerMigration("projectWorkspaceOwnership") { try Self.createProjectWorkspaceSchema(in: $0) }
            migrator.registerMigration("productDocumentationV1") { database in
                try Self.createTaskDeletionSchema(in: database)
                try Self.createProjectDocumentationSchema(in: database)
                try Self.createProcessingRecoverySchema(in: database)
                try Self.createSourceArtifactHistorySchema(in: database)
                try Self.createFeedbackImportRecoverySchema(in: database)
                try Self.createFeedbackSourceHistorySchema(in: database)
                try Self.createAudioCoverageSchema(in: database)
                try Self.createDocumentationAnalysisCheckpointSchema(in: database)
                if try !database.columns(in: "evidence_items").contains(where: { $0.name == "requested_timestamp" }) {
                    try database.execute(sql: "ALTER TABLE evidence_items ADD COLUMN requested_timestamp REAL")
                }
            }
            migrator.registerMigration("productDocumentationRecoveryV1") { database in
                // Also upgrade libraries created by an earlier documentation build.
                try Self.migrateProjectDocumentationImportJobs(in: database)
                try Self.createProcessingRecoverySchema(in: database)
                try Self.createSourceArtifactHistorySchema(in: database)
                try Self.createFeedbackImportRecoverySchema(in: database)
                try Self.createFeedbackSourceHistorySchema(in: database)
                try Self.createAudioCoverageSchema(in: database)
                try Self.createDocumentationAnalysisCheckpointSchema(in: database)
                if try !database.columns(in: "evidence_items").contains(where: { $0.name == "requested_timestamp" }) {
                    try database.execute(sql: "ALTER TABLE evidence_items ADD COLUMN requested_timestamp REAL")
                }
            }
            migrator.registerMigration("projectAnalysisSelectionV1") { try Self.createProjectAnalysisSchema(in: $0) }
            try migrator.migrate(pool)
        }
    }

    public func createVideo(_ video: VideoRecord) throws {
        try pool.write { database in
            try Self.insertVideo(video, into: database)
        }
    }

    public func updateVideo(
        id: String,
        title: String? = nil,
        duration: TimeInterval? = nil,
        status: ProcessingStatus? = nil,
        errorMessage: String? = nil,
        estimatedCostUSD: Double? = nil
    ) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: id, from: database) else {
                throw VideoContextStoreError.videoNotFound(id)
            }
            if let title { video.title = title }
            if let duration { video.duration = duration }
            if let status { video.status = status }
            video.errorMessage = errorMessage
            if let estimatedCostUSD { video.estimatedCostUSD = estimatedCostUSD }
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
        }
    }

    public func listVideos(query: String? = nil, cursor: String? = nil, limit: Int = 20) throws -> Page<VideoRecord> {
        let offset = try Self.offset(from: cursor, limit: limit)
        return try pool.read { database in
            let pattern = "%\((query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))%"
            let sql: String
            let arguments: StatementArguments
            if query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                sql = "SELECT * FROM videos WHERE title LIKE ? COLLATE NOCASE ORDER BY updated_at DESC, id LIMIT ? OFFSET ?"
                arguments = [pattern, limit + 1, offset]
            } else {
                sql = "SELECT * FROM videos ORDER BY updated_at DESC, id LIMIT ? OFFSET ?"
                arguments = [limit + 1, offset]
            }
            let rows = try Row.fetchAll(database, sql: sql, arguments: arguments)
            let hasMore = rows.count > limit
            let videos = rows.prefix(limit).map(Self.video(from:))
            return Page(items: Array(videos), nextCursor: hasMore ? PaginationCursor(offset: offset + limit).encoded : nil)
        }
    }

    public func videoSnapshot(id: String) throws -> VideoSnapshot? {
        try pool.read { database in
            guard let video = try Self.fetchVideo(id: id, from: database) else { return nil }
            let transcript = try Row.fetchAll(
                database,
                sql: "SELECT * FROM transcript_segments WHERE video_id = ? ORDER BY start_time, id",
                arguments: [id]
            ).map(Self.transcript(from:))
            let evidence = try Row.fetchAll(
                database,
                sql: "SELECT * FROM evidence_items WHERE video_id = ? ORDER BY timestamp, id",
                arguments: [id]
            ).map(Self.evidence(from:))
            let briefRow = try Row.fetchOne(database, sql: "SELECT * FROM briefs WHERE video_id = ?", arguments: [id])
            let usage = try Row.fetchAll(
                database,
                sql: "SELECT * FROM api_usage WHERE video_id = ? ORDER BY created_at, id",
                arguments: [id]
            ).map(Self.apiUsage(from:))
            return VideoSnapshot(
                video: video,
                transcript: transcript,
                evidence: evidence,
                brief: briefRow.map(Self.brief(from:)),
                apiUsage: usage,
                provenance: try database.tableExists("artifact_provenance") ? Row.fetchAll(database,
                    sql: "SELECT * FROM artifact_provenance WHERE video_id = ? ORDER BY revision, stage", arguments: [id]).map {
                    ArtifactProvenance(stage: APIUsageStage(rawValue: $0["stage"]) ?? .analysis,
                        revision: $0["revision"], identity: ProviderIdentity(provider: InferenceProvider(rawValue: $0["provider"]) ?? .openAI, model: $0["model"]))
                } : []
            )
        }
    }

    public func recordAPIUsage(_ usage: APIUsageRecord) throws {
        try pool.write { database in
            guard try Self.fetchVideo(id: usage.videoID, from: database) != nil else {
                throw VideoContextStoreError.videoNotFound(usage.videoID)
            }
            try database.execute(
                sql: "INSERT INTO api_usage (id, video_id, stage, model, input_tokens, output_tokens, total_tokens, audio_seconds, created_at, provider) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    usage.id, usage.videoID, usage.stage.rawValue, usage.model,
                    usage.inputTokens, usage.outputTokens, usage.totalTokens,
                    usage.audioSeconds, usage.createdAt.timeIntervalSince1970, usage.provider.rawValue
                ]
            )
        }
    }

    public func publishArtifacts(
        videoID: String,
        transcript: [TranscriptSegment],
        evidence: [EvidenceItem],
        brief: BriefDocument
    ) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            try Self.preserveCurrentArtifacts(videoID: videoID, stages: [.transcript, .evidence, .brief], db: database)
            try database.execute(sql: "DELETE FROM transcript_segments WHERE video_id = ?", arguments: [videoID])
            try database.execute(sql: "DELETE FROM evidence_items WHERE video_id = ?", arguments: [videoID])
            try database.execute(sql: "DELETE FROM briefs WHERE video_id = ?", arguments: [videoID])
            try database.execute(sql: "DELETE FROM search_index WHERE video_id = ?", arguments: [videoID])

            for segment in transcript { try Self.insertTranscript(segment, into: database) }
            for item in evidence { try Self.insertEvidence(item, into: database) }
            try Self.insertBrief(brief, into: database)

            video.revisions.transcript += 1
            video.revisions.evidence += 1
            video.revisions.brief += 1
            video.revisions.briefSourceTranscript = video.revisions.transcript
            video.revisions.briefSourceEvidence = video.revisions.evidence
            video.status = .ready
            video.errorMessage = nil
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: videoID, in: database)
        }
    }

    public func correctTranscript(segmentID: String, correctedText: String) throws {
        try pool.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT video_id FROM transcript_segments WHERE id = ?", arguments: [segmentID]) else {
                throw VideoContextStoreError.transcriptSegmentNotFound(segmentID)
            }
            let videoID: String = row["video_id"]
            try Self.preserveCurrentArtifacts(videoID: videoID, stages: [.transcript], db: database)
            try database.execute(
                sql: "UPDATE transcript_segments SET corrected_text = ? WHERE id = ?",
                arguments: [correctedText, segmentID]
            )
            guard var video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            video.revisions = video.revisions.afterTranscriptCorrection()
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: videoID, in: database)
        }
    }

    public func replaceTranscript(videoID: String, segments: [TranscriptSegment], provenance: ProviderIdentity? = nil) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            try Self.preserveCurrentArtifacts(videoID: videoID, stages: [.transcript], db: database)
            try database.execute(sql: "DELETE FROM transcript_segments WHERE video_id = ?", arguments: [videoID])
            for segment in segments { try Self.insertTranscript(segment, into: database) }
            video.revisions.transcript += 1
            try Self.insertProvenance(provenance, videoID: videoID, stage: .transcription, revision: video.revisions.transcript, into: database)
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: videoID, in: database)
        }
    }

    public func replaceEvidence(videoID: String, items: [EvidenceItem], expectedEvidenceRevision: Int? = nil) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            if let expectedEvidenceRevision, video.revisions.evidence != expectedEvidenceRevision {
                throw LocalProviderError.configuration("Screenshots changed during processing. Your screenshots were preserved. Resume to use the updated evidence.")
            }
            try Self.preserveCurrentArtifacts(videoID: videoID, stages: [.evidence], db: database)
            try database.execute(sql: "DELETE FROM evidence_items WHERE video_id = ?", arguments: [videoID])
            for item in items { try Self.insertEvidence(item, into: database) }
            video.revisions.evidence += 1
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: videoID, in: database)
        }
    }

    public func addEvidence(_ item: EvidenceItem) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: item.videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(item.videoID)
            }
            try Self.preserveCurrentArtifacts(videoID: item.videoID, stages: [.evidence], db: database)
            try Self.insertEvidence(item, into: database)
            video.revisions = video.revisions.afterEvidenceCorrection()
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: item.videoID, in: database)
        }
    }

    public func publishBrief(videoID: String, brief: BriefDocument, provenance: ProviderIdentity? = nil, expectedRevision: ArtifactRevision? = nil) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            if let expectedRevision, video.revisions != expectedRevision {
                throw LocalProviderError.configuration("The recording was corrected during analysis. Your corrections were preserved. Resume processing to generate a brief from the current evidence.")
            }
            try Self.preserveCurrentArtifacts(videoID: videoID, stages: [.brief], db: database)
            try database.execute(sql: "DELETE FROM briefs WHERE video_id = ?", arguments: [videoID])
            try Self.insertBrief(brief, into: database)
            video.revisions = video.revisions.afterBriefRegeneration()
            try Self.insertProvenance(provenance, videoID: videoID, stage: .analysis, revision: video.revisions.brief, into: database)
            video.status = .ready
            video.errorMessage = nil
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: videoID, in: database)
        }
    }

    public func markIncomplete(videoID: String, error: String) throws {
        try updateVideo(id: videoID, status: .incomplete, errorMessage: error)
    }

    public func updateBrief(videoID: String, markdown: String, userEdited: Bool = true) throws {
        try pool.write { database in
            guard var video = try Self.fetchVideo(id: videoID, from: database) else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            try Self.preserveCurrentArtifacts(videoID: videoID, stages: [.brief], db: database)
            try database.execute(
                sql: "INSERT INTO briefs (video_id, markdown, is_user_edited) VALUES (?, ?, ?) ON CONFLICT(video_id) DO UPDATE SET markdown = excluded.markdown, is_user_edited = excluded.is_user_edited",
                arguments: [videoID, markdown, userEdited]
            )
            video.revisions.brief += 1
            video.revisions.briefSourceTranscript = video.revisions.transcript
            video.revisions.briefSourceEvidence = video.revisions.evidence
            video.updatedAt = .now
            try Self.updateVideoRow(video, in: database)
            try Self.rebuildSearchIndex(videoID: videoID, in: database)
        }
    }

    public func search(videoID: String, query: String, cursor: String? = nil, limit: Int = 20) throws -> Page<SearchHit> {
        let offset = try Self.offset(from: cursor, limit: limit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw VideoContextStoreError.emptyQuery }
        let match = Self.ftsQuery(trimmed)
        return try pool.read { database in
            guard try Self.fetchVideo(id: videoID, from: database) != nil else {
                throw VideoContextStoreError.videoNotFound(videoID)
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT ref_id, kind, text, start_time, end_time
                    FROM search_index
                    WHERE search_index MATCH ? AND video_id = ?
                    ORDER BY bm25(search_index), rowid
                    LIMIT ? OFFSET ?
                    """,
                arguments: [match, videoID, limit + 1, offset]
            )
            let hasMore = rows.count > limit
            let hits = rows.prefix(limit).compactMap(Self.searchHit(from:))
            return Page(items: Array(hits), nextCursor: hasMore ? PaginationCursor(offset: offset + limit).encoded : nil)
        }
    }

    public func segment(videoID: String, start: TimeInterval, end: TimeInterval, cursor: String? = nil, limit: Int = 50) throws -> Page<TranscriptSegment> {
        let offset = try Self.offset(from: cursor, limit: limit)
        return try pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM transcript_segments WHERE video_id = ? AND end_time >= ? AND start_time <= ? ORDER BY start_time, id LIMIT ? OFFSET ?",
                arguments: [videoID, start, end, limit + 1, offset]
            )
            let hasMore = rows.count > limit
            return Page(items: Array(rows.prefix(limit).map(Self.transcript(from:))), nextCursor: hasMore ? PaginationCursor(offset: offset + limit).encoded : nil)
        }
    }

    public func evidence(videoID: String, from start: TimeInterval, through end: TimeInterval) throws -> [EvidenceItem] {
        try pool.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM evidence_items WHERE video_id = ? AND timestamp BETWEEN ? AND ? ORDER BY timestamp, id",
                arguments: [videoID, start, end]
            ).map(Self.evidence(from:))
        }
    }
}

extension VideoContextStore {
    static func createSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE videos (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source_type TEXT NOT NULL,
                source_value TEXT NOT NULL,
                media_path TEXT NOT NULL,
                duration REAL NOT NULL,
                status TEXT NOT NULL,
                error_message TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                transcript_revision INTEGER NOT NULL DEFAULT 0,
                evidence_revision INTEGER NOT NULL DEFAULT 0,
                brief_revision INTEGER NOT NULL DEFAULT 0,
                brief_source_transcript INTEGER NOT NULL DEFAULT 0,
                brief_source_evidence INTEGER NOT NULL DEFAULT 0,
                estimated_cost_usd REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE transcript_segments (
                id TEXT PRIMARY KEY,
                video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                original_text TEXT NOT NULL,
                corrected_text TEXT
            );
            CREATE INDEX transcript_video_time ON transcript_segments(video_id, start_time, end_time);
            CREATE TABLE evidence_items (
                id TEXT PRIMARY KEY,
                video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                timestamp REAL NOT NULL,
                image_path TEXT NOT NULL,
                ocr_text TEXT NOT NULL,
                origin TEXT NOT NULL
            );
            CREATE INDEX evidence_video_time ON evidence_items(video_id, timestamp);
            CREATE TABLE briefs (
                video_id TEXT PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
                markdown TEXT NOT NULL,
                is_user_edited INTEGER NOT NULL DEFAULT 0
            );
            CREATE VIRTUAL TABLE search_index USING fts5(
                video_id UNINDEXED,
                kind UNINDEXED,
                ref_id UNINDEXED,
                text,
                start_time UNINDEXED,
                end_time UNINDEXED,
                tokenize = 'unicode61'
            );
            """)
    }

    static func insertVideo(_ video: VideoRecord, into database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO videos (id,title,source_type,source_value,media_path,duration,status,error_message,created_at,updated_at,transcript_revision,evidence_revision,brief_revision,brief_source_transcript,brief_source_evidence,estimated_cost_usd,project_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: videoArguments(video)
        )
    }

    static func updateVideoRow(_ video: VideoRecord, in database: Database) throws {
        if let previous = try fetchVideo(id: video.id, from: database), previous.revisions != video.revisions {
            try invalidateTasks(videoID: video.id, in: database)
        }
        try database.execute(
            sql: """
                UPDATE videos SET title = ?, source_type = ?, source_value = ?, media_path = ?, duration = ?, status = ?, error_message = ?, created_at = ?, updated_at = ?, transcript_revision = ?, evidence_revision = ?, brief_revision = ?, brief_source_transcript = ?, brief_source_evidence = ?, estimated_cost_usd = ? WHERE id = ?
                """,
            arguments: [
                video.title, video.source.rawValue, video.sourceValue, video.mediaRelativePath,
                video.duration, video.status.rawValue, video.errorMessage,
                video.createdAt.timeIntervalSince1970, video.updatedAt.timeIntervalSince1970,
                video.revisions.transcript, video.revisions.evidence, video.revisions.brief,
                video.revisions.briefSourceTranscript, video.revisions.briefSourceEvidence,
                video.estimatedCostUSD, video.id
            ]
        )
    }

    static func videoArguments(_ video: VideoRecord) -> StatementArguments {
        [
            video.id, video.title, video.source.rawValue, video.sourceValue, video.mediaRelativePath,
            video.duration, video.status.rawValue, video.errorMessage,
            video.createdAt.timeIntervalSince1970, video.updatedAt.timeIntervalSince1970,
            video.revisions.transcript, video.revisions.evidence, video.revisions.brief,
            video.revisions.briefSourceTranscript, video.revisions.briefSourceEvidence,
            video.estimatedCostUSD, video.projectID
        ]
    }

    static func fetchVideo(id: String, from database: Database) throws -> VideoRecord? {
        try Row.fetchOne(database, sql: "SELECT * FROM videos WHERE id = ?", arguments: [id]).map(video(from:))
    }

    static func video(from row: Row) -> VideoRecord {
        VideoRecord(
            id: row["id"],
            title: row["title"],
            source: VideoSource(rawValue: row["source_type"]) ?? .localFile,
            sourceValue: row["source_value"],
            mediaRelativePath: row["media_path"],
            duration: row["duration"],
            status: ProcessingStatus(rawValue: row["status"]) ?? .failed,
            errorMessage: row["error_message"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            revisions: ArtifactRevision(
                transcript: row["transcript_revision"],
                evidence: row["evidence_revision"],
                brief: row["brief_revision"],
                briefSourceTranscript: row["brief_source_transcript"],
                briefSourceEvidence: row["brief_source_evidence"]
            ),
            estimatedCostUSD: row["estimated_cost_usd"],
            projectID: row.hasColumn("project_id") ? row["project_id"] : nil
        )
    }

    static func insertTranscript(_ segment: TranscriptSegment, into database: Database) throws {
        try database.execute(
            sql: "INSERT INTO transcript_segments VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [segment.id, segment.videoID, segment.start, segment.end, segment.originalText, segment.correctedText]
        )
    }

    static func transcript(from row: Row) -> TranscriptSegment {
        TranscriptSegment(
            id: row["id"], videoID: row["video_id"], start: row["start_time"], end: row["end_time"],
            originalText: row["original_text"], correctedText: row["corrected_text"]
        )
    }

    static func insertEvidence(_ item: EvidenceItem, into database: Database) throws {
        try database.execute(
            sql: "INSERT INTO evidence_items(id,video_id,timestamp,image_path,ocr_text,origin,requested_timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [item.id, item.videoID, item.timestamp, item.imageRelativePath, item.ocrText, item.origin.rawValue, item.requestedTimestamp]
        )
    }

    static func evidence(from row: Row) -> EvidenceItem {
        EvidenceItem(
            id: row["id"], videoID: row["video_id"], requestedTimestamp: row.hasColumn("requested_timestamp") ? row["requested_timestamp"] : nil, timestamp: row["timestamp"],
            imageRelativePath: row["image_path"], ocrText: row["ocr_text"],
            origin: EvidenceOrigin(rawValue: row["origin"]) ?? .automatic
        )
    }

    static func insertBrief(_ brief: BriefDocument, into database: Database) throws {
        try database.execute(
            sql: "INSERT INTO briefs VALUES (?, ?, ?)",
            arguments: [brief.videoID, brief.markdown, brief.isUserEdited]
        )
    }

    static func brief(from row: Row) -> BriefDocument {
        BriefDocument(videoID: row["video_id"], markdown: row["markdown"], isUserEdited: row["is_user_edited"])
    }

    private static func insertProvenance(_ identity: ProviderIdentity?, videoID: String, stage: APIUsageStage, revision: Int, into database: Database) throws {
        guard let identity else { return }
        try database.execute(sql: "INSERT OR REPLACE INTO artifact_provenance VALUES (?, ?, ?, ?, ?)",
                             arguments: [videoID, stage.rawValue, revision, identity.provider.rawValue, identity.model])
    }

    static func apiUsage(from row: Row) -> APIUsageRecord {
        APIUsageRecord(
            id: row["id"],
            videoID: row["video_id"],
            stage: APIUsageStage(rawValue: row["stage"]) ?? .analysis,
            model: row["model"],
            provider: row.hasColumn("provider") ? InferenceProvider(rawValue: row["provider"]) ?? .openAI : .openAI,
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            totalTokens: row["total_tokens"],
            audioSeconds: row["audio_seconds"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    static func rebuildSearchIndex(videoID: String, in database: Database) throws {
        try database.execute(sql: "DELETE FROM search_index WHERE video_id = ?", arguments: [videoID])
        try database.execute(
            sql: "INSERT INTO search_index SELECT video_id, 'transcript', id, COALESCE(corrected_text, original_text), start_time, end_time FROM transcript_segments WHERE video_id = ?",
            arguments: [videoID]
        )
        try database.execute(
            sql: "INSERT INTO search_index SELECT video_id, 'evidence', id, ocr_text, timestamp, timestamp FROM evidence_items WHERE video_id = ? AND ocr_text <> ''",
            arguments: [videoID]
        )
        try database.execute(
            sql: "INSERT INTO search_index SELECT video_id, 'brief', video_id, markdown, NULL, NULL FROM briefs WHERE video_id = ?",
            arguments: [videoID]
        )
    }

    static func searchHit(from row: Row) -> SearchHit? {
        guard let kind = SearchHitKind(rawValue: row["kind"]) else { return nil }
        return SearchHit(id: row["ref_id"], kind: kind, text: row["text"], start: row["start_time"], end: row["end_time"])
    }

    static func offset(from cursor: String?, limit: Int) throws -> Int {
        guard (1...100).contains(limit) else { throw VideoContextStoreError.invalidLimit }
        guard let cursor else { return 0 }
        guard let decoded = PaginationCursor(encoded: cursor) else { throw VideoContextStoreError.invalidCursor }
        return decoded.offset
    }

    static func ftsQuery(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace }).map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }
}
