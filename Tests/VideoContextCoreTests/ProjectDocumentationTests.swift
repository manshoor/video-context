import Foundation
import GRDB
import AppKit
import CoreText
import PDFKit
import Testing
@testable import VideoContextCore

struct ProjectDocumentationTests {
    @Test("Markdown inspection preserves line locators and only selected local assets")
    func markdownInspection() throws {
        let root = try makeTemporaryDirectory()
        let markdownURL = root.appending(path: "requirements.md")
        let imageURL = root.appending(path: "screen.png")
        try "# Checkout\n\nThe preview must remain visible.\n\n![Screen](screen.png)\n\n```swift\nlet value = true\n```\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: imageURL)

        let withoutAttachment = try DocumentSourceImporter.inspect(markdownURL)
        #expect(withoutAttachment.kind == .markdown)
        #expect(withoutAttachment.units.contains { $0.kind == .heading && $0.locator.startLine == 1 })
        #expect(withoutAttachment.units.contains { $0.kind == .code && $0.text.contains("value") })
        #expect(withoutAttachment.assets.first?.status == .missing)

        let withAttachment = try DocumentSourceImporter.inspect(markdownURL, selectedAttachments: [imageURL])
        #expect(withAttachment.assets.first?.status == .copied)
        #expect(withAttachment.assetPayloads.first?.data == Data([0, 1, 2, 3]))
        #expect(withAttachment.contentHash != withoutAttachment.contentHash)
    }

    @Test("Project source imports reuse unchanged revisions and preserve changed history")
    func sourceRevisionHistory() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# First\n\nKeep the preview visible.\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let first = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let duplicate = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        #expect(first.source.id == duplicate.source.id)
        #expect(duplicate.revision.revision == 1)
        #expect(duplicate.reusedExistingRevision)

        try "# Second\n\nShow an error state.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let second = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        #expect(second.source.id == first.source.id)
        #expect(second.revision.revision == 2)
        #expect(second.revision.contentHash != first.revision.contentHash)

        try "# First\n\nKeep the preview visible.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let restored = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        #expect(restored.revision.revision == 3)
        #expect(try await fixture.store.projectDocumentSource(projectID: project.id, sourceID: first.source.id, revision: 1)?.1.units.first?.text.contains("First") == true)
    }

    @Test("Pending document imports resume from the durable intake copy after the source is gone")
    func durableImportResume() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let originalURL = fixture.root.appending(path: "requirements.md")
        let attachmentURL = fixture.root.appending(path: "screen.png")
        try "# Checkout\n\n![Screen](screen.png)\n".write(to: originalURL, atomically: true, encoding: .utf8)
        try Data([1, 2, 3, 4]).write(to: attachmentURL)

        let jobID = "dimport_restart_\(UUID().uuidString.lowercased())"
        let intakeDirectory = fixture.paths.root.appending(path: "documents/_imports/\(jobID)", directoryHint: .isDirectory)
        let intakeURL = intakeDirectory.appending(path: "requirements.md")
        let intakeAttachmentURL = intakeDirectory.appending(path: "screen.png")
        try FileManager.default.createDirectory(at: intakeDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: originalURL, to: intakeURL)
        try FileManager.default.copyItem(at: attachmentURL, to: intakeAttachmentURL)
        let intakeRelativePath = fixture.paths.relativePath(for: intakeURL)
        let checkpointRelativePath = fixture.paths.relativePath(for: intakeDirectory.appending(path: "checkpoint.json"))
        let attachmentData = try JSONEncoder().encode(["screen.png"])
        let database = try DatabaseQueue(path: fixture.databaseURL.path)
        try await database.write { db in
            try VideoContextStore.ensureDocumentImportJobColumns(in: db)
            try db.execute(sql: "INSERT INTO project_document_import_jobs(id,project_id,source_key,source_path,source_id,intake_relative_path,attachment_relative_paths,checkpoint_relative_path,content_hash,status,error,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                arguments: [jobID, project.id, originalURL.standardizedFileURL.path, originalURL.standardizedFileURL.path, nil, intakeRelativePath, attachmentData, checkpointRelativePath, nil, ProjectDocumentImportJobStatus.processing.rawValue, nil, Date.now.timeIntervalSince1970])
        }
        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.removeItem(at: attachmentURL)

        let resumed = await fixture.store.resumePendingDocumentImports(paths: fixture.paths)
        let result = try #require(resumed.first)
        #expect(result.revision.status == .ready)
        #expect(result.revision.assets.first?.status == .copied)
        let copiedPath = try #require(result.revision.assets.first?.relativePath)
        #expect(try Data(contentsOf: fixture.paths.absoluteURL(relativePath: copiedPath)) == Data([1, 2, 3, 4]))
        #expect(try await fixture.store.pendingDocumentImportJobs().isEmpty)
    }

    @Test("Documentation drafts, proposals, and review gates are optimistic and evidence bound")
    func documentationReviewFlow() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# Checkout\n\nThe preview must remain visible.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let evidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision, locator: imported.revision.units[0].locator)
        let section = ProjectDocumentationSection(title: "Requirements", body: "Keep the preview visible.", classification: .requested, evidence: [evidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Checkout", slug: "checkout", sections: [section])
        #expect(document.isReviewed == false)
        let reviewed = try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)
        #expect(reviewed.isReviewed)

        let edited = try await fixture.store.saveDocumentationDraft(.init(documentID: document.id, projectID: project.id, expectedRevision: reviewed.currentRevision,
            title: "Checkout", slug: "checkout", markdown: "Updated", sections: [section]))
        #expect(edited.currentRevision == reviewed.currentRevision + 1)
        #expect(edited.reviewedRevision == nil)

        let proposalSection = ProjectDocumentationSection(title: "Requirements", body: "Keep the preview and error states visible.", classification: .requested, evidence: [evidence])
        let proposal = ProjectDocumentationProposal(projectID: project.id, documentID: document.id, expectedDocumentRevision: edited.currentRevision,
            title: "Checkout", slug: "checkout", markdown: "Updated", sections: [proposalSection], diff: .init(changedSectionIDs: [section.id]), evidence: [evidence])
        let savedProposal = try await fixture.store.proposeDocumentation(proposal, requestID: "cursor-request-1")
        let accepted = try await fixture.store.reviewDocumentationProposal(proposalID: savedProposal.id, decision: .accept, expectedDocumentRevision: edited.currentRevision)
        #expect(accepted.state == .accepted)
        let afterAccept = try #require(try await fixture.store.projectDocumentation(projectID: project.id, documentID: document.id).documentation.first)
        #expect(afterAccept.isReviewed == false)
        #expect(try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: afterAccept.currentRevision).isReviewed)

        let decision = try await fixture.store.saveProjectDecision(.init(projectID: project.id, key: "preview", question: "Should preview stay visible?", answer: "Yes", evidence: [evidence], state: .confirmed))
        #expect(decision.state == .confirmed)
        let snapshot = try await fixture.store.projectDocumentationReadSnapshot(projectID: project.id)
        #expect(snapshot.decisions.map(\.id) == [decision.id])
    }

    @Test("Missing Markdown assets cannot become current evidence until explicitly imported")
    func missingMarkdownAssetBlocksCurrentReview() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let sourceURL = fixture.root.appending(path: "requirements.md")
        let attachmentURL = fixture.root.appending(path: "screen.png")
        try "# Checkout\n\n![Screen](screen.png)\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try Data([137, 80, 78, 71]).write(to: attachmentURL)

        let missing = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let missingAsset = try #require(missing.revision.assets.first)
        #expect(missingAsset.status == .missing)
        let missingEvidence = ProjectEvidenceReference.document(sourceID: missing.source.id, revision: missing.revision.revision, locator: .init(asset: missingAsset.sourcePath))
        #expect(try await fixture.store.validateEvidenceReference(missingEvidence, projectID: project.id).status == .missing)

        let missingSection = ProjectDocumentationSection(title: "Visual reference", body: "Keep the preview visible.", classification: .observed, evidence: [missingEvidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Checkout", slug: "checkout", sections: [missingSection])
        await #expect(throws: ProjectDocumentationStoreError.self) {
            try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)
        }
        #expect(try await fixture.store.projectDocumentation(projectID: project.id, documentID: document.id).documentation.first?.isReviewed == false)

        let copied = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths, selectedAttachments: [attachmentURL])
        #expect(copied.revision.revision == missing.revision.revision + 1)
        let copiedAsset = try #require(copied.revision.assets.first)
        #expect(copiedAsset.status == .copied)
        let copiedEvidence = ProjectEvidenceReference.document(sourceID: copied.source.id, revision: copied.revision.revision, locator: .init(asset: copiedAsset.sourcePath))
        #expect(try await fixture.store.validateEvidenceReference(copiedEvidence, projectID: project.id).status == .valid)
        let copiedSection = ProjectDocumentationSection(id: missingSection.id, title: missingSection.title, body: missingSection.body, classification: missingSection.classification, evidence: [copiedEvidence])
        let updated = try await fixture.store.saveDocumentationDraft(.init(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision,
            title: document.title, slug: document.slug,
            markdown: ProjectDocumentationFormatting.markdown(title: document.title, sections: [copiedSection]), sections: [copiedSection]))
        let reviewed = try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: updated.currentRevision)
        #expect(reviewed.isReviewed)
    }

    @Test("Accepting a first documentation proposal creates the document")
    func acceptFirstDocumentationProposal() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# Checkout\n\nThe preview must remain visible.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let evidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision, locator: imported.revision.units[0].locator)
        let section = ProjectDocumentationSection(title: "Requirements", body: "Keep the preview visible.", classification: .requested, evidence: [evidence])
        let proposal = ProjectDocumentationProposal(projectID: project.id, documentID: "pdoc_new", expectedDocumentRevision: 0,
            title: "Checkout", slug: "checkout", markdown: "", sections: [section], diff: .init(addedSectionIDs: [section.id]), evidence: [evidence])
        let saved = try await fixture.store.proposeDocumentation(proposal)
        let pendingSnapshot = try await fixture.store.projectDocumentation(projectID: project.id)
        #expect(pendingSnapshot.proposals.first(where: { $0.id == saved.id })?.isStale == false)
        let accepted = try await fixture.store.reviewDocumentationProposal(proposalID: saved.id, decision: .accept, expectedDocumentRevision: 0)
        #expect(accepted.state == .accepted)
        let document = try #require(try await fixture.store.projectDocumentation(projectID: project.id, documentID: "pdoc_new").documentation.first)
        #expect(document.currentRevision == 1)
        #expect(document.isReviewed == false)
    }

    @Test("Changed source evidence clears approval and blocks stale review")
    func changedSourceInvalidatesReview() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# Checkout\n\nThe preview must remain visible.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let first = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let evidence = ProjectEvidenceReference.document(sourceID: first.source.id, revision: first.revision.revision, locator: first.revision.units[0].locator)
        let section = ProjectDocumentationSection(title: "Requirements", body: "Keep the preview visible.", classification: .requested, evidence: [evidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Checkout", slug: "checkout", sections: [section])
        _ = try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)
        let proposal = ProjectDocumentationProposal(projectID: project.id, documentID: document.id, expectedDocumentRevision: document.currentRevision,
            title: "Checkout", slug: "checkout", markdown: "", sections: [section], diff: .init(changedSectionIDs: [section.id]), evidence: [evidence])
        let savedProposal = try await fixture.store.proposeDocumentation(proposal)

        try "# Checkout\n\nThe preview now includes an error state.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let second = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        #expect(second.revision.revision == first.revision.revision + 1)
        #expect(try await fixture.store.validateEvidenceReference(evidence, projectID: project.id).status == .stale)

        let snapshot = try await fixture.store.projectDocumentation(projectID: project.id)
        let stale = try #require(snapshot.documentation.first)
        #expect(stale.reviewedRevision == nil)
        #expect(snapshot.proposals.first(where: { $0.id == savedProposal.id })?.isStale == true)
        let rejectedStale = try await fixture.store.reviewDocumentationProposal(proposalID: savedProposal.id, decision: .accept, expectedDocumentRevision: stale.currentRevision)
        #expect(rejectedStale.state == .pending)
        #expect(rejectedStale.isStale == true)
        do {
            _ = try await fixture.store.reviewDocumentation(documentID: stale.id, projectID: project.id, expectedRevision: stale.currentRevision)
            Issue.record("Expected stale evidence to block review")
        } catch { }
    }

    @Test("Old libraries remain readable before the additive documentation migration")
    func oldSchemaReadCompatibility() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Inbox")
        #expect(try await fixture.store.listProjectDocumentSources(projectID: project.id).isEmpty)
        #expect(try await fixture.store.projectDocumentation(projectID: project.id).documentation.isEmpty)
    }

    @Test("Documentation generation validates provider evidence IDs and reports source coverage")
    func generationEvidenceAndCoverage() async throws {
        let revision = ArtifactRevision(transcript: 1, evidence: 1, brief: 1)
        let cited = ProjectEvidenceReference.recording(videoID: "recording-1", sourceRevision: revision, timestamp: 1, evidenceID: "frame-1")
        let response = """
        {"status":"completed","output":[{"content":[{"type":"output_text","text":"{\\"title\\":\\"Checkout\\",\\"sections\\":[{\\"title\\":\\"Observed\\",\\"body\\":\\"The preview remains visible.\\",\\"classification\\":\\"observed\\",\\"evidenceIDs\\":[\\"\(cited.id)\\"],\\"sourceIDs\\":[\\"recording:recording-1\\"]}]}"}]}]}
        """
        let client = DocumentationHTTPStub(response: HTTPResult(data: Data(response.utf8), statusCode: 200))
        let generator = ProjectDocumentationGenerator(client: client, configuration: .init(analysisModel: "test"), credential: "test")
        let input = ProjectDocumentationGenerationInput(projectID: "project", projectName: "Checkout", requestedTitle: "Checkout", sources: [
            .init(id: "recording:recording-1", title: "Recording", kind: "recording", revision: "r1", text: "preview", evidence: [cited]),
            .init(id: "feedback:batch-1", title: "Feedback", kind: "feedback", revision: "r1", text: "error state")
        ])
        let generated = try await generator.generate(input: input)
        #expect(generated.sections.count == 1)
        #expect(generated.sourceIDsCovered == ["recording:recording-1"])
        #expect(generated.sourceIDsOmitted == ["feedback:batch-1"])
    }

    @Test("Documentation generation rejects an unknown evidence ID")
    func generationRejectsUnknownEvidence() async throws {
        let response = """
        {"status":"completed","output":[{"content":[{"type":"output_text","text":"{\\"title\\":\\"Checkout\\",\\"sections\\":[{\\"title\\":\\"Observed\\",\\"body\\":\\"Unsupported claim.\\",\\"classification\\":\\"observed\\",\\"evidenceIDs\\":[\\"missing\\"],\\"sourceIDs\\":[\\"recording:recording-1\\"]}]}"}]}]}
        """
        let client = DocumentationHTTPStub(response: HTTPResult(data: Data(response.utf8), statusCode: 200))
        let generator = ProjectDocumentationGenerator(client: client, configuration: .init(analysisModel: "test"), credential: "test")
        let input = ProjectDocumentationGenerationInput(projectID: "project", projectName: "Checkout", requestedTitle: "Checkout", sources: [
            .init(id: "recording:recording-1", title: "Recording", kind: "recording", revision: "r1", text: "preview", evidence: [])
        ])
        do {
            _ = try await generator.generate(input: input)
            Issue.record("Expected an unknown evidence ID error")
        } catch let error as ProjectDocumentationGenerationError {
            #expect(error == .unknownEvidenceID("missing"))
        }
    }

    @Test("Documentation generation reuses a completed batch checkpoint")
    func generationReusesCompletedBatch() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let revision = ArtifactRevision(transcript: 1, evidence: 1, brief: 1)
        let cited = ProjectEvidenceReference.recording(videoID: "recording-1", sourceRevision: revision, timestamp: 1, evidenceID: "frame-1")
        let response = try makeDocumentationProviderResponse(title: "Checkout", body: "The preview remains visible.", classification: "observed", evidenceIDs: [cited.id], sourceIDs: ["recording:recording-1"])
        let client = CountingDocumentationHTTPStub(response: HTTPResult(data: Data(response.utf8), statusCode: 200))
        let generator = ProjectDocumentationGenerator(
            client: client,
            configuration: .init(analysisModel: "test"),
            credential: "test",
            checkpointStore: fixture.store
        )
        let input = ProjectDocumentationGenerationInput(projectID: project.id, projectName: "Checkout", requestedTitle: "Checkout", sources: [
            .init(id: "recording:recording-1", title: "Recording", kind: "recording", revision: "r1", text: "preview", evidence: [cited])
        ])

        let first = try await generator.generate(input: input)
        let second = try await generator.generate(input: input)
        #expect(first == second)
        #expect(await client.callCount() == 1)
        let checkpoints = try await fixture.store.documentationAnalysisCheckpoints(projectID: project.id)
        #expect(checkpoints.count == 1)
        #expect(checkpoints.first?.state == .completed)
    }

    @Test("PDF imports retain page locators and report damaged input")
    func pdfImportDiagnostics() throws {
        let root = try makeTemporaryDirectory()
        let pdfURL = root.appending(path: "requirements.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let pdfData = try #require(document.dataRepresentation())
        try pdfData.write(to: pdfURL)
        let checkpoint = root.appending(path: "checkpoint.json")
        let artifact = try DocumentSourceImporter.inspect(pdfURL, checkpointURL: checkpoint)
        #expect(artifact.kind == .pdf)
        #expect(artifact.units.first?.locator == ProjectDocumentLocator(pdfPage: 1))
        #expect(artifact.assets.first?.sourcePath == "page-1.png")
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
        let resumed = try DocumentSourceImporter.inspect(pdfURL, checkpointURL: checkpoint)
        #expect(resumed.units == artifact.units)
        #expect(resumed.assets == artifact.assets)

        let damagedURL = root.appending(path: "damaged.pdf")
        try Data([0, 1, 2, 3]).write(to: damagedURL)
        let damaged = try DocumentSourceImporter.inspect(damagedURL)
        #expect(damaged.status == .failed)
        #expect(damaged.errors.contains { $0.isFatal })
    }

    @Test("Selectable text PDFs preserve page text and page evidence")
    func selectablePDFTextExtraction() throws {
        let root = try makeTemporaryDirectory()
        let pdfURL = root.appending(path: "selectable.pdf")
        try selectableTextPDF().write(to: pdfURL)

        let artifact = try DocumentSourceImporter.inspect(pdfURL)
        let page = try #require(artifact.units.first)
        #expect(page.kind == .page)
        #expect(page.locator == .init(pdfPage: 1))
        #expect(page.text.contains("Checkout requirements"))
        #expect(page.text.contains("Keep the order summary visible"))
        #expect(artifact.status == .ready)
        #expect(artifact.assets.first?.status == .copied)
    }

    @Test("Image-only PDFs run OCR and retain a visual page asset")
    func scannedPDFOCR() throws {
        let root = try makeTemporaryDirectory()
        let pdfURL = root.appending(path: "scanned.pdf")
        try scannedTextPDF().write(to: pdfURL)

        let artifact = try DocumentSourceImporter.inspect(pdfURL)
        let page = try #require(artifact.units.first)
        #expect(page.kind == .page)
        #expect(page.locator == .init(pdfPage: 1))
        #expect(artifact.assets.first?.status == .copied)
        #expect(artifact.assets.first?.sourcePath == "page-1.png")

        // Vision is unavailable in some headless test environments. In that
        // case the importer must retain the page image and report the missing
        // OCR explicitly instead of claiming that the page was extracted.
        if page.text.isEmpty {
            #expect(artifact.errors.contains { $0.message.contains("No selectable text or OCR text") })
            #expect(artifact.status == .partial)
        } else {
            #expect(page.text.localizedCaseInsensitiveContains("SCANNED CHECKOUT"))
            #expect(artifact.status == .ready)
        }
    }

    @Test("Encrypted PDFs are reported as locked")
    func lockedPDFDiagnostics() throws {
        let root = try makeTemporaryDirectory()
        let pdfURL = root.appending(path: "locked.pdf")
        let document = try #require(PDFDocument(data: selectableTextPDF()))
        #expect(document.write(to: pdfURL, withOptions: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner",
            PDFDocumentWriteOption.userPasswordOption: "user"
        ]))

        let artifact = try DocumentSourceImporter.inspect(pdfURL)
        #expect(artifact.status == .failed)
        #expect(artifact.errors.contains { $0.isFatal && $0.message.localizedCaseInsensitiveContains("locked") })
    }

    @Test("Invalid UTF-8 Markdown is reported as an unreadable source")
    func invalidMarkdownDiagnostics() throws {
        let root = try makeTemporaryDirectory()
        let markdownURL = root.appending(path: "damaged.md")
        try Data([0x23, 0x20, 0xFF, 0xFE]).write(to: markdownURL)

        let artifact = try DocumentSourceImporter.inspect(markdownURL)
        #expect(artifact.status == .failed)
        #expect(artifact.errors.contains { $0.isFatal && $0.message.contains("valid UTF-8") })
    }

    @Test("Portable export includes cited source revisions, images, and explicit notices")
    func portableExportCitations() async throws {
        let fixture = try DocumentationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        try fixture.enableDocumentationSchema()
        let sourceURL = fixture.root.appending(path: "requirements.md")
        let imageDirectory = fixture.root.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appending(path: "Checkout screen.png")
        try Data([137, 80, 78, 71]).write(to: imageURL)
        try "# Checkout\n\n![Screen](assets/Checkout%20screen.png)\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths, selectedAttachments: [imageURL])
        let assetEvidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision, locator: .init(asset: "assets/Checkout%20screen.png"))
        let section = ProjectDocumentationSection(title: "Visual reference", body: "Keep the preview visible.", classification: .observed, evidence: [assetEvidence])
        _ = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Checkout", slug: "checkout", sections: [section])
        let destination = fixture.root.appending(path: "export", directoryHint: .isDirectory)
        let result = try await fixture.store.exportProjectDocumentation(projectID: project.id, destination: destination, paths: fixture.paths)
        let markdown = try String(contentsOf: try #require(result.documentationURLs.first), encoding: .utf8)
        #expect(markdown.contains("../sources/"))
        let manifest = try JSONDecoder().decode(ProjectDocumentationExportManifest.self, from: Data(contentsOf: result.manifestURL))
        let evidence = try #require(manifest.evidence.first { $0.referenceID == assetEvidence.id })
        #expect(evidence.relativePaths.isEmpty == false)
        #expect(evidence.status == .available)
        #expect(evidence.relativePaths.allSatisfy { FileManager.default.fileExists(atPath: destination.appending(path: $0).path) })
        let exportedOriginal = try #require(manifest.sources.first?.originalPath)
        let originalText = try String(contentsOf: destination.appending(path: exportedOriginal), encoding: .utf8)
        #expect(originalText.contains("assets/Checkout%20screen.png"))
        let exportedAttachment = destination
            .appending(path: exportedOriginal)
            .deletingLastPathComponent()
            .appending(path: "assets/Checkout screen.png")
        #expect(FileManager.default.fileExists(atPath: exportedAttachment.path))
        #expect(manifest.sources.contains { !$0.originalPath.isEmpty && $0.originalPath.hasPrefix("sources/") })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "VideoContextDocumentation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func selectableTextPDF() -> Data {
    let content = "BT\n/F1 20 Tf\n72 700 Td\n(Checkout requirements) Tj\n0 -36 Td\n(Keep the order summary visible.) Tj\n0 -36 Td\n(Allow one retry after payment failure.) Tj\nET\n"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    var data = Data("%PDF-1.4\n".utf8)
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(data.count)
        data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
    }
    let xrefOffset = data.count
    data.append(contentsOf: "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
    for offset in offsets.dropFirst() {
        data.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
    }
    data.append(contentsOf: "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
    return data
}

private func scannedTextPDF() throws -> Data {
    let width = 1600
    let height = 800
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil) as CTFont? else {
        throw NSError(domain: "ProjectDocumentationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create OCR fixture context."])
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black.cgColor
    ]
    for (text, baseline) in [("SCANNED CHECKOUT", CGFloat(450)), ("KEEP PREVIEW VISIBLE", CGFloat(250))] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 100, y: baseline)
        CTLineDraw(line, context)
    }
    let cgImage = try #require(context.makeImage())
    let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    let page = try #require(PDFPage(image: image))
    let document = PDFDocument()
    document.insert(page, at: 0)
    return try #require(document.dataRepresentation())
}

private struct DocumentationHTTPStub: HTTPDataLoading, Sendable {
    let response: HTTPResult

    func data(for request: URLRequest) async throws -> HTTPResult { response }
    func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult { response }
}

private func makeDocumentationProviderResponse(
    title: String,
    body: String,
    classification: String,
    evidenceIDs: [String],
    sourceIDs: [String]
) throws -> String {
    let payload: [String: Any] = [
        "title": title,
        "sections": [[
            "title": "Observed",
            "body": body,
            "classification": classification,
            "evidenceIDs": evidenceIDs,
            "sourceIDs": sourceIDs
        ]]
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let payloadText = String(decoding: payloadData, as: UTF8.self)
    let envelope: [String: Any] = [
        "status": "completed",
        "output": [["content": [["type": "output_text", "text": payloadText]]]]
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]), as: UTF8.self)
}

private actor CountingDocumentationHTTPStub: HTTPDataLoading {
    let response: HTTPResult
    private var calls = 0

    init(response: HTTPResult) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> HTTPResult {
        calls += 1
        return response
    }

    func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult {
        calls += 1
        return response
    }

    func callCount() -> Int { calls }
}

private struct DocumentationFixture {
    let root: URL
    let databaseURL: URL
    let paths: LibraryPaths
    let store: VideoContextStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextDocumentationFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "library.sqlite")
        paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        store = try VideoContextStore(databaseURL: databaseURL)
    }

    func enableDocumentationSchema() throws {
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { database in
            if try !database.tableExists("project_document_sources") {
                try VideoContextStore.createProjectDocumentationSchema(in: database)
            }
        }
    }
}
