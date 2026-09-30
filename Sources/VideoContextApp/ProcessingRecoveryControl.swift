import SwiftUI
import VideoContextCore

struct ProcessingRecoveryControl: View {
    @Bindable var model: AppModel
    let video: VideoRecord
    @State private var checkpoints: [ProcessingCheckpoint] = []
    @State private var selected: ProcessingCheckpoint?
    @State private var error: String?
    @State private var coverage: AudioCoverage?
    var body: some View {
        Group {
            if let coverage {
                Label(coverage.status == .silent ? "No audio track · visual evidence only" : coverage.status == .present ? "Audio track present" : "Audio coverage unavailable",
                      systemImage: coverage.status == .silent ? "speaker.slash" : "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !checkpoints.isEmpty {
                DisclosureGroup("Processing needs reconciliation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A provider request may have completed before its result was saved. Check the provider outcome before allowing another attempt.").font(.callout)
                        ForEach(checkpoints) { checkpoint in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(checkpoint.stage.rawValue) · \(checkpoint.itemKey)")
                                    Text("\(checkpoint.provider ?? "Provider") · \(checkpoint.model ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Allow retry…") { selected = checkpoint }.disabled(model.isProcessing)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.padding(.top, 8)
                }.font(.callout).padding(10).background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
            }
        }
        .task(id: video.updatedAt) { await reload() }
        .confirmationDialog("Allow this processing step to run again?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button("I checked the outcome — allow retry") {
                guard let checkpoint = selected, let store = model.store else { return }
                Task {
                    do {
                        try await store.resetProcessingCheckpoint(videoID: video.id, stage: checkpoint.stage, itemKey: checkpoint.itemKey, expectedRequestID: checkpoint.requestID)
                        selected = nil; await reload()
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: { Text("Only continue after checking that no usable result can be recovered. Running the step again may incur another provider charge. Resume processing after resolving all pending steps.") }
    }
    private func reload() async {
        guard let store = model.store else { return }
        do {
            checkpoints = try await store.processingCheckpoints(videoID: video.id).filter { $0.state == .unknown || ($0.state == .running && !model.isProcessing) }
            coverage = try await store.audioCoverage(videoID: video.id)
        }
        catch { self.error = error.localizedDescription }
    }
}
