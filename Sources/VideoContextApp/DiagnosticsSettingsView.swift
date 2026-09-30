import SwiftUI
import UniformTypeIdentifiers
import VideoContextCore

struct DiagnosticsSettingsSection: View {
    @Bindable var model: AppModel
    @State private var showExport = false
    var body: some View {
        Section("Diagnostics") {
            if model.diagnosticsEnabled {
                Label("Diagnostic logging on", systemImage: "waveform.path.ecg").foregroundStyle(.orange)
                if let expiry = model.diagnosticsExpiry { Text("Stops automatically \(expiry.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                Button("Stop logging", systemImage: "stop.circle") { Task { await model.stopDiagnostics() } }
            } else {
                Button("Enable logging for 24 hours", systemImage: "waveform.path.ecg") { Task { await model.enableDiagnostics() } }
            }
            Text(model.diagnosticsHealth).font(.caption).foregroundStyle(.secondary)
            Text("Logs stay on this Mac. They exclude recording content and credentials. Enable capture before reproducing a problem; earlier events cannot be recovered.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open logs folder", systemImage: "folder") { model.openDiagnosticsFolder() }
                Button("Export diagnostics", systemImage: "square.and.arrow.up") { showExport = true }
            }
        }
        .disabled(model.diagnostics == nil)
        .task { await model.refreshDiagnostics() }
        .sheet(isPresented: $showExport) { DiagnosticsExportSheet(model: model) }
    }
}

