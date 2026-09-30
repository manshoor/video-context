import Foundation
import CoreFoundation


public enum UsageOperation: String, Codable, CaseIterable, Sendable { case processing, taskGeneration, documentationGeneration, modelTest, earlierUsage }
public enum UsageStage: String, Codable, Sendable { case transcription, analysis, taskExtraction, taskConsolidation, evidenceReview, modelTest }
public enum UsageOutcome: String, Codable, Sendable { case running, completed, failed, cancelled, interrupted, responseReceived }

public struct FeedbackValidationDiagnostic: Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        case invalidTargetTaskID, emptyValue, valueTooLong, missingItems, missingCitations, unexpectedSourceIDs, invalidOrigin
    }
    public let attempt: Int
    public let primaryIssueID: String
    public let fieldPath: String
    public let category: Category
    public let sourceIDs: [String]

    public init(attempt: Int, primaryIssueID: String, fieldPath: String, category: Category, sourceIDs: [String] = []) {
        self.attempt = min(2, max(1, attempt))
        self.primaryIssueID = Self.identifier(primaryIssueID, prefix: "fcom_") ?? "<missing>"
        self.fieldPath = fieldPath.count <= 160 && fieldPath.range(of: #"^tasks\[[0-9]+\]\.(targetTaskID|title|behavior|checks|sourceIDs|requirements\[[0-9]+\]\.(text|origin|sourceIDs)|checks\[[0-9]+\]\.(text|origin|sourceIDs)|questions\[[0-9]+\]\.(question|sourceIDs))$"#, options: .regularExpression) != nil ? fieldPath : "unknown"
        self.category = category
        self.sourceIDs = Array(sourceIDs.prefix(8)).map { value in
            Self.identifier(value, prefix: "fcom_") ?? Self.identifier(value, prefix: "fsrc_") ?? "<invalid-source-id>"
        }
    }

    private static func identifier(_ value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix), UUID(uuidString: String(value.dropFirst(prefix.count))) != nil else { return nil }
        return value
    }
}

public struct UsageTokens: Codable, Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public var total: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var reasoning: Int?
    public var audioSeconds: Double?
    public init(input: Int? = nil, output: Int? = nil, total: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil, reasoning: Int? = nil, audioSeconds: Double? = nil) {
        self.input = input; self.output = output; self.total = total ?? Self.sum(input, output)
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reasoning = reasoning; self.audioSeconds = audioSeconds
    }
    static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        let sum = a.addingReportingOverflow(b); return sum.overflow ? nil : sum.partialValue
    }
    public static func decode(_ data: Data, provider: InferenceProvider) -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let usage = root["usage"] as? [String: Any] else { return .init() }
        func number(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0,
                  n.doubleValue < Double(Int.max), n.doubleValue.rounded(.down) == n.doubleValue else { return nil }
            return n.intValue
        }
        let cacheRead = number(usage["cache_read_input_tokens"] ?? usage["prompt_cache_hit_tokens"] ?? (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] ?? (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
        let cacheWrite = number(usage["cache_creation_input_tokens"])
        var input = number(usage["input_tokens"] ?? usage["prompt_tokens"])
        if provider == .claude {
            let read = usage["cache_read_input_tokens"] == nil ? 0 : cacheRead
            let write = usage["cache_creation_input_tokens"] == nil ? 0 : cacheWrite
            input = sum(sum(input, read), write)
        }
        let output = number(usage["output_tokens"] ?? usage["completion_tokens"])
        let reasoning = number((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] ?? (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] ?? (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"])
        let seconds = usage["seconds"] as? Double
        return .init(input: input, output: output, total: provider == .claude ? sum(input, output) : number(usage["total_tokens"]) ?? sum(input, output), cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning, audioSeconds: seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }
}

public struct UsageRun: Codable, Sendable, Identifiable {
    public var id = "run_\(UUID().uuidString.lowercased())"
    public var videoID: String?
    public var feedbackBatchID: String?
    public var projectID: String?
    public var operation: UsageOperation
    public var provider: InferenceProvider
    public var model: String
    public var startedAt = Date()
    public var finishedAt: Date?
    public var outcome: UsageOutcome = .running
    public var fingerprint: String
    public var resumedFrom: String?
    public var reusedRuns: [String] = []
    public var cachedBatches = 0
    public var accountingIncomplete = false
    public var feedbackValidationDiagnostics: [FeedbackValidationDiagnostic]?
    public var feedbackValidationDiagnosticsTruncated: Bool?
    public var processID = ProcessInfo.processInfo.processIdentifier
    public init(videoID: String?, operation: UsageOperation, provider: InferenceProvider, model: String, fingerprint: String = "", feedbackBatchID: String? = nil) {
        self.videoID = videoID; self.feedbackBatchID = feedbackBatchID; self.operation = operation; self.provider = provider; self.model = Self.safeModel(model); self.fingerprint = fingerprint
    }
}
public extension UsageRun {
    static func safeModel(_ value: String) -> String {
        DiagnosticContext.modelName(value.replacingOccurrences(of: ":", with: "-")) == nil ? "unreported-model" : value
    }
}
public struct UsageAttempt: Codable, Sendable, Identifiable {
    public var id = "attempt_\(UUID().uuidString.lowercased())"
    public var runID: String
    public var stage: UsageStage
    public var provider: InferenceProvider
    public var requestedModel: String
    public var resolvedModel: String?
    public var startedAt = Date()
    public var finishedAt: Date?
    public var outcome: UsageOutcome = .running
    public var httpStatus: Int?
    public var tokens = UsageTokens()
    public init(runID: String, stage: UsageStage, provider: InferenceProvider, requestedModel: String) {
        self.runID = runID; self.stage = stage; self.provider = provider; self.requestedModel = UsageRun.safeModel(requestedModel)
    }
}
public struct UsageSnapshot: Sendable {
    public let runs: [UsageRun]
    public let attempts: [UsageAttempt]
    public let recordingTitles: [String: String]
    public var feedbackTitles: [String: String] = [:]
}
public struct UsageTotal: Sendable {
    public let value: Int?
    public let partial: Bool
    public init(_ values: [Int?]) {
        var sum = 0, count = 0, overflow = false
        for value in values.compactMap({ $0 }) {
            let next = sum.addingReportingOverflow(value); overflow = overflow || next.overflow
            if !next.overflow { sum = next.partialValue }; count += 1
        }
        value = count == 0 && !values.isEmpty ? nil : sum
        partial = count < values.count || overflow
    }
}
