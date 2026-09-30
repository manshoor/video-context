import Foundation
import Testing
@testable import VideoContextCore

struct OpenAIClientTests {
    @Test("Brief generation reports every analysis batch and final assembly")
    func briefGenerationReportsProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextBriefProgress-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = try LibraryPaths(root: root)
        let frameDirectory = try paths.framesDirectory(id: "vid_progress")
        let first = frameDirectory.appending(path: "1.jpg")
        let second = frameDirectory.appending(path: "2.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: first)
        try Data([0xFF, 0xD8, 0xFF]).write(to: second)
        let recorder = AnalysisProgressRecorder()
        let generator = OpenAIBriefGenerator(
            client: SuccessfulAnalysisClient(),
            apiKey: "secret-key",
            model: "gpt-5.6-terra",
            evidenceBatchSize: 1
        )

        _ = try await generator.generate(
            videoID: "vid_progress",
            transcript: [],
            evidence: [
                EvidenceItem(videoID: "vid_progress", timestamp: 1, imageRelativePath: paths.relativePath(for: first), origin: .automatic),
                EvidenceItem(videoID: "vid_progress", timestamp: 2, imageRelativePath: paths.relativePath(for: second), origin: .automatic)
            ],
            paths: paths,
            progress: { await recorder.record($0) }
        )

        let progress = await recorder.values()
        #expect(progress.map(\.stage) == [.analyzing, .analyzing, .analyzing, .analyzing])
        #expect(progress.map(\.completed) == [0, 1, 2, 3])
        #expect(progress.allSatisfy { $0.total == 3 })
    }

    @Test("Transcription requests use Whisper verbose segments and authenticate")
    func transcriptionRequestCarriesRequiredFields() throws {
        let audio = FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audio)

        let request = try OpenAIRequestBuilder.transcription(
            audioURL: audio,
            apiKey: "secret-key",
            model: "whisper-1"
        )
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        #expect(body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(body.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment"))
    }

    @Test("Brief requests carry chronological text, images, and the configured model")
    func briefRequestCarriesEvidence() throws {
        let request = try OpenAIRequestBuilder.analysis(
            apiKey: "secret-key",
            model: "gpt-5.6-terra",
            prompt: "[00:05] Click Billing",
            images: [Data([0xFF, 0xD8, 0xFF])]
        )
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let text = try #require(object["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])

        #expect(object["model"] as? String == "gpt-5.6-terra")
        #expect(content.contains { $0["type"] as? String == "input_text" })
        #expect(content.contains { $0["type"] as? String == "input_image" })
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
    }

    @Test("Brief requests carry the configured reasoning effort")
    func briefRequestCarriesReasoningEffort() throws {
        let request = try OpenAIRequestBuilder.analysis(
            apiKey: "secret-key",
            model: "gpt-6-sol",
            prompt: "Evidence",
            images: [],
            reasoningEffort: .high
        )
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try #require(object["reasoning"] as? [String: Any])

        #expect(reasoning["effort"] as? String == "high")
    }

    @Test("Accuracy profile routes task, documentation, and review independently")
    func accuracyProfileRoutesAnalysisStages() throws {
        var configuration = ModelConfiguration(transcriptionModel: "whisper-1", analysisModel: "gpt-5.6-terra")
        configuration.applyAccuracyProfile()

        #expect(configuration.analysisProvider == .openAI)
        #expect(configuration.analysisModel == "gpt-6-sol")
        #expect(configuration.reasoningEffort == .high)
        #expect(configuration.taskConfiguration.selectedAnalysisModel == "gpt-6-astra")
        #expect(configuration.documentationConfiguration.selectedAnalysisModel == "gpt-6-astra")
        #expect(configuration.reviewConfiguration?.analysisProvider == .claude)
        #expect(configuration.reviewConfiguration?.selectedAnalysisModel == "claude-opus-5-5")
    }

    @Test("Claude requests preserve native reasoning effort")
    func claudeRequestCarriesReasoningEffort() throws {
        let configuration = ModelConfiguration(
            analysisProvider: .claude,
            claudeModel: "claude-opus-5-5",
            reasoningEffort: .high
        )
        let request = try AnalysisAdapter.request(configuration: configuration, credential: "secret-key", prompt: "Evidence", images: [])
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outputConfig = try #require(object["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "high")
    }

    @Test("Provider errors expose the API message")
    func providerErrorsExposeMessage() {
        let data = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)

        let message = OpenAIResponseDecoder.errorMessage(from: data)

        #expect(message == "Invalid API key")
    }

    @Test("Provider usage decodes audio seconds and response tokens")
    func providerUsageDecoding() throws {
        let transcription = Data(#"{"usage":{"type":"duration","seconds":91}}"#.utf8)
        let response = Data(#"{"usage":{"input_tokens":1200,"output_tokens":240,"total_tokens":1440}}"#.utf8)

        let audioUsage = APIUsageDecoder.decode(transcription)
        let tokenUsage = APIUsageDecoder.decode(response)

        #expect(audioUsage.audioSeconds == 91)
        #expect(tokenUsage.inputTokens == 1_200)
        #expect(tokenUsage.outputTokens == 240)
        #expect(tokenUsage.totalTokens == 1_440)
    }
}

private struct SuccessfulAnalysisClient: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult {
        HTTPResult(
            data: Data(#"{"output":[{"content":[{"type":"output_text","text":"{\"markdown\":\"Generated context\"}"}]}]}"#.utf8),
            statusCode: 200
        )
    }
}

private actor AnalysisProgressRecorder {
    private var recorded: [ProcessingProgress] = []

    func record(_ progress: ProcessingProgress) { recorded.append(progress) }
    func values() -> [ProcessingProgress] { recorded }
}
