import SwiftUI
import VideoContextCore

private enum ProjectListSelection: Hashable {
    case task(ProjectTaskReference)
    case proposal(String)
}

struct ProjectTasksWorkspace: View {
    @Bindable var model: AppModel
    let workspace: ProjectWorkspaceSnapshot
    let moveSource: (ProjectSourceReference) -> Void
    @State private var search = ""
    @State private var filter: ProjectTaskFilter = .all
    @State private var archived = false
    @State private var selected: Set<ProjectTaskReference> = []
    @State private var showHandoff = false
    private var listSelection: Binding<ProjectListSelection?> {
        Binding(get: {
            if let task = model.workspaceLocation.task { return .task(task) }
            if let proposal = model.workspaceLocation.proposalID { return .proposal(proposal) }
            return nil
        }, set: { selection in
            switch selection {
            case .task(let task): model.selectProjectTask(task)
            case .proposal(let id):
                var next = model.workspaceLocation; next.task = nil; next.proposalID = id
                model.requestNavigation(next)
            case nil: break
            }
        })
    }
    private var tasks: [ProjectTaskItem] {
        workspace.tasks.filter { $0.archived == archived && filter.includes($0) && (search.isEmpty || $0.content.title.localizedCaseInsensitiveContains(search)) }
    }
    private var sources: [ProjectSourceReference] {
        var seen = Set<ProjectSourceReference>()
        return tasks.map(\.reference.source).filter { seen.insert($0).inserted }
    }
    private var proposals: [ProjectProposalItem] {
        guard !archived, filter != .ready else { return [] }
        return workspace.proposals.filter {
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) &&
            (filter != .questions || $0.content?.questions.contains(where: { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true)
        }
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    TextField("Search task titles", text: $search).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Task filter", selection: $filter) { ForEach(ProjectTaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
                        Toggle("Archived", isOn: $archived).toggleStyle(.button)
                    }
                    HStack {
                        Text(selected.isEmpty ? "\(tasks.count) tasks" : "\(selected.count) selected").foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete selected…", systemImage: "trash", role: .destructive) { Task { await model.requestTaskDeletion(selected) } }
                            .labelStyle(.iconOnly).disabled(selected.isEmpty || model.taskDraft?.saving == true)
                        Button("Copy for AI", systemImage: "doc.on.clipboard") { showHandoff = true }
                            .disabled(selected.isEmpty || archived || workspace.project == nil || model.taskDraft?.dirty == true)
                            .help("Preview a handoff for the selected tasks")
                    }.font(.callout)
                }.padding(12)
                Divider()
                if !model.projectAnalysisWarnings.isEmpty {
                    DisclosureGroup("Reference sources need attention") {
                        ForEach(model.projectAnalysisWarnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }.padding(10)
                }
                if let projectID = workspace.project?.id {
                    DocumentationRecoveryControl(model: model, projectID: projectID)
                }
                List(selection: listSelection) {
                    if !proposals.isEmpty {
                        Section("Proposed changes") {
                            ForEach(proposals) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(item.title, systemImage: item.outdated ? "clock.badge.exclamationmark" : "sparkles")
                                    Text(item.outdated ? "Outdated proposal · review source" : item.sourceTitle).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4).tag(ProjectListSelection.proposal(item.id))
                            }
                        }
                    }
                    ForEach(sources) { source in
                        Section {
                            ForEach(tasks.filter { $0.reference.source == source }) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("Select \(item.content.title)", isOn: Binding(get: { selected.contains(item.reference) }, set: { if $0 { selected.insert(item.reference) } else { selected.remove(item.reference) } }))
                                        .labelsHidden()
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.content.title).font(.headline).lineLimit(2)
                                        Label(item.state, systemImage: item.canImplement ? "checkmark.seal" : "doc.text.magnifyingglass").font(.caption)
                                        HStack { Text(item.origin); if item.openQuestions > 0 { Label("\(item.openQuestions)", systemImage: "questionmark.bubble") } }.font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.vertical, 6)
                                    .tag(ProjectListSelection.task(item.reference))
                                    .contextMenu {
                                        Button("Delete Task…", systemImage: "trash", role: .destructive) { Task { await model.requestTaskDeletion([item.reference]) } }
                                        Button("Move source group to Project") { moveSource(source) }.disabled(model.projectMoveBlocked)
                                    }
                            }
                        } header: {
                            HStack { Text(tasks.first { $0.reference.source == source }?.sourceTitle ?? "Source"); Spacer(); Button { moveSource(source) } label: { Label("Move source group", systemImage: "folder") }.labelStyle(.iconOnly).disabled(model.projectMoveBlocked) }
                        }
                    }
                }.listStyle(.inset)
                    .overlay {
                        if tasks.isEmpty && proposals.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "No matching tasks" : "No results", systemImage: "checklist", description: Text(workspace.project == nil ? "Unassigned tasks appear here until their sources belong to a project." : "Use New Task to write a request, or generate tasks from this project's sources."))
                        }
                    }
            }.frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
            Group {
                if let proposalID = model.workspaceLocation.proposalID, let proposal = workspace.proposals.first(where: { $0.id == proposalID }) {
                    ProjectProposalDetail(model: model, item: proposal)
                } else if let draft = model.taskDraft {
                    ProjectTaskDetail(model: model, draft: draft).id(draft.reference)
                } else {
                    ContentUnavailableView("Select a task", systemImage: "doc.text", description: Text("Review requirements, acceptance checks, questions, and source evidence here."))
                }
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showHandoff) { ProjectHandoffSheet(model: model, snapshot: workspace, selected: selected) }
        .onChange(of: archived) { _, _ in selected = [] }
        .onChange(of: workspace.project?.id) { _, _ in selected = []; search = ""; filter = .all; archived = false }
        .onChange(of: workspace.tasks.map { "\($0.id.id):\($0.revision):\($0.archived)" }) { _, _ in
            selected.formIntersection(Set(workspace.tasks.filter { $0.archived == archived }.map(\.reference)))
        }
    }
}

private struct ProjectProposalDetail: View {
    @Bindable var model: AppModel
    let item: ProjectProposalItem
    @State private var busy = false
    private var current: ProjectTaskItem? {
        let taskID = item.recording?.taskID ?? item.feedback?.taskID
        return model.projectWorkspace?.tasks.first { $0.reference.source == item.source && $0.taskID == taskID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Proposed change").font(.title2.bold())
            Text(item.sourceTitle).foregroundStyle(.secondary)
            if item.outdated { Label("This proposal is outdated. Generate again from the source before applying it.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let current {
                        Text("Current task").font(.headline)
                        TaskContentSummary(content: current.content)
                        Divider()
                    }
                    Text("Proposed task").font(.headline)
                    if let content = item.content { TaskContentSummary(content: content) }
                    else { Text("Archive this task. Its ID, requirements, and history remain saved.") }
                    if let run = item.recording?.generationRunID {
                        Button("View generation usage") { model.showUsage(runID: run) }
                    }
                }
            }
            HStack {
                Button("Open source") { model.openProjectSource(item.source) }
                Spacer()
                Button("Reject") { resolve(false) }.disabled(busy)
                if let proposal = item.recording, proposal.kind != .addition {
                    Button("Keep wording") { resolve(true, keepWording: true) }.disabled(busy || item.outdated)
                }
                Button("Apply change") { resolve(true) }.buttonStyle(.borderedProminent).disabled(busy || item.outdated)
            }
        }.padding(20)
    }
    private func resolve(_ apply: Bool, keepWording: Bool = false) {
        busy = true
        Task { await model.resolveProjectProposal(item, apply: apply, keepWording: keepWording); busy = false }
    }
}
