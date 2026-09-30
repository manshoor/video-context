import Foundation
import Testing
@testable import VideoContextCore

struct DiagnosticExportTests {
    private let secret = "SECRET_RECORDING_CONTENT_sk-abcdefghijklmnopqrstuvwxyz"
    private func crash(_ secret: String, date: Date = .now) throws -> Data {
        let header: [String: Any] = ["bundleID": "app.videocontext.mac", "timestamp": date.ISO8601Format(), "app_version": "1.0.0", "build_version": "5"]
        let body: [String: Any] = ["procName": "VideoContext", "procPath": "/Users/private/\(secret)",
            "exception": ["type": "EXC_CRASH", "message": secret],
            "usedImages": [["uuid": UUID().uuidString, "path": secret]],
            "threads": [["triggered": true, "frames": [["imageIndex": 0, "imageOffset": 42, "symbol": secret]]]]]
        var data = try JSONSerialization.data(withJSONObject: header); data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: body)); return data
    }
    @Test func exportScopesMetadataAndOmitsContentUnlessRawReportsSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostic-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let store = try VideoContextStore(databaseURL: paths.database)
        let first = VideoRecord(title: secret, source: .localFile, sourceValue: secret, mediaRelativePath: secret)
        let second = VideoRecord(title: secret, source: .onlineURL, sourceValue: secret, mediaRelativePath: secret)
        for video in [first, second] {
            try await store.createVideo(video)
            try await store.replaceTranscript(videoID: video.id, segments: [.init(videoID: video.id, start: 0, end: 1, originalText: secret)])
        }
        let service = DiagnosticsService.library(paths, component: .app)
        _ = try await service.enable()
        for video in [first, second] {
            await service.record(.init(.failed, operation: .processing, context: .init(videoID: video.id), error: DiagnosticFailure(MediaImportError.copyFailed(secret))))
        }
        try await service.stop() // Export is available after capture ends.
        let crashes = root.appending(path: "crashes")
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        try crash(secret).write(to: crashes.appending(path: "VideoContext-fixture.ips"))
        let exporter = DiagnosticExporter(service: service, store: store, crashDirectory: crashes)
        for full in [false, true] {
            let zip = root.appending(path: "export-\(full).zip")
            let result = try await exporter.export(to: zip, options: .init(videoID: first.id, includeFullCrashReports: full))
            #expect(result.eventCount == 2) // App-wide capture event and only the selected recording.
            #expect(result.omissions.isEmpty)
            let inventory = try await ProcessRunner().run(.init(executable: "/usr/bin/unzip", arguments: ["-Z1", zip.path]))
            #expect(inventory.status == 0)
            #expect(!inventory.text.contains("/._"))
            #expect(!inventory.text.contains("__MACOSX"))
            let extracted = root.appending(path: "extracted-\(full)")
            let output = try await ProcessRunner().run(.init(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, extracted.path]))
            #expect(output.status == 0)
            let folder = extracted.appending(path: "VideoContext-diagnostics")
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let text = try String(contentsOf: file, encoding: .utf8)
                if file.pathExtension == "ips" { #expect(full); #expect(text.contains(secret)) }
                else { #expect(!text.contains(secret)); #expect(!text.contains(second.id)) }
            }
            let metadata = try JSONDecoder().decode([DiagnosticRecordingMetadata].self, from: Data(contentsOf: folder.appending(path: "recordings.json")))
            #expect(metadata.count == 1)
            #expect(metadata.first?.transcriptSegments == 1)
            let summaries = try DiagnosticsService.decoder.decode([DiagnosticCrashSummary].self, from: Data(contentsOf: folder.appending(path: "crash-summaries.json")))
            #expect(summaries.first?.frames.first?.imageOffset == 42)
            #expect(summaries.first?.build == "5")
            #expect(summaries.first?.applicationWide == true)
        }
    }
    @Test func cancellationPreservesExistingDestinationAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostic-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let destination = root.appending(path: "existing.zip")
        try Data("original".utf8).write(to: destination)
        let exporter = DiagnosticExporter(service: .library(paths, component: .app), store: nil, crashDirectory: root)
        let job = Task {
            try await exporter.export(to: destination, options: .init()) { stage in
                if stage == .archive { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }
    @Test func unavailableComponentsProduceManifestOmissions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostic-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let exporter = DiagnosticExporter(service: .library(paths, component: .app), store: nil, crashDirectory: root.appending(path: "missing"))
        let result = try await exporter.export(to: root.appending(path: "report.zip"), options: .init())
        #expect(result.eventCount == 0)
        #expect(result.omissions.count == 2)
    }
    @Test func crashParserRejectsOtherAppsAndSanitizesUnexpectedFields() throws {
        #expect(DiagnosticCrashSummary.parse(try crash(secret))?.exception == "EXC_CRASH")
        var text = String(decoding: try crash(secret), as: UTF8.self)
        text = text.replacingOccurrences(of: "app.videocontext.mac", with: "other.app")
        #expect(DiagnosticCrashSummary.parse(Data(text.utf8)) == nil)
    }
}
