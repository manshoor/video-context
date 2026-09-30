import Foundation
import Testing
@testable import VideoContextCore

struct DocumentProposalInboxTests {
    @Test func retriesAreIdempotentAndConflictingRequestsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try DocumentProposalInbox(url: root.appending(path: "inbox.sqlite"))
        let payload = Data("{\"markdown\":\"Proposed change\"}".utf8)
        let original = try await inbox.submit(requestID: "request-1", projectID: "project-a", documentID: "doc-a", expectedRevision: 2, payload: payload)
        let duplicate = try await inbox.submit(requestID: "request-1", projectID: "project-a", documentID: "doc-a", expectedRevision: 2, payload: payload)
        #expect(original == duplicate)
        await #expect(throws: TaskContextError.self) {
            try await inbox.submit(requestID: "request-1", projectID: "project-a", documentID: "doc-a", expectedRevision: 3, payload: payload)
        }
        #expect(try await inbox.pending(projectID: "project-a").count == 1)
        #expect(try await inbox.pending(projectID: "project-b").isEmpty)
        try await inbox.markImported(id: original.id)
        #expect(try await inbox.pending(projectID: "project-a").isEmpty)
        #expect(try await inbox.submit(requestID: "request-1", projectID: "project-a", documentID: "doc-a", expectedRevision: 2, payload: payload).imported)
    }

    @Test func oversizedSubmissionDoesNotEnterInbox() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try DocumentProposalInbox(url: root.appending(path: "inbox.sqlite"))
        await #expect(throws: TaskContextError.self) {
            try await inbox.submit(requestID: "oversized", projectID: "a", documentID: "d", expectedRevision: 1, payload: Data(repeating: 0, count: 1_048_577))
        }
        #expect(try await inbox.pending(projectID: "a").isEmpty)
    }
}
