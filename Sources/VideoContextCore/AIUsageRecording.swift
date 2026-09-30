import Foundation

public actor UsageSession {
    public nonisolated let runID: String
    public nonisolated let store: VideoContextStore
    private var storageFailed = false
    private let changed: @Sendable () async -> Void
    public init(runID: String, store: VideoContextStore, changed: @escaping @Sendable () async -> Void = {}) { self.runID = runID; self.store = store; self.changed = changed }
    public func notify() async { await changed() }
    public func markStorageFailure() { storageFailed = true }
    public func hasStorageFailure() -> Bool { storageFailed }
    public func cache(key: String, reused: Bool) async {
        do { try await store.recordUsageCache(key: key, runID: runID, reused: reused) }
        catch { storageFailed = true }
    }
    public func feedbackValidation(_ diagnostics: [FeedbackValidationDiagnostic], truncated: Bool) async {
        do { try await store.recordFeedbackValidationDiagnostics(runID: runID, diagnostics: diagnostics, truncated: truncated); await changed() }
        catch { storageFailed = true }
    }
}
public enum UsageTrace {
    @TaskLocal public static var session: UsageSession?
    @TaskLocal public static var stage: UsageStage?
    public static func cache(key: String, reused: Bool) async { await session?.cache(key: key, reused: reused) }
    public static func feedbackValidation(_ diagnostics: [FeedbackValidationDiagnostic], truncated: Bool) async {
        await session?.feedbackValidation(diagnostics, truncated: truncated)
    }
}

/// Captures only allowlisted metrics, never requests, prompts, images, or error bodies.
public struct UsageRecordingClient<Base: HTTPDataLoading>: HTTPDataLoading {
    public let base: Base
    public let provider: InferenceProvider
    public let model: String
    public let defaultStage: UsageStage
    public init(base: Base, provider: InferenceProvider, model: String, stage: UsageStage) {
        self.base = base; self.provider = provider; self.model = model; self.defaultStage = stage
    }
    public func data(for request: URLRequest) async throws -> HTTPResult {
        guard request.httpMethod == "POST", let session = UsageTrace.session else { return try await base.data(for: request) }
        let requestJSON = request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true
            ? request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        var attempt = UsageAttempt(runID: session.runID, stage: UsageTrace.stage ?? defaultStage, provider: provider, requestedModel: model)
        attempt.resolvedModel = (requestJSON?["model"] as? String).map(UsageRun.safeModel)
        // Stop before inference if we cannot record that it was attempted.
        do { try await session.store.saveUsageAttempt(attempt); await session.notify() }
        catch { await session.markStorageFailure(); throw error }
        do {
            let response = try await base.data(for: request)
            attempt.finishedAt = .now; attempt.httpStatus = response.statusCode
            attempt.outcome = (200..<300).contains(response.statusCode) ? .responseReceived : .failed
            attempt.tokens = UsageTokens.decode(response.data, provider: provider)
            if attempt.stage == .transcription, attempt.tokens.audioSeconds == nil,
               let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let duration = root["duration"] as? Double, duration.isFinite, duration >= 0 {
                attempt.tokens.audioSeconds = duration
            }
            if let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let resolved = root["model"] as? String,
               !resolved.isEmpty, resolved.count <= 200, resolved.allSatisfy({ $0.isLetter || $0.isNumber || "-_.:/".contains($0) }) {
                attempt.resolvedModel = UsageRun.safeModel(resolved)
            }
            do { try await session.store.saveUsageAttempt(attempt); await session.notify() } catch { await session.markStorageFailure() }
            return response
        } catch {
            attempt.finishedAt = .now; attempt.outcome = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            do { try await session.store.saveUsageAttempt(attempt); await session.notify() } catch { await session.markStorageFailure() }
            throw error
        }
    }
}
