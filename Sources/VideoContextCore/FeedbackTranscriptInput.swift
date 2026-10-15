import Foundation

/// Recognizes pasted recording transcripts before the line-based issue parser runs.
enum FeedbackTranscriptInput {
    static func split(_ raw: String) -> (comments: String, transcript: String)? {
        let heading = try! NSRegularExpression(
            pattern: #"^[\t #*]*(?:video[\t ]+)?transcript[\t :*]*\r?$"#,
            options: [.caseInsensitive, .anchorsMatchLines])
        let range = NSRange(raw.startIndex..., in: raw)
        if let match = heading.firstMatch(in: raw, range: range), let headingRange = Range(match.range, in: raw) {
            let transcript = String(raw[headingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { return (String(raw[..<headingRange.lowerBound]), transcript) }
        }

        // Loom copies can put all timestamped passages on one line or one passage per line.
        let timestamp = try! NSRegularExpression(pattern: #"(?:^|\s)(?:\d{1,2}:)?\d{1,3}:[0-5]\d[\t ]+(?=\S)"#)
        let matches = timestamp.matches(in: raw, range: range)
        guard matches.count >= 2, let first = matches.first, let firstRange = Range(first.range, in: raw) else { return nil }
        let start = raw[firstRange].first?.isWhitespace == true ? raw.index(after: firstRange.lowerBound) : firstRange.lowerBound
        // A time mentioned inside an ordinary issue is not a transcript boundary.
        let prefix = raw[..<start]
        let precedingLine = prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        guard precedingLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (String(prefix), String(raw[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
