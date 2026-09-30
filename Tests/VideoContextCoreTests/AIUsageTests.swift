import Foundation
import GRDB
import Testing
@testable import VideoContextCore

struct AIUsageTests {
    @Test func normalizesInclusiveTokenCountsAndMissingValues() {
        let claude = UsageTokens.decode(Data(#"{"usage":{"input_tokens":100,"cache_read_input_tokens":80,"cache_creation_input_tokens":20,"output_tokens":30,"output_tokens_details":{"thinking_tokens":10}}}"#.utf8), provider: .claude)
        #expect(claude.input == 200 && claude.output == 30 && claude.total == 230 && claude.reasoning == 10)
        let deepseek = UsageTokens.decode(Data(#"{"usage":{"prompt_tokens":100,"prompt_cache_hit_tokens":80,"completion_tokens":30,"total_tokens":130,"completion_tokens_details":{"reasoning_tokens":10}}}"#.utf8), provider: .deepSeek)
        #expect(deepseek.input == 100 && deepseek.total == 130 && deepseek.cacheRead == 80)
        let missing = UsageTokens.decode(Data(#"{"usage":{"input_tokens":true,"output_tokens":-3,"total_tokens":1.5}}"#.utf8), provider: .openAI)
        #expect(missing.input == nil && missing.output == nil && missing.total == nil)
        #expect(UsageTotal([10, nil, 5]).value == 15)
        #expect(UsageTotal([10, nil, 5]).partial)
        #expect(UsageTotal([nil]).value == nil)
        #expect(UsageTotal([]).value == 0)
    }

    @Test(arguments: [AnalysisProvider.claude, .deepSeek, .openAI, .lmStudio])
    func adaptersUseDedicatedEndpointsAndStructuredSchemas(provider: AnalysisProvider) throws {
        let config = ModelConfiguration(analysisProvider: provider, lmStudio: .init(modelID: "vision"), claudeModel: "claude-sonnet-4-6", deepSeekModel: "deepseek-flash")
        let request = try AnalysisAdapter.request(configuration: config, credential: "fixture-key", prompt: "source", images: [Data([1, 2, 3])])
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == config.selectedAnalysisModel)
        if provider == .claude {
            #expect(request.url?.host == "api.anthropic.com")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(json["output_config"] != nil)
            #expect(String(decoding: body, as: UTF8.self).contains("base64"))
        } else if provider == .deepSeek {
            #expect(request.url?.host == "api.deepseek.com")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
        }
        #expect(try AnalysisAdapter.markdown(response(provider: provider, text: #"{"markdown":"Evidence [00:01]"}"#), provider: provider) == "Evidence [00:01]")
        #expect(throws: (any Error).self) { try AnalysisAdapter.markdown(response(provider: provider, text: #"{"markdown":"ok","unexpected":true}"#), provider: provider) }
    }

    @Test func rejectsUnsupportedModelsRefusalsAndTruncation() throws {
        var config = ModelConfiguration(analysisProvider: .deepSeek, deepSeekModel: "deepseek-reasoner")
        #expect(throws: (any Error).self) { try AnalysisAdapter.request(configuration: config, credential: "fixture", prompt: "source", images: []) }
        config.deepSeekModel = "deepseek-flash"
        #expect(throws: (any Error).self) { try AnalysisAdapter.request(configuration: config, credential: "", prompt: "source", images: []) }
        #expect(throws: LocalProviderError.truncated) {
            try AnalysisAdapter.output(.init(data: Data(#"{"stop_reason":"max_tokens"}"#.utf8), statusCode: 200), provider: .claude)
        }
        #expect(throws: LocalProviderError.invalidOutput) {
            try AnalysisAdapter.output(.init(data: Data(#"{"stop_reason":"refusal","content":[]}"#.utf8), statusCode: 200), provider: .claude)
        }
        #expect(throws: LocalProviderError.contextLength) {
            try AnalysisAdapter.output(.init(data: Data(), statusCode: 413), provider: .deepSeek)
        }
    }

    @Test func recordsEveryAttemptAndKeepsPrivateBodiesOutOfStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let run = try await store.startUsageRun(.init(videoID: nil, operation: .modelTest, provider: .claude, model: "claude-fixture"))
        let session = UsageSession(runID: run.id, store: store)
        let client = UsageRecordingClient(base: UsageHTTP(), provider: .claude, model: "claude-fixture", stage: .modelTest)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PRIVATE_CREDENTIAL", forHTTPHeaderField: "x-api-key")
        request.httpBody = Data(#"{"model":"claude-fixture","prompt":"PRIVATE_TRANSCRIPT"}"#.utf8)
        try await UsageTrace.$session.withValue(session) {
            _ = try await client.data(for: request)
            _ = try await client.data(for: request)
        }
        try await store.finishUsageRun(id: run.id, outcome: .failed)
        let snapshot = try await store.usageSnapshot()
        #expect(snapshot.attempts.count == 2)
        #expect(snapshot.attempts.allSatisfy { $0.tokens.total == 13 && $0.httpStatus == 503 })
        #expect(UsageTotal(snapshot.attempts.map { $0.tokens.total }).value == 26)
        let bytes = try JSONEncoder().encode(snapshot.attempts)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        #expect(snapshot.attempts.allSatisfy { $0.resolvedModel == "unreported-model" })
        // Re-saving a received attempt must update it, not count it again.
        try await store.saveUsageAttempt(snapshot.attempts[0])
        #expect(try await store.usageSnapshot().attempts.count == 2)
    }

    @Test func cacheReuseAndResumptionDoNotDuplicateUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let first = try await store.startUsageRun(.init(videoID: nil, operation: .taskGeneration, provider: .lmStudio, model: "vision", fingerprint: "same"))
        try await store.recordUsageCache(key: "batch", runID: first.id, reused: false)
        try await store.finishUsageRun(id: first.id, outcome: .cancelled)
        let second = try await store.startUsageRun(.init(videoID: nil, operation: .taskGeneration, provider: .lmStudio, model: "vision", fingerprint: "same"))
        #expect(second.resumedFrom == first.id)
        try await store.recordUsageCache(key: "batch", runID: second.id, reused: true)
        let result = try await store.usageSnapshot()
        #expect(result.attempts.isEmpty)
        #expect(result.runs.first(where: { $0.id == second.id })?.reusedRuns == [first.id])
        let changed = try await store.startUsageRun(.init(videoID: nil, operation: .taskGeneration, provider: .claude, model: "different", fingerprint: "changed"))
        #expect(changed.resumedFrom == nil)
    }

    @Test func filtersMixedRunsByActualAttemptProviderAndRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let first = VideoRecord(title: "Same", source: .localFile, sourceValue: "fixture", mediaRelativePath: "a.mp4")
        let second = VideoRecord(title: "Same", source: .localFile, sourceValue: "fixture", mediaRelativePath: "b.mp4")
        try await store.createVideo(first); try await store.createVideo(second)
        let run = try await store.startUsageRun(.init(videoID: first.id, operation: .processing, provider: .claude, model: "vision"))
        try await store.saveUsageAttempt(.init(runID: run.id, stage: .transcription, provider: .openAI, requestedModel: "whisper-1"))
        try await store.saveUsageAttempt(.init(runID: run.id, stage: .analysis, provider: .claude, requestedModel: "vision"))
        let snapshot = try await store.usageSnapshot()
        let cloudSpeech = UsageQuery(videoID: first.id, provider: .openAI).filter(snapshot)
        #expect(cloudSpeech.runs.count == 1 && cloudSpeech.attempts.count == 1)
        #expect(UsageQuery(videoID: second.id).filter(snapshot).runs.isEmpty)
        #expect(UsageQuery(provider: .deepSeek).filter(snapshot).runs.isEmpty)
        #expect(UsageQuery(since: Date().addingTimeInterval(60)).filter(snapshot).runs.isEmpty)
        #expect(!InferenceProvider.claude.isLocal && !InferenceProvider.deepSeek.isLocal)
    }

    @Test func migratesOldUsageAndPreservesTaskGenerationLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), original = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(title: "fixture", source: .localFile, sourceValue: "fixture", mediaRelativePath: "a.mp4")
        try await original.createVideo(video)
        try await original.publishArtifacts(videoID: video.id, transcript: [], evidence: [], brief: .init(videoID: video.id, markdown: "brief"))
        try await original.recordAPIUsage(.init(videoID: video.id, stage: .analysis, model: "old", inputTokens: 7, outputTokens: 3))
        let db = try DatabaseQueue(path: paths.database.path)
        try await db.write { db in
            try db.execute(sql: "DROP TABLE usage_cache_origins; DROP TABLE usage_attempts; DROP TABLE usage_runs; DELETE FROM grdb_migrations WHERE identifier='aiUsageRuns'")
        }
        let migrated = try VideoContextStore(databaseURL: paths.database)
        let history = try await migrated.usageSnapshot()
        #expect(history.runs.count == 1 && history.runs[0].operation == .earlierUsage)
        #expect(history.attempts[0].tokens.total == 10)
        let source = try await migrated.taskSnapshot(videoID: video.id)
        let run = try await migrated.startUsageRun(.init(videoID: video.id, operation: .taskGeneration, provider: .deepSeek, model: "deepseek-flash"))
        var proposal = TaskProposal(videoID: video.id, kind: .addition, sourceRevision: source.video.revisions, content: .init(title: "Task"), provenance: .init(provider: .deepSeek, model: "deepseek-flash"))
        proposal.generationRunID = run.id
        try await migrated.publishTaskProposals([proposal], videoID: video.id, expectedSource: source.video.revisions, expectedTasks: [:])
        try await migrated.resolveTaskProposal(videoID: video.id, proposalID: proposal.id, apply: true)
        var task = try #require(try await migrated.taskSnapshot(videoID: video.id).tasks.first)
        #expect(task.generationRunID == run.id)
        task.content.behavior = "User edit"
        let updated = try await migrated.saveTask(task, expectedRevision: task.revision, expectedSource: source.video.revisions)
        #expect(updated.id == task.id && updated.generationRunID == run.id)
        #expect(try await migrated.videoSnapshot(id: video.id)?.brief?.markdown == "brief")
    }

    @Test func interruptedRunsAndCancellationKeepUnknownUsageVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        var input = UsageRun(videoID: nil, operation: .modelTest, provider: .claude, model: "fixture")
        input.processID = Int32.max
        let run = try await store.startUsageRun(input)
        try await store.saveUsageAttempt(.init(runID: run.id, stage: .modelTest, provider: .claude, requestedModel: "fixture"))
        try await store.recoverInterruptedUsageRuns()
        var snapshot = try await store.usageSnapshot()
        #expect(snapshot.runs[0].outcome == .interrupted && snapshot.runs[0].accountingIncomplete)
        #expect(snapshot.attempts[0].outcome == .interrupted && snapshot.attempts[0].tokens.total == nil)
        let current = try await store.startUsageRun(.init(videoID: nil, operation: .modelTest, provider: .claude, model: "fixture"))
        let client = UsageRecordingClient(base: CancelledUsageHTTP(), provider: .claude, model: "fixture", stage: .modelTest)
        var request = URLRequest(url: URL(string: "https://example.invalid")!); request.httpMethod = "POST"
        await #expect(throws: CancellationError.self) {
            try await UsageTrace.$session.withValue(UsageSession(runID: current.id, store: store)) { _ = try await client.data(for: request) }
        }
        snapshot = try await store.usageSnapshot()
        #expect(snapshot.attempts.contains { $0.runID == current.id && $0.outcome == .cancelled && $0.tokens.total == nil })
        try await store.recoverInterruptedUsageRuns()
        #expect(try await store.usageSnapshot().runs.first { $0.id == current.id }?.outcome == .running)
    }

    @Test func storageFailureStopsUnaccountableRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), writer = try VideoContextStore(databaseURL: paths.database)
        let run = try await writer.startUsageRun(.init(videoID: nil, operation: .modelTest, provider: .deepSeek, model: "fixture"))
        let readOnly = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        let session = UsageSession(runID: run.id, store: readOnly), base = TaskTestHTTP([])
        let client = UsageRecordingClient(base: base, provider: .deepSeek, model: "fixture", stage: .modelTest)
        var request = URLRequest(url: URL(string: "https://example.invalid")!); request.httpMethod = "POST"
        await #expect(throws: (any Error).self) { try await UsageTrace.$session.withValue(session) { _ = try await client.data(for: request) } }
        #expect(await base.requests.isEmpty)
        #expect(await session.hasStorageFailure())
    }

    @Test func audioDurationIsRecordedWithoutFabricatingTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let run = try await store.startUsageRun(.init(videoID: nil, operation: .processing, provider: .openAI, model: "whisper-1"))
        let base = TaskTestHTTP([.init(data: Data(#"{"duration":42.5,"text":"PRIVATE_TRANSCRIPT"}"#.utf8), statusCode: 200)])
        let client = UsageRecordingClient(base: base, provider: .openAI, model: "whisper-1", stage: .transcription)
        var request = URLRequest(url: URL(string: "https://example.invalid")!); request.httpMethod = "POST"
        try await UsageTrace.$session.withValue(UsageSession(runID: run.id, store: store)) { _ = try await client.data(for: request) }
        let attempt = try #require(try await store.usageSnapshot().attempts.first)
        #expect(attempt.tokens.audioSeconds == 42.5 && attempt.tokens.total == nil && attempt.usesAudioAccounting)
    }

    private func response(provider: AnalysisProvider, text: String) throws -> HTTPResult {
        let root: [String: Any]
        switch provider {
        case .claude: root = ["stop_reason": "end_turn", "content": [["type": "text", "text": text]]]
        case .openAI: root = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
        case .lmStudio, .deepSeek: root = ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: root), statusCode: 200)
    }
}

private struct UsageHTTP: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult {
        .init(data: Data(#"{"model":"sk-PRIVATE_CREDENTIAL","error":{"message":"PRIVATE_PROVIDER_BODY"},"usage":{"input_tokens":10,"output_tokens":3}}"#.utf8), statusCode: 503)
    }
}

private struct CancelledUsageHTTP: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult { throw CancellationError() }
}
