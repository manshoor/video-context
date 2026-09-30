import Foundation

/// Re-runs evidence review for one saved task while preserving its authored content.
public enum SavedTaskEvidenceReview {
    public static func review(
        reference: ProjectTaskReference,
        expectedRevision: Int,
        store: VideoContextStore,
        paths: LibraryPaths,
        projectContext: ProjectAnalysisContext?,
        reviewer: TaskEvidenceReviewer
    ) async throws {
        let projectContext = contextExcludingReviewedTask(projectContext, reference: reference)
        switch reference {
        case .recording(let videoID, let taskID):
            let snapshot = try await store.taskSnapshot(videoID: videoID)
            guard let task = snapshot.tasks.first(where: { $0.id == taskID }), task.revision == expectedRevision,
                  !task.archived, !task.isStale(snapshot.video), task.analysisIsStale != true else {
                throw TaskContextError.conflict
            }
            let sourceFingerprint = reviewFingerprint(reference: reference, content: task.content,
                source: "\(snapshot.video.revisions.transcript):\(snapshot.video.revisions.evidence):\(snapshot.video.revisions.brief)", projectFingerprint: projectContext?.sourceFingerprint)
            let result: (reviews: [TaskEvidenceReview], visualObservations: [[TaskVisualEvidenceObservation]])
            do {
                let batches = try await recordingBatches(snapshot: snapshot, paths: paths, projectContext: projectContext)
                result = try await reviewer.review(drafts: [generatedTask(from: task.content, id: task.id)], batches: batches,
                                                   sourceFingerprint: sourceFingerprint, checkpointStore: store,
                                                   projectID: snapshot.video.projectID)
            } catch {
                var content = task.content
                content.evidenceReview = TaskEvidenceReviewer.awaitingReview(configuration: reviewer.configuration,
                    sourceFingerprint: sourceFingerprint, error: error.localizedDescription)
                content.visualEvidenceObservations = []
                try await store.applySavedTaskReview(reference: reference, expectedRevision: expectedRevision,
                    expectedSource: snapshot.video.revisions, review: content.evidenceReview!, observations: [])
                throw error
            }
            try await saveRecordingResult(task: task, snapshot: snapshot, result: result, sourceFingerprint: sourceFingerprint, reviewer: reviewer, store: store)

        case .feedback(let batchID, let taskID):
            let snapshot = try await store.feedbackSnapshot(id: batchID)
            guard let task = snapshot.tasks.first(where: { $0.id == taskID }), task.revision == expectedRevision,
                  !task.archived, task.sourceRevision == snapshot.batch.revision, task.analysisIsStale != true else {
                throw TaskContextError.conflict
            }
            let sourceFingerprint = reviewFingerprint(reference: reference, content: task.content,
                source: String(snapshot.batch.revision), projectFingerprint: projectContext?.sourceFingerprint)
            let result: (reviews: [TaskEvidenceReview], visualObservations: [[TaskVisualEvidenceObservation]])
            do {
                let batches = try await feedbackBatches(snapshot: snapshot, store: store, paths: paths, projectContext: projectContext)
                result = try await reviewer.review(drafts: [generatedTask(from: task.content, id: task.id)], batches: batches,
                                                   sourceFingerprint: sourceFingerprint, checkpointStore: store,
                                                   projectID: snapshot.batch.projectID)
            } catch {
                var content = task.content
                content.evidenceReview = TaskEvidenceReviewer.awaitingReview(configuration: reviewer.configuration,
                    sourceFingerprint: sourceFingerprint, error: error.localizedDescription)
                content.visualEvidenceObservations = []
                try await store.applySavedTaskReview(reference: reference, expectedRevision: expectedRevision,
                    expectedBatchRevision: snapshot.batch.revision, review: content.evidenceReview!, observations: [])
                throw error
            }
            try await saveFeedbackResult(task: task, snapshot: snapshot, result: result, sourceFingerprint: sourceFingerprint, reviewer: reviewer, store: store)
        }
    }

    private static func contextExcludingReviewedTask(_ context: ProjectAnalysisContext?, reference: ProjectTaskReference) -> ProjectAnalysisContext? {
        guard let context else { return nil }
        return .init(projectID: context.projectID, selection: context.selection,
            fingerprint: context.sourceFingerprint, sourceFingerprint: context.sourceFingerprint,
            sourceManifest: context.sourceManifest, evidence: context.evidence,
            passages: context.passages.filter { !$0.id.hasPrefix("task:\(reference.taskID):") }, frames: context.frames,
            warnings: context.warnings, missingSourceIDs: context.missingSourceIDs, staleSourceIDs: context.staleSourceIDs,
            confirmedDecisions: context.confirmedDecisions, existingTasks: context.existingTasks.filter { $0.id != reference.taskID })
    }

    private static func generatedTask(from content: TaskContent, id: String) -> GeneratedTask {
        var value = GeneratedTask(targetTaskID: id, title: content.title, behavior: content.behavior,
            requirements: content.requirements.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) },
            checks: content.checks.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) },
            questions: content.questions.map { .init(question: $0.question, sourceIDs: $0.sourceIDs, category: $0.category) },
            sourceIDs: content.sourceIDs, dependencyTaskIDs: content.dependencyTaskIDs,
            projectEvidenceIDs: content.evidenceReferences.map(\.id))
        var reviewInput = content
        reviewInput.evidenceReview = nil
        reviewInput.visualEvidenceObservations = []
        value.analysisContent = reviewInput
        return value
    }

    private static func reviewFingerprint(reference: ProjectTaskReference, content: TaskContent,
                                          source: String, projectFingerprint: String?) -> String {
        var stable = content
        stable.evidenceReview = nil
        stable.visualEvidenceObservations = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(stable)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ProcessingFingerprint.make(["saved-task-review", reference.id, source, projectFingerprint ?? content.analysisSourceFingerprint ?? "", encoded])
    }

    private static func saveRecordingResult(task: VideoTask, snapshot: TaskLibrarySnapshot,
                                            result: (reviews: [TaskEvidenceReview], visualObservations: [[TaskVisualEvidenceObservation]]),
                                            sourceFingerprint: String, reviewer: TaskEvidenceReviewer, store: VideoContextStore) async throws {
        guard let review = result.reviews.first else { throw TaskEvidenceReviewError.invalidOutput }
        var content = task.content
        content.evidenceReview = review
        content.visualEvidenceObservations = result.visualObservations.first ?? []
        let questions = blockingQuestions(from: review, existing: content.questions)
        try await store.applySavedTaskReview(reference: .recording(videoID: task.videoID, taskID: task.id), expectedRevision: task.revision,
            expectedSource: snapshot.video.revisions, review: review, observations: content.visualEvidenceObservations, addedQuestions: questions)
    }

    private static func saveFeedbackResult(task: FeedbackTask, snapshot: FeedbackSnapshot,
                                           result: (reviews: [TaskEvidenceReview], visualObservations: [[TaskVisualEvidenceObservation]]),
                                           sourceFingerprint: String, reviewer: TaskEvidenceReviewer, store: VideoContextStore) async throws {
        guard let review = result.reviews.first else { throw TaskEvidenceReviewError.invalidOutput }
        var content = task.content
        content.evidenceReview = review
        content.visualEvidenceObservations = result.visualObservations.first ?? []
        let questions = blockingQuestions(from: review, existing: content.questions)
        try await store.applySavedTaskReview(reference: .feedback(batchID: task.batchID, taskID: task.id), expectedRevision: task.revision,
            expectedBatchRevision: snapshot.batch.revision, review: review, observations: content.visualEvidenceObservations, addedQuestions: questions)
    }

    private static func blockingQuestions(from review: TaskEvidenceReview, existing: [TaskQuestion]) -> [TaskQuestion] {
        review.findings.filter { $0.blocking }.compactMap { finding in
            let text = finding.message
            guard !existing.contains(where: { $0.question == text }) else { return nil }
            var question = TaskQuestion(question: text)
            question.category = finding.kind == .contradiction ? .productDecision : .missingEvidence
            question.disagreement = finding.kind == .contradiction ? text : ""
            return question
        }
    }

    private static func recordingBatches(snapshot: TaskLibrarySnapshot, paths: LibraryPaths,
                                         projectContext: ProjectAnalysisContext?) async throws -> [TaskEvidenceReviewBatch] {
        return try await TaskGenerator<AnyHTTPDataLoader>.reviewBatches(snapshot: snapshot, paths: paths, projectContext: projectContext)
    }

    private static func feedbackBatches(snapshot: FeedbackSnapshot, store: VideoContextStore, paths: LibraryPaths,
                                        projectContext: ProjectAnalysisContext?) async throws -> [TaskEvidenceReviewBatch] {
        var batches: [TaskEvidenceReviewBatch] = []
        func appendText(_ text: String, reference: ProjectEvidenceReference) {
            for part in LocalAnalysisBatchPlanner.pieces(text, budget: 12_000) {
                batches.append(.init(text: "EVIDENCE \(reference.id)\n\(part)", evidence: [reference]))
            }
        }
        for comment in snapshot.batch.comments {
            appendText("COMMENT [\(comment.kind.rawValue)]: \(comment.text)",
                reference: .feedback(batchID: snapshot.batch.id, sourceRevision: snapshot.batch.revision, commentID: comment.id, sourceID: nil))
        }
        let linkedIDs = Set(snapshot.batch.comments.flatMap(\.sourceIDs) + snapshot.batch.batchWideSourceIDs)
        for source in snapshot.batch.sources where linkedIDs.contains(source.id) {
            let reference = ProjectEvidenceReference.feedback(batchID: snapshot.batch.id, sourceRevision: snapshot.batch.revision, commentID: nil, sourceID: source.id)
            appendText("SOURCE status=\(source.status.rawValue)\nExtracted OCR: \(source.ocrText)\nAvailability: \(source.error ?? "available")", reference: reference)
            if source.kind == .image {
                guard source.status == .ready, let path = source.localPath else { throw TaskContextError.missing(source.id) }
                let image = try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: path), annotations: [])
                batches.append(.init(text: "IMAGE 1 EVIDENCE \(reference.id)", images: [image], evidence: [reference], authoritativeOCR: [reference.id: source.ocrText]))
            }
            if source.kind == .jam, let jam = source.jam {
                for item in jam.items {
                    if let text = item.text { appendText("JAM \(item.component.rawValue) \(item.id)\n\(text)", reference: reference) }
                    if let path = item.localPath {
                        let image = try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: path), annotations: [])
                        batches.append(.init(text: "IMAGE 1 EVIDENCE \(reference.id) JAM ITEM \(item.id). OCR unavailable.", images: [image], evidence: [reference], authoritativeOCR: [reference.id: ""]))
                    }
                }
            }
            if source.kind == .recording, let recordingID = source.recordingID {
                let recording = try await store.taskSnapshot(videoID: recordingID)
                guard recording.video.projectID == snapshot.batch.projectID else { throw TaskContextError.conflict }
                batches += try await TaskGenerator<AnyHTTPDataLoader>.reviewBatches(snapshot: recording, paths: paths, projectContext: nil)
            }
        }
        return try await combine(batches, context: projectContext)
    }

    private static func combine(_ primary: [TaskEvidenceReviewBatch], context: ProjectAnalysisContext?) async throws -> [TaskEvidenceReviewBatch] {
        guard let context else { return primary }
        var selected: [TaskEvidenceReviewBatch] = []
        for batch in context.batches(maxCharacters: 16_000, maxImages: 2) {
            var images: [Data] = []
            for url in batch.imageURLs { images.append(try await TaskFrameRenderer.render(url: url, annotations: [])) }
            let frameIDs = Set(batch.frameIDs)
            let ocr = Dictionary((context.frames.filter { frameIDs.contains($0.id) }).map { ($0.evidence.id, $0.ocrText) }, uniquingKeysWith: { first, _ in first })
            selected.append(TaskEvidenceReviewBatch(text: batch.promptText, images: images, evidence: batch.allowedEvidenceReferences, authoritativeOCR: ocr))
        }
        return selected.isEmpty ? primary : primary.flatMap { source in selected.map {
            .init(text: source.text + "\n\nPROJECT CROSS-REFERENCE:\n" +
                    ProjectAnalysisContextBatch.offsetImageLabels(in: $0.text, by: source.images.count, imageCount: $0.images.count),
                  images: source.images + $0.images,
                  evidence: Array(Set(source.evidence + $0.evidence)).sorted { $0.id < $1.id },
                  authoritativeOCR: source.authoritativeOCR.merging($0.authoritativeOCR) { first, _ in first })
        } }
    }
}

extension VideoContextStore {
    public func applySavedTaskReview(
        reference: ProjectTaskReference,
        expectedRevision: Int,
        expectedSource: ArtifactRevision,
        review: TaskEvidenceReview,
        observations: [TaskVisualEvidenceObservation],
        addedQuestions: [TaskQuestion] = []
    ) throws {
        guard case .recording(let videoID, let taskID) = reference else { throw TaskContextError.conflict }
        try pool.write { db in
            guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == expectedSource,
                  var task = try Self.fetchTasks(videoID: videoID, db: db).first(where: { $0.id == taskID }),
                  task.revision == expectedRevision, !task.archived, task.sourceRevision == video.revisions,
                  !task.isStale(video), task.analysisIsStale != true,
                  try !Self.taskAnalysisSourcesAreStale(task.content, projectID: video.projectID, db: db) else { throw TaskContextError.conflict }
            task.content.evidenceReview = review
            task.content.visualEvidenceObservations = observations
            task.content.evidenceReferences = Array(Set(task.content.evidenceReferences + observations.map(\.evidence) +
                review.findings.flatMap { $0.evidence + $0.conflictingEvidence })).sorted { $0.id < $1.id }
            for question in addedQuestions where !task.content.questions.contains(where: { $0.question == question.question }) {
                task.content.questions.append(question)
            }
            try Self.validateContent(task.content, videoID: videoID, db: db)
            task.revision += 1
            task.reviewedRevision = nil
            task.analysisIsStale = nil
            try Self.writeTask(task, db: db)
        }
    }

    public func applySavedTaskReview(
        reference: ProjectTaskReference,
        expectedRevision: Int,
        expectedBatchRevision: Int,
        review: TaskEvidenceReview,
        observations: [TaskVisualEvidenceObservation],
        addedQuestions: [TaskQuestion] = []
    ) throws {
        guard case .feedback(let batchID, let taskID) = reference else { throw TaskContextError.conflict }
        try pool.write { db in
            let batch = try Self.feedbackBatch(batchID, in: db)
            guard batch.revision == expectedBatchRevision,
                  var task = try Self.feedbackTasks(batchID, in: db).first(where: { $0.id == taskID }),
                  task.revision == expectedRevision, !task.archived, task.sourceRevision == batch.revision,
                  task.analysisIsStale != true,
                  try !Self.taskAnalysisSourcesAreStale(task.content, projectID: batch.projectID, db: db) else { throw TaskContextError.conflict }
            task.content.evidenceReview = review
            task.content.visualEvidenceObservations = observations
            task.content.evidenceReferences = Array(Set(task.content.evidenceReferences + observations.map(\.evidence) +
                review.findings.flatMap { $0.evidence + $0.conflictingEvidence })).sorted { $0.id < $1.id }
            for question in addedQuestions where !task.content.questions.contains(where: { $0.question == question.question }) {
                task.content.questions.append(question)
            }
            try Self.validateFeedbackTask(task.content, batch: batch)
            task.revision += 1
            task.approvedRevision = nil
            task.analysisIsStale = nil
            try Self.writeFeedbackTask(task, in: db)
        }
    }
}
