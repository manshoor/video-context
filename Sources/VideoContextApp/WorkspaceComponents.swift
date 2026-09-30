import SwiftUI
import VideoContextCore

enum WorkspaceStyle {
    static let padding: CGFloat = 16
    static let cornerRadius: CGFloat = 10
}

enum TaskDisplayOrigin {
    case recording, feedback, request
    var label: String {
        switch self { case .recording: "Recording"; case .feedback: "Feedback"; case .request: "Request" }
    }
    var color: Color {
        switch self { case .recording: .indigo; case .feedback: .orange; case .request: .purple }
    }
}

struct TaskOriginBadge: View {
    let origin: TaskDisplayOrigin
    var body: some View {
        Text(origin.label).font(.caption2.bold())
            .foregroundStyle(origin.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(origin.color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Task source: \(origin.label)")
    }
}

struct RecordingStatusBadge: View {
    let state: AgentHandoffState
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
    }
    private var title: String {
        switch state {
        case .ready: "Ready"
        case .active: "Processing"
        case .importing: "Importing"
        case .paused: "Paused"
        case .failed: "Needs attention"
        case .stale: "Brief out of date"
        }
    }
    private var symbol: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .active, .importing: "gearshape.2"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle.fill"
        case .stale: "arrow.clockwise.circle"
        }
    }
    private var color: Color {
        switch state {
        case .ready: .green
        case .active, .importing: .indigo
        case .paused, .stale: .orange
        case .failed: .red
        }
    }
}

struct ActivityIndicator: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 72)
            } else if reduceMotion {
                Image(systemName: "hourglass").foregroundStyle(.indigo)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityLabel("Processing")
    }
}

struct ProcessingPanel: View {
    let activity: AppActivity
    let cancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                ActivityIndicator(fraction: activity.fraction)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.isCancelling ? "Stopping…" : activity.title).font(.callout.bold())
                    HStack(spacing: 8) {
                        Text(activity.recordingTitle).lineLimit(1)
                        if let completed = activity.completed, let total = activity.total, total > 0 {
                            Text("\(completed) of \(total)").fixedSize()
                        }
                        Text("\(max(0, Int(context.date.timeIntervalSince(activity.startedAt))))s elapsed")
                            .monospacedDigit().fixedSize()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Cancel", systemImage: "stop.circle", action: cancel)
                    .disabled(activity.isCancelling).help("Stop the current operation")
            }
            .padding(12)
            .background(.indigo.opacity(0.06), in: .rect(cornerRadius: WorkspaceStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: WorkspaceStyle.cornerRadius).stroke(.indigo.opacity(0.18)))
        }
    }
}

struct CredentialNotice: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if model.credentialState == .loading { ActivityIndicator(fraction: nil).accessibilityLabel("Checking API key") }
            else { Image(systemName: model.credentialStatusSystemImage) }
            Text(model.credentialStatusText).font(.callout)
            Spacer()
            if model.shouldOfferCredentialUnlock {
                Button("Unlock API key", systemImage: "key.horizontal") { model.unlockAPIKey() }
            } else if model.credentialState == .missing {
                Button("Load saved key") { model.reloadSavedAPIKey() }.disabled(!model.canReloadSavedAPIKey)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "--:--" }
    let value = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", value / 60, value % 60)
}
