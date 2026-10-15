import Foundation
import ImageIO
import Testing
@testable import VideoContextCore

struct VideoFrameProviderTests {
    @Test("Normalized crops accept valid regions and reject out-of-bounds rectangles")
    func cropValidation() throws {
        let crop = try NormalizedCrop(x: 0.1, y: 0.2, width: 0.4, height: 0.5)

        #expect(crop.x == 0.1)
        #expect(crop.y == 0.2)
        #expect(throws: VideoFrameError.self) {
            _ = try NormalizedCrop(x: 0.8, y: 0.2, width: 0.4, height: 0.5)
        }
        #expect(throws: VideoFrameError.self) {
            _ = try NormalizedCrop(x: 0.1, y: 0.2, width: 0, height: 0.5)
        }
    }

    @Test("A real MP4 can be inspected and cropped at a timestamp")
    func realMP4FrameExtraction() async throws {
        let videoURL = FileManager.default.temporaryDirectory
            .appending(path: "video-context-frame-\(UUID().uuidString).mp4")
        let output = try await ProcessRunner().run(ProcessCommand(
            executable: "/opt/homebrew/bin/ffmpeg",
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "color=c=blue:s=320x180:d=2",
                "-f", "lavfi", "-i", "sine=frequency=1000:duration=2",
                "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                videoURL.path
            ]
        ))
        #expect(output.status == 0)

        let media = FFmpegMediaProcessor(toolchain: .init(), runner: ProcessRunner())
        let inspection = try await media.inspect(videoURL)
        let frame = try await VideoFrameProvider().frame(
            videoURL: videoURL,
            timestamp: 1,
            crop: NormalizedCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        )
        let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])

        #expect(inspection.hasVideo)
        #expect(inspection.hasAudio)
        #expect(inspection.duration >= 1.9)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 160)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 90)
    }

    @Test("Actual timestamp is the recording time of the returned frame")
    func actualTimestampMatchesReturnedFrame() async throws {
        // 10 fps: a 1.25 s request returns the next frame, at 1.3 s. The
        // second file's container starts at 10 s; times stay recording-relative.
        let directory = FileManager.default.temporaryDirectory.appending(path: "video-context-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let videoURL = directory.appending(path: "frames.mp4")
        let offsetURL = directory.appending(path: "offset.mp4")
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        let encoded = try await ProcessRunner().run(ProcessCommand(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=s=160x120:d=5:r=10",
            "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", videoURL.path
        ]))
        #expect(encoded.status == 0)
        let shifted = try await ProcessRunner().run(ProcessCommand(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-i", videoURL.path,
            "-c", "copy", "-output_ts_offset", "10", offsetURL.path
        ]))
        #expect(shifted.status == 0)

        let provider = VideoFrameProvider()
        for (url, requested, expected) in [(videoURL, 1.25, 1.3), (videoURL, 0.0, 0.0), (offsetURL, 1.25, 1.3)] {
            let frame = try await provider.frame(videoURL: url, timestamp: requested)
            #expect(abs(frame.actualTimestamp - expected) < 0.001, "requested \(requested) in \(url.lastPathComponent)")
        }
    }
}
