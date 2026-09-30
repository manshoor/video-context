import AppKit
import Foundation

struct SystemJamBrowser: JamBrowserOpening, Sendable {
    @MainActor
    func open(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else { throw JamConnectionError.authorizationRequired }
    }
}
