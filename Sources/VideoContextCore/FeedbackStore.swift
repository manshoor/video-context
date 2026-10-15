import Foundation
import GRDB

extension VideoContextStore {
    static func createFeedbackProjectSchema(in db: Database) throws {
        try db.execute(sql: "CREATE TABLE feedback_projects(id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE)")
        let rows = try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches")
        for data in rows {
            var batch = try JSONDecoder().decode(FeedbackBatch.self, from: data)
            let name = batch.project.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let project = try feedbackProject(named: name, in: db)
            batch.projectID = project.id
            try db.execute(sql: "UPDATE feedback_batches SET document=? WHERE id=?", arguments: [try JSONEncoder().encode(batch), batch.id])
        }
    }
    static func feedbackProject(named name: String, in db: Database) throws -> FeedbackProject {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw TaskContextError.invalid("Enter a project name.") }
        let normalized = clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let row = try Row.fetchOne(db, sql: "SELECT id,name FROM feedback_projects WHERE normalized_name=?", arguments: [normalized]) {
            return .init(id: row["id"], name: row["name"])
        }
        let project = FeedbackProject(name: clean)
        try db.execute(sql: "INSERT INTO feedback_projects(id,name,normalized_name) VALUES(?,?,?)", arguments: [project.id, project.name, normalized])
        return project
    }
    public func createFeedbackProject(name: String) throws -> FeedbackProject {
        try pool.write { try Self.feedbackProject(named: name, in: $0) }
    }
    public func listFeedbackProjects() throws -> [FeedbackProject] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,name FROM feedback_projects ORDER BY name COLLATE NOCASE").map {
                FeedbackProject(id: $0["id"], name: $0["name"])
            }
        }
    }
    static func createFeedbackSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE feedback_batches(id TEXT PRIMARY KEY, updated_at REAL NOT NULL, document BLOB NOT NULL);
            CREATE TABLE feedback_tasks(id TEXT PRIMARY KEY, batch_id TEXT NOT NULL REFERENCES feedback_batches(id), document BLOB NOT NULL);
            CREATE INDEX feedback_tasks_batch ON feedback_tasks(batch_id);
            CREATE TABLE feedback_task_history(task_id TEXT NOT NULL, revision INTEGER NOT NULL, document BLOB NOT NULL, PRIMARY KEY(task_id, revision));
            CREATE TABLE feedback_proposals(id TEXT PRIMARY KEY, batch_id TEXT NOT NULL REFERENCES feedback_batches(id), document BLOB NOT NULL);
            CREATE INDEX feedback_proposals_batch ON feedback_proposals(batch_id);
            """)
    }

    static func feedbackBatch(_ id: String, in db: Database) throws -> FeedbackBatch {
        guard let data = try Data.fetchOne(db, sql: "SELECT document FROM feedback_batches WHERE id=?", arguments: [id]) else { throw TaskContextError.missing(id) }
        return try JSONDecoder().decode(FeedbackBatch.self, from: data)
    }
    static func feedbackTasks(_ id: String, in db: Database) throws -> [FeedbackTask] {
        var tasks = try Data.fetchAll(db, sql: "SELECT document FROM feedback_tasks WHERE batch_id=? ORDER BY rowid", arguments: [id]).map { try JSONDecoder().decode(FeedbackTask.self, from: $0) }
        let batch = try feedbackBatch(id, in: db)
        if (try? validateDocumentationRequest(batch, db: db)) == nil {
            for i in tasks.indices { tasks[i].approvedRevision = nil }
        }
        for i in tasks.indices {
            tasks[i].analysisIsStale = (try? taskAnalysisSourcesAreStale(tasks[i].content, projectID: batch.projectID, db: db)) ?? true
            let reviewIncomplete = tasks[i].content.evidenceReview.map { [.awaitingReview, .failed].contains($0.status) } ?? false
            if (try? validateTaskDecisions(tasks[i].content, projectID: batch.projectID, db: db)) == nil ||
                tasks[i].analysisIsStale == true || reviewIncomplete {
                tasks[i].approvedRevision = nil
            }
        }
        return tasks
    }
    static func feedbackProposals(_ id: String, in db: Database) throws -> [FeedbackTaskProposal] {
        try Data.fetchAll(db, sql: "SELECT document FROM feedback_proposals WHERE batch_id=? ORDER BY rowid", arguments: [id]).map { try JSONDecoder().decode(FeedbackTaskProposal.self, from: $0) }
    }
    static func writeFeedbackTask(_ task: FeedbackTask, in db: Database) throws {
        let data = try JSONEncoder().encode(task)
        try db.execute(sql: "INSERT INTO feedback_tasks(id,batch_id,document) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document", arguments: [task.id, task.batchID, data])
        try db.execute(sql: "INSERT INTO feedback_task_history(task_id,revision,document) VALUES(?,?,?)", arguments: [task.id, task.revision, data])
    }
    static func sameGeneratedContent(_ left: TaskContent?, _ right: TaskContent) -> Bool {
        guard let left else { return false }
        func statements(_ items: [TaskStatement]) -> [String] {
            items.map { "\($0.origin.rawValue):\($0.text):\($0.sourceIDs.sorted().joined(separator: ","))" }
        }
        return left.title == right.title && left.behavior == right.behavior &&
            statements(left.requirements) == statements(right.requirements) &&
            statements(left.checks) == statements(right.checks) &&
            left.questions.map { "\($0.question):\($0.sourceIDs.sorted())" } == right.questions.map { "\($0.question):\($0.sourceIDs.sorted())" } &&
            Set(left.sourceIDs) == Set(right.sourceIDs) &&
            left.dependencyTaskIDs == right.dependencyTaskIDs &&
            left.analysisSourceFingerprint == right.analysisSourceFingerprint &&
            left.evidenceReferences == right.evidenceReferences &&
            left.evidenceReview?.status == right.evidenceReview?.status &&
            left.evidenceReview?.findings.map { "\($0.kind.rawValue):\($0.message):\($0.blocking):\($0.evidence.map(\.id)):\($0.conflictingEvidence.map(\.id))" } ==
                right.evidenceReview?.findings.map { "\($0.kind.rawValue):\($0.message):\($0.blocking):\($0.evidence.map(\.id)):\($0.conflictingEvidence.map(\.id))" } &&
            left.visualEvidenceObservations.map { "\($0.evidence.id):\($0.visualInterpretation):\($0.extractedOCR):\($0.assessment.rawValue)" } ==
                right.visualEvidenceObservations.map { "\($0.evidence.id):\($0.visualInterpretation):\($0.extractedOCR):\($0.assessment.rawValue)" }
    }
    static func validateFeedback(_ batch: FeedbackBatch) throws {
        guard batch.videoID?.isEmpty == false || batch.projectID?.isEmpty == false else {
            throw TaskContextError.invalid("Choose a project or recording for this feedback.")
        }
        guard
              !batch.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !batch.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !batch.comments.isEmpty || !batch.transcriptSources.isEmpty else { throw TaskContextError.invalid("Enter a title and feedback text.") }
        let ids = Set(batch.sources.map(\.id))
        guard ids.count == batch.sources.count,
              Set(batch.batchWideSourceIDs).isSubset(of: ids),
              batch.comments.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Set($0.sourceIDs).isSubset(of: ids) &&
                  Set($0.sharedTargetIDs).isSubset(of: Set(batch.comments.map(\.id))) }),
              batch.sources.allSatisfy({ source in
                  guard let path = source.localPath else { return true }
                  return !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
              }) else { throw TaskContextError.invalid("Feedback source references or local paths are invalid.") }
    }
    static func validateFeedbackTask(_ content: TaskContent, batch: FeedbackBatch) throws {
        let ids = Set(batch.comments.map(\.id) + batch.sources.map(\.id))
        guard !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.title.count <= 200,
              !content.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !content.checks.isEmpty,
              !content.allSourceIDs.isEmpty,
              content.allSourceIDs.isSubset(of: ids),
              (content.requirements + content.checks).allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (![TaskOrigin.feedback, .request].contains($0.origin) || !$0.sourceIDs.isEmpty) }),
              content.questions.allSatisfy({ !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              content.annotations.allSatisfy({ annotation in annotation.isValid && batch.sources.contains(where: { $0.id == annotation.evidenceID && $0.kind == .image }) })
        else { throw TaskContextError.invalid("A feedback task is missing behavior, checks, or valid evidence.") }
    }

    public func createFeedback(_ batch: FeedbackBatch) throws {
        try pool.write { db in
            var value = batch
            if value.projectID == nil && !value.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let project = try Self.feedbackProject(named: value.project, in: db)
                value.projectID = project.id; value.project = project.name
            }
            try Self.validateFeedback(value)
            try Self.validateProjectLinks(value, db: db)
            if let videoID = value.videoID, try Self.fetchVideo(id: videoID, from: db) == nil {
                throw TaskContextError.missing(videoID)
            }
            if let projectID = value.projectID,
               try String.fetchOne(db, sql: "SELECT id FROM feedback_projects WHERE id=?", arguments: [projectID]) == nil {
                throw TaskContextError.missing(projectID)
            }
            try db.execute(sql: "INSERT INTO feedback_batches(id,updated_at,document) VALUES(?,?,?)",
                           arguments: [value.id, value.updatedAt.timeIntervalSince1970, try JSONEncoder().encode(value)])
        }
    }
    public func listFeedback(videoID: String) throws -> [FeedbackBatch] {
        try pool.read { db in
            try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches ORDER BY updated_at DESC")
                .map { try JSONDecoder().decode(FeedbackBatch.self, from: $0) }
                .filter { $0.videoID == videoID }
        }
    }
    public func listFeedback(projectID: String) throws -> [FeedbackBatch] {
        try pool.read { db in
            try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches ORDER BY updated_at DESC")
                .map { try JSONDecoder().decode(FeedbackBatch.self, from: $0) }
                .filter { $0.projectID == projectID }
        }
    }
    public func listUnassignedFeedback() throws -> [FeedbackBatch] {
        try pool.read { db in
            try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches ORDER BY updated_at DESC")
                .map { try JSONDecoder().decode(FeedbackBatch.self, from: $0) }
                .filter { $0.videoID == nil && $0.projectID == nil }
        }
    }
    public func feedbackSnapshot(id: String) throws -> FeedbackSnapshot {
        try pool.read { db in
            FeedbackSnapshot(batch: try Self.feedbackBatch(id, in: db), tasks: try Self.feedbackTasks(id, in: db), proposals: try Self.feedbackProposals(id, in: db))
        }
    }
    @discardableResult public func updateFeedback(_ input: FeedbackBatch, expectedRevision: Int) throws -> FeedbackBatch {
        try pool.write { db in
            var draft = input
            var current = try Self.feedbackBatch(draft.id, in: db)
            guard current.revision == expectedRevision else { throw TaskContextError.conflict }
            if draft.projectID == nil && draft.project == current.project { draft.projectID = current.projectID }
            guard draft.projectID == current.projectID else { throw TaskContextError.invalid("Use Move source group to change the project.") }
            guard current.videoID == draft.videoID else { throw TaskContextError.conflict }
            try Self.validateFeedback(draft)
            try Self.validateProjectLinks(draft, previous: current, db: db)
            try Self.preserveFeedbackSource(current, db: db)
            try Self.reconcileFeedbackExclusions(draft, db: db)
            if let projectID = draft.projectID,
               try String.fetchOne(db, sql: "SELECT id FROM feedback_projects WHERE id=?", arguments: [projectID]) == nil {
                throw TaskContextError.missing(projectID)
            }
            current.title = draft.title; current.project = draft.project; current.projectID = draft.projectID; current.rawText = draft.rawText
            current.comments = draft.comments; current.sources = draft.sources; current.batchWideSourceIDs = draft.batchWideSourceIDs
            current.preparationSuggestions = draft.preparationSuggestions
            current.revision += 1; current.updatedAt = .now
            try db.execute(sql: "UPDATE feedback_batches SET updated_at=?,document=? WHERE id=?",
                           arguments: [current.updatedAt.timeIntervalSince1970, try JSONEncoder().encode(current), current.id])
            for var task in try Self.feedbackTasks(current.id, in: db) {
                task.revision += 1; task.approvedRevision = nil
                try Self.writeFeedbackTask(task, in: db)
            }
            try db.execute(sql: "DELETE FROM feedback_proposals WHERE batch_id=?", arguments: [current.id])
            return current
        }
    }
    @discardableResult public func attachFeedback(_ batchID: String, toVideoID videoID: String, expectedRevision: Int) throws -> FeedbackBatch {
        try pool.write { db in
            var batch = try Self.feedbackBatch(batchID, in: db)
            guard batch.videoID == nil, batch.revision == expectedRevision else { throw TaskContextError.conflict }
            guard try Self.fetchVideo(id: videoID, from: db) != nil else { throw TaskContextError.missing(videoID) }
            let previous = batch
            try Self.preserveFeedbackSource(previous, db: db)
            batch.videoID = videoID
            try Self.validateProjectLinks(batch, previous: previous, db: db)
            batch.revision += 1; batch.updatedAt = .now
            try db.execute(sql: "UPDATE feedback_batches SET updated_at=?,document=? WHERE id=?",
                           arguments: [batch.updatedAt.timeIntervalSince1970, try JSONEncoder().encode(batch), batch.id])
            for var task in try Self.feedbackTasks(batch.id, in: db) {
                task.revision += 1; task.approvedRevision = nil
                try Self.writeFeedbackTask(task, in: db)
            }
            try db.execute(sql: "DELETE FROM feedback_proposals WHERE batch_id=?", arguments: [batch.id])
            return batch
        }
    }
    public func saveFeedbackTask(_ draft: FeedbackTask, expectedRevision: Int?, expectedBatchRevision: Int) throws -> FeedbackTask {
        try pool.write { db in
            let batch = try Self.feedbackBatch(draft.batchID, in: db)
            guard batch.revision == expectedBatchRevision else { throw TaskContextError.conflict }
            try Self.validateFeedbackTask(draft.content, batch: batch)
            let existing = try Self.feedbackTasks(batch.id, in: db).first { $0.id == draft.id }
            guard existing?.revision == expectedRevision else { throw TaskContextError.conflict }
            if existing == nil, try Self.isTaskDeleted(draft.id, db: db) { throw TaskContextError.conflict }
            var value = existing ?? draft
            if existing != nil { value.revision += 1 }
            value.content = Self.invalidatingAnalysisReview(in: draft.content, comparedWith: existing?.content); value.archived = draft.archived
            value.approvedRevision = nil; value.sourceRevision = batch.revision
            value.analysisIsStale = nil
            if !value.content.evidenceReferences.isEmpty {
                guard let projectID = batch.projectID else { throw TaskContextError.invalid("Task evidence references require a project.") }
                try Self.validateEvidence(value.content.evidenceReferences, projectID: projectID, database: db)
            }
            var prospective = try batch.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                Self.feedbackTasks(batch.id, in: db).filter { !$0.archived }.map { ($0.id, $0.content) }
            prospective.removeAll { $0.id == value.id }
            if !value.archived { prospective.append((value.id, value.content)) }
            try Self.validateDependencyGraph(prospective)
            try Self.writeFeedbackTask(value, in: db)
            return value
        }
    }
    public func setFeedbackTasksArchived(batchID: String, expectedBatchRevision: Int,
                                         expectedTaskRevisions: [String: Int], archived: Bool) throws {
        try pool.write { db in
            let batch = try Self.feedbackBatch(batchID, in: db)
            guard batch.revision == expectedBatchRevision, !expectedTaskRevisions.isEmpty else {
                throw TaskContextError.conflict
            }
            let tasks = try Self.feedbackTasks(batchID, in: db)
            let selected = tasks.filter { expectedTaskRevisions[$0.id] != nil }
            guard selected.count == expectedTaskRevisions.count,
                  selected.allSatisfy({ expectedTaskRevisions[$0.id] == $0.revision }) else {
                throw TaskContextError.conflict
            }
            var prospective = try batch.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                tasks.filter { !$0.archived }.map { ($0.id, $0.content) }
            prospective.removeAll { expectedTaskRevisions[$0.id] != nil }
            if !archived { prospective += selected.map { ($0.id, $0.content) } }
            try Self.validateDependencyGraph(prospective)
            for var task in selected {
                task.archived = archived; task.revision += 1; task.approvedRevision = nil
                try Self.writeFeedbackTask(task, in: db)
                if archived {
                    try db.execute(sql: "DELETE FROM feedback_proposals WHERE json_extract(document, '$.taskID')=?", arguments: [task.id])
                }
            }
        }
    }
    public func prepareFeedbackTaskConsolidation(batchID: String, taskID: String, expectedBatchRevision: Int,
                                                 expectedTaskRevision: Int, replacement: TaskContent) throws -> FeedbackTaskProposal {
        try pool.write { db in
            let batch = try Self.feedbackBatch(batchID, in: db)
            guard batch.revision == expectedBatchRevision,
                  let task = try Self.feedbackTasks(batchID, in: db).first(where: { $0.id == taskID }),
                  task.revision == expectedTaskRevision, !task.archived else { throw TaskContextError.conflict }
            try Self.validateFeedbackTask(replacement, batch: batch)
            guard replacement.allSourceIDs == task.content.allSourceIDs else {
                throw TaskContextError.invalid("Task consolidation must preserve every evidence reference.")
            }
            let proposal = FeedbackTaskProposal(batchID: batchID, taskID: taskID,
                expectedRevision: expectedTaskRevision, sourceRevision: expectedBatchRevision, content: replacement,
                preserveGeneratedOriginal: true)
            try db.execute(sql: "DELETE FROM feedback_proposals WHERE json_extract(document, '$.taskID')=?", arguments: [taskID])
            try db.execute(sql: "INSERT INTO feedback_proposals(id,batch_id,document) VALUES(?,?,?)",
                           arguments: [proposal.id, batchID, try JSONEncoder().encode(proposal)])
            return proposal
        }
    }
    public func approveFeedbackTasks(batchID: String, expectedBatchRevision: Int, expectedTaskRevisions: [String: Int]) throws {
        try pool.write { db in
            let batch = try Self.feedbackBatch(batchID, in: db)
            try Self.validateDocumentationRequest(batch, db: db)
            guard batch.revision == expectedBatchRevision, !expectedTaskRevisions.isEmpty else { throw TaskContextError.conflict }
            let tasks = try Self.feedbackTasks(batchID, in: db)
            for (id, revision) in expectedTaskRevisions {
                guard var task = tasks.first(where: { $0.id == id }), task.revision == revision,
                      !task.archived, task.sourceRevision == batch.revision, task.content.blockers == 0,
                      try !Self.taskAnalysisIsStale(task.content, projectID: batch.projectID, db: db) else { throw TaskContextError.reviewRequired }
                try Self.validateFeedbackTask(task.content, batch: batch)
                try Self.validateTaskDecisions(task.content, projectID: batch.projectID, db: db)
                task.revision += 1; task.approvedRevision = task.revision
                try Self.writeFeedbackTask(task, in: db)
            }
        }
    }
    public func publishFeedbackGeneration(batchID: String, expectedRevision: Int, expectedTasks: [String: Int], generated: [FeedbackTask],
                                          expectedGenerationEpoch: Int? = nil,
                                          preserveOnCancellation: Bool = false) throws {
        if !preserveOnCancellation { try Task.checkCancellation() }
        try pool.write { db in
            try Self.assertTaskGenerationEpoch(source: .feedback(batchID), expected: expectedGenerationEpoch, db: db)
            let batch = try Self.feedbackBatch(batchID, in: db)
            guard batch.revision == expectedRevision else { throw TaskContextError.conflict }
            let existing = try Self.feedbackTasks(batchID, in: db)
            guard Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.revision) }) == expectedTasks else { throw TaskContextError.conflict }
            guard generated.allSatisfy({ $0.batchID == batchID && $0.sourceRevision == batch.revision }),
                  Set(generated.map(\.id)).count == generated.count else { throw TaskContextError.conflict }
            for task in generated {
                try Self.validateFeedbackTask(task.content, batch: batch)
                if try Self.taskAnalysisSourcesAreStale(task.content, projectID: batch.projectID, db: db) { throw TaskContextError.conflict }
            }
            var activeGenerated: [FeedbackTask] = []
            for task in generated {
                guard try !Self.generationExclusionExists(source: .feedback(batchID),
                                                          identityKey: Self.feedbackGenerationIdentity(issueID: task.issueID,
                                                                                                       content: task.content), db: db) else { continue }
                activeGenerated.append(task)
            }
            let issueIDs = activeGenerated.compactMap(\.issueID)
            guard Set(issueIDs).count == issueIDs.count else { throw TaskContextError.conflict }
            let dependencyTasks = try batch.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                existing.filter { !$0.archived }.map { ($0.id, $0.content) }
            var prospective = Dictionary(uniqueKeysWithValues: dependencyTasks)
            for task in activeGenerated { prospective[task.id] = task.content }
            try Self.validateDependencyGraph(prospective.map { ($0.key, $0.value) })
            var additions: [FeedbackTask] = [], proposals: [FeedbackTaskProposal] = []
            for task in activeGenerated {
                if existing.contains(where: { $0.archived && ($0.id == task.id || (task.issueID != nil && $0.issueID == task.issueID)) }) {
                    continue
                }
                let sourceMatches = existing.filter { !$0.archived && $0.generatedOriginal?.allSourceIDs == task.content.allSourceIDs }
                if let match = existing.first(where: { !$0.archived && $0.id == task.id }) ??
                    existing.first(where: { !$0.archived && task.issueID != nil && $0.issueID == task.issueID }) ??
                    (sourceMatches.count == 1 ? sourceMatches.first : nil) {
                    if !Self.sameGeneratedContent(match.generatedOriginal, task.content) {
                        proposals.append(.init(batchID: batchID, taskID: match.id, expectedRevision: match.revision,
                                               sourceRevision: expectedRevision, content: task.content))
                    } else if match.sourceRevision != batch.revision {
                        var refreshed = match
                        refreshed.issueID = task.issueID ?? refreshed.issueID
                        refreshed.sourceRevision = batch.revision; refreshed.revision += 1; refreshed.approvedRevision = nil
                        refreshed.analysisIsStale = nil
                        try Self.writeFeedbackTask(refreshed, in: db)
                    }
                } else {
                    // Feedback task IDs are deterministic for an issue in
                    // older libraries. A reset exclusion deliberately starts
                    // a fresh reviewed task, so never reuse a tombstoned ID.
                    if try Self.isTaskDeleted(task.id, db: db) {
                        var replacement = FeedbackTask(batchID: task.batchID, issueID: task.issueID,
                                                        sourceRevision: task.sourceRevision, content: task.content,
                                                        provenance: task.provenance)
                        replacement.generationRunID = task.generationRunID
                        replacement.generatedOriginal = task.generatedOriginal
                        additions.append(replacement)
                    } else {
                        additions.append(task)
                    }
                }
            }
            if !preserveOnCancellation { try Task.checkCancellation() }
            try db.execute(sql: "DELETE FROM feedback_proposals WHERE batch_id=?", arguments: [batchID])
            for item in additions { try Self.writeFeedbackTask(item, in: db) }
            for item in proposals {
                try db.execute(sql: "INSERT INTO feedback_proposals(id,batch_id,document) VALUES(?,?,?)",
                               arguments: [item.id, batchID, try JSONEncoder().encode(item)])
            }
        }
    }
    public func resolveFeedbackProposal(batchID: String, proposalID: String, apply: Bool) throws {
        try pool.write { db in
            guard let proposal = try Self.feedbackProposals(batchID, in: db).first(where: { $0.id == proposalID }) else { throw TaskContextError.missing(proposalID) }
            if !apply {
                try db.execute(sql: "DELETE FROM feedback_proposals WHERE id=?", arguments: [proposalID])
                return
            }
            guard try !Self.isProjectProposalOutdated(proposalID, db: db) else { throw TaskContextError.conflict }
            let batch = try Self.feedbackBatch(batchID, in: db)
            guard batch.revision == proposal.sourceRevision,
                  var task = try Self.feedbackTasks(batchID, in: db).first(where: { $0.id == proposal.taskID }),
                  task.revision == proposal.expectedRevision,
                  try !Self.isTaskDeleted(proposal.taskID, db: db) else { throw TaskContextError.conflict }
            if apply {
                try Self.validateFeedbackTask(proposal.content, batch: batch)
                var merged = proposal.content
                merged.annotations = task.content.annotations
                for old in task.content.questions where !old.answer.isEmpty || !old.nonBlockingReason.isEmpty {
                    if let index = merged.questions.firstIndex(where: { $0.question == old.question }) {
                        merged.questions[index] = old
                    } else {
                        merged.questions.append(old)
                    }
                }
                merged = Self.invalidatingAnalysisReview(in: merged, comparedWith: proposal.content)
                try Self.validateFeedbackTask(merged, batch: batch)
                task.content = merged
                if proposal.preserveGeneratedOriginal != true { task.generatedOriginal = proposal.content }
                task.sourceRevision = batch.revision; task.revision += 1; task.approvedRevision = nil
                task.analysisIsStale = nil
                var prospective = try batch.projectID.map { try Self.projectDependencyTasks(projectID: $0, db: db) } ??
                    Self.feedbackTasks(batchID, in: db).filter { !$0.archived }.map { ($0.id, $0.content) }
                prospective.removeAll { $0.id == task.id }
                prospective.append((task.id, task.content))
                try Self.validateDependencyGraph(prospective)
                try Self.writeFeedbackTask(task, in: db)
            }
            try db.execute(sql: "DELETE FROM feedback_proposals WHERE id=?", arguments: [proposalID])
        }
    }
}
