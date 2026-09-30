import SwiftUI
import VideoContextCore

/// Selection is edited locally and saved explicitly. Refresh copies a new immutable source revision.
struct ProjectAnalysisSourcesSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ProjectAnalysisSelection(documentIDs: [], recordingIDs: [], documentSourceIDs: [])
    @State private var documents: [ProjectDocumentation] = []
    @State private var recordings: [VideoRecord] = []
    @State private var sources: [ProjectDocumentSource] = []
    @State private var statuses: [ProjectAnalysisSourceStatus] = []
    @State private var savedSourceIDs = Set<String>()
    @State private var busy = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project reference sources").font(.title2.bold())
            Text("Choose the documentation and original recordings that tasks must cross-reference. Selected repository files are saved snapshots; refresh them explicitly when they change.")
                .foregroundStyle(.secondary)
            List {
                Section("Main reviewed documentation") {
                    ForEach(documents) { document in
                        Toggle(isOn: membership(document.id, in: $selection.documentIDs)) {
                            VStack(alignment: .leading) {
                                Text(document.title)
                                Text(document.reviewedRevision == document.currentRevision ? "Reviewed revision \(document.currentRevision)" : "Needs review before analysis")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Original reference recordings") {
                    ForEach(recordings) { recording in
                        Toggle(isOn: membership(recording.id, in: $selection.recordingIDs)) {
                            VStack(alignment: .leading) {
                                Text(recording.title)
                                Text(recording.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Imported repository documents") {
                    ForEach(sources.filter { $0.kind == .markdown || $0.kind == .pdf }) { source in
                        HStack {
                            Toggle(source.name, isOn: membership(source.id, in: $selection.documentSourceIDs))
                            Text("Revision \(source.currentRevision)").font(.caption).foregroundStyle(.secondary)
                            Button("Refresh file") { Task { await refresh(source.id) } }
                                .disabled(!savedSourceIDs.contains(source.id))
                        }
                    }
                    Text("Use Add Sources → Import Files to add Markdown or PDF files. Save a new selection before refreshing its files.").font(.caption).foregroundStyle(.secondary)
                }
                if !statuses.isEmpty {
                    Section("Saved reference source checks") {
                        ForEach(statuses) { status in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(status.title)
                                Text(status.message ?? status.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Check source files") { Task { await checkSources() } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save references") { Task { await save() } }.buttonStyle(.borderedProminent)
            }
            .disabled(busy)
        }
        .padding(24).frame(width: 720, height: 610)
        .task { await load() }
    }

    private func membership(_ id: String, in values: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            values.wrappedValue.removeAll { $0 == id }
            if selected { values.wrappedValue.append(id) }
        })
    }

    private func load() async {
        guard let store = model.store, let paths = model.paths else { busy = false; return }
        do {
            let documentation = try await store.projectDocumentationReadSnapshot(projectID: projectID)
            let workspace = try await store.projectWorkspace(projectID: projectID)
            let saved = try await store.projectAnalysisSelection(projectID: projectID)
            let checked = try await store.projectAnalysisSourceStatuses(projectID: projectID, paths: paths)
            try Task.checkCancellation()
            documents = documentation.documentation; sources = documentation.sources; recordings = workspace.recordings
            selection = saved ?? .init(documentIDs: [], recordingIDs: [], documentSourceIDs: [])
            savedSourceIDs = Set(selection.documentSourceIDs)
            statuses = checked
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        busy = false
    }

    private func checkSources() async {
        guard let store = model.store, let paths = model.paths else { return }
        busy = true; error = nil
        defer { busy = false }
        do { statuses = try await store.projectAnalysisSourceStatuses(projectID: projectID, paths: paths) }
        catch { self.error = error.localizedDescription }
    }

    private func refresh(_ sourceID: String) async {
        guard let store = model.store, let paths = model.paths else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await store.refreshProjectAnalysisSource(projectID: projectID, sourceID: sourceID, paths: paths)
            sources = try await store.listProjectDocumentSources(projectID: projectID)
            statuses = try await store.projectAnalysisSourceStatuses(projectID: projectID, paths: paths)
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let store = model.store else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await store.saveProjectAnalysisSelection(projectID: projectID, selection: selection)
            await model.loadSelection()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
