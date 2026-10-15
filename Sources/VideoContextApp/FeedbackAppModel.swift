import Foundation
import VideoContextCore

extension AppModel {
    func createProject(name: String) async {
        guard let store else { return }
        do {
            let project = try await store.createFeedbackProject(name: name)
            feedbackProjects = try await store.listFeedbackProjects()
            applyNavigation(WorkspaceLocation(root: .project(project.id)))
            await workspaceLoadTask?.value
        } catch { errorMessage = error.localizedDescription }
    }
    func loadFeedback() async { await loadSelection() }

    func loadFeedback(for videoID: String) async {
        guard selectedVideoID == videoID else { return }
        await loadSelection()
    }

    func loadFeedback(forProject projectID: String) async {
        guard selectedProjectID == projectID else { return }
        await loadSelection()
    }

    func selectFeedback(_ id: String, projectID: String) async {
        guard selectedProjectID == projectID, feedbackBatches.contains(where: { $0.id == id }) else { return }
        var next = workspaceLocation; next.feedbackID = id; next.task = nil; next.section = .feedback
        requestNavigation(next)
        await workspaceLoadTask?.value
    }

    func selectFeedback(_ id: String, videoID: String) async {
        guard selectedVideoID == videoID, feedbackBatches.contains(where: { $0.id == id }) else { return }
        selectedFeedbackID = id
        await loadFeedback(for: videoID)
    }

    @discardableResult func createFeedback(videoID: String? = nil, projectID: String? = nil,
                                           title: String, project: String, text: String, files: [URL] = []) async -> Bool {
        guard let store, !feedbackCreationBusy, videoID == nil || selectedVideoID == videoID else { return false }
        feedbackCreationBusy = true
        defer { feedbackCreationBusy = false }
        let creationLocation = workspaceLocation
        let fallbackProjectID = selectedProjectID
        do {
            try validateFeedbackFiles(files)
            let cleanProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedProject: FeedbackProject?
            if let projectID { resolvedProject = try await store.listFeedbackProjects().first { $0.id == projectID } }
            else if !cleanProject.isEmpty { resolvedProject = try await store.createFeedbackProject(name: cleanProject) }
            else if let fallbackProjectID { resolvedProject = try await store.listFeedbackProjects().first { $0.id == fallbackProjectID } }
            else if let videoID, let video = try await store.videoSnapshot(id: videoID), let owner = video.video.projectID {
                resolvedProject = try await store.listFeedbackProjects().first { $0.id == owner }
            } else { resolvedProject = nil }
            guard let resolvedProject else { throw TaskContextError.invalid("Choose a project before saving feedback.") }
            var batch = FeedbackBatch(videoID: videoID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                      project: resolvedProject.name, rawText: text)
            batch.projectID = resolvedProject.id
            let added = batch.addUnassignedLocalSources(named: files.map(\.lastPathComponent))
            try await store.createFeedback(batch)
            feedbackProjects = try await store.listFeedbackProjects()
            if workspaceLocation == creationLocation {
                workspaceLocation.feedbackID = batch.id
                await loadFeedback()
            }
            Task {
                sourceWorkCount += 1
                defer { sourceWorkCount -= 1 }
                for (file, source) in zip(files, added) {
                    await attachFeedbackFile(file, batchID: batch.id, sourceID: source.id)
                }
                if !isUIFixture && batch.needsTranscriptIssueExtraction { await prepareFeedback(batchID: batch.id) }
                if !isUIFixture { await processFeedbackSources(batchID: batch.id) }
                if !isUIFixture && !batch.needsTranscriptIssueExtraction { await prepareFeedback(batchID: batch.id) }
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func attachUnassignedFeedback(_ batch: FeedbackBatch, to videoID: String) async {
        guard let store, selectedVideoID == videoID else { return }
        do {
            _ = try await store.attachFeedback(batch.id, toVideoID: videoID, expectedRevision: batch.revision)
            selectedFeedbackID = batch.id
            await loadFeedback(for: videoID)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveFeedbackBatch(_ draft: FeedbackBatch, expectedRevision: Int) async -> Bool {
        guard let store else { return false }
        do {
            var updated = draft
            if updated.projectID == nil && !updated.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let project = try await store.createFeedbackProject(name: updated.project)
                updated.projectID = project.id; updated.project = project.name
                feedbackProjects = try await store.listFeedbackProjects()
            }
            _ = try await store.updateFeedback(updated, expectedRevision: expectedRevision)
            await loadFeedback(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func processFeedbackSources(batchID: String, only sourceID: String? = nil) async {
        guard !feedbackBusy, let store, let paths else { return }
        feedbackBusy = true
        defer { feedbackBusy = false; feedbackProgress = nil }
        do {
            let snapshot = try await store.feedbackSnapshot(id: batchID)
            let pending = snapshot.batch.sources.filter { source in
                (sourceID == nil || source.id == sourceID) && source.status != .ready && source.url != nil
            }
            for (index, source) in pending.enumerated() {
                feedbackProgress = "Reading source \(index + 1) of \(pending.count)"
                var resolved: FeedbackSource
                var recordingLinkPersisted = false
                do {
                    _ = try await store.beginFeedbackImport(
                        batchID: batchID,
                        sourceID: source.id,
                        projectID: snapshot.batch.projectID,
                        sourceURL: source.url,
                        filename: source.filename
                    )
                    if source.kind == .jam, let url = source.url.flatMap(URL.init(string:)) {
                        let imported = try await JamEvidenceImporter(client: jamTools).importEvidence(from: url)
                        try Task.checkCancellation()
                        resolved = source
                        resolved.jam = try JamEvidenceReference.save(imported, batchID: batchID, sourceID: source.id, paths: paths)
                        resolved.status = imported.state == .ready ? .ready : .failed
                        resolved.error = imported.state == .ready ? nil : imported.availability.first?.message
                    } else {
                        resolved = try await FeedbackMediaResolver(client: URLSessionHTTPClient()).resolve(source, batchID: batchID, paths: paths)
                        if resolved.kind == .video, let url = resolved.resolvedURL {
                            guard let projectID = snapshot.batch.projectID else { throw TaskContextError.invalid("Assign this feedback to a project before importing its recording.") }
                            let id = await importOnline(url, selectImported: false, projectID: projectID, onImported: { [weak self] id in
                                guard let self else { throw TaskContextError.conflict }
                                try await self.persistImportedFeedbackRecording(
                                    batchID: batchID,
                                    sourceID: source.id,
                                    projectID: projectID,
                                    recordingID: id
                                )
                            })
                            guard let id else { throw TaskContextError.invalid("The linked recording could not be saved.") }
                            resolved.kind = .recording; resolved.status = .pending; resolved.recordingID = id; resolved.resolvedURL = nil
                            var linkedBatch = try await store.feedbackSnapshot(id: batchID).batch
                            guard let linkedIndex = linkedBatch.sources.firstIndex(where: { $0.id == source.id }),
                                  linkedBatch.sources[linkedIndex].recordingID == nil || linkedBatch.sources[linkedIndex].recordingID == id else {
                                throw TaskContextError.conflict
                            }
                            if linkedBatch.sources[linkedIndex].recordingID == nil {
                                linkedBatch.sources[linkedIndex] = resolved
                                _ = try await store.updateFeedback(linkedBatch, expectedRevision: linkedBatch.revision)
                            } else {
                                resolved = linkedBatch.sources[linkedIndex]
                            }
                            _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: source.id, phase: .processing, recordingID: id)
                            recordingLinkPersisted = true
                            await loadFeedback()
                            await waitForProcessing()
                            if let video = try await store.videoSnapshot(id: id), video.video.status == .ready {
                                resolved.status = .ready; resolved.error = nil
                                _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: source.id, phase: .completed, recordingID: id)
                            } else {
                                resolved.status = .failed
                                resolved.error = "Video processing did not finish. Resume the recording and retry this source."
                                _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: source.id, phase: .failed, recordingID: id, errorMessage: resolved.error)
                            }
                        }
                    }
                } catch is CancellationError { return }
                catch JamConnectionError.authorizationRequired {
                    if recordingLinkPersisted, let current = try? await store.feedbackSnapshot(id: batchID).batch,
                       let currentSource = current.sources.first(where: { $0.id == source.id }) {
                        resolved = currentSource
                    } else {
                        resolved = source
                    }
                    resolved.status = .failed
                    resolved.error = "Reconnect Jam in Settings to import this recording."
                }
                catch {
                    if recordingLinkPersisted, let current = try? await store.feedbackSnapshot(id: batchID).batch,
                       let currentSource = current.sources.first(where: { $0.id == source.id }) {
                        resolved = currentSource
                    } else {
                        resolved = source
                    }
                    resolved.status = .failed; resolved.error = error.localizedDescription
                }
                var latest = try await store.feedbackSnapshot(id: batchID).batch
                guard let position = latest.sources.firstIndex(where: { $0.id == source.id }),
                      recordingLinkPersisted ? latest.sources[position].recordingID == resolved.recordingID : latest.sources[position] == source else { throw TaskContextError.conflict }
                try Task.checkCancellation()
                latest.sources[position] = resolved
                _ = try await store.updateFeedback(latest, expectedRevision: latest.revision)
                _ = try await store.updateFeedbackImport(
                    batchID: batchID,
                    sourceID: source.id,
                    phase: resolved.status == .ready ? .completed : .failed,
                    recordingID: resolved.recordingID,
                    errorMessage: resolved.error
                )
                await loadFeedback()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retryJamEvidence(batchID: String, sourceID: String) async {
        guard !feedbackBusy, let store, let paths else { return }
        feedbackBusy = true
        feedbackProgress = "Retrying Jam evidence"
        defer { feedbackBusy = false; feedbackProgress = nil }
        var originalSource: FeedbackSource?
        do {
            let snapshot = try await store.feedbackSnapshot(id: batchID)
            guard let source = snapshot.batch.sources.first(where: { $0.id == sourceID }),
                  source.kind == .jam, let sourceURL = source.url,
                  let url = URL(string: sourceURL) else { throw TaskContextError.conflict }
            originalSource = source
            let imported = try await JamEvidenceImporter(client: jamTools).importEvidence(from: url)
            try Task.checkCancellation()
            var latest = try await store.feedbackSnapshot(id: batchID).batch
            guard let position = latest.sources.firstIndex(where: { $0.id == sourceID }),
                  latest.sources[position] == source,
                  latest.sources[position].url == sourceURL else { throw TaskContextError.conflict }
            let saved = try JamEvidenceReference.save(imported, batchID: batchID, sourceID: sourceID, paths: paths)
            var updated = source
            updated.jam = try source.jam?.merging(saved) ?? saved
            updated.status = updated.jam?.state == .ready ? .ready : .failed
            updated.error = updated.status == .ready ? nil : updated.jam?.availability.first?.message
            try Task.checkCancellation()
            latest.sources[position] = updated
            _ = try await store.updateFeedback(latest, expectedRevision: latest.revision)
            await loadFeedback()
        } catch is CancellationError {
            return
        } catch JamConnectionError.authorizationRequired {
            let message = "Reconnect Jam in Settings to retry this recording."
            if let originalSource { await recordJamRetryFailure(batchID: batchID, source: originalSource, message: message) }
            errorMessage = message
        } catch TaskContextError.conflict {
            errorMessage = TaskContextError.conflict.localizedDescription
        } catch {
            let message: String
            if let context = error as? TaskContextError { message = context.localizedDescription }
            else { message = "Jam transport failed while retrying evidence." }
            if let originalSource { await recordJamRetryFailure(batchID: batchID, source: originalSource, message: message) }
            errorMessage = message
        }
    }

    private func recordJamRetryFailure(batchID: String, source: FeedbackSource, message: String) async {
        guard let store, let jam = source.jam else { return }
        do {
            var latest = try await store.feedbackSnapshot(id: batchID).batch
            guard let position = latest.sources.firstIndex(where: { $0.id == source.id }),
                  latest.sources[position] == source else { return }
            let failed = JamEvidenceReference(sourceURL: jam.sourceURL, recordingID: jam.recordingID,
                state: .unread, importedAt: .now, items: [],
                availability: [.init(component: .details, status: .failed, message: message)])
            var updated = source
            updated.jam = try jam.merging(failed)
            updated.status = updated.jam?.state == .ready ? .ready : .failed
            updated.error = updated.status == .ready ? nil : message
            latest.sources[position] = updated
            _ = try await store.updateFeedback(latest, expectedRevision: latest.revision)
            await loadFeedback()
        } catch {
            // A concurrent source edit wins; never publish a stale retry result.
        }
    }

    /// Called by an import operation after its recording row exists and before
    /// the processing pipeline is started. This closes the import race where a
    /// provider could finish before the feedback source was linked.
    private func persistImportedFeedbackRecording(
        batchID: String,
        sourceID: String,
        projectID: String,
        recordingID: String
    ) async throws {
        guard let store else { throw TaskContextError.conflict }
        var batch = try await store.feedbackSnapshot(id: batchID).batch
        guard batch.projectID == projectID,
              let index = batch.sources.firstIndex(where: { $0.id == sourceID }) else {
            throw TaskContextError.conflict
        }
        if let existing = batch.sources[index].recordingID, existing != recordingID {
            throw TaskContextError.conflict
        }
        if batch.sources[index].recordingID == nil {
            batch.sources[index].kind = .recording
            batch.sources[index].recordingID = recordingID
            batch.sources[index].status = .pending
            batch.sources[index].resolvedURL = nil
            batch.sources[index].error = nil
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
        }
        _ = try await store.updateFeedbackImport(
            batchID: batchID,
            sourceID: sourceID,
            phase: .processing,
            recordingID: recordingID
        )
    }

    func attachFeedbackFile(_ file: URL, batchID: String, sourceID: String) async {
        sourceWorkCount += 1
        defer { sourceWorkCount -= 1 }
        guard !feedbackBusy, let store, let paths else { return }
        let scope = file.startAccessingSecurityScopedResource()
        defer { if scope { file.stopAccessingSecurityScopedResource() } }
        feedbackBusy = true
        defer { feedbackBusy = false; feedbackProgress = nil }
        do {
            var batch = try await store.feedbackSnapshot(id: batchID).batch
            guard let index = batch.sources.firstIndex(where: { $0.id == sourceID }) else { throw TaskContextError.missing(sourceID) }
            var source = batch.sources[index]
            _ = try await store.beginFeedbackImport(
                batchID: batchID,
                sourceID: sourceID,
                projectID: batch.projectID,
                sourceURL: source.url,
                filename: file.lastPathComponent
            )
            feedbackProgress = "Importing \(file.lastPathComponent)"
            source.error = nil
            let extensionName = file.pathExtension.lowercased()
            if extensionName == "mp4" {
                guard let projectID = batch.projectID else { throw TaskContextError.invalid("Assign this feedback to a project before importing its recording.") }
                let id = await importLocal(file, selectImported: false, projectID: projectID, onImported: { [weak self] id in
                    guard let self else { throw TaskContextError.conflict }
                    try await self.persistImportedFeedbackRecording(
                        batchID: batchID,
                        sourceID: sourceID,
                        projectID: projectID,
                        recordingID: id
                    )
                })
                guard let id else { throw TaskContextError.invalid("The attached recording could not be saved.") }
                // Save the relationship before processing finishes so a failed
                // provider call leaves a resumable recording attachment.
                source.kind = .recording; source.recordingID = id; source.localPath = nil; source.ocrText = ""; source.status = .pending
                let linked = try await store.feedbackSnapshot(id: batchID).batch
                guard let linkedIndex = linked.sources.firstIndex(where: { $0.id == sourceID }),
                      linked.sources[linkedIndex].recordingID == nil || linked.sources[linkedIndex].recordingID == id else {
                    throw TaskContextError.conflict
                }
                if linked.sources[linkedIndex].recordingID == nil {
                    var linkedBatch = linked
                    linkedBatch.sources[linkedIndex] = source
                    _ = try await store.updateFeedback(linkedBatch, expectedRevision: linkedBatch.revision)
                } else {
                    source = linked.sources[linkedIndex]
                }
                _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: sourceID, phase: .processing, recordingID: id)
                await loadFeedback()
                await waitForProcessing()
                if let video = try await store.videoSnapshot(id: id), video.video.status == .ready {
                    source.status = .ready
                    source.error = nil
                    _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: sourceID, phase: .completed, recordingID: id)
                } else {
                    source.status = .failed
                    source.error = "Attached video processing did not finish. Resume the recording and retry this source."
                    _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: sourceID, phase: .failed, recordingID: id, errorMessage: source.error)
                }
            } else {
                guard ["png", "jpg", "jpeg", "webp"].contains(extensionName) else {
                    throw TaskContextError.invalid("Attach a PNG, JPEG, WebP, or MP4 file.")
                }
                let destination = try paths.feedbackDirectory(id: batchID).appending(path: source.id + "-" + UUID().uuidString.lowercased() + "." + extensionName)
                try FileManager.default.copyItem(at: file, to: destination)
                source.kind = .image; source.localPath = paths.relativePath(for: destination); source.recordingID = nil
                do { source.ocrText = try await VisionTextRecognizer().recognizeText(in: destination) }
                catch {
                    source.ocrText = ""
                    source.error = "Text recognition unavailable: \(error.localizedDescription)"
                }
                source.status = .ready
                _ = try await store.updateFeedbackImport(batchID: batchID, sourceID: sourceID, phase: .completed)
            }
            source.filename = file.lastPathComponent; source.resolvedURL = nil
            batch = try await store.feedbackSnapshot(id: batchID).batch
            guard let latestIndex = batch.sources.firstIndex(where: { $0.id == sourceID }) else { throw TaskContextError.conflict }
            batch.sources[latestIndex] = source
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
            await loadFeedback()
        } catch {
            errorMessage = error.localizedDescription
            _ = try? await store.updateFeedbackImport(
                batchID: batchID,
                sourceID: sourceID,
                phase: .failed,
                errorMessage: error.localizedDescription
            )
            do {
                var batch = try await store.feedbackSnapshot(id: batchID).batch
                if let index = batch.sources.firstIndex(where: { $0.id == sourceID }), batch.sources[index].status != .ready {
                    batch.sources[index].status = .failed
                    batch.sources[index].error = error.localizedDescription
                    _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
                    await loadFeedback()
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func addFeedbackAttachments(_ files: [URL], batchID: String, commentID: String? = nil) async {
        guard let store else { return }
        do {
            try validateFeedbackFiles(files)
            guard !files.isEmpty else { return }
            var batch = try await store.feedbackSnapshot(id: batchID).batch
            if let commentID, !batch.comments.contains(where: { $0.id == commentID }) { throw TaskContextError.missing(commentID) }
            let added = commentID.map { batch.addLocalSources(named: files.map(\.lastPathComponent), to: $0) } ??
                batch.addUnassignedLocalSources(named: files.map(\.lastPathComponent))
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
            await loadFeedback()
            for (file, source) in zip(files, added) { await attachFeedbackFile(file, batchID: batchID, sourceID: source.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func assignFeedbackSource(batchID: String, sourceID: String, issueID: String?) async {
        guard let store else { return }
        do {
            var batch = try await store.feedbackSnapshot(id: batchID).batch
            guard batch.sources.contains(where: { $0.id == sourceID }) else { throw TaskContextError.missing(sourceID) }
            if let issueID, !batch.comments.contains(where: { $0.id == issueID }) { throw TaskContextError.missing(issueID) }
            for index in batch.comments.indices { batch.comments[index].sourceIDs.removeAll { $0 == sourceID } }
            batch.batchWideSourceIDs.removeAll { $0 == sourceID }
            if let issueID {
                let index = batch.comments.firstIndex { $0.id == issueID }!
                batch.comments[index].sourceIDs.append(sourceID)
            } else { batch.batchWideSourceIDs.append(sourceID) }
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
            await loadFeedback()
        } catch { errorMessage = error.localizedDescription }
    }

    func prepareFeedback(batchID: String) async {
        guard !isUIFixture else { feedbackProgress = "Issue suggestions are disabled in the demo library."; return }
        guard !feedbackBusy, !editingFeedbackIDs.contains(batchID), let store, let paths else { return }
        let configuration = modelConfiguration.feedbackPreparationConfiguration
        guard credentialReady(for: configuration.analysisProvider) else {
            feedbackProgress = "Feedback preparation unavailable: unlock the \(configuration.analysisProvider.label) credential. The original feedback is saved."
            return
        }
        let credential = credentialValue(for: configuration.analysisProvider)
        feedbackBusy = true; feedbackProgress = "Suggesting issue groups and evidence links"
        defer { feedbackBusy = false }
        do {
            let snapshot = try await store.feedbackSnapshot(id: batchID)
            let client = UsageRecordingClient(base: transport(for: configuration.analysisProvider), provider: configuration.analysisProvider.identity,
                                              model: configuration.selectedAnalysisModel, stage: .taskExtraction)
            feedbackProgress = snapshot.batch.needsTranscriptIssueExtraction ? "Extracting issues from transcript" : "Suggesting issue groups and evidence links"
            let prepared = try await withUsageRun(operation: .taskGeneration, videoID: snapshot.batch.videoID,
                configuration: configuration, feedbackBatchID: batchID, feedbackRevision: snapshot.batch.revision) {
                if snapshot.batch.needsTranscriptIssueExtraction {
                    let issues = try await FeedbackTranscriptExtractor(client: client, configuration: configuration, credential: credential)
                        .extract(batch: snapshot.batch)
                    return (issues, [FeedbackPreparationSuggestion]())
                }
                let suggestions = try await FeedbackPreparer(client: client, configuration: configuration, credential: credential, paths: paths)
                    .suggest(batch: snapshot.batch)
                return (snapshot.batch.comments, suggestions)
            }
            var batch = try await store.feedbackSnapshot(id: batchID).batch
            guard batch.revision == snapshot.batch.revision else { throw TaskContextError.conflict }
            batch.comments = prepared.0
            batch.preparationSuggestions = prepared.1
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
            if snapshot.batch.needsTranscriptIssueExtraction {
                feedbackProgress = prepared.0.isEmpty ? "No actionable issues found in the transcript. Review the saved transcript before retrying." : "\(prepared.0.count) issues extracted. Review or edit them before generating tasks."
            } else { feedbackProgress = "\(prepared.1.count) issue suggestions ready for review." }
            await loadFeedback()
        } catch is CancellationError { feedbackProgress = "Issue preparation cancelled; original feedback and evidence were kept." }
        catch { feedbackProgress = "Issue preparation failed; original feedback and evidence were kept."; errorMessage = error.localizedDescription }
    }

    func applyFeedbackSuggestion(batchID: String, issueID: String) async {
        guard let store else { return }
        do {
            let snapshot = try await store.feedbackSnapshot(id: batchID)
            var batch = snapshot.batch
            guard let suggestion = batch.preparationSuggestions.first(where: { $0.issueID == issueID }),
                  let index = batch.comments.firstIndex(where: { $0.id == issueID }) else { throw TaskContextError.missing(issueID) }
            if suggestion.joinWithPrevious {
                guard index > 0, snapshot.tasks.isEmpty else { throw TaskContextError.reviewRequired }
                batch.comments[index - 1].text += "\n" + batch.comments[index].text
                batch.comments[index - 1].lineNumbers += batch.comments[index].lineNumbers
                batch.comments[index - 1].sourceIDs = Array(Set(batch.comments[index - 1].sourceIDs + batch.comments[index].sourceIDs + suggestion.sourceIDs)).sorted()
                batch.comments.remove(at: index)
            } else {
                batch.comments[index].isShared = suggestion.sharedInstruction
                batch.comments[index].sourceIDs = Array(Set(batch.comments[index].sourceIDs + suggestion.sourceIDs)).sorted()
            }
            batch.preparationSuggestions.removeAll { $0.issueID == issueID }
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
            await loadFeedback()
        } catch { errorMessage = error.localizedDescription }
    }

    private func validateFeedbackFiles(_ files: [URL]) throws {
        guard files.allSatisfy({ ["png", "jpg", "jpeg", "webp", "mp4"].contains($0.pathExtension.lowercased()) }) else {
            throw TaskContextError.invalid("Attach PNG, JPEG, WebP, or MP4 files.")
        }
    }

    func linkFeedbackRecording(batchID: String, commentID: String, recordingID: String) async {
        guard let store else { return }
        do {
            guard let video = try await store.videoSnapshot(id: recordingID), video.video.status == .ready else {
                throw TaskContextError.invalid("Choose a ready recording.")
            }
            var batch = try await store.feedbackSnapshot(id: batchID).batch
            guard let index = batch.comments.firstIndex(where: { $0.id == commentID }) else { throw TaskContextError.missing(commentID) }
            let source = FeedbackSource(kind: .recording, status: .ready, recordingID: recordingID)
            batch.sources.append(source); batch.comments[index].sourceIDs.append(source.id)
            _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
            await loadFeedback()
        } catch { errorMessage = error.localizedDescription }
    }

    func generateFeedbackTasks() {
        guard !isUIFixture else { errorMessage = "Task generation is disabled in the demo library. Use the fixture tasks to review the workflow."; return }
        guard !feedbackBusy, let snapshot = feedbackSnapshot,
              (snapshot.batch.videoID != nil && snapshot.batch.videoID == selectedVideoID ||
               snapshot.batch.projectID != nil && snapshot.batch.projectID == selectedProjectID),
              let store, let paths else { return }
        guard let projectID = snapshot.batch.projectID else { errorMessage = "Assign this feedback to a project before generating tasks."; return }
        guard !snapshot.batch.needsTranscriptIssueExtraction else {
            errorMessage = "Extract and review issues from the transcript before generating tasks."
            return
        }
        guard snapshot.batch.unassignedSourceIDs.isEmpty else {
            errorMessage = "Assign every uploaded source to an issue or batch-wide context before generating tasks."
            return
        }
        let configuration = taskConfiguration
        guard credentialReady(for: configuration.analysisProvider) else {
            errorMessage = "Unlock or enter the \(configuration.analysisProvider.label) credential before generating tasks."
            return
        }
        let credential = credentialValue(for: configuration.analysisProvider)
        let reviewConfiguration = modelConfiguration.reviewConfiguration
        let reviewCredential = reviewConfiguration.map { credentialValue(for: $0.analysisProvider) }
        let reviewClient = evidenceReviewClient(configuration: reviewConfiguration)
        feedbackBusy = true; feedbackProgress = "Preparing feedback tasks"
        feedbackGenerationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.feedbackBusy = false; self.feedbackGenerationTask = nil }
            do {
                let projectContext = try await self.projectAnalysisInput(projectID: projectID, store: store, paths: paths)
                var frozen = configuration
                if configuration.analysisProvider == .lmStudio {
                    let instance = try await LMStudioService(client: self.localHTTP).loadedModel(configuration: configuration.lmStudio, token: credential)
                    frozen.lmStudio.modelID = instance.id
                }
                let client = UsageRecordingClient(base: self.transport(for: frozen.analysisProvider), provider: frozen.analysisProvider.identity,
                                                  model: frozen.selectedAnalysisModel, stage: .taskExtraction)
                let output = try await self.withUsageRun(operation: .taskGeneration, videoID: snapshot.batch.videoID, configuration: frozen,
                    feedbackBatchID: snapshot.batch.id, feedbackRevision: snapshot.batch.revision, projectID: snapshot.batch.projectID,
                    projectAnalysisFingerprint: projectContext?.fingerprint) {
                    let guardedClient = AnalysisOutcomeGuard(base: client, store: store, projectID: projectID,
                        sourceIdentity: "feedback:\(snapshot.batch.id):\(snapshot.batch.revision):" + (projectContext?.fingerprint ?? "legacy"))
                    return try await FeedbackGenerator(client: guardedClient, configuration: frozen, credential: credential, paths: paths, store: store,
                        reviewClient: reviewClient, reviewConfiguration: reviewConfiguration, reviewCredential: reviewCredential)
                        .generate(snapshot: snapshot, projectContext: projectContext, progress: { completed, total in
                            await self.setFeedbackProgress("Generating tasks \(completed) of \(total)")
                        })
                }
                self.feedbackProgress = "\(output.count) tasks generated. Review them before copying."
                await self.loadFeedback()
            } catch is CancellationError { self.feedbackProgress = "Generation cancelled; saved tasks were kept." }
            catch { self.errorMessage = error.localizedDescription; self.feedbackProgress = "Generation stopped; saved tasks were kept." }
        }
    }
    private func setFeedbackProgress(_ value: String) { feedbackProgress = value }
    func cancelFeedbackGeneration() { feedbackGenerationTask?.cancel() }

    func saveFeedbackTask(_ task: FeedbackTask, expectedRevision: Int, expectedBatchRevision: Int) async -> Bool {
        guard let store else { return false }
        do {
            _ = try await store.saveFeedbackTask(task, expectedRevision: expectedRevision, expectedBatchRevision: expectedBatchRevision)
            await loadFeedback(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func consolidateFeedbackTask(_ task: FeedbackTask, batch: FeedbackBatch) async -> FeedbackTaskProposal? {
        guard !feedbackBusy, !task.archived, task.batchID == batch.id, let store else { return nil }
        let configuration = taskConfiguration
        guard credentialReady(for: configuration.analysisProvider) else {
            errorMessage = "Unlock or enter the \(configuration.analysisProvider.label) credential before consolidating this task."
            return nil
        }
        let credential = credentialValue(for: configuration.analysisProvider)
        feedbackBusy = true; feedbackProgress = "Consolidating task content"
        defer { feedbackBusy = false; feedbackProgress = nil }
        do {
            var frozen = configuration
            if configuration.analysisProvider == .lmStudio {
                let instance = try await LMStudioService(client: localHTTP).loadedModel(configuration: configuration.lmStudio,
                                                                                       token: credential)
                frozen.lmStudio.modelID = instance.id
            }
            let client = UsageRecordingClient(base: transport(for: frozen.analysisProvider),
                provider: frozen.analysisProvider.identity, model: frozen.selectedAnalysisModel,
                stage: .taskConsolidation)
            let protectedClient: AnyHTTPDataLoader
            if let projectID = batch.projectID {
                protectedClient = AnyHTTPDataLoader(AnalysisOutcomeGuard(base: client, store: store, projectID: projectID,
                    sourceIdentity: "feedback-consolidation:\(batch.id):\(batch.revision):\(task.id):\(task.revision)"))
            } else { protectedClient = AnyHTTPDataLoader(client) }
            let replacement = try await withUsageRun(operation: .taskGeneration, videoID: batch.videoID,
                configuration: frozen, feedbackBatchID: batch.id, feedbackRevision: batch.revision, projectID: batch.projectID) {
                try await FeedbackContentConsolidator(client: protectedClient, configuration: frozen, credential: credential)
                    .consolidate(content: task.content, generatedOriginal: task.generatedOriginal)
            }
            try Task.checkCancellation()
            let proposal = try await store.prepareFeedbackTaskConsolidation(batchID: batch.id, taskID: task.id,
                expectedBatchRevision: batch.revision, expectedTaskRevision: task.revision, replacement: replacement)
            await loadFeedback()
            return proposal
        } catch is CancellationError {
            feedbackProgress = "Task consolidation cancelled; the saved task was kept."
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
    func setFeedbackTasksArchived(_ tasks: [FeedbackTask], archived: Bool, batch: FeedbackBatch) async -> Bool {
        guard !feedbackBusy, let store, !tasks.isEmpty,
              tasks.allSatisfy({ $0.batchID == batch.id && $0.archived != archived }) else { return false }
        feedbackBusy = true
        feedbackProgress = archived ? "Removing tasks" : "Restoring tasks"
        defer { feedbackBusy = false; feedbackProgress = nil }
        do {
            try await store.setFeedbackTasksArchived(batchID: batch.id, expectedBatchRevision: batch.revision,
                expectedTaskRevisions: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.revision) }),
                archived: archived)
            await loadFeedback()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    func approveFeedback(_ tasks: [FeedbackTask], batchRevision: Int, batchID: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.approveFeedbackTasks(batchID: batchID, expectedBatchRevision: batchRevision,
                                                 expectedTaskRevisions: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.revision) }))
            await loadFeedback(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func resolveFeedbackProposal(_ proposal: FeedbackTaskProposal, apply: Bool) async {
        guard let store else { return }
        do {
            try await store.resolveFeedbackProposal(batchID: proposal.batchID, proposalID: proposal.id, apply: apply)
            await loadFeedback()
        } catch { errorMessage = error.localizedDescription }
    }
    func copyFeedbackHandoff(snapshot: FeedbackSnapshot, selected: Set<String>, mode: TaskHandoffMode, text: String) async -> Bool {
        guard let store else { return false }
        do {
            let latest = try await store.feedbackSnapshot(id: snapshot.batch.id)
            guard latest.batch.revision == snapshot.batch.revision else { throw TaskContextError.conflict }
            for id in selected {
                guard let before = snapshot.tasks.first(where: { $0.id == id }),
                      let after = latest.tasks.first(where: { $0.id == id }), before.revision == after.revision else { throw TaskContextError.conflict }
            }
            _ = try FeedbackHandoff.message(snapshot: latest, selected: selected, mode: mode)
            copy(text); confirmCopy("Feedback handoff copied"); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Reconciles feedback recording imports after an app restart. The import
    /// row captures the project and recording ID before processing starts, so a
    /// late provider result cannot attach itself to whichever project is open
    /// when this method runs. Completed local checkpoints are reused by the
    /// pipeline; running or unknown provider checkpoints are left for explicit
    /// user reconciliation and are never submitted automatically again.
    func recoverFeedbackImports() async {
        guard let store else { return }
        do {
            let recoveries = try await store.feedbackImportRecoveries()
            let resumable: Set<ProcessingStatus> = [
                .imported, .inspecting, .extractingAudio, .transcribing,
                .capturingFrames, .recognizingText, .analyzing, .incomplete
            ]
            for recovery in recoveries where [.accepted, .downloading, .copied, .processing].contains(recovery.phase) {
                guard let recordingID = recovery.recordingID else {
                    // The copy/download has not created a recording row yet.
                    // Leave the recovery row intact so the next import attempt
                    // can report the captured project instead of guessing one.
                    continue
                }
                guard let snapshot = try await store.videoSnapshot(id: recordingID) else {
                    let message = "The imported recording is missing. The feedback attachment was retained for review."
                    try? await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .failed, recordingID: recordingID, errorMessage: message)
                    continue
                }
                if let projectID = recovery.projectID, snapshot.video.projectID != projectID {
                    let message = "The linked recording belongs to another project. Resolve the feedback attachment before processing it."
                    try? await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .failed, recordingID: recordingID, errorMessage: message)
                    continue
                }

                if snapshot.video.status == .ready {
                    try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .ready, error: nil)
                    _ = try await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .completed, recordingID: recordingID)
                    continue
                }

                let checkpoints = try await store.processingCheckpoints(videoID: recordingID)
                if checkpoints.contains(where: { $0.state == .running || $0.state == .unknown }) {
                    let message = "Processing stopped with an uncertain provider result. Reconcile it in the recording before retrying this attachment."
                    try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .failed, error: message)
                    _ = try await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .processing, recordingID: recordingID, errorMessage: message)
                    continue
                }

                guard resumable.contains(snapshot.video.status) else {
                    let message = "Recording processing is \(snapshot.video.status.rawValue) and needs review before this attachment can continue."
                    try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .failed, error: message)
                    _ = try await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .failed, recordingID: recordingID, errorMessage: message)
                    continue
                }

                guard !isProcessing else { continue }
                guard credentialReady(for: analysisProvider) else {
                    // Keep the source pending while credentials are loading.
                    // Root calls this hook again after credentials become ready.
                    let message = "Recording is linked. Unlock the \(analysisProvider.label) credential to resume processing."
                    try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .pending, error: message)
                    _ = try await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .processing, recordingID: recordingID, errorMessage: message)
                    continue
                }

                try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .pending, error: nil)
                beginProcessing(videoID: recordingID)
                guard processingVideoID == recordingID else { continue }
                await waitForProcessing()
                guard let finished = try await store.videoSnapshot(id: recordingID) else { continue }
                if finished.video.status == .ready {
                    try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .ready, error: nil)
                    _ = try await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .completed, recordingID: recordingID)
                } else {
                    let message = finished.video.errorMessage ?? "Recording processing did not finish. Resume it from the recording workspace."
                    try await reconcileRecoveredFeedbackSource(recovery, recordingID: recordingID, status: .failed, error: message)
                    _ = try await store.updateFeedbackImport(batchID: recovery.batchID, sourceID: recovery.sourceID,
                        phase: .processing, recordingID: recordingID, errorMessage: message)
                }
            }
            await loadFeedback()
        } catch {
            errorMessage = "Feedback import recovery could not finish: \(error.localizedDescription)"
        }
    }

    private func reconcileRecoveredFeedbackSource(
        _ recovery: FeedbackImportRecovery,
        recordingID: String,
        status: FeedbackSourceStatus,
        error: String?
    ) async throws {
        guard let store else { throw TaskContextError.conflict }
        var batch = try await store.feedbackSnapshot(id: recovery.batchID).batch
        guard recovery.projectID == batch.projectID,
              let index = batch.sources.firstIndex(where: { $0.id == recovery.sourceID }) else {
            throw TaskContextError.conflict
        }
        if let existing = batch.sources[index].recordingID, existing != recordingID {
            throw TaskContextError.conflict
        }
        var source = batch.sources[index]
        source.kind = .recording
        source.recordingID = recordingID
        source.resolvedURL = nil
        source.status = status
        source.error = error
        guard source != batch.sources[index] else { return }
        batch.sources[index] = source
        _ = try await store.updateFeedback(batch, expectedRevision: batch.revision)
    }
}
