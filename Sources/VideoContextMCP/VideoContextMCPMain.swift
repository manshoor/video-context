import Foundation
import MCP
import VideoContextCore

@main
enum VideoContextMCPMain {
    static func main() async throws {
        let paths = try resolveLibraryPaths(arguments: CommandLine.arguments)
        let ffmpegPath = argument(named: "--ffmpeg", in: CommandLine.arguments) ?? "/opt/homebrew/bin/ffmpeg"
        let store = try VideoContextStore(databaseURL: paths.database, access: .readOnly)
        let context = MCPContextService(store: store)
        let server = Server(
            name: "video-context",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await callTool(parameters, context: context, store: store, paths: paths, ffmpegPath: ffmpegPath)
        }

        let transport = RetrievalStdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        await server.stop()
    }

    private static var tools: [Tool] {
        [
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
    }

    private static func callTool(
        _ parameters: CallTool.Parameters,
        context: MCPContextService,
        store: VideoContextStore,
        paths: LibraryPaths,
        ffmpegPath: String
    ) async -> CallTool.Result {
        do {
            switch parameters.name {
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

    private static func readOnlyAnnotations(title: String) -> Tool.Annotations {
        .init(
            title: title,
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
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
