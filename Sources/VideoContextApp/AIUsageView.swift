import SwiftUI
import VideoContextCore

private enum UsagePeriod: String, CaseIterable {
    case today = "Today", week = "7 days", month = "30 days", all = "All time"
    var since: Date? {
        switch self {
        case .today: Calendar.current.startOfDay(for: .now)
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: .now)
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: .now)
        case .all: nil
        }
    }
}

struct AIUsageView: View {
    @Bindable var model: AppModel
    let scope: UsagePresentation
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: UsageSnapshot?
    @State private var error: String?
    @State private var videoID: String
    @State private var provider = ""
    @State private var modelID = ""
    @State private var operation = ""
    @State private var period: UsagePeriod
    @State private var focusedRun: String?
    @State private var expanded: Set<String> = []
    @State private var clearing = UsageClearingModel()

    init(model: AppModel, scope: UsagePresentation) {
        self.model = model; self.scope = scope
        _videoID = State(initialValue: scope.videoID ?? "")
        _period = State(initialValue: scope.videoID != nil || scope.runID != nil ? .all : .month)
        _focusedRun = State(initialValue: scope.runID)
        _expanded = State(initialValue: Set(scope.runID.map { [$0] } ?? []))
    }
    private var filtered: UsageSnapshot? {
        snapshot.map { UsageQuery(videoID: videoID.isEmpty ? nil : videoID, runID: focusedRun,
            provider: InferenceProvider(rawValue: provider), model: modelID.isEmpty ? nil : modelID,
            operation: UsageOperation(rawValue: operation), since: period.since).filter($0) }
    }
    private var focusedUsageUnavailable: Bool {
        guard let focusedRun, let snapshot else { return false }
        return !snapshot.runs.contains { $0.id == focusedRun }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceStyle.padding) {
            HStack {
                Label("AI Usage", systemImage: "chart.bar.xaxis").font(.title2.bold())
                Spacer()
                Menu("Clear usage history", systemImage: "trash") {
                    if !videoID.isEmpty {
                        Button("This recording…", role: .destructive) { prepareClear(.recording(videoID)) }
                            .disabled(!hasFinishedHistory(videoID: videoID))
                    }
                    Button("Entire library…", role: .destructive) { prepareClear(.library) }
                        .disabled(!hasFinishedHistory())
                }
                .disabled(clearing.isBusy || snapshot == nil)
                .help("Clear finished usage after confirmation. Active runs are retained.")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Local history of this library’s AI requests. Token totals are shared by the tasks generated in each run; they are not per-card estimates or monetary costs.")
                .font(.caption).foregroundStyle(.secondary)
            if focusedRun != nil {
                HStack { Text("Showing the shared generation run.").font(.callout); Button("Show all runs") { focusedRun = nil } }
            }
            HStack {
                Picker("Recording", selection: $videoID) {
                    Text("All recordings and model tests").tag("")
                    ForEach((snapshot?.recordingTitles ?? [:]).keys.sorted(), id: \.self) { id in Text(snapshot?.recordingTitles[id] ?? id).tag(id) }
                }
                Picker("Date", selection: $period) { ForEach(UsagePeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 180)
            }
            HStack {
                Picker("Provider", selection: $provider) {
                    Text("All providers").tag("")
                    ForEach([InferenceProvider.openAI, .lmStudio, .localWhisper, .claude, .deepSeek], id: \.self) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Model", selection: $modelID) {
                    Text("All models").tag("")
                    ForEach(Array(Set(snapshot?.attempts.flatMap { [$0.requestedModel, $0.resolvedModel].compactMap { $0 } } ?? [])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Operation", selection: $operation) {
                    Text("All operations").tag("")
                    ForEach(UsageOperation.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
            }
            if clearing.isBusy { ProgressView("Updating usage history…").controlSize(.small) }
            if let success = clearing.success { Label(success, systemImage: "checkmark.circle").font(.callout) }
            if let message = clearing.error { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let message = model.usageStorageError ?? error { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let filtered {
                let tokenAttempts = filtered.attempts.filter { !$0.usesAudioAccounting }
                if !focusedUsageUnavailable {
                HStack(spacing: 12) {
                    metric("Input tokens", tokenAttempts.map { $0.tokens.input })
                    metric("Output tokens", tokenAttempts.map { $0.tokens.output })
                    metric("Total tokens", tokenAttempts.map { $0.tokens.total })
                    VStack(alignment: .leading) { Text("Inference requests").font(.caption); Text(filtered.attempts.count.formatted()).font(.title2.monospacedDigit()) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary, in: .rect(cornerRadius: 8))
                }
                Text("Counts appear when responses arrive. Missing usage is “Not reported”; partial totals include only known counts. Audio-only transcription is shown in seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if focusedUsageUnavailable {
                    ContentUnavailableView("Usage history no longer available", systemImage: "chart.bar",
                        description: Text("This run’s usage is no longer stored in this library. Its tasks and recording evidence remain available."))
                } else if filtered.runs.isEmpty {
                    ContentUnavailableView("No matching AI usage", systemImage: "chart.bar", description: Text("Change the filters or process a recording. New AI requests appear here as they are recorded."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filtered.runs) { run in
                                runRow(run, attempts: filtered.attempts.filter { $0.runID == run.id })
                            }
                        }
                    }
                }
            } else if error == nil { ProgressView("Loading usage…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(WorkspaceStyle.padding)
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 560, idealHeight: 720)
        .task(id: model.usageRevision) { await refresh() }
        .alert("Clear usage history?", isPresented: $clearing.showsConfirmation) {
            Button("Cancel", role: .cancel) { clearing.cancel() }
            Button("Clear history", role: .destructive) { Task { await clearing.confirm(model: model) } }
        } message: { Text(clearing.confirmationText) }
    }
    private func metric(_ name: String, _ values: [Int?]) -> some View {
        let total = UsageTotal(values)
        let incomplete = filtered?.runs.contains(where: \.accountingIncomplete) == true
        return VStack(alignment: .leading) {
            Text(name).font(.caption)
            Text(total.value?.formatted() ?? "Not reported").font(.title2.monospacedDigit())
            if total.partial || incomplete { Text("Partial total").font(.caption).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary, in: .rect(cornerRadius: 8))
    }
    private func runRow(_ run: UsageRun, attempts: [UsageAttempt]) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(run.id) }, set: { if $0 { expanded.insert(run.id) } else { expanded.remove(run.id) } })) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(run.id).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Clear this run…", systemImage: "trash", role: .destructive) { prepareClear(.run(run.id)) }
                        .disabled(clearing.isBusy || !run.outcome.permitsUsageClearing)
                        .help(run.outcome.permitsUsageClearing ? "Clear all usage for this run after confirmation" : "Active runs cannot be cleared")
                }
                if let id = run.videoID { Text("Context ID: \(id)").font(.caption.monospaced()).textSelection(.enabled) }
                if let id = run.feedbackBatchID { Text("Feedback batch: \(id)").font(.caption.monospaced()).textSelection(.enabled) }
                if let previous = run.resumedFrom { linkedRun("Continues an earlier attempt", id: previous) }
                if run.cachedBatches > 0 { Text("\(run.cachedBatches) cached batches reused · no new inference for those batches").font(.caption) }
                ForEach(run.reusedRuns, id: \.self) { linkedRun("Earlier usage for reused evidence", id: $0) }
                if run.accountingIncomplete { Text("Accounting is incomplete for this run.").foregroundStyle(.orange) }
                if attempts.isEmpty { Text("No inference requests recorded for this run.").foregroundStyle(.secondary) }
                ForEach(attempts) { attempt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(attempt.stage.label) · \(attempt.provider.displayName) · \(attempt.provider.isLocal ? "Local" : "Cloud")").font(.callout.bold())
                        Text("Model: \(attempt.requestedModel)\(attempt.resolvedModel.map { $0 == attempt.requestedModel ? "" : " → \($0)" } ?? "")").font(.caption).textSelection(.enabled)
                        if attempt.usesAudioAccounting {
                            Text("Audio: \(attempt.tokens.audioSeconds.map { String(format: "%.1f seconds", $0) } ?? "Not reported") · Tokens: not applicable").font(.caption)
                        } else {
                            Text("Input: \(count(attempt.tokens.input)) · Output: \(count(attempt.tokens.output)) · Total: \(count(attempt.tokens.total))").font(.callout.monospacedDigit())
                            if attempt.tokens.cacheRead != nil || attempt.tokens.cacheWrite != nil || attempt.tokens.reasoning != nil {
                                Text("Included breakdown — cache read: \(count(attempt.tokens.cacheRead)); cache write: \(count(attempt.tokens.cacheWrite)); reasoning: \(count(attempt.tokens.reasoning))").font(.caption)
                            }
                        }
                        Text("\(attempt.outcome.label) · \(duration(start: attempt.startedAt, end: attempt.finishedAt))\(attempt.httpStatus.map { " · HTTP \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(run.operation.label) · \(run.videoID.flatMap { snapshot?.recordingTitles[$0] } ?? run.feedbackBatchID.flatMap { snapshot?.feedbackTitles[$0] } ?? run.projectID.flatMap { id in model.feedbackProjects.first { $0.id == id }?.name } ?? "Model test")").font(.headline)
                Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.provider.displayName) · \(run.model) · \(run.outcome.label)").font(.caption).foregroundStyle(.secondary)
                let eligible = attempts.filter { !$0.usesAudioAccounting }
                Text("Input \(total(eligible.map { $0.tokens.input })) · Output \(total(eligible.map { $0.tokens.output })) · Total \(total(eligible.map { $0.tokens.total })) · \(duration(start: run.startedAt, end: run.operation == .earlierUsage ? nil : run.finishedAt))").font(.caption.monospacedDigit())
            }
        }.padding(12).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
    private func linkedRun(_ title: String, id: String) -> some View {
        VStack(alignment: .leading) {
            Button(title) { focusedRun = id; expanded.insert(id); provider = ""; modelID = ""; operation = ""; period = .all }.font(.caption)
            if snapshot?.runs.contains(where: { $0.id == id }) == false {
                Text("Usage history no longer available").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func prepareClear(_ scope: UsageClearScope) {
        Task { await clearing.prepare(scope, model: model) }
    }
    private func hasFinishedHistory(videoID: String? = nil) -> Bool {
        snapshot?.runs.contains { $0.outcome.permitsUsageClearing && (videoID == nil || $0.videoID == videoID) } == true
    }
    private func count(_ value: Int?) -> String { value?.formatted() ?? "Not reported" }
    private func total(_ values: [Int?]) -> String {
        let sum = UsageTotal(values)
        return count(sum.value) + (sum.partial ? " (partial)" : "")
    }
    private func duration(start: Date, end: Date?) -> String {
        end.map { String(format: "%.1fs", max(0, $0.timeIntervalSince(start))) } ?? "Duration not yet reported"
    }
    private func refresh() async {
        do {
            guard let store = model.store else { throw TaskContextError.invalid("Library unavailable") }
            snapshot = try await store.usageSnapshot(); error = nil
        }
        catch { self.error = "Usage history could not be read. Check library access and disk space." }
    }
}
