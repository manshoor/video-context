import Foundation
import GRDB
import PDFKit
import Testing
@testable import VideoContextCore

struct ProjectMCPContextTests {
    @Test func discoveryIsolationSearchAndExactEvidenceStayProjectScoped() async throws {
        let fixture = try MCPFixture()
        let first = try await fixture.store.createFeedbackProject(name: "Checkout")
        let second = try await fixture.store.createFeedbackProject(name: "Billing")

        let firstVideo = VideoRecord(id: "vid_checkout", title: "Checkout walkthrough", source: .localFile,
                                     sourceValue: "fixture", mediaRelativePath: "checkout.mp4", status: .imported,
                                     projectID: first.id)
        let secondVideo = VideoRecord(id: "vid_billing", title: "Billing walkthrough", source: .localFile,
                                      sourceValue: "fixture", mediaRelativePath: "billing.mp4", status: .imported,
                                      projectID: second.id)
        try await fixture.store.createVideo(firstVideo)
        try await fixture.store.createVideo(secondVideo)

        let segment = TranscriptSegment(id: "seg_checkout", videoID: firstVideo.id, start: 1, end: 2,
                                        originalText: "The checkout preview should remain visible.")
        let evidence = EvidenceItem(id: "ev_checkout", videoID: firstVideo.id, timestamp: 1.5,
                                    imageRelativePath: "evidence/checkout.png", ocrText: "Preview error",
                                    origin: .manual)
        let evidenceURL = fixture.paths.absoluteURL(relativePath: evidence.imageRelativePath)
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: evidenceURL)
        try await fixture.store.replaceTranscript(videoID: firstVideo.id, segments: [segment])
        try await fixture.store.replaceEvidence(videoID: firstVideo.id, items: [evidence])
        let current = try #require(try await fixture.store.videoSnapshot(id: firstVideo.id)?.video)
        try await fixture.store.publishBrief(videoID: firstVideo.id,
            brief: .init(videoID: firstVideo.id, markdown: "Checkout preview reference"), expectedRevision: current.revisions)
        let taskSource = try #require(try await fixture.store.videoSnapshot(id: firstVideo.id)?.video)
        let recordingTask = try await fixture.store.saveTask(
            .init(videoID: firstVideo.id, sourceRevision: taskSource.revisions,
                  content: .init(title: "Review checkout preview", behavior: "Keep the preview visible.",
                                 checks: [.init(text: "The preview is visible.", origin: .recording, sourceIDs: [segment.id])],
                                 sourceIDs: [segment.id])),
            expectedRevision: nil, expectedSource: taskSource.revisions)

        let firstBatch = try await fixture.store.createProjectRequest(projectID: first.id, title: "Checkout request", text: "Keep the preview visible")
        _ = try await fixture.store.createProjectRequest(projectID: second.id, title: "Billing request", text: "Hide the billing preview")
        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# Checkout\n\nThe preview remains visible.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: first.id, sourceURL: sourceURL, paths: fixture.paths)
        let documentEvidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision,
                                                                  locator: imported.revision.units[0].locator)
        let section = ProjectDocumentationSection(title: "Preview", body: "Keep the preview visible.",
                                                  classification: .requested, evidence: [documentEvidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: first.id, title: "Checkout reference",
            slug: "checkout-reference", markdown: "# Checkout\n\nKeep the preview visible.", sections: [section])

        let service = ProjectMCPService(store: fixture.store)
        let projects = try await service.listProjects()
        #expect(Set(projects.projects.map(\.id)) == Set([first.id, second.id]))
        #expect(projects.projects.first(where: { $0.id == first.id })?.documentCount == 1)

        let context = try await service.context(projectID: first.id, limit: 100)
        #expect(context.items.contains { $0.id == "recording:\(firstVideo.id)" })
        #expect(context.items.contains { $0.id == "feedback:\(firstBatch.id)" })
        #expect(context.items.contains { $0.id == "document:\(document.id)" })
        #expect(context.items.allSatisfy { !$0.id.contains(second.id) })

        let search = try await service.search(projectID: first.id, query: "preview", limit: 100)
        #expect(search.hits.contains { $0.citations.contains { $0.id.contains(firstVideo.id) } })
        #expect(search.hits.allSatisfy { !$0.id.contains(second.id) && !$0.excerpt.localizedCaseInsensitiveContains("billing") })

        let recordingReference = ProjectEvidenceReference.recording(videoID: firstVideo.id,
            sourceRevision: (try #require(try await fixture.store.videoSnapshot(id: firstVideo.id)?.video.revisions)),
            timestamp: evidence.timestamp, evidenceID: evidence.id)
        let exact = try await service.evidence(projectID: first.id, reference: recordingReference, paths: fixture.paths)
        #expect(exact.text == evidence.ocrText)
        #expect(exact.imageData == Data([0, 1, 2, 3]))
        let transcriptReference = ProjectEvidenceReference.recording(videoID: firstVideo.id,
            sourceRevision: recordingReferenceSourceRevision(recordingReference), timestamp: segment.start, evidenceID: segment.id)
        try await fixture.store.replaceTranscript(videoID: firstVideo.id,
            segments: [.init(id: segment.id, videoID: firstVideo.id, start: segment.start, end: segment.end, originalText: "The checkout preview changed.")])
        let historical = try await service.evidence(projectID: first.id, reference: transcriptReference, paths: fixture.paths)
        #expect(historical.freshness == .stale)
        #expect(historical.text == segment.originalText)
        let changedContext = try await service.context(projectID: first.id, limit: 100)
        let taskContext = try #require(changedContext.items.first(where: { $0.id == "recording:\(firstVideo.id):\(recordingTask.id)" }))
        #expect(taskContext.freshness == .stale)
        #expect(taskContext.citations.contains {
            $0 == .recording(videoID: firstVideo.id, sourceRevision: taskSource.revisions,
                             timestamp: segment.start, evidenceID: segment.id)
        })
        let missingEvidence = ProjectEvidenceReference.recording(videoID: firstVideo.id,
            sourceRevision: recordingReferenceSourceRevision(recordingReference), timestamp: segment.start, evidenceID: "missing-evidence")
        await #expect(throws: (any Error).self) {
            try await service.evidence(projectID: first.id, reference: missingEvidence, paths: fixture.paths)
        }
        await #expect(throws: (any Error).self) {
            try await service.evidence(projectID: second.id, reference: recordingReference, paths: fixture.paths)
        }

        let documentPage = try await service.document(projectID: first.id, documentID: document.id, expectedRevision: document.currentRevision, wordLimit: 1)
        #expect(documentPage.revision == document.currentRevision)
        #expect(documentPage.sections.isEmpty)
        #expect(documentPage.citations.isEmpty)
        let fullDocumentPage = try await service.document(projectID: first.id, documentID: document.id, expectedRevision: document.currentRevision, wordLimit: 100)
        #expect(fullDocumentPage.sections.count == 1)
        #expect(fullDocumentPage.citations == [documentEvidence])
    }

    private func recordingReferenceSourceRevision(_ reference: ProjectEvidenceReference) -> ArtifactRevision {
        guard case .recording(_, let revision, _, _) = reference else { fatalError("Expected recording reference") }
        return revision
    }

    @Test func projectCursorsRejectChangedScopeAndDocumentRevisions() async throws {
        let fixture = try MCPFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Cursor project")
        let video = VideoRecord(id: "vid_cursor", title: "Cursor recording", source: .localFile,
                                sourceValue: "fixture", mediaRelativePath: "cursor.mp4", status: .ready,
                                projectID: project.id)
        try await fixture.store.createVideo(video)
        _ = try await fixture.store.createProjectRequest(projectID: project.id, title: "First request", text: "Preview")
        _ = try await fixture.store.createProjectRequest(projectID: project.id, title: "Second request", text: "Preview")
        let service = ProjectMCPService(store: fixture.store)

        let firstContextPage = try await service.context(projectID: project.id, limit: 1)
        let contextCursor = try #require(firstContextPage.nextCursor)
        _ = try await fixture.store.createProjectRequest(projectID: project.id, title: "Changed request", text: "Preview")
        await #expect(throws: TaskContextError.conflict) {
            try await service.context(projectID: project.id, cursor: contextCursor, limit: 1)
        }

        let sourceURL = fixture.root.appending(path: "cursor.md")
        try "# Cursor\n\nThe preview is visible in this document.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        try "# Cursor\n\nThe revised preview is visible in this document.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let revisedImport = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let staleSearch = try await service.search(projectID: project.id, query: "preview", limit: 100)
        let originalUnit = try #require(imported.revision.units.first { $0.text.contains("preview") })
        let oldSourceHit = try #require(staleSearch.hits.first { $0.id == "document-unit:\(originalUnit.id)" })
        #expect(oldSourceHit.freshness == .stale)
        let evidence = ProjectEvidenceReference.document(sourceID: revisedImport.source.id, revision: revisedImport.revision.revision,
                                                         locator: revisedImport.revision.units[0].locator)
        let section = ProjectDocumentationSection(title: "Preview", body: "Visible", evidence: [evidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Cursor doc", slug: "cursor", markdown: "one two three", sections: [section])
        let firstDocumentPage = try await service.document(projectID: project.id, documentID: document.id, wordLimit: 1)
        let documentCursor = try #require(firstDocumentPage.nextCursor)
        let edited = try await fixture.store.saveDocumentationDraft(.init(documentID: document.id, projectID: project.id,
            expectedRevision: document.currentRevision, title: document.title, slug: document.slug,
            markdown: "changed document", sections: [section]))
        #expect(edited.currentRevision == document.currentRevision + 1)
        await #expect(throws: TaskContextError.conflict) {
            try await service.document(projectID: project.id, documentID: document.id, cursor: documentCursor, wordLimit: 1)
        }
    }

    @Test func proposalSubmissionIsSeparateIdempotentInboxWrite() async throws {
        let fixture = try MCPFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Proposal project")
        let sourceURL = fixture.root.appending(path: "proposal.md")
        try "# Proposal\n\nReference text.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let evidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision,
                                                         locator: imported.revision.units[0].locator)
        let section = ProjectDocumentationSection(title: "Reference", body: "Reference text.", evidence: [evidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Proposal doc", slug: "proposal", sections: [section])
        let proposal = ProjectDocumentationProposal(id: "provider-random-one", projectID: project.id, documentID: document.id,
            expectedDocumentRevision: document.currentRevision, title: document.title, slug: document.slug,
            markdown: "Updated reference", sections: [section], diff: .init(changedSectionIDs: [section.id]), evidence: [evidence],
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        let repeatedSection = ProjectDocumentationSection(title: "Reference", body: "Reference text.", evidence: [evidence])
        let repeatedProposal = ProjectDocumentationProposal(id: "provider-random-two", projectID: project.id, documentID: document.id,
            expectedDocumentRevision: document.currentRevision, title: document.title, slug: document.slug,
            markdown: "Different provider rendering is ignored by the editor payload", sections: [repeatedSection],
            diff: .init(changedSectionIDs: [repeatedSection.id]), evidence: [evidence],
            createdAt: Date(timeIntervalSince1970: 99), updatedAt: Date(timeIntervalSince1970: 100))
        let service = ProjectMCPService(store: fixture.store)
        let first = try await service.submitDocumentProposal(proposal, requestID: "proposal-request-1", paths: fixture.paths)
        let repeated = try await service.submitDocumentProposal(repeatedProposal, requestID: "proposal-request-1", paths: fixture.paths)
        #expect(first == repeated)
        #expect(try await fixture.store.projectDocumentation(projectID: project.id, documentID: document.id).documentation.first?.currentRevision == document.currentRevision)
        _ = try await fixture.store.saveDocumentationDraft(.init(documentID: document.id, projectID: project.id,
            expectedRevision: document.currentRevision, title: document.title, slug: document.slug,
            markdown: "Accepted manually", sections: [section]))
        let staleRetry = try await service.submitDocumentProposal(proposal, requestID: "proposal-request-1", paths: fixture.paths)
        #expect(staleRetry == first)
        let changedSection = ProjectDocumentationSection(title: section.title, body: "Different proposal body", evidence: section.evidence)
        let differentProposal = ProjectDocumentationProposal(projectID: project.id, documentID: document.id,
            expectedDocumentRevision: document.currentRevision, title: document.title, slug: document.slug,
            markdown: "Different proposal body", sections: [changedSection], diff: .init(changedSectionIDs: [changedSection.id]), evidence: [evidence])
        await #expect(throws: TaskContextError.self) {
            try await service.submitDocumentProposal(differentProposal, requestID: "proposal-request-1", paths: fixture.paths)
        }
        let inbox = try DocumentProposalInbox(url: DocumentProposalInbox.url(in: fixture.paths))
        let pending = try await inbox.pending(projectID: project.id)
        #expect(pending.count == 1)
        let payload = try JSONDecoder().decode(DocumentEditorProposalPayload.self, from: try #require(pending.first?.payload))
        #expect(payload.title == proposal.title)
        #expect(payload.sections.count == 1)
        #expect(payload.sections[0].id.hasPrefix("section_"))
        #expect(payload.sections[0].id != section.id)

        let otherProject = try await fixture.store.createFeedbackProject(name: "Other proposal project")
        let otherDocument = try await fixture.store.createDocumentationDraft(projectID: otherProject.id,
            title: "Other document", slug: "other-document")
        let collidingProposal = ProjectDocumentationProposal(projectID: project.id, documentID: otherDocument.id,
            expectedDocumentRevision: 0, title: "Collision", slug: "collision", markdown: "",
            sections: [], diff: .init())
        await #expect(throws: TaskContextError.conflict) {
            try await service.submitDocumentProposal(collidingProposal, requestID: "proposal-collision", paths: fixture.paths)
        }
        await #expect(throws: ProjectDocumentationStoreError.conflict) {
            try await fixture.store.proposeDocumentation(collidingProposal)
        }
    }

    @Test func documentPageDoesNotExposeWholeSectionWhenPageSplitsIt() async throws {
        let fixture = try MCPFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Pagination project")
        let sourceURL = fixture.root.appending(path: "pagination-source.md")
        try "# Requirements\n\nReference.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let source = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let structuredBody = Array(repeating: "Use `--flag`, then call foo().", count: 50).joined(separator: " ")
        let section = ProjectDocumentationSection(
            title: "Long requirements",
            body: structuredBody,
            classification: .requested,
            evidence: [.document(sourceID: source.source.id, revision: source.revision.revision,
                                 locator: source.revision.units[0].locator)])
        let secondSection = ProjectDocumentationSection(
            order: 1,
            title: "Fallback decision",
            body: "Keep the fallback visible.",
            classification: .confirmedDecision,
            evidence: section.evidence)
        let markdown = "# Pagination\n\nManual summary."
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id,
            title: "Pagination", slug: "pagination", markdown: markdown, sections: [section, secondSection])
        let page = try await ProjectMCPService(store: fixture.store).document(projectID: project.id,
            documentID: document.id, wordLimit: 10)
        #expect(page.sections.count == 1)
        #expect(page.sections[0].body.count < structuredBody.count)
        #expect(page.sections[0].body.contains("`--flag`"))
        #expect(page.sections[0].body.contains("foo()."))
        #expect(page.citations.isEmpty)
        #expect(page.markdown.contains("Manual summary."))
        var cursor = page.nextCursor
        var citations = page.citations
        var sectionIDs = Set(page.sections.map(\.id))
        var recoveredBody = page.sections.filter { $0.id == section.id }.map(\.body).joined()
        for _ in 0..<40 {
            guard let nextCursor = cursor else { break }
            let next = try await ProjectMCPService(store: fixture.store).document(projectID: project.id,
                documentID: document.id, cursor: nextCursor, wordLimit: 10)
            citations.append(contentsOf: next.citations)
            sectionIDs.formUnion(next.sections.map(\.id))
            recoveredBody += next.sections.filter { $0.id == section.id }.map(\.body).joined()
            cursor = next.nextCursor
        }
        #expect(cursor == nil)
        #expect(recoveredBody == structuredBody)
        #expect(sectionIDs.contains(section.id))
        #expect(sectionIDs.contains(secondSection.id))
        #expect(citations.contains { $0.id == section.evidence[0].id })
    }

    @Test func documentEvidenceResolvesHeadingRelativeAssetAndPDFPage() async throws {
        let fixture = try MCPFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Evidence project")
        let markdownURL = fixture.root.appending(path: "evidence.md")
        let attachmentURL = fixture.root.appending(path: "screen.png")
        try "# Checkout\n\nThe preview remains visible.\n\n![Screen](screen.png)\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: attachmentURL)
        let markdown = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: markdownURL,
            paths: fixture.paths, selectedAttachments: [attachmentURL])
        let service = ProjectMCPService(store: fixture.store)
        let heading = try await service.evidence(projectID: project.id,
            reference: .document(sourceID: markdown.source.id, revision: markdown.revision.revision,
                                 locator: .init(heading: "Checkout")), paths: fixture.paths)
        #expect(!heading.text.isEmpty)
        let asset = try #require(markdown.revision.assets.first)
        let assetLocator = ProjectDocumentLocator(asset: asset.relativePath ?? asset.sourcePath)
        let assetEvidence = try await service.evidence(projectID: project.id,
            reference: .document(sourceID: markdown.source.id, revision: markdown.revision.revision,
                                 locator: assetLocator), paths: fixture.paths)
        #expect(assetEvidence.imageData == Data([0, 1, 2, 3]))

        let pdfURL = fixture.root.appending(path: "page.pdf")
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let pdfData = try #require(pdf.dataRepresentation())
        try pdfData.write(to: pdfURL)
        let importedPDF = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: pdfURL, paths: fixture.paths)
        let pageEvidence = try await service.evidence(projectID: project.id,
            reference: .document(sourceID: importedPDF.source.id, revision: importedPDF.revision.revision,
                                 locator: .init(pdfPage: 1)), paths: fixture.paths)
        #expect(pageEvidence.imageData != nil)
        #expect(pageEvidence.freshness == .current)
    }

    @Test func oldReadOnlyLibrariesExposeInboxWithoutProjectMigration() async throws {
        let fixture = try LegacyMCPFixture()
        let store = try VideoContextStore(databaseURL: fixture.databaseURL, access: .readOnly)
        let service = ProjectMCPService(store: store)
        let projects = try await service.listProjects()
        #expect(projects.projects.count == 1)
        #expect(projects.projects[0].id == ProjectMCPService.inboxID)
        #expect(projects.projects[0].recordingCount == 1)
        let context = try await service.context(projectID: ProjectMCPService.inboxID)
        #expect(context.isInbox)
        #expect(context.items.contains { $0.id == "recording:vid_legacy" })
        let exact = try await service.evidence(projectID: ProjectMCPService.inboxID,
            reference: .recording(videoID: "vid_legacy", sourceRevision: .init(), timestamp: 1, evidenceID: "seg_legacy"),
            paths: fixture.paths)
        #expect(exact.text == "Legacy transcript")
        let database = try DatabaseQueue(path: fixture.databaseURL.path)
        let hasProjectOwnershipColumn = try await database.read {
            try $0.columns(in: "videos").contains { $0.name == "project_id" }
        }
        #expect(hasProjectOwnershipColumn == false)
    }
}

private struct MCPFixture {
    let root: URL
    let paths: LibraryPaths
    let store: VideoContextStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextMCP-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        store = try VideoContextStore(databaseURL: root.appending(path: "library.sqlite"))
    }
}

private struct LegacyMCPFixture {
    let root: URL
    let databaseURL: URL
    let paths: LibraryPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextMCPLegacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "library.sqlite")
        paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { db in
            try VideoContextStore.createSchema(in: db)
            try VideoContextStore.createTaskSchema(in: db)
            try VideoContextStore.createFeedbackSchema(in: db)
            try VideoContextStore.createFeedbackProjectSchema(in: db)
            try db.execute(sql: "INSERT INTO videos(id,title,source_type,source_value,media_path,duration,status,error_message,created_at,updated_at,transcript_revision,evidence_revision,brief_revision,brief_source_transcript,brief_source_evidence,estimated_cost_usd) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           arguments: ["vid_legacy", "Legacy recording", "localFile", "fixture", "legacy.mp4", 0, "ready", nil, 0, 0, 0, 0, 0, 0, 0, 0])
            try VideoContextStore.insertTranscript(.init(id: "seg_legacy", videoID: "vid_legacy", start: 1, end: 2,
                                                         originalText: "Legacy transcript"), into: db)
        }
    }
}
