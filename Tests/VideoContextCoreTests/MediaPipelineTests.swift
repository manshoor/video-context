import Foundation
import Testing
@testable import VideoContextCore

struct MediaPipelineTests {
    @Test("Retrieval paths do not create library directories")
    func readOnlyPathsDoNotWrite() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoContextReadOnlyPaths-\(UUID().uuidString)")

        let paths = try LibraryPaths(root: root, createDirectories: false)

        #expect(paths.root == root)
        #expect(FileManager.default.fileExists(atPath: paths.videos.path) == false)
    }

    @Test("Local import copies media into the library without changing the source")
    func localImportPreservesSource() throws {
        let fixture = try MediaFixture()
        let source = fixture.root.appending(path: "source.mp4")
        let original = Data("video bytes".utf8)
        try original.write(to: source)
        let paths = try LibraryPaths(root: fixture.library)

        let imported = try LocalMediaImporter(paths: paths).importFile(source, videoID: "vid_copy")

        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: imported) == original)
        #expect(imported.path.contains("vid_copy"))
        #expect(imported != source)
    }

    @Test("Loom and YouTube imports use a bounded yt-dlp command")
    func onlineImportCommandIsBounded() throws {
        let destination = URL(fileURLWithPath: "/tmp/video context/video.mp4")

        let command = try OnlineMediaImportCommand.make(
            source: URL(string: "https://www.loom.com/share/0123456789abcdef0123456789abcdef")!,
            destination: destination,
            executable: "/usr/local/bin/yt-dlp"
        )

        #expect(command.executable == "/usr/local/bin/yt-dlp")
        #expect(command.arguments == [
            "--no-playlist", "--merge-output-format", "mp4", "--output", destination.path,
            "https://www.loom.com/share/0123456789abcdef0123456789abcdef"
        ])
    }

    @Test("Unsafe online import schemes are rejected")
    func onlineImportRejectsUnsafeSchemes() {
        #expect(throws: MediaImportError.self) {
            _ = try OnlineMediaImportCommand.make(
                source: URL(string: "file:///private/video.mp4")!,
                destination: URL(fileURLWithPath: "/tmp/video.mp4"),
                executable: "/usr/local/bin/yt-dlp"
            )
        }
    }

    @Test("Whisper segments restore the chunk offset")
    func whisperSegmentsRestoreChunkOffset() throws {
        let response = Data(#"{"text":"Open settings","segments":[{"start":1.25,"end":4.5,"text":" Open settings "}]}"#.utf8)

        let segments = try OpenAIResponseDecoder.transcriptSegments(from: response, videoID: "vid_1", chunkStart: 600)

        #expect(segments.count == 1)
        #expect(segments[0].start == 601.25)
        #expect(segments[0].end == 604.5)
        #expect(segments[0].originalText == "Open settings")
    }

    @Test("Responses output text is found without depending on output ordering")
    func responseOutputTextIsDecoded() throws {
        let response = Data("{\"output\":[{\"type\":\"reasoning\",\"content\":[]},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"# Goal\\nFix checkout\"}]}]}".utf8)

        let text = try OpenAIResponseDecoder.outputText(from: response)

        #expect(text == "# Goal\nFix checkout")
    }

    @Test("Scene timestamps parse from ffmpeg diagnostics and deduplicate frames")
    func sceneTimestampsParseFromDiagnostics() {
        let output = """
            [Parsed_showinfo_1] n: 1 pts: 123 pts_time:12.34 duration:1
            [Parsed_showinfo_1] n: 2 pts: 130 pts_time:12.38 duration:1
            [Parsed_showinfo_1] n: 3 pts: 720 pts_time:72.00 duration:1
            """

        let timestamps = FFmpegOutputParser.sceneTimestamps(output, minimumSeparation: 1)

        #expect(timestamps == [12.34, 72])
    }

    @Test("Media inspection rejects a recording without audio")
    func mediaInspectionReadsStreams() throws {
        let response = Data(#"{"format":{"duration":"42.75"},"streams":[{"codec_type":"video"}]}"#.utf8)

        let inspection = try MediaInspection.decode(response)

        #expect(inspection.duration == 42.75)
        #expect(inspection.hasVideo)
        #expect(inspection.hasAudio == false)
    }

    @Test("Narrated instruction cues select timestamps with actionable language")
    func narratedInstructionCuesAreSelected() {
        let segments = [
            TranscriptSegment(videoID: "vid", start: 1, end: 2, originalText: "This is the account page"),
            TranscriptSegment(videoID: "vid", start: 8, end: 10, originalText: "Click the Billing button here"),
            TranscriptSegment(videoID: "vid", start: 20, end: 22, originalText: "The weather is warm")
        ]

        #expect(InstructionCueDetector.timestamps(in: segments) == [1, 8])
    }
}

private struct MediaFixture {
    let root: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoContextMediaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        library = root.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
