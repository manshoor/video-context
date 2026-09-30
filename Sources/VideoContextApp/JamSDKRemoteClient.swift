import Foundation
import MCP
import VideoContextCore

actor JamSDKRemoteClient: JamRemoteConnecting {
    private let storage: JamOAuthCredentialStore
    private let browser: any JamBrowserOpening
    private let callbackFactory: any JamAuthorizationCallbackCreating
    private var client: Client?
    private var advertisedTools: [String: Tool] = [:]

    init(
        storage: JamOAuthCredentialStore,
        browser: any JamBrowserOpening = SystemJamBrowser(),
        callbackFactory: any JamAuthorizationCallbackCreating = LiveJamAuthorizationCallbackFactory()
    ) {
        self.storage = storage
        self.browser = browser
        self.callbackFactory = callbackFactory
    }

    func connect(interactive: Bool) async throws -> Set<String> {
        await disconnect()

        let callback: (any JamAuthorizationCallbackReceiving)?
        let delegate: any OAuthAuthorizationDelegate
        let redirectURI: URL
        if interactive {
            let created = try await callbackFactory.makeCallback()
            callback = created
            redirectURI = created.redirectURI
            delegate = JamAuthorizationDelegate(browser: browser, callback: created)
        } else {
            callback = nil
            redirectURI = JamOAuthPolicy.unusedLoopbackRedirectURI()
            delegate = JamNoninteractiveAuthorizationDelegate()
        }

        let configuration = JamOAuthPolicy.configuration(
            redirectURI: redirectURI,
            clientID: storage.clientID,
            delegate: delegate
        )
        let authorizer = OAuthAuthorizer(
            configuration: configuration,
            tokenStorage: storage,
            scopeSelector: JamReadOnlyScopeSelector()
        )
        let transport = HTTPClientTransport(
            endpoint: JamOAuthPolicy.endpoint,
            streaming: false,
            authorizer: authorizer
        )
        let newClient = Client(
            name: "Video Context",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        )

        do {
            try await newClient.connect(transport: transport)
            var tools: [String: Tool] = [:]
            var cursor: String?
            repeat {
                let page = try await newClient.listTools(cursor: cursor)
                for tool in page.tools { tools[tool.name] = tool }
                cursor = page.nextCursor
            } while cursor != nil
            client = newClient
            advertisedTools = tools
            await callback?.cancel()
            return Set(tools.keys)
        } catch {
            await callback?.cancel()
            await newClient.disconnect()
            throw error
        }
    }

    func disconnect() async {
        guard let client else { return }
        self.client = nil
        advertisedTools = [:]
        await client.disconnect()
    }
}

extension JamSDKRemoteClient: JamToolCalling {
    func listTools() async throws -> [JamToolDescriptor] {
        advertisedTools.values.compactMap { tool in
            JamMCPValueCodec.fromMCP(tool.inputSchema).map { JamToolDescriptor(name: tool.name, inputSchema: $0) }
        }
    }

    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> VideoContextCore.JamToolResponse {
        guard JamReadToolPolicy.allowedTools.contains(name), let tool = advertisedTools[name] else {
            throw TaskContextError.invalid("Jam tool is not in the read-only allowlist.")
        }
        guard let schema = JamMCPValueCodec.fromMCP(tool.inputSchema) else {
            throw TaskContextError.invalid("Jam tool advertised an invalid input schema.")
        }
        let descriptor = JamToolDescriptor(name: name, inputSchema: schema)
        guard descriptor.validates(arguments) else {
            throw TaskContextError.invalid("Jam tool arguments did not match the advertised schema.")
        }
        guard let client else { throw JamConnectionError.authorizationRequired }
        let result = try await client.callTool(
            name: name,
            arguments: JamMCPValueCodec.toMCP(arguments)
        )
        let content: [JamToolContent] = result.content.compactMap { value in
            switch value {
            case .text(let text, _, _): .text(text)
            case .image(let data, let mimeType, _, _):
                Data(base64Encoded: data).map { .image(data: $0, mimeType: mimeType) }
            default: nil
            }
        }
        return .init(content: content, isError: result.isError ?? false)
    }
}

enum JamMCPValueCodec {
    static func toMCP(_ arguments: [String: JamJSONValue]) -> [String: Value] { arguments.mapValues(toMCP) }
    static func toMCP(_ value: JamJSONValue) -> Value {
        switch value {
        case .null: .null
        case .bool(let value): .bool(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(toMCP))
        case .object(let values): .object(values.mapValues(toMCP))
        }
    }
    static func fromMCP(_ value: Value) -> JamJSONValue? {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let values):
            let converted = values.compactMap(fromMCP)
            return converted.count == values.count ? .array(converted) : nil
        case .object(let values):
            let converted = values.compactMapValues(fromMCP)
            return converted.count == values.count ? .object(converted) : nil
        case .data: return nil
        }
    }
}
