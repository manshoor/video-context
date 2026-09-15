import Foundation

public enum MediaImportError: Error, LocalizedError, Equatable {
    case unsupportedFile
    case unsupportedURL
    case copyFailed(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Select an MP4 video file."
        case .unsupportedURL: "Use an HTTP or HTTPS video link. If access is blocked, download the MP4 and import it instead."
        case .copyFailed(let message): "The video could not be copied: \(message)"
        case .downloadFailed(let message): "The video link could not be imported: \(message). Download the MP4 and import it instead."
        }
    }
}

public struct LocalMediaImporter: Sendable {
    private let paths: LibraryPaths

    public init(paths: LibraryPaths) {
        self.paths = paths
    }

    @concurrent
    public func copyFile(_ source: URL, videoID: String) async throws -> URL {
        try Task.checkCancellation()
        // Return a finished copy even if cancellation arrived during copyItem.
        // The app must register it before deciding whether to start processing.
        return try importFile(source, videoID: videoID)
    }

    public func importFile(_ source: URL, videoID: String) throws -> URL {
        guard source.pathExtension.lowercased() == "mp4" else { throw MediaImportError.unsupportedFile }
        let destination = try paths.videoDirectory(id: videoID).appending(path: "video.mp4")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                return destination
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            throw MediaImportError.copyFailed(error.localizedDescription)
        }
    }
}

public enum OnlineMediaImportCommand {
    public static func make(source: URL, destination: URL, executable: String) throws -> ProcessCommand {
        guard let scheme = source.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MediaImportError.unsupportedURL
        }
        return ProcessCommand(
            executable: executable,
            arguments: [
                "--no-playlist",
                "--merge-output-format", "mp4",
                "--output", destination.path,
                source.absoluteString
            ]
        )
    }
}

public struct OnlineMediaImporter<Runner: CommandRunning>: Sendable {
    private let paths: LibraryPaths
    private let executable: String
    private let runner: Runner

    public init(paths: LibraryPaths, executable: String, runner: Runner) {
        self.paths = paths
        self.executable = executable
        self.runner = runner
    }

    public func importURL(_ source: URL, videoID: String) async throws -> URL {
        let destination = try paths.videoDirectory(id: videoID).appending(path: "video.mp4")
        let command = try OnlineMediaImportCommand.make(source: source, destination: destination, executable: executable)
        let output = try await runner.run(command)
        guard output.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw MediaImportError.downloadFailed(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return destination
    }
}
