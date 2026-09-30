import Foundation
import Testing
@testable import VideoContextCore

private actor CancelledReviewHTTP: HTTPDataLoading {
    private(set) var requestCount = 0
    func data(for request: URLRequest) async throws -> HTTPResult {
        requestCount += 1
        throw CancellationError()
    }
}

struct TaskEvidenceReviewTests {
    private let configuration = ModelConfiguration(
        analysisProvider: .lmStudio,
        lmStudio: .init(modelID: "review-fixture"),
        claudeModel: "claude-fixture",
        deepSeekModel: "deepseek-fixture"
    )

    private func draft() -> GeneratedTask {
        .init(targetTaskID: "", title: "Save label", behavior: "Use Save",
              requirements: [.init(text: "Use Save", origin: .recording, sourceIDs: ["seg_test"])],
              checks: [.init(text: "Button displays Save", origin: .interpretation, sourceIDs: ["seg_test"])],
              questions: [], sourceIDs: ["seg_test"])
    }

    private func references() -> (ProjectEvidenceReference, ProjectEvidenceReference) {
        let revision = ArtifactRevision(transcript: 1, evidence: 1, brief: 1)
        return (
            .recording(videoID: "video-a", sourceRevision: revision, timestamp: 3, evidenceID: "seg_test"),
            .reviewedDocumentation(documentID: "main-doc", revision: 2, sectionID: "save")
        )
    }

    @Test("Contradictions always block and Apple OCR remains authoritative")
    func contradictionAndOCRIntegrity() async throws {
        let (recording, documentation) = references()
        let response = """
        {"findings":[{"draftIndex":0,"kind":"contradiction","message":"The labels conflict.","blocking":false,"evidenceIDs":["\(recording.id)"],"conflictingEvidenceIDs":["\(documentation.id)"]}],"visualObservations":[{"draftIndex":0,"evidenceID":"\(recording.id)","visualInterpretation":"The image shows Save.","extractedOCR":"MODEL REWROTE OCR","assessment":"discrepancy"}]}
        """
        let client = TaskTestHTTP([try TaskGenerationTests.result(response)])
        let result = try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(client),
            configuration: configuration, credential: "").review(
                drafts: [draft()],
                batches: [.init(text: "Original recording and reviewed documentation", images: [Data([1, 2, 3])],
                                evidence: [recording, documentation],
                                authoritativeOCR: [recording.id: "APPLE VISION OCR"])],
                sourceFingerprint: "source-v1")

        let finding = try #require(result.reviews.first?.findings.first)
        #expect(finding.kind == .contradiction)
        #expect(finding.blocking)
        #expect(finding.evidence == [recording])
        #expect(finding.conflictingEvidence == [documentation])
        #expect(result.visualObservations.first?.first?.extractedOCR == "APPLE VISION OCR")
    }

    @Test("A visual observation cannot cite text-only evidence")
    func textEvidenceCannotBecomeVisualObservation() async throws {
        let (_, documentation) = references()
        let response = """
        {"findings":[],"visualObservations":[{"draftIndex":0,"evidenceID":"\(documentation.id)","visualInterpretation":"Invented visual reading","extractedOCR":"invented","assessment":"consistent"}]}
        """
        let client = TaskTestHTTP([try TaskGenerationTests.result(response)])
        await #expect(throws: TaskEvidenceReviewError.invalidOutput) {
            try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(client), configuration: configuration,
                                           credential: "").review(
                drafts: [draft()], batches: [.init(text: "Reviewed text", evidence: [documentation])],
                sourceFingerprint: "source-v1")
        }
    }

    @Test("A contradiction must cite distinct evidence on both sides")
    func contradictionRejectsSameReference() async throws {
        let (recording, _) = references()
        let response = """
        {"findings":[{"draftIndex":0,"kind":"contradiction","message":"Invalid conflict","blocking":true,"evidenceIDs":["\(recording.id)"],"conflictingEvidenceIDs":["\(recording.id)"]}],"visualObservations":[]}
        """
        let client = TaskTestHTTP([try TaskGenerationTests.result(response)])
        await #expect(throws: TaskEvidenceReviewError.invalidOutput) {
            try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(client), configuration: configuration,
                                           credential: "").review(
                drafts: [draft()], batches: [.init(text: "Recording", evidence: [recording])],
                sourceFingerprint: "source-v1")
        }
    }

    @Test("Invalid returned findings do not poison a completed checkpoint")
    func invalidResponseCanRetry() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory
            .appending(path: "TaskEvidenceReviewTests-\(UUID())"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Review")
        let (recording, _) = references()
        let invalid = """
        {"findings":[{"draftIndex":0,"kind":"unsupportedClaim","message":"Bad citation","blocking":true,"evidenceIDs":["missing"],"conflictingEvidenceIDs":[]}],"visualObservations":[]}
        """
        let first = TaskTestHTTP([try TaskGenerationTests.result(invalid)])
        let batch = TaskEvidenceReviewBatch(text: "Recording", evidence: [recording])
        await #expect(throws: TaskEvidenceReviewError.invalidOutput) {
            try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(first), configuration: configuration,
                                           credential: "").review(
                drafts: [draft()], batches: [batch], sourceFingerprint: "source-v1",
                checkpointStore: store, projectID: project.id)
        }
        #expect(try await store.documentationAnalysisCheckpoints(projectID: project.id).first?.state == .failed)

        let second = TaskTestHTTP([try TaskGenerationTests.result(#"{"findings":[],"visualObservations":[]}"#)])
        let result = try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(second), configuration: configuration,
                                                    credential: "").review(
            drafts: [draft()], batches: [batch], sourceFingerprint: "source-v1",
            checkpointStore: store, projectID: project.id)
        #expect(result.reviews.first?.status == .passed)
        #expect(await second.requests.count == 1)
        #expect(try await store.documentationAnalysisCheckpoints(projectID: project.id).first?.state == .completed)
    }

    @Test("An uncertain provider outcome is not retried automatically")
    func uncertainOutcomeRequiresReconciliation() async throws {
        let paths = try LibraryPaths(root: FileManager.default.temporaryDirectory
            .appending(path: "TaskEvidenceReviewTests-\(UUID())"))
        let store = try VideoContextStore(databaseURL: paths.database)
        let project = try await store.createFeedbackProject(name: "Review")
        let (recording, _) = references()
        let batch = TaskEvidenceReviewBatch(text: "Recording", evidence: [recording])
        let first = TaskTestHTTP([])
        await #expect(throws: (any Error).self) {
            try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(first), configuration: configuration,
                                           credential: "").review(
                drafts: [draft()], batches: [batch], sourceFingerprint: "source-v1",
                checkpointStore: store, projectID: project.id)
        }
        #expect(try await store.documentationAnalysisCheckpoints(projectID: project.id).first?.state == .unknown)

        let second = TaskTestHTTP([try TaskGenerationTests.result(#"{"findings":[],"visualObservations":[]}"#)])
        await #expect(throws: (any Error).self) {
            try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(second), configuration: configuration,
                                           credential: "").review(
                drafts: [draft()], batches: [batch], sourceFingerprint: "source-v1",
                checkpointStore: store, projectID: project.id)
        }
        #expect(await second.requests.isEmpty)
    }

    @Test("Large draft sets are reviewed in bounded windows with stable global indices")
    func draftsAreBounded() async throws {
        let (recording, _) = references()
        let large = String(repeating: "Detailed requirement. ", count: 1_100)
        let drafts = [
            GeneratedTask(targetTaskID: "", title: "First", behavior: large,
                          requirements: [.init(text: "First", origin: .recording, sourceIDs: ["seg_test"])],
                          checks: [.init(text: "First works", origin: .recording, sourceIDs: ["seg_test"])],
                          questions: [], sourceIDs: ["seg_test"]),
            GeneratedTask(targetTaskID: "", title: "Second", behavior: large,
                          requirements: [.init(text: "Second", origin: .recording, sourceIDs: ["seg_test"])],
                          checks: [.init(text: "Second works", origin: .recording, sourceIDs: ["seg_test"])],
                          questions: [], sourceIDs: ["seg_test"])
        ]
        let empty = try TaskGenerationTests.result(#"{"findings":[],"visualObservations":[]}"#)
        let client = TaskTestHTTP(Array(repeating: empty, count: 8))
        let result = try await TaskEvidenceReviewer(client: AnyHTTPDataLoader(client),
            configuration: configuration, credential: "").review(
                drafts: drafts, batches: [.init(text: "Recording", evidence: [recording])],
                sourceFingerprint: "source-v1")
        #expect(result.reviews.count == 2)
        let bodies = await client.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(bodies.count >= 2)
        #expect(bodies.contains { $0.contains("DRAFT INDEX 0 FRAGMENT") })
        #expect(bodies.contains { $0.contains("DRAFT INDEX 1 FRAGMENT") })
        #expect(bodies.allSatisfy {
            $0.contains("DRAFT INDEX 0 FRAGMENT") != $0.contains("DRAFT INDEX 1 FRAGMENT")
        })
    }

    @Test("Interrupted independent review preserves generated proposals as awaiting review")
    func interruptedReviewPreservesDrafts() async throws {
        let (paths, store, snapshot, brief) = try await TaskGenerationTests().fixture()
        let extraction = TaskTestHTTP([
            try TaskGenerationTests.result(TaskGenerationTests.taskJSON),
            try TaskGenerationTests.result()
        ])
        let review = CancelledReviewHTTP()
        let generator = TaskGenerator(client: extraction, configuration: configuration, credential: "",
            reviewClient: AnyHTTPDataLoader(review), reviewConfiguration: configuration, reviewCredential: "")
        let proposals = try await generator.generate(snapshot: snapshot, brief: brief, paths: paths, store: store)
        #expect(proposals.count == 1)
        #expect(proposals.first?.content?.evidenceReview?.status == .awaitingReview)
        #expect(proposals.first?.content?.evidenceReview?.errorMessage?.contains("interrupted") == true)
        #expect(try await store.taskSnapshot(videoID: snapshot.video.id).proposals.count == 1)
        #expect(await review.requestCount == 1)
    }
}
