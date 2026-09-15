import Foundation

public struct ScreenshotPlanner: Sendable {
    public let periodicInterval: TimeInterval
    public let minimumSeparation: TimeInterval

    public init(periodicInterval: TimeInterval = 30, minimumSeparation: TimeInterval = 2) {
        self.periodicInterval = periodicInterval
        self.minimumSeparation = minimumSeparation
    }

    public func timestamps(
        duration: TimeInterval,
        sceneChanges: [TimeInterval] = [],
        transcriptCues: [TimeInterval] = []
    ) -> [TimeInterval] {
        guard duration > 0 else { return [] }
        var candidates = [TimeInterval(0)]
        if periodicInterval > 0 {
            var timestamp = periodicInterval
            while timestamp < duration {
                candidates.append(timestamp)
                timestamp += periodicInterval
            }
        }
        candidates.append(contentsOf: sceneChanges)
        candidates.append(contentsOf: transcriptCues)

        var result: [TimeInterval] = []
        for candidate in candidates.filter({ $0 >= 0 && $0 <= duration }).sorted() {
            if let last = result.last, candidate - last < minimumSeparation { continue }
            result.append(candidate)
        }
        return result
    }
}
