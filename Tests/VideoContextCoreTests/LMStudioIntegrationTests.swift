import Foundation
import Testing
import GRDB
@testable import VideoContextCore

struct LMStudioIntegrationTests {
    @Test func modelDiscoveryRequiresVisionAndLoadedContext() async throws {
        for (vision, loaded, context, shouldPass) in [(true, true, 32768, true), (false, true, 32768, false), (true, false, 32768, false), (true, true, 4096, false)] {
            let instances = loaded ? #"[{"id":"loaded-instance","config":{"context_length":CONTEXT}}]"#.replacingOccurrences(of: "CONTEXT", with: String(context)) : "[]"
            let json = "{\"models\":[{\"key\":\"vision\",\"display_name\":\"Vision\",\"type\":\"llm\",\"format\":\"mlx\",\"capabilities\":{\"vision\":\(vision)},\"loaded_instances\":\(instances)}]}"
            let client = LocalSequenceClient(responses: [HTTPResult(data: Data(json.utf8), statusCode: 200)])
            let service = LMStudioService(client: client)
            if shouldPass {
                let instance = try await service.loadedModel(configuration: .init(modelID: "vision"), token: "")
                #expect(instance.id == "loaded-instance")
            } else {
                await #expect(throws: LocalProviderError.self) { try await service.loadedModel(configuration: .init(modelID: "vision"), token: "") }
            }
        }
    }

    @Test func oversizedImageBatchSplitsWithoutDroppingFrames() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let frame = paths.root.appending(path: "frame.jpg")
        try Data([1, 2, 3]).write(to: frame)
        let client = LocalSequenceClient(responses: [HTTPResult(data: Data(#"{"error":{"message":"context length exceeded"}}"#.utf8), statusCode: 400)] + Array(repeating: Self.success, count: 3))
        let generator = LMStudioBriefGenerator(client: client, configuration: .init(modelID: "vision"))
        let output = try await generator.generate(videoID: "vid_a", transcript: [], evidence: [1.0, 20.0].map {
            EvidenceItem(videoID: "vid_a", timestamp: $0, imageRelativePath: "frame.jpg", ocrText: "Visible error", origin: .automatic)
        }, paths: paths)
        #expect(output.markdown == "Evidence [00:01]")
        let requests = await client.requests
        let imageCounts = try requests.map { request -> Int in
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: Any]])
            return (messages[0]["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image_url" }.count ?? 0
        }
        #expect(imageCounts == [2, 1, 1, 0])
    }

    @Test func missingEvidenceImageDoesNotSilentlyBecomeTextOnly() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = LocalSequenceClient(responses: [Self.success])
        let generator = LMStudioBriefGenerator(client: client, configuration: .init(modelID: "vision"))
        await #expect(throws: (any Error).self) {
            try await generator.generate(videoID: "vid_a", transcript: [], evidence: [EvidenceItem(videoID: "vid_a", timestamp: 1, imageRelativePath: "missing.jpg", origin: .automatic)], paths: paths)
        }
        #expect(await client.requests.isEmpty)
    }

    @Test func cancellationStopsBeforePublishingOrAnotherRequest() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = CancellationGateClient()
        let generator = LMStudioBriefGenerator(client: client, configuration: .init(modelID: "vision"))
        let task = Task {
            try await generator.generate(videoID: "vid_a", transcript: [TranscriptSegment(videoID: "vid_a", start: 0, end: 1, originalText: "hello")], evidence: [], paths: paths)
        }
        await client.waitForRequest()
        task.cancel()
        await client.release(Self.success)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await client.calls == 1)
    }

    @Test func provenanceAndUsageRemainScopedAndReadableAfterReopening() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let store = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(title: "Duplicate title", source: .localFile, sourceValue: "source", mediaRelativePath: "video.mp4")
        try await store.createVideo(video)
        try await store.replaceTranscript(videoID: video.id, segments: [TranscriptSegment(videoID: video.id, start: 0, end: 1, originalText: "Local transcript")], provenance: .init(provider: .localWhisper, model: "turbo"))
        try await store.publishBrief(videoID: video.id, brief: BriefDocument(videoID: video.id, markdown: "Local brief"), provenance: .init(provider: .lmStudio, model: "vision"))
        let client = APIUsageRecordingClient(base: LocalSequenceClient(responses: [Self.success]), store: store, videoID: video.id, transcriptionModel: "turbo", analysisModel: "vision", provider: .lmStudio)
        _ = try await client.data(for: LMStudioRequestBuilder.analysis(configuration: .init(modelID: "vision"), token: "", prompt: "test", images: []))
        let reader = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        let snapshot = try #require(try await reader.videoSnapshot(id: video.id))
        #expect(snapshot.video.id == video.id)
        #expect(snapshot.provenance.map(\.identity.provider).contains(.localWhisper))
        #expect(snapshot.provenance.map(\.identity.provider).contains(.lmStudio))
        #expect(snapshot.apiUsage.first?.provider == .lmStudio)
        #expect(snapshot.apiUsage.first?.inputTokens == 12)
        #expect(try await reader.search(videoID: video.id, query: "absent").items.isEmpty)
    }

    @Test func legacyDatabaseMigratesWithoutChangingArtifacts() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let writer = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(title: "Legacy", source: .localFile, sourceValue: "source", mediaRelativePath: "video.mp4")
        try await writer.createVideo(video)
        try await writer.recordAPIUsage(.init(videoID: video.id, stage: .analysis, model: "existing-model"))
        let before = try #require(try await writer.videoSnapshot(id: video.id))
        let db = try DatabaseQueue(path: paths.database.path)
        try await db.write { db in
            try db.execute(sql: "DROP TABLE artifact_provenance; ALTER TABLE api_usage DROP COLUMN provider; DELETE FROM grdb_migrations WHERE identifier = 'addLocalProviderProvenance';")
        }
        let legacyReader = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        #expect(try await legacyReader.videoSnapshot(id: video.id)?.apiUsage.first?.provider == .openAI)
        let upgraded = try VideoContextStore(databaseURL: paths.database)
        let snapshot = try #require(try await upgraded.videoSnapshot(id: video.id))
        #expect(snapshot.video == before.video)
        #expect(snapshot.apiUsage.first?.model == "existing-model")
        #expect(snapshot.apiUsage.first?.provider == .openAI)
    }

    static let success = HTTPResult(data: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"markdown\":\"Evidence [00:01]\"}"}}],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#.utf8), statusCode: 200)
}

private actor LocalSequenceClient: HTTPDataLoading {
    var responses: [HTTPResult]
    private(set) var requests: [URLRequest] = []
    init(responses: [HTTPResult]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        return responses.removeFirst()
    }
}

private actor CancellationGateClient: HTTPDataLoading {
    private var continuation: CheckedContinuation<HTTPResult, Never>?
    private(set) var calls = 0
    func data(for request: URLRequest) async throws -> HTTPResult {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitForRequest() async { while continuation == nil { await Task.yield() } }
    func release(_ result: HTTPResult) { continuation?.resume(returning: result); continuation = nil }
}
