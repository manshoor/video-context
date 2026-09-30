import Foundation

/// Provider-specific wire formats share the same validated, content-only result.
public enum AnalysisAdapter {
    public static var markdownSchema: [String: Any] { ["type": "object", "properties": ["markdown": ["type": "string"]], "required": ["markdown"], "additionalProperties": false] }

    public static func request(configuration: ModelConfiguration, credential: String, prompt: String, images: [Data],
                               schema: [String: Any] = markdownSchema, name: String = "video_context_analysis",
                               instructions: String? = nil, maxTokens: Int = 4096) throws -> URLRequest {
        let provider = configuration.analysisProvider, model = configuration.selectedAnalysisModel
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalProviderError.configuration("Choose a \(provider.label) model in Settings.") }
        guard provider == .lmStudio || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalProviderError.configuration("Unlock or enter the \(provider.label) API key in Settings.") }
        if provider == .deepSeek, !["deepseek-flash", "deepseek-v4-flash-vision-exp"].contains(model) {
            throw LocalProviderError.configuration("Choose DeepSeek’s vision-capable deepseek-flash model for video context. Text-only models cannot inspect screenshot evidence.")
        }
        let request: URLRequest
        switch provider {
        case .openAI:
            request = try OpenAIRequestBuilder.analysis(apiKey: credential, model: model, prompt: prompt, images: images)
        case .lmStudio:
            request = try LMStudioRequestBuilder.analysis(configuration: configuration.lmStudio, token: credential, prompt: prompt, images: images, maxTokens: maxTokens)
        case .claude, .deepSeek:
            var new = URLRequest(url: URL(string: provider == .claude ? "https://api.anthropic.com/v1/messages" : "https://api.deepseek.com/chat/completions")!)
            new.httpMethod = "POST"; new.timeoutInterval = 600
            new.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            if provider == .claude {
                new.setValue(credential, forHTTPHeaderField: "x-api-key")
                new.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                content += images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]] }
            } else {
                new.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                content += images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]] }
            }
            new.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "max_tokens": maxTokens, "stream": false, "messages": [["role": "user", "content": content]]])
            request = new
        }
        var output = request
        var payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        switch provider {
        case .openAI:
            payload["text"] = ["format": ["type": "json_schema", "name": name, "strict": true, "schema": schema]]
            payload["max_output_tokens"] = maxTokens
            if let effort = configuration.reasoningEffort { payload["reasoning"] = ["effort": effort.rawValue] }
            if let instructions { payload["instructions"] = instructions }
        case .claude:
            payload["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
            if let effort = configuration.reasoningEffort {
                guard [.low, .medium, .high, .max].contains(effort) else {
                    throw LocalProviderError.configuration("Claude supports low, medium, high, or max reasoning effort.")
                }
                payload["output_config"] = ["effort": effort.rawValue, "format": ["type": "json_schema", "schema": schema]]
            }
            if let instructions { payload["system"] = instructions }
        case .deepSeek, .lmStudio:
            if configuration.reasoningEffort != nil {
                throw LocalProviderError.configuration("\(provider.label) does not support configurable reasoning effort.")
            }
            let system: String?
            if provider == .deepSeek {
                payload["response_format"] = ["type": "json_object"]
                payload["thinking"] = ["type": "disabled"]
                let jsonSchema = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: .sortedKeys), as: UTF8.self)
                system = (instructions ?? "") + "\nReturn only JSON matching this schema: " + jsonSchema
            } else {
                payload["response_format"] = ["type": "json_schema", "json_schema": ["name": name, "strict": true, "schema": schema]]
                system = instructions
                if name.hasPrefix("video_context_task") { payload["temperature"] = 0.7 }
            }
            if let system, let messages = payload["messages"] as? [[String: Any]] {
                payload["messages"] = [["role": "system", "content": system]] + messages
            }
        }
        output.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return output
    }

    public static func output(_ response: HTTPResult, provider: AnalysisProvider) throws -> String {
        guard (200..<300).contains(response.statusCode) else {
            let message = OpenAIResponseDecoder.errorMessage(from: response.data) ?? "HTTP \(response.statusCode)"
            if response.statusCode == 413 || ([400, 422].contains(response.statusCode) && message.lowercased().contains("context")) { throw LocalProviderError.contextLength }
            throw LocalProviderError.unavailable("\(provider.label) request failed (HTTP \(response.statusCode)). Check your model, credentials, and provider availability.")
        }
        guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw LocalProviderError.invalidOutput }
        let text: String
        switch provider {
        case .openAI:
            guard root["status"] as? String == "completed" else { throw LocalProviderError.truncated }
            text = try OpenAIResponseDecoder.outputText(from: response.data)
        case .claude:
            if root["stop_reason"] as? String == "max_tokens" { throw LocalProviderError.truncated }
            guard root["stop_reason"] as? String == "end_turn", let blocks = root["content"] as? [[String: Any]] else { throw LocalProviderError.invalidOutput }
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .lmStudio, .deepSeek:
            guard let choice = (root["choices"] as? [[String: Any]])?.first else { throw LocalProviderError.invalidOutput }
            if choice["finish_reason"] as? String == "length" { throw LocalProviderError.truncated }
            guard choice["finish_reason"] as? String == "stop", let message = choice["message"] as? [String: Any], let content = message["content"] as? String else { throw LocalProviderError.invalidOutput }
            text = content
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalProviderError.invalidOutput }
        return text
    }

    public static func markdown(_ response: HTTPResult, provider: AnalysisProvider) throws -> String {
        let text = try output(response, provider: provider)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], Set(object.keys) == ["markdown"],
              let markdown = object["markdown"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalProviderError.invalidOutput }
        return markdown
    }
}
