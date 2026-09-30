import SwiftUI
import VideoContextCore

struct DocumentationWorkspace: View {
    @Bindable var model: AppModel
    @State private var showGeneration = false
    @State private var showNewDocument = false
    @State private var showReferenceSources = false
    @State private var documentTitle = ""
    @State private var search = ""
    private var selection: Binding<DocumentationSelection?> {
        Binding(get: { model.workspaceLocation.documentationSelection }, set: { value in
            var next = model.workspaceLocation; next.documentationSelection = value; next.documentSourceRevision = nil
            model.requestNavigation(next)
        })
    }
    var body: some View {
        if let projectID = model.selectedProjectID {
            VStack(spacing: 0) {
                HStack {
                    Button("Generate / Update", systemImage: "sparkles") { showGeneration = true }
                        .disabled(model.documentationBusy || model.documentationDraft?.dirty == true)
                    Button("New document", systemImage: "doc.badge.plus") { documentTitle = ""; showNewDocument = true }
                        .disabled(model.documentationDraft?.dirty == true)
                    Button("Reference sources", systemImage: "link") { showReferenceSources = true }
                        .disabled(model.documentationBusy)
                    Spacer()
                    Button("Copy context for AI", systemImage: "doc.on.clipboard") { Task { await model.copyDocumentationContext() } }
                    Button("Export", systemImage: "square.and.arrow.up") { Task { await model.exportDocumentation() } }
                        .disabled(model.documentation.documentation.isEmpty)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadSelection() } }.labelStyle(.iconOnly)
                }.padding(12)
                if let progress = model.documentationProgress {
                    HStack { if model.documentationBusy { ProgressView().controlSize(.small) }; Text(progress); Spacer() }
                        .font(.callout).padding(.horizontal, 12).padding(.bottom, 10)
                }
                Divider()
                DocumentationRecoveryControl(model: model, projectID: projectID)
                HSplitView {
                    VStack(spacing: 0) {
                        TextField("Search documentation", text: $search).textFieldStyle(.roundedBorder).padding(10)
                        List(selection: selection) {
                            Section("Documentation") {
                                ForEach(model.documentation.documentation.filter { matches($0.title) }) { document in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(document.title, systemImage: "doc.text")
                                        Text(document.reviewedRevision == document.currentRevision ? "Reviewed" : "Needs review").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 3).tag(DocumentationSelection.document(document.id))
                                }
                                Label("Decisions & questions", systemImage: "questionmark.bubble").tag(DocumentationSelection.decisions)
                            }
                            Section("Proposed changes") {
                                ForEach(model.documentation.proposals.filter { $0.state == .pending && matches($0.title) }) { proposal in
                                    Label(proposal.title, systemImage: proposal.isStale ? "clock.badge.exclamationmark" : "sparkles")
                                        .tag(DocumentationSelection.proposal(proposal.id))
                                }
                            }
                            if !model.documentationInboxIssues.isEmpty {
                                Section("Editor proposals needing attention") {
                                    ForEach(model.documentationInboxIssues) { issue in
                                        DisclosureGroup("Proposal \(issue.entry.requestID)") {
                                            Text(issue.message).foregroundStyle(.orange).textSelection(.enabled)
                                            Text("Refresh to retry after resolving the source or revision conflict.").font(.caption)
                                            DisclosureGroup("Submitted content") {
                                                Text(String(decoding: issue.entry.payload, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
                                            }
                                            Button("Dismiss proposal") { Task { await model.dismissEditorProposal(issue) } }
                                        }
                                    }
                                }
                            }
                            Section("Source files") {
                                ForEach(model.documentationSources.filter { matches($0.name) }) { source in
                                    Label(source.name, systemImage: source.kind == .image ? "photo" : "doc.richtext")
                                        .tag(DocumentationSelection.source(source.id))
                                }
                            }
                        }.listStyle(.inset)
                    }.frame(minWidth: 230, idealWidth: 265, maxWidth: 310)
                    Group {
                        switch model.workspaceLocation.documentationSelection {
                        case .document:
                            if let draft = model.documentationDraft { DocumentationDetail(model: model, draft: draft) }
                            else { ContentUnavailableView("Document unavailable", systemImage: "doc.questionmark") }
                        case .source:
                            if let revision = model.documentationSourceRevision { DocumentationSourceDetail(model: model, revision: revision) }
                            else { ContentUnavailableView("Source unavailable", systemImage: "doc.questionmark") }
                        case .proposal(let id):
                            if let proposal = model.documentation.proposals.first(where: { $0.id == id }) { DocumentationProposalDetail(model: model, proposal: proposal) }
                            else { ContentUnavailableView("Proposal unavailable", systemImage: "doc.questionmark") }
                        case .decisions: ProjectDecisionsView(model: model, projectID: projectID)
                        case nil:
                            ContentUnavailableView("Your product reference", systemImage: "books.vertical", description: Text("Add PDF, Markdown, images, or recordings, then generate documentation. Proposed changes stay separate until reviewed."))
                        }
                    }.frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .sheet(isPresented: $showGeneration) { DocumentationGenerationSheet(model: model, projectID: projectID) }
            .sheet(isPresented: $showReferenceSources) { ProjectAnalysisSourcesSheet(model: model, projectID: projectID) }
            .sheet(item: $model.documentationEvidence) { reference in DocumentationEvidenceSheet(model: model, projectID: projectID, reference: reference) }
            .alert("New document", isPresented: $showNewDocument) {
                TextField("Document title", text: $documentTitle)
                Button("Create") { Task { await model.createDocumentation(title: documentTitle, projectID: projectID) } }
                Button("Cancel", role: .cancel) { }
            }
        } else {
            ContentUnavailableView("Choose a project", systemImage: "folder", description: Text("Documentation and source files belong to one project."))
        }
    }
    private func matches(_ title: String) -> Bool { search.isEmpty || title.localizedCaseInsensitiveContains(search) }
}

struct DocumentationDetail: View {
    @Bindable var model: AppModel
    @Bindable var draft: DocumentationDraft
    @State private var history: ProjectDocumentationRevision?
    @State private var evidenceWarnings: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Product documentation").font(.title2.bold())
                Spacer()
                Button("Cancel") { draft.discard() }.disabled(!draft.dirty || draft.saving)
                Button("Save") { Task { await model.saveDocumentationDraft() } }.disabled(!draft.dirty || draft.saving).keyboardShortcut("s", modifiers: .command)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Document title", text: $draft.document.title).font(.title2).textFieldStyle(.roundedBorder)
                    ForEach($draft.document.sections) { $section in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Section title", text: $section.title).font(.headline).textFieldStyle(.roundedBorder)
                            Picker("Statement type", selection: $section.classification) {
                                ForEach(ProjectDocumentationClassification.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }.frame(maxWidth: 300)
                            TextEditor(text: $section.body).frame(minHeight: 110).accessibilityLabel("\(section.title) content")
                                .font(.body).scrollContentBackground(.hidden).padding(8).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                            ForEach(section.evidence) { reference in
                                Button(reference.displayName, systemImage: "link") { model.openDocumentationEvidence(reference) }.font(.callout)
                            }
                            if let warning = evidenceWarnings[section.id] { Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                            Button("Create request from section", systemImage: "checklist") { Task { await model.createRequestFromDocumentation(sectionIDs: [section.id]) } }
                                .disabled(draft.dirty || draft.document.reviewedRevision != draft.document.currentRevision)
                        }.padding(.bottom, 10)
                    }
                    Button("Add section", systemImage: "plus") { draft.document.sections.append(.init(order: draft.document.sections.count, title: "New section", body: "", classification: .requested)) }
                    if model.documentation.decisions.contains(where: { $0.state == .confirmed }) {
                        Menu("Add confirmed decision") {
                            ForEach(model.documentation.decisions.filter { $0.state == .confirmed }) { decision in
                                Button(decision.question) {
                                    draft.document.sections.append(.init(order: draft.document.sections.count, title: decision.question, body: decision.answer, classification: .confirmedDecision, evidence: decision.evidence, decisionIDs: [decision.id]))
                                }
                            }
                        }
                    }
                    DisclosureGroup("Revisions and details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(draft.document.id) · revision \(draft.document.currentRevision)").font(.caption.monospaced()).textSelection(.enabled)
                            ForEach(model.documentation.revisions.filter { $0.documentID == draft.document.id }.sorted { $0.revision > $1.revision }) { revision in
                                Button("Read revision \(revision.revision) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))") { history = revision }
                            }
                        }.padding(.top, 8)
                    }
                }.padding(.vertical, 4)
            }
            if let error = draft.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Text(draft.document.reviewedRevision == draft.document.currentRevision ? "Reviewed revision" : "Draft · review before using as approved requirements").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Mark reviewed", systemImage: "checkmark.seal") { Task { await model.reviewDocumentationDraft() } }
                    .buttonStyle(.borderedProminent).disabled(draft.dirty || draft.saving || draft.document.sections.isEmpty)
            }
        }.padding(18).disabled(draft.saving)
            .task(id: model.workspaceLoadID) {
                guard let store = model.store else { return }
                var warnings: [String: String] = [:]
                for section in draft.document.sections {
                    for reference in section.evidence {
                        do {
                            let value = try await store.validateEvidenceReference(reference, projectID: draft.document.projectID)
                            if value.status != .valid { warnings[section.id] = value.message ?? "Source changed. Review this section against its evidence." }
                        } catch { warnings[section.id] = error.localizedDescription }
                    }
                }
                if !Task.isCancelled { evidenceWarnings = warnings }
            }
            .sheet(item: $history) { revision in
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(revision.title) · revision \(revision.revision)").font(.title2.bold())
                    ScrollView { Text(revision.markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Close") { history = nil }
                }.padding(24).frame(minWidth: 600, minHeight: 440)
            }
    }
}

extension ProjectDocumentationClassification {
    var displayName: String {
        switch self {
        case .observed: "Observed behavior"
        case .requested: "Requested behavior"
        case .confirmedDecision: "Confirmed decision"
        case .interpretation: "AI interpretation"
        case .unresolved: "Unresolved question"
        }
    }
}

extension ProjectEvidenceReference {
    var displayName: String {
        switch self {
        case .recording(_, _, let time, _): "Recording at \(BriefPromptBuilder.timestamp(time))"
        case .feedback(_, let revision, let comment, _): "Feedback revision \(revision)\(comment == nil ? "" : " · original comment")"
        case .document(_, let revision, let locator): "Source revision \(revision) · \(locator.displayValue)"
        case .reviewedDocumentation(_, let revision, let sectionID): "Reviewed documentation revision \(revision)\(sectionID.map { " · section \($0)" } ?? " · complete document")"
        }
    }
}
