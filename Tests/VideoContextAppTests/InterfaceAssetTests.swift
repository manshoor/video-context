import AppKit
import Foundation
import Testing

@MainActor
struct InterfaceAssetTests {
    @Test func allLiteralInterfaceSymbolsResolve() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = project.appending(path: "Sources/VideoContextApp")
        let regex = try NSRegularExpression(pattern: #"(?:systemImage:|systemName:)\s*"([^"]+)""#)
        var names: Set<String> = ["checkmark.circle.fill", "gearshape.2", "pause.circle", "exclamationmark.circle.fill", "arrow.clockwise.circle", "photo.badge.exclamationmark", "photo", "play.fill", "pause.fill", "play.rectangle.fill", "link", "key.horizontal", "key.slash", "lock.open", "exclamationmark.triangle.fill"]
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) { names.insert(String(source[range])) }
            }
        }
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing icon: \(name)")
        }
        #expect(names.count > 25)
    }
}
