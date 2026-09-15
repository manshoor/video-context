import Foundation
import Testing
@testable import VideoContextCore

actor TaskTestHTTP: HTTPDataLoading {
    var responses: [HTTPResult]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [HTTPResult]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> HTTPResult {
        try Task.checkCancellation()
        requests.append(request)
        guard !responses.isEmpty else { throw TaskContextError.invalid("Unexpected inference request") }
        return responses.removeFirst()
    }
}
struct TaskGenerationTests {
    static func result(_ output: String = "{\"tasks\":[]}", provider: AnalysisProvider = .lmStudio) throws -> HTTPResult {
        let object: [String: Any] = provider == .lmStudio
            ? ["choices": [["finish_reason": "stop", "message": ["content": output]]]]
            : ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": output]]]]]
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
    func fixture(text: String = "Change the save label") async throws -> (LibraryPaths, VideoContextStore, TaskLibrarySnapshot, BriefDocument) {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let store = try VideoContextStore(databaseURL: paths.database)
        let video = VideoRecord(id: "vid_test", title: "Shared", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 50)
        try await store.createVideo(video)
        let brief = BriefDocument(videoID: video.id, markdown: "Change the label [00:03]")
        try await store.publishArtifacts(videoID: video.id, transcript: [.init(id: "seg_test", videoID: video.id, start: 3, end: 20, originalText: text)], evidence: [], brief: brief)
        return (paths, store, try await store.taskSnapshot(videoID: video.id), brief)
    }
    static let taskJSON = #"{"tasks":[{"targetTaskID":"","title":"Save label","behavior":"Use Save","requirements":[{"text":"Use Save","origin":"recording","sourceIDs":["seg_test"]}],"checks":[{"text":"Button displays Save","origin":"interpretation","sourceIDs":["seg_test"]}],"questions":[],"sourceIDs":["seg_test"]}]}"#
    @Test(arguments: [AnalysisProvider.lmStudio, .openAI])
    func bothProvidersGenerateStructuredProposals(provider: AnalysisProvider) async throws {
        let (paths, store, snapshot, brief) = try await fixture()
        let client = TaskTestHTTP([try Self.result(Self.taskJSON, provider: provider), try Self.result(provider: provider)])
        let config = ModelConfiguration(analysisProvider: provider, lmStudio: .init(modelID: "vision"))
        let generator = TaskGenerator(client: client, configuration: config, credential: provider == .openAI ? "mock-key" : "")
        let proposals = try await generator.generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        #expect(proposals.count == 1)
        #expect(proposals[0].content?.checks[0].origin == .interpretation)
        #expect(try await store.taskSnapshot(videoID: snapshot.video.id).tasks.isEmpty)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == (provider == .lmStudio ? "127.0.0.1" : "api.openai.com") })
        #expect(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("json_schema"))
        let payload = try #require(try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        if provider == .lmStudio {
            let messages = try #require(payload["messages"] as? [[String: Any]])
            #expect(messages.map { $0["role"] as? String } == ["system", "user"])
            #expect(payload["temperature"] as? Double == 0.7)
        } else { #expect(payload["instructions"] as? String != nil) }
        let usage = try #require(try await store.videoSnapshot(id: snapshot.video.id)).apiUsage
        #expect(usage.allSatisfy { $0.stage == .taskGeneration })
        try await store.resolveTaskProposal(videoID: snapshot.video.id, proposalID: proposals[0].id, apply: true)
        let added = try #require(try await store.taskSnapshot(videoID: snapshot.video.id).tasks.first)
        #expect(added.generatedOriginal != nil); #expect(added.state(snapshot.video) == "Draft")
    }
    @Test func failureReusesValidatedCheckpoint() async throws {
        let (paths, store, snapshot, brief) = try await fixture()
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision"))
        let first = TaskTestHTTP([try Self.result(Self.taskJSON), .init(data: Data(), statusCode: 503)])
        await #expect(throws: (any Error).self) { try await TaskGenerator(client: first, configuration: config, credential: "").generate(snapshot: snapshot, brief: brief, paths: paths, store: store) }
        #expect(try await store.taskSnapshot(videoID: snapshot.video.id).proposals.isEmpty)
        #expect(try await store.videoSnapshot(id: snapshot.video.id)?.video.status == .ready)
        let second = TaskTestHTTP([try Self.result()])
        let proposals = try await TaskGenerator(client: second, configuration: config, credential: "").generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        #expect(proposals.count == 1); #expect(await second.requests.count == 1)
    }
    @Test func overflowSplitsAndCoversTranscriptTail() async throws {
        let text = String(repeating: "visible label ", count: 300) + "FINAL_REQUIREMENT"
        let (paths, store, snapshot, brief) = try await fixture(text: text)
        let client = TaskTestHTTP([.init(data: Data(#"{"error":{"message":"context length exceeded"}}"#.utf8), statusCode: 400)] + Array(repeating: try Self.result(), count: 10))
        let config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision"))
        _ = try await TaskGenerator(client: client, configuration: config, credential: "").generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        let requests = await client.requests
        #expect(requests.count >= 4)
        #expect(requests.dropFirst().contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("FINAL_REQUIREMENT") })
    }
    @Test func invalidReferencesAndTruncationRejected() async throws {
        let (_, _, snapshot, _) = try await fixture()
        let batch = try JSONDecoder().decode(GeneratedTaskBatch.self, from: Data(Self.taskJSON.replacingOccurrences(of: "seg_test", with: "seg_other_video").utf8))
        #expect(throws: (any Error).self) { try TaskGenerator<TaskTestHTTP>.validate(batch, snapshot: snapshot) }
        #expect(throws: LocalProviderError.truncated) { try TaskGenerationSchema.decode(.init(data: Data(#"{"choices":[{"finish_reason":"length"}]}"#.utf8), statusCode: 200), provider: .lmStudio) }
        #expect(throws: (any Error).self) { try TaskGenerationSchema.decode(Self.result("not json"), provider: .lmStudio) }
        #expect(throws: (any Error).self) { try TaskGenerationSchema.decode(.init(data: Data(), statusCode: 401), provider: .lmStudio) }
    }
    @Test func emptyFinalOutputReportsActionableError() throws {
        let response = HTTPResult(data: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"","reasoning_content":"{\"tasks\":[]}"}}]}"#.utf8), statusCode: 200)
        #expect(throws: LocalProviderError.invalidOutput) {
            try TaskGenerationSchema.decode(response, provider: .lmStudio)
        }
    }
    @Test(arguments: [AnalysisProvider.lmStudio, .openAI])
    func schemaConstrainsReferencesAndDoesNotAllowInventedUserClarifications(provider: AnalysisProvider) throws {
        let request = try TaskGenerationSchema.request(provider: provider, configuration: .init(analysisProvider: provider, lmStudio: .init(modelID: "vision")), credential: "test", prompt: "SOURCE seg_test", images: [], allowedSourceIDs: ["seg_test", "ev_test"])
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let format: [String: Any]
        if provider == .lmStudio { format = (body["response_format"] as! [String: Any])["json_schema"] as! [String: Any] }
        else { format = (body["text"] as! [String: Any])["format"] as! [String: Any] }
        let schema = format["schema"] as! [String: Any]
        let tasks = (schema["properties"] as! [String: Any])["tasks"] as! [String: Any]
        let properties = (tasks["items"] as! [String: Any])["properties"] as! [String: Any]
        let sources = properties["sourceIDs"] as! [String: Any]
        #expect((sources["items"] as? [String: Any])?["enum"] as? [String] == ["ev_test", "seg_test"])
        let checks = properties["checks"] as! [String: Any]
        #expect(checks["minItems"] as? Int == 1)
        let checkFields = (checks["items"] as! [String: Any])["properties"] as! [String: Any]
        #expect((checkFields["origin"] as? [String: Any])?["enum"] as? [String] == ["recording", "interpretation"])
    }
    @Test func deduplicationPreservesDistinctChecks() async throws {
        let (_, _, snapshot, _) = try await fixture()
        let a = try JSONDecoder().decode(GeneratedTaskBatch.self, from: Data(Self.taskJSON.utf8)).tasks[0]
        let b = try JSONDecoder().decode(GeneratedTaskBatch.self, from: Data(Self.taskJSON.replacingOccurrences(of: "Button displays Save", with: "Keyboard activation works").utf8)).tasks[0]
        let proposals = TaskGenerator<TaskTestHTTP>.proposals([a, b], snapshot: snapshot, identity: .init(provider: .lmStudio, model: "mock"))
        #expect(proposals.count == 1); #expect(proposals[0].content?.checks.count == 2)
    }
    @Test func briefCitationsResolveToPrimaryEvidenceWithinBoundedBatches() async throws {
        let (_, _, snapshot, _) = try await fixture(text: String(repeating: "Keep the existing layout. ", count: 250))
        let inputs = TaskGenerator<TaskTestHTTP>.briefInputs("# Constraint\nKeep the existing layout. [00:03]\nAn unsupported claim. [00:49]", snapshot: snapshot, budget: 3000)
        #expect(inputs.count > 1)
        #expect(inputs.allSatisfy { $0.contains("SOURCE seg_test") })
        #expect(inputs.allSatisfy { $0.utf8.count < 3500 })
        #expect(inputs.joined().contains("Keep the existing layout."))
        let unsupported = TaskGenerator<TaskTestHTTP>.briefInputs("Unknown context [00:49]", snapshot: snapshot, budget: 3000)
        #expect(!unsupported.joined().contains("SOURCE seg_test"))
    }
    @Test func briefCitationsSupportLongMinuteAndHourFormats() {
        let video = VideoRecord(id: "vid_long", title: "Long", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 8000)
        let snapshot = TaskLibrarySnapshot(video: video, tasks: [], transcript: [.init(id: "seg_late", videoID: video.id, start: 6005.4, end: 6010, originalText: "Keep the final requirement")], evidence: [], proposals: [])
        for citation in ["[100:05]", "[01:40:05]"] {
            let inputs = TaskGenerator<TaskTestHTTP>.briefInputs("Final requirement \(citation)", snapshot: snapshot, budget: 3000)
            #expect(inputs.joined().contains("SOURCE seg_late"))
        }
    }
    @Test func cancellationDoesNotPublish() async throws {
        let (paths, store, snapshot, brief) = try await fixture()
        let client = TaskTestHTTP([])
        let task = Task {
            try Task.checkCancellation()
            return try await TaskGenerator(client: client, configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")), credential: "").generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.taskSnapshot(videoID: snapshot.video.id).proposals.isEmpty)
    }
}
