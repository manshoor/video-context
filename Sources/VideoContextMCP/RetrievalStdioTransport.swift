import Foundation
import Logging
import MCP

/// The SDK currently decodes client experimental capabilities as [String: String].
/// Clients may advertise object-valued extensions, which this retrieval server does not use.
actor RetrievalStdioTransport: Transport {
    private let base = StdioTransport()
    nonisolated var logger: Logger { base.logger }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let forwarding = Task {
                do {
                    for try await data in await base.receive() {
                        try Task.checkCancellation()
                        continuation.yield(Self.supportedInitialization(data))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in forwarding.cancel() }
        }
    }

    private static func supportedInitialization(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              capabilities["experimental"] != nil else { return data }
        // No experimental client capability is consumed or advertised by Video Context.
        // Keep all ordinary capabilities and all tool-call arguments unchanged.
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities; request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? data
    }
}
