import Foundation

public struct LibraryPaths: Sendable {
    public let root: URL
    public let database: URL
    public let videos: URL

    public init(root: URL, createDirectories: Bool = true) throws {
        self.root = root
        database = root.appending(path: "library.sqlite")
        videos = root.appending(path: "videos", directoryHint: .isDirectory)
        if createDirectories {
            try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        }
    }

    public static func applicationSupport(
        fileManager: FileManager = .default,
        createDirectories: Bool = true
    ) throws -> Self {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectories
        )
        return try Self(
            root: base.appending(path: "VideoContext", directoryHint: .isDirectory),
            createDirectories: createDirectories
        )
    }

    public func videoDirectory(id: String) throws -> URL {
        let directory = videos.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func framesDirectory(id: String) throws -> URL {
        let directory = try videoDirectory(id: id).appending(path: "frames", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func chunksDirectory(id: String) throws -> URL {
        let directory = try videoDirectory(id: id).appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func feedbackDirectory(id: String) throws -> URL {
        let directory = root.appending(path: "feedback", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func absoluteURL(relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    public func relativePath(for url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
