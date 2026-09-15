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
}
