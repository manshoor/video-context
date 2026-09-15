import Foundation
import Testing
@testable import VideoContextCore

struct TaskLocalAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_CONTEXT_TASK_ACCEPTANCE"] == "1", "Opt in with a running LM Studio vision model and an approved recording"))
    func approvedRecordingInSeparateLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourceRoot = try #require(environment["VIDEO_CONTEXT_SOURCE_LIBRARY"])
        let sourceID = try #require(environment["VIDEO_CONTEXT_SOURCE_ID"])
        let outputRoot = try #require(environment["VIDEO_CONTEXT_TASK_OUTPUT"])
        let modelID = try #require(environment["VIDEO_CONTEXT_TASK_MODEL"])
        guard URL(fileURLWithPath: sourceRoot).standardizedFileURL != URL(fileURLWithPath: outputRoot).standardizedFileURL else { throw TaskContextError.invalid("Acceptance must use a separate library.") }
        let source = try VideoContextStore(databaseURL: URL(fileURLWithPath: sourceRoot).appending(path: "library.sqlite"), access: .readOnly)
        let original = try #require(try await source.videoSnapshot(id: sourceID))
        let paths = try LibraryPaths(root: URL(fileURLWithPath: outputRoot))
        let store = try VideoContextStore(databaseURL: paths.database)
        let video: VideoRecord
        let evidence: [EvidenceItem]
        let brief: BriefDocument
        if let reuseID = environment["VIDEO_CONTEXT_REUSE_TASK_ID"] {
            let reused = try #require(try await store.videoSnapshot(id: reuseID))
            guard try await store.taskSnapshot(videoID: reuseID).tasks.isEmpty else { throw TaskContextError.invalid("The disposable retry library must have no saved tasks.") }
            video = reused.video; evidence = reused.evidence; brief = try #require(reused.brief)
        } else {
            video = VideoRecord(title: "Acceptance copy — " + original.video.title, source: .localFile, sourceValue: "approved test copy", mediaRelativePath: "acceptance.mp4", duration: original.video.duration)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: sourceRoot).appending(path: original.video.mediaRelativePath), to: paths.root.appending(path: video.mediaRelativePath))
            try await store.createVideo(video)
            let transcript = original.transcript.map { TranscriptSegment(videoID: video.id, start: $0.start, end: $0.end, originalText: $0.text) }
            var copiedEvidence: [EvidenceItem] = []
            for frame in original.evidence {
                let name = "\(UUID().uuidString).jpg"
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourceRoot).appending(path: frame.imageRelativePath), to: paths.root.appending(path: name))
                copiedEvidence.append(.init(videoID: video.id, timestamp: frame.timestamp, imageRelativePath: name, ocrText: frame.ocrText, origin: frame.origin))
            }
            evidence = copiedEvidence
            brief = BriefDocument(videoID: video.id, markdown: try #require(original.brief).markdown)
            try await store.publishArtifacts(videoID: video.id, transcript: transcript, evidence: evidence, brief: brief)
        }
        let transport = LoopbackHTTPClient()
        var config = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: modelID))
        let instance = try await LMStudioService(client: transport).loadedModel(configuration: config.lmStudio, token: "")
        config.lmStudio.modelID = instance.id
        let snapshot = try await store.taskSnapshot(videoID: video.id)
        let proposals = try await TaskGenerator(client: transport, configuration: config, credential: "", contextLength: instance.config.contextLength).generate(snapshot: snapshot, brief: brief, paths: paths, store: store) { progress in
            print("Local task generation: \(progress.completed ?? 0)/\(progress.total ?? 0)")
        }
        #expect(!proposals.isEmpty)
        for proposal in proposals where proposal.kind == .addition { try await store.resolveTaskProposal(videoID: video.id, proposalID: proposal.id, apply: true) }
        let reader = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        let tasks = try await reader.taskSnapshot(videoID: video.id)
        #expect(!tasks.tasks.isEmpty)
        if sourceID == "vid_17be76da-f212-4e79-ab16-16fadc11ecf4" {
            let content = tasks.tasks.map { task in ([task.content.title, task.content.behavior] + task.content.requirements.map(\.text) + task.content.checks.map(\.text)).joined(separator: " ") }.joined(separator: " ").lowercased()
            #expect(tasks.tasks.count < 30, "Repeated extraction wording must be consolidated for this walkthrough")
            let questions = tasks.tasks.flatMap { $0.content.questions.map(\.question) }.joined(separator: " ").lowercased()
            #expect(questions.contains("only") && (questions.contains("remaining") || questions.contains("total") || questions.contains("planned")), "The conflicting approval-count drafts need an explicit review question")
            for alternatives in [["popup", "pop-up", "style selector", "style selection"], ["caption"], ["approved", "approval"], ["layout", "style guide"], ["edit", "regenerat"]] {
                #expect(alternatives.contains(where: { content.contains($0) }), "Missing walkthrough requirement: \(alternatives)")
            }
        }
        let context = TaskMCPService(store: reader)
        for task in tasks.tasks {
            let page = try await context.task(videoID: video.id, taskID: task.id, expectedRevision: task.revision)
            #expect(!page.blocks.isEmpty)
        }
        if let task = tasks.tasks.first(where: { task in evidence.contains { task.content.allSourceIDs.contains($0.id) } }), let frame = evidence.first(where: { task.content.allSourceIDs.contains($0.id) }) {
            let output = try await context.frame(videoID: video.id, taskID: task.id, evidenceID: frame.id, expectedRevision: task.revision, paths: paths)
            #expect(!output.image.isEmpty)
        }
        #expect(try await store.videoSnapshot(id: video.id)?.apiUsage.allSatisfy { $0.provider == .lmStudio && $0.stage == .taskGeneration } == true)
        let after = try #require(try await source.videoSnapshot(id: sourceID))
        #expect(after.video == original.video); #expect(after.transcript == original.transcript); #expect(after.evidence == original.evidence); #expect(after.brief == original.brief)
        try JSONEncoder().encode(tasks).write(to: paths.root.appending(path: "task-acceptance-results.json"), options: .atomic)
    }
}
