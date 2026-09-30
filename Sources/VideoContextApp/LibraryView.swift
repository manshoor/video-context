import SwiftUI
import UniformTypeIdentifiers
import VideoContextCore

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var showFileImporter = false
    @State private var showURLImporter = false
    @State private var showNewProject = false
    @State private var requestProject: FeedbackProject?
    @State private var feedbackProject: FeedbackProject?
    @State private var projectName = ""
    @State private var importProjectID: String?
    @State private var moveSource: ProjectSourceReference?
    private var project: FeedbackProject? { model.feedbackProjects.first { $0.id == model.selectedProjectID } }
    private var editing: Bool { model.libraryReadOnlyReason != nil || model.taskDraft?.dirty == true || model.taskDraft?.saving == true || model.documentationDraft?.dirty == true || model.documentationDraft?.saving == true }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<WorkspaceLocation.Root?>(get: { model.workspaceLocation.root }, set: { root in
                if let root { model.requestNavigation(.init(root: root)) }
            })) {
                Section("Workspace") {
                    Label("Inbox", systemImage: "tray").tag(WorkspaceLocation.Root.inbox)
                }
                Section("Projects") {
                    ForEach(model.feedbackProjects) { project in
                        Label(project.name, systemImage: "folder").padding(.vertical, 3)
                            .tag(WorkspaceLocation.Root.project(project.id))
                    }
                    Button("New Project", systemImage: "plus") { projectName = ""; showNewProject = true }.disabled(editing)
                }
            }.listStyle(.sidebar)
                .navigationTitle("Video Context")
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        Button("AI Usage", systemImage: "chart.bar.xaxis") { model.showUsage() }.buttonStyle(.plain)
                        SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.bar)
                }
        } detail: {
            VStack(spacing: 0) {
                notices
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project?.name ?? "Inbox").font(.title2.bold())
                        Text(project == nil ? "Assign older content to a project" : "Your product reference and work requests")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("Project section", selection: Binding(get: { model.workspaceLocation.section }, set: { value in
                        var next = model.workspaceLocation; next.section = value; next.task = nil; next.proposalID = nil
                        model.requestNavigation(next)
                    })) {
                        ForEach(WorkspaceLocation.Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
                }.padding(16)
                Divider()
                if let error = model.workspaceLoadError {
                    ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    Button("Try again") { Task { await model.loadSelection() } }.padding()
                } else if let workspace = model.projectWorkspace {
                    if !workspace.conflicts.isEmpty {
                        HStack {
                            Label("Some linked sources have conflicting project assignments.", systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("Resolve") { moveSource = workspace.conflicts.first }.disabled(model.projectMoveBlocked)
                        }.font(.callout).padding(12).background(.orange.opacity(0.1))
                    }
                    switch model.workspaceLocation.section {
                    case .tasks: ProjectTasksWorkspace(model: model, workspace: workspace) { moveSource = $0 }
                    case .documentation: DocumentationWorkspace(model: model)
                    case .recordings: recordings(workspace)
                    case .feedback:
                        HStack {
                            sourceReturnButton
                            Spacer()
                            if let id = model.selectedFeedbackID {
                                GenerationExclusionControl(model: model, source: .feedback(id))
                                Button("Move to Project", systemImage: "folder") { moveSource = .feedback(id) }.disabled(model.projectMoveBlocked)
                            }
                        }.padding(.trailing, 12)
                        FeedbackLibraryView(model: model, projectID: model.selectedProjectID, embedded: true, allowsUnassigned: model.selectedProjectID == nil)
                    }
                } else {
                    ProgressView("Loading workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 740, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Task", systemImage: "plus") { requestProject = project }
                    .disabled(project == nil || editing).help("Write a request, then generate and review its tasks")
                Button("Add Feedback", systemImage: "text.bubble") { feedbackProject = project }
                    .disabled(project == nil || editing)
                Menu("Add Sources", systemImage: "plus.rectangle.on.folder") {
                    Button("Import Files…") { importProjectID = model.selectedProjectID; showFileImporter = true }
                    Button("Import Link") { importProjectID = model.selectedProjectID; showURLImporter = true }
                }.disabled(project == nil || model.isProcessing || editing)
                    .accessibilityLabel("Add Sources")
                    .help("Import into the selected project")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let projectID = model.selectedProjectID, !model.isProcessing, !editing, !urls.isEmpty else { return false }
            Task { await model.importProjectSources(urls, projectID: projectID) }; return true
        }
        .sheet(item: $model.usagePresentation) { AIUsageView(model: model, scope: $0) }
        .sheet(item: $requestProject) { ProjectRequestSheet(model: model, project: $0) }
        .sheet(item: $feedbackProject) { composerProject in
                FeedbackCreationSheet(recordingTitle: composerProject.name, fixedProject: composerProject.name) { title, _, text, files in
                    Task {
                        if await model.createFeedback(projectID: composerProject.id, title: title, project: composerProject.name, text: text, files: files) {
                            feedbackProject = nil
                            var next = model.workspaceLocation; next.section = .feedback
                            model.requestNavigation(next)
                        }
                    }
                }
        }
        .sheet(item: $moveSource) { ProjectMoveSheet(model: model, source: $0) }
        .sheet(item: $model.taskDeletion) { TaskDeletionSheet(model: model, presentation: $0) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .plainText, .image, .mpeg4Movie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): if let importProjectID { Task { await model.importProjectSources(urls, projectID: importProjectID) } }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showURLImporter) {
            URLImportView { value in
                showURLImporter = false
                if let importProjectID { Task { await model.importOnline(value, projectID: importProjectID) } }
            }
        }
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Project name", text: $projectName)
            Button("Create") { Task { await model.createProject(name: projectName) } }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Save your changes?", isPresented: $model.showUnsavedTaskAlert, titleVisibility: .visible) {
            Button("Save") { Task { await model.resolvePendingNavigation(save: true) } }
            Button("Discard Changes", role: .destructive) { Task { await model.resolvePendingNavigation(save: false) } }
            Button("Cancel", role: .cancel) { model.pendingNavigation = nil; model.pendingSourceTimestamp = nil; model.sourceReturnLocation = nil }
        } message: { Text("Your draft stays open if saving fails.") }
        .alert("Video Context", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .task { await model.loadLibrary(resume: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.appBecameActive() }
    }

    @ViewBuilder private var notices: some View {
        if let reason = model.libraryReadOnlyReason { Label(reason, systemImage: "lock.doc").font(.callout).padding(10).textSelection(.enabled) }
        if model.isUIFixture { Label("Demo library · no API calls", systemImage: "testtube.2").font(.caption).padding(6) }
        if let error = model.usageStorageError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding(8) }
        if model.settingsSaved {
            HStack { Label("Settings saved", systemImage: "checkmark.circle"); Spacer(); Button("Dismiss") { model.settingsSaved = false } }.padding(10).background(.green.opacity(0.08))
        }
        if model.diagnosticsEnabled { Label("Diagnostic logging on", systemImage: "waveform.path.ecg").font(.caption).foregroundStyle(.orange).padding(6) }
        if let activity = model.activity { ProcessingPanel(activity: activity) { model.cancelProcessing() }.padding(12) }
    }
    @ViewBuilder private var sourceReturnButton: some View {
        if let back = model.sourceReturnLocation {
            HStack { Button(back.section == .documentation ? "Back to documentation" : "Back to task", systemImage: "arrow.left") { model.requestNavigation(back); model.sourceReturnLocation = nil }; Spacer() }.padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
    @ViewBuilder private func recordings(_ workspace: ProjectWorkspaceSnapshot) -> some View {
        if let snapshot = model.snapshot, workspace.recordings.contains(where: { $0.id == snapshot.video.id }) {
            HStack {
                Button("All recordings", systemImage: "chevron.left") { var next = model.workspaceLocation; next.recordingID = nil; model.requestNavigation(next) }
                if let back = model.sourceReturnLocation { Button(back.section == .documentation ? "Back to documentation" : "Back to task") { model.requestNavigation(back); model.sourceReturnLocation = nil } }
                Spacer()
                GenerationExclusionControl(model: model, source: .recording(snapshot.video.id))
                Button("Move to Project", systemImage: "folder") { moveSource = .recording(snapshot.video.id) }.disabled(model.projectMoveBlocked)
            }.padding(12)
            VideoWorkspaceView(model: model, snapshot: snapshot)
        } else if workspace.recordings.isEmpty {
            ContentUnavailableView("No recordings", systemImage: "video", description: Text("Add a recording to this project to collect transcript and evidence."))
        } else {
            List(selection: Binding<String?>(get: { model.workspaceLocation.recordingID }, set: { id in
                if let id { model.openProjectSource(.recording(id)) }
            })) {
              ForEach(workspace.recordings) { video in
                HStack {
                    Label { VStack(alignment: .leading, spacing: 5) { Text(video.title).font(.headline); Text(video.status.rawValue).foregroundStyle(.secondary) } } icon: { Image(systemName: "video") }
                    Spacer()
                    Button("Move to Project") { moveSource = .recording(video.id) }.disabled(model.projectMoveBlocked)
                }.padding(.vertical, 6).tag(video.id)
              }
            }.listStyle(.inset)
        }
    }
}
