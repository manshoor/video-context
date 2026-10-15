import Foundation

public enum AgentClient: String, CaseIterable, Sendable, Identifiable {
    case codex, claude, cursor
    public var id: String { rawValue }
    public var label: String { switch self { case .codex: "Codex"; case .claude: "Claude Code"; case .cursor: "Cursor" } }
    public func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let path = switch self { case .codex: ".codex/config.toml"; case .claude: ".claude.json"; case .cursor: ".cursor/mcp.json" }
        return home.appending(path: path)
    }
}

public enum AgentConfigStatus: String, Sendable {
    case missingFile, missingEntry, matching, different, disabled, unreadableFile, unsupportedSyntax
    public var label: String {
        switch self {
        case .missingFile: "Config file missing"
        case .missingEntry: "video-context entry missing"
        case .matching: "Command matches this executable"
        case .different: "Command points to a different executable"
        case .disabled: "Entry is disabled"
        case .unreadableFile: "Config file unreadable"
        case .unsupportedSyntax: "Unsupported config syntax"
        }
    }
}
public struct AgentConfigCheck: Sendable {
    public let status: AgentConfigStatus
    public let command: String?
}

public struct AgentSetup: Sendable {
    public let executable: String
    public let library: String
    public let ffmpeg: String
    public let alias: String
    public init(executable: String, library: String, ffmpeg: String, alias: String = "video-context") {
        self.executable = executable; self.library = library; self.ffmpeg = ffmpeg; self.alias = alias
    }
    public var arguments: [String] { ["--library", library, "--ffmpeg", ffmpeg] }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public func command(for client: AgentClient) -> String {
        let prefix = client == .claude ? "claude mcp add --transport stdio --scope user" : "codex mcp add"
        return prefix + " " + alias + " -- " + ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }
    public func configuration(for client: AgentClient) -> String {
        if client == .codex {
            return "[mcp_servers.\(alias)]\ncommand = \(Self.quoted(executable))\nargs = [\(arguments.map(Self.quoted).joined(separator: ", "))]"
        }
        let object = ["mcpServers": [alias: ["command": executable, "args": arguments] as [String: Any]]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }
    private static func quoted(_ value: String) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }
    public func removalCommand(for client: AgentClient) -> String {
        client == .claude ? "claude mcp remove --scope user \(alias)" : "codex mcp remove \(alias)"
    }
}

public enum AgentConfigInspector {
    public static func inspect(file: URL, client: AgentClient, currentCommand: String,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentConfigCheck {
        do {
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8) else { return .init(status: .unsupportedSyntax, command: nil) }
            return parse(text, client: client, currentCommand: currentCommand, home: home)
        } catch {
            // fileExists also returns false when a parent directory is inaccessible.
            // Preserve the read error so a permissions failure is not labelled missing.
            let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
            return .init(status: missing ? .missingFile : .unreadableFile, command: nil)
        }
    }
    public static func parse(_ text: String, client: AgentClient, currentCommand: String,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentConfigCheck {
        do {
            let entry = try client == .codex ? tomlEntry(text) : jsonEntry(text)
            guard let entry else { return .init(status: .missingEntry, command: nil) }
            guard let command = entry.command, let configured = canonical(command, home: home),
                  let current = canonical(currentCommand, home: home) else { return .init(status: .unsupportedSyntax, command: entry.command) }
            return .init(status: entry.disabled ? .disabled : (configured == current ? .matching : .different), command: command)
        } catch { return .init(status: .unsupportedSyntax, command: nil) }
    }
    private static func canonical(_ command: String, home: URL) -> String? {
        let expanded = command.hasPrefix("~/") ? home.path + String(command.dropFirst()) : command
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private struct Entry: Decodable {
        var command: String?
        var disabled: Bool?
        var enabled: Bool?
    }
    private struct JSONConfig: Decodable {
        var mcpServers: [String: Entry]?
        var disabledMcpServers: [String]?
    }
    private struct ParsedEntry { let command: String?; let disabled: Bool }
    private enum ParseError: Error { case unsupported }
    private static func jsonEntry(_ text: String) throws -> ParsedEntry? {
        let config = try JSONDecoder().decode(JSONConfig.self, from: Data(text.utf8))
        guard let entry = config.mcpServers?["video-context"] else { return nil }
        return .init(command: entry.command, disabled: entry.disabled == true || entry.enabled == false || config.disabledMcpServers?.contains("video-context") == true)
    }
    /// Intentionally parses only a user-level stdio section. Other sections are ignored.
    /// Complex target declarations are reported as unsupported rather than guessed.
    private static func tomlEntry(_ text: String) throws -> ParsedEntry? {
        var inSection = false, found = false, command: String?, disabled = false, keys: Set<String> = []
        for raw in text.components(separatedBy: .newlines) {
            let line = stripComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                inSection = ["[mcp_servers.video-context]", "[mcp_servers.\"video-context\"]", "[mcp_servers.'video-context']"].contains(line.replacingOccurrences(of: " ", with: ""))
                if inSection { guard !found else { throw ParseError.unsupported }; found = true }
                else if line.contains("mcp_servers") && line.contains("video-context") { throw ParseError.unsupported }
                continue
            }
            guard inSection else {
                if line.hasPrefix("video-context") || line.hasPrefix("mcp_servers.video-context") { throw ParseError.unsupported }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw ParseError.unsupported }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard keys.insert(key).inserted else { throw ParseError.unsupported }
            switch key {
            case "command": command = try tomlString(value)
            case "enabled", "disabled":
                guard value == "true" || value == "false" else { throw ParseError.unsupported }
                disabled = disabled || (key == "enabled" ? value == "false" : value == "true")
            default: break // args/env and other client settings do not affect command comparison.
            }
        }
        return found ? .init(command: command, disabled: disabled) : nil
    }
    private static func stripComment(_ line: String) -> String {
        var quote: Character?, escaped = false, result = ""
        for char in line {
            if escaped { result.append(char); escaped = false; continue }
            if quote == "\"" && char == "\\" { escaped = true; result.append(char); continue }
            if let current = quote { if char == current { quote = nil } }
            else if char == "#" { break }
            else if char == "\"" || char == "'" { quote = char }
            result.append(char)
        }
        return result
    }
    private static func tomlString(_ value: String) throws -> String {
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 && !value.dropFirst().dropLast().contains("'") {
            return String(value.dropFirst().dropLast())
        }
        // Basic TOML strings have JSON-compatible escapes, plus \UXXXXXXXX.
        guard value.hasPrefix("\""), !value.hasPrefix("\"\"\"") else { throw ParseError.unsupported }
        var json = "", i = value.startIndex
        while i < value.endIndex {
            let char = value[i]; i = value.index(after: i)
            if char != "\\" { json.append(char); continue }
            guard i < value.endIndex else { throw ParseError.unsupported }
            let escape = value[i]; i = value.index(after: i)
            if escape == "U" {
                guard let end = value.index(i, offsetBy: 8, limitedBy: value.endIndex),
                      let number = UInt32(value[i..<end], radix: 16), let scalar = UnicodeScalar(number) else { throw ParseError.unsupported }
                json += String(decoding: try JSONEncoder().encode(String(scalar)), as: UTF8.self).dropFirst().dropLast()
                i = end
            } else { json.append("\\"); json.append(escape) }
        }
        return try JSONDecoder().decode(String.self, from: Data(json.utf8))
    }
}
