import SwiftUI

struct JamIntegrationSettingsSection: View {
    @Bindable var model: JamSettingsModel

    var body: some View {
        Section("Integrations") {
            LabeledContent("Jam") {
                Label(model.message, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    Button("Cancel Jam connection", systemImage: "xmark.circle") {
                        model.cancelOperation()
                    }
                } else if model.isConnected {
                    Button("Reconnect Jam", systemImage: "arrow.clockwise") {
                        model.startReconnect()
                    }
                    Button("Disconnect Jam", systemImage: "xmark.circle") {
                        Task { await model.disconnect() }
                    }
                } else {
                    Button(model.status == .reconnectRequired ? "Reconnect Jam" : "Connect Jam", systemImage: "link") {
                        model.startConnect()
                    }
                }
            }

            Text("Browser sign-in grants read-only access to the fixed Jam MCP endpoint. Imported evidence stays in the local library after disconnecting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await model.restoreConnection() }
    }

    private var statusIcon: String {
        switch model.status {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .reconnectRequired: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "link.badge.plus"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .failed, .reconnectRequired: .orange
        default: .secondary
        }
    }
}
