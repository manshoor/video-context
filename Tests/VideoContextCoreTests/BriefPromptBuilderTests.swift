import Foundation
import Testing
@testable import VideoContextCore

struct BriefPromptBuilderTests {
    @Test("Final brief prompt requires provenance, evidence, and every requested section")
    func finalBriefPromptRequiresCompleteStructure() {
        let prompt = BriefPromptBuilder.finalPrompt(batchAnalyses: ["At 00:12 the user reports a payment error."])

        #expect(prompt.contains("Explicit statement"))
        #expect(prompt.contains("AI interpretation"))
        #expect(prompt.contains("[MM:SS]"))
        #expect(prompt.contains("## Goal and requested changes"))
        #expect(prompt.contains("## Reported problems and demonstrated behavior"))
        #expect(prompt.contains("## Ordered instructions or reproduction steps"))
        #expect(prompt.contains("## Expected results and constraints"))
        #expect(prompt.contains("## Ambiguities, contradictions, and unanswered questions"))
    }

    @Test("Batch prompt presents transcript in timestamp order")
    func batchPromptOrdersTranscript() throws {
        let transcript = [
            TranscriptSegment(videoID: "vid", start: 20, end: 22, originalText: "Second"),
            TranscriptSegment(videoID: "vid", start: 3, end: 5, originalText: "First")
        ]

        let prompt = BriefPromptBuilder.batchPrompt(transcript: transcript, evidence: [])

        let first = try #require(prompt.range(of: "[00:03] First"))
        let second = try #require(prompt.range(of: "[00:20] Second"))
        #expect(first.lowerBound < second.lowerBound)
    }
}
