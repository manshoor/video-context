import SwiftUI
import VideoContextCore

struct TaskAnalysisReferenceSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    let entry: TaskAnalysisSourceManifestEntry
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Reference revision"
    @State private var text: String?
    @State private var stale = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text("\(entry.sourceID) · \(entry.revision)").font(.caption.monospaced()).textSelection(.enabled)
            if stale { Label("Historical revision · reference has changed", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
            if let text { ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            else if let error { Text(error).foregroundStyle(.orange) }
            else { ProgressView("Loading reference…") }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 680, height: 500)
        .task(id: entry.id) {
            guard let store = model.store else { return }
            do {
                let snapshot = try await store.projectDocumentation(projectID: projectID)
                try Task.checkCancellation()
                let sourceID = String(entry.sourceID.split(separator: ":", maxSplits: 1).last ?? "")
                switch entry.kind {
                case .reviewedDocumentation:
                    guard let revision = Int(entry.revision.dropFirst()) else { throw TaskContextError.missing(entry.id) }
                    guard let document = snapshot.revisions.first(where: { $0.documentID == sourceID && $0.revision == revision }) else { throw TaskContextError.missing(entry.id) }
                    title = document.title; text = document.markdown
                    stale = snapshot.documentation.first { $0.id == sourceID }?.currentRevision != revision
                case .confirmedDecision:
                    guard let revision = Int(entry.revision.dropFirst()) else { throw TaskContextError.missing(entry.id) }
                    guard let decision = snapshot.decisions.first(where: { $0.id == sourceID && $0.revision == revision }) else { throw TaskContextError.missing(entry.id) }
                    title = decision.question; text = decision.answer
                    stale = decision.state != .confirmed
                case .importedDocument:
                    guard let revisionText = entry.revision.split(separator: ":").first,
                          let revision = Int(revisionText.dropFirst()),
                          let (source, document) = try await store.projectDocumentSource(projectID: projectID, sourceID: sourceID, revision: revision) else {
                        throw TaskContextError.missing(entry.id)
                    }
                    title = source.name
                    text = document.units.map(\.text).joined(separator: "\n\n")
                    stale = source.currentRevision != revision
                case .recording:
                    guard let recording = try await store.videoSnapshot(id: sourceID), recording.video.projectID == projectID else {
                        throw TaskContextError.missing(entry.id)
                    }
                    let revision = recording.video.revisions
                    guard entry.revision == "transcript:\(revision.transcript):evidence:\(revision.evidence):brief:\(revision.brief)" else {
                        throw TaskContextError.conflict
                    }
                    title = recording.video.title
                    text = recording.transcript.map { "[\(Int($0.start))s] \($0.correctedText ?? $0.originalText)" }.joined(separator: "\n\n")
                }
            } catch is CancellationError { }
            catch { self.error = "This exact reference revision is unavailable. Request refreshed task analysis. \(error.localizedDescription)" }
        }
    }
}
