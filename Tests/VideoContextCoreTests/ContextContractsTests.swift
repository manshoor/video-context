import Foundation
import Testing
@testable import VideoContextCore

struct ContextContractsTests {
    @Test("Pagination cursor round trips and rejects malformed values")
    func cursorRoundTrip() {
        let encoded = PaginationCursor(offset: 40).encoded

        #expect(PaginationCursor(encoded: encoded)?.offset == 40)
        #expect(PaginationCursor(encoded: "not a cursor") == nil)
    }

    @Test("Transcript corrections advance the revision and stale the generated brief")
    func transcriptCorrectionInvalidatesBrief() {
        let current = ArtifactRevision(transcript: 3, evidence: 2, brief: 3, briefSourceTranscript: 3, briefSourceEvidence: 2)

        let corrected = current.afterTranscriptCorrection()

        #expect(corrected.transcript == 4)
        #expect(corrected.brief == 3)
        #expect(corrected.isBriefStale)
    }

    @Test("A regenerated brief records its exact source revisions")
    func regeneratedBriefBecomesCurrent() {
        let stale = ArtifactRevision(transcript: 4, evidence: 5, brief: 2, briefSourceTranscript: 3, briefSourceEvidence: 4)

        let current = stale.afterBriefRegeneration()

        #expect(current.brief == 3)
        #expect(current.briefSourceTranscript == 4)
        #expect(current.briefSourceEvidence == 5)
        #expect(current.isBriefStale == false)
    }

    @Test("Context message includes recording metadata and exact MCP instructions")
    func contextMessageContainsRequiredContext() {
        let video = VideoRecord(
            id: "vid_01HXYZ",
            title: "Checkout walkthrough",
            source: .localFile,
            sourceValue: "checkout.mp4",
            mediaRelativePath: "videos/vid_01HXYZ/video.mp4",
            status: .ready
        )

        let message = AgentHandoff.message(video: video, state: .ready)

        #expect(message == """
        I’ve recorded a walkthrough for this task in Video Context. Use the `video-context` MCP server to understand the requested changes and inspect the supporting evidence.

        **Recording:** Checkout walkthrough  
        **Context ID:** `vid_01HXYZ`  
        **Status when copied:** Ready

        Start by calling `get_video_brief` with `video_id="vid_01HXYZ"`. Then use `search_video`, `get_video_segment`, and `get_video_frame` with that same ID to inspect relevant transcript passages and screenshots. Follow continuation cursors when present.

        Keep this task scoped to this exact Context ID. Do not call `list_videos`, search by title to choose another recording, or switch recordings unless I explicitly ask.

        If processing is incomplete or the brief is stale, clearly identify what is missing and use available evidence cautiously. Report unavailable evidence instead of guessing. Check the evidence before implementing changes.

        If the MCP tools are unavailable, ask me to connect the Video Context MCP server.
        """)
    }

    @Test("Context status distinguishes active, paused, failed, ready, and stale recordings")
    func contextStatusDistinguishesProcessingStates() {
        #expect(AgentHandoffState.active(stage: .recognizingText, completed: 12, total: 29, elapsedSeconds: 8).description == "Processing: Reading screen text (12 of 29, 8s elapsed)")
        #expect(AgentHandoffState.paused(stage: .recognizingText).description == "Paused at Reading screen text")
        #expect(AgentHandoffState.failed(message: "Provider unavailable").description == "Failed: Provider unavailable")
        #expect(AgentHandoffState.ready.description == "Ready")
        #expect(AgentHandoffState.stale.description == "Ready with a stale coding brief")
    }

    @Test(
        "Context message reports its effective availability",
        arguments: [
            HandoffStatusCase(state: .ready, expected: "**Status when copied:** Ready"),
            HandoffStatusCase(state: .active(stage: .recognizingText, completed: 4, total: 10, elapsedSeconds: 3), expected: "**Status when copied:** Processing: Reading screen text (4 of 10, 3s elapsed)"),
            HandoffStatusCase(state: .paused(stage: .capturingFrames), expected: "**Status when copied:** Paused at Capturing frames"),
            HandoffStatusCase(state: .failed(message: "OCR failed"), expected: "**Status when copied:** Failed: OCR failed"),
            HandoffStatusCase(state: .stale, expected: "**Status when copied:** Ready with a stale coding brief")
        ]
    )
    func contextMessageReportsStatus(testCase: HandoffStatusCase) {
        let video = VideoRecord(
            id: "vid_status",
            title: "Status walkthrough",
            source: .localFile,
            sourceValue: "status.mp4",
            mediaRelativePath: "videos/vid_status/video.mp4"
        )

        let message = AgentHandoff.message(video: video, state: testCase.state)

        #expect(message.contains(testCase.expected))
    }

    @Test("Separate recordings receive distinct permanent Context IDs")
    func contextIDsAreUnique() {
        let first = VideoRecord(title: "Same title", source: .localFile, sourceValue: "first.mp4", mediaRelativePath: "first/video.mp4")
        let second = VideoRecord(title: "Same title", source: .localFile, sourceValue: "second.mp4", mediaRelativePath: "second/video.mp4")

        #expect(first.id.hasPrefix("vid_"))
        #expect(second.id.hasPrefix("vid_"))
        #expect(first.id != second.id)
    }
}

struct HandoffStatusCase: Sendable {
    let state: AgentHandoffState
    let expected: String
}
