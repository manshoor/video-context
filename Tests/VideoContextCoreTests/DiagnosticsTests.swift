import Foundation
import Darwin
import Synchronization
import Testing
@testable import VideoContextCore

private final class DiagnosticTestClock: Sendable {
    let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0.addTimeInterval(seconds) } }
}

struct DiagnosticsTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "diagnostics-test-\(UUID())") }

    @Test func optInExpiryAndExistingMCPInstance() async throws {
        let root = root(), clock = DiagnosticTestClock()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = DiagnosticsService(root: root, component: .app, clock: { clock.now() })
        let mcp = DiagnosticsService(root: root, component: .mcp, clock: { clock.now() })
        await mcp.record(.init(.toolStarted, operation: .getVideoBrief))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let policy = try await app.enable()
        await mcp.record(.init(.toolStarted, operation: .getVideoBrief))
        #expect(try await app.events(since: .distantPast).last?.captureID == policy.captureID)
        clock.advance(86_400)
        let count = try await app.events(since: .distantPast).count
        await mcp.record(.init(.toolFinished, operation: .getVideoBrief))
        #expect(try await app.events(since: .distantPast).count == count)
        #expect(await mcp.status().enabled == false)
        _ = try await app.enable()
        try await app.stop()
        await mcp.record(.init(.toolStarted, operation: .getVideoBrief))
        #expect(await mcp.status().enabled == false)
    }

    @Test func privacyAndSafeErrors() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app)
        _ = try await service.enable()
        let secret = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
        let context = DiagnosticContext(videoID: secret, taskID: "/Users/private/movie.mp4", model: secret)
        let errors: [any Error] = [OpenAIClientError.provider(status: 401, message: secret),
            LocalProviderError.unavailable(secret), TaskContextError.missing(secret),
            MediaImportError.downloadFailed(secret), NSError(domain: secret, code: 99, userInfo: [NSLocalizedDescriptionKey: secret])]
        for error in errors { await service.record(.init(.failed, operation: .processing, context: context, error: DiagnosticFailure(error))) }
        let data = try JSONEncoder().encode(await service.events(since: .distantPast))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("/Users/"))
        #expect(text.contains("401"))
    }

    @Test func concurrentWritersRotationAndPartialTail() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = DiagnosticLimits(fileBytes: 2048, totalBytes: 16_384)
        let app = DiagnosticsService(root: root, component: .app, limits: limits)
        let mcp = DiagnosticsService(root: root, component: .mcp, limits: limits)
        _ = try await app.enable()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                group.addTask { await (index.isMultiple(of: 2) ? app : mcp).record(.init(.toolFinished, operation: .getVideoBrief)) }
            }
        }
        let values = try await app.events(since: .distantPast)
        #expect(!values.isEmpty)
        #expect(Set(values.map(\.component)) == [.app, .mcp])
        let files = try FileManager.default.contentsOfDirectory(at: root.appending(path: "logs"), includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        #expect(bytes <= limits.totalBytes)
        let current = root.appending(path: "logs/events.jsonl")
        let handle = try FileHandle(forWritingTo: current)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        #expect(try await app.events(since: .distantPast).count == values.count)
        await app.record(.init(.completed, operation: .processing))
        #expect(try await app.events(since: .distantPast).last?.event == .completed)
    }

    @Test func storageFailureNeverThrowsAndRecovers() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app)
        _ = try await service.enable()
        let logs = root.appending(path: "logs")
        try? FileManager.default.removeItem(at: logs)
        try Data("blocked".utf8).write(to: logs)
        await service.record(.init(.started, operation: .processing))
        #expect(await service.status().failure != nil)
        try FileManager.default.removeItem(at: logs)
        await service.record(.init(.completed, operation: .processing))
        #expect(try await service.events(since: .distantPast).last?.droppedEvents == 1)
        #expect(await service.status().failure == nil)
    }
}

extension DiagnosticsTests {
    @Test func progressIsThrottledWithoutSuppressingCompletionOrNextCapture() async throws {
        let root = root(), clock = DiagnosticTestClock()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app, clock: { clock.now() })
        _ = try await service.enable()
        let operation = UUID()
        for _ in 0..<5 { await service.record(.init(.progress, operation: .processing, operationID: operation)) }
        clock.advance(29)
        await service.record(.init(.progress, operation: .processing, operationID: operation))
        clock.advance(1)
        await service.record(.init(.progress, operation: .processing, operationID: operation))
        await service.record(.init(.completed, operation: .processing, operationID: operation))
        #expect(try await service.events(since: .distantPast).filter { $0.event == .progress }.count == 2)
        _ = try await service.enable()
        await service.record(.init(.progress, operation: .processing, operationID: operation))
        #expect(try await service.events(since: .distantPast).filter { $0.event == .progress }.count == 3)
    }
    @Test func retentionRemovesOldFilesAndOtherLibrariesStayOff() async throws {
        let root = root(), other = root.appending(path: "separate-library")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app)
        _ = try await service.enable()
        let log = root.appending(path: "logs/events.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: log.path)
        await service.record(.init(.completed, operation: .processing))
        #expect(try await service.events(since: .distantPast).count == 1)
        let isolated = DiagnosticsService(root: other, component: .mcp)
        #expect(await isolated.status().enabled == false)
        await isolated.record(.init(.started, operation: .lifecycle))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
    @Test func httpErrorsKeepCodesWithoutRequestOrResponseContent() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app)
        _ = try await service.enable()
        let scope = DiagnosticScope(service: service, operation: .taskGeneration)
        let client = DiagnosticHTTPClient(base: DiagnosticHTTPFixture(), provider: .lmStudio)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1234/private-secret-query")!)
        request.setValue("Bearer PRIVATE_SECRET", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"model":"gemma-4-12b","messages":[{"content":"PRIVATE_SECRET"}]}"#.utf8)
        let response = try await DiagnosticTrace.$scope.withValue(scope) { try await client.data(for: request) }
        #expect(response.statusCode == 401)
        let events = try await service.events(since: .distantPast)
        #expect(events.last?.entry.error?.code == 401)
        #expect(events.last?.entry.context.model == "gemma-4-12b")
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!text.contains("PRIVATE_SECRET")); #expect(!text.contains("private-secret-query"))
    }
}
private struct DiagnosticHTTPFixture: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPResult {
        .init(data: Data(#"{"error":{"message":"PRIVATE_SECRET"}}"#.utf8), statusCode: 401)
    }
}

extension DiagnosticsTests {
    @Test func filesystemLockContentionDropsAnEventThenReportsRecovery() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app)
        _ = try await service.enable()
        let fd = open(root.appending(path: ".lock").path, O_RDWR)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await service.record(.init(.started, operation: .processing))
        #expect(await service.status().failure != nil)
        flock(fd, LOCK_UN)
        await service.record(.init(.completed, operation: .processing))
        #expect(try await service.events(since: .distantPast).last?.droppedEvents == 1)
    }
    @Test func malformedSettingsFailClosedAndCorruptLogsAreReported() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DiagnosticsService(root: root, component: .app)
        _ = try await service.enable()
        let policy = root.appending(path: "settings.json")
        try Data("not a policy".utf8).write(to: policy)
        let before = try Data(contentsOf: root.appending(path: "logs/events.jsonl"))
        await service.record(.init(.started, operation: .processing))
        #expect(await service.status().enabled == false)
        #expect(try Data(contentsOf: root.appending(path: "logs/events.jsonl")) == before)
        _ = try await service.enable()
        let broken = root.appending(path: "logs/broken.jsonl")
        try Data("{bad}\n{partial".utf8).write(to: broken)
        let snapshot = try await service.snapshot(since: .distantPast)
        #expect(snapshot.omissions.count == 2)
        #expect(!snapshot.events.isEmpty)
    }
}
