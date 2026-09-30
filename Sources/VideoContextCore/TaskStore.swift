import Foundation
import GRDB

extension VideoContextStore {
    static func createTaskSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE video_tasks(id TEXT PRIMARY KEY, video_id TEXT NOT NULL REFERENCES videos(id), position INTEGER NOT NULL, document BLOB NOT NULL);
            CREATE INDEX tasks_video ON video_tasks(video_id, position);
            CREATE TABLE task_history(task_id TEXT NOT NULL, revision INTEGER NOT NULL, document BLOB NOT NULL, PRIMARY KEY(task_id, revision));
            CREATE TABLE task_proposals(id TEXT PRIMARY KEY, video_id TEXT NOT NULL REFERENCES videos(id), document BLOB NOT NULL);
            CREATE TABLE task_generation_cache(cache_key TEXT PRIMARY KEY, document BLOB NOT NULL);
            """)
    }

    static func fetchTasks(videoID: String, db: Database) throws -> [VideoTask] {
        guard try db.tableExists("video_tasks") else { return [] }
        var tasks = try Row.fetchAll(db, sql: "SELECT document FROM video_tasks WHERE video_id = ? ORDER BY position, id", arguments: [videoID]).map {
            try JSONDecoder().decode(VideoTask.self, from: $0["document"] as Data)
        }
        let projectID = try fetchVideo(id: videoID, from: db)?.projectID
        for i in tasks.indices {
            tasks[i].analysisIsStale = (try? taskAnalysisSourcesAreStale(tasks[i].content, projectID: projectID, db: db)) ?? true
            let reviewIncomplete = tasks[i].content.evidenceReview.map { [.awaitingReview, .failed].contains($0.status) } ?? false
            if (try? validateTaskDecisions(tasks[i].content, projectID: projectID, db: db)) == nil ||
                tasks[i].analysisIsStale == true ||
                reviewIncomplete {
                tasks[i].reviewedRevision = nil
            }
        }
        return tasks
    }

    static func writeTask(_ task: VideoTask, db: Database) throws {
        let data = try JSONEncoder().encode(task)
        try db.execute(sql: "INSERT INTO video_tasks(id, video_id, position, document) VALUES(?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET position=excluded.position, document=excluded.document", arguments: [task.id, task.videoID, task.order, data])
        try db.execute(sql: "INSERT INTO task_history(task_id, revision, document) VALUES(?, ?, ?) ON CONFLICT(task_id, revision) DO UPDATE SET document=excluded.document", arguments: [task.id, task.revision, data])
    }

    static func invalidateTasks(videoID: String, in db: Database) throws {
        for var task in try fetchTasks(videoID: videoID, db: db) {
            task.revision += 1; task.reviewedRevision = nil
            try writeTask(task, db: db)
        }
    }

    static func validateContent(_ content: TaskContent, videoID: String, db: Database) throws {
        guard !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.title.count <= 200 else { throw TaskContextError.invalid("A task title is required.") }
        let segments = try String.fetchAll(db, sql: "SELECT id FROM transcript_segments WHERE video_id = ?", arguments: [videoID])
        let frames = try String.fetchAll(db, sql: "SELECT id FROM evidence_items WHERE video_id = ?", arguments: [videoID])
        guard content.allSourceIDs.isSubset(of: Set(segments + frames)) else { throw TaskContextError.invalid("A task references evidence missing from this recording. Reconcile its evidence first.") }
        guard content.annotations.allSatisfy({ $0.isValid && $0.text.count <= 500 && frames.contains($0.evidenceID) }), Dictionary(grouping: content.annotations, by: \.evidenceID).values.allSatisfy({ $0.count <= 12 }) else { throw TaskContextError.invalid("Annotations need a description and valid coordinates inside a linked screenshot.") }
        for item in content.requirements + content.checks {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.origin != .recording || !item.sourceIDs.isEmpty else { throw TaskContextError.invalid("Recording statements require supporting evidence; checklist text cannot be empty.") }
        }
        guard content.questions.allSatisfy({ !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TaskContextError.invalid("Question text cannot be empty.") }
        if !content.evidenceReferences.isEmpty {
            guard let projectID = try fetchVideo(id: videoID, from: db)?.projectID else {
                throw TaskContextError.invalid("Task evidence references require a project.")
            }
            try validateEvidence(content.evidenceReferences, projectID: projectID, database: db)
        }
    }

    static func invalidatingAnalysisReview(in draft: TaskContent, comparedWith existing: TaskContent?) -> TaskContent {
        guard let existing, existing.evidenceReview != nil else { return draft }
        var before = existing, after = draft
        before.evidenceReview = nil; before.visualEvidenceObservations = []
        after.evidenceReview = nil; after.visualEvidenceObservations = []
        guard before != after else { return draft }
        var value = draft
        if let previous = existing.evidenceReview {
            value.evidenceReview = .init(status: .awaitingReview, reviewer: previous.reviewer,
                sourceFingerprint: previous.sourceFingerprint, promptVersion: previous.promptVersion,
                errorMessage: "Task content changed after the evidence review.")
        }
        value.visualEvidenceObservations = []
        return value
    }

    static func validateDependencyGraph(_ tasks: [(id: String, content: TaskContent)]) throws {
        let valid = Set(tasks.map(\.id))
        let graph = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.content.dependencyTaskIDs) })
        for (id, dependencies) in graph {
            guard Set(dependencies).isSubset(of: valid), !dependencies.contains(id) else {
                throw TaskContextError.invalid("Task dependencies reference an unavailable task or the task itself.")
            }
        }
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ id: String) throws {
            if visiting.contains(id) { throw TaskContextError.invalid("Task dependencies contain a cycle.") }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for dependency in graph[id] ?? [] { try visit(dependency) }
            visiting.remove(id); visited.insert(id)
        }
        for id in graph.keys { try visit(id) }
    }

    static func projectDependencyTasks(projectID: String, db: Database) throws -> [(id: String, content: TaskContent)] {
        var result: [(String, TaskContent)] = []
        let videoRows = try Data.fetchAll(db, sql: "SELECT t.document FROM video_tasks t JOIN videos v ON v.id=t.video_id WHERE v.project_id=?", arguments: [projectID])
        for data in videoRows {
            let task = try JSONDecoder().decode(VideoTask.self, from: data)
            if !task.archived { result.append((task.id, task.content)) }
        }
        let feedbackRows = try Data.fetchAll(db, sql: "SELECT document FROM feedback_tasks")
        for data in feedbackRows {
            let task = try JSONDecoder().decode(FeedbackTask.self, from: data)
            guard !task.archived, try feedbackBatch(task.batchID, in: db).projectID == projectID else { continue }
            result.append((task.id, task.content))
        }
        return result
    }

    public static func taskAnalysisIsStale(_ content: TaskContent, projectID: String?, db: Database) throws -> Bool {
        if let review = content.evidenceReview, [.awaitingReview, .failed].contains(review.status) { return true }
        return try taskAnalysisSourcesAreStale(content, projectID: projectID, db: db)
    }

    static func taskAnalysisSourcesAreStale(_ content: TaskContent, projectID: String?, db: Database) throws -> Bool {
        guard !content.evidenceReferences.isEmpty || !content.analysisSourceManifest.isEmpty else { return false }
        guard let projectID else { return true }
        let selectedDocumentation = Set(content.analysisSourceManifest.filter { $0.kind == .reviewedDocumentation }
            .map { $0.sourceID.replacingOccurrences(of: "documentation:", with: "") })
        let selectedDocuments = Set(content.analysisSourceManifest.filter { $0.kind == .importedDocument }
            .map { $0.sourceID.replacingOccurrences(of: "document:", with: "") })
        let selectedRecordings = Set(content.analysisSourceManifest.filter { $0.kind == .recording }
            .map { $0.sourceID.replacingOccurrences(of: "recording:", with: "") })
        if !selectedDocumentation.isEmpty || !selectedDocuments.isEmpty || !selectedRecordings.isEmpty {
            guard try db.tableExists("project_analysis_selections"),
                  let data = try Data.fetchOne(db, sql: "SELECT selection FROM project_analysis_selections WHERE project_id=?", arguments: [projectID]),
                  let selection = try? JSONDecoder().decode(ProjectAnalysisSelection.self, from: data),
                  Set(selection.documentIDs) == selectedDocumentation,
                  Set(selection.documentSourceIDs) == selectedDocuments,
                  Set(selection.recordingIDs) == selectedRecordings else { return true }
        }
        do { try validateFreshDocumentationEvidence(content.evidenceReferences, projectID: projectID, database: db) }
        catch { return true }
        for item in content.analysisSourceManifest {
            switch item.kind {
            case .reviewedDocumentation:
                guard item.revision.hasPrefix("r"), let revision = Int(item.revision.dropFirst()) else { return true }
                let id = item.sourceID.replacingOccurrences(of: "documentation:", with: "")
                guard let row = try Row.fetchOne(db, sql: "SELECT current_revision,reviewed_revision FROM project_documentation WHERE id=? AND project_id=?", arguments: [id, projectID]),
                      (row["current_revision"] as Int) == revision,
                      (row["reviewed_revision"] as Int?) == revision else { return true }
            case .confirmedDecision:
                guard item.revision.hasPrefix("r"), let revision = Int(item.revision.dropFirst()) else { return true }
                let id = item.sourceID.replacingOccurrences(of: "decision:", with: "")
                guard try Int.fetchOne(db, sql: "SELECT revision FROM project_decisions WHERE id=? AND project_id=?", arguments: [id, projectID]) == revision else { return true }
            case .importedDocument:
                let id = item.sourceID.replacingOccurrences(of: "document:", with: "")
                let parts = item.revision.dropFirst().split(separator: ":", maxSplits: 1).map(String.init)
                guard item.revision.hasPrefix("r"), parts.count == 2, let revision = Int(parts[0]),
                      let row = try Row.fetchOne(db, sql: "SELECT s.current_revision,r.content_hash FROM project_document_sources s JOIN project_document_source_revisions r ON r.source_id=s.id AND r.revision=s.current_revision WHERE s.id=? AND s.project_id=?", arguments: [id, projectID]),
                      (row["current_revision"] as Int) == revision,
                      (row["content_hash"] as String) == parts[1] else { return true }
            case .recording:
                let id = item.sourceID.replacingOccurrences(of: "recording:", with: "")
                guard let video = try fetchVideo(id: id, from: db), video.projectID == projectID else { return true }
                let current = "transcript:\(video.revisions.transcript):evidence:\(video.revisions.evidence):brief:\(video.revisions.brief)"
                guard item.revision == current else { return true }
            }
        }
        return false
    }

    public func taskAnalysisIsStale(_ content: TaskContent, projectID: String?) throws -> Bool {
        try pool.read { try Self.taskAnalysisIsStale(content, projectID: projectID, db: $0) }
    }

    public func taskSnapshot(videoID: String) throws -> TaskLibrarySnapshot {
        try pool.read { db in
            guard let video = try Self.fetchVideo(id: videoID, from: db) else { throw VideoContextStoreError.videoNotFound(videoID) }
            let tasks = try Self.fetchTasks(videoID: videoID, db: db)
            let proposals: [TaskProposal] = try db.tableExists("task_proposals") ? Row.fetchAll(db, sql: "SELECT document FROM task_proposals WHERE video_id = ? ORDER BY rowid", arguments: [videoID]).map { try JSONDecoder().decode(TaskProposal.self, from: $0["document"] as Data) } : []
            return TaskLibrarySnapshot(video: video, tasks: tasks,
                transcript: try Row.fetchAll(db, sql: "SELECT * FROM transcript_segments WHERE video_id = ? ORDER BY start_time, id", arguments: [videoID]).map(Self.transcript(from:)),
                evidence: try Row.fetchAll(db, sql: "SELECT * FROM evidence_items WHERE video_id = ? ORDER BY timestamp, id", arguments: [videoID]).map(Self.evidence(from:)), proposals: proposals)
        }
    }

    public func saveTask(_ draft: VideoTask, expectedRevision: Int?, expectedSource: ArtifactRevision) throws -> VideoTask {
        try pool.write { db in
            guard let video = try Self.fetchVideo(id: draft.videoID, from: db) else { throw VideoContextStoreError.videoNotFound(draft.videoID) }
            guard video.revisions == expectedSource else { throw TaskContextError.conflict }
            let existing = try Self.fetchTasks(videoID: draft.videoID, db: db).first { $0.id == draft.id }
            guard existing?.revision == expectedRevision else { throw TaskContextError.conflict }
            if existing == nil, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM video_tasks WHERE id = ?)", arguments: [draft.id]) == true { throw TaskContextError.conflict }
            if existing == nil, try Self.isTaskDeleted(draft.id, db: db) { throw TaskContextError.conflict }
            try Self.validateContent(draft.content, videoID: draft.videoID, db: db)
            var value = draft
            if let existing {
                value = existing; value.content = Self.invalidatingAnalysisReview(in: draft.content, comparedWith: existing.content); value.order = draft.order; value.archived = draft.archived
                value.revision += 1; value.reviewedRevision = nil
            } else {
                value.revision = 1; value.reviewedRevision = nil; value.wasReviewed = false; value.sourceRevision = expectedSource
            }
            value.analysisIsStale = nil
            var prospective = try video.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                Self.fetchTasks(videoID: draft.videoID, db: db).filter { !$0.archived }.map { ($0.id, $0.content) }
            prospective.removeAll { $0.id == value.id }
            if !value.archived { prospective.append((value.id, value.content)) }
            try Self.validateDependencyGraph(prospective)
            try Self.writeTask(value, db: db)
            return value
        }
    }

    public func reviewTask(videoID: String, taskID: String, expectedRevision: Int, expectedSource: ArtifactRevision) throws {
        try pool.write { db in
            guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == expectedSource,
                  var task = try Self.fetchTasks(videoID: videoID, db: db).first(where: { $0.id == taskID }), task.revision == expectedRevision else { throw TaskContextError.conflict }
            guard !task.archived, !task.isStale(video), video.status == .ready, task.content.blockers == 0,
                  try !Self.taskAnalysisIsStale(task.content, projectID: video.projectID, db: db),
                  !task.content.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !task.content.checks.isEmpty else { throw TaskContextError.reviewRequired }
            try Self.validateContent(task.content, videoID: videoID, db: db)
            try Self.validateTaskDecisions(task.content, projectID: video.projectID, db: db)
            task.revision += 1; task.reviewedRevision = task.revision; task.wasReviewed = true
            try Self.writeTask(task, db: db)
        }
    }

    public func publishTaskProposals(_ proposals: [TaskProposal], videoID: String, expectedSource: ArtifactRevision,
                                     expectedTasks: [String: Int], expectedGenerationEpoch: Int? = nil,
                                     preserveOnCancellation: Bool = false) throws {
        if !preserveOnCancellation { try Task.checkCancellation() }
        try pool.write { db in
            if !preserveOnCancellation { try Task.checkCancellation() }
            try Self.assertTaskGenerationEpoch(source: .recording(videoID), expected: expectedGenerationEpoch, db: db)
            if try Self.generationExclusionExists(source: .recording(videoID), identityKey: "source-wide", db: db) { return }
            guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == expectedSource, video.status == .ready, !video.revisions.isBriefStale else { throw TaskContextError.conflict }
            let existing = try Self.fetchTasks(videoID: videoID, db: db)
            guard Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.revision) }) == expectedTasks else { throw TaskContextError.conflict }
            for proposal in proposals {
                guard proposal.videoID == videoID, proposal.sourceRevision == expectedSource else { throw TaskContextError.conflict }
                if let taskID = proposal.taskID, try Self.isTaskDeleted(taskID, db: db) { throw TaskContextError.conflict }
                if let runID = proposal.generationRunID {
                    guard let data = try Data.fetchOne(db, sql: "SELECT document FROM usage_runs WHERE id = ? AND video_id = ?", arguments: [runID, videoID]),
                          try JSONDecoder().decode(UsageRun.self, from: data).operation == .taskGeneration else { throw TaskContextError.conflict }
                }
                if let content = proposal.content {
                    try Self.validateContent(content, videoID: videoID, db: db)
                    if try Self.taskAnalysisSourcesAreStale(content, projectID: video.projectID, db: db) { throw TaskContextError.conflict }
                }
                if let content = proposal.content,
                   try Self.generationExclusionExists(source: .recording(videoID), identityKey: Self.recordingGenerationIdentity(content), db: db) {
                    continue
                }
                if proposal.kind != .addition {
                    guard existing.contains(where: { $0.id == proposal.taskID && $0.revision == proposal.expectedTaskRevision }) else { throw TaskContextError.conflict }
                }
            }
            let dependencyTasks = try video.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                existing.filter { !$0.archived }.map { ($0.id, $0.content) }
            var prospective = Dictionary(uniqueKeysWithValues: dependencyTasks)
            for proposal in proposals {
                switch proposal.kind {
                case .addition:
                    if let content = proposal.content { prospective[proposal.id] = content }
                case .modification:
                    if let taskID = proposal.taskID, let content = proposal.content { prospective[taskID] = content }
                case .archive:
                    if let taskID = proposal.taskID { prospective[taskID] = nil }
                }
            }
            try Self.validateDependencyGraph(prospective.map { ($0.key, $0.value) })
            var allowed: [TaskProposal] = []
            for proposal in proposals {
                if let content = proposal.content,
                   try Self.generationExclusionExists(source: .recording(videoID), identityKey: Self.recordingGenerationIdentity(content), db: db) {
                    continue
                }
                allowed.append(proposal)
            }
            try db.execute(sql: "DELETE FROM task_proposals WHERE video_id = ?", arguments: [videoID])
            for proposal in allowed {
                try db.execute(sql: "INSERT INTO task_proposals VALUES(?, ?, ?)", arguments: [proposal.id, videoID, try JSONEncoder().encode(proposal)])
            }
            if !preserveOnCancellation { try Task.checkCancellation() }
        }
    }

    public func resolveTaskProposal(videoID: String, proposalID: String, apply: Bool, keepWording: Bool = false) throws {
        try pool.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT document FROM task_proposals WHERE id = ? AND video_id = ?", arguments: [proposalID, videoID]) else { throw TaskContextError.missing(proposalID) }
            let proposal = try JSONDecoder().decode(TaskProposal.self, from: data)
            if apply {
                guard try !Self.isProjectProposalOutdated(proposalID, db: db) else { throw TaskContextError.conflict }
                guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == proposal.sourceRevision, !video.revisions.isBriefStale else { throw TaskContextError.conflict }
                let tasks = try Self.fetchTasks(videoID: videoID, db: db)
                var value: VideoTask
                if proposal.kind == .addition {
                    guard let content = proposal.content else { throw TaskContextError.invalid("Proposal has no task content.") }
                    guard try !Self.generationExclusionExists(source: .recording(videoID), identityKey: Self.recordingGenerationIdentity(content), db: db) else { throw TaskContextError.conflict }
                    value = VideoTask(videoID: videoID, sourceRevision: proposal.sourceRevision, content: content, order: (tasks.map(\.order).max() ?? -1) + 1, provenance: proposal.provenance)
                } else {
                    if let taskID = proposal.taskID, try Self.isTaskDeleted(taskID, db: db) { throw TaskContextError.conflict }
                    guard var current = tasks.first(where: { $0.id == proposal.taskID }), current.revision == proposal.expectedTaskRevision else { throw TaskContextError.conflict }
                    current.revision += 1; current.reviewedRevision = nil
                    current.sourceRevision = proposal.sourceRevision
                    if proposal.kind == .archive && !keepWording { current.archived = true }
                    if let content = proposal.content {
                        if keepWording {
                            // Reconcile references while retaining the user's wording, answers and annotations.
                            let available = Set(try String.fetchAll(db, sql: "SELECT id FROM transcript_segments WHERE video_id = ? UNION SELECT id FROM evidence_items WHERE video_id = ?", arguments: [videoID, videoID]))
                            current.content.sourceIDs = content.sourceIDs
                            for index in current.content.requirements.indices { current.content.requirements[index].sourceIDs = current.content.requirements[index].sourceIDs.filter { available.contains($0) } }
                            for index in current.content.checks.indices { current.content.checks[index].sourceIDs = current.content.checks[index].sourceIDs.filter { available.contains($0) } }
                            current.content.evidenceReferences = content.evidenceReferences
                            current.content.analysisSourceFingerprint = content.analysisSourceFingerprint
                            current.content.analysisSourceManifest = content.analysisSourceManifest
                            current.content.evidenceReview = content.evidenceReview
                            current.content.visualEvidenceObservations = content.visualEvidenceObservations
                            current.content.dependencyTaskIDs = content.dependencyTaskIDs
                            current.content = Self.invalidatingAnalysisReview(in: current.content, comparedWith: content)
                        } else {
                            current.content = content
                        }
                    }
                    current.provenance = proposal.provenance; value = current
                }
                value.generationRunID = proposal.generationRunID
                value.analysisIsStale = nil
                try Self.validateContent(value.content, videoID: videoID, db: db)
                var prospective = try video.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                    tasks.filter { !$0.archived }.map { ($0.id, $0.content) }
                prospective.removeAll { $0.id == value.id }
                if !value.archived { prospective.append((value.id, value.content)) }
                try Self.validateDependencyGraph(prospective)
                try Self.writeTask(value, db: db)
            }
            try db.execute(sql: "DELETE FROM task_proposals WHERE id = ? AND video_id = ?", arguments: [proposalID, videoID])
        }
    }

}

extension VideoContextStore {
    public func moveTask(videoID: String, taskID: String, direction: Int, expectedRevision: Int, expectedSource: ArtifactRevision) throws {
        try pool.write { db in
            guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == expectedSource else { throw TaskContextError.conflict }
            var tasks = try Self.fetchTasks(videoID: videoID, db: db)
            guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].revision == expectedRevision else { throw TaskContextError.conflict }
            let target = index + (direction < 0 ? -1 : 1)
            guard tasks.indices.contains(target) else { return }
            tasks.swapAt(index, target)
            for position in tasks.indices where tasks[position].order != position {
                let wasApproved = tasks[position].reviewedRevision == tasks[position].revision
                tasks[position].order = position; tasks[position].revision += 1
                if wasApproved { tasks[position].reviewedRevision = tasks[position].revision }
                try Self.writeTask(tasks[position], db: db)
            }
        }
    }
}
