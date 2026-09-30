import Foundation
import VideoContextCore

extension AppModel {
    /// Explicit UI fixtures use a disposable library and never call providers.
    func installUsageFixture(videoID: String) async throws -> String? {
        guard isUIFixture, CommandLine.arguments.contains("--ui-usage"), let store else { return nil }
        var processing = UsageRun(videoID: videoID, operation: .processing, provider: .lmStudio, model: "fixture-vision")
        processing.startedAt = .now.addingTimeInterval(-240)
        let first = try await store.startUsageRun(processing)
        for (stage, provider, tokens) in [(UsageStage.transcription, InferenceProvider.localWhisper, UsageTokens(audioSeconds: 125)), (.analysis, .lmStudio, UsageTokens(input: 12500, output: 1800))] {
            var attempt = UsageAttempt(runID: first.id, stage: stage, provider: provider, requestedModel: provider == .localWhisper ? "whisper-large-v3-turbo" : "fixture-vision")
            attempt.startedAt = .now.addingTimeInterval(-180); attempt.finishedAt = .now.addingTimeInterval(-90)
            attempt.tokens = tokens; attempt.outcome = .responseReceived
            try await store.saveUsageAttempt(attempt)
        }
        try await store.finishUsageRun(id: first.id, outcome: .completed)
        let generated = try await store.startUsageRun(.init(videoID: videoID, operation: .taskGeneration, provider: .claude, model: "fixture-claude"))
        for stage in [UsageStage.taskExtraction, .taskConsolidation] {
            var attempt = UsageAttempt(runID: generated.id, stage: stage, provider: .claude, requestedModel: "fixture-claude")
            attempt.tokens = .init(input: 4300, output: 850, cacheRead: 1200, reasoning: 200)
            attempt.finishedAt = .now; attempt.outcome = .responseReceived
            try await store.saveUsageAttempt(attempt)
        }
        try await store.finishUsageRun(id: generated.id, outcome: .completed)
        let unknown = try await store.startUsageRun(.init(videoID: nil, operation: .modelTest, provider: .deepSeek, model: "deepseek-flash"))
        var attempt = UsageAttempt(runID: unknown.id, stage: .modelTest, provider: .deepSeek, requestedModel: "deepseek-flash")
        attempt.finishedAt = .now; attempt.outcome = .failed; attempt.httpStatus = 503
        try await store.saveUsageAttempt(attempt)
        try await store.finishUsageRun(id: unknown.id, outcome: .failed)
        usageRevision += 1
        return generated.id
    }
}
