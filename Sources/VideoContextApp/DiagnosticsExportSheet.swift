import SwiftUI
import UniformTypeIdentifiers
import VideoContextCore

struct DiagnosticsExportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var allRecordings = false
    @State private var contextID: String?
    @State private var days = 1
    @State private var fullReports = false
    @State private var stage: DiagnosticExportStage?
    @State private var exportTask: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export diagnostics").font(.title2.bold())
            Form {
                Picker("Recordings", selection: $allRecordings) {
                    if contextID != nil { Text("Selected Context ID").tag(false) }
                    Text("All recordings").tag(true)
                }
                if !allRecordings, let id = contextID { Text(id).font(.caption.monospaced()).textSelection(.enabled) }
                Picker("Time range", selection: $days) {
                    Text("Last 24 hours").tag(1)
                    Text("Last 3 days").tag(3)
                    Text("Last 7 days").tag(7)
                }
                Toggle("Include full macOS crash reports", isOn: $fullReports)
                if fullReports {
                    Label("Full reports may contain private paths, identifiers, and other details. Review the ZIP before sharing.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.disabled(exportTask != nil)
            Text("Includes: event logs, readable timeline, build/OS details, recording status and checkpoint counts, and safe crash summaries. App-wide events and crashes are included for either recording scope.")
                .font(.callout)
            Text(fullReports ? "Other export files exclude recording content and credentials. Nothing is uploaded." : "No video, transcript, OCR, brief, task wording, database, or credentials. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            if exportTask != nil {
                HStack { ProgressView().controlSize(.small); Text("Exporting \(stage?.rawValue ?? "diagnostics")…") }
            }
            HStack {
                Spacer()
                Button(exportTask == nil ? "Close" : "Cancel export") {
                    if let exportTask { exportTask.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("Save ZIP…", systemImage: "square.and.arrow.up") { save() }
                    .buttonStyle(.borderedProminent).disabled(exportTask != nil)
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 580, minHeight: 430)
        .onAppear { contextID = model.selectedVideoID; allRecordings = contextID == nil }
        .interactiveDismissDisabled(exportTask != nil)
        .onDisappear { exportTask?.cancel() }
    }
    private func save() {
        guard let diagnostics = model.diagnostics else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "VideoContext-diagnostics-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).zip"
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            let options = DiagnosticExportOptions(videoID: allRecordings ? nil : contextID, days: days, includeFullCrashReports: fullReports)
            let exporter = DiagnosticExporter(service: diagnostics, store: model.store)
            message = nil
            exportTask = Task {
                do {
                    let result = try await exporter.export(to: destination, options: options) { value in
                        await MainActor.run { stage = value }
                    }
                    message = "Exported \(result.eventCount) events. " + (result.omissions.isEmpty ? "Ready to review and share." : result.omissions.joined(separator: " "))
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch is CancellationError { message = "Export cancelled. No partial ZIP was saved." }
                catch { message = "Export could not be saved. Check destination access and free disk space." }
                exportTask = nil
            }
        }
    }
}
