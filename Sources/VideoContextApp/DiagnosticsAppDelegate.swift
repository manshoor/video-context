import AppKit
import VideoContextCore

@MainActor
final class DiagnosticsAppDelegate: NSObject, NSApplicationDelegate {
    var diagnostics: DiagnosticsService?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let diagnostics else { return .terminateNow }
        Task {
            await diagnostics.record(.init(.completed, operation: .lifecycle))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
