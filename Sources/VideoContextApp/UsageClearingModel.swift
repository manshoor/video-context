import Foundation
import Observation
import VideoContextCore

@MainActor @Observable
final class UsageClearingModel {
    private(set) var preview: UsageClearPreview?
    private(set) var confirmationText = ""
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var success: String?
    var showsConfirmation = false
    private var previewStore: VideoContextStore?

    func prepare(_ scope: UsageClearScope, model: AppModel) async {
        guard !isBusy else { return }
        isBusy = true; error = nil; success = nil; preview = nil
        defer { isBusy = false }
        do {
            guard let store = model.store else { throw TaskContextError.invalid("Library unavailable") }
            let prepared = try await store.prepareUsageClear(scope)
            guard !prepared.isEmpty else { throw UsageClearError.noFinishedHistory }
            let snapshot = try await store.usageSnapshot()
            let target: String
            switch scope {
            case .library: target = "Entire library — all recordings and model tests."
            case .recording(let id): target = "Recording: \(snapshot.recordingTitles[id] ?? "Unavailable")\nContext ID: \(id)"
            case .run(let id):
                let run = snapshot.runs.first { $0.id == id }
                let recording = run?.videoID.map { "Recording: \(snapshot.recordingTitles[$0] ?? "Unavailable")\nContext ID: \($0)\n" } ?? ""
                target = recording + "Run: \(id)\n\(run?.model ?? "") · \(run?.startedAt.formatted(date: .abbreviated, time: .shortened) ?? "")"
            }
            confirmationText = """
            \(target)

            Remove \(counts(prepared)).
            Retain \(counted(prepared.retainedActiveRunCount, "active run")) and their requests. New history and work that finishes after this preview will also remain.

            Includes all dates, providers, and operations in this scope, even when hidden by filters.

            This permanently removes local usage history and cannot be undone. Videos, transcripts, briefs, tasks, screenshots, and processing checkpoints remain intact.
            """
            preview = prepared; previewStore = store; showsConfirmation = true
        } catch { self.error = message(for: error) }
    }

    func cancel() {
        guard !isBusy else { return }
        showsConfirmation = false; preview = nil; previewStore = nil
    }

    func confirm(model: AppModel) async {
        guard !isBusy, let preview, let store = previewStore else { return }
        isBusy = true; showsConfirmation = false; error = nil; success = nil
        defer { isBusy = false; self.preview = nil; previewStore = nil }
        do {
            guard model.store === store else { throw UsageClearError.stalePreview }
            try await store.clearUsage(preview)
            success = "Cleared \(counts(preview)). Other history was retained."
            model.usageRevision += 1
            await model.loadSelection()
        } catch { self.error = message(for: error) }
    }

    private func counted(_ value: Int, _ label: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? label : (plural ?? label + "s"))"
    }
    private func counts(_ preview: UsageClearPreview) -> String {
        "\(counted(preview.runCount, "run")), \(counted(preview.requestCount, "inference request")), and \(counted(preview.earlierEntryCount, "earlier usage entry", plural: "earlier usage entries"))"
    }
    private func message(for error: Error) -> String {
        switch error {
        case UsageClearError.stalePreview:
            "Usage history changed. Nothing was cleared. Refresh and open a new confirmation."
        case UsageClearError.noFinishedHistory:
            "There is no finished usage history to clear. Active runs are retained."
        default:
            "Usage history could not be cleared. Nothing was removed. Check library access and disk space, then retry."
        }
    }
}
