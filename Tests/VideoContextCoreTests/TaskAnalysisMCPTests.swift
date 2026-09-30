import Foundation
import Testing
@testable import VideoContextCore

struct TaskAnalysisMCPTests {
    @Test func reviewedSectionAndVisualOnlyReferencesHaveExactRetrievalRequests() throws {
        let section = ProjectEvidenceReference.reviewedDocumentation(documentID: "main-doc", revision: 3, sectionID: "section-login")
        let screenshot = ProjectEvidenceReference.recording(videoID: "original", sourceRevision: .init(transcript: 2, evidence: 4, brief: 1), timestamp: 8, evidenceID: "frame-8")
        let content = TaskContent(evidenceReferences: [section], visualEvidenceObservations: [
            .init(evidence: screenshot, visualInterpretation: "Unreadable label", extractedOCR: "Maybe", assessment: .unreadable)
        ])
        let blocks = try TaskAnalysisMCPBlocks.make(content: content, projectID: "project")
        let requests = blocks.filter { $0.kind == "project_evidence_request" }
        #expect(requests.count == 2)
        #expect(requests.contains { $0.text.contains("reviewedDocumentation") && $0.text.contains("section-login") && $0.text.contains("\"revision\":3") })
        #expect(requests.contains { $0.text.contains("frame-8") && $0.text.contains("original") })
    }

    @Test func evidenceRequestsPreserveProjectRevisionAndLocator() throws {
        let reference = ProjectEvidenceReference.document(sourceID: "source-reference", revision: 7, locator: .init(markdownLine: 14, endLine: 18))
        let content = TaskContent(title: "Referenced requirement", evidenceReferences: [reference],
                                  dependencyTaskIDs: ["task-prerequisite"], analysisSourceFingerprint: "frozen-context")
        let blocks = try TaskAnalysisMCPBlocks.make(content: content, projectID: "project-exact")
        let request = try #require(blocks.first { $0.kind == "project_evidence_request" })
        let json = String(request.text.dropFirst("Call get_project_evidence with ".count))
        let args = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(args["project_id"] as? String == "project-exact")
        #expect(args["source_id"] as? String == "source-reference")
        #expect(args["revision"] as? Int == 7)
        let locator = try #require(args["locator"] as? [String: Any])
        #expect(locator["startLine"] as? Int == 14)
        #expect(locator["endLine"] as? Int == 18)
        #expect(blocks.contains { $0.kind == "task_dependency" && $0.text == "task-prerequisite" })
    }

    @Test func reviewFailureAndBothConflictSourcesAreVisibleToEditors() throws {
        let first = ProjectEvidenceReference.document(sourceID: "source-a", revision: 1, locator: .init(markdownLine: 1))
        let second = ProjectEvidenceReference.feedback(batchID: "batch-b", sourceRevision: 4, commentID: "comment-b", sourceID: nil)
        let finding = TaskEvidenceReviewFinding(kind: .contradiction, message: "Visibility differs", blocking: true,
                                                evidence: [first], conflictingEvidence: [second])
        let review = TaskEvidenceReview(status: .awaitingReview, findings: [finding], sourceFingerprint: "source",
                                        promptVersion: "test", errorMessage: "Provider outcome unknown")
        let blocks = try TaskAnalysisMCPBlocks.make(content: .init(evidenceReview: review), projectID: "project")
        #expect(blocks.filter { $0.kind == "project_evidence_request" }.count == 2)
        #expect(blocks.contains { $0.kind == "ai_review_state" && $0.text.contains("awaitingReview") && $0.text.contains("unknown") })
        #expect(blocks.contains { $0.kind == "ai_review_finding" && $0.text.contains("Visibility differs") })
    }
}
