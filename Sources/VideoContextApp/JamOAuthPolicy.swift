import Foundation
import MCP

struct JamReadOnlyScopeSelector: OAuthScopeSelecting, Sendable {
    func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>? {
        [JamOAuthPolicy.scope]
    }

    func parseScopeString(_ scope: String) -> Set<String> {
        Set(scope.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    func serialize(_ scopes: Set<String>) -> String? {
        scopes.contains(JamOAuthPolicy.scope) ? JamOAuthPolicy.scope : nil
    }
}

enum JamOAuthPolicy {
    static let endpoint = URL(string: "https://mcp.jam.dev/mcp")!
    static let authorizationServer = URL(string: "https://api.jam.dev")!
    static let tokenEndpoint = URL(string: "https://api.jam.dev/oauth/token")!
    static let revocationEndpoint = URL(string: "https://api.jam.dev/oauth/revoke")!
    static let scope = "mcp:read"

    static func configuration(
        redirectURI: URL,
        clientID: String?,
        delegate: any OAuthAuthorizationDelegate
    ) -> OAuthConfiguration {
        OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: clientID ?? ""),
            endpointOverrides: .init(
                authorizationServerURL: authorizationServer,
                tokenEndpoint: tokenEndpoint,
                resource: endpoint
            ),
            authorizationRedirectURI: redirectURI,
            clientName: "Video Context",
            authorizationDelegate: delegate
        )
    }

    static func unusedLoopbackRedirectURI() -> URL {
        URL(string: "http://127.0.0.1:\(Int.random(in: 49_152...65_535))/callback")!
    }
}
