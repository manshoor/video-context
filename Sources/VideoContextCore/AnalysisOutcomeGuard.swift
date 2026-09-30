import CryptoKit
import Foundation

/// Holds uncertain transport outcomes across task extraction and consolidation.
/// Each stage retains responsibility for validating and caching its result.
public struct AnalysisOutcomeGuard: HTTPDataLoading {
    public let base: AnyHTTPDataLoader
    public let store: VideoContextStore
    public let projectID: String
    public let sourceIdentity: String

    public init(base: some HTTPDataLoading, store: VideoContextStore, projectID: String, sourceIdentity: String) {
        self.base = AnyHTTPDataLoader(base); self.store = store
        self.projectID = projectID; self.sourceIdentity = sourceIdentity
    }

    public func data(for request: URLRequest) async throws -> HTTPResult {
        let body: Data
        if let raw = request.httpBody, let json = try? JSONSerialization.jsonObject(with: raw) {
            body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        } else { body = request.httpBody ?? Data() }
        let identity = Data(("task-provider-outcome-v1:" + projectID + ":" + sourceIdentity + ":" +
            (request.url?.absoluteString ?? "") + ":" + (request.httpMethod ?? "POST")).utf8) + body
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let checkpoint = try await store.beginDocumentationAnalysis(projectID: projectID, key: key)
        do {
            let response = try await base.data(for: request)
            // A received response has a known outcome. The caller validates it
            // and saves the stage cache, or explicitly retries invalid output.
            try await store.rejectDocumentationAnalysis(checkpoint, error: "Provider response received; stage validation owns the reusable result.")
            return response
        } catch {
            try? await store.failDocumentationAnalysis(checkpoint, error: error.localizedDescription)
            throw error
        }
    }
}
