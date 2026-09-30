import VideoContextCore

enum FeedbackTaskVisibility {
    static func visible(_ tasks: [FeedbackTask], showRemoved: Bool) -> [FeedbackTask] {
        tasks.filter { $0.archived == showRemoved }
    }

    static func activeSelection(_ selected: Set<String>, tasks: [FeedbackTask]) -> Set<String> {
        let activeIDs = Set(tasks.lazy.filter { !$0.archived }.map(\.id))
        return selected.intersection(activeIDs)
    }
}
