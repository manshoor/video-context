import Foundation
import Testing
@testable import VideoContextCore

struct LightshotImportTests {
    @Test func sharePageImportsTheScreenshotAndPreservesSourceIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let share = URL(string: "https://prnt.sc/KSWODEWlr0du")!
        let image = URL(string: "https://img.lightshot.app/bRx9UTodSyyC61JxRvnXgQ.png")!
        let html = """
        <!doctype html><html><head>
        <meta property='og:image' content='https://img.lightshot.app/fallback.png'>
        </head><body><img class="screenshot" src="https://img.lightshot.app/bRx9UTodSyyC61JxRvnXgQ.png" id='screenshot-image'></body></html>
        """
        let client = LightshotFixtureClient(responses: [
            share: .init(data: Data(html.utf8), statusCode: 200),
            image: .init(data: try modelProbeData(), statusCode: 200)
        ])
        let source = FeedbackSource(id: "fsrc_lightshot", url: share.absoluteString)

        let imported = try await FeedbackMediaResolver(client: client).resolve(source, batchID: "fb_fixture", paths: paths)

        #expect(imported.id == "fsrc_lightshot")
        #expect(imported.url == share.absoluteString)
        #expect(imported.resolvedURL == image.absoluteString)
        #expect(imported.kind == .image && imported.status == .ready)
        let path = try #require(imported.localPath)
        #expect(FileManager.default.fileExists(atPath: paths.absoluteURL(relativePath: path).path))
        #expect(await client.requests == [share, image])
    }

    @Test func metadataFallbackDecodesEntitiesAndReorderedAttributes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let share = URL(string: "https://prnt.sc/fallback")!
        let image = URL(string: "https://img.lightshot.app/fallback.png?one=1&two=2")!
        let html = """
        <html><head><meta content='https://img.lightshot.app/fallback.png?one=1&amp;two=2' name=twitter property=og:image></head>
        <body><img id='other' src='https://img.lightshot.app/wrong.png'></body></html>
        """
        let client = LightshotFixtureClient(responses: [
            share: .init(data: Data(html.utf8), statusCode: 200),
            image: .init(data: try modelProbeData(), statusCode: 200)
        ])

        let imported = try await FeedbackMediaResolver(client: client).resolve(
            .init(url: share.absoluteString), batchID: "fb_fixture", paths: paths
        )
        #expect(imported.resolvedURL == image.absoluteString)
        #expect(imported.status == .ready)
        #expect(await client.requests == [share, image])
    }

    @Test func primaryImageAcceptsUnquotedAttributesAndNumericEntities() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let share = URL(string: "https://prnt.sc/unquoted")!
        let image = URL(string: "https://img.lightshot.app/unquoted.png?one=1&two=2")!
        let html = "<img src=https://img.lightshot.app/unquoted.png?one=1&#38;two=2 class=screenshot id=screenshot-image>"
        let client = LightshotFixtureClient(responses: [share: .init(data: Data(html.utf8), statusCode: 200),
                                                         image: .init(data: try modelProbeData(), statusCode: 200)])
        let imported = try await FeedbackMediaResolver(client: client).resolve(.init(url: share.absoluteString),
                                                                                batchID: "fb_fixture", paths: paths)
        #expect(imported.resolvedURL == image.absoluteString)
    }

    @Test func missingScreenshotMetadataHasSpecificFailure() async throws {
        let share = URL(string: "https://prnt.sc/missing")!
        let client = LightshotFixtureClient(responses: [
            share: .init(data: Data("<html><img src='https://img.lightshot.app/other.png'></html>".utf8), statusCode: 200)
        ])
        await expectFailure("Lightshot screenshot metadata is missing.") {
            try await FeedbackMediaResolver(client: client).resolve(.init(url: share.absoluteString),
                batchID: "fb_fixture", paths: LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        }
    }

    @Test func unexpectedScreenshotHostIsRejectedBeforeDownload() async throws {
        let share = URL(string: "https://prnt.sc/wrong-host")!
        let client = LightshotFixtureClient(responses: [
            share: .init(data: Data("<img id='screenshot-image' src='https://evil.example/capture.png'>".utf8), statusCode: 200)
        ])
        await expectFailure("Lightshot media URL was rejected.") {
            try await FeedbackMediaResolver(client: client).resolve(.init(url: share.absoluteString),
                batchID: "fb_fixture", paths: LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        }
        #expect(await client.requests == [share])
    }

    @Test func inaccessiblePageAndInvalidImageHaveDifferentFailures() async throws {
        let share = URL(string: "https://prnt.sc/broken")!
        let image = URL(string: "https://img.lightshot.app/broken.png")!
        let root = FileManager.default.temporaryDirectory
        let inaccessible = LightshotFixtureClient(responses: [share: .init(data: Data(), statusCode: 404)])
        await expectFailure("Lightshot page could not be read.") {
            try await FeedbackMediaResolver(client: inaccessible).resolve(.init(url: share.absoluteString),
                batchID: "fb_fixture", paths: LibraryPaths(root: root.appending(path: UUID().uuidString)))
        }
        let invalid = LightshotFixtureClient(responses: [
            share: .init(data: Data("<img id='screenshot-image' src='https://img.lightshot.app/broken.png'>".utf8), statusCode: 200),
            image: .init(data: Data("not an image".utf8), statusCode: 200)
        ])
        await expectFailure("Lightshot image response is invalid.") {
            try await FeedbackMediaResolver(client: invalid).resolve(.init(url: share.absoluteString),
                batchID: "fb_fixture", paths: LibraryPaths(root: root.appending(path: UUID().uuidString)))
        }
    }

    @Test func redirectPolicyRejectsUnexpectedDestinationsAndCredentials() {
        let policy = HTTPRedirectPolicy(allowedHosts: ["prnt.sc"])
        #expect(policy.allows(URL(string: "https://prnt.sc/next")!))
        #expect(!policy.allows(URL(string: "https://other.example/next")!))
        #expect(!policy.allows(URL(string: "http://prnt.sc/next")!))
        #expect(!policy.allows(URL(string: "https://user:secret@prnt.sc/next")!))
        #expect(!policy.allows(URL(string: "https://prnt.sc:444/next")!))
    }

    @Test func mediaRedirectToAnotherHostIsRejectedBeforeDownload() async throws {
        let share = URL(string: "https://prnt.sc/redirect")!
        let image = URL(string: "https://img.lightshot.app/redirect.png")!
        let client = LightshotRedirectFixtureClient(share: share, image: image,
                                                    redirect: URL(string: "https://unexpected.example/file.png")!)
        await expectFailure("Lightshot media URL was rejected.") {
            try await FeedbackMediaResolver(client: client).resolve(.init(url: share.absoluteString),
                batchID: "fb_fixture", paths: LibraryPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        }
        #expect(await client.requests == [share, image])
    }

    @Test func ocrFailureKeepsSavedScreenshotReady() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = try LibraryPaths(root: root)
        let share = URL(string: "https://prnt.sc/ocr")!
        let image = URL(string: "https://img.lightshot.app/ocr.png")!
        let client = LightshotFixtureClient(responses: [
            share: .init(data: Data("<img src='https://img.lightshot.app/ocr.png' id='screenshot-image'>".utf8), statusCode: 200),
            image: .init(data: try modelProbeData(), statusCode: 200)
        ])
        let resolver = FeedbackMediaResolver(client: client, recognizeText: { _ in
            throw TaskContextError.invalid("Private OCR diagnostics")
        })
        let imported = try await resolver.resolve(.init(url: share.absoluteString), batchID: "fb_fixture", paths: paths)
        #expect(imported.status == .ready)
        #expect(imported.error == "OCR failed; image remains available.")
        let path = try #require(imported.localPath)
        #expect(FileManager.default.fileExists(atPath: paths.absoluteURL(relativePath: path).path))
    }

    private func expectFailure(_ message: String, operation: () async throws -> FeedbackSource) async {
        do {
            _ = try await operation()
            Issue.record("Expected failure: \(message)")
        } catch {
            #expect(error.localizedDescription == message)
        }
    }

    private func modelProbeData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Sources/VideoContextApp/Resources/ModelProbe.jpg"))
    }
}

private actor LightshotRedirectFixtureClient: HTTPDataLoading {
    let share: URL
    let image: URL
    let redirect: URL
    private(set) var requests: [URL] = []
    init(share: URL, image: URL, redirect: URL) { self.share = share; self.image = image; self.redirect = redirect }
    func data(for request: URLRequest) async throws -> HTTPResult {
        Issue.record("Lightshot must use a guarded request")
        throw HTTPRedirectError.rejected
    }
    func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult {
        let url = request.url!
        requests.append(url)
        if url == share {
            #expect(redirectPolicy.maximumBytes == 3_000_000)
            return .init(data: Data("<img id='screenshot-image' src='https://img.lightshot.app/redirect.png'>".utf8), statusCode: 200)
        }
        #expect(url == image)
        #expect(!redirectPolicy.allows(redirect))
        throw HTTPRedirectError.rejected
    }
}

private actor LightshotFixtureClient: HTTPDataLoading {
    let responses: [URL: HTTPResult]
    private(set) var requests: [URL] = []
    init(responses: [URL: HTTPResult]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> HTTPResult {
        let url = request.url!
        requests.append(url)
        return responses[url] ?? .init(data: Data(), statusCode: 404)
    }
    func data(for request: URLRequest, redirectPolicy: HTTPRedirectPolicy) async throws -> HTTPResult {
        #expect(redirectPolicy.allows(request.url!))
        if request.url?.host == "prnt.sc" { #expect(redirectPolicy.maximumBytes == 3_000_000) }
        return try await data(for: request)
    }
}
