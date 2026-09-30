import Foundation
import VideoContextCore

extension AppModel {
    func groupProjectQuestions() async {
        guard let store, let projectID = selectedProjectID else { return }
        do {
            let groups = try await store.proposeProjectQuestionGroups(projectID: projectID)
            documentationProgress = groups.isEmpty ? "No repeated product questions found." : "Review \(groups.count) suggested question groups."
            await loadSelection()
        } catch { errorMessage = error.localizedDescription }
    }
    func resolveQuestionGroup(_ group: ProjectQuestionGroupProposal, accept: Bool) async {
        guard let store else { return }
        do { try await store.resolveProjectQuestionGroup(id: group.id, projectID: group.projectID, accept: accept); await loadSelection() }
        catch { errorMessage = error.localizedDescription }
    }
    func saveSharedDecision(projectID: String, question: String, answer: String) async -> Bool {
        guard let store else { return false }
        do {
            _ = try await store.saveProjectDecision(.init(projectID: projectID, key: VideoContextStore.normalizedProductQuestion(question), question: question,
                answer: answer, state: answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unresolved : .confirmed))
            await loadSelection(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func updateSharedDecision(_ decision: ProjectDecision, answer: String) async {
        guard let store else { return }
        var next = decision; next.answer = answer; next.state = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unresolved : .confirmed
        do { _ = try await store.saveProjectDecision(next, expectedRevision: decision.revision); await loadSelection() }
        catch { errorMessage = error.localizedDescription }
    }
    func applySharedDecision(_ decision: ProjectDecision) async {
        guard let store else { return }
        do {
            let count = try await store.applyProjectDecision(id: decision.id, projectID: decision.projectID, expectedRevision: decision.revision)
            documentationProgress = "Applied to \(count) unanswered questions. Review the changed tasks before implementation."
            await loadSelection()
        } catch { errorMessage = error.localizedDescription }
    }
    func createRequestFromDocumentation(sectionIDs: Set<String>) async {
        guard let store, let document = documentationDraft?.document, documentationDraft?.dirty == false else { return }
        let origin = workspaceLocation
        do {
            let batch = try await store.createDocumentationRequest(projectID: document.projectID, documentID: document.id, expectedRevision: document.currentRevision, sectionIDs: sectionIDs)
            if workspaceLocation == origin {
                var next = origin; next.section = .feedback; next.feedbackID = batch.id; next.task = nil
                requestNavigation(next)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
