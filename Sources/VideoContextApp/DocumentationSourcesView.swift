import SwiftUI
import PDFKit
import VideoContextCore

struct DocumentationSourceDetail: View {
    @Bindable var model: AppModel
    let revision: ProjectDocumentSourceRevision
    @State private var showAll = false
    private var source: ProjectDocumentSource? { model.documentationSources.first { $0.id == revision.sourceID } }
    private var units: [ProjectDocumentExtractionUnit] {
        guard !showAll, let locator = model.documentationEvidenceLocator else { return revision.units }
        return revision.units.filter { unit in
            switch locator.kind {
            case .heading: return unit.kind == .heading && unit.title == locator.value
            case .unit: return unit.id == locator.value
            case .markdownLine:
                guard let start = unit.locator.startLine, let selectedStart = locator.startLine else { return false }
                return start <= (locator.endLine ?? selectedStart) && (unit.locator.endLine ?? start) >= selectedStart
            case .pdfPage, .asset: return unit.locator == locator
            }
        }
    }
    private var assets: [ProjectDocumentAsset] {
        guard !showAll, let locator = model.documentationEvidenceLocator else { return revision.assets }
        if locator.kind == .asset { return revision.assets.filter { $0.sourcePath == locator.value } }
        return []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source?.name ?? "Source file").font(.title2.bold())
            HStack {
                if let back = model.sourceReturnLocation {
                    Button("Back to documentation", systemImage: "arrow.left") { model.requestNavigation(back); model.sourceReturnLocation = nil }
                }
                Label(revision.status.rawValue.capitalized, systemImage: revision.status == .ready ? "checkmark.circle" : "exclamationmark.triangle")
                Text("Revision \(revision.revision)").foregroundStyle(.secondary)
                Spacer()
                if model.documentationEvidenceLocator != nil { Button(showAll ? "Show citation" : "Show whole source") { showAll.toggle() } }
            }.font(.callout)
            if source?.currentRevision != revision.revision { Text("Historical source revision").foregroundStyle(.orange) }
            if source?.kind == .pdf, let url = model.paths?.absoluteURL(relativePath: revision.originalRelativePath) {
                SourcePDFPreview(url: url, page: model.documentationEvidenceLocator?.page).frame(minHeight: 220, idealHeight: 340)
            } else if source?.kind == .image, let url = model.paths?.absoluteURL(relativePath: revision.originalRelativePath), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300).accessibilityLabel(source?.name ?? "Imported source image")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(revision.errors) { error in Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                    ForEach(units) { unit in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(unit.locator.displayValue).font(.caption).foregroundStyle(.secondary)
                            Text(unit.text).font(unit.kind == .code ? .system(.body, design: .monospaced) : .body).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(asset.sourcePath) · \(asset.status.rawValue)").font(.caption)
                            if let path = asset.relativePath, let url = model.paths?.absoluteURL(relativePath: path), let image = NSImage(contentsOf: url), source?.kind == .markdown {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240).accessibilityLabel(asset.sourcePath)
                            }
                            if let error = asset.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).id(revision.id)
    }
}

private struct SourcePDFPreview: NSViewRepresentable {
    let url: URL
    let page: Int?
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.setAccessibilityLabel("Original PDF source")
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        if let page, let target = view.document?.page(at: max(0, page - 1)), view.currentPage != target { view.go(to: target) }
    }
}

struct DocumentationGenerationSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [ProjectDocumentationGenerationSource] = []
    @State private var selected = Set<String>()
    @State private var title = "Product reference"
    @State private var loading = true
    @State private var error: String?
    private var documentID: String? {
        if case .document(let id) = model.workspaceLocation.documentationSelection { id } else { nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(documentID == nil ? "Generate documentation" : "Propose documentation update").font(.title2.bold())
            Text("Choose the sources to analyze. The result will be a proposal for review using your selected analysis provider.").foregroundStyle(.secondary)
            TextField("Documentation title", text: $title).textFieldStyle(.roundedBorder)
            if loading { ProgressView("Loading project sources…") }
            List(sources) { source in
                Toggle(isOn: Binding(get: { selected.contains(source.id) }, set: { if $0 { selected.insert(source.id) } else { selected.remove(source.id) } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.title)
                        Text("\(source.kind) · revision \(source.revision)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(minHeight: 230)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Select all") { selected = Set(sources.map(\.id)) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Generate proposal") {
                    let targetID = documentID, requestedTitle = title, sourceIDs = selected
                    Task { await model.generateDocumentation(projectID: projectID, documentID: targetID, title: requestedTitle, selected: sourceIDs) }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(loading || selected.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 600, height: 500)
            .task {
                do {
                    sources = try await model.documentationGenerationInputs(projectID: projectID)
                    selected = Set(sources.map(\.id))
                    if let draft = model.documentationDraft { title = draft.document.title }
                } catch { self.error = error.localizedDescription }
                loading = false
            }
    }
}

struct DocumentationProposalDetail: View {
    @Bindable var model: AppModel
    let proposal: ProjectDocumentationProposal
    private var previous: ProjectDocumentation? { model.documentation.documentation.first { $0.id == proposal.documentID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(proposal.title).font(.title2.bold())
            Text("\(proposal.diff.addedSectionIDs.count) added · \(proposal.diff.changedSectionIDs.count) changed · \(proposal.diff.removedSectionIDs.count) removed sections").font(.callout).foregroundStyle(.secondary)
            if proposal.isStale { Label("This proposal is outdated. Generate an update from the current sources.", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
            HSplitView {
                proposalSections("Current", previous?.sections ?? [], proposed: false)
                proposalSections("Proposed", proposal.sections, proposed: true)
            }
            HStack {
                Button("Reject proposal") { Task { await model.resolveDocumentationProposal(proposal, accept: false) } }
                    .disabled(proposal.state != .pending)
                Spacer()
                Button("Accept changes", systemImage: "checkmark") { Task { await model.resolveDocumentationProposal(proposal, accept: true) } }
                    .buttonStyle(.borderedProminent).disabled(proposal.state != .pending || proposal.isStale || model.documentationDraft?.dirty == true)
            }
            Text("Accepting changes creates a saved revision. Review its requirements before creating an implementation request.").font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }
    private func proposalSections(_ label: String, _ sections: [ProjectDocumentationSection], proposed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if sections.isEmpty { Text(proposed ? "No sections proposed" : "New document").foregroundStyle(.secondary) }
                    ForEach(sections.sorted { $0.order < $1.order }) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            Text(section.classification.displayName).font(.caption).foregroundStyle(.secondary)
                            if proposed && proposal.diff.addedSectionIDs.contains(section.id) {
                                Label("Added", systemImage: "plus.circle").font(.caption).foregroundStyle(.green)
                            } else if proposal.diff.changedSectionIDs.contains(section.id) {
                                Label("Changed", systemImage: "pencil.circle").font(.caption).foregroundStyle(.orange)
                            } else if !proposed && proposal.diff.removedSectionIDs.contains(section.id) {
                                Label("Removed", systemImage: "minus.circle").font(.caption).foregroundStyle(.orange)
                            }
                            Text(section.body).textSelection(.enabled)
                            ForEach(section.evidence) { reference in
                                Button { model.openDocumentationEvidence(reference) } label: {
                                    Label(reference.displayName, systemImage: "link").multilineTextAlignment(.leading)
                                }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                            }
                            DisclosureGroup("Technical details") {
                                Text("Section ID: \(section.id)").font(.caption).textSelection(.enabled)
                                ForEach(section.evidence) { reference in
                                    Text(ProjectDocumentationFormatting.citationID(reference)).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }.font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 190, maxWidth: .infinity).padding(8)
    }
}
