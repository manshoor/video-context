import Foundation
import Testing
@testable import VideoContextCore

struct ProjectDecisionMoveTests {
    @Test func movedEvidenceIsPreviewedAndCanBeReconfirmedAsAManualDecision() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "decision-move-\(UUID())"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let a = try await store.createFeedbackProject(name: "First product")
        let b = try await store.createFeedbackProject(name: "Second product")
        let source = try await store.createProjectRequest(projectID: a.id, title: "Source", text: "Keep preview visible")
        let decision = try await store.saveProjectDecision(.init(projectID: a.id, key: "preview", question: "Keep preview visible?", answer: "Yes",
            evidence: [.feedback(batchID: source.id, sourceRevision: source.revision, commentID: source.comments[0].id, sourceID: nil)], state: .confirmed))
        let document = try await store.createDocumentationDraft(projectID: a.id, title: "Preview", slug: "preview", sections: [
            .init(title: "Decision", body: "Keep preview visible", classification: .confirmedDecision, decisionIDs: [decision.id])
        ])
        _ = try await store.reviewDocumentation(documentID: document.id, projectID: a.id, expectedRevision: document.currentRevision)
        let move = try await store.previewProjectMove(source: .feedback(source.id), destinationProjectID: b.id)
        #expect(move.affectedDecisions.map(\.id) == [decision.id])
        #expect(move.affectedDocumentation.map(\.id) == [document.id])
        try await store.moveProjectSources(move)
        let changed = try await store.projectDocumentation(projectID: a.id)
        #expect(changed.decisions[0].evidenceNeedsReview == true)
        #expect(changed.documentation[0].isReviewed == false)
        await #expect(throws: (any Error).self) { try await store.currentDecisionEvidence(decision) }
        var manual = decision; manual.evidence = []; manual.evidenceNeedsReview = false
        let saved = try await store.saveProjectDecision(manual, expectedRevision: decision.revision)
        #expect(saved.answer == decision.answer)
        #expect(saved.revision == 2)
        #expect(try await store.projectDocumentation(projectID: a.id).decisions[0].evidenceNeedsReview == false)
        #expect(try await store.feedbackSnapshot(id: source.id).batch.projectID == b.id)
        #expect(try await store.feedbackSnapshot(id: source.id).batch.rawText == "Keep preview visible")
    }
}
