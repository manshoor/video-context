import Foundation
import MCP

protocol JamBrowserOpening: Sendable {
    func open(_ url: URL) async throws
}

protocol JamAuthorizationCallbackReceiving: Sendable {
    var redirectURI: URL { get }
    func receiveRedirect() async throws -> URL
    func cancel() async
}

struct JamAuthorizationDelegate: OAuthAuthorizationDelegate, Sendable {
    let browser: any JamBrowserOpening
    let callback: any JamAuthorizationCallbackReceiving

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        try await browser.open(url)
        return try await withTaskCancellationHandler {
            try await callback.receiveRedirect()
        } onCancel: {
            Task { await callback.cancel() }
        }
    }
}

struct JamNoninteractiveAuthorizationDelegate: OAuthAuthorizationDelegate, Sendable {
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        throw JamConnectionError.authorizationRequired
    }
}
