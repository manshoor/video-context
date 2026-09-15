import Foundation
import Testing
@testable import VideoContextCore

struct TaskConsolidationTests {
    func candidates() throws -> [GeneratedTask] {
        let first = try JSONDecoder().decode(GeneratedTaskBatch.self, from: Data(TaskGenerationTests.taskJSON.utf8)).tasks[0]
        let second = try JSONDecoder().decode(GeneratedTaskBatch.self, from: Data(TaskGenerationTests.taskJSON.replacingOccurrences(of: "Save label", with: "Update Save button").replacingOccurrences(of: "Button displays Save", with: "Keyboard activation works").utf8)).tasks[0]
        return [first, second]
    }
    @Test func duplicateWordingAndConflictQuestionsPreserveAllEvidence() throws {
        let input = try candidates()
        let grouping = TaskGrouping(groups: [.init(members: [0, 1], questions: ["Confirm the intended label before implementation."])])
        let output = try TaskConsolidation.merge(grouping, candidates: input)
        #expect(output.count == 1)
        #expect(output[0].checks.map(\.text) == ["Button displays Save", "Keyboard activation works"])
        #expect(output[0].content.allSourceIDs == input.reduce(into: Set<String>()) { $0.formUnion($1.content.allSourceIDs) })
        #expect(output[0].content.questions.first?.unresolved == true)
        #expect(output[0].requirements.allSatisfy { $0.origin == .recording })
    }
    @Test func omittedRepeatedOrUnknownCandidatesRejectTheWholeResult() throws {
        let input = try candidates()
        for members in [[0], [0, 0, 1], [0, 1, 2]] {
            #expect(throws: (any Error).self) { try TaskConsolidation.merge(.init(groups: [.init(members: members, questions: [])]), candidates: input) }
        }
    }
    @Test func distinctExistingTaskIDsCannotBeMerged() throws {
        let input = try candidates().enumerated().map { index, task in
            GeneratedTask(targetTaskID: "task_\(index)", title: task.title, behavior: task.behavior, requirements: task.requirements, checks: task.checks, questions: [], sourceIDs: task.sourceIDs)
        }
        #expect(throws: (any Error).self) { try TaskConsolidation.merge(.init(groups: [.init(members: [0, 1], questions: [])]), candidates: input) }
    }
    @Test(arguments: [AnalysisProvider.lmStudio, .openAI])
    func adapterRequestsOnlyGroupingAndBlockingQuestions(provider: AnalysisProvider) throws {
        let request = try TaskConsolidation.request(candidates: candidates(), configuration: .init(analysisProvider: provider, lmStudio: .init(modelID: "vision")), credential: "mock")
        let payload = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("video_context_task_groups")); #expect(body.contains("draft_0")); #expect(body.contains("contradict"))
        #expect(!body.contains("api.openai.com"))
        if provider == .lmStudio { #expect(payload["reasoning_effort"] as? String == "none") }
    }
    @Test func consolidationCachesValidatedGroupsAndPreservesReadyState() async throws {
        let (_, store, snapshot, _) = try await TaskGenerationTests().fixture()
        let result = #"{"assignments":{"draft_0":{"group":0,"questions":["Which label is intended?"]},"draft_1":{"group":0,"questions":[]}}}"#
        let client = TaskTestHTTP([try TaskGenerationTests.result(result)])
        let generator = TaskGenerator(client: client, configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")), credential: "")
        for _ in 0..<2 {
            let output = try await generator.consolidate(candidates(), snapshot: snapshot, store: store, progress: nil)
            #expect(output.count == 1); #expect(output[0].checks.count == 2)
        }
        #expect(await client.requests.count == 1)
        #expect(try await store.videoSnapshot(id: snapshot.video.id)?.video.status == .ready)
    }
    @Test func consolidationOverflowPreservesEveryDraftAndRequiresBoundaryReview() async throws {
        let (_, store, snapshot, _) = try await TaskGenerationTests().fixture()
        let client = TaskTestHTTP([.init(data: Data(#"{"error":{"message":"context length exceeded"}}"#.utf8), statusCode: 400)])
        let output = try await TaskGenerator(client: client, configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "vision")), credential: "").consolidate(candidates(), snapshot: snapshot, store: store, progress: nil)
        #expect(output.count == 2)
        #expect(output.allSatisfy { $0.content.questions.contains { $0.unresolved && $0.question.contains("bounded batch") } })
        #expect(await client.requests.count == 1)
    }
    @Test(arguments: [AnalysisProvider.lmStudio, .openAI])
    func incompleteConsolidationDoesNotPublishAndRetryReusesExtraction(provider: AnalysisProvider) async throws {
        let (paths, store, snapshot, brief) = try await TaskGenerationTests().fixture()
        let config = ModelConfiguration(analysisProvider: provider, lmStudio: .init(modelID: "vision"))
        let first = TaskTestHTTP([
            try TaskGenerationTests.result(TaskGenerationTests.taskJSON, provider: provider),
            try TaskGenerationTests.result(TaskGenerationTests.taskJSON.replacingOccurrences(of: "Save label", with: "Update Save button"), provider: provider),
            try TaskGenerationTests.result(#"{"assignments":{"draft_0":{"group":0,"questions":[]}}}"#, provider: provider)
        ])
        await #expect(throws: (any Error).self) {
            try await TaskGenerator(client: first, configuration: config, credential: "mock").generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        }
        #expect(try await store.taskSnapshot(videoID: snapshot.video.id).proposals.isEmpty)
        let retry = TaskTestHTTP([try TaskGenerationTests.result(#"{"assignments":{"draft_0":{"group":0,"questions":[]},"draft_1":{"group":0,"questions":[]}}}"#, provider: provider)])
        let proposals = try await TaskGenerator(client: retry, configuration: config, credential: "mock").generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        #expect(proposals.count == 1); #expect(await retry.requests.count == 1)
        #expect(try await store.videoSnapshot(id: snapshot.video.id)?.video.status == .ready)
    }
}
