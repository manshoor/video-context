import Foundation
import CryptoKit

private enum FeedbackGenerationOutputError: Error, LocalizedError {
    case identity(expected: [String], returned: [String], missing: [String], duplicates: [String], unexpected: [String])

    var errorDescription: String? {
        switch self {
        case let .identity(expected, returned, missing, duplicates, unexpected):
            func list(_ values: [String]) -> String { values.isEmpty ? "none" : values.joined(separator: ", ") }
            return "Feedback task identity mismatch. Expected issue IDs: \(list(expected)). Returned primary issue IDs: \(list(returned)). Missing issue IDs: \(list(missing)). Duplicate issue IDs: \(list(duplicates)). Unexpected issue IDs: \(list(unexpected)). No tasks were saved."
        }
    }
}

private struct FeedbackContentValidationError: Error, LocalizedError {
    let diagnostics: [FeedbackValidationDiagnostic]
    let omittedCount: Int

    var errorDescription: String? {
        let details = diagnostics.map { failure in
            let sources = failure.sourceIDs.isEmpty ? "" : " Unexpected source IDs: \(failure.sourceIDs.joined(separator: ", "))."
            return "\(failure.primaryIssueID) \(failure.fieldPath) [\(failure.category.rawValue)].\(sources)"
        }.joined(separator: " ")
        let omitted = omittedCount == 0 ? "" : " \(omittedCount) additional validation failures were omitted from this bounded report."
        return "Feedback content validation failed. \(details)\(omitted) No tasks were saved."
    }
}

public struct FeedbackGenerator<Client: HTTPDataLoading>: Sendable {
    public let client: Client
    public let configuration: ModelConfiguration
    public let credential: String
    public let paths: LibraryPaths
    public let store: VideoContextStore
    public let reviewClient: AnyHTTPDataLoader?
    public let reviewConfiguration: ModelConfiguration?
    public let reviewCredential: String?

    public init(client: Client, configuration: ModelConfiguration, credential: String, paths: LibraryPaths, store: VideoContextStore,
                reviewClient: AnyHTTPDataLoader? = nil, reviewConfiguration: ModelConfiguration? = nil,
                reviewCredential: String? = nil) {
        self.client = client; self.configuration = configuration; self.credential = credential; self.paths = paths; self.store = store
        self.reviewClient = reviewClient; self.reviewConfiguration = reviewConfiguration; self.reviewCredential = reviewCredential
    }

    public func generate(snapshot: FeedbackSnapshot, projectContext: ProjectAnalysisContext? = nil,
                         progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> [FeedbackTask] {
        let batch = snapshot.batch
        let generationSource = ProjectSourceReference.feedback(batch.id)
        let generationEpoch = try await store.taskGenerationEpoch(source: generationSource)
        let recording: VideoSnapshot?
        if let videoID = batch.videoID {
            guard let found = try await store.videoSnapshot(id: videoID) else { throw TaskContextError.missing(videoID) }
            recording = found
        } else { recording = nil }
        guard batch.projectID != nil || recording != nil else {
            throw TaskContextError.invalid("Choose a project or recording before generating tasks.")
        }
        let recordingTasks: [VideoTask]
        if let videoID = batch.videoID { recordingTasks = try await store.taskSnapshot(videoID: videoID).tasks }
        else { recordingTasks = [] }
        let excludedIdentityKeys = Set(try await store.taskGenerationExclusions(source: generationSource).map(\.identityKey))
        if excludedIdentityKeys.contains("source-wide") {
            throw TaskContextError.invalid("Source needs reconciliation before generation can publish another task. Choose Allow generation again after resolving the deleted task.")
        }
        let identity = ProviderIdentity(provider: configuration.analysisProvider.identity, model: configuration.selectedAnalysisModel)
        let shared = batch.comments.filter(\.isShared)
        let removed = snapshot.tasks.filter(\.archived)
        let linked = batch.comments.filter { comment in
            guard !comment.isShared else { return false }
            guard !excludedIdentityKeys.contains("issue:\(comment.id)") else { return false }
            return !removed.contains { task in
                task.issueID == comment.id || (task.issueID == nil && task.generatedOriginal?.allSourceIDs.contains(comment.id) == true)
            }
        }
        guard !linked.isEmpty else {
            if batch.comments.contains(where: { !$0.isShared }) {
                throw TaskContextError.invalid("Restore a removed task before regenerating its feedback issue.")
            }
            throw TaskContextError.invalid("Mark at least one issue before generating tasks.")
        }
        let groups: [[FeedbackComment]] = stride(from: 0, to: linked.count, by: 2).map { start in
            let focus = Array(linked[start..<min(linked.count, start + 2)])
            return focus + shared.filter { common in
                common.sharedTargetIDs.isEmpty || focus.contains(where: { common.sharedTargetIDs.contains($0.id) })
            }
        }
        var all: [FeedbackTask] = []
        var reviewBatches: [TaskEvidenceReviewBatch] = []
        let contextBatches = projectContext?.batches(maxCharacters: 12_000, maxImages: 2) ?? []
        var renderedContextBatches: [String: TaskEvidenceReviewBatch] = [:]
        for context in contextBatches {
            var images: [Data] = []
            for url in context.imageURLs { images.append(try await TaskFrameRenderer.render(url: url, annotations: [])) }
            let frameIDs = Set(context.frameIDs)
            let authoritativeOCR = Dictionary((projectContext?.frames ?? []).filter { frameIDs.contains($0.id) }
                .map { ($0.evidence.id, $0.ocrText) }, uniquingKeysWith: { first, _ in first })
            renderedContextBatches[context.id] = .init(text: context.promptText, images: images,
                                                       evidence: context.allowedEvidenceReferences,
                                                       authoritativeOCR: authoritativeOCR)
        }
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            await progress?(index, groups.count)
            var lines: [String] = [
                "Project: \(batch.project). Batch: \(batch.title).",
                "Project Context ID: \(batch.projectID ?? "none").",
                "Recording Context ID: \(batch.videoID ?? "none"). Recording title: \(recording?.video.title ?? "none").",
                "Recording brief: " + String((recording?.brief?.markdown ?? "Unavailable").prefix(12_000)),
                "Existing recording tasks (context, do not replace them automatically): " + recordingTasks.map { "\($0.id): \($0.content.title) — \($0.content.behavior)" }.joined(separator: "; "),
                "Return exactly one independently reviewable task for each FOCUS ISSUE below, even if titles or behavior look similar. Set primaryIssueID to that task's exact focus issue ID. primaryIssueID identifies the task; sourceIDs are evidence citations and may cite other relevant focus issues, shared instructions, and supplied evidence. Never infer task identity from sourceIDs. Never combine two focus issues into one task. The full pasted batch is context. Where QA and Manager disagree, add a blocking question. Keep exact source IDs and requirements, and add acceptance checks. Use relevant timestamped Jam evidence in acceptance checks. Never claim Jam visuals were inspected unless a JAM FRAME input is present. Never assume failed linked media works. Do not invent repository findings; ask the editor to inspect the project for consistency. Classify questions as productDecision, investigation, or missingEvidence. Ask the user only for genuine product choices; code investigation belongs to the editor. targetTaskID is empty for new tasks, or an exact existing task ID for the same issue.",
                "COMPLETE FEEDBACK CONTEXT (do not generate tasks for comments outside this focus group):",
                batch.comments.map { "\($0.id) [\($0.reviewer.rawValue)]: \($0.text)" }.joined(separator: "\n"),
                "Existing tasks: " + snapshot.tasks.map { "\($0.id): \($0.content.title), sources=\($0.content.allSourceIDs.sorted())" }.joined(separator: "; ")
            ]
            var frames: [(label: String, data: Data, evidence: ProjectEvidenceReference, ocrText: String)] = []
            var transcriptParts: [String] = []
            if !batch.transcriptSources.isEmpty {
                lines.append("Pasted video transcripts are evidence for the reviewed focus issues. Do not copy a full transcript into task requirements, create tasks for each passage, or treat praise and navigation as requested changes. Keep exact supporting quotes and timestamps. A supplied transcript does not prove that video frames were inspected.")
            }
            var recordingReferences: [ProjectEvidenceReference] = []
            var allowed: [String] = []
            var visitedRecordings: Set<String> = []
            var visitedJamSources: Set<String> = []
            func includeVideo(_ video: VideoSnapshot, sourceID: String) async throws {
                guard visitedRecordings.insert(video.video.id).inserted else { return }
                lines.append("RECORDING \(video.video.id) source=\(sourceID) brief=\(video.brief?.markdown ?? "unavailable")")
                let segments = video.transcript.map { "[\($0.start)-\($0.end)s] \($0.text)" }.joined(separator: "\n")
                recordingReferences += video.transcript.map { .recording(videoID: video.video.id,
                    sourceRevision: video.video.revisions, timestamp: $0.start, evidenceID: $0.id) }
                transcriptParts += LocalAnalysisBatchPlanner.pieces(segments, budget: 8_000).map { "RECORDING \(video.video.id) transcript:\n" + $0 }
                for frame in video.evidence {
                    recordingReferences.append(.recording(videoID: video.video.id, sourceRevision: video.video.revisions,
                                                          timestamp: frame.timestamp, evidenceID: frame.id))
                    let url = paths.absoluteURL(relativePath: frame.imageRelativePath)
                    let rendered = try await TaskFrameRenderer.render(url: url, annotations: [])
                    let reference = ProjectEvidenceReference.recording(videoID: video.video.id,
                        sourceRevision: video.video.revisions, timestamp: frame.timestamp, evidenceID: frame.id)
                    frames.append(("FRAME \(frame.id) at \(frame.timestamp)s from \(video.video.id), source=\(sourceID), OCR=\(frame.ocrText)",
                                   rendered, reference, frame.ocrText))
                }
            }
            func includeJam(_ source: FeedbackSource, sourceID: String,
                            reference: ProjectEvidenceReference) async throws {
                guard source.kind == .jam, visitedJamSources.insert(sourceID).inserted else { return }
                guard let jam = source.jam, jam.state == .ready else {
                    lines.append("JAM RECORDING UNREAD source=\(sourceID). No Jam recording content was analyzed. \(source.error ?? source.jam?.availability.first?.message ?? "Reconnect Jam or retry the import.")")
                    return
                }
                lines.append("JAM EVIDENCE source=\(sourceID) recording=\(jam.recordingID) importedAt=\(jam.importedAt.formatted(.iso8601))")
                for value in jam.availability where value.status != .available {
                    lines.append("JAM LIMITATION source=\(sourceID) component=\(value.component.rawValue) status=\(value.status.rawValue): \(value.message)")
                }
                for value in jam.lastAttemptAvailability ?? [] where value.status != .available {
                    lines.append("JAM RETRY LIMITATION source=\(sourceID) component=\(value.component.rawValue) status=\(value.status.rawValue): \(value.message). Earlier saved evidence, if any, is retained.")
                }
                if !jam.items.contains(where: { $0.component == .frame && $0.localPath != nil }) {
                    lines.append("JAM VISUAL LIMITATION source=\(sourceID): No video frames were imported. Do not claim visual evidence was inspected.")
                }
                for item in jam.items {
                    let timestamp = item.timestampMilliseconds.map { " at \($0)ms" } ?? ""
                    let importTime = (item.importedAt ?? jam.importedAt).formatted(.iso8601)
                    if item.component == .frame, let path = item.localPath {
                        let data = try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: path), annotations: [])
                        frames.append(("JAM FRAME \(item.id)\(timestamp) source=\(sourceID) provenance=\(item.toolName) importedAt=\(importTime)",
                                       data, reference, ""))
                    } else if let text = item.text, !text.isEmpty {
                        let prefix = "JAM \(item.component.rawValue.uppercased()) \(item.id)\(timestamp) source=\(sourceID) provenance=\(item.toolName) importedAt=\(importTime):\n"
                        let pieces = LocalAnalysisBatchPlanner.pieces(text, budget: 8_000)
                        if item.component == .transcript, pieces.count > 1 {
                            transcriptParts += pieces.map { prefix + $0 }
                        } else {
                            lines.append(prefix + String(text.prefix(12_000)))
                        }
                    }
                }
            }
            for comment in group {
                lines.append("FOCUS COMMENT \(comment.id) [\(comment.reviewer.rawValue), \(comment.kind.rawValue)]: \(comment.text)")
                allowed.append(comment.id)
                for id in comment.sourceIDs {
                    guard let source = batch.sources.first(where: { $0.id == id }) else { continue }
                    allowed.append(id)
                    lines.append("SOURCE \(id) link=\(source.url ?? source.filename ?? "local attachment") status=\(source.status.rawValue) OCR=\(source.ocrText)")
                    if source.kind == .image, source.status == .ready, let path = source.localPath {
                        let url = paths.absoluteURL(relativePath: path)
                        let reference = ProjectEvidenceReference.feedback(batchID: batch.id, sourceRevision: batch.revision,
                                                                          commentID: comment.id, sourceID: id)
                        frames.append(("IMAGE \(id) original screenshot",
                                       try await TaskFrameRenderer.render(url: url, annotations: []),
                                       reference, source.ocrText))
                    }
                    if source.kind == .recording, let recordingID = source.recordingID,
                       let video = try await store.videoSnapshot(id: recordingID) {
                        try await includeVideo(video, sourceID: id)
                    }
                    try await includeJam(source, sourceID: id, reference: .feedback(batchID: batch.id,
                        sourceRevision: batch.revision, commentID: comment.id, sourceID: id))
                }
                if comment.sourceIDs.isEmpty, let recording, !comment.isShared {
                    try await includeVideo(recording, sourceID: comment.id)
                }
            }
            for id in batch.batchWideSourceIDs {
                guard let source = batch.sources.first(where: { $0.id == id }) else { continue }
                allowed.append(id)
                lines.append("BATCH-WIDE SOURCE \(id) link=\(source.url ?? source.filename ?? "attachment") status=\(source.status.rawValue) OCR=\(source.ocrText)")
                if source.kind == .image, source.status == .ready, let path = source.localPath {
                    let reference = ProjectEvidenceReference.feedback(batchID: batch.id, sourceRevision: batch.revision,
                                                                      commentID: nil, sourceID: id)
                    frames.append(("BATCH-WIDE IMAGE \(id)",
                                   try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: path), annotations: []),
                                   reference, source.ocrText))
                }
                if source.kind == .recording, let recordingID = source.recordingID,
                   let video = try await store.videoSnapshot(id: recordingID) {
                    try await includeVideo(video, sourceID: id)
                }
                try await includeJam(source, sourceID: id, reference: .feedback(batchID: batch.id,
                    sourceRevision: batch.revision, commentID: nil, sourceID: id))
            }
            let focus = group.filter { !$0.isShared }
            let allowedIDs = Set(allowed)
            let targetTaskIDs = Set(snapshot.tasks.filter { !$0.archived }.map(\.id))
            let dependencyTaskIDs = targetTaskIDs.union(
                projectContext?.existingTasks.filter { !$0.isStale }.map(\.id) ?? [])
            let allProjectEvidence = Set(projectContext?.evidence.map(\.id) ?? [])
            let primaryPassCount = max(1, (frames.count + 1) / 2, transcriptParts.count)
            let passPlan: [(primary: Int, context: Int?)] = contextBatches.isEmpty
                ? (0..<primaryPassCount).map { ($0, nil) }
                : (0..<primaryPassCount).flatMap { primary in contextBatches.indices.map { (primary, Optional($0)) } }
            guard passPlan.count <= 256 else {
                throw TaskContextError.invalid("The feedback and selected project evidence require \(passPlan.count) bounded analysis passes. Select fewer project sources or split this feedback batch before generating tasks.")
            }
            let passCount = passPlan.count
            var passResults: [GeneratedTask] = []
            for pass in 0..<passCount {
                try Task.checkCancellation()
                let primaryPass = passPlan[pass].primary
                let imageSlice = Array(frames.dropFirst(primaryPass * 2).prefix(2))
                let context = passPlan[pass].context.map { contextBatches[$0] }
                let allowedProjectEvidence = Set(context?.allowedEvidenceReferences.map(\.id) ?? [])
                let passLines = lines + ["EVIDENCE PASS \(pass + 1) OF \(passCount). Include observations from this pass in each relevant issue task. Later passes will be consolidated by issue ID."] +
                    (primaryPass < transcriptParts.count ? [transcriptParts[primaryPass]] : []) +
                    imageSlice.enumerated().map { "[image=\($0.offset + 1)] \($0.element.label) evidence=\($0.element.evidence.id)" } +
                    (context.map { ["PROJECT CROSS-REFERENCE (baseline evidence only; do not create unrelated tasks from it):",
                                    $0.promptText(imageOffset: imageSlice.count)] } ?? [])
                var images = imageSlice.map(\.data)
                if let context {
                    images += renderedContextBatches[context.id]?.images ?? []
                }
                let prompt = passLines.joined(separator: "\n")
                let keyData = try JSONEncoder().encode(configuration) + Data("feedback-v4:\(batch.id):\(batch.revision):\(projectContext?.fingerprint ?? "legacy-no-project-context"):\(prompt)".utf8)
                let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
                let generated: GeneratedTaskBatch
                if let cached = try await store.taskCache(key: key, source: generationSource, expectedEpoch: generationEpoch) {
                    do {
                        let decoded = try JSONDecoder().decode(GeneratedTaskBatch.self, from: cached)
                        try validate(decoded, focus: focus, allowed: allowedIDs, targets: targetTaskIDs,
                                     dependencies: dependencyTaskIDs,
                                     allowedProjectEvidence: allowedProjectEvidence)
                        generated = decoded
                        await UsageTrace.cache(key: key, reused: true)
                    } catch {
                        generated = try await requestValidated(prompt: prompt, images: images, focus: focus,
                            allowed: allowedIDs, targets: targetTaskIDs, dependencies: dependencyTaskIDs,
                            allowedProjectEvidence: allowedProjectEvidence)
                        try Task.checkCancellation()
                        try await store.saveTaskCache(key: key, data: JSONEncoder().encode(generated), source: generationSource,
                                                     expectedEpoch: generationEpoch)
                        await UsageTrace.cache(key: key, reused: false)
                    }
                } else {
                    generated = try await requestValidated(prompt: prompt, images: images, focus: focus,
                        allowed: allowedIDs, targets: targetTaskIDs, dependencies: dependencyTaskIDs,
                        allowedProjectEvidence: allowedProjectEvidence)
                    try Task.checkCancellation()
                    try await store.saveTaskCache(key: key, data: JSONEncoder().encode(generated), source: generationSource,
                                                 expectedEpoch: generationEpoch)
                    await UsageTrace.cache(key: key, reused: false)
                }
                passResults += generated.tasks
                if contextBatches.isEmpty || passPlan[pass].context == contextBatches.indices.first {
                    var refs = group.map { ProjectEvidenceReference.feedback(batchID: batch.id, sourceRevision: batch.revision,
                        commentID: $0.id, sourceID: nil) }
                    for comment in group {
                        refs += comment.sourceIDs.map { ProjectEvidenceReference.feedback(batchID: batch.id,
                            sourceRevision: batch.revision, commentID: comment.id, sourceID: $0) }
                    }
                    refs += batch.batchWideSourceIDs.map { ProjectEvidenceReference.feedback(batchID: batch.id,
                        sourceRevision: batch.revision, commentID: nil, sourceID: $0) }
                    refs += recordingReferences
                    let baseLines = lines + ["EVIDENCE PASS \(primaryPass + 1) OF \(primaryPassCount)."] +
                        (primaryPass < transcriptParts.count ? [transcriptParts[primaryPass]] : []) +
                        imageSlice.enumerated().map { "[image=\($0.offset + 1)] \($0.element.label) evidence=\($0.element.evidence.id)" }
                    refs += imageSlice.map(\.evidence)
                    let authoritativeOCR = Dictionary(imageSlice.map { ($0.evidence.id, $0.ocrText) },
                                                      uniquingKeysWith: { first, _ in first })
                    let baseReview = TaskEvidenceReviewBatch(text: baseLines.joined(separator: "\n"),
                        images: imageSlice.map(\.data), evidence: Array(Set(refs)).sorted { $0.id < $1.id },
                        authoritativeOCR: authoritativeOCR)
                    if renderedContextBatches.isEmpty { reviewBatches.append(baseReview) }
                    else {
                        for reference in renderedContextBatches.values.sorted(by: { $0.text < $1.text }) {
                            reviewBatches.append(.init(text: baseReview.text + "\n\nPROJECT CROSS-REFERENCE:\n" +
                                ProjectAnalysisContextBatch.offsetImageLabels(in: reference.text,
                                    by: baseReview.images.count, imageCount: reference.images.count),
                                images: baseReview.images + reference.images,
                                evidence: Array(Set(baseReview.evidence + reference.evidence)).sorted { $0.id < $1.id },
                                authoritativeOCR: baseReview.authoritativeOCR.merging(reference.authoritativeOCR) { first, _ in first }))
                        }
                    }
                }
            }

            for issue in focus {
                let candidates = passResults.filter { $0.primaryIssueID == issue.id }
                guard candidates.count == passCount else {
                    throw FeedbackGenerationOutputError.identity(expected: focus.map(\.id),
                        returned: passResults.compactMap(\.primaryIssueID), missing: [issue.id],
                        duplicates: Self.duplicates(in: passResults.compactMap(\.primaryIssueID)), unexpected: [])
                }
                let item: GeneratedTask
                if candidates.count == 1 {
                    item = candidates[0]
                } else {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let keyData = try encoder.encode(configuration) + encoder.encode(GeneratedTaskBatch(tasks: candidates)) +
                        Data("feedback-consolidation-v1:\(batch.id):\(batch.revision):\(issue.id)".utf8)
                    let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
                    if let cached = try await store.taskCache(key: key, source: generationSource, expectedEpoch: generationEpoch),
                       let decoded = try? JSONDecoder().decode(GeneratedTask.self, from: cached) {
                        try validate(.init(tasks: [decoded]), focus: [issue], allowed: allowedIDs,
                                     targets: targetTaskIDs, dependencies: dependencyTaskIDs,
                                     allowedProjectEvidence: allProjectEvidence)
                        item = decoded
                        await UsageTrace.cache(key: key, reused: true)
                    } else {
                        let original = GeneratedTaskStatement(text: issue.text,
                            origin: issue.kind == .request ? .request : .feedback, sourceIDs: [issue.id])
                        let consolidated = try await FeedbackContentConsolidator(client: client,
                            configuration: configuration, credential: credential)
                            .consolidate(candidates: candidates, originalFeedback: original)
                        try validate(.init(tasks: [consolidated]), focus: [issue], allowed: allowedIDs,
                                     targets: targetTaskIDs, dependencies: dependencyTaskIDs,
                                     allowedProjectEvidence: allProjectEvidence)
                        try Task.checkCancellation()
                        try await store.saveTaskCache(key: key, data: encoder.encode(consolidated), source: generationSource,
                                                     expectedEpoch: generationEpoch)
                        await UsageTrace.cache(key: key, reused: false)
                        item = consolidated
                    }
                }
                var content = item.content
                let projectEvidenceIndex = Dictionary((projectContext?.evidence ?? []).map { ($0.id, $0) },
                                                      uniquingKeysWith: { first, _ in first })
                content.evidenceReferences = (item.projectEvidenceIDs ?? []).compactMap { projectEvidenceIndex[$0] }
                let issueID = issue.id
                content.sourceIDs = Array(Set(content.sourceIDs + batch.batchWideSourceIDs)).sorted()
                let irrelevantShared = Set(shared.filter { !$0.sharedTargetIDs.isEmpty && !$0.sharedTargetIDs.contains(issueID) }.map(\.id))
                content.requirements.removeAll { !Set($0.sourceIDs).isDisjoint(with: irrelevantShared) && Set($0.sourceIDs).isSubset(of: irrelevantShared) }
                content.checks.removeAll { !Set($0.sourceIDs).isDisjoint(with: irrelevantShared) && Set($0.sourceIDs).isSubset(of: irrelevantShared) }
                for index in content.requirements.indices { content.requirements[index].sourceIDs.removeAll { irrelevantShared.contains($0) } }
                for index in content.checks.indices { content.checks[index].sourceIDs.removeAll { irrelevantShared.contains($0) } }
                content.sourceIDs.removeAll { irrelevantShared.contains($0) }
                for index in content.requirements.indices where content.requirements[index].origin == .feedback || content.requirements[index].origin == .request {
                    content.requirements[index].origin = issue.kind == .request ? .request : .feedback
                }
                for common in shared where common.sharedTargetIDs.isEmpty || common.sharedTargetIDs.contains(issueID) {
                    if let requirement = content.requirements.firstIndex(where: { $0.text == common.text }) {
                        if !content.requirements[requirement].sourceIDs.contains(common.id) {
                            content.requirements[requirement].sourceIDs.append(common.id)
                        }
                    } else {
                        content.requirements.append(.init(text: common.text, origin: common.kind == .request ? .request : .feedback, sourceIDs: [common.id]))
                    }
                    if !content.sourceIDs.contains(common.id) { content.sourceIDs.append(common.id) }
                }
                content.sourceIDs = Array(Set(content.sourceIDs + issue.sourceIDs + [issue.id])).sorted()
                let cleanOriginal = issue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                content.requirements.removeAll {
                    [.feedback, .request].contains($0.origin) &&
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == cleanOriginal
                }
                content.requirements.insert(.init(text: issue.text,
                    origin: issue.kind == .request ? .request : .feedback, sourceIDs: [issue.id]), at: 0)
                for id in issue.sourceIDs {
                    guard let source = batch.sources.first(where: { $0.id == id }) else { continue }
                    appendEvidenceQuestions(source: source, sourceID: id, content: &content, batchWide: false)
                }
                for id in batch.batchWideSourceIDs {
                    guard let source = batch.sources.first(where: { $0.id == id }) else { continue }
                    appendEvidenceQuestions(source: source, sourceID: id, content: &content, batchWide: true)
                }
                let prior = snapshot.tasks.first { !$0.archived && $0.issueID == issueID } ?? snapshot.tasks.first {
                    !$0.archived && $0.issueID == nil && $0.generatedOriginal?.allSourceIDs.contains(issueID) == true
                }
                let taskID = prior?.id ?? (item.targetTaskID.isEmpty ? "ftask_\(issueID.replacingOccurrences(of: "fcom_", with: ""))" : item.targetTaskID)
                var task = FeedbackTask(id: taskID, batchID: batch.id, issueID: issueID, sourceRevision: batch.revision, content: content, provenance: identity)
                task.generationRunID = UsageTrace.session?.runID
                all.append(task)
            }
        }
        let expectedIssueIDs = Set(linked.map(\.id))
        let coveredIssueIDs = Set(all.compactMap(\.issueID))
        guard expectedIssueIDs == coveredIssueIDs else {
            let expected = linked.map(\.id)
            let returned = all.compactMap(\.issueID)
            let missing = expected.filter { !coveredIssueIDs.contains($0) }
            let duplicates = Self.duplicates(in: returned)
            let unexpected = returned.filter { !expectedIssueIDs.contains($0) }
            throw FeedbackGenerationOutputError.identity(expected: expected, returned: returned, missing: missing,
                duplicates: duplicates, unexpected: Self.unique(unexpected))
        }
        let reviewInterrupted = try await applyAnalysisMetadata(to: &all, snapshot: snapshot,
            projectContext: projectContext, reviewBatches: reviewBatches)
        for index in all.indices { all[index].generatedOriginal = all[index].content }
        try await store.publishFeedbackGeneration(batchID: batch.id, expectedRevision: batch.revision,
            expectedTasks: Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.revision) }), generated: all,
            expectedGenerationEpoch: generationEpoch, preserveOnCancellation: reviewInterrupted)
        await progress?(groups.count, groups.count)
        return all
    }

    private func applyAnalysisMetadata(to tasks: inout [FeedbackTask], snapshot: FeedbackSnapshot,
                                       projectContext: ProjectAnalysisContext?,
                                       reviewBatches: [TaskEvidenceReviewBatch]) async throws -> Bool {
        let fingerprint = projectContext?.sourceFingerprint ?? "feedback:\(snapshot.batch.id):\(snapshot.batch.revision)"
        var manifest: [TaskAnalysisSourceManifestEntry] = projectContext?.sourceManifest.compactMap { source in
            switch source.kind {
            case .reviewedDocumentation:
                return .init(kind: .reviewedDocumentation, sourceID: source.sourceID, revision: source.revision)
            case .confirmedDecision:
                return .init(kind: .confirmedDecision, sourceID: source.sourceID, revision: source.revision)
            case .importedDocument:
                return .init(kind: .importedDocument, sourceID: source.sourceID, revision: source.revision)
            case .transcript:
                return .init(kind: .recording, sourceID: source.sourceID, revision: source.revision)
            default:
                return nil
            }
        } ?? []
        manifest = Dictionary(grouping: manifest, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
        let drafts = tasks.map { task in
            GeneratedTask(targetTaskID: task.id, title: task.content.title, behavior: task.content.behavior,
                requirements: task.content.requirements.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) },
                checks: task.content.checks.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) },
                questions: task.content.questions.map { .init(question: $0.question, sourceIDs: $0.sourceIDs, category: $0.category) },
                sourceIDs: task.content.sourceIDs, primaryIssueID: task.issueID,
                dependencyTaskIDs: task.content.dependencyTaskIDs)
        }
        var reviews: [TaskEvidenceReview]? = nil
        var observations = Array(repeating: [TaskVisualEvidenceObservation](), count: tasks.count)
        var reviewInterrupted = false
        if let reviewConfiguration {
            if let reviewClient, let reviewCredential {
                do {
                    let result = try await TaskEvidenceReviewer(client: reviewClient, configuration: reviewConfiguration,
                        credential: reviewCredential).review(drafts: drafts, batches: reviewBatches,
                                                             sourceFingerprint: fingerprint, checkpointStore: store,
                                                             projectID: projectContext?.projectID ?? snapshot.batch.projectID)
                    reviews = result.reviews; observations = result.visualObservations
                } catch is CancellationError {
                    reviewInterrupted = true
                    reviews = Array(repeating: TaskEvidenceReviewer.awaitingReview(configuration: reviewConfiguration,
                        sourceFingerprint: fingerprint,
                        error: "Independent review was interrupted. Reconcile its provider outcome before retrying."),
                        count: tasks.count)
                }
                catch {
                    reviews = Array(repeating: TaskEvidenceReviewer.awaitingReview(configuration: reviewConfiguration,
                        sourceFingerprint: fingerprint, error: error.localizedDescription), count: tasks.count)
                }
            } else {
                reviews = Array(repeating: TaskEvidenceReviewer.awaitingReview(configuration: reviewConfiguration,
                    sourceFingerprint: fingerprint,
                    error: "Independent review is configured, but its client or credential is unavailable."), count: tasks.count)
            }
        }
        let warnings = Array(Set((projectContext?.warnings.map(\.sourceID) ?? []) +
            (projectContext?.missingSourceIDs ?? []) + (projectContext?.staleSourceIDs ?? []))).sorted()
        let localSourceIDs = Set(snapshot.batch.comments.map(\.id) + snapshot.batch.sources.map(\.id) +
            snapshot.batch.batchWideSourceIDs)
        for index in tasks.indices {
            var content = tasks[index].content
            content.analysisSourceFingerprint = fingerprint
            content.analysisSourceManifest = manifest
            content.visualEvidenceObservations = observations[index]
            var refs: [ProjectEvidenceReference] = snapshot.batch.projectID == nil ? [] : content.evidenceReferences
            for comment in snapshot.batch.comments where snapshot.batch.projectID != nil && content.allSourceIDs.contains(comment.id) {
                refs.append(.feedback(batchID: snapshot.batch.id, sourceRevision: snapshot.batch.revision,
                                      commentID: comment.id, sourceID: nil))
                refs += comment.sourceIDs.filter { content.allSourceIDs.contains($0) }.map {
                    .feedback(batchID: snapshot.batch.id, sourceRevision: snapshot.batch.revision,
                              commentID: comment.id, sourceID: $0)
                }
            }
            for sourceID in snapshot.batch.batchWideSourceIDs where snapshot.batch.projectID != nil && content.allSourceIDs.contains(sourceID) {
                refs.append(.feedback(batchID: snapshot.batch.id, sourceRevision: snapshot.batch.revision,
                                      commentID: nil, sourceID: sourceID))
            }
            if var review = reviews?[index] {
                if !warnings.isEmpty {
                    if review.status == .passed { review.status = .findings }
                    review.findings.append(.init(kind: .invalidCitation,
                        message: "Selected project evidence is unavailable or changed: " + warnings.joined(separator: ", "),
                        blocking: true))
                }
                content.evidenceReview = review
                for finding in review.findings {
                    refs += finding.evidence + finding.conflictingEvidence
                    guard finding.blocking else { continue }
                    let sourceIDs = (finding.evidence + finding.conflictingEvidence).compactMap(\.taskLegacySourceID)
                        .filter { localSourceIDs.contains($0) }
                    var question = TaskQuestion(question: finding.message, sourceIDs: Array(Set(sourceIDs)).sorted())
                    question.category = finding.kind == .contradiction ? .productDecision : .missingEvidence
                    question.disagreement = finding.kind == .contradiction ? finding.message : ""
                    content.questions.append(question)
                }
            }
            if reviews == nil, !warnings.isEmpty {
                var question = TaskQuestion(question: "Selected project evidence is unavailable or changed: " +
                    warnings.joined(separator: ", "))
                question.category = .missingEvidence
                content.questions.append(question)
            }
            content.evidenceReferences = Array(Set(refs)).sorted { $0.id < $1.id }
            tasks[index].content = content
        }
        return reviewInterrupted
    }

    private func validate(_ output: GeneratedTaskBatch, focus: [FeedbackComment], allowed: Set<String>,
                          targets: Set<String>, dependencies: Set<String>,
                          allowedProjectEvidence: Set<String>, attempt: Int = 1) throws {
        let expected = focus.map(\.id)
        let expectedSet = Set(expected)
        let returned = output.tasks.map { $0.primaryIssueID ?? "<missing>" }
        let returnedIDs = output.tasks.compactMap(\.primaryIssueID)
        let returnedSet = Set(returnedIDs)
        let missing = expected.filter { !returnedSet.contains($0) }
        let duplicates = Self.duplicates(in: returnedIDs)
        let unexpected = returned.filter { $0 == "<missing>" || !expectedSet.contains($0) }
        let uniqueUnexpected = unexpected.reduce(into: [String]()) { values, value in
            if !values.contains(value) { values.append(value) }
        }
        guard returned.count == expected.count, missing.isEmpty, duplicates.isEmpty, uniqueUnexpected.isEmpty else {
            throw FeedbackGenerationOutputError.identity(expected: expected, returned: returned, missing: missing,
                duplicates: duplicates, unexpected: uniqueUnexpected)
        }
        var failures: [FeedbackValidationDiagnostic] = []
        var omittedCount = 0
        func add(_ issueID: String, _ path: String, _ category: FeedbackValidationDiagnostic.Category,
                 sourceIDs: [String] = []) {
            guard failures.count < 32 else { omittedCount += 1; return }
            failures.append(.init(attempt: attempt, primaryIssueID: issueID, fieldPath: path,
                                  category: category, sourceIDs: sourceIDs))
        }
        func citations(_ values: [String], issueID: String, path: String) {
            if values.isEmpty { add(issueID, path, .missingCitations) }
            let unexpected = Self.unique(values.filter { !allowed.contains($0) })
            if !unexpected.isEmpty { add(issueID, path, .unexpectedSourceIDs, sourceIDs: unexpected) }
        }
        func hasContent(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for (taskIndex, item) in output.tasks.enumerated() {
            let issueID = item.primaryIssueID ?? "<missing>"
            let taskPath = "tasks[\(taskIndex)]"
            if !item.targetTaskID.isEmpty && !targets.contains(item.targetTaskID) {
                add(issueID, "\(taskPath).targetTaskID", .invalidTargetTaskID)
            }
            let itemDependencies = Set(item.dependencyTaskIDs ?? [])
            if !itemDependencies.isSubset(of: dependencies) || itemDependencies.contains(item.targetTaskID) {
                add(issueID, "\(taskPath).dependencyTaskIDs", .invalidTargetTaskID,
                    sourceIDs: Array(itemDependencies.subtracting(dependencies)).sorted())
            }
            let invalidProjectEvidence = Set(item.projectEvidenceIDs ?? []).subtracting(allowedProjectEvidence)
            if !invalidProjectEvidence.isEmpty {
                add(issueID, "\(taskPath).projectEvidenceIDs", .unexpectedSourceIDs,
                    sourceIDs: invalidProjectEvidence.sorted())
            }
            if !hasContent(item.title) { add(issueID, "\(taskPath).title", .emptyValue) }
            if item.title.count > 200 { add(issueID, "\(taskPath).title", .valueTooLong) }
            if !hasContent(item.behavior) { add(issueID, "\(taskPath).behavior", .emptyValue) }
            if item.checks.isEmpty { add(issueID, "\(taskPath).checks", .missingItems) }
            citations(item.sourceIDs, issueID: issueID, path: "\(taskPath).sourceIDs")
            for (index, statement) in item.requirements.enumerated() {
                let path = "\(taskPath).requirements[\(index)]"
                if !hasContent(statement.text) { add(issueID, "\(path).text", .emptyValue) }
                if ![TaskOrigin.feedback, .request, .interpretation].contains(statement.origin) {
                    add(issueID, "\(path).origin", .invalidOrigin)
                }
                citations(statement.sourceIDs, issueID: issueID, path: "\(path).sourceIDs")
            }
            for (index, statement) in item.checks.enumerated() {
                let path = "\(taskPath).checks[\(index)]"
                if !hasContent(statement.text) { add(issueID, "\(path).text", .emptyValue) }
                if ![TaskOrigin.feedback, .request, .interpretation].contains(statement.origin) {
                    add(issueID, "\(path).origin", .invalidOrigin)
                }
                citations(statement.sourceIDs, issueID: issueID, path: "\(path).sourceIDs")
            }
            for (index, question) in item.questions.enumerated() {
                let path = "\(taskPath).questions[\(index)]"
                if !hasContent(question.question) { add(issueID, "\(path).question", .emptyValue) }
                citations(question.sourceIDs, issueID: issueID, path: "\(path).sourceIDs")
            }
        }
        if !failures.isEmpty { throw FeedbackContentValidationError(diagnostics: failures, omittedCount: omittedCount) }
    }

    private func requestValidated(prompt: String, images: [Data], focus: [FeedbackComment], allowed: Set<String>,
                                  targets: Set<String>, dependencies: Set<String>,
                                  allowedProjectEvidence: Set<String>) async throws -> GeneratedTaskBatch {
        var attemptPrompt = prompt
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                let request = try TaskGenerationSchema.request(provider: configuration.analysisProvider, configuration: configuration,
                    credential: credential, prompt: attemptPrompt, images: images, allowedSourceIDs: Array(allowed),
                    instructions: "Return complete JSON. Set primaryIssueID to exactly one supplied focus issue ID. Evidence citations are separate: every feedback statement and acceptance check must cite supplied source IDs.",
                    feedback: true, primaryIssueIDs: focus.map(\.id), permittedTargetTaskIDs: Array(targets),
                    permittedDependencyTaskIDs: Array(dependencies),
                    allowedProjectEvidenceIDs: Array(allowedProjectEvidence))
                let response = try await UsageTrace.$stage.withValue(.taskExtraction) { try await client.data(for: request) }
                let output = try TaskGenerationSchema.decode(response, provider: configuration.analysisProvider)
                try validate(output, focus: focus, allowed: allowed, targets: targets, dependencies: dependencies,
                             allowedProjectEvidence: allowedProjectEvidence, attempt: attempt + 1)
                return output
            } catch {
                if let error = error as? FeedbackContentValidationError {
                    await UsageTrace.feedbackValidation(error.diagnostics, truncated: error.omittedCount > 0)
                }
                guard attempt == 0, let reason = recoverableOutputReason(error) else { throw error }
                attemptPrompt = prompt + "\n\nRECOVERY ATTEMPT 1 OF 1. The previous output was rejected: \(reason) Return the full corrected task set. Expected primaryIssueID values: \(focus.map(\.id).joined(separator: ", "))."
            }
        }
        throw LocalProviderError.invalidOutput
    }

    private func recoverableOutputReason(_ error: Error) -> String? {
        if let error = error as? FeedbackGenerationOutputError { return error.localizedDescription }
        if let error = error as? FeedbackContentValidationError { return error.localizedDescription }
        if let error = error as? LocalProviderError, error == .invalidOutput {
            return "The response was not valid structured task JSON."
        }
        if error is DecodingError { return "The response did not match the feedback task schema." }
        return nil
    }

    private static func duplicates(in values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return values.reduce(into: [String]()) { duplicates, value in
            if counts[value, default: 0] > 1, !duplicates.contains(value) { duplicates.append(value) }
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { unique, value in
            if !unique.contains(value) { unique.append(value) }
        }
    }

    private func appendEvidenceQuestions(source: FeedbackSource, sourceID: String, content: inout TaskContent, batchWide: Bool) {
        if source.kind == .jam {
            guard let jam = source.jam, jam.state == .ready else {
                let detail = source.error ?? source.jam?.availability.first?.message ?? "The Jam recording was not read."
                let prompt = detail.localizedCaseInsensitiveContains("reconnect")
                    ? detail
                    : "The Jam recording was not read. Reconnect Jam in Settings or retry the import before implementation. \(detail)"
                var question = TaskQuestion(question: prompt, sourceIDs: [sourceID]); question.category = .missingEvidence
                content.questions.append(question)
                return
            }
            for limitation in jam.availability where limitation.status != .available {
                var question = TaskQuestion(question: "Jam evidence limitation: \(limitation.message)", sourceIDs: [sourceID])
                question.category = .missingEvidence
                question.isBlocking = false
                question.nonBlockingReason = "The recording details were read; this missing Jam evidence remains an explicit limitation."
                content.questions.append(question)
            }
            return
        }
        guard source.status != .ready else { return }
        let scope = batchWide ? "unavailable batch-wide evidence" : "unavailable evidence"
        var question = TaskQuestion(question: "Inspect \(scope) at \(source.url ?? source.filename ?? "the attachment") before implementation.", sourceIDs: [sourceID])
        question.category = .missingEvidence; content.questions.append(question)
    }
}
