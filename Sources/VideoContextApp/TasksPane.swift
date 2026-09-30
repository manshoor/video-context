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
    var body: some View {
        BriefPane(model: model, videoID: snapshot.video.id, brief: snapshot.brief)
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
        let filtered = TaskPaneFilter(tasks: library?.tasks ?? [], proposals: library?.proposals ?? [], showQuestions: showQuestions, showArchived: showArchived)
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { generationButton; addButton; copyButton }
                HStack { generationButton; addButton; Spacer(minLength: 0); copyButton.labelStyle(.iconOnly) }
            }
            Text(model.taskProviderLabel).font(.caption).foregroundStyle(.secondary)
            if let message = model.taskGenerationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Toggle("Open questions", isOn: $showQuestions).toggleStyle(.button)
                    .help("Show unanswered questions in generated proposals and saved tasks")
                Toggle("Archived", isOn: $showArchived).toggleStyle(.button)
            }.font(.caption)
            if showQuestions {
                Text(showArchived ? "Unanswered questions in archived tasks." : "Unanswered questions in generated proposals and saved tasks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let library {
                        if filtered.tasks.isEmpty && filtered.proposals.isEmpty && showQuestions {
                            ContentUnavailableView("No open questions", systemImage: "checkmark.bubble", description: Text(showArchived ? "No archived tasks have unanswered questions." : "No generated proposals or active tasks have unanswered questions. Turn off Open questions to see all items."))
                        } else if filtered.tasks.isEmpty && filtered.proposals.isEmpty && showArchived {
                            ContentUnavailableView("No archived tasks", systemImage: "archivebox", description: Text("Turn off Archived to see active tasks and proposals."))
                        } else if library.tasks.isEmpty && library.proposals.isEmpty {
                            ContentUnavailableView("Turn this recording into tasks", systemImage: "checklist", description: Text("Generate task proposals or add a task. Review requirements and evidence before an implementation handoff."))
                        }
                        ForEach(filtered.proposals) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { proposal = item } label: {
                                    Label("\(item.kind == .addition ? "Add" : item.kind == .archive ? "Archive" : "Update"): \(item.content?.title ?? library.tasks.first(where: { $0.id == item.taskID })?.content.title ?? "Task")", systemImage: "doc.badge.gearshape")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered).help("Review proposed changes before applying")
                                if showQuestions {
                                    questions(in: item.content)
                                    Text(item.kind == .addition ? "Accept this proposal with Add task, then use Edit to answer its questions." : "Apply this proposal, then use Edit on the saved task to answer its questions.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(filtered.tasks) { task in
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
    private func questions(in content: TaskContent?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(TaskPaneFilter.openQuestions(in: content)) { question in
                VStack(alignment: .leading, spacing: 3) {
                    Label(question.question, systemImage: "questionmark.circle")
                        .font(.callout).textSelection(.enabled)
                    Text(question.unresolved ? "Unresolved blocker" : "Non-blocking · \(question.nonBlockingReason)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
            TaskOriginBadge(origin: task.generatedOriginal == nil ? .request : .recording)
            if task.content.blockers > 0 { Label("\(task.content.blockers) unresolved blockers", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange) }
            if task.generatedOriginal != nil && task.generatedOriginal != task.content { Label("User edited", systemImage: "pencil").font(.caption) }
            Text(task.content.behavior).font(.callout).lineLimit(3)
            if showQuestions {
                questions(in: task.content)
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
