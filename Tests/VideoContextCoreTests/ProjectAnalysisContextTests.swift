import Foundation
import Testing
@testable import VideoContextCore

struct ProjectAnalysisContextTests {
    @Test("A saved selection assembles only designated reviewed evidence")
    func selectedEvidenceBuildsFrozenContext() async throws {
        let fixture = try ProjectAnalysisFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        let other = try await fixture.store.createFeedbackProject(name: "Other")

        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# Checkout\n\nKeep the preview visible.".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        let unit = try #require(imported.revision.units.last)
        let sourceEvidence = ProjectEvidenceReference.document(sourceID: imported.source.id, revision: imported.revision.revision, locator: unit.locator)
        let section = ProjectDocumentationSection(title: "Preview", body: "Keep the preview visible.", classification: .requested, evidence: [sourceEvidence])
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Checkout", slug: "checkout", sections: [section])
        _ = try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)

        let recording = VideoRecord(id: "vid_selected", title: "Walkthrough", source: .localFile, sourceValue: "fixture", mediaRelativePath: "videos/vid_selected/video.mp4", status: .ready, projectID: project.id)
        let excluded = VideoRecord(id: "vid_excluded", title: "Excluded", source: .localFile, sourceValue: "fixture", mediaRelativePath: "videos/vid_excluded/video.mp4", status: .ready, projectID: project.id)
        let foreign = VideoRecord(id: "vid_foreign", title: "Foreign", source: .localFile, sourceValue: "fixture", mediaRelativePath: "videos/vid_foreign/video.mp4", status: .ready, projectID: other.id)
        try await fixture.store.createVideo(recording)
        try await fixture.store.createVideo(excluded)
        try await fixture.store.createVideo(foreign)
        let mediaURL = fixture.paths.absoluteURL(relativePath: recording.mediaRelativePath)
        try FileManager.default.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: mediaURL)
        let frameURL = fixture.paths.absoluteURL(relativePath: "videos/vid_selected/frames/frame.jpg")
        try FileManager.default.createDirectory(at: frameURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: frameURL)
        try await fixture.store.publishArtifacts(
            videoID: recording.id,
            transcript: [.init(id: "seg_selected", videoID: recording.id, start: 1, end: 2, originalText: "The preview stays visible")],
            evidence: [.init(id: "ev_selected", videoID: recording.id, timestamp: 1.5, imageRelativePath: fixture.paths.relativePath(for: frameURL), ocrText: "Preview", origin: .automatic)],
            brief: .init(videoID: recording.id, markdown: "# Brief")
        )
        let currentRecording = try #require(try await fixture.store.videoSnapshot(id: recording.id)?.video)
        _ = try await fixture.store.saveTask(.init(videoID: recording.id, sourceRevision: currentRecording.revisions,
            content: .init(title: "Keep preview", behavior: "Keep it visible", checks: [.init(text: "Preview remains visible")], sourceIDs: ["seg_selected"])),
            expectedRevision: nil, expectedSource: currentRecording.revisions)
        _ = try await fixture.store.saveProjectDecision(.init(projectID: project.id, key: "preview", question: "Keep preview visible?", answer: "Yes", evidence: [sourceEvidence], state: .confirmed))

        let selection = ProjectAnalysisSelection(documentIDs: [document.id], recordingIDs: [recording.id], documentSourceIDs: [imported.source.id])
        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: selection)
        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: project.id, paths: fixture.paths))

        #expect(context.selection == selection)
        #expect(context.passages.contains { $0.text.contains("Keep the preview visible") })
        #expect(context.passages.contains { $0.text.contains("The preview stays visible") })
        #expect(context.passages.contains { $0.text.contains("Excluded") } == false)
        #expect(context.frames.map(\.id) == ["ev_selected"])
        #expect(context.confirmedDecisions.map(\.key) == ["preview"])
        #expect(context.existingTasks.map(\.title) == ["Keep preview"])
        #expect(context.missingSourceIDs.isEmpty)
        #expect(context.staleSourceIDs.isEmpty)
        #expect(context.fingerprint.isEmpty == false)

        let batches = context.batches(maxCharacters: 600, maxImages: 1)
        #expect(Set(batches.flatMap(\.passageIDs)) == Set(context.passages.map(\.id)))
        #expect(batches.flatMap(\.imageURLs) == context.frames.map(\.imageURL))
        #expect(Set(batches.flatMap(\.allowedEvidenceReferences)) == Set(context.evidence))
        #expect(batches.allSatisfy { $0.promptText.count <= 600 && $0.imageURLs.count <= 1 })
        #expect(batches.contains { $0.promptText.contains("kind=reviewedDocumentation classification=requested") })
        let imageBatch = try #require(batches.first { $0.frameIDs.contains("ev_selected") })
        #expect(imageBatch.promptText.contains("[image=1 frame=ev_selected evidence="))
        #expect(imageBatch.promptText.contains("FULL OCR PASSAGE: recording:vid_selected:frame:ev_selected:ocr"))
        #expect(batches.contains { $0.promptText.contains("Extracted OCR at 00:01") && $0.promptText.contains("Preview") })
        #expect(imageBatch.promptText.contains("VISUAL INTERPRETATION: not supplied"))
        let shiftedImagePrompt = imageBatch.promptText(imageOffset: 3)
        #expect(shiftedImagePrompt.contains("[image=4 frame=ev_selected evidence="))
        #expect(shiftedImagePrompt.contains("frame=ev_selected"))
        #expect(imageBatch.promptText.contains("[image=1 frame=ev_selected evidence="))
        let shiftedPair = ProjectAnalysisContextBatch.offsetImageLabels(
            in: "[image=1 frame=first evidence=a]\n[image=2 frame=second evidence=b]",
            by: 2,
            imageCount: 2
        )
        #expect(shiftedPair == "[image=3 frame=first evidence=a]\n[image=4 frame=second evidence=b]")
    }

    @Test("Selected imported files report changes and refresh only on request")
    func explicitImportedSourceRefresh() async throws {
        let fixture = try ProjectAnalysisFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        let sourceURL = fixture.root.appending(path: "requirements.md")
        try "# Checkout\n\nKeep the preview visible.".write(to: sourceURL, atomically: true, encoding: .utf8)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: sourceURL, paths: fixture.paths)
        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: .init(documentSourceIDs: [imported.source.id]))

        #expect(try await fixture.store.projectAnalysisSourceStatuses(projectID: project.id, paths: fixture.paths).first?.status == .current)
        try "# Checkout\n\nShow an error state.".write(to: sourceURL, atomically: true, encoding: .utf8)
        #expect(try await fixture.store.projectAnalysisSourceStatuses(projectID: project.id, paths: fixture.paths).first?.status == .changed)
        #expect(try await fixture.store.projectDocumentSource(projectID: project.id, sourceID: imported.source.id)?.1.revision == 1)

        let refreshed = try await fixture.store.refreshProjectAnalysisSource(projectID: project.id, sourceID: imported.source.id, paths: fixture.paths)
        #expect(refreshed.revision.revision == 2)
        #expect(try await fixture.store.projectAnalysisSourceStatuses(projectID: project.id, paths: fixture.paths).first?.status == .current)
    }

    @Test("Reviewed documentation sections are exact citations with frozen historical retrieval")
    func reviewedDocumentationIsDirectlyCitable() async throws {
        let fixture = try ProjectAnalysisFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Reviewed reference")
        let section = ProjectDocumentationSection(id: "preview-section", title: "Preview", body: "Keep the preview visible.", classification: .requested)
        let document = try await fixture.store.createDocumentationDraft(projectID: project.id, title: "Product reference", slug: "product-reference", sections: [section])
        _ = try await fixture.store.reviewDocumentation(documentID: document.id, projectID: project.id, expectedRevision: document.currentRevision)
        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: .init(documentIDs: [document.id]))

        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: project.id, paths: fixture.paths))
        let passage = try #require(context.passages.first { $0.id.contains(section.id) })
        let reference = try #require(passage.evidence.first { evidence in
            guard case .reviewedDocumentation(let documentID, let revision, let sectionID) = evidence else { return false }
            return documentID == document.id && revision == document.currentRevision && sectionID == section.id
        })
        #expect(context.evidence.contains(reference))
        #expect(try await fixture.store.validateEvidenceReference(reference, projectID: project.id).status == .valid)

        let service = ProjectMCPService(store: fixture.store)
        let exact = try await service.evidence(projectID: project.id, reference: reference, paths: fixture.paths)
        #expect(exact.text == section.body)
        #expect(exact.locator.contains(section.id))
        #expect(exact.freshness == .current)

        _ = try await fixture.store.saveDocumentationDraft(.init(
            documentID: document.id,
            projectID: project.id,
            expectedRevision: document.currentRevision,
            title: document.title,
            slug: document.slug,
            markdown: "",
            sections: [.init(id: section.id, title: section.title, body: "Replace the preview.", classification: .requested)]
        ))
        #expect(try await fixture.store.validateEvidenceReference(reference, projectID: project.id).status == .stale)
        let historical = try await service.evidence(projectID: project.id, reference: reference, paths: fixture.paths)
        #expect(historical.text == "Keep the preview visible.")
        #expect(historical.freshness == .stale)

        let other = try await fixture.store.createFeedbackProject(name: "Other project")
        await #expect(throws: (any Error).self) {
            try await service.evidence(projectID: other.id, reference: reference, paths: fixture.paths)
        }
    }

    @Test("Selection rejects evidence owned by another project and empty selection restores legacy behavior")
    func selectionIsProjectScopedAndOptional() async throws {
        let fixture = try ProjectAnalysisFixture()
        let first = try await fixture.store.createFeedbackProject(name: "First")
        let second = try await fixture.store.createFeedbackProject(name: "Second")
        let foreign = VideoRecord(id: "vid_foreign", title: "Foreign", source: .localFile, sourceValue: "fixture", mediaRelativePath: "foreign.mp4", projectID: second.id)
        try await fixture.store.createVideo(foreign)

        await #expect(throws: ProjectAnalysisStoreError.self) {
            try await fixture.store.saveProjectAnalysisSelection(projectID: first.id, selection: .init(recordingIDs: [foreign.id]))
        }
        #expect(try await fixture.store.projectAnalysisSelection(projectID: first.id) == nil)
        try await fixture.store.saveProjectAnalysisSelection(projectID: first.id, selection: .init())
        #expect(try await fixture.store.projectAnalysisContext(projectID: first.id, paths: fixture.paths) == nil)
    }

    @Test("Imported document images remain original visual evidence")
    func importedDocumentImagesAreBatched() async throws {
        let fixture = try ProjectAnalysisFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Visual reference")
        let markdown = fixture.root.appending(path: "visual.md")
        let image = fixture.root.appending(path: "screen.png")
        try "# Preview\n\n![Current preview](screen.png)".write(to: markdown, atomically: true, encoding: .utf8)
        try Data([137, 80, 78, 71, 1, 2, 3]).write(to: image)
        let imported = try await fixture.store.importDocumentSource(projectID: project.id, sourceURL: markdown, paths: fixture.paths, selectedAttachments: [image])
        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: .init(documentSourceIDs: [imported.source.id]))

        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: project.id, paths: fixture.paths))
        let frame = try #require(context.frames.first)
        #expect(frame.sourceID == "document:\(imported.source.id)")
        #expect(frame.videoID == nil)
        #expect(frame.evidence.sourceID == "document:\(imported.source.id)")
        #expect(context.batches().flatMap(\.frameIDs).contains(frame.id))
    }

    @Test("Missing original recording media is visible and blocks grounded approval")
    func missingRecordingMediaIsReported() async throws {
        let fixture = try ProjectAnalysisFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Missing footage")
        let recording = VideoRecord(id: "vid_missing_media", title: "Walkthrough", source: .localFile, sourceValue: "fixture",
                                    mediaRelativePath: "videos/vid_missing_media/missing.mp4", status: .ready, projectID: project.id)
        try await fixture.store.createVideo(recording)
        try await fixture.store.replaceTranscript(videoID: recording.id,
            segments: [.init(id: "seg_missing_media", videoID: recording.id, start: 0, end: 1, originalText: "Keep preview visible")])
        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: .init(recordingIDs: [recording.id]))

        let status = try #require(try await fixture.store.projectAnalysisSourceStatuses(projectID: project.id, paths: fixture.paths).first)
        #expect(status.status == .unavailable)
        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: project.id, paths: fixture.paths))
        #expect(context.missingSourceIDs == [recording.id])
        #expect(context.warnings.contains { $0.sourceID == recording.id && $0.kind == .unavailable })
    }
}

private struct ProjectAnalysisFixture {
    let root: URL
    let paths: LibraryPaths
    let store: VideoContextStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ProjectAnalysisContextTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        store = try VideoContextStore(databaseURL: paths.database)
    }
}
