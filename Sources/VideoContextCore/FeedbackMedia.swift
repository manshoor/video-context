import Foundation
import ImageIO

public struct ScreencastMedia: Equatable, Sendable {
    public let kind: FeedbackSourceKind
    public let url: URL
    public static func parse(_ html: String) throws -> Self {
        let regex = try NSRegularExpression(
            pattern: #"getPwcConfig\s*=\s*function\s*\(\s*\)\s*\{\s*return\s+Object\.freeze\('(.*?)'\)"#,
            options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { throw TaskContextError.invalid("Screencast media metadata is unavailable.") }
        let literal = ns.substring(with: match.range(at: 1))
        // getPwcConfig returns a JavaScript string containing escaped JSON. Decode the
        // string as JSON data, then decode its value as JSON; never evaluate scripts.
        let quoted = "[\"" + literal.replacingOccurrences(of: "\\'", with: "'") + "\"]"
        guard let outer = try? JSONSerialization.jsonObject(with: Data(quoted.utf8)) as? [String],
              let body = outer.first,
              let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let media = root["Media"] as? [String: Any],
              let type = media["ContentType"] as? String,
              let value = media["ContentUrl"] as? String,
              let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            throw TaskContextError.invalid("Screencast media metadata is invalid or unavailable.")
        }
        let kind: FeedbackSourceKind
        switch type.lowercased() {
        case "image": kind = .image
        case "video": kind = .video
        default: throw TaskContextError.invalid("Screencast media type is not supported.")
        }
        return .init(kind: kind, url: url)
    }
}

public struct FeedbackMediaResolver<Client: HTTPDataLoading>: Sendable {
    public let client: Client
    private let recognizeText: @Sendable (URL) async throws -> String
    public init(client: Client, recognizeText: @escaping @Sendable (URL) async throws -> String = { url in
        try await VisionTextRecognizer().recognizeText(in: url)
    }) {
        self.client = client
        self.recognizeText = recognizeText
    }
    public func resolve(_ input: FeedbackSource, batchID: String, paths: LibraryPaths) async throws -> FeedbackSource {
        guard let original = input.url.flatMap(URL.init(string:)), original.scheme?.lowercased() == "https",
              let host = original.host?.lowercased(), !host.isEmpty,
              host != "localhost", host != "127.0.0.1", !host.hasSuffix(".local"),
              original.user == nil, original.password == nil else { throw TaskContextError.invalid("Use a public HTTPS evidence URL.") }
        var source = input
        var mediaURL = original
        let lightshot = host == "prnt.sc"
        if lightshot {
            guard HTTPRedirectPolicy(allowedHosts: ["prnt.sc"]).allows(original) else {
                throw TaskContextError.invalid("Lightshot page URL was rejected.")
            }
            var request = URLRequest(url: original); request.timeoutInterval = 30
            let response: HTTPResult
            do { response = try await client.data(for: request, redirectPolicy: .init(allowedHosts: ["prnt.sc"], maximumBytes: 3_000_000)) }
            catch is HTTPRedirectError { throw TaskContextError.invalid("Lightshot page URL was rejected.") }
            catch { throw TaskContextError.invalid("Lightshot page could not be read.") }
            guard (200..<300).contains(response.statusCode), !response.data.isEmpty,
                  response.data.count < 3_000_000,
                  let html = String(data: response.data, encoding: .utf8) else {
                throw TaskContextError.invalid("Lightshot page could not be read.")
            }
            guard let value = LightshotPage.screenshotURL(in: html) else {
                throw TaskContextError.invalid("Lightshot screenshot metadata is missing.")
            }
            guard let extracted = URL(string: value),
                  HTTPRedirectPolicy(allowedHosts: ["img.lightshot.app"]).allows(extracted) else {
                throw TaskContextError.invalid("Lightshot media URL was rejected.")
            }
            mediaURL = extracted
            source.kind = .image
        } else if host == "app.screencast.com" {
            var request = URLRequest(url: original); request.timeoutInterval = 30
            let response = try await client.data(for: request)
            guard (200..<300).contains(response.statusCode), response.data.count < 3_000_000,
                  let html = String(data: response.data, encoding: .utf8) else { throw TaskContextError.invalid("Screencast page could not be read.") }
            let media = try ScreencastMedia.parse(html)
            source.kind = media.kind; mediaURL = media.url
            guard mediaURL.host?.lowercased() == "cdn.screencast.com" else { throw TaskContextError.invalid("Screencast returned an unexpected media host.") }
        } else if ["mp4", "mov", "webm"].contains(original.pathExtension.lowercased()) {
            source.kind = .video
        } else { source.kind = .image }
        if source.kind == .video { source.status = .pending; source.resolvedURL = mediaURL.absoluteString; return source }
        var request = URLRequest(url: mediaURL); request.timeoutInterval = 90
        let response: HTTPResult
        if lightshot {
            do { response = try await client.data(for: request, redirectPolicy: .init(allowedHosts: ["img.lightshot.app"])) }
            catch is HTTPRedirectError { throw TaskContextError.invalid("Lightshot media URL was rejected.") }
            catch { throw TaskContextError.invalid("Lightshot image response is invalid.") }
        } else {
            response = try await client.data(for: request)
        }
        guard (200..<300).contains(response.statusCode), !response.data.isEmpty, response.data.count <= 30_000_000,
              let image = CGImageSourceCreateWithData(response.data as CFData, nil),
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
            throw TaskContextError.invalid(lightshot ? "Lightshot image response is invalid." : "The linked image could not be downloaded or decoded.")
        }
        try Task.checkCancellation()
        let directory = try paths.feedbackDirectory(id: batchID)
        let type = (CGImageSourceGetType(image) as String?) ?? ""
        let name = input.id + (type.contains("png") ? ".png" : ".jpg")
        let destination = directory.appending(path: name)
        try response.data.write(to: destination, options: .atomic)
        source.kind = .image; source.status = .ready; source.localPath = paths.relativePath(for: destination)
        source.resolvedURL = mediaURL.absoluteString
        do {
            source.ocrText = try await recognizeText(destination)
            source.error = nil
        } catch {
            try Task.checkCancellation()
            source.error = "OCR failed; image remains available."
        }
        return source
    }
}

private enum LightshotPage {
    static func screenshotURL(in html: String) -> String? {
        guard let tags = try? NSRegularExpression(pattern: #"<(img|meta)\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        var fallback: String?
        for match in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let attributes = parseAttributes(tag)
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            if name == "img", attributes["id"]?.lowercased() == "screenshot-image",
               let src = attributes["src"], !src.isEmpty { return src }
            if name == "meta", attributes["property"]?.lowercased() == "og:image",
               let content = attributes["content"], !content.isEmpty { fallback = content }
        }
        return fallback
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([^\s=/>]+)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#) else { return [:] }
        let ns = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)).dropFirst() {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).first(where: { match.range(at: $0).location != NSNotFound })
                .map { ns.substring(with: match.range(at: $0)) } ?? ""
            result[key] = decodeEntities(value)
        }
        return result
    }

    private static func decodeEntities(_ input: String) -> String {
        var result = input
        if let numeric = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);?"#) {
            let ns = result as NSString
            for match in numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let literal = ns.substring(with: match.range(at: 1))
                let value = literal.hasPrefix("x") ? UInt32(literal.dropFirst(), radix: 16) : UInt32(literal, radix: 10)
                if let value, let scalar = Unicode.Scalar(value), let range = Range(match.range, in: result) {
                    result.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        return result.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
