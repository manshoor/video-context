import Foundation

public enum OpenAIRequestBuilder {
    public static func transcription(audioURL: URL, apiKey: String, model: String) throws -> URLRequest {
        let boundary = "VideoContext-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendFormField(name: "model", value: model, boundary: boundary)
        body.appendFormField(name: "response_format", value: "verbose_json", boundary: boundary)
        body.appendFormField(name: "timestamp_granularities[]", value: "segment", boundary: boundary)
        body.appendFile(name: "file", filename: audioURL.lastPathComponent, mimeType: "audio/mp4", data: try Data(contentsOf: audioURL), boundary: boundary)
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        request.timeoutInterval = 300
        return request
    }

    public static func analysis(apiKey: String, model: String, prompt: String, images: [Data], reasoningEffort: ReasoningEffort? = nil) throws -> URLRequest {
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        content.append(contentsOf: images.map {
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\($0.base64EncodedString())"]
        })
        var payload: [String: Any] = [
            "model": model,
            "input": [["role": "user", "content": content]],
            "text": ["format": [
                "type": "json_schema",
                "name": "video_context_analysis",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "markdown": [
                            "type": "string",
                            "description": "Evidence-based analysis or coding brief in Markdown"
                        ]
                    ],
                    "required": ["markdown"],
                    "additionalProperties": false
                ]
            ]]
        ]
        if let reasoningEffort { payload["reasoning"] = ["effort": reasoningEffort.rawValue] }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 300
        return request
    }
}

public struct HTTPResult: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResult
    func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult
}

public struct HTTPRedirectPolicy: Sendable {
    public let allowedHosts: Set<String>
    public let maximumBytes: Int?
    public init(allowedHosts: Set<String>, maximumBytes: Int? = nil) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.maximumBytes = maximumBytes
    }
    public func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
        url.host.map { allowedHosts.contains($0.lowercased()) } == true &&
        url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443)
    }
}

public enum HTTPRedirectError: Error, Sendable {
    case rejected
}

extension HTTPDataLoading {
    public func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult {
        throw HTTPRedirectError.rejected
    }
}

public struct APIUsageValues: Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let audioSeconds: Double?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, audioSeconds: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.audioSeconds = audioSeconds
    }
}

public enum APIUsageDecoder {
    public static func decode(_ data: Data) -> APIUsageValues {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            return APIUsageValues()
        }
        return APIUsageValues(
            inputTokens: ((usage["input_tokens"] ?? usage["prompt_tokens"]) as? NSNumber)?.intValue,
            outputTokens: ((usage["output_tokens"] ?? usage["completion_tokens"]) as? NSNumber)?.intValue,
            totalTokens: (usage["total_tokens"] as? NSNumber)?.intValue,
            audioSeconds: (usage["seconds"] as? NSNumber)?.doubleValue
        )
    }
}

public struct APIUsageRecordingClient<Base: HTTPDataLoading>: HTTPDataLoading, Sendable {
    private let base: Base
    private let store: VideoContextStore
    private let videoID: String
    private let transcriptionModel: String
    private let analysisModel: String
    private let provider: InferenceProvider

    public init(
        base: Base,
        store: VideoContextStore,
        videoID: String,
        transcriptionModel: String,
        analysisModel: String,
        provider: InferenceProvider = .openAI
    ) {
        self.provider = provider
        self.base = base
        self.store = store
        self.videoID = videoID
        self.transcriptionModel = transcriptionModel
        self.analysisModel = analysisModel
    }

    public func data(for request: URLRequest) async throws -> HTTPResult {
        let result = try await base.data(for: request)
        guard UsageTrace.session == nil, (200..<300).contains(result.statusCode) else { return result }
        let isTranscription = request.url?.path.contains("/audio/transcriptions") == true
        let values = APIUsageDecoder.decode(result.data)
        try? await store.recordAPIUsage(APIUsageRecord(
            videoID: videoID,
            stage: isTranscription ? .transcription : .analysis,
            model: isTranscription ? transcriptionModel : analysisModel,
            provider: provider,
            inputTokens: values.inputTokens,
            outputTokens: values.outputTokens,
            totalTokens: values.totalTokens,
            audioSeconds: values.audioSeconds
        ))
        return result
    }
}

public struct URLSessionHTTPClient: HTTPDataLoading {
    public init() {}

    public func data(for request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidHTTPResponse
        }
        return HTTPResult(data: data, statusCode: http.statusCode)
    }

    public func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult {
        guard let url = request.url, redirectPolicy.allows(url) else { throw HTTPRedirectError.rejected }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let delegate = GuardedHTTPRedirectDelegate(policy: redirectPolicy)
        defer { session.invalidateAndCancel() }
        do {
            let data: Data
            let response: URLResponse
            if let maximumBytes = redirectPolicy.maximumBytes {
                let (stream, received) = try await session.bytes(for: request, delegate: delegate)
                response = received
                var bounded = Data()
                bounded.reserveCapacity(min(maximumBytes, 64_000))
                for try await byte in stream {
                    guard bounded.count < maximumBytes else { throw HTTPResponseSizeError.exceeded }
                    bounded.append(byte)
                }
                data = bounded
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
            guard !delegate.didReject else { throw HTTPRedirectError.rejected }
            guard let http = response as? HTTPURLResponse,
                  let finalURL = http.url, redirectPolicy.allows(finalURL) else { throw HTTPRedirectError.rejected }
            return HTTPResult(data: data, statusCode: http.statusCode)
        } catch {
            if delegate.didReject { throw HTTPRedirectError.rejected }
            throw error
        }
    }
}

public enum HTTPResponseSizeError: Error, Sendable { case exceeded }

private final class GuardedHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: HTTPRedirectPolicy
    private let lock = NSLock()
    private var rejected = false
    init(policy: HTTPRedirectPolicy) { self.policy = policy }
    var didReject: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, policy.allows(url) else {
            lock.lock(); rejected = true; lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public enum OpenAIClientError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidHTTPResponse
    case provider(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Settings before processing."
        case .invalidHTTPResponse: "OpenAI returned an invalid HTTP response."
        case .provider(let status, let message): "OpenAI request failed (HTTP \(status)): \(message)"
        }
    }
}

public struct OpenAITranscriber<Client: HTTPDataLoading>: Transcribing, Sendable {
    private let client: Client
    private let apiKey: String
    private let model: String

    public init(client: Client, apiKey: String, model: String) {
        self.client = client
        self.apiKey = apiKey
        self.model = model
    }

    public func transcribe(audioURL: URL, videoID: String, chunkStart: TimeInterval) async throws -> [TranscriptSegment] {
        guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw OpenAIClientError.missingAPIKey
        }
        let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25_000_000 else { throw MediaProcessingError.fileTooLarge(Int64(size)) }
        let request = try OpenAIRequestBuilder.transcription(audioURL: audioURL, apiKey: apiKey, model: model)
        let response = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIClientError.provider(
                status: response.statusCode,
                message: OpenAIResponseDecoder.errorMessage(from: response.data) ?? "Unknown provider error"
            )
        }
        return try OpenAIResponseDecoder.transcriptSegments(from: response.data, videoID: videoID, chunkStart: chunkStart)
    }
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
