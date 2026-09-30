import SwiftUI
import VideoContextCore

struct ProjectTaskDetail: View {
    @Bindable var model: AppModel
    @Bindable var draft: ProjectTaskDraft
    @State private var annotation: EvidenceItem?
    @State private var previewImage: EvidenceItem?
    @State private var projectEvidence: ProjectEvidenceReference?
    @State private var referenceSource: TaskAnalysisSourceManifestEntry?
    private var item: ProjectTaskItem? { model.projectWorkspace?.tasks.first { $0.reference == draft.reference } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task details").font(.title2.bold())
                    Label(item?.state ?? "Needs review", systemImage: item?.canImplement == true ? "checkmark.seal" : "doc.text")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { draft.discard() }.disabled(!draft.dirty || draft.saving)
                Button("Save") { Task { await model.saveProjectTask() } }.disabled(!draft.dirty || draft.saving).keyboardShortcut("s", modifiers: .command)
            }
            if item?.isStale == true { Label("Source evidence changed. Reconcile task proposals before reviewing.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Task title", text: $draft.content.title, axis: .vertical).font(.title3.bold())
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Requested behavior").font(.headline)
                        TextEditor(text: $draft.content.behavior).accessibilityLabel("Requested behavior").frame(minHeight: 80).scrollContentBackground(.hidden).padding(6).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                    }
                    statements("Requirements", items: $draft.content.requirements)
                    statements("Acceptance checks", items: $draft.content.checks)
                    questions
                    TaskAnalysisEvidenceView(content: draft.content, openEvidence: { projectEvidence = $0 }, openSource: { referenceSource = $0 })
                    if draft.content.evidenceReview != nil || model.modelConfiguration.reviewConfiguration != nil {
                        Button("Review evidence again", systemImage: "arrow.clockwise") {
                            Task { await model.reviewSavedProjectTaskEvidence() }
                        }.disabled(draft.dirty || draft.saving || draft.archived || item?.isStale == true)
                        Text("Save edits first. This reviews the saved task and preserves your wording and answers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    evidence
                    DisclosureGroup("Task details and history") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(draft.taskID) · revision \(draft.revision)").font(.caption.monospaced()).textSelection(.enabled)
                            if let run = draft.videoTask?.generationRunID ?? draft.feedbackTask?.generationRunID {
                                Button("View generation usage") { model.showUsage(runID: run) }
                            }
                            if let original = draft.videoTask?.generatedOriginal ?? draft.feedbackTask?.generatedOriginal {
                                DisclosureGroup("Original generated task") { TaskContentSummary(content: original) }
                            }
                        }.padding(.top, 8)
                    }
                }.textFieldStyle(.roundedBorder).padding(.vertical, 4)
            }
            if let error = draft.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Button(draft.archived ? "Restore" : "Archive", systemImage: "archivebox") {
                    draft.archived.toggle(); Task { await model.saveProjectTask() }
                }.disabled(draft.dirty || draft.saving)
                Button("Delete Task…", systemImage: "trash", role: .destructive) {
                    Task { await model.requestTaskDeletion([draft.reference]) }
                }.disabled(draft.saving)
                Spacer()
                if draft.saving { ProgressView().controlSize(.small) }
                Button("Mark reviewed", systemImage: "checkmark.seal") { Task { await model.reviewProjectTask() } }
                    .buttonStyle(.borderedProminent).disabled(!draft.canReview || item?.isStale == true || item?.canImplement == true)
            }
            Text("Review approves requirements; it does not mark implementation complete.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).disabled(draft.saving)
            .sheet(item: $referenceSource) { entry in
                if let projectID = model.selectedProjectID {
                    TaskAnalysisReferenceSheet(model: model, projectID: projectID, entry: entry)
                }
            }
            .sheet(item: $projectEvidence) { reference in
                if let projectID = model.selectedProjectID {
                    DocumentationEvidenceSheet(model: model, projectID: projectID, reference: reference)
                }
            }
            .sheet(item: $annotation) { evidence in
                TaskAnnotationEditor(evidence: evidence, imageURL: model.paths?.absoluteURL(relativePath: evidence.imageRelativePath), initial: draft.content.annotations.filter { $0.evidenceID == evidence.id }) { notes in
                    draft.content.annotations.removeAll { $0.evidenceID == evidence.id }; draft.content.annotations += notes
                    if !draft.content.sourceIDs.contains(evidence.id) { draft.content.sourceIDs.append(evidence.id) }
                }
            }
            .sheet(item: $previewImage) { evidence in
                VStack {
                    if let url = model.paths?.absoluteURL(relativePath: evidence.imageRelativePath), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Source image at \(formatTime(evidence.timestamp))") }
                    else { ContentUnavailableView("Image unavailable", systemImage: "photo") }
                    Button("Close") { previewImage = nil }
                }.padding(20).frame(minWidth: 600, idealWidth: 850, minHeight: 450, idealHeight: 650)
            }
    }
    private func statements(_ title: String, items: Binding<[TaskStatement]>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            ForEach(items) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Statement", text: entry.text, axis: .vertical)
                        .onChange(of: entry.wrappedValue.text) { _, _ in entry.wrappedValue.origin = .user }
                    HStack {
                        Text(entry.wrappedValue.origin.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Link selected evidence") { entry.wrappedValue.sourceIDs = draft.content.sourceIDs }.font(.caption)
                        Button("Remove statement", systemImage: "minus.circle") { items.wrappedValue.removeAll { $0.id == entry.wrappedValue.id } }.labelStyle(.iconOnly)
                    }
                }.padding(10).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
            }
            Button("Add \(title.lowercased())", systemImage: "plus") { items.wrappedValue.append(.init(text: "")) }
        }
    }
    private var questions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Questions and clarifications").font(.headline)
            ForEach($draft.content.questions) { $question in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Question", text: $question.question, axis: .vertical)
                    Picker("Question type", selection: Binding(get: { question.category ?? .productDecision }, set: { question.category = $0 })) {
                        Text("Product decision").tag(TaskQuestionCategory.productDecision)
                        Text("Editor investigation").tag(TaskQuestionCategory.investigation)
                        Text("Missing evidence").tag(TaskQuestionCategory.missingEvidence)
                    }
                    TextField("Your answer", text: $question.answer, axis: .vertical)
                    Toggle("Blocking", isOn: $question.isBlocking)
                    if !question.isBlocking { TextField("Why this can remain unanswered", text: $question.nonBlockingReason, axis: .vertical) }
                    TextField("Disagreement with the source, if any", text: $question.disagreement, axis: .vertical)
                    Button("Remove question", systemImage: "minus.circle") { draft.content.questions.removeAll { $0.id == question.id } }
                }.padding(10).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
            }
            Button("Add question", systemImage: "plus.bubble") { draft.content.questions.append(.init(question: "")) }
        }
    }
    private var evidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Source evidence").font(.headline); Spacer(); Button("Open source", systemImage: "arrow.up.forward.square") { model.openProjectSource(draft.source) } }
            Text(draft.sourceTitle).foregroundStyle(.secondary)
            if let recording = draft.recording {
                ForEach(recording.transcript) { segment in
                    HStack(alignment: .top) {
                        sourceToggle(segment.id, text: segment.text)
                        Button(formatTime(segment.start)) { model.openProjectSource(.recording(recording.video.id), timestamp: segment.start) }
                    }
                }
                ForEach(recording.evidence) { image in
                    HStack {
                        sourceToggle(image.id, text: "Screenshot at \(formatTime(image.timestamp))")
                        Button("View") { previewImage = image }
                        Button("Seek") { model.openProjectSource(.recording(recording.video.id), timestamp: image.timestamp) }
                        Button("Annotate") { annotation = image }
                    }
                }
            }
            if let batch = draft.feedback?.batch {
                ForEach(batch.comments) { comment in
                    HStack(alignment: .top) {
                        sourceToggle(comment.id, text: comment.text)
                        Button("Open comment") { model.focusedFeedbackCommentID = comment.id; model.openProjectSource(.feedback(batch.id)) }
                    }
                }
                ForEach(batch.sources) { source in
                    HStack {
                        sourceToggle(source.id, text: source.filename ?? source.url ?? source.recordingID ?? "Source")
                        if source.kind == .recording, let id = source.recordingID { Button("Open recording") { model.openProjectSource(.recording(id)) } }
                        if source.kind == .image, let path = source.localPath {
                            let image = EvidenceItem(id: source.id, videoID: batch.id, timestamp: 0, imageRelativePath: path, origin: .manual)
                            Button("View") { previewImage = image }; Button("Annotate") { annotation = image }
                        }
                    }
                }
            }
        }
    }
    private func sourceToggle(_ id: String, text: String) -> some View {
        Toggle(isOn: Binding(get: { draft.content.sourceIDs.contains(id) }, set: { if $0 { if !draft.content.sourceIDs.contains(id) { draft.content.sourceIDs.append(id) } } else { draft.content.sourceIDs.removeAll { $0 == id } } })) { Text(text).lineLimit(3) }
    }
}
