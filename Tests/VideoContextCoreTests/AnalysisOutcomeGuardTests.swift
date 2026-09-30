import Foundation
import Testing
@testable import VideoContextCore

struct AnalysisOutcomeGuardTests {
    @Test func unknownOutcomeIsHeldEvenWhenJSONObjectOrderChanges() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "outcome-guard-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Recovery")
        let client = OutcomeProbe(fail: true)
        let guardClient = AnalysisOutcomeGuard(base: client, store: store, projectID: project.id, sourceIdentity: "revision-1")
        var request = URLRequest(url: URL(string: "https://example.invalid/analysis")!)
        request.httpBody = Data(#"{"model":"test","prompt":"source"}"#.utf8)
        await #expect(throws: (any Error).self) { try await guardClient.data(for: request) }
        request.httpBody = Data(#"{"prompt":"source","model":"test"}"#.utf8)
        await #expect(throws: (any Error).self) { try await guardClient.data(for: request) }
        #expect(await client.calls == 1)
        let checkpoint = try #require(try await store.documentationAnalysisCheckpoints(projectID: project.id).first)
        #expect(checkpoint.state == .unknown)
        try await store.resetDocumentationAnalysis(checkpoint)
        await #expect(throws: (any Error).self) { try await guardClient.data(for: request) }
        #expect(await client.calls == 2)
    }

    @Test func receivedResponseAllowsCallerToValidateAndRetryKnownInvalidOutput() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "outcome-known-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Known outcome")
        let client = OutcomeProbe(fail: false)
        let guardClient = AnalysisOutcomeGuard(base: client, store: store, projectID: project.id, sourceIdentity: "revision-1")
        let request = URLRequest(url: URL(string: "https://example.invalid/analysis")!)
        _ = try await guardClient.data(for: request)
        _ = try await guardClient.data(for: request)
        #expect(await client.calls == 2)
        #expect(try await store.documentationAnalysisCheckpoints(projectID: project.id).first?.state == .failed)
    }
}

private actor OutcomeProbe: HTTPDataLoading {
    let fail: Bool
    var calls = 0
    init(fail: Bool) { self.fail = fail }
    func data(for request: URLRequest) async throws -> HTTPResult {
        calls += 1
        if fail { throw URLError(.networkConnectionLost) }
        return HTTPResult(data: Data("invalid structured output".utf8), statusCode: 200)
    }
}
