import Foundation
import Testing
@testable import VideoContextCore

struct ProcessingAlgorithmsTests {
    @Test("Audio chunks use nearby silence and stay below the upload budget")
    func audioChunksUseSilenceAndStayBounded() throws {
        let planner = AudioChunkPlanner(maxDuration: 600, overlap: 2, silenceSearchRadius: 30)

        let chunks = try planner.plan(duration: 1_250, silencePoints: [590, 1_190])

        #expect(chunks == [
            AudioChunk(index: 0, start: 0, end: 592, contentStart: 0),
            AudioChunk(index: 1, start: 588, end: 1_192, contentStart: 590),
            AudioChunk(index: 2, start: 1_188, end: 1_250, contentStart: 1_190)
        ])
        #expect(chunks.allSatisfy { $0.duration <= 604 })
    }

    @Test("Invalid chunk planning inputs are rejected")
    func invalidChunkInputsAreRejected() {
        #expect(throws: AudioChunkPlanningError.self) {
            _ = try AudioChunkPlanner(maxDuration: 0, overlap: 2).plan(duration: 20)
        }
        #expect(throws: AudioChunkPlanningError.self) {
            _ = try AudioChunkPlanner(maxDuration: 60, overlap: 60).plan(duration: 20)
        }
    }

    @Test("Chunk transcripts restore recording time and remove overlap duplicates")
    func transcriptMergeRestoresTimeAndDeduplicates() {
        let chunks = [
            ChunkTranscript(chunkStart: 0, segments: [
                TranscriptSlice(start: 0, end: 4, text: "Open settings"),
                TranscriptSlice(start: 4, end: 9, text: "Choose billing")
            ]),
            ChunkTranscript(chunkStart: 7, segments: [
                TranscriptSlice(start: 0, end: 2, text: "Choose billing"),
                TranscriptSlice(start: 2, end: 7, text: "Change the plan")
            ])
        ]

        let merged = TranscriptMerger.merge(chunks)

        #expect(merged == [
            TranscriptSlice(start: 0, end: 4, text: "Open settings"),
            TranscriptSlice(start: 4, end: 9, text: "Choose billing"),
            TranscriptSlice(start: 9, end: 14, text: "Change the plan")
        ])
    }

    @Test("Screenshot planning combines periodic and narrated evidence without near duplicates")
    func screenshotPlanningCombinesSignals() {
        let planner = ScreenshotPlanner(periodicInterval: 30, minimumSeparation: 2)

        let timestamps = planner.timestamps(
            duration: 95,
            sceneChanges: [12, 30.6, 72],
            transcriptCues: [11.5, 45, 94]
        )

        #expect(timestamps == [0, 11.5, 30, 45, 60, 72, 90, 94])
    }
}
