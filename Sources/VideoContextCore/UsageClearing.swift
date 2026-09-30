import Foundation
import GRDB

public enum UsageClearScope: Sendable, Equatable {
    case run(String)
    case recording(String)
    case library
}

public enum UsageClearError: Error, Equatable, Sendable {
    case stalePreview
    case noFinishedHistory
}

/// An immutable confirmation snapshot. Only the store can construct deletion targets.
public struct UsageClearPreview: Sendable, Identifiable {
    public let id = UUID()
    public let scope: UsageClearScope
    public let runCount: Int
    public let requestCount: Int
    public let earlierEntryCount: Int
    public let retainedActiveRunCount: Int
    public var isEmpty: Bool { runCount + earlierEntryCount == 0 }
    fileprivate let libraryPath: String
    fileprivate let runs: [String: RunTarget]
    fileprivate let earlier: [String: APIUsageRecord]

    fileprivate struct RunTarget: Sendable, Equatable {
        let videoID: String?
        let document: Data
        let attempts: [String: Data]
        let cacheKeys: [String]
    }
}

extension UsageOutcome {
    public var permitsUsageClearing: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: true
        case .running, .responseReceived: false
        }
    }
}

extension VideoContextStore {
    public func prepareUsageClear(_ scope: UsageClearScope) throws -> UsageClearPreview {
        try recoverInterruptedUsageRuns()
        return try pool.read { db in
            if case .recording(let id) = scope,
               try String.fetchOne(db, sql: "SELECT id FROM videos WHERE id = ?", arguments: [id]) == nil {
                throw TaskContextError.missing(id)
            }
            var targets: [String: UsageClearPreview.RunTarget] = [:]
            var earlier: [String: APIUsageRecord] = [:]
            var retained = 0
            var found = false
            for row in try Row.fetchAll(db, sql: "SELECT id, video_id, document FROM usage_runs") {
                let id: String = row["id"], videoID: String? = row["video_id"]
                guard Self.clearScope(scope, includes: id, videoID: videoID) else { continue }
                found = true
                let data: Data = row["document"]
                let run = try JSONDecoder().decode(UsageRun.self, from: data)
                guard run.id == id, run.videoID == videoID else { throw UsageClearError.stalePreview }
                guard run.outcome.permitsUsageClearing else { retained += 1; continue }
                targets[id] = try Self.usageClearTarget(db, id: id, videoID: videoID, document: data)
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM api_usage") {
                let entry = Self.apiUsage(from: row)
                guard Self.clearScope(scope, includes: "earlier_" + entry.id, videoID: entry.videoID) else { continue }
                found = true
                earlier[entry.id] = entry
            }
            if case .run(let id) = scope, !found { throw TaskContextError.missing(id) }
            return UsageClearPreview(scope: scope, runCount: targets.count,
                requestCount: targets.values.reduce(0) { $0 + $1.attempts.count },
                earlierEntryCount: earlier.count, retainedActiveRunCount: retained,
                libraryPath: pool.path, runs: targets, earlier: earlier)
        }
    }

    public func clearUsage(_ preview: UsageClearPreview) throws {
        guard preview.libraryPath == pool.path else { throw UsageClearError.stalePreview }
        guard !preview.isEmpty else { throw UsageClearError.noFinishedHistory }
        try pool.write { db in
            // Revalidate the complete confirmation before any deletion. New or newly finished
            // runs are deliberately absent from the immutable target set.
            for (id, expected) in preview.runs {
                guard let row = try Row.fetchOne(db, sql: "SELECT video_id, document FROM usage_runs WHERE id = ?", arguments: [id]) else {
                    throw UsageClearError.stalePreview
                }
                let videoID: String? = row["video_id"], data: Data = row["document"]
                let run = try JSONDecoder().decode(UsageRun.self, from: data)
                guard Self.clearScope(preview.scope, includes: id, videoID: videoID),
                      run.id == id, run.videoID == videoID, run.outcome.permitsUsageClearing,
                      try Self.usageClearTarget(db, id: id, videoID: videoID, document: data) == expected else {
                    throw UsageClearError.stalePreview
                }
            }
            for (id, expected) in preview.earlier {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM api_usage WHERE id = ?", arguments: [id]),
                      Self.apiUsage(from: row) == expected,
                      Self.clearScope(preview.scope, includes: "earlier_" + id, videoID: expected.videoID) else {
                    throw UsageClearError.stalePreview
                }
            }
            for id in preview.runs.keys.sorted() {
                try db.execute(sql: "DELETE FROM usage_attempts WHERE run_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM usage_cache_origins WHERE run_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM usage_runs WHERE id = ?", arguments: [id])
            }
            for id in preview.earlier.keys.sorted() {
                try db.execute(sql: "DELETE FROM api_usage WHERE id = ?", arguments: [id])
            }
        }
    }

    private static func clearScope(_ scope: UsageClearScope, includes runID: String, videoID: String?) -> Bool {
        switch scope {
        case .run(let id): id == runID
        case .recording(let id): id == videoID
        case .library: true
        }
    }

    private static func usageClearTarget(_ db: Database, id: String, videoID: String?, document: Data) throws -> UsageClearPreview.RunTarget {
        let attempts = try Row.fetchAll(db, sql: "SELECT id, document FROM usage_attempts WHERE run_id = ?", arguments: [id])
        let keys = try String.fetchAll(db, sql: "SELECT cache_key FROM usage_cache_origins WHERE run_id = ? ORDER BY cache_key", arguments: [id])
        return .init(videoID: videoID, document: document,
            attempts: Dictionary(uniqueKeysWithValues: attempts.map { ($0["id"] as String, $0["document"] as Data) }), cacheKeys: keys)
    }
}
