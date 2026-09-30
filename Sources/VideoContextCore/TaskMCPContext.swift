import Foundation

public struct TaskContextBlock: Codable, Equatable, Sendable {
    public let kind: String
    public let text: String
    public let origin: TaskOrigin?
    public let sourceID: String?
    public let timestamp: Double?
    public init(kind: String, text: String, origin: TaskOrigin? = nil, sourceID: String? = nil, timestamp: Double? = nil) {
        self.kind = kind; self.text = text; self.origin = origin; self.sourceID = sourceID; self.timestamp = timestamp
    }
}
public struct MCPTaskPage: Codable, Sendable {
    public let videoID: String
    public let taskID: String
    public let revision: Int
    public let sourceRevision: ArtifactRevision
    public let processingStatus: ProcessingStatus
    public let state: String
    public let isStale: Bool
    public let canImplement: Bool
    public let blockerCount: Int
    public let blocks: [TaskContextBlock]
    public let nextCursor: String?
}
public struct MCPTaskSummary: Codable, Sendable {
    public let id: String
    public let title: String
    public let revision: Int
    public let state: String
    public let blockers: Int
}
public struct MCPTaskList: Codable, Sendable {
    public let videoID: String
    public let sourceRevision: ArtifactRevision
    public let processingStatus: ProcessingStatus
    public let tasks: [MCPTaskSummary]
    public let nextCursor: String?
}
private struct TaskCursor: Codable {
    let signature: String
    let offset: Int
    var encoded: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }
    static func offset(_ value: String?, signature: String) throws -> Int {
        guard let value else { return 0 }
        guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.signature == signature, cursor.offset >= 0 else { throw TaskContextError.conflict }
        return cursor.offset
    }
}

public struct TaskMCPService: Sendable {
    private let store: VideoContextStore
    public init(store: VideoContextStore) { self.store = store }
    public func list(videoID: String, cursor: String? = nil) async throws -> MCPTaskList {
        let snapshot = try await store.taskSnapshot(videoID: videoID)
        let signature = "list:\(videoID):\(snapshot.signature)"
        let offset = try TaskCursor.offset(cursor, signature: signature)
        guard offset <= snapshot.tasks.count else { throw TaskContextError.conflict }
        let end = min(offset + 15, snapshot.tasks.count)
        return MCPTaskList(videoID: videoID, sourceRevision: snapshot.video.revisions, processingStatus: snapshot.video.status,
            tasks: snapshot.tasks[offset..<end].map { MCPTaskSummary(id: $0.id, title: $0.content.title, revision: $0.revision, state: $0.state(snapshot.video), blockers: $0.content.blockers) },
            nextCursor: end < snapshot.tasks.count ? TaskCursor(signature: signature, offset: end).encoded : nil)
    }
    public func task(videoID: String, taskID: String, expectedRevision: Int? = nil, cursor: String? = nil) async throws -> MCPTaskPage {
        let snapshot = try await store.taskSnapshot(videoID: videoID)
        let task = try Self.exactTask(snapshot, taskID: taskID, expectedRevision: expectedRevision)
        var blocks = [TaskContextBlock(kind: "title", text: task.content.title), .init(kind: "requested_behavior", text: task.content.behavior)]
        blocks += try TaskAnalysisMCPBlocks.make(content: task.content, projectID: snapshot.video.projectID)
        for (kind, statements) in [("requirement", task.content.requirements), ("acceptance_check", task.content.checks)] {
            for statement in statements {
                blocks.append(.init(kind: kind, text: "\(statement.id): \(statement.text)", origin: statement.origin))
                blocks += statement.sourceIDs.map { .init(kind: "statement_evidence", text: statement.id, sourceID: $0) }
            }
        }
        for question in task.content.questions {
            blocks.append(.init(kind: "question", text: "\(question.id): \(question.question)\nBlocking: \(question.isBlocking); unresolved: \(question.unresolved)"))
            blocks += question.sourceIDs.map { .init(kind: "question_evidence", text: question.id, sourceID: $0) }
            blocks.append(.init(kind: "answer", text: "\(question.id): \(question.answer)\nNon-blocking reason: \(question.nonBlockingReason)\nDisagreement with recording: \(question.disagreement)", origin: .user))
        }
        for annotation in task.content.annotations {
            blocks.append(.init(kind: "annotation", text: "\(annotation.kind.rawValue): \(annotation.text) (x=\(annotation.x), y=\(annotation.y), width=\(annotation.width), height=\(annotation.height))", origin: .user, sourceID: annotation.evidenceID))
        }
        for id in task.content.allSourceIDs.sorted() {
            if let segment = snapshot.transcript.first(where: { $0.id == id }) {
                blocks.append(.init(kind: "transcript_reference", text: "\(segment.start)–\(segment.end) seconds", sourceID: id, timestamp: segment.start))
            } else if let evidence = snapshot.evidence.first(where: { $0.id == id }) {
                blocks.append(.init(kind: "screenshot_reference", text: "Retrieve with get_task_frame", sourceID: id, timestamp: evidence.timestamp))
            } else {
                blocks.append(.init(kind: "missing_evidence", text: "Referenced evidence is unavailable. Request reconciliation.", sourceID: id))
            }
        }
        let pieces = blocks.flatMap { block in LocalAnalysisBatchPlanner.pieces(block.text, budget: 1800).map { TaskContextBlock(kind: block.kind, text: $0, origin: block.origin, sourceID: block.sourceID, timestamp: block.timestamp) } }
        let signature = "task:\(videoID):\(taskID):\(task.revision):\(snapshot.video.revisions)"
        let offset = try TaskCursor.offset(cursor, signature: signature)
        guard offset <= pieces.count else { throw TaskContextError.conflict }
        var page: [TaskContextBlock] = [], size = 0, end = offset
        while end < pieces.count {
            let next = pieces[end].text.utf8.count + 250
            if size + next > 6000 && !page.isEmpty { break }
            page.append(pieces[end]); size += next; end += 1
        }
        return MCPTaskPage(videoID: videoID, taskID: taskID, revision: task.revision, sourceRevision: task.sourceRevision, processingStatus: snapshot.video.status,
            state: task.state(snapshot.video), isStale: task.isStale(snapshot.video), canImplement: task.canImplement(snapshot.video), blockerCount: task.content.blockers,
            blocks: page, nextCursor: end < pieces.count ? TaskCursor(signature: signature, offset: end).encoded : nil)
    }
    static func exactTask(_ snapshot: TaskLibrarySnapshot, taskID: String, expectedRevision: Int?) throws -> VideoTask {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID }) else { throw TaskContextError.missing(taskID) }
        if let expectedRevision, expectedRevision != task.revision { throw TaskContextError.conflict }
        return task
    }
    public func frame(videoID: String, taskID: String, evidenceID: String, expectedRevision: Int? = nil, crop: NormalizedCrop? = nil, paths: LibraryPaths) async throws -> TaskFrameResult {
        let snapshot = try await store.taskSnapshot(videoID: videoID)
        let task = try Self.exactTask(snapshot, taskID: taskID, expectedRevision: expectedRevision)
        guard task.content.allSourceIDs.contains(evidenceID), let evidence = snapshot.evidence.first(where: { $0.id == evidenceID }) else { throw TaskContextError.missing(evidenceID) }
        let annotations = task.content.annotations.filter { $0.evidenceID == evidenceID }
        let image = try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: evidence.imageRelativePath), annotations: annotations, crop: crop)
        return TaskFrameResult(image: image, metadata: .init(videoID: videoID, taskID: taskID, revision: task.revision, evidenceID: evidenceID, timestamp: evidence.timestamp, isStale: task.isStale(snapshot.video), annotations: annotations, crop: crop))
    }
}
public struct TaskFrameResult: Sendable { public let image: Data; public let metadata: TaskFrameMetadata }
public struct TaskFrameMetadata: Codable, Sendable {
    public let videoID: String
    public let taskID: String
    public let revision: Int
    public let evidenceID: String
    public let timestamp: Double
    public let isStale: Bool
    public let annotations: [TaskAnnotation]
    public let crop: NormalizedCrop?
}
