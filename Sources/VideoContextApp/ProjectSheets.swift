import SwiftUI
import VideoContextCore

struct ProjectRequestSheet: View {
    @Bindable var model: AppModel
    let project: FeedbackProject
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New task request").font(.title2.bold())
            Label(project.name, systemImage: "folder").foregroundStyle(.secondary)
            TextField("Request title", text: $title).textFieldStyle(.roundedBorder)
            Text("Describe the changes you need. Put separate requests on separate lines.").font(.callout)
            TextEditor(text: $text).accessibilityLabel("Request details").frame(minHeight: 240).border(.quaternary)
            Text("Save the request, then generate and review its tasks. A recording is optional.").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save request") {
                    saving = true
                    Task {
                        if await model.createProjectTaskRequest(projectID: project.id, title: title, text: text) { dismiss() }
                        else { error = model.errorMessage; model.errorMessage = nil }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 600).interactiveDismissDisabled(!text.isEmpty || saving)
    }
}

struct ProjectMoveSheet: View {
    @Bindable var model: AppModel
    let source: ProjectSourceReference
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var preview: ProjectMovePreview?
    @State private var error: String?
    @State private var moving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move source group").font(.title2.bold())
            Text("Linked recordings, feedback batches, and their tasks move together.").foregroundStyle(.secondary)
            Picker("Destination project", selection: $destination) {
                Text("Choose a project").tag("")
                ForEach(model.feedbackProjects) { Text($0.name).tag($0.id) }
            }.disabled(moving)
            if let preview {
                Text("\(preview.recordings.count) recordings · \(preview.batches.count) batches · \(preview.tasks.count) tasks").font(.headline)
                List {
                    Section("Recordings") { ForEach(preview.recordings) { Label($0.title, systemImage: "video") } }
                    Section("Feedback and requests") { ForEach(preview.batches) { Label($0.title, systemImage: "text.bubble") } }
                    Section("Tasks") { ForEach(preview.tasks) { Label($0.content.title, systemImage: $0.archived ? "archivebox" : "checklist") } }
                    if !preview.affectedDocumentation.isEmpty {
                        Section("Documentation requiring review") { ForEach(preview.affectedDocumentation) { Label($0.title, systemImage: "doc.text") } }
                    }
                    if !preview.affectedDecisions.isEmpty {
                        Section("Decisions requiring review") { ForEach(preview.affectedDecisions) { Label($0.question, systemImage: "questionmark.bubble") } }
                    }
                }.frame(minHeight: 220)
                Text("Moving to a different project requires a fresh review. Task wording, evidence, IDs, and history are preserved. Pending proposals become outdated.").font(.callout)
                if let reason = preview.blockedReason { Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            } else if !destination.isEmpty && error == nil { ProgressView("Preparing preview…") }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(moving)
                Spacer()
                Button("Move group") {
                    guard let preview else { return }
                    moving = true
                    Task {
                        if await model.performProjectMove(preview) { dismiss() }
                        else { error = model.errorMessage ?? "Wait for processing or editing to finish."; model.errorMessage = nil }
                        moving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(preview == nil || preview?.blockedReason != nil || moving || model.projectMoveBlocked)
            }
        }.padding(24).frame(width: 620, height: 560).interactiveDismissDisabled(moving)
            .task(id: destination) {
                preview = nil; error = nil
                guard !destination.isEmpty, let store = model.store else { return }
                let requested = destination
                do {
                    let result = try await store.previewProjectMove(source: source, destinationProjectID: requested)
                    guard !Task.isCancelled, requested == destination else { return }
                    preview = result
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
}

struct ProjectHandoffSheet: View {
    @Bindable var model: AppModel
    let snapshot: ProjectWorkspaceSnapshot
    let selected: Set<ProjectTaskReference>
    @Environment(\.dismiss) private var dismiss
    @State private var mode: TaskHandoffMode = .plan
    @State private var message = ""
    @State private var error: String?
    @State private var copying = false
    private var implementAllowed: Bool {
        let tasks = snapshot.tasks.filter { selected.contains($0.reference) }
        return !tasks.isEmpty && tasks.count == selected.count && tasks.allSatisfy(\.canImplement)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy tasks for AI").font(.title2.bold())
            Text("\(snapshot.project?.name ?? "Project") · \(selected.count) selected tasks").foregroundStyle(.secondary)
            HStack {
                ForEach(TaskHandoffMode.allCases, id: \.self) { value in
                    Button(value.rawValue) { mode = value }.tint(mode == value ? .accentColor : .secondary)
                        .disabled(value == .implement && !implementAllowed)
                        .accessibilityAddTraits(mode == value ? .isSelected : [])
                }
            }
            if !implementAllowed { Text("Implement requires every selected task to be current, reviewed, and free of unresolved blockers.").font(.callout).foregroundStyle(.orange) }
            TextEditor(text: $message).font(.body.monospaced())
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Reset preview") { rebuild() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Copy message") {
                    copying = true
                    Task {
                        if await model.copyProjectHandoff(snapshot, selected: selected, mode: mode, text: message) { dismiss() }
                        else { error = model.errorMessage; model.errorMessage = nil }
                        copying = false
                    }
                }.buttonStyle(.borderedProminent).disabled(copying || message.isEmpty || error != nil)
            }
        }.padding(24).frame(minWidth: 700, idealWidth: 820, minHeight: 550, idealHeight: 700)
            .onAppear { rebuild() }.onChange(of: mode) { _, _ in rebuild() }
    }
    private func rebuild() {
        do { message = try ProjectHandoff.message(snapshot: snapshot, selected: selected, mode: mode); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
