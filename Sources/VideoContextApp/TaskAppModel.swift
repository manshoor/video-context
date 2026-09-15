import Foundation
import VideoContextCore

extension AppModel {
    var taskProviderLabel: String { analysisProvider == .lmStudio ? "LM Studio · \(lmStudioModelID) · local" : "OpenAI · \(analysisModel) · sends saved context to OpenAI" }
    func generateTasks() {
        guard !isProcessing, let store, let paths, let snapshot, snapshot.video.status == .ready, !snapshot.video.revisions.isBriefStale, let brief = snapshot.brief else { return }
        var configuration = modelConfiguration
        let key = apiKey, token = lmStudioUsesToken ? lmStudioToken : "", needsToken = lmStudioUsesToken
        guard configuration.analysisProvider != .openAI || (credentialState == .ready && !key.isEmpty) else { errorMessage = "Unlock or enter the OpenAI key before generating tasks."; return }
        guard configuration.analysisProvider != .lmStudio || !needsToken || !token.isEmpty else { errorMessage = "Unlock or enter the LM Studio token in Settings."; return }
        let videoID = snapshot.video.id
        activity = AppActivity(videoID: videoID, recordingTitle: snapshot.video.title, phase: .processing(.analyzing))
        activity?.detail = "Preparing task generation"
        taskGenerationMessage = nil
        taskGenerationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await store.taskSnapshot(videoID: videoID)
                guard source.video.revisions == snapshot.video.revisions else { throw TaskContextError.conflict }
                var contextLength = 32_768
                let client: AnyHTTPDataLoader
                if configuration.analysisProvider == .lmStudio {
                    let instance = try await LMStudioService(client: self.localHTTP).loadedModel(configuration: configuration.lmStudio, token: token)
                    configuration.lmStudio.modelID = instance.id; contextLength = instance.config.contextLength; client = self.localHTTP
                } else { client = self.cloudHTTP }
                try Task.checkCancellation()
                let generator = TaskGenerator(client: client, configuration: configuration, credential: configuration.analysisProvider == .lmStudio ? token : key, contextLength: contextLength)
                let proposals = try await generator.generate(snapshot: source, brief: brief, paths: paths, store: store, progress: { [weak self] progress in await self?.updateTaskActivity(progress) })
                self.taskGenerationMessage = proposals.isEmpty ? "No actionable tasks found." : "\(proposals.count) proposed changes. Review them before applying."
            } catch is CancellationError { self.taskGenerationMessage = "Task generation paused. Generate again to reuse validated batches." }
            catch {
                if Task.isCancelled { self.taskGenerationMessage = "Task generation paused. Generate again to reuse validated batches." }
                else { self.errorMessage = error.localizedDescription; self.taskGenerationMessage = "Task generation stopped. Saved tasks and evidence were preserved." }
            }
            self.activity = nil; self.taskGenerationTask = nil
            await self.loadLibrary()
        }
    }
    private func updateTaskActivity(_ progress: ProcessingProgress) {
        activity?.update(progress)
    }
    func saveVideoTask(_ draft: VideoTask, expectedRevision: Int?, expectedSource: ArtifactRevision) async -> VideoTask? {
        guard let store else { return nil }
        do {
            let saved = try await store.saveTask(draft, expectedRevision: expectedRevision, expectedSource: expectedSource)
            await loadSelection(); return saved
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    func reviewVideoTask(_ task: VideoTask, source: ArtifactRevision) async {
        guard let store else { return }
        do { try await store.reviewTask(videoID: task.videoID, taskID: task.id, expectedRevision: task.revision, expectedSource: source); await loadSelection() }
        catch { errorMessage = error.localizedDescription }
    }
    func resolveProposal(_ proposal: TaskProposal, apply: Bool, keepWording: Bool = false) async {
        guard let store else { return }
        do { try await store.resolveTaskProposal(videoID: proposal.videoID, proposalID: proposal.id, apply: apply, keepWording: keepWording); await loadSelection() }
        catch { errorMessage = error.localizedDescription }
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
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

extension AppModel {
    func moveVideoTask(_ task: VideoTask, direction: Int, source: ArtifactRevision) async {
        guard let store else { return }
        do { try await store.moveTask(videoID: task.videoID, taskID: task.id, direction: direction, expectedRevision: task.revision, expectedSource: source); await loadSelection() }
        catch { errorMessage = error.localizedDescription }
    }
}
