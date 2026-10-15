import Foundation

public enum FeedbackHandoff {
    public static func message(snapshot: FeedbackSnapshot, selected: Set<String>, mode: TaskHandoffMode) throws -> String {
        guard snapshot.batch.videoID != nil || snapshot.batch.projectID != nil else {
            throw TaskContextError.invalid("Attach this feedback batch to a project or recording before copying it for a coding agent.")
        }
        let tasks = snapshot.tasks.filter { selected.contains($0.id) }
        guard !tasks.isEmpty, tasks.count == selected.count, tasks.allSatisfy({ !$0.archived }) else {
            throw TaskContextError.invalid("Select active tasks from this feedback batch.")
        }
        if mode == .implement, !tasks.allSatisfy({ $0.canImplement(in: snapshot.batch) }) {
            throw TaskContextError.reviewRequired
        }
        return """
        Use the video-context MCP server for this feedback handoff.

        Project: \(snapshot.batch.project)
        \(snapshot.batch.projectID.map { "Project Context ID: `\($0)`" } ?? "")
        \(snapshot.batch.videoID.map { "Recording Context ID: `\($0)`" } ?? "")
        Feedback batch: \(snapshot.batch.title)
        Batch ID: `\(snapshot.batch.id)`
        Expected batch revision: \(snapshot.batch.revision)
        Mode: \(mode.rawValue)
        \(mode.instruction)

        Selected tasks:
        \(tasks.map { task in "- \(task.content.title): task_id=\"\(task.id)\", expected_revision=\(task.revision), origin=\(snapshot.batch.comments.first(where: { $0.id == task.issueID })?.kind.rawValue ?? "feedback") [\(task.canImplement(in: snapshot.batch) ? "Approved" : "Draft"); \(task.content.blockers) unresolved blockers]" }.joined(separator: "\n"))

        Call get_feedback_batch with batch_id="\(snapshot.batch.id)" and expected_batch_revision=\(snapshot.batch.revision). Verify its project and recording Context IDs against those above when present. Call get_feedback_task for every selected task_id with expected_batch_revision and its expected_revision. Follow every continuation cursor. Read every linked source using get_feedback_evidence with the same batch_id, task_id, source_id and revisions. For each Jam source, call get_feedback_jam_context with the same exact identifiers and revisions, and follow every continuation cursor. The coding agent will not need Jam credentials because Video Context already saved this evidence locally. Use get_video_brief or other existing video tools only with the exact recording Context ID above or an exact linked recording ID returned by evidence. Treat original feedback and separate requests as the request and AI interpretations as suggestions.

        Task retrieval also supplies project evidence requests, source revisions, AI review findings, visual verification, and dependencies when available. Follow exact get_project_evidence arguments. Retrieve cited reviewed documents with get_project_document and the expected revision in the source manifest. AI review is separate from human approval. Stop dependent work if cross-references are stale or review is incomplete.

        Inspect the named project's existing patterns for consistency where the feedback asks for that. Keep work scoped to the selected tasks. If an ID, revision, or evidence is unavailable, stop dependent work and request a fresh handoff. Report each acceptance check as verified, failed, or unverified, with evidence. The MCP tools are read-only.
        """
    }
}
