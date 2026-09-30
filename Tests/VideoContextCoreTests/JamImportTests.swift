import Foundation
import Testing
@testable import VideoContextCore

struct JamImportTests {
    @Test func jamLinksAreRecognizedBeforeGenericMediaAndRepeatedLinksReuseOneSource() throws {
        let url = "https://jam.dev/c/recording-123"
        let parsed = FeedbackBatch.parse("Preview is blank: \(url)\nThe same run: \(url)")

        #expect(parsed.1.count == 1)
        #expect(parsed.1[0].kind == .jam)
        #expect(parsed.0.allSatisfy { $0.sourceIDs == [parsed.1[0].id] })
        #expect(JamLink(url: URL(string: url)!) != nil)
        #expect(JamLink(url: URL(string: "https://eviljam.dev/c/recording-123")!) == nil)
        #expect(FeedbackBatch.parse("See https://eviljam.dev/c/recording-123").1[0].kind == .link)
    }

    @Test func importerUsesOnlyTheReadAllowlistAndCollectsDebuggingEvidence() async throws {
        let client = RecordingJamToolClient(responses: [
            "getDetails": .text(#"{"title":"Blank checkout","duration":14}"#),
            "getVideoTranscript": .text("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nThe checkout is blank"),
            "getFrames": .init(content: [
                .text("t=1500"),
                .image(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")
            ]),
            "getUserEvents": .text(#"[{"timestamp":1200,"type":"click","target":"Pay now"}]"#),
            "getConsoleLogs": .text(#"[{"timestamp":1300,"level":"error","message":"Checkout failed"}]"#),
            "getNetworkRequests:4xx": .text(#"[{"method":"POST","url":"https://shop.test/pay","statusCode":422,"headers":{"Authorization":"Bearer private-token"},"requestBody":"card-secret","responseBody":"private-response"}]"#),
            "getNetworkRequests:5xx": .text(#"[{"method":"GET","url":"https://shop.test/cart","statusCode":503,"body":"private-body"}]"#)
        ], extraTools: ["analyzeVideo", "createJam", "updateJam"])
        let importer = JamEvidenceImporter(client: client)

        let result = try await importer.importEvidence(from: URL(string: "https://jam.dev/c/recording-123")!)

        #expect(result.state == .ready)
        #expect(result.items.contains { $0.component == .transcript && $0.text?.contains("checkout is blank") == true })
        #expect(result.items.contains { $0.component == .frame && $0.timestampMilliseconds == 1_500 && $0.imageData != nil })
        #expect(result.items.contains { $0.component == .userActions })
        #expect(result.items.contains { $0.component == .consoleErrors })
        let network = result.items.filter { $0.component == .failedRequests }.compactMap(\.text).joined()
        #expect(network.contains("422"))
        #expect(network.contains("503"))
        #expect(network.contains("private-token") == false)
        #expect(network.contains("card-secret") == false)
        #expect(network.contains("private-response") == false)
        #expect(network.contains("private-body") == false)
        #expect(network.localizedCaseInsensitiveContains("headers") == false)
        let called = await client.calledToolNames
        #expect(Set(called).isSubset(of: JamReadToolPolicy.allowedTools))
        #expect(called.contains("analyzeVideo") == false)
        #expect(called.contains("createJam") == false)
    }

    @Test func missingTranscriptAndUnsupportedFramesStayVisible() async throws {
        let client = RecordingJamToolClient(
            responses: ["getDetails": .text(#"{"title":"Instant Replay"}"#)],
            advertisedTools: ["getDetails", "getConsoleLogs"]
        )

        let result = try await JamEvidenceImporter(client: client)
            .importEvidence(from: URL(string: "https://jam.dev/c/instant-replay")!)

        #expect(result.state == .ready)
        #expect(result.availability.first { $0.component == .transcript }?.status == .unsupported)
        #expect(result.availability.first { $0.component == .frame }?.status == .unsupported)
        #expect(result.availability.first { $0.component == .transcript }?.message.isEmpty == false)
        #expect(result.availability.first { $0.component == .frame }?.message.isEmpty == false)
    }

    @Test func unavailableDetailsRemainUnreadAndRetryAfterCancellationCanSucceed() async throws {
        let unavailable = RecordingJamToolClient(responses: ["getDetails": .init(content: [.text("Not found")], isError: true)])
        let unread = try await JamEvidenceImporter(client: unavailable)
            .importEvidence(from: URL(string: "https://jam.dev/c/missing")!)
        #expect(unread.state == .unread)
        #expect(unread.availability.first { $0.component == .details }?.status == .failed)

        let retry = RetryJamToolClient()
        let importer = JamEvidenceImporter(client: retry)
        await #expect(throws: CancellationError.self) {
            try await importer.importEvidence(from: URL(string: "https://jam.dev/c/retry")!)
        }
        let recovered = try await importer.importEvidence(from: URL(string: "https://jam.dev/c/retry")!)
        #expect(recovered.state == .ready)
        #expect(await retry.detailsCalls == 2)
    }

    @Test func networkToolWithoutStatusFilterIsCalledOnceAndStillKeepsOnlyFailures() async throws {
        let client = NoNetworkFilterJamClient()
        let result = try await JamEvidenceImporter(client: client)
            .importEvidence(from: URL(string: "https://jam.dev/c/no-filter")!)

        #expect(await client.networkCalls == 1)
        let text = result.items.filter { $0.component == .failedRequests }.compactMap(\.text).joined()
        #expect(text.contains("503"))
        #expect(text.contains("200") == false)
    }

    @Test func framesUseBooleanOverviewAndStringFiltersRemainStrings() async throws {
        let client = RecordingJamToolClient(responses: [
            "getDetails": .text(#"{"title":"Typed arguments"}"#),
            "getFrames": .text("Frames are unavailable for this hosted recording."),
            "getConsoleLogs": .text("[]"),
            "getNetworkRequests:4xx": .text("[]"),
            "getNetworkRequests:5xx": .text("[]")
        ])
        let imported = try await JamEvidenceImporter(client: client).importEvidence(from: URL(string: "https://jam.dev/c/typed")!)
        let calls = await client.calls
        #expect(calls.first { $0.0 == "getFrames" }?.1["overview"] == .bool(true))
        #expect(calls.first { $0.0 == "getConsoleLogs" }?.1["logLevel"] == .string("error"))
        #expect(calls.first { $0.1["statusCode"] == .string("4xx") } != nil)
        #expect(imported.availability.first { $0.component == .frame }?.message.contains("hosted recording") == true)
        #expect(imported.availability.first { $0.component == .consoleErrors }?.message == "No matching errors recorded.")
        #expect(imported.availability.first { $0.component == .failedRequests }?.message == "No matching errors recorded.")
    }

    @Test func toolErrorsKeepSanitizedBoundedReasons() async throws {
        let client = RecordingJamToolClient(responses: [
            "getDetails": .text(#"{"title":"Error case"}"#),
            "getFrames": .init(content: [.text("Invalid arguments: overview must be boolean. Bearer secret-token")], isError: true),
            "getVideoTranscript": .init(content: [.text("Transcript requires microphone audio.")], isError: true)
        ])
        let imported = try await JamEvidenceImporter(client: client).importEvidence(from: URL(string: "https://jam.dev/c/errors")!)
        let frame = try #require(imported.availability.first { $0.component == .frame })
        #expect(frame.status == .failed)
        #expect(frame.message.contains("overview must be boolean"))
        #expect(!frame.message.contains("secret-token"))
        #expect(frame.message.utf8.count <= 512)
        #expect(imported.availability.first { $0.component == .transcript }?.message.contains("microphone audio") == true)
    }

    @Test func advertisedSchemaRejectsWrongTypesBeforeTransport() async throws {
        let client = SchemaJamToolClient()
        let imported = try await JamEvidenceImporter(client: client).importEvidence(from: URL(string: "https://jam.dev/c/schema")!)
        #expect(imported.state == .ready)
        #expect(imported.availability.first { $0.component == .frame }?.status == .failed)
        #expect(imported.availability.first { $0.component == .frame }?.message.contains("advertised schema") == true)
        #expect(await client.calledNames == ["getDetails"])
    }
}

private actor SchemaJamToolClient: JamToolCalling {
    private(set) var calledNames: [String] = []
    func listTools() async throws -> [JamToolDescriptor] {
        let reference: JamJSONValue = .object(["type": .string("string")])
        return [
            .init(name: "getDetails", inputSchema: .object([
                "type": .string("object"), "required": .array([.string("jamUrl")]),
                "properties": .object(["jamUrl": reference]), "additionalProperties": .bool(false)
            ])),
            .init(name: "getFrames", inputSchema: .object([
                "type": .string("object"), "required": .array([.string("jamUrl")]),
                "properties": .object(["jamUrl": reference, "overview": .object(["type": .string("string")])]),
                "additionalProperties": .bool(false)
            ]))
        ]
    }
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        calledNames.append(name)
        return .text(#"{"title":"Schema"}"#)
    }
}

private actor RecordingJamToolClient: JamToolCalling {
    let descriptors: [JamToolDescriptor]
    let responses: [String: JamToolResponse]
    private(set) var calls: [(String, [String: JamJSONValue])] = []

    init(
        responses: [String: JamToolResponse],
        advertisedTools: Set<String>? = nil,
        extraTools: Set<String> = []
    ) {
        self.responses = responses
        let responseNames = Set(responses.keys.map { $0.components(separatedBy: ":")[0] })
        let names = (advertisedTools ?? responseNames).union(extraTools)
        descriptors = names.sorted().map { .init(name: $0, inputProperties: ["jamUrl", "statusCode", "logLevel", "overview"]) }
    }

    var calledToolNames: [String] { calls.map(\.0) }
    func listTools() async throws -> [JamToolDescriptor] { descriptors }
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        calls.append((name, arguments))
        let key = arguments["statusCode"]?.stringValue.map { "\(name):\($0)" } ?? name
        return responses[key] ?? .text("[]")
    }
}

private actor RetryJamToolClient: JamToolCalling {
    private(set) var detailsCalls = 0
    func listTools() async throws -> [JamToolDescriptor] {
        [.init(name: "getDetails", inputProperties: ["jamUrl"])]
    }
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        detailsCalls += 1
        if detailsCalls == 1 { throw CancellationError() }
        return .text(#"{"title":"Recovered"}"#)
    }
}

private actor NoNetworkFilterJamClient: JamToolCalling {
    private(set) var networkCalls = 0
    func listTools() async throws -> [JamToolDescriptor] {
        [
            .init(name: "getDetails", inputProperties: ["jamUrl"]),
            .init(name: "getNetworkRequests", inputProperties: ["jamUrl"])
        ]
    }
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse {
        if name == "getDetails" { return .text(#"{"title":"No filter"}"#) }
        networkCalls += 1
        return .text(#"[{"statusCode":200,"url":"https://shop.test/ok"},{"statusCode":503,"url":"https://shop.test/fail"}]"#)
    }
}
