import Foundation
import Testing
@testable import VideoContextCore

struct LocalProviderTests {
    @Test func legacySettingsKeepOpenAIAndCustomModels() throws {
        let config = try JSONDecoder().decode(ModelConfiguration.self, from: Data(#"{"transcriptionModel":"whisper-custom","analysisModel":"analysis-custom"}"#.utf8))
        #expect(config.transcriptionProvider == .openAI)
        #expect(config.analysisProvider == .openAI)
        #expect(config.transcriptionModel == "whisper-custom")
        #expect(config.analysisModel == "analysis-custom")
    }

    @Test(arguments: ["https://example.com", "http://127.0.0.1.example.com", "http://user:pass@localhost:1234", "file:///tmp/test", "http://localhost:1234/v1?key=x"])
    func remoteEndpointsAreRejected(address: String) {
        #expect(throws: (any Error).self) { try LMStudioConfiguration(baseURL: address).validatedURL() }
    }

    @Test func localRequestsUseOnlyLocalCredentialsAndImages() throws {
        let request = try LMStudioRequestBuilder.analysis(configuration: .init(modelID: "vision"), token: "local-token", prompt: "Evidence", images: [Data([1, 2])])
        #expect(request.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("image_url"))
        #expect(body.contains("json_schema"))
        #expect(!body.contains("api.openai.com"))
        let payload = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(payload["reasoning_effort"] as? String == "none")
    }

    @Test func malformedOrTruncatedResponsesCannotPublish() {
        for json in [#"{"choices":[{"finish_reason":"length","message":{"content":"{\"markdown\":\"partial\"}"}}]}"#,
                     #"{"choices":[{"finish_reason":"stop","message":{"content":"not JSON"}}]}"#,
                     #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"markdown\":\" \"}"}}]}"#] {
            #expect(throws: (any Error).self) { try LMStudioResponseDecoder.markdown(Data(json.utf8)) }
        }
    }

    @Test func batchesCoverSpeechBetweenAndAfterFrames() {
        let transcript = (0..<200).map { TranscriptSegment(id: "seg_\($0)", videoID: "vid_a", start: Double($0 * 10), end: Double($0 * 10 + 5), originalText: "step \($0)") }
        let evidence = [0.0, 1_000].map { EvidenceItem(videoID: "vid_a", timestamp: $0, imageRelativePath: "x.jpg", origin: .automatic) }
        let batches = LocalAnalysisBatchPlanner.batches(transcript: transcript, evidence: evidence, textBudget: 2_000)
        #expect(Set(batches.flatMap(\.transcript).map(\.id)) == Set(transcript.map(\.id)))
        #expect(Set(batches.flatMap(\.evidence).map(\.id)) == Set(evidence.map(\.id)))
        #expect(batches.allSatisfy { $0.evidence.count <= 2 })
    }

    @Test func credentialsDependOnRemainingWork() {
        var config = ModelConfiguration()
        config.analysisProvider = .lmStudio
        #expect(config.requiresOpenAI(transcriptNeeded: true))
        #expect(!config.requiresOpenAI(transcriptNeeded: false))
        config.transcriptionProvider = .localWhisper
        #expect(!config.requiresOpenAI(transcriptNeeded: true))
        config.analysisProvider = .openAI
        #expect(config.requiresOpenAI(transcriptNeeded: false))
    }
}
