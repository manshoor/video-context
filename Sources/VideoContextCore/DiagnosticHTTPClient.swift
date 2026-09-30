import Foundation

/// Keeps payloads and arbitrary provider error messages out of diagnostic events.
public struct DiagnosticHTTPClient<Base: HTTPDataLoading>: HTTPDataLoading {
    public let base: Base
    public let provider: InferenceProvider
    public init(base: Base, provider: InferenceProvider) { self.base = base; self.provider = provider }
    public func data(for request: URLRequest) async throws -> HTTPResult {
        guard let scope = DiagnosticTrace.scope else { return try await base.data(for: request) }
        let started = Date()
        // Only the configured model identifier is read; multipart audio and all other fields are ignored.
        let json = request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true
            ? request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        let context = DiagnosticContext(videoID: scope.context.videoID, taskID: scope.context.taskID,
            revision: scope.context.revision, provider: provider, model: json?["model"] as? String)
        await scope.service.record(.init(.providerStarted, operation: scope.operation, operationID: scope.id, context: context))
        do {
            let response = try await base.data(for: request)
            await scope.service.record(.init(.providerFinished, operation: scope.operation, operationID: scope.id, context: context,
                elapsedSeconds: Date().timeIntervalSince(started), error: (200..<300).contains(response.statusCode) ? nil : .init(category: .provider, code: response.statusCode)))
            return response
        } catch {
            await scope.service.record(.init(.providerFinished, operation: scope.operation, operationID: scope.id, context: context,
                elapsedSeconds: Date().timeIntervalSince(started), error: DiagnosticFailure(error)))
            throw error
        }
    }
}
