import Foundation
import GRDB

public extension VideoContextStore {
    static func validateDecisionOwnership(_ sections: [ProjectDocumentationSection], projectID: String, db: Database) throws {
        for id in Set(sections.flatMap(\.decisionIDs)) {
            guard try String.fetchOne(db, sql: "SELECT id FROM project_decisions WHERE id=? AND project_id=?", arguments: [id, projectID]) != nil else {
                throw ProjectDocumentationStoreError.invalidEvidence("A linked decision is missing or belongs to another project.")
            }
        }
    }

    /// A documentation section may cite a shared decision in addition to
    /// citing the source material that supports it. Direct source citations
    /// can still be current while the decision has since become unresolved,
    /// superseded, or changed to a revision with stale evidence. Review,
    /// request creation, and proposal acceptance must gate on the decision's
    /// current state as well as its evidence.
    static func validateCurrentDocumentationDecisions(_ sections: [ProjectDocumentationSection], projectID: String, db: Database) throws {
        for id in Set(sections.flatMap(\.decisionIDs)) {
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_decisions WHERE id=? AND project_id=?", arguments: [id, projectID]) else {
                throw ProjectDocumentationStoreError.invalidEvidence("Linked decision \(id) is missing or belongs to another project. Review the linked product decision and its evidence in Documentation before reviewing this work.")
            }
            let decision = try Self.decision(from: row)
            guard decision.projectID == projectID, decision.state == .confirmed,
                  !decision.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectDocumentationStoreError.invalidEvidence("Linked decision \(id) is not confirmed. Review the linked product decision and its evidence in Documentation before reviewing this work.")
            }
            do {
                try validateCurrentDocumentationEvidence(decision.evidence, projectID: projectID, db: db)
            } catch {
                throw ProjectDocumentationStoreError.invalidEvidence("Linked decision \(id) has stale or missing evidence. Review the linked product decision and its evidence in Documentation before reviewing this work.")
            }
        }
    }

    static func validateTaskDecisions(_ content: TaskContent, projectID: String?, db: Database) throws {
        for id in Set(content.questions.compactMap(\.sharedDecisionID)) {
            guard let projectID, try db.tableExists("project_decisions"),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM project_decisions WHERE id=? AND project_id=?", arguments: [id, projectID]) else {
                throw ProjectDocumentationStoreError.invalidEvidence("A linked product decision is unavailable. Review its ownership and evidence in Documentation before reviewing this task.")
            }
            let decision = try Self.decision(from: row)
            guard decision.state == .confirmed, !decision.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectDocumentationStoreError.invalidEvidence("Confirm the linked product decision in Documentation before reviewing this task.")
            }
            do { try validateCurrentDocumentationEvidence(decision.evidence, projectID: projectID, db: db) }
            catch { throw ProjectDocumentationStoreError.invalidEvidence("Review the linked product decision and its current evidence in Documentation before reviewing this task.") }
        }
    }

    func currentDecisionEvidence(_ decision: ProjectDecision) throws -> [ProjectEvidenceReference] {
        try pool.read { db in
            let refs = try decision.evidence.map { reference -> ProjectEvidenceReference in
                switch reference {
                case .recording(let id, _, let timestamp, let evidenceID):
                    guard let video = try Self.fetchVideo(id: id, from: db), video.projectID == decision.projectID else { throw TaskContextError.reviewRequired }
                    return .recording(videoID: id, sourceRevision: video.revisions, timestamp: timestamp, evidenceID: evidenceID)
                case .feedback(let id, _, let commentID, let sourceID):
                    let batch = try Self.feedbackBatch(id, in: db)
                    return .feedback(batchID: id, sourceRevision: batch.revision, commentID: commentID, sourceID: sourceID)
                case .document(let id, _, let locator):
                    guard let revision = try Self.documentSourceRevision(sourceID: id, db: db) else { throw TaskContextError.reviewRequired }
                    return .document(sourceID: id, revision: revision.revision, locator: locator)
                case .reviewedDocumentation(let id, _, let sectionID):
                    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [id, decision.projectID]) else {
                        throw TaskContextError.reviewRequired
                    }
                    let document = try Self.documentation(from: row)
                    guard let reviewedRevision = document.reviewedRevision,
                          reviewedRevision == document.currentRevision,
                          sectionID == nil || document.sections.contains(where: { $0.id == sectionID }) else {
                        throw TaskContextError.reviewRequired
                    }
                    return .reviewedDocumentation(documentID: id, revision: reviewedRevision, sectionID: sectionID)
                }
            }
            try Self.validateCurrentDocumentationEvidence(refs, projectID: decision.projectID, db: db)
            return refs
        }
    }
    static func invalidateDecisionDependents(_ decision: ProjectDecision, db: Database) throws {
        let workspace = try projectWorkspace(projectID: decision.projectID, db: db)
        for task in workspace.tasks where task.content.questions.contains(where: { $0.sharedDecisionID == decision.id && $0.sharedDecisionRevision != nil && $0.sharedDecisionRevision != decision.revision }) {
            try changeTaskQuestions(task.reference, projectID: decision.projectID, db: db) { question in
                guard question.sharedDecisionID == decision.id, question.sharedDecisionRevision != nil, question.sharedDecisionRevision != decision.revision else { return }
                let notice = "Shared decision changed to revision \(decision.revision): \(decision.answer). Review this answer."
                if !question.disagreement.contains(notice) { question.disagreement += (question.disagreement.isEmpty ? "" : "\n") + notice }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM project_documentation WHERE project_id=?", arguments: [decision.projectID]) {
            var document = try documentation(from: row)
            guard document.sections.contains(where: { $0.decisionIDs.contains(decision.id) }) else { continue }
            document.reviewedRevision = nil
            try db.execute(sql: "UPDATE project_documentation SET reviewed_revision=NULL,document=? WHERE id=?", arguments: [try JSONEncoder().encode(document), document.id])
        }
        // A proposal may still point at the same document revision while its
        // linked decision has changed. Persist that stale state immediately so
        // proposal consumers cannot accept an outdated pending proposal from
        // a cached or pre-move snapshot.
        if try db.tableExists("project_documentation_proposals") {
            for row in try Row.fetchAll(db, sql: "SELECT * FROM project_documentation_proposals WHERE project_id=? AND state=?", arguments: [decision.projectID, ProjectDocumentationProposalState.pending.rawValue]) {
                var proposal = try proposal(from: row)
                guard proposal.sections.contains(where: { $0.decisionIDs.contains(decision.id) }) else { continue }
                proposal.isStale = true
                proposal.updatedAt = .now
                try updateProposal(proposal, database: db)
            }
        }
    }

    static func normalizedProductQuestion(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func proposeProjectQuestionGroups(projectID: String) throws -> [ProjectQuestionGroupProposal] {
        try pool.write { db in
            let workspace = try Self.projectWorkspace(projectID: projectID, db: db)
            let existing = try Self.projectDocumentationSnapshot(projectID: projectID, db: db)
            var questions: [String: [(ProjectTaskReference, TaskQuestion)]] = [:]
            for task in workspace.tasks where !task.archived {
                for question in task.content.questions where question.sharedDecisionID == nil && (question.category == nil || question.category == .productDecision) {
                    let key = Self.normalizedProductQuestion(question.question)
                    if !key.isEmpty { questions[key, default: []].append((task.reference, question)) }
                }
            }
            var added: [ProjectQuestionGroupProposal] = []
            for (key, items) in questions.sorted(by: { $0.key < $1.key }) where items.count > 1 {
                let ids = Set(items.map { $0.1.id })
                let revisions = Dictionary(uniqueKeysWithValues: workspace.tasks.filter { task in items.contains { $0.0 == task.reference } }.map { ($0.reference.id, $0.revision) })
                guard !existing.questionGroups.contains(where: { $0.state == .pending && Set($0.questionIDs) == ids && $0.expectedTaskRevisions == revisions }) else { continue }
                let decision = existing.decisions.first { Self.normalizedProductQuestion($0.question) == key }
                var group = ProjectQuestionGroupProposal(projectID: projectID, normalizedQuestion: items[0].1.question,
                    questionIDs: ids.sorted(), taskIDs: items.map(\.0), suggestedDecisionID: decision?.id)
                group.expectedTaskRevisions = revisions
                try db.execute(sql: "INSERT INTO project_question_group_proposals(id,project_id,state,document,created_at,updated_at) VALUES(?,?,?,?,?,?)",
                    arguments: [group.id, projectID, group.state.rawValue, try JSONEncoder().encode(group), group.createdAt.timeIntervalSince1970, group.updatedAt.timeIntervalSince1970])
                added.append(group)
            }
            return added
        }
    }

    func resolveProjectQuestionGroup(id: String, projectID: String, accept: Bool) throws {
        try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_question_group_proposals WHERE id=? AND project_id=?", arguments: [id, projectID]) else { throw TaskContextError.missing(id) }
            var group = try Self.questionGroup(from: row)
            guard group.state == .pending else { throw TaskContextError.conflict }
            if accept {
                let snapshot = try Self.projectWorkspace(projectID: projectID, db: db)
                guard group.taskIDs.allSatisfy({ ref in snapshot.tasks.contains { $0.reference == ref } }) else { throw TaskContextError.conflict }
                let members = snapshot.tasks.filter { group.taskIDs.contains($0.reference) }
                if let revisions = group.expectedTaskRevisions {
                    guard members.allSatisfy({ revisions[$0.reference.id] == $0.revision }) else { throw TaskContextError.conflict }
                }
                let questions = members.flatMap { $0.content.questions }.filter { group.questionIDs.contains($0.id) }
                guard Set(questions.map(\.id)) == Set(group.questionIDs), questions.allSatisfy({ Self.normalizedProductQuestion($0.question) == Self.normalizedProductQuestion(group.normalizedQuestion) }) else { throw TaskContextError.conflict }
                var decision: ProjectDecision
                if let id = group.suggestedDecisionID, let row = try Row.fetchOne(db, sql: "SELECT * FROM project_decisions WHERE id=? AND project_id=?", arguments: [id, projectID]) { decision = try Self.decision(from: row) }
                else {
                    decision = .init(projectID: projectID, key: Self.normalizedProductQuestion(group.normalizedQuestion), question: group.normalizedQuestion)
                    try db.execute(sql: "INSERT INTO project_decisions(id,project_id,revision,document,updated_at) VALUES(?,?,?,?,?)", arguments: [decision.id, projectID, decision.revision, try JSONEncoder().encode(decision), decision.updatedAt.timeIntervalSince1970])
                }
                for reference in Set(group.taskIDs) {
                    try Self.changeTaskQuestions(reference, projectID: projectID, db: db) { question in
                        guard group.questionIDs.contains(question.id) else { return }
                        question.category = .productDecision; question.sharedDecisionID = decision.id
                        question.sharedDecisionRevision = decision.revision
                    }
                }
            }
            group.state = accept ? .accepted : .rejected; group.updatedAt = .now
            try db.execute(sql: "UPDATE project_question_group_proposals SET state=?,document=?,updated_at=? WHERE id=?", arguments: [group.state.rawValue, try JSONEncoder().encode(group), group.updatedAt.timeIntervalSince1970, id])
        }
    }

    func applyProjectDecision(id: String, projectID: String, expectedRevision: Int) throws -> Int {
        try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_decisions WHERE id=? AND project_id=?", arguments: [id, projectID]) else { throw TaskContextError.missing(id) }
            let decision = try Self.decision(from: row)
            guard decision.revision == expectedRevision, decision.state == .confirmed, !decision.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskContextError.conflict }
            try Self.validateCurrentDocumentationEvidence(decision.evidence, projectID: projectID, db: db)
            let snapshot = try Self.projectWorkspace(projectID: projectID, db: db)
            var count = 0
            for task in snapshot.tasks where !task.archived {
                try Self.changeTaskQuestions(task.reference, projectID: projectID, db: db) { question in
                    guard question.sharedDecisionID == id, question.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    question.answer = decision.answer; question.sharedDecisionRevision = decision.revision; count += 1
                }
            }
            return count
        }
    }

    private static func changeTaskQuestions(_ reference: ProjectTaskReference, projectID: String, db: Database, change: (inout TaskQuestion) -> Void) throws {
        switch reference {
        case .recording(let videoID, let taskID):
            guard let video = try fetchVideo(id: videoID, from: db), video.projectID == projectID,
                  var task = try fetchTasks(videoID: videoID, db: db).first(where: { $0.id == taskID }) else { throw TaskContextError.conflict }
            let before = task.content
            for i in task.content.questions.indices { change(&task.content.questions[i]) }
            if task.content != before { task.revision += 1; task.reviewedRevision = nil; try writeTask(task, db: db) }
        case .feedback(let batchID, let taskID):
            let batch = try feedbackBatch(batchID, in: db)
            guard batch.projectID == projectID, var task = try feedbackTasks(batchID, in: db).first(where: { $0.id == taskID }) else { throw TaskContextError.conflict }
            let before = task.content
            for i in task.content.questions.indices { change(&task.content.questions[i]) }
            if task.content != before { task.revision += 1; task.approvedRevision = nil; try writeFeedbackTask(task, in: db) }
        }
    }

    func createDocumentationRequest(projectID: String, documentID: String, expectedRevision: Int, sectionIDs: Set<String>) throws -> FeedbackBatch {
        try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [documentID, projectID]) else { throw TaskContextError.missing(documentID) }
            let document = try Self.documentation(from: row)
            guard document.currentRevision == expectedRevision, document.isReviewed, !sectionIDs.isEmpty,
                sectionIDs.isSubset(of: Set(document.sections.map(\.id))) else { throw TaskContextError.reviewRequired }
            let sections = document.sections.filter { sectionIDs.contains($0.id) }
            try Self.validateCurrentDocumentationEvidence(sections.flatMap(\.evidence), projectID: projectID, db: db)
            try Self.validateCurrentDocumentationDecisions(sections, projectID: projectID, db: db)
            let project = try String.fetchOne(db, sql: "SELECT name FROM feedback_projects WHERE id=?", arguments: [projectID]) ?? projectID
            let text = sections.map { "\($0.title)\n\($0.body)" }.joined(separator: "\n\n")
            var batch = FeedbackBatch(projectID: projectID, title: document.title + " request", project: project, rawText: text)
            var source = FeedbackSource(kind: .document, status: .ready, filename: document.title, ocrText: text)
            source.documentID = documentID; source.documentRevision = expectedRevision; source.documentSectionIDs = sectionIDs.sorted()
            batch.sources = [source]
            batch.comments = sections.map { .init(text: "\($0.title)\n\($0.body)", sourceIDs: [source.id], kind: .request) }
            try Self.validateFeedback(batch)
            try db.execute(sql: "INSERT INTO feedback_batches(id,updated_at,document) VALUES(?,?,?)", arguments: [batch.id, batch.updatedAt.timeIntervalSince1970, try JSONEncoder().encode(batch)])
            return batch
        }
    }

    static func validateCurrentDocumentationEvidence(_ references: [ProjectEvidenceReference], projectID: String, db: Database) throws {
        try validateEvidence(references, projectID: projectID, database: db)
        try validateCurrentDocumentAssets(references, projectID: projectID, database: db)
        for reference in references {
            switch reference {
            case .recording(let id, let rev, _, _):
                guard let video = try fetchVideo(id: id, from: db), video.projectID == projectID, video.revisions == rev else { throw TaskContextError.reviewRequired }
            case .feedback(let id, let rev, _, _):
                let batch = try feedbackBatch(id, in: db)
                guard batch.projectID == projectID, batch.revision == rev else { throw TaskContextError.reviewRequired }
            case .document(let id, let rev, _):
                guard let current = try Row.fetchOne(db, sql: "SELECT current_revision,project_id FROM project_document_sources WHERE id=?", arguments: [id]), current["current_revision"] as Int == rev, current["project_id"] as String == projectID else { throw TaskContextError.reviewRequired }
            case .reviewedDocumentation(let id, let rev, _):
                guard let current = try Row.fetchOne(db, sql: "SELECT current_revision,reviewed_revision,project_id FROM project_documentation WHERE id=?", arguments: [id]),
                      current["current_revision"] as Int == rev,
                      current["reviewed_revision"] as Int? == rev,
                      current["project_id"] as String == projectID else { throw TaskContextError.reviewRequired }
            }
        }
    }

    static func validateDocumentationRequest(_ batch: FeedbackBatch, db: Database) throws {
        for source in batch.sources where source.kind == .document {
            guard let projectID = batch.projectID, let id = source.documentID, let revision = source.documentRevision,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM project_documentation WHERE id=? AND project_id=?", arguments: [id, projectID]) else { throw TaskContextError.reviewRequired }
            let document = try documentation(from: row)
            guard document.currentRevision == revision, document.isReviewed else { throw TaskContextError.reviewRequired }
            let sections = document.sections.filter { source.documentSectionIDs?.contains($0.id) == true }
            guard !sections.isEmpty else { throw TaskContextError.reviewRequired }
            try validateCurrentDocumentationEvidence(sections.flatMap(\.evidence), projectID: projectID, db: db)
            try validateCurrentDocumentationDecisions(sections, projectID: projectID, db: db)
        }
    }
}
