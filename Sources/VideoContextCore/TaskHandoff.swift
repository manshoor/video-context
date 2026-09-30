import Foundation

public enum TaskHandoffMode: String, CaseIterable, Codable, Sendable {
    case investigate = "Investigate", plan = "Plan", implement = "Implement"
    public var instruction: String {
        switch self {
        case .investigate: "Inspect evidence, identify causes and missing information. Do not modify code."
        case .plan: "Propose an implementation and verification approach. Do not modify code."
        case .implement: "Implement only the selected reviewed requirements. Report each acceptance check as verified, failed, or unverified, with evidence."
        }
    }
}
public enum TaskHandoff {
    public static func message(snapshot: TaskLibrarySnapshot, selectedIDs: Set<String>, mode: TaskHandoffMode) throws -> String {
        let tasks = snapshot.tasks.filter { selectedIDs.contains($0.id) }
        guard !tasks.isEmpty, tasks.count == selectedIDs.count, tasks.allSatisfy({ !$0.archived }) else { throw TaskContextError.invalid("Select available, active tasks from this recording.") }
        if mode == .implement, !tasks.allSatisfy({ $0.canImplement(snapshot.video) }) { throw TaskContextError.reviewRequired }
        return """
        Use the video-context MCP server for this task.

        Recording: \(snapshot.video.title)
        Context ID: `\(snapshot.video.id)`
        Status when copied: \(snapshot.video.status.rawValue)
        Mode: \(mode.rawValue)
        \(mode.instruction)

        Selected tasks (exact IDs and revisions):
        \(tasks.map { "- \($0.content.title): task_id=\"\($0.id)\", expected_revision=\($0.revision) [\($0.state(snapshot.video)); \($0.content.blockers) unresolved blockers]" }.joined(separator: "\n"))

        Call get_video_task with video_id="\(snapshot.video.id)", each selected task_id, and its expected_revision above. Follow every continuation cursor. Inspect linked transcript with get_video_segment and screenshots/annotations with get_task_frame, using the same video_id, task_id, and expected_revision. User clarifications and annotation notes are identified separately from recorded statements.

        Task retrieval also supplies project evidence requests, source revisions, AI review findings, visual verification, and dependencies when available. Follow exact get_project_evidence arguments. Retrieve cited reviewed documents with get_project_document and the expected revision in the source manifest. AI review is separate from human approval. Stop dependent work if cross-references are stale or review is incomplete.

        Keep implementation scoped to the selected tasks. Do not implement unselected tasks, call list_videos, switch recordings, or guess substitute evidence. Report prerequisites that need work outside this selection. Draft, stale, or blocked tasks require further review before implementation.

        If an ID, revision, or evidence is unavailable, stop dependent work and request an updated handoff. Check supporting evidence before making changes. If the MCP tools are unavailable, ask me to connect the Video Context MCP server.
        """
    }
}
