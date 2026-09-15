import SwiftUI
import VideoContextCore

struct TaskEditorSheet: View {
    @Bindable var model: AppModel
    let source: ArtifactRevision
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VideoTask
    @State private var saved: VideoTask
    @State private var exists: Bool
    @State private var saving = false
    @State private var annotating: EvidenceItem?
    @State private var showOriginal = false
    @State private var failure: String?
    init(model: AppModel, initial: VideoTask, source: ArtifactRevision, isNew: Bool) {
        self.model = model; self.source = source; self.isNew = isNew
        _draft = State(initialValue: initial); _saved = State(initialValue: initial); _exists = State(initialValue: !isNew)
    }
    private var library: TaskLibrarySnapshot? { model.taskLibrary?.video.id == draft.videoID ? model.taskLibrary : nil }
    private var dirty: Bool { draft != saved || !exists }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Task requirements").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", systemImage: "checkmark") { Task { await save() } }.disabled(saving || !dirty).keyboardShortcut("s", modifiers: .command)
            }
            Text("\(draft.id) · revision \(saved.revision)").font(.caption.monospaced()).textSelection(.enabled)
            if let library, draft.isStale(library.video) { Label("Evidence changed. Reconcile generation proposals before reviewing.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Task title", text: $draft.content.title).font(.title3)
                    Text("Requested behavior").font(.headline)
                    TextEditor(text: $draft.content.behavior).frame(minHeight: 75).border(.quaternary)
                    statementSection("Requirements", items: $draft.content.requirements)
                    statementSection("Acceptance checks", items: $draft.content.checks)
                    Text("Open questions and user clarifications").font(.headline)
                    ForEach($draft.content.questions) { $question in
                        VStack(alignment: .leading, spacing: 7) {
                            TextField("Question", text: $question.question, axis: .vertical)
                            TextField("Your answer (user clarification)", text: $question.answer, axis: .vertical)
                            Toggle("Blocking", isOn: $question.isBlocking)
                            if !question.isBlocking { TextField("Why this can remain unanswered", text: $question.nonBlockingReason, axis: .vertical) }
                            TextField("Disagreement with recording, if any", text: $question.disagreement, axis: .vertical)
                            Button("Remove question", systemImage: "minus.circle") { draft.content.questions.removeAll { $0.id == question.id } }
                        }.padding(10).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    }
                    Button("Add question", systemImage: "plus.bubble") { draft.content.questions.append(.init(question: "")) }
                    Text("Linked evidence").font(.headline)
                    Text("Choose transcript passages and screenshots. Click a timestamp to seek in the recording.").font(.caption).foregroundStyle(.secondary)
                    if let library {
                        ForEach(library.transcript) { segment in
                            HStack(alignment: .top) {
                                sourceToggle(segment.id, title: segment.text)
                                Button(formatTime(segment.start)) { model.requestSeek(to: segment.start) }
                            }
                        }
                        ForEach(library.evidence) { evidence in
                            HStack {
                                sourceToggle(evidence.id, title: "Screenshot at \(formatTime(evidence.timestamp))")
                                Button("Seek") { model.requestSeek(to: evidence.timestamp) }
                                Button("Annotate", systemImage: "pencil.tip.crop.circle") { annotating = evidence }
                            }
                        }
                    }
                    if let original = draft.generatedOriginal {
                        DisclosureGroup("Original generated task", isExpanded: $showOriginal) { TaskContentSummary(content: original) }
                    }
                    Toggle("Archived (kept in history)", isOn: $draft.archived)
                }.textFieldStyle(.roundedBorder)
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            Divider()
            HStack {
                Text("Review approves requirements; it does not mark implementation complete.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Mark reviewed", systemImage: "checkmark.seal") {
                    Task {
                        await model.reviewVideoTask(saved, source: source)
                        if let latest = model.taskLibrary?.tasks.first(where: { $0.id == saved.id }), latest.reviewedRevision == latest.revision { dismiss() }
                        else { failure = model.errorMessage }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(dirty || saving || draft.archived || draft.content.blockers > 0 || draft.content.checks.isEmpty || draft.content.behavior.isEmpty || library.map { draft.isStale($0.video) || $0.video.status != .ready } != false)
            }
        }.padding(20).frame(minWidth: 700, idealWidth: 820, minHeight: 600, idealHeight: 760)
        .interactiveDismissDisabled(dirty)
        .sheet(item: $annotating) { evidence in
            TaskAnnotationEditor(evidence: evidence, imageURL: model.imageURL(for: evidence), initial: draft.content.annotations.filter { $0.evidenceID == evidence.id }) { annotations in
                draft.content.annotations.removeAll { $0.evidenceID == evidence.id }; draft.content.annotations += annotations
                if !draft.content.sourceIDs.contains(evidence.id) { draft.content.sourceIDs.append(evidence.id) }
            }
        }
    }
    private func sourceToggle(_ id: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { draft.content.sourceIDs.contains(id) }, set: { enabled in
            if enabled { draft.content.sourceIDs.append(id) } else { draft.content.sourceIDs.removeAll { $0 == id } }
        })).lineLimit(3)
    }
    private func statementSection(_ title: String, items: Binding<[TaskStatement]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(items) { item in
                VStack(alignment: .leading) {
                    TextField("Text", text: item.text, axis: .vertical)
                        .onChange(of: item.wrappedValue.text) { _, _ in item.wrappedValue.origin = .user }
                    HStack {
                        Text(item.wrappedValue.origin.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Link selected evidence") { item.wrappedValue.sourceIDs = draft.content.sourceIDs }
                            .font(.caption).help("Associate the evidence selected below with this statement")
                        Button("Remove", systemImage: "minus.circle") { items.wrappedValue.removeAll { $0.id == item.wrappedValue.id } }.labelStyle(.iconOnly).help("Remove statement")
                    }
                    if !item.wrappedValue.sourceIDs.isEmpty { Text("\(item.wrappedValue.sourceIDs.count) evidence references").font(.caption) }
                }.padding(8).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
            Button("Add \(title.lowercased())", systemImage: "plus") { items.wrappedValue.append(.init(text: "")) }
        }
    }
    private func save() async {
        saving = true
        if let value = await model.saveVideoTask(draft, expectedRevision: exists ? saved.revision : nil, expectedSource: source) { saved = value; draft = value; exists = true; failure = nil }
        else { failure = model.errorMessage }
        saving = false
    }
}

struct TaskContentSummary: View {
    let content: TaskContent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.title).font(.headline)
            Text(content.behavior)
            Text("Requirements").bold()
            ForEach(content.requirements) { Text("• \($0.text) [\($0.origin.label)]") }
            Text("Acceptance checks").bold()
            ForEach(content.checks) { Text("• \($0.text) [\($0.origin.label)]") }
            Text("Questions / clarifications").bold()
            ForEach(content.questions) { Text("\($0.question)\nAnswer: \($0.answer)\nBlocking: \($0.isBlocking ? "Yes" : "No")\nReason: \($0.nonBlockingReason)\nDisagreement: \($0.disagreement)") }
            Text("Evidence: \(content.allSourceIDs.sorted().joined(separator: ", "))").font(.caption)
            ForEach(content.annotations) { Text("Annotation: \($0.text)") }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}
