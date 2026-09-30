import SwiftUI
import VideoContextCore

struct DocumentationEvidenceSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    let reference: ProjectEvidenceReference
    @Environment(\.dismiss) private var dismiss
    @State private var evidence: MCPProjectEvidenceResult?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(evidence?.title ?? "Exact source evidence").font(.title2.bold())
            if let evidence {
                Text("\(evidence.locator) · \(evidence.sourceRevision)").foregroundStyle(.secondary)
                if evidence.freshness != .current { Label("Historical evidence · source has changed", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let data = evidence.imageData, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Cited screenshot") }
                        Text(evidence.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let error = evidence.error { Text(error).foregroundStyle(.orange) }
                    }
                }
                HStack {
                    if case .recording(let id, _, let time, _) = reference {
                        Button("Open recording at citation") { dismiss(); model.openProjectSource(.recording(id), timestamp: time) }
                    }
                    if case .feedback(let id, _, let commentID, _) = reference {
                        Button("Open current feedback thread") { dismiss(); model.openProjectSource(.feedback(id), commentID: commentID) }
                    }
                    if case .reviewedDocumentation(let id, _, _) = reference {
                        Button("Open current project document") {
                            dismiss()
                            var next = model.workspaceLocation
                            next.section = .documentation
                            next.documentationSelection = .document(id)
                            model.requestNavigation(next)
                        }
                    }
                    Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else if let error { ContentUnavailableView("Evidence unavailable", systemImage: "exclamationmark.triangle", description: Text(error)); Button("Close") { dismiss() } }
            else { ProgressView("Loading cited revision…") }
        }.padding(24).frame(minWidth: 640, minHeight: 460)
        .task(id: reference) {
            guard let store = model.store, let paths = model.paths else { return }
            do {
                let result = try await ProjectMCPService(store: store).evidence(projectID: projectID, reference: reference, paths: paths)
                try Task.checkCancellation(); evidence = result
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
