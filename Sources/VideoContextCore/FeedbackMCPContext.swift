import Foundation

public struct FeedbackContextBlock: Codable, Sendable {
    public let kind: String
    public let text: String
    public let sourceID: String?
    /// ID of the requirement, acceptance check, or question this block shows.
    public let itemID: String?
    public init(kind: String, text: String, sourceID: String? = nil, itemID: String? = nil) {
        self.kind = kind; self.text = text; self.sourceID = sourceID; self.itemID = itemID
    }
}
public struct FeedbackContextPage: Codable, Sendable {
    public let batchID: String
    public let projectID: String?
    public let videoID: String?
    public let batchRevision: Int
    public let taskID: String?
    public let taskRevision: Int?
    public let blocks: [FeedbackContextBlock]
    public let nextCursor: String?
}
public struct FeedbackTaskList: Codable, Sendable {
    public let batchID: String
    public let projectID: String?
    public let videoID: String?
    public let batchRevision: Int
    public let tasks: [FeedbackTaskSummary]
    public let nextCursor: String?
}
public struct FeedbackTaskSummary: Codable, Sendable {
    public let id: String
    public let title: String
    public let revision: Int
    public let approved: Bool
    public let blockers: Int
    public let origin: FeedbackIssueKind
}
public struct FeedbackEvidenceMetadata: Codable, Sendable {
    public let batchID: String
    public let projectID: String?
    public let videoID: String?
    public let batchRevision: Int
    public let taskID: String
    public let taskRevision: Int
    public let sourceID: String
    public let kind: FeedbackSourceKind
    public let url: String?
    public let filename: String?
    public let status: FeedbackSourceStatus
    public let presentationStatus: String
    public let ocrText: String
    public let text: String?
    public let recordingID: String?
    public let error: String?
    public let annotations: [TaskAnnotation]
    public let jam: FeedbackJamEvidenceMetadata?
}
public struct FeedbackEvidenceResult: Sendable {
    public let metadata: FeedbackEvidenceMetadata
    public let image: Data?
}
public struct FeedbackJamEvidenceMetadata: Codable, Sendable {
    public let state: JamEvidenceReadState
    public let recordingID: String
    public let importedAt: Date
    public let itemCount: Int
    public let tools: [String]
    public let availability: [JamEvidenceAvailability]
    public let lastAttemptAt: Date?
    public let lastAttemptAvailability: [JamEvidenceAvailability]?
}
public struct FeedbackJamContextBlock: Codable, Equatable, Sendable {
    public let kind: String
    public let itemID: String?
    public let component: JamEvidenceComponent?
    public let timestampMilliseconds: Int?
    public let text: String
    public let toolName: String?
    public let evidenceImportedAt: Date?
    public let availabilityStatus: JamEvidenceAvailabilityStatus?
    public let hasImage: Bool
    public let mimeType: String?
}
public struct FeedbackJamContextPage: Codable, Sendable {
    public let batchID: String
    public let projectID: String?
    public let videoID: String?
    public let batchRevision: Int
    public let taskID: String
    public let taskRevision: Int
    public let sourceID: String
    public let jamRecordingID: String
    public let state: JamEvidenceReadState
    public let importedAt: Date
    public let lastAttemptAt: Date?
    public let blocks: [FeedbackJamContextBlock]
    public let nextCursor: String?
}
public struct FeedbackJamImage: Sendable {
    public let itemID: String
    public let mimeType: String
    public let data: Data
}
public struct FeedbackJamContextResult: Sendable {
    public let page: FeedbackJamContextPage
    public let images: [FeedbackJamImage]
}
private struct FeedbackCursor: Codable {
    let signature: String
    let offset: Int
    var encoded: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }
    static func offset(_ value: String?, signature: String) throws -> Int {
        guard let value else { return 0 }
        guard let data = Data(base64Encoded: value), let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.signature == signature, decoded.offset >= 0 else { throw TaskContextError.conflict }
        return decoded.offset
    }
}

public struct FeedbackMCPService: Sendable {
    public let store: VideoContextStore
    public init(store: VideoContextStore) { self.store = store }
    private func snapshot(_ id: String, expected: Int?) async throws -> FeedbackSnapshot {
        let value = try await store.feedbackSnapshot(id: id)
        if let expected, value.batch.revision != expected { throw TaskContextError.conflict }
        return value
    }
    public func batch(id: String, expectedRevision: Int? = nil, cursor: String? = nil) async throws -> FeedbackContextPage {
        let value = try await snapshot(id, expected: expectedRevision)
        var blocks: [FeedbackContextBlock] = [
            .init(kind: "title", text: value.batch.title),
            .init(kind: "project", text: value.batch.project),
            .init(kind: "original_feedback", text: value.batch.rawText)
        ]
        if let videoID = value.batch.videoID { blocks.insert(.init(kind: "recording_context", text: videoID), at: 0) }
        if let projectID = value.batch.projectID { blocks.insert(.init(kind: "project_context", text: projectID), at: 0) }
        for comment in value.batch.comments {
            blocks.append(.init(kind: "comment", text: "\(comment.reviewer.rawValue): \(comment.text)", sourceID: comment.id))
            blocks += comment.sourceIDs.map { .init(kind: "comment_source", text: comment.id, sourceID: $0) }
        }
        return try Self.page(blocks, batchID: id, projectID: value.batch.projectID, videoID: value.batch.videoID, batchRevision: value.batch.revision, task: nil, cursor: cursor)
    }
    public func list(batchID: String, expectedRevision: Int? = nil, cursor: String? = nil) async throws -> FeedbackTaskList {
        let value = try await snapshot(batchID, expected: expectedRevision)
        let signature = "feedback-list:\(batchID):\(value.batch.revision):" + value.tasks.map { "\($0.id):\($0.revision)" }.joined(separator: ",")
        let offset = try FeedbackCursor.offset(cursor, signature: signature)
        guard offset <= value.tasks.count else { throw TaskContextError.conflict }
        let end = min(offset + 15, value.tasks.count)
        return .init(batchID: batchID, projectID: value.batch.projectID, videoID: value.batch.videoID, batchRevision: value.batch.revision,
                     tasks: value.tasks[offset..<end].map { task in
                         .init(id: task.id, title: task.content.title, revision: task.revision,
                               approved: task.canImplement(in: value.batch), blockers: task.content.blockers,
                               origin: value.batch.comments.first(where: { $0.id == task.issueID })?.kind ?? .feedback)
                     },
                     nextCursor: end < value.tasks.count ? FeedbackCursor(signature: signature, offset: end).encoded : nil)
    }
    public func task(batchID: String, taskID: String, expectedBatchRevision: Int? = nil,
                     expectedRevision: Int? = nil, cursor: String? = nil) async throws -> FeedbackContextPage {
        let value = try await snapshot(batchID, expected: expectedBatchRevision)
        guard let task = value.tasks.first(where: { $0.id == taskID }) else { throw TaskContextError.missing(taskID) }
        if let expectedRevision, task.revision != expectedRevision { throw TaskContextError.conflict }
        var blocks: [FeedbackContextBlock] = [
            .init(kind: "title", text: task.content.title),
            .init(kind: "behavior", text: task.content.behavior),
            .init(kind: "state", text: "approved=\(task.canImplement(in: value.batch)); archived=\(task.archived); blockers=\(task.content.blockers); sourceStale=\(task.sourceRevision != value.batch.revision || task.analysisIsStale == true)")
        ]
        if let videoID = value.batch.videoID { blocks.insert(.init(kind: "recording_context", text: videoID), at: 0) }
        if let projectID = value.batch.projectID { blocks.insert(.init(kind: "project_context", text: projectID), at: 0) }
        if let issueID = task.issueID { blocks.append(.init(kind: "issue_id", text: issueID)) }
        blocks += try TaskAnalysisMCPBlocks.make(content: task.content, projectID: value.batch.projectID).map {
            .init(kind: $0.kind, text: $0.text, sourceID: $0.sourceID)
        }
        blocks.append(.init(kind: "origin", text: value.batch.comments.first(where: { $0.id == task.issueID })?.kind.rawValue ?? "feedback"))
        for statement in task.content.requirements {
            blocks.append(.init(kind: "requirement", text: "\(statement.origin.label): \(statement.text)", itemID: statement.id))
            blocks += statement.sourceIDs.map { .init(kind: "requirement_source", text: statement.id, sourceID: $0) }
        }
        for statement in task.content.checks {
            blocks.append(.init(kind: "acceptance_check", text: statement.text, itemID: statement.id))
            blocks += statement.sourceIDs.map { .init(kind: "check_source", text: statement.id, sourceID: $0) }
        }
        for question in task.content.questions {
            blocks.append(.init(kind: "question", text: Self.questionText(question), itemID: question.id))
            blocks += question.sourceIDs.map { .init(kind: "question_source", text: question.id, sourceID: $0) }
        }
        blocks += task.content.allSourceIDs.sorted().map { sourceID in
            let tool = value.batch.sources.first(where: { $0.id == sourceID })?.kind == .jam
                ? "Retrieve metadata with get_feedback_evidence, then follow every cursor from get_feedback_jam_context"
                : "Retrieve with get_feedback_evidence"
            return .init(kind: "evidence_reference", text: tool, sourceID: sourceID)
        }
        return try Self.page(blocks, batchID: batchID, projectID: value.batch.projectID, videoID: value.batch.videoID, batchRevision: value.batch.revision, task: task, cursor: cursor)
    }
    public func evidence(batchID: String, taskID: String, sourceID: String,
                         expectedBatchRevision: Int, expectedRevision: Int, paths: LibraryPaths) async throws -> FeedbackEvidenceResult {
        let value = try await snapshot(batchID, expected: expectedBatchRevision)
        guard let task = value.tasks.first(where: { $0.id == taskID }), task.revision == expectedRevision,
              task.content.allSourceIDs.contains(sourceID) else { throw TaskContextError.conflict }
        let source: FeedbackSource
        let commentText: String?
        if let linked = value.batch.sources.first(where: { $0.id == sourceID }) { source = linked }
        else if let comment = value.batch.comments.first(where: { $0.id == sourceID }) {
            source = FeedbackSource(id: comment.id, kind: .comment, status: .ready)
        } else { throw TaskContextError.missing(sourceID) }
        commentText = value.batch.comments.first(where: { $0.id == sourceID })?.text
        let annotations = task.content.annotations.filter { $0.evidenceID == sourceID }
        let metadata = FeedbackEvidenceMetadata(batchID: batchID, projectID: value.batch.projectID, videoID: value.batch.videoID, batchRevision: value.batch.revision,
            taskID: taskID, taskRevision: task.revision, sourceID: sourceID, kind: source.kind,
            url: source.url, filename: source.filename, status: source.status, presentationStatus: source.presentationStatus,
            ocrText: source.ocrText, text: commentText,
            recordingID: source.recordingID, error: source.error, annotations: annotations,
            jam: source.jam.map { jam in
                .init(state: jam.state, recordingID: jam.recordingID, importedAt: jam.importedAt,
                      itemCount: jam.items.count, tools: Array(Set(jam.items.map(\.toolName))).sorted(),
                      availability: jam.availability, lastAttemptAt: jam.lastAttemptAt,
                      lastAttemptAvailability: jam.lastAttemptAvailability)
            })
        let image: Data?
        if source.kind == .image, source.status == .ready, let path = source.localPath {
            image = try await TaskFrameRenderer.render(url: paths.absoluteURL(relativePath: path), annotations: annotations)
        } else { image = nil }
        return .init(metadata: metadata, image: image)
    }
    public func jamContext(batchID: String, taskID: String, sourceID: String,
                           expectedBatchRevision: Int, expectedRevision: Int, cursor: String? = nil,
                           paths: LibraryPaths) async throws -> FeedbackJamContextResult {
        let value = try await snapshot(batchID, expected: expectedBatchRevision)
        guard let task = value.tasks.first(where: { $0.id == taskID }), task.revision == expectedRevision,
              task.content.allSourceIDs.contains(sourceID),
              let source = value.batch.sources.first(where: { $0.id == sourceID }), source.kind == .jam,
              let jam = source.jam else { throw TaskContextError.conflict }

        var allBlocks: [FeedbackJamContextBlock] = []
        for item in jam.items {
            if let text = item.text, !text.isEmpty {
                allBlocks += LocalAnalysisBatchPlanner.pieces(text, budget: 1_500).map { piece in
                    .init(kind: "evidence", itemID: item.id, component: item.component,
                          timestampMilliseconds: item.timestampMilliseconds, text: piece, toolName: item.toolName,
                          evidenceImportedAt: item.importedAt ?? jam.importedAt,
                          availabilityStatus: nil, hasImage: false, mimeType: item.mimeType)
                }
            }
            if item.localPath != nil {
                allBlocks.append(.init(kind: "evidence", itemID: item.id, component: item.component,
                                       timestampMilliseconds: item.timestampMilliseconds, text: "Saved Jam frame",
                                       toolName: item.toolName, evidenceImportedAt: item.importedAt ?? jam.importedAt,
                                       availabilityStatus: nil, hasImage: true, mimeType: item.mimeType))
            }
        }
        allBlocks += jam.availability.map { value in
            .init(kind: "availability", itemID: nil, component: value.component, timestampMilliseconds: nil,
                  text: value.message, toolName: nil, evidenceImportedAt: nil,
                  availabilityStatus: value.status, hasImage: false, mimeType: nil)
        }
        allBlocks += (jam.lastAttemptAvailability ?? []).map { value in
            .init(kind: "retry_availability", itemID: nil, component: value.component, timestampMilliseconds: nil,
                  text: value.message, toolName: nil, evidenceImportedAt: nil,
                  availabilityStatus: value.status, hasImage: false, mimeType: nil)
        }

        let signature = "feedback-jam:\(batchID):\(value.batch.revision):\(taskID):\(task.revision):\(sourceID):\(jam.importedAt.timeIntervalSince1970):\(jam.lastAttemptAt?.timeIntervalSince1970 ?? 0):" + jam.items.map(\.id).joined(separator: ",")
        let offset = try FeedbackCursor.offset(cursor, signature: signature)
        guard offset <= allBlocks.count else { throw TaskContextError.conflict }
        var pageBlocks: [FeedbackJamContextBlock] = []
        var size = 0
        var imageCount = 0
        var end = offset
        while end < allBlocks.count {
            let block = allBlocks[end]
            let nextSize = block.text.utf8.count + 300
            if !pageBlocks.isEmpty && (size + nextSize > 6_000 || (block.hasImage && imageCount >= 2)) { break }
            pageBlocks.append(block)
            size += nextSize
            if block.hasImage { imageCount += 1 }
            end += 1
        }

        var images: [FeedbackJamImage] = []
        for block in pageBlocks where block.hasImage {
            guard let itemID = block.itemID,
                  let record = jam.items.first(where: { $0.id == itemID }), let path = record.localPath else { continue }
            let data = try Data(contentsOf: paths.absoluteURL(relativePath: path), options: [.mappedIfSafe])
            guard data.count <= 30_000_000 else { throw TaskContextError.invalid("Saved Jam frame is too large to return.") }
            images.append(.init(itemID: itemID, mimeType: record.mimeType ?? "image/jpeg", data: data))
        }
        let page = FeedbackJamContextPage(
            batchID: batchID, projectID: value.batch.projectID, videoID: value.batch.videoID,
            batchRevision: value.batch.revision, taskID: taskID, taskRevision: task.revision,
            sourceID: sourceID, jamRecordingID: jam.recordingID, state: jam.state, importedAt: jam.importedAt,
            lastAttemptAt: jam.lastAttemptAt,
            blocks: pageBlocks,
            nextCursor: end < allBlocks.count ? FeedbackCursor(signature: signature, offset: end).encoded : nil
        )
        return .init(page: page, images: images)
    }
    // Same state fields as recording task questions, plus the answer.
    private static func questionText(_ question: TaskQuestion) -> String {
        var text = "\(question.question)\nAnswer: \(question.answer)\nBlocking: \(question.isBlocking); unresolved: \(question.unresolved)"
        if let category = question.category {
            text += "\nCategory: \(category.rawValue)"
        }
        let reason = question.nonBlockingReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty {
            text += "\nNon-blocking reason: \(reason)"
        }
        return text
    }
    private static func page(_ input: [FeedbackContextBlock], batchID: String, projectID: String?, videoID: String?, batchRevision: Int,
                             task: FeedbackTask?, cursor: String?) throws -> FeedbackContextPage {
        let blocks = input.flatMap { block in
            LocalAnalysisBatchPlanner.pieces(block.text, budget: 1500).map {
                FeedbackContextBlock(kind: block.kind, text: $0, sourceID: block.sourceID, itemID: block.itemID)
            }
        }
        let signature = "feedback:\(batchID):\(batchRevision):\(task?.id ?? "batch"):\(task?.revision ?? 0)"
        let offset = try FeedbackCursor.offset(cursor, signature: signature)
        guard offset <= blocks.count else { throw TaskContextError.conflict }
        var page: [FeedbackContextBlock] = [], size = 0, end = offset
        while end < blocks.count {
            let next = blocks[end].text.utf8.count + 200
            if !page.isEmpty && size + next > 6000 { break }
            page.append(blocks[end]); size += next; end += 1
        }
        return .init(batchID: batchID, projectID: projectID, videoID: videoID, batchRevision: batchRevision, taskID: task?.id, taskRevision: task?.revision,
                     blocks: page, nextCursor: end < blocks.count ? FeedbackCursor(signature: signature, offset: end).encoded : nil)
    }
}
