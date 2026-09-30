import VideoContextCore

struct TaskPaneFilter {
    let tasks: [VideoTask]
    let proposals: [TaskProposal]

    init(tasks: [VideoTask], proposals: [TaskProposal], showQuestions: Bool, showArchived: Bool) {
        self.tasks = tasks.filter {
            $0.archived == showArchived && (!showQuestions || !Self.openQuestions(in: $0.content).isEmpty)
        }
        self.proposals = proposals.filter {
            !showArchived && (!showQuestions || !Self.openQuestions(in: $0.content).isEmpty)
        }
    }

    static func openQuestions(in content: TaskContent?) -> [TaskQuestion] {
        content?.questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
    }
}
