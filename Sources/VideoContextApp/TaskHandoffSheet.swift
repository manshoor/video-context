import SwiftUI
import VideoContextCore

struct TaskHandoffSheet: View {
    @Bindable var model: AppModel
    @State private var snapshot: TaskLibrarySnapshot
    let selected: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var mode = TaskHandoffMode.plan
    @State private var text = ""
    @State private var error: String?
    @State private var copying = false
    init(model: AppModel, snapshot: TaskLibrarySnapshot, selected: Set<String>) {
        self.model = model; self.selected = selected
        _snapshot = State(initialValue: snapshot)
    }
    private var implementAllowed: Bool { snapshot.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.canImplement(snapshot.video) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy selected tasks").font(.title2.bold())
            HStack {
                ForEach(TaskHandoffMode.allCases, id: \.self) { item in
                    Button(item.rawValue) { mode = item }
                        .buttonStyle(.bordered)
                        .tint(mode == item ? Color.accentColor : .secondary)
                        .accessibilityAddTraits(mode == item ? .isSelected : [])
                        .disabled(item == .implement && !implementAllowed)
                }
            }.accessibilityElement(children: .contain).accessibilityLabel("Agent action")
            if !implementAllowed { Text("Implementation requires current, reviewed tasks with all blocking questions resolved.").font(.callout).foregroundStyle(.orange) }
            Text("You can edit this message. Keep its exact IDs, revisions and scope instructions.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced())
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Reset preview") { rebuild() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy message", systemImage: "doc.on.clipboard") {
                    copying = true
                    Task {
                        if await model.copyTaskHandoff(snapshot: snapshot, selected: selected, mode: mode, text: text) { dismiss() }
                        else { error = model.errorMessage }
                        copying = false
                    }
                }.buttonStyle(.borderedProminent).disabled(error != nil || text.isEmpty || copying)
            }
        }.padding(20).frame(minWidth: 700, idealWidth: 800, minHeight: 550, idealHeight: 700)
        .onAppear { rebuild() }.onChange(of: mode) { _, _ in rebuild() }
    }
    private func rebuild() {
        do { text = try TaskHandoff.message(snapshot: snapshot, selectedIDs: selected, mode: mode); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct TaskProposalSheet: View {
    @Bindable var model: AppModel
    let proposal: TaskProposal
    let existing: VideoTask?
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var showGenerationUsage = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review proposed \(proposal.kind.rawValue)").font(.title2.bold())
            Text("Applying changes keeps the task ID and clears its review. Your previous revisions remain in local history.").font(.callout)
            if proposal.generationRunID != nil {
                Button("View generation usage", systemImage: "chart.bar.xaxis") { showGenerationUsage = true }
                Text("Shared usage for all proposals from this generation run.").font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                if let existing { ScrollView { VStack(alignment: .leading) { Text("Current task").font(.title3); TaskContentSummary(content: existing.content) }.padding() }.frame(minWidth: 260) }
                ScrollView {
                    VStack(alignment: .leading) {
                        Text("Proposed task").font(.title3)
                        if let content = proposal.content { TaskContentSummary(content: content) }
                        else { Text("Archive this task. Its ID, requirements and history remain saved.") }
                    }.padding()
                }.frame(minWidth: 260)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Button("Reject proposal") { resolve(apply: false) }
                Spacer()
                if existing != nil { Button("Keep current wording") { resolve(apply: true, keep: true) } }
                Button(proposal.kind == .addition ? "Add task" : "Apply proposal") { resolve(apply: true) }.buttonStyle(.borderedProminent)
            }.disabled(busy)
        }.padding(20).frame(minWidth: 700, idealWidth: 1000, minHeight: 550, idealHeight: 700)
        .sheet(isPresented: $showGenerationUsage) {
            AIUsageView(model: model, scope: .init(videoID: proposal.videoID, runID: proposal.generationRunID))
        }
    }
    private func resolve(apply: Bool, keep: Bool = false) {
        busy = true
        Task {
            await model.resolveProposal(proposal, apply: apply, keepWording: keep)
            if model.taskLibrary?.proposals.contains(where: { $0.id == proposal.id }) == false { dismiss() }
            else { failure = model.errorMessage }
            busy = false
        }
    }
}
