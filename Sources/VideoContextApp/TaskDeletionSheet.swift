import SwiftUI
import VideoContextCore

struct TaskDeletionSheet: View {
    @Bindable var model: AppModel
    @Bindable var presentation: TaskDeletionPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Permanently delete tasks?", systemImage: "trash").font(.title2.bold())
            Text("These tasks and their task histories will be permanently removed. Their recordings, screenshots, PRDs, feedback, and product documentation will remain available.")
            List(presentation.preview.tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.headline)
                    Text(task.archived ? "Archived task" : task.reviewed ? "Reviewed task" : "Task awaiting review")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }.frame(minHeight: 90, maxHeight: 230)
            Text("Deleted work stays excluded from generation until you choose Allow generation again in its source details. Unsaved changes to these tasks will also be discarded.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = presentation.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if presentation.deleting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { model.taskDeletion = nil }.keyboardShortcut(.cancelAction)
                Button("Delete permanently", role: .destructive) { Task { await model.confirmTaskDeletion() } }
            }.disabled(presentation.deleting)
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(presentation.deleting)
    }
}

struct GenerationExclusionControl: View {
    @Bindable var model: AppModel
    let source: ProjectSourceReference
    @State private var exclusions: [TaskGenerationExclusion] = []
    @State private var showConfirmation = false
    @State private var resetting = false
    var body: some View {
        Group {
            if !exclusions.isEmpty {
                Button("Allow generation again…", systemImage: "arrow.counterclockwise") { showConfirmation = true }
                    .help("Deleted tasks stay removed; future generation may create new tasks from this source.")
                    .disabled(resetting)
                    .confirmationDialog("Allow this source to generate deleted work again?", isPresented: $showConfirmation, titleVisibility: .visible) {
                        Button("Allow generation again") { Task { await reset() } }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This clears \(exclusions.count) generation exclusions. Deleted tasks and their histories will not be restored. Generate tasks explicitly to review new suggestions.")
                    }
            }
        }.task(id: "\(source.id):\(model.projectWorkspace?.tasks.count ?? 0)") { await load() }
    }
    private func load() async {
        guard let store = model.store else { return }
        do { exclusions = try await store.taskGenerationExclusions(source: source) }
        catch { model.errorMessage = error.localizedDescription }
    }
    private func reset() async {
        guard let store = model.store else { return }
        let projectID = model.selectedProjectID
        resetting = true; defer { resetting = false }
        do {
            try await store.resetTaskGenerationExclusions(source: source, projectID: projectID)
            await load()
        } catch { model.errorMessage = error.localizedDescription }
    }
}
