import SwiftUI
import VideoContextCore

struct ProjectDecisionsView: View {
    @Bindable var model: AppModel
    let projectID: String
    @State private var question = ""
    @State private var answer = ""
    @State private var saving = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Decisions & questions").font(.title2.bold())
                    Spacer()
                    Button("Group repeated questions") { Task { await model.groupProjectQuestions() } }
                }
                Text("Confirm an answer once, then apply it to linked questions. Existing answers and disagreements remain visible.").foregroundStyle(.secondary)
                ForEach(model.documentation.decisions) { decision in
                    ProjectDecisionCard(model: model, decision: decision)
                }
                if !model.documentation.questionGroups.filter({ $0.state == .pending }).isEmpty {
                    Divider()
                    Text("Suggested question groups").font(.headline)
                    ForEach(model.documentation.questionGroups.filter { $0.state == .pending }) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.normalizedQuestion)
                            Text("\(group.questionIDs.count) questions across \(Set(group.taskIDs).count) tasks").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Use as shared question") { Task { await model.resolveQuestionGroup(group, accept: true) } }
                                Button("Keep separate") { Task { await model.resolveQuestionGroup(group, accept: false) } }
                            }
                        }.padding(12).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                    }
                }
                Divider()
                Text("Add a shared decision").font(.headline)
                TextField("Product question", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
                TextField("Answer (leave empty to keep open)", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
                Button(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Save question" : "Save confirmed decision") {
                    saving = true
                    Task {
                        if await model.saveSharedDecision(projectID: projectID, question: question, answer: answer) { question = ""; answer = "" }
                        saving = false
                    }
                }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectDecisionCard: View {
    @Bindable var model: AppModel
    let decision: ProjectDecision
    @State private var answer = ""
    @State private var saving = false
    @State private var loadedRevision: Int?
    @State private var savedAnswer = ""
    @State private var currentEvidence: [ProjectEvidenceReference]?
    @State private var evidenceError: String?
    @State private var confirmEvidence = false
    @State private var confirmManualDecision = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(decision.question).font(.headline); Spacer(); Text(decision.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
            TextField("Decision answer", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
            ForEach(currentEvidence ?? decision.evidence) { reference in
                Button(reference.displayName) { model.openDocumentationEvidence(reference) }.font(.caption)
            }
            if decision.evidenceNeedsReview == true {
                Label("Evidence changed. Review the current sources before confirming this answer again.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button(currentEvidence == nil ? "Load current evidence" : "Confirm answer with current evidence…") {
                    if currentEvidence != nil { confirmEvidence = true }
                    else {
                        Task {
                            do { currentEvidence = try await model.store?.currentDecisionEvidence(decision); evidenceError = nil }
                            catch { evidenceError = error.localizedDescription }
                        }
                    }
                }
                Button("Confirm as a manual decision…") { confirmManualDecision = true }
            }
            if let evidenceError { Text(evidenceError).foregroundStyle(.red) }
            HStack {
                Button("Save answer") {
                    saving = true
                    Task { await model.updateSharedDecision(decision, answer: answer); saving = false }
                }.disabled(answer == decision.answer || saving)
                Button("Apply to linked unanswered questions") { Task { await model.applySharedDecision(decision) } }
                    .disabled(decision.state != .confirmed || decision.evidenceNeedsReview == true || answer != decision.answer || saving)
            }
        }.padding(12).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
            .task(id: decision.revision) {
                if loadedRevision == nil || answer == savedAnswer {
                    answer = decision.answer; savedAnswer = decision.answer; loadedRevision = decision.revision
                }
            }
            .confirmationDialog("Confirm this answer against the current evidence?", isPresented: $confirmEvidence, titleVisibility: .visible) {
                Button("Confirm answer") {
                    guard let currentEvidence else { return }
                    var updated = decision; updated.evidence = currentEvidence; updated.evidenceNeedsReview = false
                    Task { await model.updateSharedDecision(updated, answer: answer); self.currentEvidence = nil }
                }
            } message: { Text("Linked tasks and documents will need review again. Check the current evidence links before confirming.") }
            .confirmationDialog("Confirm this answer without source citations?", isPresented: $confirmManualDecision, titleVisibility: .visible) {
                Button("Confirm manual decision") {
                    var updated = decision; updated.evidence = []; updated.evidenceNeedsReview = false
                    Task { await model.updateSharedDecision(updated, answer: answer); currentEvidence = nil }
                }
            } message: { Text("The decision will use your written answer and remove its stale citation links. Source files and earlier task and document versions remain intact. Linked work will need review again.") }
    }
}
