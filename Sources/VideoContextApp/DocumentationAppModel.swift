import AppKit
import Foundation
import VideoContextCore

struct DocumentationInboxIssue: Identifiable {
    let entry: DocumentProposalInbox.Entry
    let message: String
    var id: String { entry.id }
}

extension AppModel {
    func loadDocumentationSelection(location: WorkspaceLocation, requestID: UUID) async throws {
        guard let store, let projectID = location.projectID else { return }
        let inboxIssues = libraryReadOnlyReason == nil ? try await importEditorProposals(projectID: projectID) : []
        let snapshot = try await store.projectDocumentation(projectID: projectID)
        let sources = try await store.listProjectDocumentSources(projectID: projectID)
        var revision: ProjectDocumentSourceRevision?
        if case .source(let id) = location.documentationSelection {
            revision = try await store.projectDocumentSource(projectID: projectID, sourceID: id, revision: location.documentSourceRevision)?.1
        }
        try Task.checkCancellation()
        guard workspaceLocation == location, workspaceLoadID == requestID else { return }
        documentation = snapshot; documentationSources = sources; documentationSourceRevision = revision
        documentationInboxIssues = inboxIssues
        if case .document(let id) = location.documentationSelection,
           let document = snapshot.documentation.first(where: { $0.id == id }) {
            if documentationDraft?.document.id != id || (documentationDraft?.dirty == false && documentationDraft?.saving == false) {
                documentationDraft = DocumentationDraft(document)
            }
        } else if documentationDraft?.dirty != true { documentationDraft = nil }
    }

    private func importEditorProposals(projectID: String) async throws -> [DocumentationInboxIssue] {
        guard let store, let paths, FileManager.default.fileExists(atPath: DocumentProposalInbox.url(in: paths).path) else { return [] }
        let inbox = try DocumentProposalInbox(url: DocumentProposalInbox.url(in: paths))
        var issues: [DocumentationInboxIssue] = []
        for entry in try await inbox.pending(projectID: projectID) {
            do {
            let payload = try JSONDecoder().decode(DocumentEditorProposalPayload.self, from: entry.payload)
            let sections = payload.sectionsIncludingSupportingEvidence
            let current = try await store.projectDocumentation(projectID: projectID, documentID: entry.documentID).documentation.first
            let proposal = ProjectDocumentationProposal(id: entry.id, projectID: projectID, documentID: entry.documentID,
                expectedDocumentRevision: entry.expectedRevision, title: payload.title, slug: current?.slug ?? entry.documentID,
                markdown: ProjectDocumentationFormatting.markdown(title: payload.title, sections: sections), sections: sections,
                diff: ProjectDocumentationFormatting.diff(before: current?.sections ?? [], after: sections),
                evidence: sections.flatMap(\.evidence), isStale: (current?.currentRevision ?? 0) != entry.expectedRevision)
            _ = try await store.proposeDocumentation(proposal, requestID: entry.id)
            try await inbox.markImported(id: entry.id)
            } catch {
                issues.append(.init(entry: entry, message: error.localizedDescription))
            }
        }
        return issues
    }

    func dismissEditorProposal(_ issue: DocumentationInboxIssue) async {
        guard let paths, libraryReadOnlyReason == nil else { return }
        do {
            let inbox = try DocumentProposalInbox(url: DocumentProposalInbox.url(in: paths))
            try await inbox.markImported(id: issue.id)
            await loadSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    func createDocumentation(title: String, projectID: String) async {
        guard let store, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let origin = workspaceLocation
        do {
            let doc = try await store.createDocumentationDraft(projectID: projectID, title: title, slug: UUID().uuidString.lowercased())
            if workspaceLocation == origin {
                var next = origin; next.section = .documentation; next.documentationSelection = .document(doc.id)
                requestNavigation(next)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func saveDocumentationDraft() async -> Bool {
        guard let draft = documentationDraft, !draft.saving, let store else { return false }
        draft.saving = true; defer { draft.saving = false }
        do {
            var content = draft.document
            content.markdown = ProjectDocumentationFormatting.markdown(title: content.title, sections: content.sections)
            let saved: ProjectDocumentation
            if let documentationSaver { saved = try await documentationSaver(content) }
            else {
                saved = try await store.saveDocumentationDraft(.init(documentID: content.id, projectID: content.projectID,
                    expectedRevision: content.currentRevision, title: content.title, slug: content.slug, markdown: content.markdown,
                    sections: content.sections, sourceSignature: content.sourceSignature))
            }
            draft.document = saved; draft.saved = saved; draft.error = nil
            await loadSelection(); return true
        } catch { draft.error = error.localizedDescription; return false }
    }

    func reviewDocumentationDraft() async {
        guard let draft = documentationDraft, !draft.dirty, !draft.saving, let store else { return }
        draft.saving = true; defer { draft.saving = false }
        do {
            let saved = try await store.reviewDocumentation(documentID: draft.document.id, projectID: draft.document.projectID, expectedRevision: draft.document.currentRevision)
            draft.document = saved; draft.saved = saved; draft.error = nil; await loadSelection()
        } catch { draft.error = error.localizedDescription }
    }

    func documentationGenerationInputs(projectID: String) async throws -> [ProjectDocumentationGenerationSource] {
        guard let store else { return [] }
        return try await store.documentationGenerationInput(projectID: projectID).sources
    }

    func generateDocumentation(projectID: String, documentID: String?, title: String, selected: Set<String>) async {
        guard !documentationBusy, let store, let paths else { return }
        guard !isUIFixture else { errorMessage = "Documentation generation is disabled in the demo library. Review the included proposal."; return }
        var configuration = modelConfiguration.documentationConfiguration
        let credential = credentialValue(for: configuration.analysisProvider)
        guard credentialReady(for: configuration.analysisProvider) else { errorMessage = "Unlock or enter the analysis provider credential before generating documentation."; return }
        documentationBusy = true; documentationProgress = "Generating documentation for the selected project…"
        defer { documentationBusy = false }
        do {
            let current = try await store.projectDocumentation(projectID: projectID, documentID: documentID).documentation.first { $0.id == documentID }
            var input = try await store.documentationGenerationInput(projectID: projectID, selectedSourceIDs: selected, requestedTitle: title)
            input.targetDocumentID = current?.id
            let projectContext = try await projectAnalysisInput(projectID: projectID, store: store, paths: paths)
            documentationProgress = "Generating documentation for \(input.projectName)…"
            if configuration.analysisProvider == .lmStudio {
                let loaded = try await LMStudioService(client: localHTTP).loadedModel(configuration: configuration.lmStudio, token: credential)
                configuration.lmStudio.modelID = loaded.id
            }
            let config = configuration
            let result = try await withUsageRun(operation: .documentationGeneration, videoID: nil, configuration: config, projectID: projectID,
                projectAnalysisFingerprint: projectContext?.fingerprint) {
                let client = UsageRecordingClient(base: transport(for: config.analysisProvider), provider: config.analysisProvider.identity, model: config.selectedAnalysisModel, stage: .analysis)
                return try await ProjectDocumentationGenerator(client: client, configuration: config, credential: credential, paths: paths, checkpointStore: store)
                    .generate(input: input, projectContext: projectContext)
            }
            // Keep existing wording in the document; generated changes are a separate proposal.
            let sections = result.sections.map { generated in
                var next = generated
                if let old = current?.sections.first(where: { $0.title.caseInsensitiveCompare(generated.title) == .orderedSame }) {
                    next = .init(id: old.id, order: generated.order, title: generated.title, body: generated.body, classification: generated.classification, evidence: generated.evidence, decisionIDs: old.decisionIDs)
                }
                return next
            }
            let proposal = ProjectDocumentationProposal(projectID: projectID, documentID: current?.id ?? "pdoc_\(UUID().uuidString.lowercased())",
                expectedDocumentRevision: current?.currentRevision ?? 0, title: result.title, slug: current?.slug ?? UUID().uuidString.lowercased(),
                markdown: ProjectDocumentationFormatting.markdown(title: result.title, sections: sections), sections: sections,
                diff: ProjectDocumentationFormatting.diff(before: current?.sections ?? [], after: sections), sourceSignature: result.sourceSignature,
                evidence: sections.flatMap(\.evidence))
            _ = try await store.proposeDocumentation(proposal)
            documentationProgress = result.sourceIDsOmitted.isEmpty ? "Documentation is ready for review." : "Documentation is ready for review. \(result.sourceIDsOmitted.count) sources have no cited coverage; review those gaps."
            if selectedProjectID == projectID { await loadSelection() }
        } catch { documentationProgress = "Generation stopped. Existing documents and drafts are preserved."; errorMessage = error.localizedDescription }
    }

    func resolveDocumentationProposal(_ proposal: ProjectDocumentationProposal, accept: Bool) async {
        guard let store else { return }
        let location = workspaceLocation
        do {
            _ = try await store.reviewDocumentationProposal(proposalID: proposal.id, decision: accept ? .accept : .reject, expectedDocumentRevision: proposal.expectedDocumentRevision)
            if workspaceLocation == location, location.projectID == proposal.projectID,
               location.documentationSelection == .proposal(proposal.id), documentationDraft?.dirty != true {
                workspaceLocation.documentationSelection = accept ? .document(proposal.documentID) : nil
            }
            await loadSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    func importProjectSources(_ urls: [URL], projectID: String) async {
        guard let store, let paths else { return }
        let origin = workspaceLocation
        var lastDocumentID: String?
        var lastRecordingID: String?
        let grants = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { grants.forEach { $0.stopAccessingSecurityScopedResource() } }
        sourceWorkCount += 1; defer { sourceWorkCount -= 1 }
        for url in urls {
            do {
                if url.pathExtension.lowercased() == "mp4" {
                    lastRecordingID = await importLocal(url, selectImported: false, projectID: projectID)
                    await waitForProcessing()
                }
                else {
                    let directory = url.resolvingSymlinksInPath().deletingLastPathComponent().path + "/"
                    let attachments = urls.filter { ["png", "jpg", "jpeg", "webp", "gif"].contains($0.pathExtension.lowercased()) && $0.resolvingSymlinksInPath().path.hasPrefix(directory) && $0 != url }
                    lastDocumentID = try await store.importDocumentSourceAsync(projectID: projectID, sourceURL: url, paths: paths, selectedAttachments: attachments).source.id
                }
            } catch { errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
        await loadLibrary()
        if workspaceLocation == origin, origin.projectID == projectID {
            var next = origin
            if let lastDocumentID { next.section = .documentation; next.documentationSelection = .source(lastDocumentID); next.documentSourceRevision = nil; requestNavigation(next) }
            else if let lastRecordingID { next.section = .recordings; next.recordingID = lastRecordingID; requestNavigation(next) }
        }
    }

    func openDocumentationEvidence(_ reference: ProjectEvidenceReference) {
        switch reference {
        case .recording, .feedback, .reviewedDocumentation: documentationEvidence = reference
        case .document(let sourceID, let revision, let locator):
            let origin = workspaceLocation
            var next = origin; next.section = .documentation; next.documentationSelection = .source(sourceID); next.documentSourceRevision = revision
            sourceReturnLocation = origin; documentationEvidenceLocator = locator; requestNavigation(next)
        }
    }

    func copyDocumentationContext() async {
        guard let projectID = selectedProjectID, let store else { return }
        do {
            let latest = try await store.projectDocumentationReadSnapshot(projectID: projectID)
            let refs = latest.documentation.flatMap { $0.sections.flatMap(\.evidence) }
            var stale = 0
            for ref in Set(refs) { if try await store.validateEvidenceReference(ref, projectID: projectID).status != .valid { stale += 1 } }
            let text = "Use Video Context MCP for project \(projectID). Read get_project_context, then get_project_document and get_project_evidence for exact citations. Treat drafts and stale evidence as unapproved.\n\n" + latest.documentation.map { "\($0.title) | document_id=\($0.id) | revision=\($0.currentRevision) | \($0.isReviewed ? "reviewed" : "draft")" }.joined(separator: "\n") + "\nStale or unavailable evidence references: \(stale)."
            copy(text); confirmCopy("Project context copied")
        } catch { errorMessage = error.localizedDescription }
    }

    func exportDocumentation() async {
        guard let projectID = selectedProjectID, let store, let paths else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export here"; panel.message = "A new folder will contain Markdown, source images, and a revision manifest."
        guard await panel.begin() == .OK, let directory = panel.url else { return }
        let access = directory.startAccessingSecurityScopedResource(); defer { if access { directory.stopAccessingSecurityScopedResource() } }
        do {
            let destination = directory.appending(path: "Video Context Export \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            _ = try await store.exportProjectDocumentation(projectID: projectID, destination: destination, paths: paths)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { errorMessage = error.localizedDescription }
    }
}
