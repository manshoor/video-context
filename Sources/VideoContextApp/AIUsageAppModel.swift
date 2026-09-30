import Foundation
import CryptoKit
import VideoContextCore

struct UsagePresentation: Identifiable {
    let id = UUID()
    var videoID: String?
    var runID: String?
}

extension AppModel {
    func showUsage(videoID: String? = nil, runID: String? = nil) { usagePresentation = .init(videoID: videoID, runID: runID) }

    func withUsageRun<T>(operation: UsageOperation, videoID: String?, configuration: ModelConfiguration,
                         source: ArtifactRevision? = nil, feedbackBatchID: String? = nil, feedbackRevision: Int? = nil, projectID: String? = nil,
                         projectAnalysisFingerprint: String? = nil,
                         body: () async throws -> T) async throws -> T {
        guard let store else { throw TaskContextError.invalid("The library is unavailable.") }
        var fingerprintData = try JSONEncoder().encode(configuration) + JSONEncoder().encode(source)
        if let feedbackRevision { fingerprintData += try JSONEncoder().encode(feedbackRevision) }
        if let projectAnalysisFingerprint { fingerprintData += Data(projectAnalysisFingerprint.utf8) }
        let fingerprint = SHA256.hash(data: fingerprintData).map { String(format: "%02x", $0) }.joined()
        let run: UsageRun
        do {
            var request = UsageRun(videoID: videoID, operation: operation, provider: configuration.analysisProvider.identity, model: configuration.selectedAnalysisModel, fingerprint: fingerprint, feedbackBatchID: feedbackBatchID)
            request.projectID = projectID
            run = try await store.startUsageRun(request)
        }
        catch { usageStorageError = "AI usage could not be saved. Check library access and disk space before retrying."; throw error }
        usageRevision += 1
        let session = UsageSession(runID: run.id, store: store) { [weak self] in await self?.usageChanged() }
        do {
            let result = try await UsageTrace.$session.withValue(session) { try await body() }
            await finishUsage(session, outcome: .completed)
            return result
        } catch {
            await finishUsage(session, outcome: Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }
    private func usageChanged() { usageRevision += 1 }
    private func finishUsage(_ session: UsageSession, outcome: UsageOutcome) async {
        let incomplete = await session.hasStorageFailure()
        do { try await session.store.finishUsageRun(id: session.runID, outcome: outcome, incomplete: incomplete) }
        catch { usageStorageError = "Some AI usage could not be saved. Totals may be incomplete. Check disk space and library access." }
        if incomplete { usageStorageError = "Some AI usage could not be saved. Totals may be incomplete. Check disk space and library access." }
        usageRevision += 1
    }
}
