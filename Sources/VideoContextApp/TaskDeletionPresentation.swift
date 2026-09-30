import Foundation
import Observation
import VideoContextCore

@MainActor @Observable
final class TaskDeletionPresentation: Identifiable {
    let id = UUID()
    let preview: ProjectTaskDeletionPreview
    var deleting = false
    var error: String?
    init(preview: ProjectTaskDeletionPreview) { self.preview = preview }
}

extension AppModel {
    func requestTaskDeletion(_ selected: Set<ProjectTaskReference>) async {
        guard let store, !selected.isEmpty, taskDraft?.saving != true else { return }
        let location = workspaceLocation
        do {
            let preview = try await store.previewProjectTaskDeletion(projectID: location.projectID, selected: selected)
            guard workspaceLocation == location else { return }
            taskDeletion = TaskDeletionPresentation(preview: preview)
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func confirmTaskDeletion() async -> Bool {
        guard let presentation = taskDeletion, !presentation.deleting, let store else { return false }
        presentation.deleting = true
        defer { presentation.deleting = false }
        do {
            if let taskDeleter { try await taskDeleter(presentation.preview) }
            else { try await store.deleteProjectTasks(presentation.preview) }
            let references = Set(presentation.preview.tasks.map(\.reference))
            if let draft = taskDraft, references.contains(draft.reference) {
                taskDraft = nil
                workspaceLocation.task = nil
                pendingNavigation = nil
                showUnsavedTaskAlert = false
            }
            if let oldTask = sourceReturnLocation?.task, references.contains(oldTask) { sourceReturnLocation = nil }
            if taskDeletion?.id == presentation.id { taskDeletion = nil }
            await loadSelection()
            return true
        } catch {
            presentation.error = error.localizedDescription
            return false
        }
    }
}
