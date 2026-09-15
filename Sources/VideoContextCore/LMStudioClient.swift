import Foundation

public struct LMStudioModel: Decodable, Equatable, Sendable, Identifiable {
    public let key: String
    public let displayName: String
    public let type: String
    public let format: String?
    public let capabilities: Capabilities?
    public let loadedInstances: [Instance]
    public var id: String { key }
    public var supportsVision: Bool { type == "llm" && capabilities?.vision == true }
    public struct Capabilities: Decodable, Equatable, Sendable { public let vision: Bool? }
    public struct Instance: Decodable, Equatable, Sendable {
        public let id: String
        public let config: Configuration
        public struct Configuration: Decodable, Equatable, Sendable {
            public let contextLength: Int
            enum CodingKeys: String, CodingKey { case contextLength = "context_length" }
        }
    }
    enum CodingKeys: String, CodingKey {
        case key, type, capabilities, format
        case displayName = "display_name", loadedInstances = "loaded_instances"
    }
}

public enum LMStudioRequestBuilder {
    public static func models(configuration: LMStudioConfiguration, token: String) throws -> URLRequest {
        try request(configuration: configuration, path: "api/v1/models", token: token)
    }

    public static func analysis(configuration: LMStudioConfiguration, token: String, prompt: String, images: [Data], maxTokens: Int = 4096) throws -> URLRequest {
        guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalProviderError.configuration("Choose a loaded vision model in Settings.")
        }
        var request = try request(configuration: configuration, path: "v1/chat/completions", token: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        content += images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.modelID,
            "messages": [["role": "user", "content": content]],
            "stream": false, "max_tokens": maxTokens,
            // MLX reasoning models can route schema-constrained JSON into reasoning_content.
            // Request a final structured answer; never publish a reasoning trace as evidence.
            "reasoning_effort": "none",
            "response_format": ["type": "json_schema", "json_schema": [
                "name": "video_context_analysis", "strict": true,
                "schema": ["type": "object", "properties": ["markdown": ["type": "string"]], "required": ["markdown"], "additionalProperties": false]
            ]]
        ])
        return request
    }

    private static func request(configuration: LMStudioConfiguration, path: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: try configuration.validatedURL().appending(path: path))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

public enum LMStudioResponseDecoder {
    public static func markdown(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first else { throw LocalProviderError.invalidOutput }
        if choice["finish_reason"] as? String == "length" { throw LocalProviderError.truncated }
        guard choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any], let content = message["content"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              object.count == 1, let markdown = object["markdown"] as? String,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalProviderError.invalidOutput }
        return markdown
    }

    public static func validate(_ response: HTTPResult) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = OpenAIResponseDecoder.errorMessage(from: response.data) ?? "HTTP \(response.statusCode)"
            if [400, 413, 422].contains(response.statusCode), message.lowercased().contains("context") || response.statusCode == 413 {
                throw LocalProviderError.contextLength
            }
            throw LocalProviderError.unavailable("LM Studio request failed: \(message). Check the server, loaded vision model, and optional token in Settings.")
        }
    }
}

public struct LMStudioService<Client: HTTPDataLoading>: Sendable {
    public let client: Client
    public init(client: Client) { self.client = client }
    public func models(configuration: LMStudioConfiguration, token: String) async throws -> [LMStudioModel] {
        let response = try await client.data(for: LMStudioRequestBuilder.models(configuration: configuration, token: token))
        try LMStudioResponseDecoder.validate(response)
        return try JSONDecoder().decode(LMStudioModelsResponse.self, from: response.data).models
    }
    public func loadedModel(configuration: LMStudioConfiguration, token: String) async throws -> LMStudioModel.Instance {
        let models = try await models(configuration: configuration, token: token)
        guard let model = models.first(where: { $0.key == configuration.modelID || $0.loadedInstances.contains(where: { $0.id == configuration.modelID }) }), model.supportsVision else {
            throw LocalProviderError.configuration("Select a vision model in Settings. Text-only and embedding models cannot analyze screenshots.")
        }
        guard ["gguf", "mlx"].contains(model.format?.lowercased() ?? "") else {
            throw LocalProviderError.configuration("Choose a locally downloaded GGUF or MLX vision model. Cloud model routing is not supported by local mode.")
        }
        guard let instance = model.loadedInstances.first(where: { $0.id == configuration.modelID }) ?? model.loadedInstances.first else {
            throw LocalProviderError.configuration("Load \(model.displayName) in LM Studio, then refresh models in Settings.")
        }
        guard instance.config.contextLength >= 16_384 else {
            throw LocalProviderError.configuration("Load the LM Studio model with at least 16K context; 32K is recommended.")
        }
        return instance
    }
}

/// Redirects are rejected so local recording content and tokens cannot leave loopback.
public final class LoopbackHTTPClient: NSObject, HTTPDataLoading, URLSessionTaskDelegate, Sendable {
    public func data(for request: URLRequest) async throws -> HTTPResult {
        guard let url = request.url, let host = url.host(), ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host.lowercased()) else {
            throw LocalProviderError.configuration("LM Studio requests must stay on this Mac.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw LocalProviderError.invalidOutput }
            return HTTPResult(data: data, statusCode: http.statusCode)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LocalProviderError.unavailable("Cannot reach LM Studio: \(error.localizedDescription). Start its local server in the Developer tab and load a vision model.")
        }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct LMStudioModelsResponse: Decodable { let models: [LMStudioModel] }

public struct AnyHTTPDataLoader: HTTPDataLoading {
    private let base: any HTTPDataLoading
    public init(_ base: any HTTPDataLoading) { self.base = base }
    public func data(for request: URLRequest) async throws -> HTTPResult { try await base.data(for: request) }
}
