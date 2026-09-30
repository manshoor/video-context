import Foundation
import Testing
@testable import VideoContextCore

struct DocumentationAnalysisCheckpointTests {
    @Test func completedBatchesAreReusedAndUnknownResultsRequireExplicitReset() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "documentation-checkpoints-\(UUID())"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Checkpoint")
        let first = try await store.beginDocumentationAnalysis(projectID: project.id, key: "batch-one")
        let payload = Data("Completed sections".utf8)
        try await store.completeDocumentationAnalysis(first, result: payload)
        let reused = try await store.beginDocumentationAnalysis(projectID: project.id, key: "batch-one")
        #expect(reused.state == .completed)
        #expect(reused.result == payload)
        #expect(reused.requestID == first.requestID)
        let interrupted = try await store.beginDocumentationAnalysis(projectID: project.id, key: "batch-two")
        try await store.failDocumentationAnalysis(interrupted, error: "Connection ended without a receipt")
        await #expect(throws: (any Error).self) { try await store.beginDocumentationAnalysis(projectID: project.id, key: "batch-two") }
        try await store.resetDocumentationAnalysis(interrupted)
        let retried = try await store.beginDocumentationAnalysis(projectID: project.id, key: "batch-two")
        #expect(retried.requestID != interrupted.requestID)
        await #expect(throws: (any Error).self) { try await store.completeDocumentationAnalysis(interrupted, result: payload) }
        #expect(try await store.documentationAnalysisCheckpoints(projectID: project.id).first { $0.key == "batch-two" }?.state == .running)
    }
}
