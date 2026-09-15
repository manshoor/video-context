import Foundation

public enum FFmpegOutputParser {
    public static func sceneTimestamps(_ output: String, minimumSeparation: TimeInterval = 1) -> [TimeInterval] {
        let pattern = #"pts_time:([0-9]+(?:\.[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let values = expression.matches(in: output, range: range).compactMap { match -> TimeInterval? in
            guard let matchRange = Range(match.range(at: 1), in: output) else { return nil }
            return TimeInterval(output[matchRange])
        }.sorted()
        var result: [TimeInterval] = []
        for value in values {
            if let last = result.last, value - last < minimumSeparation { continue }
            result.append(value)
        }
        return result
    }

    public static func silenceEndTimestamps(_ output: String) -> [TimeInterval] {
        let pattern = #"silence_end:\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return expression.matches(in: output, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: output) else { return nil }
            return TimeInterval(output[matchRange])
        }
    }
}
