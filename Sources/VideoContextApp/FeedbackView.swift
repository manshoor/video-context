import SwiftUI
import UniformTypeIdentifiers
import VideoContextCore

struct FeedbackCreationSheet: View {
    let recordingTitle: String
    let fixedProject: String?
    let create: (String, String, String, [URL]) -> Void
    init(recordingTitle: String, fixedProject: String? = nil, create: @escaping (String, String, String, [URL]) -> Void) {
        self.recordingTitle = recordingTitle; self.fixedProject = fixedProject; self.create = create
    }
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = ""
    @State private var feedback = ""
    @State private var attachments: [URL] = []
    @State private var showFilePicker = false
    @State private var fileError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Feedback").font(.title2.bold())
            Text("For: \(recordingTitle)").font(.caption).foregroundStyle(.secondary)
            TextField("Batch title", text: $title)
            TextField("Project (optional)", text: $project).disabled(fixedProject != nil)
            Text("Paste QA and manager comments with their links. Keep each comment on its own line.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $feedback).frame(minHeight: 260).border(.quaternary)
            HStack {
                Button("Add images or MP4", systemImage: "paperclip") { showFilePicker = true }
                Text("PNG, JPEG, WebP, or MP4 · assign each file after import")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !attachments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(attachments, id: \.absoluteString) { file in
                            HStack {
                                Image(systemName: file.pathExtension.lowercased() == "mp4" ? "film" : "photo")
                                Text(file.lastPathComponent).lineLimit(1)
                                Spacer()
                                Button("Remove", systemImage: "xmark") {
                                    attachments.removeAll { $0 == file }
                                }.labelStyle(.iconOnly)
                            }
                        }
                    }
                }.frame(maxHeight: 130)
            }
            if let fileError { Text(fileError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Feedback") { create(title, project, feedback, attachments) }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 660)
            .task { if let fixedProject { project = fixedProject } }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image, .mpeg4Movie], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let allowed = ["png", "jpg", "jpeg", "webp", "mp4"]
                    let unsupported = urls.filter { !allowed.contains($0.pathExtension.lowercased()) }
                    fileError = unsupported.isEmpty ? nil : "Use PNG, JPEG, WebP, or MP4 files."
                    for url in urls where allowed.contains(url.pathExtension.lowercased()) && !attachments.contains(url) {
                        attachments.append(url)
                    }
                case .failure(let error): fileError = error.localizedDescription
                }
            }
    }
}

struct ProjectFeedbackPane: View {
    @Bindable var model: AppModel
    let project: FeedbackProject
    @State private var showNew = false
    @State private var showReview = false
    private var batches: [FeedbackBatch] {
        model.feedbackScopeProjectID == project.id ? model.feedbackBatches : []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(project.name).font(.title2.bold())
                Spacer()
                Button("New Feedback", systemImage: "plus") { showNew = true }
            }
            Text("Project feedback and Cursor tasks").font(.caption).foregroundStyle(.secondary)
            if batches.isEmpty {
                ContentUnavailableView("No project feedback", systemImage: "text.bubble",
                                       description: Text("Paste a QA issue list or a separate request for this project."))
            }
            List(batches) { batch in
                Button {
                    Task { await model.selectFeedback(batch.id, projectID: project.id); showReview = true }
                } label: {
                    VStack(alignment: .leading) {
                        Text(batch.title).font(.headline)
                        Text("\(batch.comments.count) issues · \(batch.sources.count) sources · revision \(batch.revision)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }.padding(16)
            .task(id: project.id) { await model.loadFeedback(forProject: project.id) }
            .sheet(isPresented: $showNew) {
                FeedbackCreationSheet(recordingTitle: project.name, fixedProject: project.name) { title, _, text, files in
                    Task {
                        if await model.createFeedback(projectID: project.id, title: title, project: project.name, text: text, files: files) {
                            showNew = false; showReview = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showReview) { FeedbackLibraryView(model: model, projectID: project.id) }
    }
}

struct FeedbackPane: View {
    @Bindable var model: AppModel
    let video: VideoRecord
    @State private var showNew = false
    @State private var showReview = false
    private var batches: [FeedbackBatch] {
        model.feedbackScopeVideoID == video.id ? model.feedbackBatches : []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feedback for this recording").font(.headline)
                Spacer()
                Button("New Feedback", systemImage: "plus") { showNew = true }
                    .help("Paste QA or manager feedback for this recording")
            }
            Text(video.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !model.unassignedFeedbackBatches.isEmpty {
                Menu("Attach older feedback") {
                    ForEach(model.unassignedFeedbackBatches) { batch in
                        Button(batch.title) { Task { await model.attachUnassignedFeedback(batch, to: video.id) } }
                    }
                }.help("Attach feedback saved before batches belonged to recordings")
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if batches.isEmpty {
                        ContentUnavailableView("No feedback for this recording", systemImage: "text.bubble",
                                               description: Text("Paste QA or manager comments here to create Cursor tasks."))
                    }
                    ForEach(batches) { batch in
                        Button {
                            Task { await model.selectFeedback(batch.id, videoID: video.id); showReview = true }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(batch.title).font(.headline)
                                Text("\(batch.comments.count) comments · \(batch.sources.count) sources · revision \(batch.revision)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !batch.project.isEmpty { Text(batch.project).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(12)
            .task(id: video.id) { await model.loadFeedback(for: video.id) }
            .sheet(isPresented: $showNew) {
                FeedbackCreationSheet(recordingTitle: video.title) { title, project, text, files in
                    Task {
                        if await model.createFeedback(videoID: video.id, title: title, project: project, text: text, files: files) {
                            showNew = false; showReview = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showReview) { FeedbackLibraryView(model: model, videoID: video.id) }
    }
}

struct FeedbackLibraryView: View {
    @Bindable var model: AppModel
    let videoID: String?
    let projectID: String?
    let embedded: Bool
    let allowsUnassigned: Bool
    init(model: AppModel, videoID: String? = nil, projectID: String? = nil, embedded: Bool = false, allowsUnassigned: Bool = false) {
        self.model = model; self.videoID = videoID; self.projectID = projectID; self.embedded = embedded; self.allowsUnassigned = allowsUnassigned
    }
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var showNew = false
    @State private var editingBatch: FeedbackBatch?
    @State private var editingTask: FeedbackTask?
    @State private var proposal: FeedbackTaskProposal?
    @State private var showHandoff = false
    @State private var replacementSourceID: String?
    @State private var attachmentCommentID: String?
    @State private var showFilePicker = false
    @State private var usage: UsagePresentation?
    @State private var showRemoved = false
    private var batches: [FeedbackBatch] {
        scopeMatches ? model.feedbackBatches : []
    }
    private var scopeMatches: Bool {
        if let projectID { return model.feedbackScopeProjectID == projectID }
        if let videoID { return model.feedbackScopeVideoID == videoID }
        return allowsUnassigned && model.selectedProjectID == nil
    }
    private var scopeTitle: String {
        if let projectID { return model.feedbackProjects.first(where: { $0.id == projectID })?.name ?? projectID }
        if let videoID { return model.videos.first(where: { $0.id == videoID })?.title ?? videoID }
        return allowsUnassigned ? "Inbox" : "Feedback"
    }
    private var snapshot: FeedbackSnapshot? {
        guard scopeMatches,
              model.feedbackSnapshot?.batch.id == model.selectedFeedbackID,
              (projectID.map { model.feedbackSnapshot?.batch.projectID == $0 } ??
               videoID.map { model.feedbackSnapshot?.batch.videoID == $0 } ?? (allowsUnassigned && model.feedbackSnapshot?.batch.projectID == nil)) else { return nil }
        return model.feedbackSnapshot
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Feedback").font(.title2.bold())
                    Spacer()
                    Button("New Feedback", systemImage: "plus") { showNew = true }.labelStyle(.iconOnly).disabled(allowsUnassigned)
                }.padding(.horizontal)
                Text(scopeTitle)
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if let videoID, !model.unassignedFeedbackBatches.isEmpty {
                    Menu("Attach older feedback") {
                        ForEach(model.unassignedFeedbackBatches) { batch in
                            Button(batch.title) { Task { await model.attachUnassignedFeedback(batch, to: videoID) } }
                        }
                    }.padding(.horizontal)
                }
                List(selection: Binding<String?>(get: { model.selectedFeedbackID }, set: { id in
                    guard let id else { return }
                    selected = []; showRemoved = false
                    var next = model.workspaceLocation; next.feedbackID = id; next.task = nil
                    model.requestNavigation(next)
                })) {
                    ForEach(batches) { batch in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.title).font(.headline)
                            Text(batch.project.isEmpty ? "No project" : batch.project).font(.caption).foregroundStyle(.secondary)
                            Text("\(batch.comments.count) comments · \(batch.sources.count) sources").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).tag(batch.id)
                    }
                }
            }.navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    if let batch = snapshot?.batch {
                        VStack(alignment: .leading) {
                            Text(batch.title).font(.title2.bold())
                            DisclosureGroup("Source details") {
                                Text("\(batch.id) · revision \(batch.revision)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        HStack {
                        Button("Add Media", systemImage: "paperclip") {
                            replacementSourceID = nil; attachmentCommentID = nil; showFilePicker = true
                        }.help("Import images or MP4 files, then assign each to an issue or batch-wide context")
                            .disabled(model.feedbackBusy)
                        Button("Edit Feedback", systemImage: "pencil") { editingBatch = batch }
                        Button("Suggest issue links", systemImage: "sparkles.rectangle.stack") {
                            Task { await model.prepareFeedback(batchID: batch.id) }
                        }.disabled(model.feedbackBusy)
                        Button("Generate tasks", systemImage: "sparkles") { model.generateFeedbackTasks() }
                            .disabled(model.feedbackBusy || !batch.unassignedSourceIDs.isEmpty || batch.projectID == nil)
                        if model.feedbackBusy {
                            Button("Cancel generation") { model.cancelFeedbackGeneration() }
                                .disabled(model.feedbackGenerationTask == nil)
                        }
                        }
                    } else { Text("Select a feedback batch").font(.title2) }
                    if !embedded { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
                }
                if let progress = model.feedbackProgress { Text(progress).font(.caption).foregroundStyle(.secondary) }
                if let snapshot {
                    if embedded {
                        ScrollViewReader { proxy in
                            ScrollView { feedbackColumn(snapshot.batch) }
                                .onChange(of: model.focusedFeedbackCommentID, initial: true) { _, id in
                                    if let id { proxy.scrollTo(id, anchor: .top) }
                                }
                        }
                        HStack {
                            Text("\(snapshot.tasks.filter { !$0.archived }.count) active tasks from this source").foregroundStyle(.secondary)
                            Spacer()
                            Button("View project tasks") {
                                var next = model.workspaceLocation; next.section = .tasks; next.task = nil
                                model.requestNavigation(next)
                            }
                        }
                    } else {
                        HSplitView {
                            ScrollView { feedbackColumn(snapshot.batch) }.frame(minWidth: 310, idealWidth: 450)
                            ScrollView { taskColumn(snapshot) }.frame(minWidth: 450, idealWidth: 620)
                        }
                    }
                }
            }.padding(16)
        }
        .frame(minWidth: embedded ? 0 : 1050, idealWidth: embedded ? nil : 1200, minHeight: embedded ? 0 : 670, idealHeight: embedded ? nil : 800)
        .task {
            if let projectID { await model.loadFeedback(forProject: projectID) }
            else if let videoID { await model.loadFeedback(for: videoID) }
        }
        .sheet(isPresented: $showNew) {
            FeedbackCreationSheet(recordingTitle: scopeTitle,
                                  fixedProject: projectID.flatMap { id in model.feedbackProjects.first(where: { $0.id == id })?.name }) { title, project, text, files in
                Task { if await model.createFeedback(videoID: videoID, projectID: projectID, title: title, project: project, text: text, files: files) { showNew = false; selected = [] } }
            }
        }
        .sheet(item: $editingBatch) { batch in
            FeedbackBatchEditSheet(model: model, initial: batch)
                .onAppear { model.editingFeedbackIDs.insert(batch.id) }
                .onDisappear { model.editingFeedbackIDs.remove(batch.id) }
        }
        .sheet(item: $editingTask) { task in
            if let snapshot { FeedbackTaskEditSheet(model: model, batch: snapshot.batch, initial: task) }
        }
        .sheet(item: $proposal) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("Proposed task change").font(.title2.bold())
                if let current = snapshot?.tasks.first(where: { $0.id == item.taskID }) {
                    HSplitView {
                        ScrollView { TaskContentSummary(content: current.content).padding() }
                        ScrollView { TaskContentSummary(content: item.content).padding() }
                    }
                }
                HStack {
                    Button("Reject") { Task { await model.resolveFeedbackProposal(item, apply: false); proposal = nil } }
                    Spacer()
                    Button("Apply change") { Task { await model.resolveFeedbackProposal(item, apply: true); proposal = nil } }.buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(width: 900, height: 600)
        }
        .sheet(isPresented: $showHandoff) {
            if let snapshot { FeedbackHandoffSheet(model: model, snapshot: snapshot, selected: selected) }
        }
        .sheet(item: $usage) { AIUsageView(model: model, scope: $0) }
        .onChange(of: snapshot?.tasks.map { "\($0.id):\($0.revision):\($0.archived)" }.joined(separator: "|")) { _, _ in
            selected = FeedbackTaskVisibility.activeSelection(selected, tasks: snapshot?.tasks ?? [])
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image, .mpeg4Movie], allowsMultipleSelection: true) { result in
            guard let batchID = snapshot?.batch.id else { return }
            switch result {
            case .success(let urls):
                if let id = replacementSourceID, let url = urls.first {
                    Task { await model.attachFeedbackFile(url, batchID: batchID, sourceID: id) }
                } else if !urls.isEmpty {
                    let commentID = attachmentCommentID
                    Task { await model.addFeedbackAttachments(urls, batchID: batchID, commentID: commentID) }
                }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
            replacementSourceID = nil; attachmentCommentID = nil
        }
        .alert("Video Context", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func feedbackColumn(_ batch: FeedbackBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original feedback and evidence").font(.headline)
            Text("Assign new files to an issue or mark them as batch-wide context before generating tasks.")
                .font(.caption).foregroundStyle(.secondary)
            if !batch.unassignedSourceIDs.isEmpty {
                Text("Unassigned evidence").font(.headline).foregroundStyle(.orange)
                ForEach(batch.unassignedSourceIDs, id: \.self) { id in
                    if let source = batch.sources.first(where: { $0.id == id }) {
                        sourceCard(source, batchID: batch.id)
                        Menu("Assign \(source.filename ?? "evidence")") {
                            ForEach(batch.comments.filter { !$0.isShared }) { issue in
                                Button(issue.text.prefix(55).description) {
                                    Task { await model.assignFeedbackSource(batchID: batch.id, sourceID: id, issueID: issue.id) }
                                }
                            }
                            Button("Batch-wide context") { Task { await model.assignFeedbackSource(batchID: batch.id, sourceID: id, issueID: nil) } }
                        }
                    }
                }
            }
            if let focused = model.workspaceLocation.feedbackCommentID {
                HStack {
                    Text(batch.comments.contains(where: { $0.id == focused }) ? "Cited comment" : "This comment is only available in its cited historical revision.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show all feedback") { var next = model.workspaceLocation; next.feedbackCommentID = nil; model.requestNavigation(next) }
                }
            }
            ForEach(batch.comments.filter { model.workspaceLocation.feedbackCommentID == nil || $0.id == model.workspaceLocation.feedbackCommentID }) { comment in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        TaskOriginBadge(origin: comment.kind == .request ? .request : .feedback)
                        if comment.reviewer != .unspecified { Text(comment.reviewer.rawValue.capitalized).font(.caption.bold()) }
                        if !comment.lineNumbers.isEmpty { Text("lines \(comment.lineNumbers.map(String.init).joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if comment.isShared { Text("Shared instruction").font(.caption2).foregroundStyle(.secondary) }
                    Text(comment.text).textSelection(.enabled)
                    if let suggestion = batch.preparationSuggestions.first(where: { $0.issueID == comment.id }),
                       suggestion.joinWithPrevious || suggestion.sharedInstruction || !suggestion.sourceIDs.isEmpty || !suggestion.duplicateOfIssueID.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Luna suggestion").font(.caption.bold())
                            if suggestion.joinWithPrevious { Text("This line may continue the previous issue.") }
                            if suggestion.sharedInstruction { Text("This may be a shared instruction.") }
                            if !suggestion.sourceIDs.isEmpty { Text("Suggested evidence: \(suggestion.sourceIDs.joined(separator: ", "))") }
                            if !suggestion.duplicateOfIssueID.isEmpty { Text("Possible duplicate of \(suggestion.duplicateOfIssueID); review before merging.") }
                            Button("Apply grouping and evidence suggestion") { Task { await model.applyFeedbackSuggestion(batchID: batch.id, issueID: comment.id) } }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(comment.sourceIDs, id: \.self) { id in
                        if let source = batch.sources.first(where: { $0.id == id }) { sourceCard(source, batchID: batch.id) }
                    }
                    Button("Attach images or MP4") { replacementSourceID = nil; attachmentCommentID = comment.id; showFilePicker = true }
                        .disabled(model.feedbackBusy)
                }.id(comment.id).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
    }
    private func sourceCard(_ source: FeedbackSource, batchID: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(source.filename ?? source.url ?? "Attached recording").font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
            if source.filename != nil, let url = source.url { Text(url).font(.caption2).textSelection(.enabled).lineLimit(2) }
            Text("\(source.kind.rawValue) · \(source.presentationStatus)").font(.caption)
            if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let jam = source.jam {
                ForEach(JamEvidenceComponent.allCases, id: \.self) { component in
                    if let availability = jam.availability.first(where: { $0.component == component }) {
                        Text("\(component.rawValue): \(availability.status.rawValue) — \(availability.message)")
                            .font(.caption2).textSelection(.enabled)
                    }
                }
                if let attempt = jam.lastAttemptAt {
                    Text("Last retry: \(attempt.formatted())").font(.caption2)
                    ForEach(jam.lastAttemptAvailability ?? [], id: \.component) { availability in
                        if availability.status != .available {
                            Text("Retry \(availability.component.rawValue): \(availability.message)")
                                .font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
            }
            if source.kind == .image, let path = source.localPath, let url = model.paths?.absoluteURL(relativePath: path), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
            }
            if !source.ocrText.isEmpty { Text(source.ocrText).font(.caption).lineLimit(5).textSelection(.enabled) }
            HStack {
                if source.kind == .jam, source.url != nil {
                    Button("Retry evidence") { Task { await model.retryJamEvidence(batchID: batchID, sourceID: source.id) } }
                } else if source.status == .failed, source.url != nil {
                    Button("Retry") { Task { await model.processFeedbackSources(batchID: batchID, only: source.id) } }
                }
                Button("Replace file") { replacementSourceID = source.id; showFilePicker = true }
            }.disabled(model.feedbackBusy)
        }.padding(8).background(.background, in: .rect(cornerRadius: 6))
    }

    private func taskColumn(_ snapshot: FeedbackSnapshot) -> some View {
        let visibleTasks = FeedbackTaskVisibility.visible(snapshot.tasks, showRemoved: showRemoved)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(showRemoved ? "Archived tasks" : "Tasks").font(.headline)
                Spacer()
                Button(showRemoved ? "Show active" : "Show archived") {
                    showRemoved.toggle(); selected = []
                }
                if !showRemoved {
                    Button("Select all") { selected = Set(visibleTasks.map(\.id)) }
                    Menu("Selected tasks") {
                    Button("Archive selected") {
                        let tasks = visibleTasks.filter { selected.contains($0.id) }
                        Task {
                            if await model.setFeedbackTasksArchived(tasks, archived: true, batch: snapshot.batch) {
                                selected.subtract(tasks.map(\.id))
                            }
                        }
                    }.disabled(selected.isEmpty || model.feedbackBusy)
                    Button("Delete selected…", role: .destructive) {
                        Task { await model.requestTaskDeletion(Set(selected.map { .feedback(batchID: snapshot.batch.id, taskID: $0) })) }
                    }.disabled(selected.isEmpty || model.feedbackBusy)
                    Button("Approve selected") {
                        let tasks = visibleTasks.filter { selected.contains($0.id) }
                        Task { _ = await model.approveFeedback(tasks, batchRevision: snapshot.batch.revision, batchID: snapshot.batch.id) }
                    }.disabled(selected.isEmpty || model.feedbackBusy || visibleTasks.filter { selected.contains($0.id) }.contains(where: { $0.content.blockers > 0 || $0.sourceRevision != snapshot.batch.revision }))
                    }.disabled(selected.isEmpty || model.feedbackBusy)
                    Button("Copy for AI", systemImage: "doc.on.clipboard") { showHandoff = true }
                        .disabled(selected.isEmpty || model.feedbackBusy)
                        .buttonStyle(.borderedProminent)
                }
            }
            if visibleTasks.isEmpty && (showRemoved || snapshot.proposals.isEmpty) {
                ContentUnavailableView(showRemoved ? "No archived tasks" : "No tasks yet", systemImage: "checklist",
                    description: Text(showRemoved ? "Archived tasks can be restored here." : "Generate tasks from this feedback, then review them together."))
            }
            if !showRemoved {
                ForEach(snapshot.proposals) { item in
                    Button("Review proposed change: \(item.content.title)") { proposal = item }
                        .buttonStyle(.bordered)
                }
            }
            ForEach(visibleTasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if task.archived {
                            Text(task.content.title).font(.headline)
                        } else {
                            Toggle(task.content.title, isOn: Binding(get: { selected.contains(task.id) }, set: { if $0 { selected.insert(task.id) } else { selected.remove(task.id) } }))
                                .font(.headline)
                        }
                        Spacer()
                        Button("Edit", systemImage: "pencil") { model.selectProjectTask(.feedback(batchID: snapshot.batch.id, taskID: task.id)) }.labelStyle(.iconOnly)
                    }
                    Text("\(task.canImplement(in: snapshot.batch) ? "Approved" : "Draft") · r\(task.revision) · \(task.content.checks.count) checks · \(task.content.blockers) blockers")
                        .font(.caption).foregroundStyle(.secondary)
                    TaskOriginBadge(origin: snapshot.batch.comments.first(where: { $0.id == task.issueID })?.kind == .request ? .request : .feedback)
                    if let runID = task.generationRunID {
                        Button("View generation usage") { usage = .init(videoID: nil, runID: runID) }.font(.caption)
                    }
                    Text(task.content.behavior).lineLimit(3)
                    HStack {
                        if task.archived {
                            Button("Restore") {
                                Task { _ = await model.setFeedbackTasksArchived([task], archived: false, batch: snapshot.batch) }
                            }
                        } else {
                            Button("Consolidate task") {
                                Task {
                                    if let change = await model.consolidateFeedbackTask(task, batch: snapshot.batch) {
                                        proposal = change
                                    }
                                }
                            }
                            Button("Archive task") {
                                Task {
                                    if await model.setFeedbackTasksArchived([task], archived: true, batch: snapshot.batch) {
                                        selected.remove(task.id)
                                    }
                                }
                            }
                        }
                    }.disabled(model.feedbackBusy)
                    Button("Delete Task…", role: .destructive) { Task { await model.requestTaskDeletion([.feedback(batchID: snapshot.batch.id, taskID: task.id)]) } }
                    if task.sourceRevision != snapshot.batch.revision { Text("Feedback changed; regenerate or reconcile before approval.").font(.caption).foregroundStyle(.orange) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                    .contextMenu { Button("Delete Task…", role: .destructive) { Task { await model.requestTaskDeletion([.feedback(batchID: snapshot.batch.id, taskID: task.id)]) } } }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
    }
}

private struct FeedbackBatchEditSheet: View {
    @Bindable var model: AppModel
    let initial: FeedbackBatch
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FeedbackBatch
    @State private var saving = false
    @State private var parsedRawText: String
    init(model: AppModel, initial: FeedbackBatch) {
        self.model = model; self.initial = initial
        _draft = State(initialValue: initial)
        _parsedRawText = State(initialValue: initial.rawText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit feedback and source links").font(.title2.bold())
            TextField("Batch title", text: $draft.title)
            TextField("Project", text: $draft.project).disabled(draft.projectID != nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Original pasted text").font(.headline)
                    TextEditor(text: $draft.rawText).frame(height: 170).border(.quaternary)
                    if draft.rawText != parsedRawText {
                        Button("Reparse edited text and links") { reparse() }
                            .help("Refresh comments and links from the edited text before saving")
                    }
                    ForEach($draft.comments) { $comment in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Comment", text: $comment.text, axis: .vertical)
                            Picker("Reviewer", selection: $comment.reviewer) {
                                ForEach(FeedbackReviewer.allCases, id: \.self) { reviewer in
                                    Text(reviewer == .unspecified ? "Unspecified" : reviewer.rawValue.capitalized).tag(reviewer)
                                }
                            }.pickerStyle(.segmented)
                            Picker("Source type", selection: $comment.kind) {
                                Text("Feedback").tag(FeedbackIssueKind.feedback)
                                Text("Separate request").tag(FeedbackIssueKind.request)
                            }.pickerStyle(.segmented)
                            Toggle("Apply to all generated tasks", isOn: $comment.isShared)
                            if comment.isShared {
                                Text("Applied to: \(comment.sharedTargetIDs.isEmpty ? "All issues" : "Selected issues")").font(.caption)
                                ForEach(draft.comments.filter { $0.id != comment.id && !$0.isShared }) { issue in
                                    Toggle(issue.text.prefix(55).description, isOn: Binding(
                                        get: { comment.sharedTargetIDs.isEmpty || comment.sharedTargetIDs.contains(issue.id) },
                                        set: { enabled in
                                            if comment.sharedTargetIDs.isEmpty { comment.sharedTargetIDs = draft.comments.filter { $0.id != comment.id && !$0.isShared }.map(\.id) }
                                            if enabled && !comment.sharedTargetIDs.contains(issue.id) { comment.sharedTargetIDs.append(issue.id) }
                                            if !enabled {
                                                comment.sharedTargetIDs.removeAll { $0 == issue.id }
                                                if comment.sharedTargetIDs.isEmpty { comment.isShared = false }
                                            }
                                        }))
                                }
                            }
                            Text("Linked evidence").font(.caption.bold())
                            ForEach(draft.sources) { source in
                Toggle(source.filename ?? source.url ?? source.recordingID ?? source.id,
                                       isOn: Binding(get: { comment.sourceIDs.contains(source.id) }, set: { enabled in
                                           if enabled { comment.sourceIDs.append(source.id) }
                                           else { comment.sourceIDs.removeAll { $0 == source.id } }
                                       })).font(.caption)
                            }
                            Menu("Link ready recording") {
                                ForEach(model.videos.filter { $0.status == .ready && $0.projectID == draft.projectID }) { video in
                                    Button(video.title) {
                                        let source = FeedbackSource(kind: .recording, status: .ready, recordingID: video.id)
                                        draft.sources.append(source); comment.sourceIDs.append(source.id)
                                    }
                                }
                            }
                        }.padding(10).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save changes") {
                    saving = true
                    Task { if await model.saveFeedbackBatch(draft, expectedRevision: initial.revision) { dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).disabled(saving || draft == initial || draft.title.isEmpty || draft.comments.isEmpty || draft.rawText != parsedRawText)
            }
        }.padding(20).frame(width: 760, height: 710)
    }
    private func reparse() {
        let previousComments = draft.comments
        let previousSources = draft.sources
        let (comments, sources) = FeedbackBatch.parse(draft.rawText)
        let mapped: [FeedbackSource] = sources.map { candidate in
            previousSources.first(where: { $0.url == candidate.url }) ?? candidate
        }
        let attachedSources = previousSources.filter { $0.url == nil }
        let attachedIDs = Set(attachedSources.map(\.id))
        draft.comments = comments.enumerated().map { index, item in
            let old = previousComments.first(where: { $0.text == item.text })
                ?? (index < previousComments.count ? previousComments[index] : nil)
            var value = old ?? item
            value.text = item.text
            value.lineNumbers = item.lineNumbers
            let linkedIDs: [String] = item.sourceIDs.compactMap { candidateID -> String? in
                guard let candidate = sources.first(where: { $0.id == candidateID }) else { return nil }
                return mapped.first(where: { $0.url == candidate.url })?.id
            }
            value.sourceIDs = Array(Set(linkedIDs + (old?.sourceIDs.filter { attachedIDs.contains($0) } ?? []))).sorted()
            return value
        }
        draft.sources = mapped + attachedSources
        parsedRawText = draft.rawText
    }
}

private struct FeedbackTaskEditSheet: View {
    @Bindable var model: AppModel
    let batch: FeedbackBatch
    let initial: FeedbackTask
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FeedbackTask
    @State private var annotating: EvidenceItem?
    @State private var saving = false
    init(model: AppModel, batch: FeedbackBatch, initial: FeedbackTask) {
        self.model = model; self.batch = batch; self.initial = initial
        _draft = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review feedback task").font(.title2.bold())
            Text("\(draft.id) · revision \(initial.revision)").font(.caption.monospaced()).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $draft.content.title)
                    Text("Requested behavior").bold()
                    TextEditor(text: $draft.content.behavior).frame(height: 75).border(.quaternary)
                    statements("Requirements", items: $draft.content.requirements)
                    statements("Acceptance checks", items: $draft.content.checks)
                    Text("Questions and clarifications").bold()
                    ForEach($draft.content.questions) { $question in
                        VStack(alignment: .leading, spacing: 5) {
                            TextField("Question", text: $question.question, axis: .vertical)
                            TextField("Answer", text: $question.answer, axis: .vertical)
                            Toggle("Blocking", isOn: $question.isBlocking)
                            if !question.isBlocking { TextField("Why this is nonblocking", text: $question.nonBlockingReason) }
                            Button("Remove question") { draft.content.questions.removeAll { $0.id == question.id } }
                        }.padding(8).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                    }
                    Button("Add question") { draft.content.questions.append(.init(question: "")) }
                    Text("Evidence").bold()
                    ForEach(batch.comments) { comment in sourceToggle(comment.id, label: comment.text) }
                    ForEach(batch.sources) { source in
                        HStack {
                            sourceToggle(source.id, label: source.url ?? source.recordingID ?? source.id)
                            if source.kind == .image, let path = source.localPath {
                                Button("Annotate") {
                                    annotating = EvidenceItem(id: source.id, videoID: batch.id, timestamp: 0,
                                                              imageRelativePath: path, origin: .manual)
                                }
                            }
                        }
                    }
                    Toggle("Archived", isOn: $draft.archived)
                }.textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Approval happens from the batch review screen after saving.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    saving = true
                    Task {
                        if await model.saveFeedbackTask(draft, expectedRevision: initial.revision, expectedBatchRevision: batch.revision) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || draft == initial || draft.content.title.isEmpty)
            }
        }.padding(20).frame(width: 790, height: 760)
        .sheet(item: $annotating) { evidence in
            TaskAnnotationEditor(evidence: evidence, imageURL: model.paths?.absoluteURL(relativePath: evidence.imageRelativePath),
                                 initial: draft.content.annotations.filter { $0.evidenceID == evidence.id }) { notes in
                draft.content.annotations.removeAll { $0.evidenceID == evidence.id }
                draft.content.annotations += notes
                if !draft.content.sourceIDs.contains(evidence.id) { draft.content.sourceIDs.append(evidence.id) }
            }
        }
    }
    private func sourceToggle(_ id: String, label: String) -> some View {
        Toggle(label, isOn: Binding(get: { draft.content.sourceIDs.contains(id) }, set: { enabled in
            if enabled { draft.content.sourceIDs.append(id) }
            else { draft.content.sourceIDs.removeAll { $0 == id } }
        })).font(.caption).lineLimit(3)
    }
    private func statements(_ title: String, items: Binding<[TaskStatement]>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).bold()
            ForEach(items) { item in
                HStack {
                    TextField("Statement", text: item.text, axis: .vertical)
                        .onChange(of: item.wrappedValue.text) { _, _ in item.wrappedValue.origin = .user }
                    Button("Remove", systemImage: "minus.circle") { items.wrappedValue.removeAll { $0.id == item.wrappedValue.id } }.labelStyle(.iconOnly)
                }
            }
            Button("Add \(title.lowercased())") { items.wrappedValue.append(.init(text: "")) }
        }
    }
}

private struct FeedbackHandoffSheet: View {
    @Bindable var model: AppModel
    let snapshot: FeedbackSnapshot
    let selected: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var mode = TaskHandoffMode.plan
    @State private var message = ""
    @State private var error: String?
    @State private var copying = false
    private var implementAllowed: Bool {
        snapshot.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.canImplement(in: snapshot.batch) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy for Cursor").font(.title2.bold())
            HStack {
                ForEach(TaskHandoffMode.allCases, id: \.self) { item in
                    Button(item.rawValue) { mode = item }.buttonStyle(.bordered)
                        .tint(mode == item ? Color.accentColor : .secondary)
                        .disabled(item == .implement && !implementAllowed)
                }
            }
            if !implementAllowed { Text("Implement requires approved tasks with no unresolved blockers.").font(.caption).foregroundStyle(.orange) }
            ScrollView {
                Text(message).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(8).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 7))
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Copy message") {
                    copying = true
                    Task {
                        if await model.copyFeedbackHandoff(snapshot: snapshot, selected: selected, mode: mode, text: message) { dismiss() }
                        else { error = model.errorMessage }
                        copying = false
                    }
                }.buttonStyle(.borderedProminent).disabled(copying || message.isEmpty || error != nil)
            }
        }.padding(20).frame(width: 800, height: 620)
            .onAppear { rebuild() }.onChange(of: mode) { _, _ in rebuild() }
    }
    private func rebuild() {
        do { message = try FeedbackHandoff.message(snapshot: snapshot, selected: selected, mode: mode); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
