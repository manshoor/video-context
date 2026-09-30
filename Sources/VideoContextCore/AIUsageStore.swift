import Foundation
import GRDB
import Darwin

extension VideoContextStore {
    static func createUsageSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE usage_runs(id TEXT PRIMARY KEY, video_id TEXT REFERENCES videos(id), document BLOB NOT NULL);
        CREATE TABLE usage_attempts(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES usage_runs(id), document BLOB NOT NULL);
        CREATE INDEX usage_attempt_run ON usage_attempts(run_id);
        CREATE TABLE usage_cache_origins(cache_key TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES usage_runs(id));
        """)
    }
    public func startUsageRun(_ input: UsageRun) throws -> UsageRun {
        try pool.write { db in
            var run = input
            let old = try Data.fetchAll(db, sql: "SELECT document FROM usage_runs WHERE video_id IS ?", arguments: [run.videoID])
                .map { try JSONDecoder().decode(UsageRun.self, from: $0) }
                .filter { $0.feedbackBatchID == run.feedbackBatchID }
            run.resumedFrom = old.filter { $0.operation == run.operation && $0.fingerprint == run.fingerprint && [.failed, .cancelled, .interrupted].contains($0.outcome) }.max(by: { $0.startedAt < $1.startedAt })?.id
            try db.execute(sql: "INSERT INTO usage_runs(id,video_id,document) VALUES (?, ?, ?)", arguments: [run.id, run.videoID, try JSONEncoder().encode(run)])
            return run
        }
    }
    public func finishUsageRun(id: String, outcome: UsageOutcome, incomplete: Bool = false) throws {
        try pool.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT document FROM usage_runs WHERE id = ?", arguments: [id]) else { throw TaskContextError.missing(id) }
            var run = try JSONDecoder().decode(UsageRun.self, from: data)
            run.outcome = outcome; run.finishedAt = .now; run.accountingIncomplete = run.accountingIncomplete || incomplete
            try db.execute(sql: "UPDATE usage_runs SET document = ? WHERE id = ?", arguments: [try JSONEncoder().encode(run), id])
        }
    }
    public func saveUsageAttempt(_ attempt: UsageAttempt) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO usage_attempts VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET document=excluded.document", arguments: [attempt.id, attempt.runID, try JSONEncoder().encode(attempt)])
        }
    }
    public func recordUsageCache(key: String, runID: String, reused: Bool) throws {
        try pool.write { db in
            if !reused {
                try db.execute(sql: "INSERT OR IGNORE INTO usage_cache_origins VALUES (?, ?)", arguments: [key, runID]); return
            }
            guard let data = try Data.fetchOne(db, sql: "SELECT document FROM usage_runs WHERE id = ?", arguments: [runID]) else { return }
            var run = try JSONDecoder().decode(UsageRun.self, from: data)
            run.cachedBatches += 1
            if let origin = try String.fetchOne(db, sql: "SELECT run_id FROM usage_cache_origins WHERE cache_key = ?", arguments: [key]), origin != runID, !run.reusedRuns.contains(origin) { run.reusedRuns.append(origin) }
            try db.execute(sql: "UPDATE usage_runs SET document = ? WHERE id = ?", arguments: [try JSONEncoder().encode(run), runID])
        }
    }
    public func recordFeedbackValidationDiagnostics(runID: String, diagnostics: [FeedbackValidationDiagnostic], truncated: Bool) throws {
        try pool.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT document FROM usage_runs WHERE id = ?", arguments: [runID]) else { return }
            var run = try JSONDecoder().decode(UsageRun.self, from: data)
            var saved = run.feedbackValidationDiagnostics ?? []
            let remaining = max(0, 32 - saved.count)
            saved.append(contentsOf: diagnostics.prefix(remaining))
            run.feedbackValidationDiagnostics = saved
            run.feedbackValidationDiagnosticsTruncated = (run.feedbackValidationDiagnosticsTruncated ?? false) || truncated || diagnostics.count > remaining
            try db.execute(sql: "UPDATE usage_runs SET document = ? WHERE id = ?", arguments: [try JSONEncoder().encode(run), runID])
        }
    }
    public func recoverInterruptedUsageRuns() throws {
        try pool.write { db in
            for data in try Data.fetchAll(db, sql: "SELECT document FROM usage_runs") {
                var run = try JSONDecoder().decode(UsageRun.self, from: data)
                guard run.outcome == .running, kill(run.processID, 0) == -1, errno == ESRCH else { continue }
                run.outcome = .interrupted; run.finishedAt = .now
                for bytes in try Data.fetchAll(db, sql: "SELECT document FROM usage_attempts WHERE run_id = ?", arguments: [run.id]) {
                    var attempt = try JSONDecoder().decode(UsageAttempt.self, from: bytes)
                    if attempt.outcome == .running { attempt.outcome = .interrupted; run.accountingIncomplete = true
                        try db.execute(sql: "UPDATE usage_attempts SET document=? WHERE id=?", arguments: [try JSONEncoder().encode(attempt), attempt.id])
                    }
                }
                try db.execute(sql: "UPDATE usage_runs SET document=? WHERE id=?", arguments: [try JSONEncoder().encode(run), run.id])
            }
        }
    }
    public func usageSnapshot() throws -> UsageSnapshot {
        try pool.read { db in
            var runs = try Data.fetchAll(db, sql: "SELECT document FROM usage_runs").map { try JSONDecoder().decode(UsageRun.self, from: $0) }
            var attempts = try Data.fetchAll(db, sql: "SELECT document FROM usage_attempts").map { try JSONDecoder().decode(UsageAttempt.self, from: $0) }
            // Old records remain separate; no guessed invocation or task attribution.
            for row in try Row.fetchAll(db, sql: "SELECT * FROM api_usage") {
                let legacy = Self.apiUsage(from: row)
                var run = UsageRun(videoID: legacy.videoID, operation: .earlierUsage, provider: legacy.provider, model: legacy.model)
                run.id = "earlier_" + legacy.id; run.startedAt = legacy.createdAt; run.finishedAt = legacy.createdAt; run.outcome = .completed
                var attempt = UsageAttempt(runID: run.id, stage: legacy.stage == .transcription ? .transcription : legacy.stage == .taskGeneration ? .taskExtraction : .analysis, provider: legacy.provider, requestedModel: legacy.model)
                attempt.id = legacy.id; attempt.startedAt = legacy.createdAt; attempt.finishedAt = nil; attempt.outcome = .completed
                attempt.tokens = .init(input: legacy.inputTokens, output: legacy.outputTokens, total: legacy.totalTokens, audioSeconds: legacy.audioSeconds)
                runs.append(run); attempts.append(attempt)
            }
            let titles = try Row.fetchAll(db, sql: "SELECT id, title FROM videos").reduce(into: [String: String]()) { $0[$1["id"]] = $1["title"] }
            var result = UsageSnapshot(runs: runs.sorted { $0.startedAt > $1.startedAt }, attempts: attempts.sorted { $0.startedAt < $1.startedAt }, recordingTitles: titles)
            if try db.tableExists("feedback_batches") {
                for data in try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches") {
                    let batch = try JSONDecoder().decode(FeedbackBatch.self, from: data)
                    result.feedbackTitles[batch.id] = batch.title
                }
            }
            return result
        }
    }
}
