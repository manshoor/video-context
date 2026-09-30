import Foundation

public struct DiagnosticCrashSummary: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public let imageUUID: UUID?
        public let imageOffset: UInt64?
    }
    public let timestamp: Date
    public let component: DiagnosticComponent
    public let version: String?
    public let build: String?
    public let exception: String
    public let frames: [Frame]
    public let applicationWide: Bool

    /// Never includes arbitrary symbols, paths, messages, memory, or register values.
    public static func parse(_ data: Data) -> Self? {
        guard let newline = data.firstIndex(of: 10),
              let header = try? JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: data.suffix(from: data.index(after: newline))) as? [String: Any] else { return nil }
        let bundle = body["bundleInfo"] as? [String: Any]
        let isApp = (header["bundleID"] as? String ?? bundle?["CFBundleIdentifier"] as? String) == "app.videocontext.mac"
        let isMCP = (body["procName"] as? String ?? header["app_name"] as? String) == "video-context-mcp"
        guard isApp || isMCP, let time = header["timestamp"] as? String ?? body["captureTime"] as? String,
              let date = parseDate(time) else { return nil }
        let type = (body["exception"] as? [String: Any])?["type"] as? String ?? "unknown"
        let allowed = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_EMULATION", "EXC_SOFTWARE", "EXC_BREAKPOINT", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD", "EXC_CORPSE_NOTIFY"]
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let thread = threads.first { $0["triggered"] as? Bool == true }
        let rawFrames = thread?["frames"] as? [[String: Any]] ?? []
        let frames = rawFrames.prefix(40).map { value -> Frame in
            let index = value["imageIndex"] as? Int
            let image = index.flatMap { images.indices.contains($0) ? images[$0] : nil }
            return .init(imageUUID: (image?["uuid"] as? String).flatMap(UUID.init(uuidString:)), imageOffset: value["imageOffset"] as? UInt64)
        }
        func numeric(_ value: Any?) -> String? {
            guard let value = value as? String, value.count < 40, value.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil else { return nil }
            return value
        }
        return .init(timestamp: date, component: isMCP ? .mcp : .app,
            version: numeric(header["app_version"] ?? bundle?["CFBundleShortVersionString"]), build: numeric(header["build_version"] ?? bundle?["CFBundleVersion"]),
            exception: allowed.contains(type) ? type : "unknown", frames: frames, applicationWide: true)
    }
    private static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return formatter.date(from: text)
    }
}
