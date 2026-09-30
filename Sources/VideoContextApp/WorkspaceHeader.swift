import SwiftUI
import VideoContextCore

struct WorkspaceHeader: View {
    @Bindable var model: AppModel
    let snapshot: VideoSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.video.title).font(.title2.bold()).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            HStack(spacing: 8) {
                        RecordingStatusBadge(state: model.contextState(for: snapshot.video))
                        Text(formatTime(snapshot.video.duration)).font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Button("View usage", systemImage: "chart.bar.xaxis") { model.showUsage(videoID: snapshot.video.id) }
                            ForEach(Array(snapshot.provenance.enumerated()), id: \.offset) { _, item in
                                Text("\(item.stage.rawValue) r\(item.revision): \(item.identity.provider.displayName) · \(item.identity.model)")
                            }
                            Text("Imported \(snapshot.video.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            Text(snapshot.video.source == .localFile ? "Local MP4" : "Online recording")
                        } label: { Label("Recording details", systemImage: "info.circle") }
                        .menuStyle(.borderlessButton).fixedSize().labelStyle(.iconOnly)
                        .help("Recording details")
                Spacer(minLength: 0)
                    Button("Generate tasks", systemImage: "sparkles") { model.generateTasks() }
                        .disabled(model.isProcessing || snapshot.video.status != .ready || snapshot.video.revisions.isBriefStale || snapshot.video.projectID == nil)
                    Button("Copy context message", systemImage: "doc.on.clipboard") { model.copyContextMessage() }
                        .buttonStyle(.borderedProminent).help("Copy complete instructions for your coding agent")
            }
            DisclosureGroup("Recording identifiers and actions") {
              HStack(spacing: 8) {
                Text("Context ID").foregroundStyle(.secondary)
                Text(snapshot.video.id).monospaced().textSelection(.enabled).lineLimit(1)
                Button("Copy ID only", systemImage: "doc.on.doc") { model.copyContextID() }
                    .labelStyle(.iconOnly).help("Copy ID only")
                Spacer(minLength: 0)
                if !model.isProcessing && (snapshot.video.status != .ready || snapshot.video.revisions.isBriefStale) {
                    Button(snapshot.video.revisions.isBriefStale ? "Refresh brief" : "Resume processing", systemImage: "arrow.clockwise") { model.beginProcessing(videoID: snapshot.video.id) }
                        .disabled((model.selectionNeedsOpenAI && model.credentialState != .ready) || !model.credentialReady(for: model.analysisProvider))
                }
              }.font(.caption)
            }
            if model.taskGenerationVideoID == snapshot.video.id, let message = model.taskGenerationMessage {
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button("View project tasks") {
                        var next = model.workspaceLocation; next.section = .tasks; next.recordingID = nil
                        model.requestNavigation(next)
                    }
                }
            }
            if let label = model.lastCopiedLabel {
                Label(label, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            if (snapshot.video.status != .ready || snapshot.video.revisions.isBriefStale) && model.selectionNeedsOpenAI && model.credentialState != .ready { CredentialNotice(model: model) }
            if (snapshot.video.status != .ready || snapshot.video.revisions.isBriefStale) && (model.analysisProvider == .claude || model.analysisProvider == .deepSeek) && !model.credentialReady(for: model.analysisProvider) {
                HStack {
                    Label("Enter or unlock the \(model.analysisProvider.label) API key in Settings.", systemImage: "key")
                    Spacer()
                    SettingsLink { Text("Settings") }
                }.font(.caption).padding(10).background(.quaternary, in: .rect(cornerRadius: 8))
            }
            if snapshot.video.status != .ready || snapshot.video.revisions.isBriefStale {
                Text(model.modelConfiguration.analysisDescription + " · " + model.modelConfiguration.processingDescription).font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.video.revisions.isBriefStale && snapshot.brief != nil {
                Label("The brief is out of date. Review your corrections before using this context.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let error = snapshot.video.errorMessage {
                Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ProcessingRecoveryControl(model: model, video: snapshot.video)
        }
        .padding(WorkspaceStyle.padding)
        .background(.background)
    }
}
