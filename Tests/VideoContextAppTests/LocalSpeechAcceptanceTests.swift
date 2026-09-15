import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

/// Opt-in acceptance only. The normal suite never downloads models or reads personal media.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VIDEO_CONTEXT_LOCAL_SPEECH_ACCEPTANCE"] == "1"), .timeLimit(.minutes(15)))
struct LocalSpeechAcceptanceTests {
    @Test func realSpeechUsesCachedModelsAndRestoresRecordingOffsets() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["VIDEO_CONTEXT_ACCEPTANCE_ROOT"]))
        let source = try #require(environment["VIDEO_CONTEXT_ACCEPTANCE_MEDIA"])
        let manager = SpeechModelManager(root: root.appending(path: "models"))
        if (try? await manager.installedAssets()) == nil {
            guard environment["VIDEO_CONTEXT_DOWNLOAD_SPEECH_MODEL"] == "1" else {
                throw LocalProviderError.configuration("Explicit model download is required for this acceptance run.")
            }
            try await manager.download { _ in }
        }
        let assets = try await manager.installedAssets()
        let audio = root.appending(path: "sample.m4a")
        _ = try await ProcessRunner().run(ProcessCommand(executable: "/opt/homebrew/bin/ffmpeg", arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-i", source, "-t", "25", "-vn", "-ac", "1", "-c:a", "aac", audio.path
        ]))
        let worker = LocalWhisperTranscriber(assets: assets)
        let segments = try await worker.transcribe(audioURL: audio, videoID: "vid_local_speech_acceptance", chunkStart: 600)
        await worker.releaseResources()
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.start >= 600 && $0.end >= $0.start && $0.end <= 626 })
        #expect(segments.map(\.text).joined(separator: " ").lowercased().contains("calendar"))
    }
}
