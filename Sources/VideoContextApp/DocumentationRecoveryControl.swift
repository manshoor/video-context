import SwiftUI
import VideoContextCore

struct DocumentationRecoveryControl: View {
    @Bindable var model: AppModel
    let projectID: String
    @State private var checkpoints: [DocumentationAnalysisCheckpoint] = []
    @State private var selected: DocumentationAnalysisCheckpoint?
    @State private var error: String?
    private var analysisBusy: Bool { model.documentationBusy || model.feedbackBusy || model.taskGenerationTask != nil || model.taskDraft?.saving == true }
    var body: some View {
        Group {
            if !checkpoints.isEmpty {
                DisclosureGroup("Analysis requests need reconciliation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Check the provider outcome before allowing another attempt. Completed batches remain saved.")
                        ForEach(checkpoints) { checkpoint in
                            HStack {
                                Text("Interrupted batch \(checkpoint.key.prefix(8))").font(.caption.monospaced())
                                Spacer(); Button("Allow retry…") { selected = checkpoint }.disabled(analysisBusy)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.padding(.top, 8)
                }.padding(12).background(.orange.opacity(0.08))
            }
        }
        .task(id: "\(projectID):\(analysisBusy)") { await reload() }
        .confirmationDialog("Allow this analysis request to run again?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button("I checked the outcome — allow retry") {
                guard !analysisBusy, let selected, let store = model.store else { return }
                Task {
                    do { try await store.resetDocumentationAnalysis(selected); self.selected = nil; await reload() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: { Text("Continue only after checking that no usable provider result can be recovered. Another attempt may incur a charge. Run the affected generation or review again after reconciliation.") }
    }
    private func reload() async {
        guard let store = model.store else { return }
        do { checkpoints = try await store.documentationAnalysisCheckpoints(projectID: projectID).filter { $0.state == .unknown || ($0.state == .running && !analysisBusy) } }
        catch { self.error = error.localizedDescription }
    }
}
