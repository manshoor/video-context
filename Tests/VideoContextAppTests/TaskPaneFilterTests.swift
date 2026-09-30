import Testing
import VideoContextCore
@testable import VideoContextApp

struct TaskPaneFilterTests {
    private let content = TaskContent(title: "Payment", questions: [.init(question: "How many retries?")])
    private func proposal(_ content: TaskContent?) -> TaskProposal {
        .init(videoID: "video", kind: content == nil ? .archive : .addition, sourceRevision: .init(), content: content,
              provenance: .init(provider: .lmStudio, model: "fixture"))
    }
    private func task(_ content: TaskContent, archived: Bool = false) -> VideoTask {
        var task = VideoTask(videoID: "video", sourceRevision: .init(), content: content)
        task.archived = archived
        return task
    }

    @Test func generatedProposalsParticipateInOpenQuestionsFilter() {
        let open = proposal(content), noQuestions = proposal(.init()), archive = proposal(nil)
        let saved = task(content)
        let filtered = TaskPaneFilter(tasks: [saved], proposals: [open, noQuestions, archive], showQuestions: true, showArchived: false)
        #expect(filtered.proposals.map(\.id) == [open.id])
        #expect(filtered.tasks.map(\.id) == [saved.id])
        let all = TaskPaneFilter(tasks: [saved], proposals: [open, noQuestions, archive], showQuestions: false, showArchived: false)
        #expect(all.proposals.count == 3)
    }

    @Test func whitespaceAnswersStayOpenAndNonBlockingQuestionsRemainVisible() {
        var whitespace = TaskQuestion(question: "Retry limit?"); whitespace.answer = " \n "
        var answered = TaskQuestion(question: "Button label?"); answered.answer = "Try again"
        var optional = TaskQuestion(question: "Animation?"); optional.isBlocking = false; optional.nonBlockingReason = "Optional polish"
        let content = TaskContent(questions: [whitespace, answered, optional])
        #expect(TaskPaneFilter.openQuestions(in: content).map(\.id) == [whitespace.id, optional.id])
    }

    @Test func emptyAndArchivedViewsReflectTheFilteredResults() {
        let active = task(content), archived = task(content, archived: true)
        let archiveView = TaskPaneFilter(tasks: [active, archived], proposals: [proposal(content)], showQuestions: true, showArchived: true)
        #expect(archiveView.proposals.isEmpty)
        #expect(archiveView.tasks.map(\.id) == [archived.id])
        let empty = TaskPaneFilter(tasks: [task(.init())], proposals: [proposal(.init()), proposal(nil)], showQuestions: true, showArchived: false)
        #expect(empty.tasks.isEmpty && empty.proposals.isEmpty)
    }
}
