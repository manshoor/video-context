import Foundation
import Testing
@testable import VideoContextCore

struct ProjectDecisionWorkflowTests {
    @Test func confirmedAnswerIsSharedWithoutOverwritingContradictions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "shared-decisions-\(UUID())")
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Decisions")
        let batch = try await store.createProjectRequest(projectID: project.id, title: "Requests", text: "Preview stays visible")
        var answered = TaskQuestion(question: "Should preview remain visible?"); answered.answer = "No, hide it"; answered.disagreement = "Existing design says otherwise"
        let a = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "First", behavior: "Keep preview visible", checks: [.init(text: "Preview visible")], questions: [.init(question: "Should preview remain visible?")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let b = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Second", behavior: "Explain preview behavior", checks: [.init(text: "Preview follows decision")], questions: [answered], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        var investigation = TaskQuestion(question: "Should preview remain visible?"); investigation.category = .investigation
        _ = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Inspect code", behavior: "Investigate current preview behavior", checks: [.init(text: "Report code evidence")], questions: [investigation], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let groups = try await store.proposeProjectQuestionGroups(projectID: project.id)
        #expect(groups.count == 1)
        #expect(groups[0].questionIDs.count == 2)
        #expect(try await store.proposeProjectQuestionGroups(projectID: project.id).isEmpty)
        try await store.resolveProjectQuestionGroup(id: groups[0].id, projectID: project.id, accept: true)
        var decision = try #require(try await store.projectDocumentation(projectID: project.id).decisions.first)
        decision.answer = "Yes"; decision.state = .confirmed
        decision = try await store.saveProjectDecision(decision, expectedRevision: decision.revision)
        #expect(try await store.applyProjectDecision(id: decision.id, projectID: project.id, expectedRevision: decision.revision) == 1)
        let tasks = try await store.feedbackSnapshot(id: batch.id).tasks
        #expect(tasks.first { $0.id == a.id }?.content.questions[0].answer == "Yes")
        #expect(tasks.first { $0.id == a.id }?.approvedRevision == nil)
        #expect(tasks.first { $0.id == b.id }?.content.questions[0].answer == "No, hide it")
        #expect(tasks.first { $0.id == b.id }?.content.questions[0].disagreement.contains("Existing design says otherwise") == true)
    }

    @Test func documentationRequestsKeepProvenanceAndLoseEligibilityWhenEvidenceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "document-requests-\(UUID())")
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Product")
        let url = root.appending(path: "requirements.md")
        try "# Checkout\n\nKeep preview visible.".write(to: url, atomically: true, encoding: .utf8)
        let imported = try await store.importDocumentSource(projectID: project.id, sourceURL: url, paths: paths)
        let section = ProjectDocumentationSection(title: "Preview", body: "Keep visible", classification: .requested, evidence: [.document(sourceID: imported.source.id, revision: 1, locator: imported.revision.units[0].locator)])
        let document = try await store.createDocumentationDraft(projectID: project.id, title: "Checkout", slug: "checkout", sections: [section])
        _ = try await store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: 1)
        let batch = try await store.createDocumentationRequest(projectID: project.id, documentID: document.id, expectedRevision: 1, sectionIDs: [section.id])
        #expect(batch.videoID == nil)
        #expect(batch.comments.allSatisfy { $0.kind == .request })
        #expect(batch.sources[0].documentID == document.id)
        #expect(batch.sources[0].documentRevision == 1)
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks.isEmpty)
        let other = try await store.createFeedbackProject(name: "Other product")
        let move = try await store.previewProjectMove(source: .feedback(batch.id), destinationProjectID: other.id)
        #expect(move.affectedDocumentation.map(\.id).contains(document.id))
        #expect(move.blockedReason != nil)
        await #expect(throws: (any Error).self) { try await store.moveProjectSources(move) }
        #expect(try await store.feedbackSnapshot(id: batch.id).batch.projectID == project.id)
        let task = try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Implement preview", behavior: "Keep preview visible", checks: [.init(text: "Preview visible")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        try await store.approveFeedbackTasks(batchID: batch.id, expectedBatchRevision: batch.revision, expectedTaskRevisions: [task.id: task.revision])
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks[0].canImplement(in: batch))
        try "# Checkout\n\nHide preview.".write(to: url, atomically: true, encoding: .utf8)
        _ = try await store.importDocumentSource(projectID: project.id, sourceURL: url, paths: paths)
        #expect(try await store.feedbackSnapshot(id: batch.id).tasks[0].canImplement(in: batch) == false)
        await #expect(throws: (any Error).self) { try await store.createDocumentationRequest(projectID: project.id, documentID: document.id, expectedRevision: 1, sectionIDs: [section.id]) }
    }

    @Test func changedQuestionsRejectAnOldGroupAndCanBeProposedAgain() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "stale-question-group-\(UUID())"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Questions")
        let batch = try await store.createProjectRequest(projectID: project.id, title: "Preview", text: "Keep preview visible")
        var tasks: [FeedbackTask] = []
        for title in ["First", "Second"] {
            tasks.append(try await store.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision,
                content: .init(title: title, behavior: "Keep preview", checks: [.init(text: "Visible")], questions: [.init(question: "Keep preview visible?")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision))
        }
        let group = try #require(try await store.proposeProjectQuestionGroups(projectID: project.id).first)
        var edit = tasks[0]; edit.content.behavior = "Keep preview visible during retries"
        _ = try await store.saveFeedbackTask(edit, expectedRevision: edit.revision, expectedBatchRevision: batch.revision)
        await #expect(throws: TaskContextError.conflict) { try await store.resolveProjectQuestionGroup(id: group.id, projectID: project.id, accept: true) }
        #expect(try await store.projectDocumentation(projectID: project.id).decisions.isEmpty)
        let refreshed = try await store.proposeProjectQuestionGroups(projectID: project.id)
        #expect(refreshed.count == 1)
        #expect(refreshed[0].id != group.id)
    }

    @Test func changedDecisionEvidenceRequiresExplicitReview() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: "decision-evidence-\(UUID())"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Decision evidence")
        let file = paths.root.appending(path: "requirements.md")
        try "# Preview\nKeep visible".write(to: file, atomically: true, encoding: .utf8)
        let source = try await store.importDocumentSource(projectID: project.id, sourceURL: file, paths: paths)
        let decision = try await store.saveProjectDecision(.init(projectID: project.id, key: "preview", question: "Keep visible?", answer: "Yes",
            evidence: [.document(sourceID: source.source.id, revision: 1, locator: .init(heading: "Preview"))], state: .confirmed))
        try "# Preview\nKeep visible during retries".write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.importDocumentSource(projectID: project.id, sourceURL: file, paths: paths)
        #expect(try await store.projectDocumentation(projectID: project.id).decisions[0].evidenceNeedsReview == true)
        await #expect(throws: (any Error).self) { try await store.applyProjectDecision(id: decision.id, projectID: project.id, expectedRevision: 1) }
        var reviewed = decision; reviewed.evidence = try await store.currentDecisionEvidence(decision)
        _ = try await store.saveProjectDecision(reviewed, expectedRevision: 1)
        #expect(try await store.projectDocumentation(projectID: project.id).decisions[0].evidenceNeedsReview == false)
    }

    @Test func documentationDecisionLinksRequireCurrentConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "documentation-decision-links-\(UUID())")
        let paths = try LibraryPaths(root: root), store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Decision documentation")
        let file = root.appending(path: "requirements.md")
        try "# Preview\n\nKeep the preview visible.".write(to: file, atomically: true, encoding: .utf8)
        let imported = try await store.importDocumentSource(projectID: project.id, sourceURL: file, paths: paths)
        let unit = try #require(imported.revision.units.first)
        let evidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision, locator: unit.locator)
        let decision = try await store.saveProjectDecision(.init(projectID: project.id, key: "preview", question: "Keep the preview visible?", answer: "Yes", evidence: [evidence], state: .confirmed))
        let section = ProjectDocumentationSection(id: "preview-decision", title: "Preview", body: "The preview stays visible.", classification: .confirmedDecision, evidence: [evidence], decisionIDs: [decision.id])
        let document = try await store.createDocumentationDraft(projectID: project.id, title: "Preview guide", slug: "preview-guide", sections: [section])
        _ = try await store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)

        let request = try await store.createDocumentationRequest(projectID: project.id, documentID: document.id, expectedRevision: document.currentRevision, sectionIDs: [section.id])
        #expect(request.sources.first?.documentID == document.id)
        #expect(request.sources.first?.documentRevision == document.currentRevision)
        #expect(request.sources.first?.documentSectionIDs == [section.id])

        let proposal = ProjectDocumentationProposal(projectID: project.id, documentID: document.id, expectedDocumentRevision: document.currentRevision,
            title: document.title, slug: document.slug, markdown: document.markdown, sections: [section], diff: .init(changedSectionIDs: [section.id]), evidence: [evidence])
        let savedProposal = try await store.proposeDocumentation(proposal)

        var unresolved = decision
        unresolved.answer = ""
        unresolved.state = .unresolved
        _ = try await store.saveProjectDecision(unresolved, expectedRevision: decision.revision)

        let snapshot = try await store.projectDocumentation(projectID: project.id)
        #expect(snapshot.documentation.first(where: { $0.id == document.id })?.isReviewed == false)
        #expect(snapshot.proposals.first(where: { $0.id == savedProposal.id })?.isStale == true)
        await #expect(throws: ProjectDocumentationStoreError.self) {
            try await store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)
        }
        await #expect(throws: TaskContextError.self) {
            try await store.createDocumentationRequest(projectID: project.id, documentID: document.id, expectedRevision: document.currentRevision, sectionIDs: [section.id])
        }

        // New proposals can still be drafted against readable source material,
        // but acceptance must revalidate the linked decision at the current
        // revision instead of silently publishing it.
        let postChangeProposal = try await store.proposeDocumentation(.init(projectID: project.id, documentID: document.id, expectedDocumentRevision: document.currentRevision,
            title: document.title, slug: document.slug, markdown: document.markdown, sections: [section], diff: .init(changedSectionIDs: [section.id]), evidence: [evidence]))
        let accepted = try await store.reviewDocumentationProposal(proposalID: postChangeProposal.id, decision: .accept, expectedDocumentRevision: document.currentRevision)
        #expect(accepted.state == ProjectDocumentationProposalState.pending)
        #expect(accepted.isStale)

        let firstDocumentProposal = try await store.proposeDocumentation(.init(projectID: project.id, documentID: "new-preview-guide", expectedDocumentRevision: 0,
            title: "New preview guide", slug: "new-preview-guide", markdown: "", sections: [section], diff: .init(addedSectionIDs: [section.id]), evidence: [evidence]))
        let firstDocumentResult = try await store.reviewDocumentationProposal(proposalID: firstDocumentProposal.id, decision: .accept)
        #expect(firstDocumentResult.state == ProjectDocumentationProposalState.pending)
        #expect(firstDocumentResult.isStale)
    }
}
