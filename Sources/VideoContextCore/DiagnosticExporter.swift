import Foundation

public struct DiagnosticExportOptions: Sendable {
    public let videoID: String?
    public let days: Int
    public let includeFullCrashReports: Bool
    public init(videoID: String? = nil, days: Int = 1, includeFullCrashReports: Bool = false) {
        self.videoID = videoID; self.days = min(7, max(1, days)); self.includeFullCrashReports = includeFullCrashReports
    }
}
public enum DiagnosticExportStage: String, Sendable { case logs, metadata, crashes, archive, finished }
public struct DiagnosticExportResult: Sendable { public let eventCount: Int; public let omissions: [String] }
private struct DiagnosticManifest: Encodable {
    let schemaVersion = 1
    let exportedAt: Date
    let since: Date
    let context: DiagnosticContext
    let allRecordings: Bool
    let build: String
    let osVersion: String
    let fullCrashReports: Bool
    let eventCount: Int
    let omissions: [String]
}

public actor DiagnosticExporter {
    private let service: DiagnosticsService
    private let store: VideoContextStore?
    private let crashDirectory: URL
    private let clock: @Sendable () -> Date
    public init(service: DiagnosticsService, store: VideoContextStore?, crashDirectory: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service; self.store = store; self.clock = clock
        self.crashDirectory = crashDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    }
    public func export(to destination: URL, options: DiagnosticExportOptions,
                       progress: (@Sendable (DiagnosticExportStage) async -> Void)? = nil) async throws -> DiagnosticExportResult {
        let now = clock(), since = now.addingTimeInterval(-Double(options.days) * 86_400)
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appending(path: "VideoContext-diagnostics-\(UUID())")
        let contents = temporary.appending(path: "VideoContext-diagnostics")
        try manager.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        var omissions: [String] = []
        await progress?(.logs); try Task.checkCancellation()
        var events: [DiagnosticEvent] = []
        do {
            let snapshot = try await service.snapshot(since: since, videoID: options.videoID)
            events = snapshot.events; omissions += snapshot.omissions
        }
        catch { omissions.append("Diagnostic logs could not be read.") }
        var lines = Data()
        for event in events { lines.append(try DiagnosticsService.encoder.encode(event)); lines.append(10) }
        try lines.write(to: contents.appending(path: "events.jsonl"))
        let timeline: String = events.map { event -> String in
            let e = event.entry
            return "\(event.timestamp.ISO8601Format()) [\(event.component.rawValue)] \(e.operation.rawValue) \(e.event.rawValue) context=\(e.context.videoID ?? "application") operation=\(e.operationID) stage=\(e.stage?.rawValue ?? "none") count=\(e.completed.map(String.init) ?? "?")/\(e.total.map(String.init) ?? "?") elapsed=\(e.elapsedSeconds.map { String(format: "%.1f", $0) } ?? "?")s error=\(e.error?.category.rawValue ?? "none")"
        }.joined(separator: "\n")
        try Data(timeline.utf8).write(to: contents.appending(path: "timeline.txt"))
        await progress?(.metadata); try Task.checkCancellation()
        if let store {
            do { try DiagnosticsService.encoder.encode(await store.diagnosticMetadata(videoID: options.videoID)).write(to: contents.appending(path: "recordings.json")) }
            catch { omissions.append("Recording metadata could not be read.") }
        } else { omissions.append("The library is unavailable; recording metadata is omitted.") }
        await progress?(.crashes); try Task.checkCancellation()
        var summaries: [DiagnosticCrashSummary] = [], crashBytes = 0
        do {
            let files = try manager.contentsOfDirectory(at: crashDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                .filter { ($0.lastPathComponent.hasPrefix("VideoContext-") || $0.lastPathComponent.hasPrefix("video-context-mcp-")) && $0.pathExtension == "ips" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in files {
                try Task.checkCancellation()
                let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes?.isRegularFile == true, let bytes = attributes?.fileSize, bytes <= 20 * 1024 * 1024 else { omissions.append("A crash report was unreadable or exceeded the size limit."); continue }
                guard let data = try? Data(contentsOf: file), let summary = DiagnosticCrashSummary.parse(data) else { omissions.append("A crash report could not be summarized."); continue }
                guard summary.timestamp >= since, summary.timestamp <= now else { continue }
                guard summaries.count < 20, crashBytes + bytes <= 50 * 1024 * 1024 else { omissions.append("Additional crash reports exceeded the export limit."); break }
                summaries.append(summary); crashBytes += bytes
                if options.includeFullCrashReports {
                    try data.write(to: contents.appending(path: "full-crash-\(summaries.count).ips"))
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { omissions.append("macOS crash reports could not be read.") }
        try DiagnosticsService.encoder.encode(summaries).write(to: contents.appending(path: "crash-summaries.json"))
        omissions = Array(Set(omissions)).sorted()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let manifest = DiagnosticManifest(exportedAt: now, since: since, context: .init(videoID: options.videoID), allRecordings: options.videoID == nil,
            build: DiagnosticBuild.current, osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", fullCrashReports: options.includeFullCrashReports, eventCount: events.count, omissions: omissions)
        try DiagnosticsService.encoder.encode(manifest).write(to: contents.appending(path: "manifest.json"))
        try Data("Capture is opt-in and expires after 24 hours. Missing start/end events do not establish success or failure. Elapsed time is not progress. Application events and crash reports are application-wide. Raw crash reports are included only by explicit export selection. No library content is included in the other files. See manifest.json for omissions.\n".utf8).write(to: contents.appending(path: "README.txt"))
        await progress?(.archive); try Task.checkCancellation()
        let archive = temporary.appending(path: "diagnostics.zip")
        let result = try await ProcessRunner().run(.init(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", contents.path, archive.path]))
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        // Atomic publication prevents cancellation or a failed archive from leaving a partial export.
        try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: .atomic)
        await progress?(.finished)
        return .init(eventCount: events.count, omissions: omissions)
    }
}
