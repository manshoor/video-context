import Foundation

public enum OpenAIResponseDecodingError: Error, LocalizedError, Equatable {
    case invalidResponse
    case missingOutputText

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenAI returned a response that could not be read."
        case .missingOutputText: "OpenAI returned no output text."
        }
    }
}

public enum OpenAIResponseDecoder {
    public static func transcriptSegments(from data: Data, videoID: String, chunkStart: TimeInterval) throws -> [TranscriptSegment] {
        struct Response: Decodable {
            struct Segment: Decodable {
                let start: TimeInterval
                let end: TimeInterval
                let text: String
            }
            let segments: [Segment]?
            let text: String
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OpenAIResponseDecodingError.invalidResponse
        }
        let raw = response.segments ?? [Response.Segment(start: 0, end: 0, text: response.text)]
        return raw.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return nil }
            return TranscriptSegment(
                videoID: videoID,
                start: chunkStart + segment.start,
                end: chunkStart + segment.end,
                originalText: text
            )
        }
    }

    public static func outputText(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Output: Decodable {
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                let content: [Content]?
            }
            let output: [Output]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OpenAIResponseDecodingError.invalidResponse
        }
        guard let text = response.output.lazy.compactMap(\.content).joined().first(where: { $0.type == "output_text" })?.text else {
            throw OpenAIResponseDecodingError.missingOutputText
        }
        return text
    }

    public static func errorMessage(from data: Data) -> String? {
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        return try? JSONDecoder().decode(Failure.self, from: data).error.message
    }

    public static func markdown(fromStructuredOutput text: String) -> String? {
        struct Output: Decodable { let markdown: String }
        return try? JSONDecoder().decode(Output.self, from: Data(text.utf8)).markdown
    }
}
