import Foundation
import Testing
@testable import VideoContextCore

struct ProjectGroundedGenerationTests {
    @Test("Task generation and independent review receive selected documentation and original recording evidence")
    func taskAndReviewShareExactGroundedEvidence() async throws {
        let fixture = try GroundedGenerationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Checkout")
        let video = VideoRecord(
            id: "grounded-video",
            title: "Checkout walkthrough",
            source: .localFile,
            sourceValue: "fixture",
            mediaRelativePath: "videos/grounded-video/original.mov",
            duration: 20,
            status: .ready,
            projectID: project.id
        )
        try await fixture.store.createVideo(video)
        let mediaURL = fixture.paths.absoluteURL(relativePath: video.mediaRelativePath)
        try FileManager.default.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: mediaURL)
        try await fixture.store.publishArtifacts(
            videoID: video.id,
            transcript: [.init(id: "seg-grounded", videoID: video.id, start: 2, end: 4, originalText: "The narrator requests a blue checkout button.")],
            evidence: [],
            brief: .init(videoID: video.id, markdown: "")
        )
        let section = ProjectDocumentationSection(
            id: "checkout-rule",
            title: "Checkout color",
            body: "The reviewed product reference requires a green checkout button.",
            classification: .requested
        )
        let document = try await fixture.store.createDocumentationDraft(
            projectID: project.id,
            title: "Main product reference",
            slug: "main-product-reference",
            sections: [section]
        )
        _ = try await fixture.store.reviewDocumentation(
            documentID: document.id,
            projectID: project.id,
            expectedRevision: document.currentRevision
        )
        try await fixture.store.saveProjectAnalysisSelection(
            projectID: project.id,
            selection: .init(documentIDs: [document.id], recordingIDs: [video.id])
        )
        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: project.id, paths: fixture.paths))
        let documentReference = ProjectEvidenceReference.reviewedDocumentation(
            documentID: document.id,
            revision: document.currentRevision,
            sectionID: section.id
        )
        let current = try await fixture.store.taskSnapshot(videoID: video.id)
        let recordingReference = ProjectEvidenceReference.recording(
            videoID: video.id,
            sourceRevision: current.video.revisions,
            timestamp: 2,
            evidenceID: "seg-grounded"
        )
        let generated = GeneratedTaskBatch(tasks: [.init(
            targetTaskID: "",
            title: "Resolve checkout color",
            behavior: "Implement the reviewed checkout behavior.",
            requirements: [.init(text: "Use the stated checkout behavior.", origin: .recording, sourceIDs: ["seg-grounded"])],
            checks: [.init(text: "The checkout behavior is visible.", origin: .interpretation, sourceIDs: ["seg-grounded"])],
            questions: [],
            sourceIDs: ["seg-grounded"],
            projectEvidenceIDs: [documentReference.id]
        )])
        let generatedResponse = try lmStudioEnvelope(generated)
        let emptyResponse = try lmStudioEnvelope(GeneratedTaskBatch(tasks: []))
        let extraction = GroundedHTTP(responses: [generatedResponse] + Array(repeating: emptyResponse, count: 20))
        let reviewPayload = """
        {"findings":[{"draftIndex":0,"kind":"contradiction","message":"The recording requests blue while the reviewed reference requires green.","blocking":true,"evidenceIDs":["\(recordingReference.id)"],"conflictingEvidenceIDs":["\(documentReference.id)"]}],"visualObservations":[]}
        """
        let reviewResponse = try lmStudioEnvelope(reviewPayload)
        let review = GroundedHTTP(responses: Array(repeating: reviewResponse, count: 20))
        let configuration = ModelConfiguration(analysisProvider: .lmStudio, lmStudio: .init(modelID: "fixture"))
        let proposals = try await TaskGenerator(
            client: extraction,
            configuration: configuration,
            credential: "",
            reviewClient: AnyHTTPDataLoader(review),
            reviewConfiguration: configuration,
            reviewCredential: ""
        ).generate(
            snapshot: current,
            brief: .init(videoID: video.id, markdown: ""),
            paths: fixture.paths,
            store: fixture.store,
            projectContext: context
        )

        let extractionBodies = await extraction.requestBodies
        let extractionBody = try #require(extractionBodies.first)
        #expect(extractionBody.contains("The reviewed product reference requires a green checkout button."))
        #expect(extractionBody.contains("The narrator requests a blue checkout button."))
        #expect(extractionBody.contains(documentReference.id))
        let reviewBodies = await review.requestBodies
        let reviewBody = try #require(reviewBodies.first)
        #expect(reviewBody.contains("The reviewed product reference requires a green checkout button."))
        #expect(reviewBody.contains("The narrator requests a blue checkout button."))
        #expect(reviewBody.contains(documentReference.id))
        #expect(reviewBody.contains(recordingReference.id))

        let proposal = try #require(proposals.first)
        let content = try #require(proposal.content)
        #expect(Set(content.evidenceReferences) == [documentReference, recordingReference])
        let finding = try #require(content.evidenceReview?.findings.first)
        #expect(finding.evidence == [recordingReference])
        #expect(finding.conflictingEvidence == [documentReference])
        let conflict = try #require(content.questions.first { $0.category == .productDecision })
        #expect(conflict.sourceIDs == ["seg-grounded"])
        #expect(conflict.sourceIDs.contains(documentReference.id) == false)
    }

    @Test("Documentation replacement excludes its own direct citation while retaining cross-reference text and underlying evidence")
    func documentationReplacementFiltersSelfCitation() async throws {
        let targetReference = ProjectEvidenceReference.reviewedDocumentation(documentID: "main-doc", revision: 3, sectionID: "requirements")
        let underlying = ProjectEvidenceReference.document(sourceID: "imported-spec", revision: 2, locator: .init(markdownLine: 10, endLine: 12))
        let context = ProjectAnalysisContext(
            projectID: "project-a",
            selection: .init(documentIDs: ["main-doc"]),
            fingerprint: "context-fingerprint",
            sourceFingerprint: "source-fingerprint",
            sourceManifest: [],
            evidence: [targetReference, underlying],
            passages: [.init(
                id: "main-doc-section",
                sourceID: "documentation:main-doc",
                title: "Existing reviewed requirements",
                kind: .reviewedDocumentation,
                revision: "r3",
                text: "Preserve this cross-reference text in the replacement.",
                classification: .requested,
                evidence: [targetReference, underlying]
            )],
            frames: []
        )
        let payload: [String: Any] = [
            "title": "Replacement",
            "sections": [[
                "title": "Requirements",
                "body": "Preserve the referenced behavior.",
                "classification": "requested",
                "evidenceIDs": [underlying.id],
                "sourceIDs": ["analysis-context:main-doc-section"]
            ]]
        ]
        let client = GroundedHTTP(responses: [try lmStudioEnvelope(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))])
        let input = ProjectDocumentationGenerationInput(
            projectID: "project-a",
            projectName: "Project A",
            requestedTitle: "Replacement",
            sources: [.init(id: "seed", title: "Seed", kind: "request", revision: "r1", text: "Update the product reference.")],
            targetDocumentID: "main-doc"
        )
        let result = try await ProjectDocumentationGenerator(
            client: client,
            configuration: .init(analysisProvider: .lmStudio, lmStudio: .init(modelID: "fixture")),
            credential: ""
        ).generate(input: input, projectContext: context)

        let bodies = await client.requestBodies
        let body = try #require(bodies.first)
        #expect(body.contains("Preserve this cross-reference text in the replacement."))
        #expect(body.contains(underlying.id))
        #expect(body.contains(targetReference.id) == false)
        #expect(result.sections.first?.evidence == [underlying])
    }

    @Test("Legacy task content decodes with safe analysis defaults")
    func legacyTaskContentDecoding() throws {
        let legacy = #"{"title":"Legacy","behavior":"Keep behavior","requirements":[],"checks":[],"questions":[],"sourceIDs":["seg-old"],"annotations":[]}"#
        let content = try JSONDecoder().decode(TaskContent.self, from: Data(legacy.utf8))
        #expect(content.evidenceReferences.isEmpty)
        #expect(content.evidenceReview == nil)
        #expect(content.visualEvidenceObservations.isEmpty)
        #expect(content.analysisSourceManifest.isEmpty)
        #expect(content.dependencyTaskIDs.isEmpty)
        #expect(content.analysisSourceFingerprint == nil)
    }

    @Test("An uncited selected source stays freshness-relevant through its frozen manifest")
    func uncitedSelectedSourceManifestControlsFreshness() async throws {
        let fixture = try GroundedGenerationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Manifest freshness")
        let video = VideoRecord(
            id: "manifest-video",
            title: "Manifest task source",
            source: .localFile,
            sourceValue: "fixture",
            mediaRelativePath: "manifest.mov",
            projectID: project.id
        )
        try await fixture.store.createVideo(video)
        let section = ProjectDocumentationSection(
            id: "manifest-rule",
            title: "Manifest rule",
            body: "Keep the selected source relevant even when this task does not cite its text.",
            classification: .requested
        )
        let document = try await fixture.store.createDocumentationDraft(
            projectID: project.id,
            title: "Selected product reference",
            slug: "selected-product-reference",
            sections: [section]
        )
        _ = try await fixture.store.reviewDocumentation(
            documentID: document.id,
            projectID: project.id,
            expectedRevision: document.currentRevision
        )
        let selection = ProjectAnalysisSelection(documentIDs: [document.id])
        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: selection)
        let context = try #require(try await fixture.store.projectAnalysisContext(projectID: project.id, paths: fixture.paths))
        #expect(context.sourceManifest.contains { $0.sourceID == "documentation:\(document.id)" })
        let content = TaskContent(
            title: "Uncited manifest task",
            behavior: "Keep existing behavior.",
            checks: [.init(text: "Existing behavior remains available.", origin: .interpretation)],
            evidenceReferences: [],
            analysisSourceManifest: TaskGenerator<AnyHTTPDataLoader>.sourceManifest(context),
            analysisSourceFingerprint: context.sourceFingerprint
        )
        _ = try await fixture.store.saveTask(
            .init(id: "manifest-task", videoID: video.id, sourceRevision: video.revisions, content: content),
            expectedRevision: nil,
            expectedSource: video.revisions
        )
        #expect(try await fixture.store.taskSnapshot(videoID: video.id).tasks.first?.analysisIsStale == false)

        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: .init())
        #expect(try await fixture.store.taskSnapshot(videoID: video.id).tasks.first?.analysisIsStale == true)

        try await fixture.store.saveProjectAnalysisSelection(projectID: project.id, selection: selection)
        #expect(try await fixture.store.taskSnapshot(videoID: video.id).tasks.first?.analysisIsStale == false)
        _ = try await fixture.store.saveDocumentationDraft(.init(
            documentID: document.id,
            projectID: project.id,
            expectedRevision: document.currentRevision,
            title: document.title,
            slug: document.slug,
            markdown: "",
            sections: [.init(id: section.id, title: section.title, body: "The selected reference changed.", classification: .requested)]
        ))
        #expect(try await fixture.store.taskSnapshot(videoID: video.id).tasks.first?.analysisIsStale == true)
    }

    @Test("Saving a project task rejects a dependency cycle")
    func dependencyCycleIsRejected() async throws {
        let fixture = try GroundedGenerationFixture()
        let project = try await fixture.store.createFeedbackProject(name: "Dependencies")
        let video = VideoRecord(id: "dependency-video", title: "Dependencies", source: .localFile, sourceValue: "fixture", mediaRelativePath: "dependency.mov", projectID: project.id)
        try await fixture.store.createVideo(video)
        let first = try await fixture.store.saveTask(.init(id: "task-first", videoID: video.id, sourceRevision: video.revisions, content: .init(title: "First")), expectedRevision: nil, expectedSource: video.revisions)
        let second = try await fixture.store.saveTask(.init(id: "task-second", videoID: video.id, sourceRevision: video.revisions, content: .init(title: "Second")), expectedRevision: nil, expectedSource: video.revisions)
        var firstEdit = first
        firstEdit.content.dependencyTaskIDs = [second.id]
        _ = try await fixture.store.saveTask(firstEdit, expectedRevision: first.revision, expectedSource: video.revisions)
        var secondEdit = second
        secondEdit.content.dependencyTaskIDs = [first.id]
        await #expect(throws: (any Error).self) {
            try await fixture.store.saveTask(secondEdit, expectedRevision: second.revision, expectedSource: video.revisions)
        }
    }
}

private struct GroundedGenerationFixture {
    let root: URL
    let paths: LibraryPaths
    let store: VideoContextStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ProjectGroundedGenerationTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = try LibraryPaths(root: root.appending(path: "library", directoryHint: .isDirectory))
        store = try VideoContextStore(databaseURL: paths.database)
    }
}

private actor GroundedHTTP: HTTPDataLoading {
    private var responses: [HTTPResult]
    private(set) var requestBodies: [String] = []

    init(responses: [HTTPResult]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> HTTPResult {
        requestBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        guard !responses.isEmpty else { throw TaskContextError.invalid("Unexpected grounded-generation provider request.") }
        return responses.removeFirst()
    }
}

private func lmStudioEnvelope<T: Encodable>(_ value: T) throws -> HTTPResult {
    let data = try JSONEncoder().encode(value)
    return try lmStudioEnvelope(String(decoding: data, as: UTF8.self))
}

private func lmStudioEnvelope(_ output: String) throws -> HTTPResult {
    let envelope: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": output]]]]
    return .init(data: try JSONSerialization.data(withJSONObject: envelope), statusCode: 200)
}
