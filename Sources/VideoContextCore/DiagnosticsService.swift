import Foundation
import Darwin

public struct DiagnosticPolicy: Codable, Sendable {
    public let captureID: UUID
    public let startedAt: Date
    public let expiresAt: Date
}
public struct DiagnosticStatus: Sendable {
    public let policy: DiagnosticPolicy?
    public let enabled: Bool
    public let failure: DiagnosticFailure?
}
public struct DiagnosticLogSnapshot: Sendable {
    public let events: [DiagnosticEvent]
    public let omissions: [String]
}
public struct DiagnosticLimits: Sendable {
    public let fileBytes: Int
    public let totalBytes: Int
    public let retention: TimeInterval
    public init(fileBytes: Int = 2 * 1024 * 1024, totalBytes: Int = 50 * 1024 * 1024, retention: TimeInterval = 7 * 86_400) {
        self.fileBytes = max(1024, fileBytes); self.totalBytes = max(self.fileBytes, totalBytes); self.retention = retention
    }
}

/// One actor per process; flock also serializes independent app/MCP processes. No MainActor I/O.
public actor DiagnosticsService {
    public nonisolated let root: URL
    private let component: DiagnosticComponent
    private let clock: @Sendable () -> Date
    private let limits: DiagnosticLimits
    private let sessionID = UUID()
    private var build: String?
    private var failure: DiagnosticFailure?
    private var dropped = 0
    private var lastProgress: [UUID: Date] = [:]
    private var observedCapture: UUID?
    private var logs: URL { root.appending(path: "logs") }
    private var settings: URL { root.appending(path: "settings.json") }
    private var active: URL { logs.appending(path: "events.jsonl") }

    public init(root: URL, component: DiagnosticComponent, limits: DiagnosticLimits = .init(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.component = component; self.limits = limits; self.clock = clock
    }
    public static func library(_ paths: LibraryPaths, component: DiagnosticComponent) -> DiagnosticsService {
        .init(root: paths.root.appending(path: "diagnostics"), component: component)
    }
    public func status() -> DiagnosticStatus {
        do {
            let policy = try readPolicy()
            return .init(policy: policy, enabled: policy.map { $0.expiresAt > clock() } ?? false, failure: failure)
        } catch { return .init(policy: nil, enabled: false, failure: DiagnosticFailure(error)) }
    }
    @discardableResult public func enable() throws -> DiagnosticPolicy {
        let now = clock(), policy = DiagnosticPolicy(captureID: UUID(), startedAt: clock(), expiresAt: clock().addingTimeInterval(86_400))
        try locked(create: true) {
            try Self.encoder.encode(policy).write(to: settings, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        }
        failure = nil
        record(.init(.started, operation: .capture, elapsedSeconds: clock().timeIntervalSince(now)))
        return policy
    }
    public func stop() throws {
        try locked(create: false) {
            if FileManager.default.fileExists(atPath: settings.path) { try FileManager.default.removeItem(at: settings) }
        }
        lastProgress.removeAll()
    }
    public func record(_ entry: DiagnosticEntry) {
        do {
            // Do not even create the diagnostics directory while capture is off.
            guard let initial = try readPolicy(), initial.expiresAt > clock() else { return }
            try locked(create: false) {
                guard let policy = try readPolicy(), policy.expiresAt > clock() else { return }
                let now = clock()
                if observedCapture != policy.captureID { lastProgress.removeAll(); observedCapture = policy.captureID }
                if entry.event == .progress, let last = lastProgress[entry.operationID], now.timeIntervalSince(last) < 30 { return }
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if build == nil { build = DiagnosticBuild.current }
                let event = DiagnosticEvent(schemaVersion: 1, timestamp: now, monotonicTicks: mach_absolute_time(), captureID: policy.captureID,
                    sessionID: sessionID, component: component, build: build ?? "development",
                    severity: entry.error == nil ? "info" : "error", droppedEvents: dropped, entry: entry)
                var data = try Self.encoder.encode(event); data.append(10)
                try repairTail()
                let size = (try? active.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size + data.count > limits.fileBytes {
                    try FileManager.default.moveItem(at: active, to: logs.appending(path: "events-\(UUID().uuidString).jsonl"))
                }
                try prune(now: now, reserving: data.count)
                if !FileManager.default.fileExists(atPath: active.path) {
                    guard FileManager.default.createFile(atPath: active.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                let handle = try FileHandle(forWritingTo: active)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
                try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: active.path)
                failure = nil; dropped = 0
                if entry.event == .progress { lastProgress[entry.operationID] = now }
                if [.completed, .failed, .cancelled, .toolFinished].contains(entry.event) { lastProgress.removeValue(forKey: entry.operationID) }
            }
        } catch { failure = DiagnosticFailure(error); dropped += 1 }
    }
    public func events(since: Date, videoID: String? = nil) throws -> [DiagnosticEvent] {
        try snapshot(since: since, videoID: videoID).events
    }
    public func snapshot(since: Date, videoID: String? = nil) throws -> DiagnosticLogSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else { return .init(events: [], omissions: []) }
        var omissions: [String] = []
        let files: [Data] = try locked(create: false) {
            try prune(now: clock(), reserving: 0)
            return try logFiles().compactMap { url in
                do { return try Data(contentsOf: url) }
                catch { omissions.append("A diagnostic log file could not be read."); return nil }
            }
        }
        // Parse outside the filesystem lock so exporting does not stall other processes' writes.
        var results: [DiagnosticEvent] = []
        for data in files {
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            if !data.isEmpty, data.last != 10 { omissions.append("An incomplete diagnostic log tail was omitted.") }
            for line in lines.dropLast() where !line.isEmpty {
                guard let event = try? Self.decoder.decode(DiagnosticEvent.self, from: Data(line)) else {
                    omissions.append("An invalid diagnostic event was omitted."); continue
                }
                guard event.timestamp >= since, videoID == nil || event.entry.context.videoID == videoID || event.entry.context.videoID == nil else { continue }
                results.append(event)
            }
        }
        return .init(events: results.sorted { $0.timestamp == $1.timestamp ? $0.monotonicTicks < $1.monotonicTicks : $0.timestamp < $1.timestamp }, omissions: Array(Set(omissions)).sorted())
    }
    private func readPolicy() throws -> DiagnosticPolicy? {
        guard FileManager.default.fileExists(atPath: settings.path) else { return nil }
        do { return try Self.decoder.decode(DiagnosticPolicy.self, from: Data(contentsOf: settings)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
    private func logFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: logs.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            .filter { $0.pathExtension == "jsonl" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private func repairTail() throws {
        guard FileManager.default.fileExists(atPath: active.path) else { return }
        let data = try Data(contentsOf: active)
        guard !data.isEmpty, data.last != 10 else { return }
        let length = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
        let handle = try FileHandle(forWritingTo: active)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }
    private func prune(now: Date, reserving bytes: Int) throws {
        let files = try logFiles().map { ($0, try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var total = files.reduce(bytes) { $0 + ($1.1.fileSize ?? 0) }
        for (url, attributes) in files {
            if (attributes.contentModificationDate ?? now) < now.addingTimeInterval(-limits.retention) || total > limits.totalBytes {
                try FileManager.default.removeItem(at: url); total -= attributes.fileSize ?? 0
            }
        }
    }
    private func locked<T>(create: Bool, _ action: () throws -> T) throws -> T {
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = open(root.appending(path: ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else { throw CocoaError(.fileLocking) }
            usleep(1_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
    static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

/// Task-local scope follows structured pipeline/provider calls without changing their public contracts.
public enum DiagnosticTrace {
    @TaskLocal public static var scope: DiagnosticScope?
    public static func record(_ kind: DiagnosticEventKind, stage: ProcessingStatus? = nil, completed: Int? = nil, total: Int? = nil, error: (any Error)? = nil) async {
        guard let scope else { return }
        await scope.service.record(.init(kind, operation: scope.operation, operationID: scope.id, context: scope.context,
            stage: stage, completed: completed, total: total, elapsedSeconds: Date().timeIntervalSince(scope.startedAt), error: error.map(DiagnosticFailure.init)))
    }
}
public struct DiagnosticScope: Sendable {
    public let service: DiagnosticsService
    public let operation: DiagnosticOperation
    public let id: UUID
    public let context: DiagnosticContext
    public let startedAt: Date
    public init(service: DiagnosticsService, operation: DiagnosticOperation, context: DiagnosticContext = .init()) {
        self.service = service; self.operation = operation; self.context = context; id = UUID(); startedAt = .now
    }
}
