import Foundation
import MCP
import VideoContextCore

@main
enum VideoContextMCPMain {
    static func main() async throws {
        let paths = try resolveLibraryPaths(arguments: CommandLine.arguments)
        let diagnostics = DiagnosticsService.library(paths, component: .mcp)
        await diagnostics.record(.init(.started, operation: .lifecycle))
        do {
            let ffmpegPath = argument(named: "--ffmpeg", in: CommandLine.arguments) ?? "/opt/homebrew/bin/ffmpeg"
            let allowDocumentProposals = CommandLine.arguments.contains("--allow-document-proposals")
            let store = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
            let context = MCPContextService(store: store)
            let server = Server(
                name: "video-context",
                version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: false))
            )

            await server.withMethodHandler(ListTools.self) { _ in
                .init(tools: tools(allowDocumentProposals: allowDocumentProposals))
            }
            await server.withMethodHandler(CallTool.self) { parameters in
                let operation = DiagnosticOperation.tool(parameters.name)
                let scope = DiagnosticScope(service: diagnostics, operation: operation, context: .init(
                    videoID: string("video_id", in: parameters), taskID: string("task_id", in: parameters), revision: try? expectedRevision(in: parameters)))
                return await DiagnosticTrace.$scope.withValue(scope) {
                    await DiagnosticTrace.record(.toolStarted)
                    let result = await callTool(parameters, context: context, store: store, paths: paths, ffmpegPath: ffmpegPath,
                                               allowDocumentProposals: allowDocumentProposals)
                    await diagnostics.record(.init(.toolFinished, operation: operation, operationID: scope.id, context: scope.context,
                        elapsedSeconds: Date().timeIntervalSince(scope.startedAt), error: result.isError == true ? .init(category: .invalidRequest) : nil))
                    return result
                }
            }

            let transport = RetrievalStdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            await server.stop()
            await diagnostics.record(.init(.completed, operation: .lifecycle))
        } catch {
            await diagnostics.record(.init(.failed, operation: .lifecycle, error: DiagnosticFailure(error)))
            throw error
        }
    }

    private static func tools(allowDocumentProposals: Bool) -> [Tool] {
        var values: [Tool] = [
            Tool(name: "get_feedback_batch", description: "Read exact feedback batch text, comments, and linked source IDs. Follow continuation cursors.", inputSchema: schema(required: ["batch_id"], properties: ["batch_id": stringProperty("Permanent feedback batch ID"), "expected_batch_revision": numberProperty("Optional expected batch revision"), "cursor": stringProperty("Revision-bound continuation cursor")]), annotations: readOnlyAnnotations(title: "Get feedback batch")),
            Tool(name: "list_feedback_tasks", description: "List tasks for one exact feedback batch; follow continuation cursors.", inputSchema: schema(required: ["batch_id"], properties: ["batch_id": stringProperty("Permanent feedback batch ID"), "expected_batch_revision": numberProperty("Optional expected batch revision"), "cursor": stringProperty("Revision-bound continuation cursor")]), annotations: readOnlyAnnotations(title: "List feedback tasks")),
            Tool(name: "get_feedback_task", description: "Read one exact task and revision with requirements, checks, questions, and evidence references.", inputSchema: schema(required: ["batch_id", "task_id", "expected_batch_revision", "expected_revision"], properties: ["batch_id": stringProperty("Permanent feedback batch ID"), "task_id": stringProperty("Permanent feedback task ID"), "expected_batch_revision": numberProperty("Expected batch revision"), "expected_revision": numberProperty("Expected task revision"), "cursor": stringProperty("Revision-bound continuation cursor")]), annotations: readOnlyAnnotations(title: "Get feedback task")),
            Tool(name: "get_feedback_evidence", description: "Read one exact source linked to a task, including original share URL, OCR, and image if available.", inputSchema: schema(required: ["batch_id", "task_id", "source_id", "expected_batch_revision", "expected_revision"], properties: ["batch_id": stringProperty("Permanent feedback batch ID"), "task_id": stringProperty("Permanent feedback task ID"), "source_id": stringProperty("Source ID from the task"), "expected_batch_revision": numberProperty("Expected batch revision"), "expected_revision": numberProperty("Expected task revision")]), annotations: readOnlyAnnotations(title: "Get feedback evidence")),
            Tool(name: "get_feedback_jam_context", description: "Read locally saved Jam transcript, frames, user actions, console errors, failed-request summaries, provenance, and availability for one exact task source. No Jam credentials are required. Follow continuation cursors.", inputSchema: schema(required: ["batch_id", "task_id", "source_id", "expected_batch_revision", "expected_revision"], properties: ["batch_id": stringProperty("Permanent feedback batch ID"), "task_id": stringProperty("Permanent feedback task ID"), "source_id": stringProperty("Jam source ID from the task"), "expected_batch_revision": numberProperty("Expected batch revision"), "expected_revision": numberProperty("Expected task revision"), "cursor": stringProperty("Revision-bound continuation cursor")]), annotations: readOnlyAnnotations(title: "Get saved Jam context")),
            Tool(name: "list_projects", description: "Discover project IDs and the Inbox. Use the returned project ID for every project-scoped read.", inputSchema: schema(required: [], properties: ["query": stringProperty("Optional project name or ID search"), "cursor": stringProperty("Project-list continuation cursor")]), annotations: readOnlyAnnotations(title: "List projects")),
            Tool(name: "get_project_context", description: "Read concise, revision-bound context for one exact project, including recordings, feedback, requests, tasks, documents, decisions, and conflicts. Citation values use Codable one-key objects such as recording:{videoID,sourceRevision,timestamp,evidenceID}, feedback:{batchID,sourceRevision,commentID,sourceID}, document:{sourceID,revision,locator}, or reviewedDocumentation:{documentID,revision,sectionID}; pass those IDs and revisions to get_project_evidence.", inputSchema: schema(required: ["project_id"], properties: ["project_id": stringProperty("Permanent project ID, or inbox"), "cursor": stringProperty("Project-revision continuation cursor"), "limit": numberProperty("Maximum context items, 1 through 100")]), annotations: readOnlyAnnotations(title: "Get project context")),
            Tool(name: "search_project", description: "Search recordings, transcript, screenshots, feedback, requests, tasks, documents, and decisions inside one exact project.", inputSchema: schema(required: ["project_id", "query"], properties: ["project_id": stringProperty("Permanent project ID, or inbox"), "query": stringProperty("Search terms"), "cursor": stringProperty("Project-revision continuation cursor"), "limit": numberProperty("Maximum hits, 1 through 100")]), annotations: readOnlyAnnotations(title: "Search project")),
            Tool(name: "get_project_document", description: "Retrieve one exact reviewed product document with its revision, classifications, citations, and continuation cursor.", inputSchema: schema(required: ["project_id", "document_id"], properties: ["project_id": stringProperty("Permanent project ID"), "document_id": stringProperty("Permanent document ID"), "expected_revision": numberProperty("Optional expected document revision"), "cursor": stringProperty("Document-revision continuation cursor"), "word_limit": numberProperty("Words per page, 1 through 5,000")]), annotations: readOnlyAnnotations(title: "Get project document")),
            Tool(name: "get_project_evidence", description: "Retrieve exact project evidence by source revision and locator. Recording, feedback, imported document, and reviewedDocumentation evidence stay inside the requested project. Historic revisions are returned with freshness=stale when their retained source history is available; newer or missing revisions fail closed.", inputSchema: schema(required: ["project_id", "kind", "source_id", "revision"], properties: ["project_id": stringProperty("Permanent project ID"), "kind": stringProperty("recording, feedback, document, or reviewedDocumentation"), "source_id": stringProperty("Recording, feedback batch, imported document source, or reviewed project document ID"), "revision": .object(["oneOf": .array([.object(["type": .string("integer"), "minimum": .int(1)]), .object(["type": .string("object"), "description": .string("Recording ArtifactRevision with transcript, evidence, brief, briefSourceTranscript, and briefSourceEvidence integer fields"), "properties": .object(["transcript": .object(["type": .string("integer"), "minimum": .int(0)]), "evidence": .object(["type": .string("integer"), "minimum": .int(0)]), "brief": .object(["type": .string("integer"), "minimum": .int(0)]), "briefSourceTranscript": .object(["type": .string("integer"), "minimum": .int(0)]), "briefSourceEvidence": .object(["type": .string("integer"), "minimum": .int(0)])]), "required": .array(["transcript", "evidence", "brief", "briefSourceTranscript", "briefSourceEvidence"].map(Value.string)), "additionalProperties": .bool(false)])])]), "timestamp_seconds": numberProperty("Recording timestamp"), "evidence_id": stringProperty("Recording screenshot or transcript segment ID"), "comment_id": stringProperty("Feedback comment ID"), "feedback_source_id": stringProperty("Feedback source attachment ID"), "locator": documentLocatorProperty, "section_id": stringProperty("Reviewed project documentation section ID; omit for the complete document")]), annotations: readOnlyAnnotations(title: "Get project evidence")),
            Tool(name: "list_video_tasks", description: "List tasks only for the exact Context ID. Includes review state and revision; no task changes or inference.", inputSchema: schema(required: ["video_id"], properties: ["video_id": contextIDProperty, "cursor": stringProperty("Revision-bound continuation cursor")]), annotations: readOnlyAnnotations(title: "List recording tasks")),
            Tool(name: "get_video_task", description: "Retrieve one exact task and its requirements, acceptance checks, user clarifications and evidence. Supply the handoff revision; follow cursors. Review means requirements approved, not implementation complete.", inputSchema: schema(required: ["video_id", "task_id"], properties: ["video_id": contextIDProperty, "task_id": stringProperty("Permanent task ID"), "expected_revision": numberProperty("Exact task revision from the handoff"), "cursor": stringProperty("Revision-bound continuation cursor")]), annotations: readOnlyAnnotations(title: "Get reviewed task")),
            Tool(name: "get_task_frame", description: "Retrieve one bounded screenshot with task annotations from the exact recording and task. Supply the handoff revision; user notes are separate from original evidence.", inputSchema: schema(required: ["video_id", "task_id", "evidence_id"], properties: ["video_id": contextIDProperty, "task_id": stringProperty("Permanent task ID"), "evidence_id": stringProperty("Linked screenshot evidence ID"), "expected_revision": numberProperty("Exact task revision from the handoff"), "crop": cropProperty]), annotations: readOnlyAnnotations(title: "Get task screenshot")),
            Tool(
                name: "list_videos",
                description: "List or find Video Context recordings and their permanent Context IDs. Use only when the user asks to discover a recording; never substitute another recording for an unknown Context ID.",
                inputSchema: .object(["type": .string("object"), "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Optional title search")]),
                    "cursor": .object(["type": .string("string"), "description": .string("Continuation cursor")])
                ])]),
                annotations: readOnlyAnnotations(title: "List recordings")
            ),
            Tool(
                name: "get_video_brief",
                description: "Read the bounded coding brief for the exact recording selected by its permanent Context ID.",
                inputSchema: schema(required: ["video_id"], properties: [
                    "video_id": contextIDProperty,
                    "cursor": stringProperty("Continuation cursor")
                ]),
                annotations: readOnlyAnnotations(title: "Get recording brief")
            ),
            Tool(
                name: "search_video",
                description: "Search transcript, screenshot OCR, and brief text only within the recording selected by its permanent Context ID.",
                inputSchema: schema(required: ["video_id", "query"], properties: [
                    "video_id": contextIDProperty,
                    "query": stringProperty("Terms to search for"),
                    "cursor": stringProperty("Continuation cursor")
                ]),
                annotations: readOnlyAnnotations(title: "Search recording")
            ),
            Tool(
                name: "get_video_segment",
                description: "Retrieve timestamped transcript and screenshot evidence from the exact recording selected by its permanent Context ID.",
                inputSchema: schema(required: ["video_id", "start_seconds", "end_seconds"], properties: [
                    "video_id": contextIDProperty,
                    "start_seconds": numberProperty("Range start in seconds"),
                    "end_seconds": numberProperty("Range end in seconds"),
                    "cursor": stringProperty("Continuation cursor")
                ]),
                annotations: readOnlyAnnotations(title: "Get recording segment")
            ),
            Tool(
                name: "get_video_frame",
                description: "Return one frame from the exact recording selected by its permanent Context ID, optionally cropped with normalized coordinates.",
                inputSchema: schema(required: ["video_id", "timestamp_seconds"], properties: [
                    "video_id": contextIDProperty,
                    "timestamp_seconds": numberProperty("Requested timestamp in seconds"),
                    "crop": cropProperty
                ]),
                annotations: readOnlyAnnotations(title: "Get recording frame")
            )
        ]
        if allowDocumentProposals {
            values.insert(
                Tool(
                    name: "submit_document_proposal",
                    description: "Submit a review-only product-document proposal to the local Video Context inbox. The app must review it before any document changes. The proposal contains document content and evidence references only; arbitrary paths, settings, deletion, and approval are unavailable.",
                    inputSchema: schema(required: ["project_id", "document_id", "expected_revision", "request_id", "proposal"], properties: [
                        "project_id": stringProperty("Permanent project ID"),
                        "document_id": stringProperty("Permanent document ID"),
                        "expected_revision": numberProperty("Expected document revision; zero creates a new document"),
                        "request_id": stringProperty("Stable idempotency key for this proposal submission"),
                        "proposal": documentProposalProperty
                    ]),
                    annotations: proposalAnnotations()
                ),
                at: 10
            )
        }
        return values
    }

    private static func callTool(
        _ parameters: CallTool.Parameters,
        context: MCPContextService,
        store: VideoContextStore,
        paths: LibraryPaths,
        ffmpegPath: String,
        allowDocumentProposals: Bool
    ) async -> CallTool.Result {
        do {
            switch parameters.name {
            case "get_feedback_batch":
                return success(try await FeedbackMCPService(store: store).batch(id: requiredString("batch_id", in: parameters), expectedRevision: optionalRevision("expected_batch_revision", in: parameters), cursor: string("cursor", in: parameters)))
            case "list_feedback_tasks":
                return success(try await FeedbackMCPService(store: store).list(batchID: requiredString("batch_id", in: parameters), expectedRevision: optionalRevision("expected_batch_revision", in: parameters), cursor: string("cursor", in: parameters)))
            case "get_feedback_task":
                return success(try await FeedbackMCPService(store: store).task(batchID: requiredString("batch_id", in: parameters), taskID: requiredString("task_id", in: parameters), expectedBatchRevision: requiredRevision("expected_batch_revision", in: parameters), expectedRevision: requiredRevision("expected_revision", in: parameters), cursor: string("cursor", in: parameters)))
            case "get_feedback_evidence":
                let result = try await FeedbackMCPService(store: store).evidence(batchID: requiredString("batch_id", in: parameters), taskID: requiredString("task_id", in: parameters), sourceID: requiredString("source_id", in: parameters), expectedBatchRevision: requiredRevision("expected_batch_revision", in: parameters), expectedRevision: requiredRevision("expected_revision", in: parameters), paths: paths)
                let readable = String(decoding: try JSONEncoder().encode(result.metadata), as: UTF8.self)
                var content: [Tool.Content] = [.text(text: readable, annotations: nil, _meta: nil)]
                if let image = result.image { content.append(.image(data: image.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)) }
                return .init(content: content, structuredContent: try? Value(result.metadata), isError: false)
            case "get_feedback_jam_context":
                let result = try await FeedbackMCPService(store: store).jamContext(
                    batchID: requiredString("batch_id", in: parameters), taskID: requiredString("task_id", in: parameters),
                    sourceID: requiredString("source_id", in: parameters),
                    expectedBatchRevision: requiredRevision("expected_batch_revision", in: parameters),
                    expectedRevision: requiredRevision("expected_revision", in: parameters),
                    cursor: string("cursor", in: parameters), paths: paths
                )
                let readable = String(decoding: try JSONEncoder().encode(result.page), as: UTF8.self)
                var content: [Tool.Content] = [.text(text: readable, annotations: nil, _meta: nil)]
                content += result.images.map { .image(data: $0.data.base64EncodedString(), mimeType: $0.mimeType, annotations: nil, _meta: nil) }
                return .init(content: content, structuredContent: try? Value(result.page), isError: false)
            case "list_projects":
                return success(try await ProjectMCPService(store: store).listProjects(query: string("query", in: parameters), cursor: string("cursor", in: parameters), limit: optionalLimit(in: parameters, default: 20)))
            case "get_project_context":
                return success(try await ProjectMCPService(store: store).context(projectID: requiredString("project_id", in: parameters), cursor: string("cursor", in: parameters), limit: optionalLimit(in: parameters, default: 30)))
            case "search_project":
                return success(try await ProjectMCPService(store: store).search(projectID: requiredString("project_id", in: parameters), query: requiredString("query", in: parameters), cursor: string("cursor", in: parameters), limit: optionalLimit(in: parameters, default: 20)))
            case "get_project_document":
                return success(try await ProjectMCPService(store: store).document(projectID: requiredString("project_id", in: parameters), documentID: requiredString("document_id", in: parameters), expectedRevision: optionalRevision("expected_revision", in: parameters), cursor: string("cursor", in: parameters), wordLimit: optionalLimit(in: parameters, default: 1_000, max: 5_000)))
            case "get_project_evidence":
                let evidence = try await ProjectMCPService(store: store).evidence(projectID: requiredString("project_id", in: parameters), reference: try projectEvidenceReference(in: parameters), paths: paths)
                // Keep binary evidence in the native MCP image block. Returning
                // the same bytes inside structured JSON doubles response size.
                let metadata = MCPProjectEvidenceResult(projectID: evidence.projectID, reference: evidence.reference,
                    freshness: evidence.freshness, title: evidence.title, locator: evidence.locator,
                    sourceRevision: evidence.sourceRevision, text: evidence.text,
                    imageMimeType: evidence.imageMimeType, error: evidence.error)
                let readable = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
                var content: [Tool.Content] = [.text(text: readable, annotations: nil, _meta: nil)]
                if let image = evidence.imageData { content.append(.image(data: image.base64EncodedString(), mimeType: evidence.imageMimeType ?? "image/jpeg", annotations: nil, _meta: nil)) }
                return .init(content: content, structuredContent: try? Value(metadata), isError: false)
            case "submit_document_proposal":
                guard allowDocumentProposals else { throw TaskContextError.invalid("Document proposals are disabled. Start the MCP server with --allow-document-proposals to enable this opt-in capability.") }
                let proposal = try documentProposal(in: parameters)
                let requestedProjectID = try requiredString("project_id", in: parameters)
                let requestedDocumentID = try requiredString("document_id", in: parameters)
                let requestedRevision = try requiredRevisionAllowingZero("expected_revision", in: parameters)
                guard proposal.projectID == requestedProjectID,
                      proposal.documentID == requestedDocumentID,
                      proposal.expectedDocumentRevision == requestedRevision else {
                    throw TaskContextError.invalid("Proposal project, document, and expected revision must match the request.")
                }
                return success(try await ProjectMCPService(store: store).submitDocumentProposal(proposal, requestID: requiredString("request_id", in: parameters), paths: paths))
            case "list_video_tasks":
                return success(try await TaskMCPService(store: store).list(videoID: requiredString("video_id", in: parameters), cursor: string("cursor", in: parameters)))
            case "get_video_task":
                return success(try await TaskMCPService(store: store).task(videoID: requiredString("video_id", in: parameters), taskID: requiredString("task_id", in: parameters), expectedRevision: expectedRevision(in: parameters), cursor: string("cursor", in: parameters)))
            case "get_task_frame":
                let result = try await TaskMCPService(store: store).frame(videoID: requiredString("video_id", in: parameters), taskID: requiredString("task_id", in: parameters), evidenceID: requiredString("evidence_id", in: parameters), expectedRevision: expectedRevision(in: parameters), crop: crop(in: parameters), paths: paths)
                let readable = String(decoding: try JSONEncoder().encode(result.metadata), as: UTF8.self)
                return .init(content: [.text(text: readable, annotations: nil, _meta: nil), .image(data: result.image.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)], structuredContent: try? Value(result.metadata), isError: false)
            case "list_videos":
                let result = try await context.videos(query: string("query", in: parameters), cursor: string("cursor", in: parameters))
                return success(result)
            case "get_video_brief":
                let result = try await context.brief(videoID: try requiredString("video_id", in: parameters), cursor: string("cursor", in: parameters))
                return success(result)
            case "search_video":
                let result = try await context.search(
                    videoID: try requiredString("video_id", in: parameters),
                    query: try requiredString("query", in: parameters),
                    cursor: string("cursor", in: parameters)
                )
                return success(result)
            case "get_video_segment":
                let result = try await context.segment(
                    videoID: try requiredString("video_id", in: parameters),
                    start: try requiredDouble("start_seconds", in: parameters),
                    end: try requiredDouble("end_seconds", in: parameters),
                    cursor: string("cursor", in: parameters)
                )
                return success(result)
            case "get_video_frame":
                let videoID = try requiredString("video_id", in: parameters)
                let timestamp = try requiredDouble("timestamp_seconds", in: parameters)
                guard let snapshot = try await store.videoSnapshot(id: videoID) else {
                    throw VideoContextStoreError.videoNotFound(videoID)
                }
                let crop = try crop(in: parameters)
                let videoURL = paths.absoluteURL(relativePath: snapshot.video.mediaRelativePath)
                let frame = try await VideoFrameProvider(ffmpegPath: ffmpegPath)
                    .frame(videoURL: videoURL, timestamp: timestamp, crop: crop)
                let metadata = FrameMetadata(
                    videoID: videoID,
                    requestedTimestamp: timestamp,
                    actualTimestamp: frame.actualTimestamp,
                    artifactRevision: snapshot.video.revisions,
                    crop: crop
                )
                let readable = "Context ID \(videoID), requested \(timestamp)s, actual frame \(frame.actualTimestamp)s, artifact revisions \(snapshot.video.revisions)."
                return .init(
                    content: [
                        .text(text: readable, annotations: nil, _meta: nil),
                        .image(data: frame.data.base64EncodedString(), mimeType: frame.mimeType, annotations: nil, _meta: nil)
                    ],
                    structuredContent: try? Value(metadata),
                    isError: false
                )
            default:
                return failure("Unknown tool: \(parameters.name)")
            }
        } catch {
            await DiagnosticTrace.record(.failed, error: error)
            return failure(error.localizedDescription)
        }
    }

    private static func success<T: Codable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Unable to encode result."
        return .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: try? Value(value),
            isError: false
        )
    }

    private static func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func string(_ name: String, in parameters: CallTool.Parameters) -> String? {
        parameters.arguments?[name]?.stringValue
    }

    private static func requiredString(_ name: String, in parameters: CallTool.Parameters) throws -> String {
        guard let value = string(name, in: parameters), value.isEmpty == false else {
            throw MCPInputError.missing(name)
        }
        return value
    }

    private static func expectedRevision(in parameters: CallTool.Parameters) throws -> Int? {
        guard parameters.arguments?["expected_revision"] != nil else { return nil }
        guard let value = numericValue(parameters.arguments?["expected_revision"]), value.isFinite, value >= 1, value < Double(Int.max), value.rounded() == value else { throw TaskContextError.invalid("expected_revision must be a positive integer.") }
        return Int(value)
    }

    private static func optionalRevision(_ name: String, in parameters: CallTool.Parameters) throws -> Int? {
        guard parameters.arguments?[name] != nil else { return nil }
        return try requiredRevision(name, in: parameters)
    }

    private static func requiredRevision(_ name: String, in parameters: CallTool.Parameters) throws -> Int {
        guard let value = numericValue(parameters.arguments?[name]), value.isFinite,
              value >= 1, value < Double(Int.max), value.rounded() == value else { throw MCPInputError.missing(name) }
        return Int(value)
    }

    private static func requiredRevisionAllowingZero(_ name: String, in parameters: CallTool.Parameters) throws -> Int {
        guard let value = numericValue(parameters.arguments?[name]), value.isFinite,
              value >= 0, value < Double(Int.max), value.rounded() == value else { throw MCPInputError.missing(name) }
        return Int(value)
    }

    private static func optionalLimit(in parameters: CallTool.Parameters, default value: Int, max: Int = 100) throws -> Int {
        guard let raw = parameters.arguments?["limit"] else { return value }
        guard let number = numericValue(raw), number.isFinite, number >= 1, number <= Double(max), number.rounded() == number else {
            throw TaskContextError.invalid("limit must be an integer between 1 and \(max).")
        }
        return Int(number)
    }

    private static func objectValue<T: Decodable>(_ name: String, in parameters: CallTool.Parameters, as type: T.Type) throws -> T {
        guard let value = parameters.arguments?[name]?.objectValue else { throw MCPInputError.missing(name) }
        let data = try JSONEncoder().encode(Value.object(value))
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw MCPInputError.missing(name) }
        return decoded
    }

    private static func documentProposal(in parameters: CallTool.Parameters) throws -> ProjectDocumentationProposal {
        try objectValue("proposal", in: parameters, as: ProjectDocumentationProposal.self)
    }

    private static func projectEvidenceReference(in parameters: CallTool.Parameters) throws -> ProjectEvidenceReference {
        let kind = try requiredString("kind", in: parameters).lowercased()
        let sourceID = try requiredString("source_id", in: parameters)
        guard let revisionValue = parameters.arguments?["revision"] else { throw MCPInputError.missing("revision") }
        switch kind {
        case "recording":
            let revision = try objectValueFromValue(revisionValue, as: ArtifactRevision.self)
            let timestamp = try requiredDouble("timestamp_seconds", in: parameters)
            return .recording(videoID: sourceID, sourceRevision: revision, timestamp: timestamp, evidenceID: string("evidence_id", in: parameters))
        case "feedback":
            guard let revision = Int(revisionValue, strict: false), revision > 0 else { throw MCPInputError.missing("revision") }
            return .feedback(batchID: sourceID, sourceRevision: revision, commentID: string("comment_id", in: parameters), sourceID: string("feedback_source_id", in: parameters) ?? string("evidence_id", in: parameters))
        case "document":
            guard let revision = Int(revisionValue, strict: false), revision > 0 else { throw MCPInputError.missing("revision") }
            let locator = try objectValueFromValue(parameters.arguments?["locator"], as: ProjectDocumentLocator.self)
            return .document(sourceID: sourceID, revision: revision, locator: locator)
        case "revieweddocumentation":
            guard let revision = Int(revisionValue, strict: false), revision > 0 else { throw MCPInputError.missing("revision") }
            return .reviewedDocumentation(documentID: sourceID, revision: revision, sectionID: string("section_id", in: parameters))
        default:
            throw TaskContextError.invalid("kind must be recording, feedback, document, or reviewedDocumentation.")
        }
    }

    private static func objectValueFromValue<T: Decodable>(_ value: Value?, as type: T.Type) throws -> T {
        guard let value else { throw MCPInputError.missing("object") }
        let data = try JSONEncoder().encode(value)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw MCPInputError.missing("object") }
        return decoded
    }

    private static func requiredDouble(_ name: String, in parameters: CallTool.Parameters) throws -> Double {
        guard let value = numericValue(parameters.arguments?[name]) else { throw MCPInputError.missing(name) }
        return value
    }

    private static func crop(in parameters: CallTool.Parameters) throws -> NormalizedCrop? {
        guard let crop = parameters.arguments?["crop"]?.objectValue else { return nil }
        guard let x = numericValue(crop["x"]),
              let y = numericValue(crop["y"]),
              let width = numericValue(crop["width"]),
              let height = numericValue(crop["height"]) else {
            throw MCPInputError.missing("crop.x, crop.y, crop.width, or crop.height")
        }
        return try NormalizedCrop(x: x, y: y, width: width, height: height)
    }

    private static func numericValue(_ value: Value?) -> Double? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }

    private static func resolveLibraryPaths(arguments: [String]) throws -> LibraryPaths {
        if let path = argument(named: "--library", in: arguments) {
            return try LibraryPaths(
                root: URL(fileURLWithPath: path, isDirectory: true),
                createDirectories: false
            )
        }
        return try .applicationSupport(createDirectories: false)
    }

    private static func argument(named name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func schema(required: [String], properties: [String: Value]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static func stringProperty(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static var contextIDProperty: Value {
        stringProperty("Permanent Context ID shown in the Video Context app (vid_<UUID>); an exact match is required")
    }

    private static func numberProperty(_ description: String) -> Value {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static var cropProperty: Value {
        .object([
            "type": .string("object"),
            "description": .string("Optional crop rectangle. Values are normalized from 0 through 1, with x and y measured from the top-left."),
            "properties": .object([
                "x": numberProperty("Left edge from 0 through 1"),
                "y": numberProperty("Top edge from 0 through 1"),
                "width": numberProperty("Crop width from 0 through 1"),
                "height": numberProperty("Crop height from 0 through 1")
            ]),
            "required": .array(["x", "y", "width", "height"].map(Value.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static var documentLocatorProperty: Value {
        schema(required: ["kind"], properties: [
            "kind": .object(["type": .string("string"), "enum": .array(["pdfPage", "markdownLine", "heading", "asset", "unit"].map(Value.string))]),
            "page": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Required for pdfPage; one-based page number")]),
            "startLine": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Required for markdownLine; one-based line number")]),
            "endLine": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Inclusive final Markdown line")]),
            "value": stringProperty("Exact heading, asset source path, or extraction unit ID; required for heading, asset, and unit locators")
        ])
    }

    private static func readOnlyAnnotations(title: String) -> Tool.Annotations {
        .init(
            title: title,
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    private static func proposalAnnotations() -> Tool.Annotations {
        .init(
            title: "Submit document proposal",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    private static var documentProposalProperty: Value {
        .object([
            "type": .string("object"),
            "description": .string("ProjectDocumentationProposal payload. The server stores only its title and sections in the local proposal inbox."),
            "properties": .object([
                "id": stringProperty("Proposal ID; ignored for inbox identity"),
                "projectID": stringProperty("Must match project_id"),
                "documentID": stringProperty("Must match document_id"),
                "expectedDocumentRevision": numberProperty("Must match expected_revision"),
                "title": stringProperty("Proposed document title"),
                "slug": stringProperty("Document slug"),
                "markdown": stringProperty("Optional rendered Markdown"),
                "sections": .object(["type": .string("array"), "description": .string("Document sections with evidence references")]),
                "diff": .object(["type": .string("object"), "description": .string("Proposed section diff")]),
                "sourceSignature": stringProperty("Source revision signature"),
                "evidence": .object(["type": .string("array"), "description": .string("Evidence references")]),
                "state": stringProperty("Proposal state; pending is expected"),
                "isStale": .object(["type": .string("boolean")]),
                "createdAt": numberProperty("Creation timestamp"),
                "updatedAt": numberProperty("Update timestamp")
            ]),
            "additionalProperties": .bool(false)
        ])
    }
}

private struct FrameMetadata: Codable, Sendable {
    let videoID: String
    let requestedTimestamp: TimeInterval
    let actualTimestamp: TimeInterval
    let artifactRevision: ArtifactRevision
    let crop: NormalizedCrop?
}

private enum MCPInputError: Error, LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self { case .missing(let name): "Missing or invalid parameter: \(name)" }
    }
}
