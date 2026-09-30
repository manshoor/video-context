import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor struct DocumentationWorkflowTests {
    private func model() -> AppModel {
        AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: "documentation-ui-\(UUID())"), showsDockActivity: false)
    }

    @Test func deletionCancellationAndFailureKeepDraftUntilSuccess() async throws {
        let model = model()
        let library = try #require(model.store)
        let project = try await library.createFeedbackProject(name: "Delete")
        let batch = try await library.createProjectRequest(projectID: project.id, title: "Request", text: "Keep sources")
        let task = try await library.saveFeedbackTask(.init(batchID: batch.id, sourceRevision: batch.revision, content: .init(title: "Delete this", behavior: "Keep sources", checks: [.init(text: "Source remains")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let ref = ProjectTaskReference.feedback(batchID: batch.id, taskID: task.id)
        model.workspaceLocation = .init(root: .project(project.id), task: ref)
        await model.loadSelection()
        let draft = try #require(model.taskDraft); draft.content.title = "Unsaved"
        await model.requestTaskDeletion([ref])
        #expect(model.taskDeletion != nil)
        model.taskDeletion = nil
        #expect(try await library.feedbackSnapshot(id: batch.id).tasks.count == 1)
        #expect(draft.dirty)
        await model.requestTaskDeletion([ref])
        model.taskDeleter = { _ in throw TaskContextError.invalid("Controlled write failure") }
        #expect(await model.confirmTaskDeletion() == false)
        #expect(model.taskDraft === draft)
        #expect(model.taskDeletion?.error?.contains("Controlled") == true)
        model.taskDeleter = nil
        #expect(await model.confirmTaskDeletion())
        #expect(model.taskDraft == nil)
        #expect(try await library.feedbackSnapshot(id: batch.id).tasks.isEmpty)
        #expect(try await library.feedbackSnapshot(id: batch.id).batch.rawText == "Keep sources")
    }

    @Test func documentSaveFailureRetainsDraftAndNavigation() async throws {
        let model = model(), store = try #require(model.store)
        let project = try await store.createFeedbackProject(name: "Drafts")
        let doc = try await store.createDocumentationDraft(projectID: project.id, title: "Requirements", slug: "requirements", sections: [.init(title: "Overview", body: "Original")])
        var route = WorkspaceLocation(root: .project(project.id), section: .documentation)
        route.documentationSelection = .document(doc.id)
        model.workspaceLocation = route; await model.loadSelection()
        let draft = try #require(model.documentationDraft)
        draft.document.sections[0].body = "My edit"
        model.documentationSaver = { _ in throw TaskContextError.invalid("Controlled disk failure") }
        await model.loadSelection()
        #expect(model.documentationDraft === draft)
        model.requestNavigation(.init())
        #expect(model.showUnsavedTaskAlert)
        await model.resolvePendingNavigation(save: true)
        #expect(model.workspaceLocation == route)
        #expect(draft.document.sections[0].body == "My edit")
        #expect(draft.error?.contains("Controlled") == true)
        model.documentationSaver = nil
        #expect(await model.saveDocumentationDraft())
        #expect(draft.document.currentRevision == 2)
        #expect(!draft.dirty)
    }

    @Test func sourcesKeepExplicitProjectAndDoNotGenerateTasks() async throws {
        let model = model(), store = try #require(model.store), paths = try #require(model.paths)
        let a = try await store.createFeedbackProject(name: "A"), b = try await store.createFeedbackProject(name: "B")
        let file = paths.root.appending(path: "request.md")
        try "# Product requirements\n\nKeep preview visible.".write(to: file, atomically: true, encoding: .utf8)
        model.workspaceLocation = .init(root: .project(b.id))
        await model.importProjectSources([file], projectID: a.id)
        #expect(try await store.listProjectDocumentSources(projectID: a.id).count == 1)
        #expect(try await store.listProjectDocumentSources(projectID: b.id).isEmpty)
        #expect(try await store.projectWorkspace(projectID: a.id).tasks.isEmpty)
        #expect(model.selectedProjectID == b.id)
        #expect(!model.documentationBusy)
    }

    @Test func invalidEditorProposalDoesNotHideProjectDocumentation() async throws {
        let model = model(), store = try #require(model.store), paths = try #require(model.paths)
        let project = try await store.createFeedbackProject(name: "Proposal inbox")
        let document = try await store.createDocumentationDraft(projectID: project.id, title: "Still readable", slug: "readable")
        let inbox = try DocumentProposalInbox(url: DocumentProposalInbox.url(in: paths))
        let payload = DocumentEditorProposalPayload(title: "Missing document", sections: [.init(title: "Overview", body: "Proposal")])
        _ = try await inbox.submit(requestID: "missing-document", projectID: project.id, documentID: "missing", expectedRevision: 3, payload: JSONEncoder().encode(payload))
        model.workspaceLocation = .init(root: .project(project.id), section: .documentation, documentationSelection: .document(document.id))
        await model.loadSelection()
        #expect(model.documentationDraft?.document.id == document.id)
        #expect(model.workspaceLoadError == nil)
        #expect(model.documentationInboxIssues.count == 1)
        #expect(try await inbox.pending(projectID: project.id).count == 1)
    }

    @Test func newEditorDocumentKeepsTopLevelEvidenceThroughReview() async throws {
        let model = model(), store = try #require(model.store), paths = try #require(model.paths)
        let project = try await store.createFeedbackProject(name: "Editor document")
        let file = paths.root.appending(path: "source.md")
        try "# Product\nKeep preview visible".write(to: file, atomically: true, encoding: .utf8)
        let source = try await store.importDocumentSource(projectID: project.id, sourceURL: file, paths: paths)
        let evidence = ProjectEvidenceReference.document(sourceID: source.source.id, revision: 1, locator: source.revision.units[0].locator)
        let proposal = ProjectDocumentationProposal(projectID: project.id, documentID: "pdoc_editor_new", expectedDocumentRevision: 0,
            title: "Editor proposal", slug: "editor-proposal", markdown: "Preview", sections: [.init(title: "Preview", body: "Keep visible")], diff: .init(), evidence: [evidence])
        _ = try await ProjectMCPService(store: store).submitDocumentProposal(proposal, requestID: "new-document", paths: paths)
        model.workspaceLocation = .init(root: .project(project.id), section: .documentation)
        await model.loadSelection()
        let imported = try #require(model.documentation.proposals.first)
        #expect(!imported.isStale)
        #expect(imported.sections.flatMap(\.evidence) == [evidence])
        model.workspaceLocation.documentationSelection = .proposal(imported.id)
        await model.resolveDocumentationProposal(imported, accept: true)
        #expect(model.documentation.documentation.first?.sections.flatMap(\.evidence) == [evidence])
        #expect(model.workspaceLocation.documentationSelection == .document(imported.documentID))
        #expect(model.documentationDraft?.document.id == imported.documentID)
    }
}
