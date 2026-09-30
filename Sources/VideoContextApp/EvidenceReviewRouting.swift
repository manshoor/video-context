import VideoContextCore

extension AppModel {
    func reviewSavedProjectTaskEvidence() async {
        guard !isUIFixture, let draft = taskDraft, !draft.dirty, !draft.saving, !draft.archived,
              let store, let paths, let projectID = selectedProjectID else { return }
        guard let configuration = modelConfiguration.reviewConfiguration else {
            draft.error = "Enable independent evidence review in Settings first."
            return
        }
        guard credentialReady(for: configuration.analysisProvider), let client = evidenceReviewClient(configuration: configuration) else {
            draft.error = "Unlock or enter the \(configuration.analysisProvider.label) credential before reviewing evidence."
            return
        }
        let credential = credentialValue(for: configuration.analysisProvider)
        let reference = draft.reference
        let revision = draft.revision
        draft.saving = true
        defer { draft.saving = false }
        do {
            let context = try await projectAnalysisInput(projectID: projectID, store: store, paths: paths)
            try await withUsageRun(operation: .taskGeneration, videoID: draft.recording?.video.id ?? draft.feedback?.batch.videoID,
                configuration: configuration, source: draft.recording?.video.revisions,
                feedbackBatchID: draft.feedback?.batch.id, feedbackRevision: draft.feedback?.batch.revision,
                projectID: projectID, projectAnalysisFingerprint: context?.fingerprint) {
                    try await SavedTaskEvidenceReview.review(reference: reference, expectedRevision: revision,
                        store: store, paths: paths, projectContext: context,
                        reviewer: .init(client: client, configuration: configuration, credential: credential))
                }
            switch reference {
            case .recording(let videoID, _): draft.recording = try await store.taskSnapshot(videoID: videoID)
            case .feedback(let batchID, _): draft.feedback = try await store.feedbackSnapshot(id: batchID)
            }
            if let saved = draft.videoTask?.content ?? draft.feedbackTask?.content {
                draft.content = saved; draft.savedContent = saved
            }
            draft.error = nil
            await loadSelection()
        } catch {
            let message = error.localizedDescription
            // A failed provider call can still persist an awaiting-review
            // revision. Keep the editor on that saved revision for recovery.
            switch reference {
            case .recording(let videoID, _):
                if let latest = try? await store.taskSnapshot(videoID: videoID) { draft.recording = latest }
            case .feedback(let batchID, _):
                if let latest = try? await store.feedbackSnapshot(id: batchID) { draft.feedback = latest }
            }
            if let saved = draft.videoTask?.content ?? draft.feedbackTask?.content {
                draft.content = saved; draft.savedContent = saved
            }
            draft.error = message
            await loadSelection()
        }
    }

    func projectAnalysisInput(projectID: String, store: VideoContextStore, paths: LibraryPaths) async throws -> ProjectAnalysisContext? {
        let context = try await store.projectAnalysisContext(projectID: projectID, paths: paths)
        projectAnalysisWarnings = context?.warnings.map(\.message) ?? []
        return context
    }

    func evidenceReviewClient(configuration: ModelConfiguration?) -> AnyHTTPDataLoader? {
        guard let configuration else { return nil }
        return AnyHTTPDataLoader(UsageRecordingClient(
            base: transport(for: configuration.analysisProvider),
            provider: configuration.analysisProvider.identity,
            model: configuration.selectedAnalysisModel,
            stage: .evidenceReview
        ))
    }
}
