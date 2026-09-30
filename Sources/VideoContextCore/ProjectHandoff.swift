import Foundation

public enum ProjectHandoff {
    public static func message(snapshot: ProjectWorkspaceSnapshot, selected: Set<ProjectTaskReference>, mode: TaskHandoffMode) throws -> String {
        guard let project = snapshot.project else { throw TaskContextError.invalid("Assign these sources to a project before copying a handoff.") }
        let tasks = snapshot.tasks.filter { selected.contains($0.reference) }
        guard !tasks.isEmpty, tasks.count == selected.count, tasks.allSatisfy({ !$0.archived }) else { throw TaskContextError.invalid("Select active tasks from this project.") }
        if mode == .implement && !tasks.allSatisfy(\.canImplement) { throw TaskContextError.reviewRequired }
        var lines = ["Use the video-context MCP server for these selected tasks.", "", "Project: \(project.name)", "Project Context ID: `\(project.id)`", "Mode: \(mode.rawValue)", mode.instruction, "", "Selected tasks (exact scope and revisions):"]
        for task in tasks {
            lines.append("- \(task.content.title) [\(task.state); \(task.content.blockers) unresolved blockers]")
            switch task.reference {
            case .recording(let videoID, let taskID):
                guard let video = snapshot.recordings.first(where: { $0.id == videoID }) else { throw TaskContextError.missing(videoID) }
                lines.append("  Expected recording source revisions: transcript=\(video.revisions.transcript), evidence=\(video.revisions.evidence), brief=\(video.revisions.brief). Verify the returned source revision before using its evidence.")
                lines.append("  Call get_video_task with video_id=\"\(videoID)\", task_id=\"\(taskID)\", expected_revision=\(task.revision). Read linked transcript with get_video_segment and screenshots/annotations with get_task_frame, using this exact video_id and task_id.")
            case .feedback(let batchID, let taskID):
                guard let batch = snapshot.batches.first(where: { $0.id == batchID }) else { throw TaskContextError.missing(batchID) }
                lines.append("  Call get_feedback_batch with batch_id=\"\(batchID)\", expected_batch_revision=\(batch.revision). Verify project_id=\"\(project.id)\". Call get_feedback_task with the same batch_id, expected_batch_revision, task_id=\"\(taskID)\", expected_revision=\(task.revision). Read linked sources with get_feedback_evidence and saved Jam context with get_feedback_jam_context, keeping these identifiers and revisions.")
            }
        }
        lines += ["", "Read project evidence requests, frozen source manifests, AI review findings, visual verification, and dependencies returned with each task. Retrieve exact references with get_project_evidence and reviewed documents with get_project_document at the manifest revision. AI review does not replace human approval.", "", "Follow every continuation cursor. Use only the listed tasks and their exact linked sources. Multiple recordings and batches listed here are intentional; do not discover substitute recordings or implement unselected tasks. Treat user requests and original feedback as requirements and AI interpretations as suggestions. Inspect the project's existing patterns where requested.", "", "If an ID, revision, or supporting evidence is unavailable, stop dependent work and request an updated handoff. Draft, stale, or blocked tasks require review before implementation. Review approves requirements; it does not mean implementation is complete. Report acceptance checks as verified, failed, or unverified with evidence. MCP tools are read-only; saved Jam evidence needs no Jam credentials. If MCP is unavailable, ask to connect Video Context."]
        return lines.joined(separator: "\n")
    }
}

extension VideoContextStore {
    public func validateProjectHandoff(snapshot: ProjectWorkspaceSnapshot, selected: Set<ProjectTaskReference>, mode: TaskHandoffMode) throws {
        try pool.read { db in
            guard let projectID = snapshot.project?.id else { throw TaskContextError.reviewRequired }
            let current = try Self.projectWorkspace(projectID: projectID, db: db)
            for reference in selected {
                guard let before = snapshot.tasks.first(where: { $0.reference == reference }),
                      let after = current.tasks.first(where: { $0.reference == reference }),
                      before.revision == after.revision, before.sourceSignature == after.sourceSignature else { throw TaskContextError.conflict }
            }
            _ = try ProjectHandoff.message(snapshot: current, selected: selected, mode: mode)
        }
    }
}
