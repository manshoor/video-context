import Foundation
import CryptoKit
import GRDB
import Testing
@testable import VideoContextCore

struct UsageClearingTests {
    @Test func recordingScopePreservesActiveAndOtherHistoryAndFreezesTargets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (a, b) = try await fixture.videos()
        let finished = try await fixture.run(a.id, outcome: .completed)
        let active = try await fixture.run(a.id)
        let other = try await fixture.run(b.id, outcome: .failed)
        let modelTest = try await fixture.run(nil, outcome: .completed)
        try await fixture.store.recordAPIUsage(.init(videoID: a.id, stage: .analysis, model: "old", inputTokens: 7, outputTokens: 3))
        let preview = try await fixture.store.prepareUsageClear(.recording(a.id))
        #expect(preview.runCount == 1 && preview.requestCount == 1 && preview.earlierEntryCount == 1)
        #expect(preview.retainedActiveRunCount == 1)
        // Work finishing or starting after confirmation must not broaden deletion.
        try await fixture.store.finishUsageRun(id: active.id, outcome: .completed)
        let newer = try await fixture.run(a.id, outcome: .completed)
        try await fixture.store.clearUsage(preview)
        let remaining = try await fixture.store.usageSnapshot()
        #expect(Set(remaining.runs.map(\.id)) == Set([active.id, other.id, modelTest.id, newer.id]))
        #expect(remaining.attempts.contains { $0.runID == finished.id } == false)
        #expect(try await fixture.store.videoSnapshot(id: a.id)?.video.id == a.id)
        await #expect(throws: UsageClearError.stalePreview) { try await fixture.store.clearUsage(preview) }
    }

    @Test func selectedRunLegacyEntryAndLibraryAreExact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (a, b) = try await fixture.videos()
        let one = try await fixture.run(a.id, outcome: .cancelled)
        let two = try await fixture.run(b.id, outcome: .interrupted)
        let active = try await fixture.run(nil)
        try await fixture.store.recordAPIUsage(.init(videoID: b.id, stage: .analysis, model: "old"))
        let single = try await fixture.store.prepareUsageClear(.run(one.id))
        try await fixture.store.clearUsage(single)
        #expect(try await fixture.store.usageSnapshot().runs.contains { $0.id == two.id })
        let legacy = try #require(try await fixture.store.usageSnapshot().runs.first { $0.operation == .earlierUsage })
        let earlier = try await fixture.store.prepareUsageClear(.run(legacy.id))
        #expect(earlier.earlierEntryCount == 1 && earlier.runCount == 0)
        try await fixture.store.clearUsage(earlier)
        let all = try await fixture.store.prepareUsageClear(.library)
        try await fixture.store.clearUsage(all)
        #expect(try await fixture.store.usageSnapshot().runs.map(\.id) == [active.id])
        #expect(try await fixture.store.prepareUsageClear(.run(active.id)).isEmpty)
        #expect(try await fixture.store.prepareUsageClear(.library).isEmpty)
        await #expect(throws: (any Error).self) { try await fixture.store.prepareUsageClear(.run("missing")) }
        await #expect(throws: (any Error).self) { try await fixture.store.prepareUsageClear(.recording("missing")) }
    }

    @Test func changedAttemptAndOwnershipRejectPreviewAndStorageFailureRollsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (a, b) = try await fixture.videos()
        let run = try await fixture.run(a.id, outcome: .completed)
        let preview = try await fixture.store.prepareUsageClear(.library)
        var attempt = try #require(try await fixture.store.usageSnapshot().attempts.first)
        attempt.tokens = .init(input: 50, output: 12)
        try await fixture.store.saveUsageAttempt(attempt)
        await #expect(throws: UsageClearError.stalePreview) { try await fixture.store.clearUsage(preview) }
        let fresh = try await fixture.store.prepareUsageClear(.recording(a.id))
        let db = try DatabaseQueue(path: fixture.paths.database.path)
        try await db.write { db in
            try db.execute(sql: "UPDATE usage_runs SET video_id = ? WHERE id = ?", arguments: [b.id, run.id])
        }
        await #expect(throws: UsageClearError.stalePreview) { try await fixture.store.clearUsage(fresh) }
        try await db.write { db in
            try db.execute(sql: "UPDATE usage_runs SET video_id = ? WHERE id = ?", arguments: [a.id, run.id])
            try db.execute(sql: "CREATE TRIGGER fail_clear BEFORE DELETE ON usage_runs BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        await #expect(throws: (any Error).self) { try await fixture.store.clearUsage(fresh) }
        #expect(try await fixture.store.usageSnapshot().attempts.first?.tokens.total == 62)
        #expect(try await fixture.store.usageSnapshot().runs.count == 1)
    }

    @Test func proposalLinksContentAndActualCachesSurvive() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (a, _) = try await fixture.videos()
        try await fixture.store.publishArtifacts(videoID: a.id, transcript: [], evidence: [], brief: .init(videoID: a.id, markdown: "Saved brief"))
        let before = try #require(try await fixture.store.videoSnapshot(id: a.id))
        let source = try await fixture.store.taskSnapshot(videoID: a.id)
        let run = try await fixture.store.startUsageRun(.init(videoID: a.id, operation: .taskGeneration, provider: .lmStudio, model: "fixture"))
        var proposal = TaskProposal(videoID: a.id, kind: .addition, sourceRevision: source.video.revisions, content: .init(title: "Keep this task"), provenance: .init(provider: .lmStudio, model: "fixture"))
        proposal.generationRunID = run.id
        try await fixture.store.publishTaskProposals([proposal], videoID: a.id, expectedSource: source.video.revisions, expectedTasks: [:])
        try await fixture.store.recordUsageCache(key: "saved-cache", runID: run.id, reused: false)
        try await fixture.store.saveTaskCache(key: "saved-cache", data: Data("Validated generated content".utf8))
        let media = fixture.root.appending(path: "a.mp4")
        let screenshot = fixture.root.appending(path: "original-frame.jpg")
        try Data("Fixture media bytes".utf8).write(to: media)
        try Data("Fixture screenshot bytes".utf8).write(to: screenshot)
        let hashes = try [media, screenshot].map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let contentBefore = try await fixture.contentRows()
        try await fixture.store.finishUsageRun(id: run.id, outcome: .completed)
        let preview = try await fixture.store.prepareUsageClear(.run(run.id))
        // Dismissing confirmation simply does not call clearUsage.
        #expect(try await fixture.store.usageSnapshot().runs.count == 1)
        try await fixture.store.clearUsage(preview)
        #expect(try await fixture.contentRows() == contentBefore)
        #expect(try [media, screenshot].map { SHA256.hash(data: try Data(contentsOf: $0)) } == hashes)
        #expect(try await fixture.store.taskCache(key: "saved-cache") == Data("Validated generated content".utf8))
        try await fixture.store.resolveTaskProposal(videoID: a.id, proposalID: proposal.id, apply: true)
        var task = try #require(try await fixture.store.taskSnapshot(videoID: a.id).tasks.first)
        #expect(task.generationRunID == run.id)
        task.content.behavior = "User edit"
        let saved = try await fixture.store.saveTask(task, expectedRevision: task.revision, expectedSource: source.video.revisions)
        #expect(saved.generationRunID == run.id)
        let after = try #require(try await fixture.store.videoSnapshot(id: a.id))
        #expect(after.video.revisions == before.video.revisions)
        #expect(after.brief?.markdown == before.brief?.markdown)
        let newRun = try await fixture.run(a.id)
        try await fixture.store.recordUsageCache(key: "saved-cache", runID: newRun.id, reused: true)
        #expect(try await fixture.store.usageSnapshot().runs.first?.cachedBatches == 1)
        #expect(try await fixture.store.usageSnapshot().attempts.count == 1)
    }

    @Test func concurrentClearAcrossConnectionsCommitsOnlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.run(nil, outcome: .completed)
        let second = try VideoContextStore(databaseURL: fixture.paths.database)
        let firstPreview = try await fixture.store.prepareUsageClear(.library)
        let secondPreview = try await second.prepareUsageClear(.library)
        func clear(_ store: VideoContextStore, _ preview: UsageClearPreview) async -> Bool {
            do { try await store.clearUsage(preview); return true } catch { return false }
        }
        async let one = clear(fixture.store, firstPreview)
        async let two = clear(second, secondPreview)
        let results = await [one, two]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await fixture.store.usageSnapshot().runs.isEmpty)
    }

    @Test func activeGenerationCanPublishAfterHistoryClearAndDeadRunsCanBeCleared() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (a, _) = try await fixture.videos()
        try await fixture.store.publishArtifacts(videoID: a.id, transcript: [], evidence: [], brief: .init(videoID: a.id, markdown: "Saved brief"))
        _ = try await fixture.run(a.id, outcome: .failed)
        var dead = UsageRun(videoID: a.id, operation: .processing, provider: .lmStudio, model: "fixture")
        dead.processID = Int32.max
        let abandoned = try await fixture.store.startUsageRun(dead)
        let live = try await fixture.store.startUsageRun(.init(videoID: a.id, operation: .taskGeneration, provider: .lmStudio, model: "fixture"))
        let preview = try await fixture.store.prepareUsageClear(.library)
        #expect(preview.runCount == 2 && preview.retainedActiveRunCount == 1)
        try await fixture.store.clearUsage(preview)
        #expect(try await fixture.store.usageSnapshot().runs.contains { $0.id == abandoned.id } == false)
        let source = try await fixture.store.taskSnapshot(videoID: a.id)
        var proposal = TaskProposal(videoID: a.id, kind: .addition, sourceRevision: source.video.revisions, content: .init(title: "New task"), provenance: .init(provider: .lmStudio, model: "fixture"))
        proposal.generationRunID = live.id
        try await fixture.store.publishTaskProposals([proposal], videoID: a.id, expectedSource: source.video.revisions, expectedTasks: [:])
        try await fixture.store.saveUsageAttempt(.init(runID: live.id, stage: .taskExtraction, provider: .lmStudio, requestedModel: "fixture"))
        try await fixture.store.finishUsageRun(id: live.id, outcome: .completed)
        #expect(try await fixture.store.taskSnapshot(videoID: a.id).proposals.count == 1)
        #expect(try await fixture.store.usageSnapshot().attempts.count == 1)
    }

    private struct Fixture {
        let root: URL
        let paths: LibraryPaths
        let store: VideoContextStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            paths = try LibraryPaths(root: root)
            store = try VideoContextStore(databaseURL: paths.database)
        }
        func contentRows() async throws -> [String: [String]] {
            let db = try DatabaseQueue(path: paths.database.path)
            return try await db.read { db in
                let excluded = ["usage_runs", "usage_attempts", "usage_cache_origins", "api_usage"]
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
                var result: [String: [String]] = [:]
                for table in tables where !excluded.contains(table) {
                    let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    result[table] = try Row.fetchAll(db, sql: "SELECT * FROM " + quoted).map { $0.description }.sorted()
                }
                return result
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func videos() async throws -> (VideoRecord, VideoRecord) {
            let a = VideoRecord(title: "Same title", source: .localFile, sourceValue: "fixture", mediaRelativePath: "a.mp4")
            let b = VideoRecord(title: "Same title", source: .localFile, sourceValue: "fixture", mediaRelativePath: "b.mp4")
            try await store.createVideo(a); try await store.createVideo(b)
            return (a, b)
        }
        func run(_ videoID: String?, outcome: UsageOutcome = .running) async throws -> UsageRun {
            let run = try await store.startUsageRun(.init(videoID: videoID, operation: videoID == nil ? .modelTest : .processing, provider: .lmStudio, model: "fixture"))
            var attempt = UsageAttempt(runID: run.id, stage: .analysis, provider: .lmStudio, requestedModel: "fixture")
            attempt.tokens = .init(input: 12, output: 5)
            attempt.outcome = .responseReceived
            try await store.saveUsageAttempt(attempt)
            if outcome != .running { try await store.finishUsageRun(id: run.id, outcome: outcome) }
            return run
        }
    }
}
