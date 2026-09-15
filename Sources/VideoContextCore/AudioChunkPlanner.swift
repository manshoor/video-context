import Foundation

public struct AudioChunk: Codable, Equatable, Sendable {
    public let index: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let contentStart: TimeInterval

    public var duration: TimeInterval { end - start }

    public init(index: Int, start: TimeInterval, end: TimeInterval, contentStart: TimeInterval) {
        self.index = index
        self.start = start
        self.end = end
        self.contentStart = contentStart
    }
}

public enum AudioChunkPlanningError: Error, Equatable {
    case invalidDuration
    case invalidConfiguration
}

public struct AudioChunkPlanner: Sendable {
    public let maxDuration: TimeInterval
    public let overlap: TimeInterval
    public let silenceSearchRadius: TimeInterval

    public init(maxDuration: TimeInterval, overlap: TimeInterval, silenceSearchRadius: TimeInterval = 30) {
        self.maxDuration = maxDuration
        self.overlap = overlap
        self.silenceSearchRadius = silenceSearchRadius
    }

    public func plan(duration: TimeInterval, silencePoints: [TimeInterval] = []) throws -> [AudioChunk] {
        guard duration >= 0 else { throw AudioChunkPlanningError.invalidDuration }
        guard maxDuration > 0, overlap >= 0, overlap < maxDuration, silenceSearchRadius >= 0 else {
            throw AudioChunkPlanningError.invalidConfiguration
        }
        guard duration > 0 else { return [] }

        var boundaries: [TimeInterval] = [0]
        var contentStart: TimeInterval = 0
        while contentStart + maxDuration < duration {
            let target = contentStart + maxDuration
            let candidates = silencePoints.filter {
                $0 > contentStart && abs($0 - target) <= silenceSearchRadius
            }
            let boundary = candidates.min { lhs, rhs in
                let leftDistance = abs(lhs - target)
                let rightDistance = abs(rhs - target)
                return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
            } ?? target
            guard boundary > contentStart else { throw AudioChunkPlanningError.invalidConfiguration }
            boundaries.append(boundary)
            contentStart = boundary
        }
        boundaries.append(duration)

        return boundaries.dropLast().enumerated().map { index, boundary in
            let nextBoundary = boundaries[index + 1]
            return AudioChunk(
                index: index,
                start: max(0, boundary - (index == 0 ? 0 : overlap)),
                end: min(duration, nextBoundary + (nextBoundary == duration ? 0 : overlap)),
                contentStart: boundary
            )
        }
    }
}
