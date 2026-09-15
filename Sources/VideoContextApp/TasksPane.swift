import SwiftUI
import VideoContextCore

private struct TaskEditorPresentation: Identifiable {
    let task: VideoTask
    let source: ArtifactRevision
    let isNew: Bool
    var id: String { task.id }
}

struct BriefTasksPane: View {
    @Bindable var model: AppModel
    let snapshot: VideoSnapshot
    @State private var tab = CommandLine.arguments.contains("--ui-tasks") ? "Tasks" : "Brief"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Context view", selection: $tab) {
                Text("Brief").tag("Brief"); Text("Tasks").tag("Tasks")
            }.pickerStyle(.segmented).padding(10)
            if tab == "Brief" { BriefPane(model: model, videoID: snapshot.video.id, brief: snapshot.brief) }
            else { TasksPane(model: model, videoID: snapshot.video.id) }
        }
    }
}

struct TasksPane: View {
    @Bindable var model: AppModel
    let videoID: String
    @State private var selected: Set<String> = []
    @State private var editor: TaskEditorPresentation?
    @State private var showHandoff = false
    @State private var proposal: TaskProposal?
    @State private var showQuestions = false
    @State private var showArchived = false
    private var library: TaskLibrarySnapshot? { model.taskLibrary?.video.id == videoID ? model.taskLibrary : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { generationButton; addButton; copyButton }
                HStack { generationButton; addButton; Spacer(minLength: 0); copyButton.labelStyle(.iconOnly) }
            }
            Text(model.taskProviderLabel).font(.caption).foregroundStyle(.secondary)
            if let message = model.taskGenerationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Toggle("Open questions", isOn: $showQuestions).toggleStyle(.button)
                Toggle("Archived", isOn: $showArchived).toggleStyle(.button)
            }.font(.caption)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let library {
                        if library.tasks.isEmpty && library.proposals.isEmpty {
                            ContentUnavailableView("Turn this recording into tasks", systemImage: "checklist", description: Text("Generate task proposals or add a task. Review requirements and evidence before an implementation handoff."))
                        }
                        ForEach(library.proposals) { item in
                            Button { proposal = item } label: {
                                Label("\(item.kind == .addition ? "Add" : item.kind == .archive ? "Archive" : "Update"): \(item.content?.title ?? library.tasks.first(where: { $0.id == item.taskID })?.content.title ?? "Task")", systemImage: "doc.badge.gearshape")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered).help("Review proposed changes before applying")
                        }
                        ForEach(library.tasks.filter { ($0.archived == showArchived) && (!showQuestions || $0.content.questions.contains(where: { $0.answer.isEmpty })) }) { task in
                            card(task, library: library)
                        }
                    }
                }
            }
        }.padding(12)
        .sheet(item: $editor) { presentation in
            TaskEditorSheet(model: model, initial: presentation.task, source: presentation.source, isNew: presentation.isNew)
        }
        .sheet(item: $proposal) { proposal in
            if let library { TaskProposalSheet(model: model, proposal: proposal, existing: library.tasks.first { $0.id == proposal.taskID }) }
        }
        .sheet(isPresented: $showHandoff) { if let library { TaskHandoffSheet(model: model, snapshot: library, selected: selected) } }
        .onChange(of: videoID) { _, _ in selected = []; editor = nil; proposal = nil }
    }
    private var generationButton: some View {
        Button("Generate tasks", systemImage: "sparkles") { model.generateTasks() }
            .disabled(model.isProcessing || library?.video.status != .ready || library?.video.revisions.isBriefStale != false || model.snapshot?.brief == nil)
            .help("Generate proposals with the provider shown below")
    }
    private var addButton: some View {
        Button("Add", systemImage: "plus") {
            guard let library else { return }
            let task = VideoTask(videoID: videoID, sourceRevision: library.video.revisions, content: .init(), order: (library.tasks.map(\.order).max() ?? -1) + 1)
            editor = TaskEditorPresentation(task: task, source: library.video.revisions, isNew: true)
        }.help("Add a task manually").disabled(library == nil)
    }
    private var copyButton: some View {
        Button("Copy selected tasks", systemImage: "doc.on.clipboard") { showHandoff = true }
            .disabled(selected.isEmpty).help("Preview a focused agent handoff")
    }
    private func card(_ task: VideoTask, library: TaskLibrarySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Toggle(isOn: Binding(get: { selected.contains(task.id) }, set: { if $0 { selected.insert(task.id) } else { selected.remove(task.id) } })) {
                    Text(task.content.title).font(.headline)
                }.disabled(task.archived)
                Spacer(minLength: 0)
                Button("Edit", systemImage: "pencil") { editor = TaskEditorPresentation(task: task, source: library.video.revisions, isNew: false) }.labelStyle(.iconOnly).help("Edit task, questions, checks and annotations")
            }
            Text("\(task.state(library.video)) · r\(task.revision) · \(task.content.checks.count) acceptance checks").font(.caption).foregroundStyle(.secondary)
            if task.content.blockers > 0 { Label("\(task.content.blockers) unresolved blockers", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange) }
            if task.generatedOriginal != nil && task.generatedOriginal != task.content { Label("User edited", systemImage: "pencil").font(.caption) }
            Text(task.content.behavior).font(.callout).lineLimit(3)
            if showQuestions {
                ForEach(task.content.questions.filter { $0.answer.isEmpty }) { question in
                    Text("• \(question.question)").font(.callout)
                }
            }
            HStack {
                Button("Review", systemImage: "checkmark.seal") { editor = TaskEditorPresentation(task: task, source: library.video.revisions, isNew: false) }.disabled(task.archived)
                Spacer()
                Button("Move up", systemImage: "arrow.up") { Task { await model.moveVideoTask(task, direction: -1, source: library.video.revisions) } }.labelStyle(.iconOnly).help("Move task up")
                Button("Move down", systemImage: "arrow.down") { Task { await model.moveVideoTask(task, direction: 1, source: library.video.revisions) } }.labelStyle(.iconOnly).help("Move task down")
            }.font(.caption)
        }.padding(10).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
