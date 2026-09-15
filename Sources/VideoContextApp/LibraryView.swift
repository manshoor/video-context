import SwiftUI
import UniformTypeIdentifiers
import VideoContextCore

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var showFileImporter = false
    @State private var showURLImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(model.videos, selection: $model.selectedVideoID) { video in
                VideoRow(
                    video: video,
                    activity: model.activity?.videoID == video.id ? model.activity : nil,
                    state: model.contextState(for: video)
                )
                    .tag(video.id)
            }
            .overlay {
                if model.videos.isEmpty {
                    ContentUnavailableView(
                        "Import a recording",
                        systemImage: "video.fill",
                        description: Text("Drop an MP4 here, select a file, or add an accessible video link.")
                    )
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isProcessing else { return false }
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "mp4" }) else { return false }
                Task { await model.importLocal(url) }
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }
            .navigationTitle("Recordings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
          VStack(spacing: 0) {
            if model.isUIFixture {
                Label("Demo library · simulated processing · no API calls", systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            if let activity = model.activity {
                ProcessingPanel(activity: activity) { model.cancelProcessing() }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            }
            if let snapshot = model.snapshot {
                VideoWorkspaceView(model: model, snapshot: snapshot)
            } else {
                ContentUnavailableView("Select a recording", systemImage: "video")
            }
          }
          .frame(minWidth: 640, idealWidth: 800, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Import MP4", systemImage: "plus.rectangle.on.rectangle") { showFileImporter = true }
                        .disabled(model.isProcessing)
                        .help("Import an MP4 recording")
                    Button("Import Link", systemImage: "link") { showURLImporter = true }
                        .disabled(model.isProcessing)
                        .help("Import a video link")
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .help("Settings and agent connections")
                }
            }
        .task { await model.loadLibrary(resume: true) }
        .onChange(of: model.selectedVideoID) { _, _ in
            Task { await model.loadSelection() }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importLocal(url) }
            } else if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showURLImporter) {
            URLImportView { url in
                showURLImporter = false
                Task { await model.importOnline(url) }
            }
        }
        .alert("Video Context", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if $0 == false { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct VideoRow: View {
    let video: VideoRecord
    let activity: AppActivity?
    let state: AgentHandoffState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: video.source == .localFile ? "play.rectangle.fill" : "link")
                .font(.title3).foregroundStyle(.indigo)
                .frame(width: 30, height: 34)
                .background(.indigo.opacity(0.08), in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(video.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(formatTime(video.duration)).font(.caption).foregroundStyle(.secondary)
                if let activity {
                    HStack(spacing: 8) {
                        ActivityIndicator(fraction: nil)
                        Text(activity.title).font(.caption).lineLimit(1)
                    }
                } else {
                    RecordingStatusBadge(state: state)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct URLImportView: View {
    let importAction: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import video link", systemImage: "link").font(.title2.bold())
            Text("Paste an accessible Loom, YouTube, or direct video URL. If access is blocked, download the MP4 and import the file.")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if value.isEmpty == false { importAction(value) } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { importAction(value) }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "--:--" }
    let value = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

private func statusColor(_ status: ProcessingStatus) -> Color {
    switch status {
    case .ready: .green
    case .failed, .incomplete: .red
    case .cancelled: .orange
    default: .secondary
    }
}
