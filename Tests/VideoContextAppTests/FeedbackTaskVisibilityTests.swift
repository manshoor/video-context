import Testing
import VideoContextCore
@testable import VideoContextApp

struct FeedbackTaskVisibilityTests {
    @Test func removedTasksAreHiddenByDefaultAndExcludedFromSelection() {
        let active = task(archived: false)
        let removed = task(archived: true)

        #expect(FeedbackTaskVisibility.visible([active, removed], showRemoved: false).map(\.id) == [active.id])
        #expect(FeedbackTaskVisibility.visible([active, removed], showRemoved: true).map(\.id) == [removed.id])
        #expect(FeedbackTaskVisibility.activeSelection([active.id, removed.id], tasks: [active, removed]) == [active.id])
    }

    private func task(archived: Bool) -> FeedbackTask {
        var value = FeedbackTask(batchID: "fb_test", sourceRevision: 1,
            content: .init(title: archived ? "Removed" : "Active"))
        value.archived = archived
        return value
    }
}
