import Foundation
import GRDB

extension VideoContextStore {
    static func backupBeforeProjectMigration(pool: DatabasePool, databaseURL: URL) throws {
        let needed = try pool.read { db in
            guard try db.tableExists("videos") else { return false }
            guard try db.tableExists("grdb_migrations") else { return true }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier='projectWorkspaceOwnership')") != true
        }
        guard needed else { return }
        // SQLite's backup API includes committed WAL contents. A failed backup prevents migration.
        let backupURL = databaseURL.appendingPathExtension("before-projects-\(UUID().uuidString).sqlite")
        let destination = try DatabaseQueue(path: backupURL.path)
        try pool.backup(to: destination)
    }

    static func createProjectWorkspaceSchema(in db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE videos ADD COLUMN project_id TEXT REFERENCES feedback_projects(id);
            CREATE INDEX videos_project ON videos(project_id);
            CREATE TABLE project_outdated_proposals(id TEXT PRIMARY KEY);
            """)
        let videos = try allProjectVideos(db)
        let batches = try allProjectBatches(db)
        var visited = Set<ProjectSourceReference>()
        for source in videos.map({ ProjectSourceReference.recording($0.id) }) + batches.map({ .feedback($0.id) }) {
            guard !visited.contains(source) else { continue }
            let group = sourceGroup(source, videos: videos, batches: batches)
            visited.formUnion(group)
            let projects = groupProjectIDs(group, videos: videos, batches: batches)
            guard projects.count == 1, let projectID = projects.first,
                  let name = try String.fetchOne(db, sql: "SELECT name FROM feedback_projects WHERE id=?", arguments: [projectID]) else { continue }
            for video in videos where group.contains(.recording(video.id)) && video.projectID == nil {
                try db.execute(sql: "UPDATE videos SET project_id=? WHERE id=?", arguments: [projectID, video.id])
            }
            for var batch in batches where group.contains(.feedback(batch.id)) && batch.projectID == nil {
                batch.projectID = projectID; batch.project = name
                try writeProjectBatch(batch, db: db)
            }
        }
    }

    static func allProjectVideos(_ db: Database) throws -> [VideoRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM videos ORDER BY created_at DESC,id").map(video(from:))
    }
    static func allProjectBatches(_ db: Database) throws -> [FeedbackBatch] {
        guard try db.tableExists("feedback_batches") else { return [] }
        return try Data.fetchAll(db, sql: "SELECT document FROM feedback_batches ORDER BY updated_at DESC,id").map { try JSONDecoder().decode(FeedbackBatch.self, from: $0) }
    }
    static func linkedRecordings(_ batch: FeedbackBatch) -> Set<String> {
        Set([batch.videoID].compactMap { $0 } + batch.sources.filter { $0.kind == .recording }.compactMap(\.recordingID))
    }
    static func sourceGroup(_ source: ProjectSourceReference, videos: [VideoRecord], batches: [FeedbackBatch]) -> Set<ProjectSourceReference> {
        var group: Set<ProjectSourceReference> = [source]
        var changed = true
        let videoIDs = Set(videos.map(\.id))
        while changed {
            changed = false
            for batch in batches {
                let links = Set(linkedRecordings(batch).intersection(videoIDs).map(ProjectSourceReference.recording))
                if group.contains(.feedback(batch.id)) || !group.isDisjoint(with: links) {
                    let previous = group.count
                    group.insert(.feedback(batch.id)); group.formUnion(links)
                    if group.count != previous { changed = true }
                }
            }
        }
        return group
    }
    static func groupProjectIDs(_ group: Set<ProjectSourceReference>, videos: [VideoRecord], batches: [FeedbackBatch]) -> Set<String> {
        Set(videos.filter { group.contains(.recording($0.id)) }.compactMap(\.projectID) + batches.filter { group.contains(.feedback($0.id)) }.compactMap(\.projectID))
    }
    static func writeProjectBatch(_ batch: FeedbackBatch, db: Database) throws {
        if let data = try Data.fetchOne(db, sql: "SELECT document FROM feedback_batches WHERE id=?", arguments: [batch.id]) {
            try preserveFeedbackSource(JSONDecoder().decode(FeedbackBatch.self, from: data), db: db)
        }
        try db.execute(sql: "UPDATE feedback_batches SET document=?,updated_at=? WHERE id=?", arguments: [try JSONEncoder().encode(batch), batch.updatedAt.timeIntervalSince1970, batch.id])
    }
    static func isProjectProposalOutdated(_ id: String, db: Database) throws -> Bool {
        guard try db.tableExists("project_outdated_proposals") else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project_outdated_proposals WHERE id=?)", arguments: [id]) ?? false
    }
    static func projectWorkspace(projectID: String?, db: Database) throws -> ProjectWorkspaceSnapshot {
        let project: FeedbackProject?
        if let projectID {
            guard let row = try Row.fetchOne(db, sql: "SELECT id,name FROM feedback_projects WHERE id=?", arguments: [projectID]) else { throw TaskContextError.missing(projectID) }
            project = .init(id: row["id"], name: row["name"])
        } else { project = nil }
        let allVideos = try allProjectVideos(db), allBatches = try allProjectBatches(db)
        let videos = allVideos.filter { $0.projectID == projectID }
        let batches = allBatches.filter { $0.projectID == projectID }
        var tasks: [ProjectTaskItem] = [], proposals: [ProjectProposalItem] = []
        for video in videos {
            let sourceTasks = try fetchTasks(videoID: video.id, db: db)
            tasks += sourceTasks.map { ProjectTaskItem(task: $0, video: video) }
            let items = try Data.fetchAll(db, sql: "SELECT document FROM task_proposals WHERE video_id=? ORDER BY rowid", arguments: [video.id]).map { try JSONDecoder().decode(TaskProposal.self, from: $0) }
            for p in items {
                let outdated = try isProjectProposalOutdated(p.id, db: db) || p.sourceRevision != video.revisions || (p.taskID != nil && sourceTasks.first { $0.id == p.taskID }?.revision != p.expectedTaskRevision)
                proposals.append(.init(id: p.id, source: .recording(video.id), sourceTitle: video.title, content: p.content, outdated: outdated, recording: p, feedback: nil))
            }
        }
        for batch in batches {
            let sourceTasks = try feedbackTasks(batch.id, in: db)
            tasks += sourceTasks.map { ProjectTaskItem(task: $0, batch: batch) }
            for p in try feedbackProposals(batch.id, in: db) {
                let outdated = try isProjectProposalOutdated(p.id, db: db) || p.sourceRevision != batch.revision || sourceTasks.first { $0.id == p.taskID }?.revision != p.expectedRevision
                proposals.append(.init(id: p.id, source: .feedback(batch.id), sourceTitle: batch.title, content: p.content, outdated: outdated, recording: nil, feedback: p))
            }
        }
        var conflicts: [ProjectSourceReference] = [], seen = Set<ProjectSourceReference>()
        for source in allVideos.map({ ProjectSourceReference.recording($0.id) }) + allBatches.map({ .feedback($0.id) }) where !seen.contains(source) {
            let group = sourceGroup(source, videos: allVideos, batches: allBatches)
            seen.formUnion(group)
            let owners = groupProjectIDs(group, videos: allVideos, batches: allBatches)
            if owners.count > 1 && (projectID == nil || owners.contains(projectID!)) { conflicts.append(source) }
        }
        return .init(project: project, recordings: videos, batches: batches, tasks: tasks, proposals: proposals, conflicts: conflicts)
    }
    public func projectWorkspace(projectID: String?) throws -> ProjectWorkspaceSnapshot {
        try pool.read { try Self.projectWorkspace(projectID: projectID, db: $0) }
    }

    public func createProjectRequest(projectID: String, title: String, text: String) throws -> FeedbackBatch {
        try pool.write { db in
            guard let name = try String.fetchOne(db, sql: "SELECT name FROM feedback_projects WHERE id=?", arguments: [projectID]) else { throw TaskContextError.missing(projectID) }
            var batch = FeedbackBatch(projectID: projectID, title: title, project: name, rawText: text)
            for i in batch.comments.indices { batch.comments[i].kind = .request }
            try Self.validateFeedback(batch)
            try db.execute(sql: "INSERT INTO feedback_batches(id,updated_at,document) VALUES(?,?,?)", arguments: [batch.id, batch.updatedAt.timeIntervalSince1970, try JSONEncoder().encode(batch)])
            return batch
        }
    }

    static func validateProjectLinks(_ batch: FeedbackBatch, previous: FeedbackBatch? = nil, db: Database) throws {
        let projectID = batch.projectID
        let changed = previous?.projectID != projectID
        let links = changed ? linkedRecordings(batch) : linkedRecordings(batch).subtracting(previous.map(linkedRecordings) ?? [])
        for id in links {
            guard let video = try fetchVideo(id: id, from: db) else { throw TaskContextError.missing(id) }
            guard video.projectID == projectID else { throw TaskContextError.invalid("Choose a recording in this project, or move its source group first.") }
        }
        for source in batch.sources where source.kind == .document && previous?.sources.first(where: { $0.id == source.id }) != source {
            guard let id = source.documentID, let projectID,
                  try String.fetchOne(db, sql: "SELECT project_id FROM project_documentation WHERE id=?", arguments: [id]) == projectID else {
                throw TaskContextError.invalid("Choose documentation in this project.")
            }
        }
    }

    static func projectMove(source: ProjectSourceReference, destinationID: String, db: Database) throws -> ProjectMovePreview {
        guard let row = try Row.fetchOne(db, sql: "SELECT id,name FROM feedback_projects WHERE id=?", arguments: [destinationID]) else { throw TaskContextError.missing(destinationID) }
        let allVideos = try allProjectVideos(db), allBatches = try allProjectBatches(db)
        switch source {
        case .recording(let id): guard allVideos.contains(where: { $0.id == id }) else { throw TaskContextError.missing(id) }
        case .feedback(let id): guard allBatches.contains(where: { $0.id == id }) else { throw TaskContextError.missing(id) }
        }
        let group = sourceGroup(source, videos: allVideos, batches: allBatches)
        let videos = allVideos.filter { group.contains(.recording($0.id)) }, batches = allBatches.filter { group.contains(.feedback($0.id)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var parts = [try encoder.encode(videos), try encoder.encode(batches)]
        var tasks: [ProjectTaskItem] = []
        for video in videos {
            let values = try fetchTasks(videoID: video.id, db: db)
            tasks += values.map { .init(task: $0, video: video) }; parts.append(try encoder.encode(values))
            parts += try Data.fetchAll(db, sql: "SELECT document FROM task_proposals WHERE video_id=? ORDER BY id", arguments: [video.id])
        }
        for batch in batches {
            let values = try feedbackTasks(batch.id, in: db)
            tasks += values.map { .init(task: $0, batch: batch) }; parts.append(try encoder.encode(values))
            parts.append(try encoder.encode(feedbackProposals(batch.id, in: db)))
        }
        var affected: [ProjectDocumentation] = []
        var affectedDecisions: [ProjectDecision] = []
        if try db.tableExists("project_decisions") {
            for decisionRow in try Row.fetchAll(db, sql: "SELECT * FROM project_decisions ORDER BY id") {
                let decision = try Self.decision(from: decisionRow)
                if decision.evidence.contains(where: { reference in
                    switch reference { case .recording(let id, _, _, _): group.contains(.recording(id)); case .feedback(let id, _, _, _): group.contains(.feedback(id)); case .document, .reviewedDocumentation: false }
                }) { affectedDecisions.append(decision) }
            }
        }
        let linkedDocumentIDs = Set(batches.flatMap { $0.sources.compactMap(\.documentID) })
        if try db.tableExists("project_documentation") {
            for documentRow in try Row.fetchAll(db, sql: "SELECT * FROM project_documentation ORDER BY id") {
                let document = try documentation(from: documentRow)
                if linkedDocumentIDs.contains(document.id) || document.sections.flatMap(\.decisionIDs).contains(where: { id in affectedDecisions.contains { $0.id == id } }) || document.sections.flatMap(\.evidence).contains(where: { reference in
                    switch reference { case .recording(let id, _, _, _): group.contains(.recording(id)); case .feedback(let id, _, _, _): group.contains(.feedback(id)); case .document, .reviewedDocumentation: false }
                }) { affected.append(document) }
            }
        }
        parts.append(try encoder.encode(affected))
        parts.append(try encoder.encode(affectedDecisions))
        let blocked = affected.contains { linkedDocumentIDs.contains($0.id) && $0.projectID != destinationID }
        return .init(source: source, destination: .init(id: row["id"], name: row["name"]), recordings: videos, batches: batches, tasks: tasks, signature: parts.map { $0.base64EncodedString() }.joined(separator: "."), affectedDocumentation: affected, affectedDecisions: affectedDecisions, blockedReason: blocked ? "This group contains a request linked to documentation in another project. Keep it with that product reference, or create a new request in the destination project." : nil)
    }
    public func previewProjectMove(source: ProjectSourceReference, destinationProjectID: String) throws -> ProjectMovePreview {
        try pool.read { try Self.projectMove(source: source, destinationID: destinationProjectID, db: $0) }
    }
    public func moveProjectSources(_ preview: ProjectMovePreview) throws {
        try pool.write { db in
            let current = try Self.projectMove(source: preview.source, destinationID: preview.destination.id, db: db)
            guard current.signature == preview.signature else { throw TaskContextError.conflict }
            if let reason = current.blockedReason { throw TaskContextError.invalid(reason) }
            let active: Set<ProcessingStatus> = [.inspecting, .extractingAudio, .transcribing, .capturingFrames, .recognizingText, .analyzing]
            guard !current.recordings.contains(where: { active.contains($0.status) }) else { throw TaskContextError.invalid("Wait for source processing to finish before moving this group.") }
            for video in current.recordings where video.projectID != current.destination.id {
                try db.execute(sql: "UPDATE videos SET project_id=? WHERE id=?", arguments: [current.destination.id, video.id])
                try Self.invalidateTasks(videoID: video.id, in: db)
                try db.execute(sql: "INSERT OR IGNORE INTO project_outdated_proposals SELECT id FROM task_proposals WHERE video_id=?", arguments: [video.id])
            }
            for var batch in current.batches where batch.projectID != current.destination.id {
                let oldRevision = batch.revision
                batch.projectID = current.destination.id; batch.project = current.destination.name
                batch.revision += 1; batch.updatedAt = .now
                try Self.writeProjectBatch(batch, db: db)
                for var task in try Self.feedbackTasks(batch.id, in: db) {
                    task.revision += 1; task.approvedRevision = nil
                    if task.sourceRevision == oldRevision { task.sourceRevision = batch.revision }
                    try Self.writeFeedbackTask(task, in: db)
                }
                try db.execute(sql: "INSERT OR IGNORE INTO project_outdated_proposals SELECT id FROM feedback_proposals WHERE batch_id=?", arguments: [batch.id])
            }
            let changedOwnership = current.recordings.contains { $0.projectID != current.destination.id } || current.batches.contains { $0.projectID != current.destination.id }
            for var document in current.affectedDocumentation where changedOwnership {
                document.reviewedRevision = nil
                try db.execute(sql: "UPDATE project_documentation SET reviewed_revision=NULL,document=? WHERE id=?", arguments: [try JSONEncoder().encode(document), document.id])
            }
        }
    }
}
