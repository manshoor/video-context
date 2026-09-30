import Foundation
import Observation
import VideoContextCore

struct WorkspaceLocation: Equatable {
    enum Root: Hashable { case inbox, project(String) }
    enum Section: String, CaseIterable { case tasks = "Tasks", documentation = "Documentation", recordings = "Recordings", feedback = "Feedback & Requests" }
    var root: Root = .inbox
    var section: Section = .tasks
    var recordingID: String?
    var feedbackID: String?
    var feedbackCommentID: String?
    var task: ProjectTaskReference?
    var proposalID: String?
    var documentationSelection: DocumentationSelection?
    var documentSourceRevision: Int?
    var projectID: String? { if case .project(let id) = root { id } else { nil } }
}

@MainActor @Observable
final class ProjectTaskDraft {
    let reference: ProjectTaskReference
    var recording: TaskLibrarySnapshot?
    var feedback: FeedbackSnapshot?
    var content: TaskContent
    var archived: Bool
    var savedContent: TaskContent
    var savedArchived: Bool
    var saving = false
    var error: String?
    var dirty: Bool { content != savedContent || archived != savedArchived }
    var taskID: String { reference.taskID }
    var revision: Int { videoTask?.revision ?? feedbackTask?.revision ?? 0 }
    var videoTask: VideoTask? { recording?.tasks.first { $0.id == taskID } }
    var feedbackTask: FeedbackTask? { feedback?.tasks.first { $0.id == taskID } }
    var source: ProjectSourceReference { reference.source }
    var sourceTitle: String { recording?.video.title ?? feedback?.batch.title ?? "Source" }
    var canReview: Bool {
        !dirty && !saving && !archived && content.blockers == 0 && !content.checks.isEmpty && !content.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !(content.evidenceReview.map { [.awaitingReview, .failed].contains($0.status) } ?? false) &&
        (videoTask.map { task in recording.map { !task.isStale($0.video) && $0.video.status == .ready } ?? false } ?? feedbackTask.map { $0.sourceRevision == feedback?.batch.revision && $0.analysisIsStale != true } ?? false)
    }
    init(reference: ProjectTaskReference, recording: TaskLibrarySnapshot? = nil, feedback: FeedbackSnapshot? = nil, content: TaskContent, archived: Bool) {
        self.reference = reference; self.recording = recording; self.feedback = feedback
        self.content = content; self.archived = archived; savedContent = content; savedArchived = archived
    }
    func discard() { content = savedContent; archived = savedArchived; error = nil }
}

extension AppModel {
    func requestNavigation(_ destination: WorkspaceLocation) {
        guard destination != workspaceLocation else { return }
        guard taskDraft?.saving != true, documentationDraft?.saving != true else { return }
        if taskDraft?.dirty == true || documentationDraft?.dirty == true { pendingNavigation = destination; showUnsavedTaskAlert = true; return }
        applyNavigation(destination)
    }
    func applyNavigation(_ destination: WorkspaceLocation) {
        workspaceLoadTask?.cancel()
        if destination.root != workspaceLocation.root {
            projectAnalysisWarnings = []
            if destination.section == .tasks { sourceReturnLocation = nil }
            projectWorkspace = nil
        }
        workspaceLocation = destination
        taskDraft = nil; snapshot = nil; taskLibrary = nil; feedbackSnapshot = nil
        documentationDraft = nil; documentationSourceRevision = nil
        if destination.section != .documentation { documentationEvidenceLocator = nil }
        workspaceLoadError = nil
        workspaceLoadTask = Task { await loadSelection() }
    }
    func resolvePendingNavigation(save: Bool) async {
        if save {
            if documentationDraft?.dirty == true {
                guard await saveDocumentationDraft() else { return }
            } else {
                guard await saveProjectTask() else { return }
            }
        }
        guard let destination = pendingNavigation else { return }
        pendingNavigation = nil
        taskDraft?.discard()
        documentationDraft?.discard()
        applyNavigation(destination)
    }
    func selectProjectTask(_ reference: ProjectTaskReference) {
        var next = workspaceLocation; next.section = .tasks; next.task = reference
        next.recordingID = nil; next.feedbackID = nil; next.proposalID = nil
        requestNavigation(next)
    }
    func openProjectSource(_ source: ProjectSourceReference, timestamp: Double? = nil, commentID: String? = nil) {
        guard let store else { return }
        sourceNavigationTask?.cancel()
        let origin = workspaceLocation
        sourceNavigationTask = Task {
            do {
                var next = origin; next.task = nil; next.proposalID = nil
                let owner: String?
                switch source {
                case .recording(let id):
                    guard let video = try await store.videoSnapshot(id: id)?.video else { throw TaskContextError.missing(id) }
                    owner = video.projectID
                    next.section = .recordings; next.recordingID = id; next.feedbackID = nil
                case .feedback(let id):
                    owner = try await store.feedbackSnapshot(id: id).batch.projectID
                    next.section = .feedback; next.feedbackID = id; next.recordingID = nil
                    next.feedbackCommentID = commentID
                }
                guard !Task.isCancelled, workspaceLocation == origin else { return }
                next.root = owner.map(WorkspaceLocation.Root.project) ?? .inbox
                if origin.section == .tasks || origin.section == .documentation { sourceReturnLocation = origin }
                pendingSourceTimestamp = timestamp
                requestNavigation(next)
            } catch {
                if !Task.isCancelled, workspaceLocation == origin { errorMessage = error.localizedDescription }
            }
        }
    }

    func loadProjectSelection() async {
        guard let store else { return }
        let location = workspaceLocation
        let requestID = UUID(); workspaceLoadID = requestID
        do {
            let workspace: ProjectWorkspaceSnapshot
            if let projectWorkspaceLoader { workspace = try await projectWorkspaceLoader(location.projectID) }
            else { workspace = try await store.projectWorkspace(projectID: location.projectID) }
            try Task.checkCancellation()
            guard workspaceLocation == location, workspaceLoadID == requestID else { return }
            var videoID = location.recordingID
            var batchID = location.feedbackID
            if let task = location.task {
                switch task { case .recording(let id, _): videoID = id; case .feedback(let id, _): batchID = id }
            }
            if batchID == nil { batchID = workspace.batches.first?.id }
            var video: VideoSnapshot?
            var tasks: TaskLibrarySnapshot?
            var feedback: FeedbackSnapshot?
            if let videoID { video = try await store.videoSnapshot(id: videoID); tasks = try await store.taskSnapshot(videoID: videoID) }
            if let batchID { feedback = try await store.feedbackSnapshot(id: batchID) }
            try Task.checkCancellation()
            guard workspaceLocation == location, workspaceLoadID == requestID else { return }
            projectWorkspace = workspace
            snapshot = video; taskLibrary = tasks
            feedbackBatches = workspace.batches; feedbackSnapshot = feedback
            feedbackScopeProjectID = location.projectID; feedbackScopeVideoID = videoID
            if workspaceLocation.feedbackID == nil && location.task == nil && location.section == .feedback { workspaceLocation.feedbackID = batchID }
            workspaceLoadError = nil
            if let reference = location.task, let item = workspace.tasks.first(where: { $0.reference == reference }) {
                if taskDraft?.reference != reference || (taskDraft?.dirty == false && taskDraft?.saving == false && taskDraft?.revision != item.revision) {
                    switch reference {
                    case .recording:
                        taskDraft = ProjectTaskDraft(reference: reference, recording: tasks, content: item.content, archived: item.archived)
                    case .feedback:
                        taskDraft = ProjectTaskDraft(reference: reference, feedback: feedback, content: item.content, archived: item.archived)
                    }
                }
            } else if taskDraft?.dirty != true { taskDraft = nil }
            if let timestamp = pendingSourceTimestamp, video != nil {
                pendingSourceTimestamp = nil; requestSeek(to: timestamp)
            }
            if location.section == .documentation {
                try await loadDocumentationSelection(location: workspaceLocation, requestID: requestID)
            }
        } catch is CancellationError { }
        catch {
            guard workspaceLocation == location, workspaceLoadID == requestID else { return }
            workspaceLoadError = error.localizedDescription
        }
    }

    @discardableResult func saveProjectTask() async -> Bool {
        guard let draft = taskDraft, !draft.saving, let store else { return false }
        draft.saving = true; defer { draft.saving = false }
        do {
            if var task = draft.videoTask, let source = draft.recording?.video.revisions {
                task.content = draft.content; task.archived = draft.archived
                _ = try await store.saveTask(task, expectedRevision: task.revision, expectedSource: source)
                draft.recording = try await store.taskSnapshot(videoID: task.videoID)
            } else if var task = draft.feedbackTask, let batch = draft.feedback?.batch {
                task.content = draft.content; task.archived = draft.archived
                if draft.content == draft.savedContent && draft.archived != draft.savedArchived {
                    try await store.setFeedbackTasksArchived(batchID: batch.id, expectedBatchRevision: batch.revision,
                        expectedTaskRevisions: [task.id: task.revision], archived: draft.archived)
                } else {
                    _ = try await store.saveFeedbackTask(task, expectedRevision: task.revision, expectedBatchRevision: batch.revision)
                }
                draft.feedback = try await store.feedbackSnapshot(id: batch.id)
            } else { throw TaskContextError.missing(draft.taskID) }
            if let saved = draft.videoTask?.content ?? draft.feedbackTask?.content { draft.content = saved }
            draft.savedContent = draft.content; draft.savedArchived = draft.archived; draft.error = nil
            await loadSelection()
            return true
        } catch { draft.error = error.localizedDescription; return false }
    }
    func reviewProjectTask() async {
        guard let draft = taskDraft, draft.canReview, let store else { return }
        draft.saving = true; defer { draft.saving = false }
        do {
            if let task = draft.videoTask, let source = draft.recording?.video.revisions {
                try await store.reviewTask(videoID: task.videoID, taskID: task.id, expectedRevision: task.revision, expectedSource: source)
                draft.recording = try await store.taskSnapshot(videoID: task.videoID)
            } else if let task = draft.feedbackTask, let batch = draft.feedback?.batch {
                try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision, expectedTaskRevisions: [task.id: task.revision])
                draft.feedback = try await store.feedbackSnapshot(id: batch.id)
            }
            draft.error = nil; await loadSelection()
        } catch { draft.error = error.localizedDescription }
    }
    func resolveProjectProposal(_ item: ProjectProposalItem, apply: Bool, keepWording: Bool = false) async {
        guard let store else { return }
        do {
            if let proposal = item.recording { try await store.resolveTaskProposal(videoID: proposal.videoID, proposalID: proposal.id, apply: apply, keepWording: keepWording) }
            if let proposal = item.feedback { try await store.resolveFeedbackProposal(batchID: proposal.batchID, proposalID: proposal.id, apply: apply) }
            await loadSelection()
        } catch { errorMessage = error.localizedDescription }
    }
    func createProjectTaskRequest(projectID: String, title: String, text: String) async -> Bool {
        guard let store else { return false }
        let location = workspaceLocation
        do {
            let batch = try await store.createProjectRequest(projectID: projectID, title: title, text: text)
            if workspaceLocation == location {
                var next = location; next.section = .feedback; next.feedbackID = batch.id; next.recordingID = nil; next.task = nil
                applyNavigation(next)
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    var projectMoveBlocked: Bool { isProcessing || feedbackBusy || feedbackCreationBusy || sourceWorkCount > 0 || documentationBusy || !editingFeedbackIDs.isEmpty || taskDraft?.dirty == true || taskDraft?.saving == true || documentationDraft?.dirty == true || documentationDraft?.saving == true }
    func performProjectMove(_ preview: ProjectMovePreview) async -> Bool {
        guard !projectMoveBlocked, let store else { return false }
        do {
            try await store.moveProjectSources(preview)
            var next = WorkspaceLocation(); next.root = .project(preview.destination.id)
            applyNavigation(next); await loadLibrary()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func copyProjectHandoff(_ snapshot: ProjectWorkspaceSnapshot, selected: Set<ProjectTaskReference>, mode: TaskHandoffMode, text: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.validateProjectHandoff(snapshot: snapshot, selected: selected, mode: mode)
            copy(text); confirmCopy("Project task handoff copied"); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
