import AppKit
import VideoContextCore

@MainActor
final class DiagnosticsAppDelegate: NSObject, NSApplicationDelegate {
    var diagnostics: DiagnosticsService?
    var agentConnections: AgentConnectionsModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard diagnostics != nil || agentConnections != nil else { return .terminateNow }
        Task {
            await agentConnections?.endTest()
            await diagnostics?.record(.init(.completed, operation: .lifecycle))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
