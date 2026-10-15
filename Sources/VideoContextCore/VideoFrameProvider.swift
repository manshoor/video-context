import Foundation

public struct NormalizedCrop: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw VideoFrameError.invalidCrop
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct VideoFrame: Sendable {
    public let data: Data
    public let mimeType: String
    public let actualTimestamp: TimeInterval

    public init(data: Data, mimeType: String, actualTimestamp: TimeInterval) {
        self.data = data
        self.mimeType = mimeType
        self.actualTimestamp = actualTimestamp
    }
}

public enum VideoFrameError: Error, LocalizedError, Equatable {
    case invalidCrop
    case invalidTimestamp
    case frameUnavailable
    case dependencyMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCrop:
            "Crop coordinates must describe a positive rectangle inside the image, using values from 0 through 1."
        case .invalidTimestamp:
            "The requested timestamp is outside the recording."
        case .frameUnavailable:
            "A video frame is not available at the requested timestamp."
        case .dependencyMissing(let path):
            "ffmpeg is not executable at \(path)."
        }
    }
}

public struct VideoFrameProvider: Sendable {
    private let ffmpegPath: String

    public init(ffmpegPath: String = "/opt/homebrew/bin/ffmpeg") {
        self.ffmpegPath = ffmpegPath
    }

    public func frame(
        videoURL: URL,
        timestamp: TimeInterval,
        crop: NormalizedCrop? = nil
    ) async throws -> VideoFrame {
        guard timestamp >= 0 else { throw VideoFrameError.invalidTimestamp }

        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw VideoFrameError.dependencyMissing(ffmpegPath)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "video-context-frame-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        // Seek on the input so showinfo sees only the returned frame. Its
        // pts_time is then the offset from the requested time, e.g. 0.05 for
        // a 1.25 s request that lands on the 1.3 s frame. Output seeking made
        // showinfo report the recording's first frame, always 0.
        var arguments = [
            "-hide_banner", "-loglevel", "info", "-y",
            "-ss", String(format: "%.3f", timestamp),
            "-i", videoURL.path,
            "-frames:v", "1"
        ]
        if let crop {
            arguments.append(contentsOf: [
                "-vf",
                "crop=iw*\(crop.width):ih*\(crop.height):iw*\(crop.x):ih*\(crop.y),showinfo"
            ])
        } else {
            arguments.append(contentsOf: ["-vf", "showinfo"])
        }
        arguments.append(contentsOf: ["-q:v", "2", outputURL.path])

        let output = try await ProcessRunner().run(ProcessCommand(executable: ffmpegPath, arguments: arguments))
        guard output.status == 0,
              let data = try? Data(contentsOf: outputURL),
              data.isEmpty == false else {
            throw VideoFrameError.frameUnavailable
        }
        return VideoFrame(
            data: data,
            mimeType: "image/jpeg",
            actualTimestamp: timestamp + (FFmpegOutputParser.firstFrameTimestamp(output.text) ?? 0)
        )
    }
}
