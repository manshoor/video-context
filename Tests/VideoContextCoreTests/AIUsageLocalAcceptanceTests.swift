import Foundation
import Testing
@testable import VideoContextCore

struct AIUsageLocalAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_CONTEXT_USAGE_ACCEPTANCE"] == "1", "Explicit local-only acceptance with a loaded LM Studio vision model"), .timeLimit(.minutes(10)))
    func imageAndTaskUsageInDisposableLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelID = try #require(environment["VIDEO_CONTEXT_USAGE_MODEL"])
        let (paths, store, snapshot, brief) = try await TaskGenerationTests().fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let transport = LoopbackHTTPClient()
        var config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: modelID))
        let instance = try await LMStudioService(client: transport).loadedModel(configuration: config.lmStudio, token: "")
        config.lmStudio.modelID = instance.id
        let imageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg")
        let modelRun = try await store.startUsageRun(.init(videoID: nil, operation: .modelTest, provider: .lmStudio, model: modelID))
        let probeClient = UsageRecordingClient(base: transport, provider: .lmStudio, model: modelID, stage: .modelTest)
        try await UsageTrace.$session.withValue(UsageSession(runID: modelRun.id, store: store)) {
            let request = try AnalysisAdapter.request(configuration: config, credential: "", prompt: "Read the code in the image. Return that code in the markdown field.", images: [Data(contentsOf: imageURL)], maxTokens: 1024)
            let output = try AnalysisAdapter.markdown(try await probeClient.data(for: request), provider: .lmStudio)
            #expect(output.contains("VC-TEST-42"))
        }
        try await store.finishUsageRun(id: modelRun.id, outcome: .completed)
        let taskRun = try await store.startUsageRun(.init(videoID: snapshot.video.id, operation: .taskGeneration, provider: .lmStudio, model: modelID))
        let taskClient = UsageRecordingClient(base: transport, provider: .lmStudio, model: modelID, stage: .taskExtraction)
        let proposals = try await UsageTrace.$session.withValue(UsageSession(runID: taskRun.id, store: store)) {
            try await TaskGenerator(client: taskClient, configuration: config, credential: "", contextLength: instance.config.contextLength).generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        }
        try await store.finishUsageRun(id: taskRun.id, outcome: .completed)
        #expect(!proposals.isEmpty)
        #expect(proposals.allSatisfy { $0.generationRunID == taskRun.id })
        for proposal in proposals { try await store.resolveTaskProposal(videoID: snapshot.video.id, proposalID: proposal.id, apply: true) }
        let reader = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        let saved = try await reader.taskSnapshot(videoID: snapshot.video.id)
        #expect(saved.tasks.allSatisfy { $0.generationRunID == taskRun.id })
        let usage = try await reader.usageSnapshot()
        #expect(usage.attempts.count >= 3)
        #expect(usage.attempts.allSatisfy { $0.provider == .lmStudio && $0.tokens.input != nil && $0.tokens.output != nil && $0.tokens.total != nil })
        #expect(try await reader.videoSnapshot(id: snapshot.video.id)?.apiUsage.isEmpty == true)
        let service = TaskMCPService(store: reader)
        for task in saved.tasks { #expect(try await service.task(videoID: snapshot.video.id, taskID: task.id, expectedRevision: task.revision).blocks.isEmpty == false) }
        if let resultPath = environment["VIDEO_CONTEXT_USAGE_RESULT"] {
            struct Metrics: Encodable { let runs: [UsageRun]; let attempts: [UsageAttempt] }
            try JSONEncoder().encode(Metrics(runs: usage.runs, attempts: usage.attempts)).write(to: URL(fileURLWithPath: resultPath))
        }
    }
}
