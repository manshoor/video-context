import Foundation
import VideoContextCore

struct MediaImportOperations: Sendable {
    var local: @Sendable (URL, String, LibraryPaths) async throws -> URL
    var online: @Sendable (URL, String, LibraryPaths, String) async throws -> URL

    static let live = Self(
        local: { source, id, paths in
            try await LocalMediaImporter(paths: paths).copyFile(source, videoID: id)
        },
        online: { source, id, paths, executable in
            try await OnlineMediaImporter(paths: paths, executable: executable, runner: ProcessRunner()).importURL(source, videoID: id)
        }
    )
}
