import Foundation
import VideoContextCore

extension AppModel {
    var taskProviderLabel: String { taskConfiguration.analysisDescription }
    func generateTasks() {
        guard !isUIFixture else { errorMessage = "Task generation is disabled in the demo library. Use the fixture tasks to review the workflow."; return }
        guard !isProcessing, !checkingCloudProvider, let store, let paths, let snapshot, snapshot.video.status == .ready, !snapshot.video.revisions.isBriefStale, let brief = snapshot.brief else { return }
        guard let projectID = snapshot.video.projectID else { errorMessage = "Assign this recording to a project before generating tasks."; return }
        taskGenerationVideoID = snapshot.video.id
        var configuration = taskConfiguration
        let credential = credentialValue(for: configuration.analysisProvider)
        let reviewConfiguration = modelConfiguration.reviewConfiguration
        let reviewCredential = reviewConfiguration.map { credentialValue(for: $0.analysisProvider) }
        let reviewClient = evidenceReviewClient(configuration: reviewConfiguration)
        guard credentialReady(for: configuration.analysisProvider) else { errorMessage = "Unlock or enter the \(configuration.analysisProvider.label) credential before generating tasks."; return }
        let videoID = snapshot.video.id
        activity = AppActivity(videoID: videoID, recordingTitle: snapshot.video.title, phase: .processing(.analyzing))
        activity?.detail = "Preparing task generation"
        taskGenerationMessage = nil
        taskGenerationTask = Task { [weak self] in
            guard let self else { return }
            await self.runDiagnosed(.taskGeneration, videoID: videoID) {
                do {
                    let source = try await store.taskSnapshot(videoID: videoID)
                    guard source.video.revisions == snapshot.video.revisions, source.video.projectID == projectID else { throw TaskContextError.conflict }
                    let projectContext = try await self.projectAnalysisInput(projectID: projectID, store: store, paths: paths)
                    let frozen = configuration
                    let proposals = try await self.withUsageRun(operation: .taskGeneration, videoID: videoID, configuration: frozen, source: source.video.revisions,
                        projectID: source.video.projectID, projectAnalysisFingerprint: projectContext?.fingerprint) {
                        var contextLength = 32_768
                        if configuration.analysisProvider == .lmStudio {
                            let instance = try await LMStudioService(client: self.localHTTP).loadedModel(configuration: configuration.lmStudio, token: credential)
                            configuration.lmStudio.modelID = instance.id; contextLength = instance.config.contextLength
                        }
                        let client = UsageRecordingClient(base: self.transport(for: configuration.analysisProvider), provider: configuration.analysisProvider.identity, model: frozen.selectedAnalysisModel, stage: .taskExtraction)
                        let guardedClient = AnalysisOutcomeGuard(base: client, store: store, projectID: projectID,
                            sourceIdentity: source.signature + ":" + (projectContext?.fingerprint ?? "legacy"))
                        try Task.checkCancellation()
                        let generator = TaskGenerator(client: guardedClient, configuration: configuration, credential: credential, contextLength: contextLength,
                            reviewClient: reviewClient, reviewConfiguration: reviewConfiguration, reviewCredential: reviewCredential)
                        return try await generator.generate(snapshot: source, brief: brief, paths: paths, store: store,
                            projectContext: projectContext, progress: { [weak self] progress in await self?.updateTaskActivity(progress) })
                    }
                    self.taskGenerationMessage = proposals.isEmpty ? "No actionable tasks found." : "\(proposals.count) proposed changes. Review them before applying."
                    await DiagnosticTrace.record(.completed)
                } catch is CancellationError { await DiagnosticTrace.record(.cancelled); self.taskGenerationMessage = "Task generation paused. Generate again to reuse validated batches." }
                catch {
                    await DiagnosticTrace.record(Task.isCancelled ? .cancelled : .failed, error: error)
                    if Task.isCancelled { self.taskGenerationMessage = "Task generation paused. Generate again to reuse validated batches." }
                    else { self.errorMessage = error.localizedDescription; self.taskGenerationMessage = "Task generation stopped. Saved tasks and evidence were preserved." }
                }
                self.activity = nil; self.taskGenerationTask = nil
                await self.loadLibrary()
            }
        }
    }

    private func updateTaskActivity(_ progress: ProcessingProgress) async {
        await DiagnosticTrace.record(.stateChanged, stage: progress.stage, completed: progress.completed, total: progress.total)
        activity?.update(progress)
    }
    func saveVideoTask(_ draft: VideoTask, expectedRevision: Int?, expectedSource: ArtifactRevision) async -> VideoTask? {
        guard let store else { return nil }
        do {
            let saved = try await store.saveTask(draft, expectedRevision: expectedRevision, expectedSource: expectedSource)
            await loadSelection(); return saved
        } catch { await recordDiagnosticFailure(error, videoID: draft.videoID, taskID: draft.id, revision: expectedRevision); errorMessage = error.localizedDescription; return nil }
    }
    func reviewVideoTask(_ task: VideoTask, source: ArtifactRevision) async {
        guard let store else { return }
        do { try await store.reviewTask(videoID: task.videoID, taskID: task.id, expectedRevision: task.revision, expectedSource: source); await loadSelection() }
        catch { await recordDiagnosticFailure(error, operation: .review, videoID: task.videoID, taskID: task.id, revision: task.revision); errorMessage = error.localizedDescription }
    }
    func resolveProposal(_ proposal: TaskProposal, apply: Bool, keepWording: Bool = false) async {
        guard let store else { return }
        do { try await store.resolveTaskProposal(videoID: proposal.videoID, proposalID: proposal.id, apply: apply, keepWording: keepWording); await loadSelection() }
        catch { await recordDiagnosticFailure(error, videoID: proposal.videoID, taskID: proposal.taskID, revision: proposal.expectedTaskRevision); errorMessage = error.localizedDescription }
    }
    func copyTaskHandoff(snapshot: TaskLibrarySnapshot, selected: Set<String>, mode: TaskHandoffMode, text: String) async -> Bool {
        guard let store else { return false }
        do {
            let latest = try await store.taskSnapshot(videoID: snapshot.video.id)
            for id in selected {
                guard let before = snapshot.tasks.first(where: { $0.id == id }), let after = latest.tasks.first(where: { $0.id == id }), before.revision == after.revision, snapshot.video.revisions == latest.video.revisions else { throw TaskContextError.conflict }
            }
            _ = try TaskHandoff.message(snapshot: latest, selectedIDs: selected, mode: mode)
            copy(text); confirmCopy("Selected-task handoff copied"); return true
        } catch { await recordDiagnosticFailure(error, videoID: snapshot.video.id); errorMessage = error.localizedDescription; return false }
    }
}

extension AppModel {
    func moveVideoTask(_ task: VideoTask, direction: Int, source: ArtifactRevision) async {
        guard let store else { return }
        do { try await store.moveTask(videoID: task.videoID, taskID: task.id, direction: direction, expectedRevision: task.revision, expectedSource: source); await loadSelection() }
        catch { await recordDiagnosticFailure(error, videoID: task.videoID, taskID: task.id, revision: task.revision); errorMessage = error.localizedDescription }
    }
}
