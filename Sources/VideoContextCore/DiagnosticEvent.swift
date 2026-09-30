import Foundation

public enum DiagnosticComponent: String, Codable, Sendable { case app, mcp }
public enum DiagnosticOperation: String, Codable, Sendable {
    case lifecycle, capture, importLocal, importOnline, processing, taskGeneration, speechModel, modelCheck
    case credentials, save, review, export, unknownTool
    case listVideos, getVideoBrief, searchVideo, getVideoSegment, getVideoFrame, listVideoTasks, getVideoTask, getTaskFrame
    public static func tool(_ name: String) -> Self {
        switch name {
        case "list_videos": .listVideos
        case "get_video_brief": .getVideoBrief
        case "search_video": .searchVideo
        case "get_video_segment": .getVideoSegment
        case "get_video_frame": .getVideoFrame
        case "list_video_tasks": .listVideoTasks
        case "get_video_task": .getVideoTask
        case "get_task_frame": .getTaskFrame
        default: .unknownTool
        }
    }
}
public enum DiagnosticEventKind: String, Codable, Sendable {
    case started, completed, failed, cancelled, progress, checkpointReused, stateChanged, toolStarted, toolFinished, providerStarted, providerFinished, preparingModel
}
public enum DiagnosticCredentialState: String, Codable, Sendable { case loading, ready, missing, accessRequired, failed }

/// No free-text message or metadata dictionary: callers cannot accidentally persist content.
public struct DiagnosticContext: Codable, Sendable {
    public let videoID: String?
    public let taskID: String?
    public let revision: Int?
    public let provider: InferenceProvider?
    public let model: String?
    public init(videoID: String? = nil, taskID: String? = nil, revision: Int? = nil,
                provider: InferenceProvider? = nil, model: String? = nil) {
        self.videoID = Self.identifier(videoID, prefix: "vid_")
        self.taskID = Self.identifier(taskID, prefix: "task_")
        self.revision = revision.flatMap { $0 >= 0 ? $0 : nil }
        self.provider = provider
        self.model = Self.modelName(model)
    }
    public static func identifier(_ value: String?, prefix: String) -> String? {
        guard let value, value.hasPrefix(prefix), UUID(uuidString: String(value.dropFirst(prefix.count))) != nil else { return nil }
        return value
    }
    public static func modelName(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 128, !value.hasPrefix("/"), !value.contains(".."),
              value.split(separator: "/").count <= 2,
              value.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._/\-]*$"#, options: .regularExpression) != nil,
              !["sk-", "ghp_", "gho_", "github_pat_", "akia", "asia"].contains(where: { value.lowercased().contains($0) }) else { return nil }
        return value
    }
}

public struct DiagnosticFailure: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable {
        case cancelled, credentialsMissing, keychain, provider, configuration, unavailable, invalidOutput, truncated, contextLength
        case missingContext, revisionConflict, reviewRequired, invalidRequest, decoding, media, subprocess, network, fileSystem, unknown
    }
    public let category: Category
    public let code: Int?
    public init(category: Category, code: Int? = nil) { self.category = category; self.code = code }
    public init(_ error: any Error) {
        switch error {
        case is CancellationError: self.init(category: .cancelled)
        case let e as OpenAIClientError:
            switch e {
            case .missingAPIKey: self.init(category: .credentialsMissing)
            case .invalidHTTPResponse: self.init(category: .invalidOutput)
            case .provider(let status, _): self.init(category: .provider, code: status)
            }
        case let e as LocalProviderError:
            switch e {
            case .configuration: self.init(category: .configuration)
            case .unavailable: self.init(category: .unavailable)
            case .invalidOutput: self.init(category: .invalidOutput)
            case .truncated: self.init(category: .truncated)
            case .contextLength: self.init(category: .contextLength)
            }
        case let e as KeychainError:
            switch e {
            case .interactionNotAllowed: self.init(category: .keychain, code: -25308)
            case .unexpectedStatus(let status): self.init(category: .keychain, code: Int(status))
            }
        case let e as TaskContextError:
            switch e {
            case .missing: self.init(category: .missingContext)
            case .conflict: self.init(category: .revisionConflict)
            case .reviewRequired: self.init(category: .reviewRequired)
            case .invalid: self.init(category: .invalidRequest)
            }
        case let e as VideoContextStoreError:
            switch e {
            case .videoNotFound, .transcriptSegmentNotFound, .briefUnavailable: self.init(category: .missingContext)
            case .invalidCursor, .invalidLimit, .emptyQuery, .invalidTimeRange: self.init(category: .invalidRequest)
            }
        case is DecodingError: self.init(category: .decoding)
        case is MediaImportError, is MediaProcessingError: self.init(category: .media)
        case let e as ProcessRunnerError:
            if case .unsuccessful(_, let output) = e { self.init(category: .subprocess, code: Int(output.status)) }
            else { self.init(category: .subprocess) }
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { self.init(category: .network, code: ns.code) }
            else if [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(ns.domain) { self.init(category: .fileSystem, code: ns.code) }
            else { self.init(category: .unknown) }
        }
    }
}

public struct DiagnosticEntry: Codable, Sendable {
    public let event: DiagnosticEventKind
    public let operation: DiagnosticOperation
    public let operationID: UUID
    public let context: DiagnosticContext
    public let stage: ProcessingStatus?
    public let completed: Int?
    public let total: Int?
    public let elapsedSeconds: Double?
    public let error: DiagnosticFailure?
    public let credentialState: DiagnosticCredentialState?
    public let alreadyUnderway: Bool
    public init(_ event: DiagnosticEventKind, operation: DiagnosticOperation, operationID: UUID = UUID(),
                context: DiagnosticContext = .init(), stage: ProcessingStatus? = nil, completed: Int? = nil, total: Int? = nil,
                elapsedSeconds: Double? = nil, error: DiagnosticFailure? = nil,
                credentialState: DiagnosticCredentialState? = nil, alreadyUnderway: Bool = false) {
        self.event = event; self.operation = operation; self.operationID = operationID; self.context = context
        self.stage = stage; self.completed = completed; self.total = total
        self.elapsedSeconds = elapsedSeconds.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.error = error; self.credentialState = credentialState; self.alreadyUnderway = alreadyUnderway
    }
}
public struct DiagnosticEvent: Codable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let monotonicTicks: UInt64
    public let captureID: UUID
    public let sessionID: UUID
    public let component: DiagnosticComponent
    public let build: String
    public let severity: String
    public let droppedEvents: Int
    public let entry: DiagnosticEntry
    public var event: DiagnosticEventKind { entry.event }
}
public enum DiagnosticBuild {
    public static var current: String {
        // Both bundled executables use the same Info.plist. Standalone development builds are explicit.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String,
              version.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil,
              build.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil else { return "development" }
        return "\(version) (\(build))"
    }
}
