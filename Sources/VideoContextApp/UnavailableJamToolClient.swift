import VideoContextCore

struct UnavailableJamToolClient: JamToolCalling {
    func listTools() async throws -> [JamToolDescriptor] { throw JamConnectionError.authorizationRequired }
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        throw JamConnectionError.authorizationRequired
    }
}
