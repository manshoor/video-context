import Foundation

/// Additive, paginated context shared by recording and feedback task retrieval.
enum TaskAnalysisMCPBlocks {
    static func make(content: TaskContent, projectID: String?) throws -> [TaskContextBlock] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        var blocks: [TaskContextBlock] = []
        if let fingerprint = content.analysisSourceFingerprint {
            blocks.append(.init(kind: "analysis_source_fingerprint", text: fingerprint))
        }
        for entry in content.analysisSourceManifest {
            blocks.append(.init(kind: "analysis_source_revision", text: try json(entry)))
        }
        if let review = content.evidenceReview {
            blocks.append(.init(kind: "ai_review_state", text: "\(review.status.rawValue). AI review is separate from human approval. Reviewer: \(review.reviewer?.model ?? "unavailable"). \(review.errorMessage ?? "")"))
            blocks.append(.init(kind: "ai_review_metadata", text: try json(review)))
            for finding in review.findings { blocks.append(.init(kind: "ai_review_finding", text: try json(finding))) }
        }
        let references = content.evidenceReferences + content.visualEvidenceObservations.map(\.evidence) +
            (content.evidenceReview?.findings.flatMap { $0.evidence + $0.conflictingEvidence } ?? [])
        if let projectID {
            for reference in Set(references).sorted(by: { $0.id < $1.id }) {
                blocks.append(.init(kind: "project_evidence", text: try json(reference), sourceID: reference.id))
                blocks.append(.init(kind: "project_evidence_request", text: try evidenceRequest(reference, projectID: projectID), sourceID: reference.id))
            }
        }
        for observation in content.visualEvidenceObservations {
            blocks.append(.init(kind: "visual_verification", text: try json(observation), sourceID: observation.evidence.id))
        }
        for dependency in content.dependencyTaskIDs {
            blocks.append(.init(kind: "task_dependency", text: dependency))
        }
        return blocks
    }

    private static func evidenceRequest(_ reference: ProjectEvidenceReference, projectID: String) throws -> String {
        var arguments: [String: Any] = ["project_id": projectID]
        switch reference {
        case .recording(let videoID, let revision, let timestamp, let evidenceID):
            arguments["kind"] = "recording"; arguments["source_id"] = videoID
            arguments["revision"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(revision))
            arguments["timestamp_seconds"] = timestamp
            if let evidenceID { arguments["evidence_id"] = evidenceID }
        case .feedback(let batchID, let revision, let commentID, let sourceID):
            arguments["kind"] = "feedback"; arguments["source_id"] = batchID; arguments["revision"] = revision
            if let commentID { arguments["comment_id"] = commentID }
            if let sourceID { arguments["feedback_source_id"] = sourceID }
        case .document(let sourceID, let revision, let locator):
            arguments["kind"] = "document"; arguments["source_id"] = sourceID; arguments["revision"] = revision
            arguments["locator"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(locator))
        case .reviewedDocumentation(let documentID, let revision, let sectionID):
            arguments["kind"] = "reviewedDocumentation"; arguments["source_id"] = documentID; arguments["revision"] = revision
            if let sectionID { arguments["section_id"] = sectionID }
        }
        return "Call get_project_evidence with " + String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
    }
}
