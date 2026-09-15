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
        return try Row.fetchAll(db, sql: "SELECT document FROM video_tasks WHERE video_id = ? ORDER BY position, id", arguments: [videoID]).map {
            try JSONDecoder().decode(VideoTask.self, from: $0["document"] as Data)
        }
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
            try Self.validateContent(draft.content, videoID: draft.videoID, db: db)
            var value = draft
            if let existing {
                value = existing; value.content = draft.content; value.order = draft.order; value.archived = draft.archived
                value.revision += 1; value.reviewedRevision = nil
            } else {
                value.revision = 1; value.reviewedRevision = nil; value.wasReviewed = false; value.sourceRevision = expectedSource
            }
            try Self.writeTask(value, db: db)
            return value
        }
    }

    public func reviewTask(videoID: String, taskID: String, expectedRevision: Int, expectedSource: ArtifactRevision) throws {
        try pool.write { db in
            guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == expectedSource,
                  var task = try Self.fetchTasks(videoID: videoID, db: db).first(where: { $0.id == taskID }), task.revision == expectedRevision else { throw TaskContextError.conflict }
            guard !task.archived, !task.isStale(video), video.status == .ready, task.content.blockers == 0,
                  !task.content.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !task.content.checks.isEmpty else { throw TaskContextError.reviewRequired }
            try Self.validateContent(task.content, videoID: videoID, db: db)
            task.revision += 1; task.reviewedRevision = task.revision; task.wasReviewed = true
            try Self.writeTask(task, db: db)
        }
    }

    public func publishTaskProposals(_ proposals: [TaskProposal], videoID: String, expectedSource: ArtifactRevision, expectedTasks: [String: Int]) throws {
        try Task.checkCancellation()
        try pool.write { db in
            try Task.checkCancellation()
            guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == expectedSource, video.status == .ready, !video.revisions.isBriefStale else { throw TaskContextError.conflict }
            let existing = try Self.fetchTasks(videoID: videoID, db: db)
            guard Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.revision) }) == expectedTasks else { throw TaskContextError.conflict }
            for proposal in proposals {
                guard proposal.videoID == videoID, proposal.sourceRevision == expectedSource else { throw TaskContextError.conflict }
                if let content = proposal.content { try Self.validateContent(content, videoID: videoID, db: db) }
                if proposal.kind != .addition {
                    guard existing.contains(where: { $0.id == proposal.taskID && $0.revision == proposal.expectedTaskRevision }) else { throw TaskContextError.conflict }
                }
            }
            try db.execute(sql: "DELETE FROM task_proposals WHERE video_id = ?", arguments: [videoID])
            for proposal in proposals {
                try db.execute(sql: "INSERT INTO task_proposals VALUES(?, ?, ?)", arguments: [proposal.id, videoID, try JSONEncoder().encode(proposal)])
            }
            try Task.checkCancellation()
        }
    }

    public func resolveTaskProposal(videoID: String, proposalID: String, apply: Bool, keepWording: Bool = false) throws {
        try pool.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT document FROM task_proposals WHERE id = ? AND video_id = ?", arguments: [proposalID, videoID]) else { throw TaskContextError.missing(proposalID) }
            let proposal = try JSONDecoder().decode(TaskProposal.self, from: data)
            if apply {
                guard let video = try Self.fetchVideo(id: videoID, from: db), video.revisions == proposal.sourceRevision, !video.revisions.isBriefStale else { throw TaskContextError.conflict }
                let tasks = try Self.fetchTasks(videoID: videoID, db: db)
                var value: VideoTask
                if proposal.kind == .addition {
                    guard let content = proposal.content else { throw TaskContextError.invalid("Proposal has no task content.") }
                    value = VideoTask(videoID: videoID, sourceRevision: proposal.sourceRevision, content: content, order: (tasks.map(\.order).max() ?? -1) + 1, provenance: proposal.provenance)
                } else {
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
                        } else {
                            current.content = content
                        }
                    }
                    current.provenance = proposal.provenance; value = current
                }
                try Self.validateContent(value.content, videoID: videoID, db: db)
                try Self.writeTask(value, db: db)
            }
            try db.execute(sql: "DELETE FROM task_proposals WHERE id = ? AND video_id = ?", arguments: [proposalID, videoID])
        }
    }

    public func taskCache(key: String) throws -> Data? {
        try pool.read { try Data.fetchOne($0, sql: "SELECT document FROM task_generation_cache WHERE cache_key = ?", arguments: [key]) }
    }
    public func saveTaskCache(key: String, data: Data) throws {
        try pool.write { try $0.execute(sql: "INSERT INTO task_generation_cache VALUES(?, ?) ON CONFLICT(cache_key) DO UPDATE SET document=excluded.document", arguments: [key, data]) }
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
