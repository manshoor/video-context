import Foundation

public struct MediaToolchain: Codable, Equatable, Sendable {
    public var ytDLP: String
    public var ffmpeg: String
    public var ffprobe: String

    public init(
        ytDLP: String = "/usr/local/bin/yt-dlp",
        ffmpeg: String = "/opt/homebrew/bin/ffmpeg",
        ffprobe: String = "/opt/homebrew/bin/ffprobe"
    ) {
        self.ytDLP = ytDLP
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    public func missingDependencies(fileManager: FileManager = .default) -> [String] {
        [("yt-dlp", ytDLP), ("ffmpeg", ffmpeg), ("ffprobe", ffprobe)].compactMap { name, path in
            fileManager.isExecutableFile(atPath: path) ? nil : name
        }
    }
}
