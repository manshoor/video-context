import Foundation

public struct FeedbackConsolidationPlan: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public let members: [Int]
        public let text: String
        public init(members: [Int], text: String) { self.members = members; self.text = text }
    }
    public struct AdditionalQuestion: Codable, Equatable, Sendable {
        public let question: String
        public let sourceIDs: [String]
        public init(question: String, sourceIDs: [String]) { self.question = question; self.sourceIDs = sourceIDs }
    }
    public let title: String
    public let behavior: String
    public let requirements: [Group]
    public let checks: [Group]
    public let questions: [Group]
    public let additionalQuestions: [AdditionalQuestion]
    public init(title: String, behavior: String, requirements: [Group], checks: [Group], questions: [Group],
                additionalQuestions: [AdditionalQuestion]) {
        self.title = title; self.behavior = behavior; self.requirements = requirements; self.checks = checks
        self.questions = questions; self.additionalQuestions = additionalQuestions
    }
}

private struct FeedbackConsolidationInput: Codable, Sendable {
    struct Item: Codable, Sendable {
        let index: Int
        let text: String
        let origin: String?
        let sourceIDs: [String]
        let locked: Bool
    }
    let titles: [String]
    let behaviors: [String]
    let titleLocked: Bool
    let behaviorLocked: Bool
    let requirements: [Item]
    let checks: [Item]
    let questions: [Item]
}

private struct FeedbackConsolidationMaterial: Sendable {
    let input: FeedbackConsolidationInput
    let content: TaskContent
    let requirementLocked: Set<Int>
    let checkLocked: Set<Int>
    let questionLocked: Set<Int>
}

public struct FeedbackContentConsolidator<Client: HTTPDataLoading>: Sendable {
    public let client: Client
    public let configuration: ModelConfiguration
    public let credential: String

    public init(client: Client, configuration: ModelConfiguration, credential: String) {
        self.client = client; self.configuration = configuration; self.credential = credential
    }

    public func consolidate(content: TaskContent, generatedOriginal: TaskContent?) async throws -> TaskContent {
        let material = Self.material(content: content, generatedOriginal: generatedOriginal)
        let plan = try await requestValidatedPlan(material)
        return try Self.merge(plan, material: material)
    }

    public func consolidate(candidates: [GeneratedTask], originalFeedback: GeneratedTaskStatement) async throws -> GeneratedTask {
        guard let first = candidates.first, !candidates.isEmpty,
              Set(candidates.map(\.targetTaskID)).count == 1,
              Set(candidates.map { $0.primaryIssueID ?? "<missing>" }).count == 1 else {
            throw TaskContextError.invalid("Feedback consolidation received tasks from different issues or targets.")
        }
        let content = TaskContent(
            title: first.title,
            behavior: candidates.map(\.behavior).joined(separator: "\n"),
            requirements: [.init(text: originalFeedback.text, origin: originalFeedback.origin,
                                 sourceIDs: originalFeedback.sourceIDs)] + candidates.flatMap { task in
                task.requirements.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) }
            },
            checks: candidates.flatMap { task in
                task.checks.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) }
            },
            questions: candidates.flatMap { task in
                task.questions.map { .init(question: $0.question, sourceIDs: $0.sourceIDs) }
            },
            sourceIDs: Set(originalFeedback.sourceIDs + candidates.flatMap { Array($0.content.allSourceIDs) }).sorted(),
            dependencyTaskIDs: Array(Set(candidates.flatMap { $0.dependencyTaskIDs ?? [] })).sorted()
        )
        let material = Self.generatedMaterial(candidates: candidates, content: content)
        let plan = try await requestValidatedPlan(material)
        let merged = try Self.merge(plan, material: material)
        return .init(targetTaskID: first.targetTaskID, title: merged.title, behavior: merged.behavior,
            requirements: merged.requirements.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) },
            checks: merged.checks.map { .init(text: $0.text, origin: $0.origin, sourceIDs: $0.sourceIDs) },
            questions: merged.questions.map { .init(question: $0.question, sourceIDs: $0.sourceIDs) },
            sourceIDs: merged.sourceIDs, primaryIssueID: first.primaryIssueID,
            dependencyTaskIDs: merged.dependencyTaskIDs,
            projectEvidenceIDs: Array(Set(candidates.flatMap { $0.projectEvidenceIDs ?? [] })).sorted())
    }

    private func requestValidatedPlan(_ material: FeedbackConsolidationMaterial) async throws -> FeedbackConsolidationPlan {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalPrompt = String(decoding: try encoder.encode(material.input), as: UTF8.self)
        var prompt = originalPrompt
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                let request = try Self.request(prompt: prompt, material: material, configuration: configuration,
                                               credential: credential)
                let response = try await UsageTrace.$stage.withValue(.taskConsolidation) { try await client.data(for: request) }
                let plan = try Self.decode(response, provider: configuration.analysisProvider)
                try Self.validate(plan, material: material)
                return plan
            } catch {
                guard attempt == 0, Self.isRecoverable(error) else { throw error }
                prompt = originalPrompt + "\n\nRECOVERY ATTEMPT 1 OF 1. The consolidation plan was rejected: \(error.localizedDescription) Return the complete corrected plan and assign every indexed item exactly once."
            }
        }
        throw LocalProviderError.invalidOutput
    }

    private static func request(prompt: String, material: FeedbackConsolidationMaterial,
                                configuration: ModelConfiguration, credential: String) throws -> URLRequest {
        let allowedSources = material.content.allSourceIDs.sorted()
        func groupSchema(count: Int) -> [String: Any] {
            let member: [String: Any] = count == 0 ? ["type": "integer"] : ["type": "integer", "enum": Array(0..<count)]
            return ["type": "object", "additionalProperties": false, "required": ["members", "text"], "properties": [
                "members": ["type": "array", "minItems": 1, "items": member],
                "text": ["type": "string", "minLength": 1, "pattern": #"\S"#]
            ]]
        }
        let source: [String: Any] = allowedSources.isEmpty ? ["type": "string"] : ["type": "string", "enum": allowedSources]
        let additionalQuestion: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["question", "sourceIDs"], "properties": [
                "question": ["type": "string", "minLength": 1, "pattern": #"\S"#],
                "sourceIDs": ["type": "array", "minItems": 1, "items": source]
            ]]
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["title", "behavior", "requirements", "checks", "questions", "additionalQuestions"],
            "properties": [
                "title": ["type": "string", "minLength": 1, "maxLength": 200, "pattern": #"\S"#],
                "behavior": ["type": "string", "minLength": 1, "pattern": #"\S"#],
                "requirements": ["type": "array", "items": groupSchema(count: material.input.requirements.count)],
                "checks": ["type": "array", "items": groupSchema(count: material.input.checks.count)],
                "questions": ["type": "array", "items": groupSchema(count: material.input.questions.count)],
                "additionalQuestions": ["type": "array", "items": additionalQuestion]
            ]]
        let instructions = """
        Consolidate repeated task content by meaning. Return a consolidation plan, not a summary of the input. Assign every indexed requirement, check, and question exactly once. Combine only equivalent statements. Preserve distinct facts, evidence, and unresolved questions. Keep contradictory statements in separate groups and add a precise unresolved question citing every conflicting source. Never merge content from different issues. Do not truncate lists. Write one coherent requested behavior. A locked title or behavior must be returned unchanged. If a group contains a locked item, use that locked text unchanged; never place two different locked texts in one group. The app unions citations and preserves IDs, answers, annotations, and history.
        """
        return try AnalysisAdapter.request(configuration: configuration, credential: credential, prompt: prompt,
            images: [], schema: schema, name: "video_context_feedback_consolidation", instructions: instructions,
            maxTokens: configuration.analysisProvider == .lmStudio ? 4096 : 8192)
    }

    private static func decode(_ response: HTTPResult, provider: AnalysisProvider) throws -> FeedbackConsolidationPlan {
        let text = try AnalysisAdapter.output(response, provider: provider)
        return try JSONDecoder().decode(FeedbackConsolidationPlan.self, from: Data(text.utf8))
    }

    private static func validate(_ plan: FeedbackConsolidationPlan, material: FeedbackConsolidationMaterial) throws {
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonempty(plan.title), plan.title.count <= 200, nonempty(plan.behavior) else {
            throw TaskContextError.invalid("Consolidated title or behavior is empty or too long.")
        }
        if material.input.titleLocked, plan.title != material.content.title {
            throw TaskContextError.invalid("Consolidation changed the user-edited title.")
        }
        if material.input.behaviorLocked, plan.behavior != material.content.behavior {
            throw TaskContextError.invalid("Consolidation changed the user-edited behavior.")
        }
        try validateGroups(plan.requirements, items: material.input.requirements, locked: material.requirementLocked,
                           label: "requirements")
        try validateGroups(plan.checks, items: material.input.checks, locked: material.checkLocked, label: "checks")
        try validateGroups(plan.questions, items: material.input.questions, locked: material.questionLocked, label: "questions")
        let allowed = material.content.allSourceIDs
        guard plan.additionalQuestions.allSatisfy({ nonempty($0.question) && !$0.sourceIDs.isEmpty && Set($0.sourceIDs).isSubset(of: allowed) }) else {
            throw TaskContextError.invalid("Consolidation added a question without valid evidence citations.")
        }
    }

    private static func validateGroups(_ groups: [FeedbackConsolidationPlan.Group],
                                       items: [FeedbackConsolidationInput.Item], locked: Set<Int>, label: String) throws {
        let members = groups.flatMap(\.members)
        guard groups.allSatisfy({ !$0.members.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              members.sorted() == Array(items.indices) else {
            let missing = items.indices.filter { !members.contains($0) }
            let duplicates = Set(members.filter { value in members.filter { $0 == value }.count > 1 }).sorted()
            throw TaskContextError.invalid("Consolidation \(label) assignments are invalid. Missing indices: \(missing). Duplicate indices: \(duplicates).")
        }
        for group in groups {
            let protected = group.members.filter { locked.contains($0) }
            guard let first = protected.first else { continue }
            let protectedTexts = Set(protected.map { items[$0].text })
            guard protectedTexts.count == 1, group.text == items[first].text else {
                throw TaskContextError.invalid("Consolidation changed or combined incompatible user-edited \(label).")
            }
        }
    }

    private static func merge(_ plan: FeedbackConsolidationPlan, material: FeedbackConsolidationMaterial) throws -> TaskContent {
        func statements(_ groups: [FeedbackConsolidationPlan.Group], values: [TaskStatement], locked: Set<Int>) -> [TaskStatement] {
            groups.map { group in
                let protected = group.members.first { locked.contains($0) }
                var value = values[protected ?? group.members[0]]
                value.text = group.text
                value.sourceIDs = Set(group.members.flatMap { values[$0].sourceIDs }).sorted()
                if protected == nil {
                    let origins = Set(group.members.map { values[$0].origin })
                    value.origin = origins.count == 1 ? values[group.members[0]].origin : .interpretation
                }
                return value
            }
        }
        func questions(_ groups: [FeedbackConsolidationPlan.Group], values: [TaskQuestion], locked: Set<Int>) -> [TaskQuestion] {
            groups.map { group in
                let protected = group.members.first { locked.contains($0) }
                var value = values[protected ?? group.members[0]]
                value.question = group.text
                value.sourceIDs = Set(group.members.flatMap { values[$0].sourceIDs }).sorted()
                return value
            }
        }
        var output = material.content
        output.title = plan.title; output.behavior = plan.behavior
        output.requirements = statements(plan.requirements, values: material.content.requirements,
                                         locked: material.requirementLocked)
        output.checks = statements(plan.checks, values: material.content.checks, locked: material.checkLocked)
        output.questions = questions(plan.questions, values: material.content.questions, locked: material.questionLocked)
        output.questions += plan.additionalQuestions.map { .init(question: $0.question, sourceIDs: $0.sourceIDs) }
        output.sourceIDs = Set(material.content.sourceIDs + output.requirements.flatMap(\.sourceIDs) +
            output.checks.flatMap(\.sourceIDs) + output.questions.flatMap(\.sourceIDs)).sorted()
        return output
    }

    private static func material(content: TaskContent, generatedOriginal: TaskContent?) -> FeedbackConsolidationMaterial {
        let protectAll = generatedOriginal == nil
        let originalRequirements = Dictionary(uniqueKeysWithValues: (generatedOriginal?.requirements ?? []).map { ($0.id, $0) })
        let originalChecks = Dictionary(uniqueKeysWithValues: (generatedOriginal?.checks ?? []).map { ($0.id, $0) })
        let originalQuestions = Dictionary(uniqueKeysWithValues: (generatedOriginal?.questions ?? []).map { ($0.id, $0) })
        let requirementLocked = Set(content.requirements.indices.filter { index in
            let value = content.requirements[index], original = originalRequirements[value.id]
            return protectAll || value.origin == .user || original == nil || original?.text != value.text
        })
        let checkLocked = Set(content.checks.indices.filter { index in
            let value = content.checks[index], original = originalChecks[value.id]
            return protectAll || value.origin == .user || original == nil || original?.text != value.text
        })
        let questionLocked = Set(content.questions.indices.filter { index in
            let value = content.questions[index], original = originalQuestions[value.id]
            return protectAll || original == nil || original?.question != value.question || !value.answer.isEmpty ||
                !value.nonBlockingReason.isEmpty || !value.disagreement.isEmpty || !value.isBlocking
        })
        let titleLocked = protectAll || generatedOriginal?.title != content.title
        let behaviorLocked = protectAll || generatedOriginal?.behavior != content.behavior
        let input = FeedbackConsolidationInput(titles: [content.title], behaviors: [content.behavior],
            titleLocked: titleLocked, behaviorLocked: behaviorLocked,
            requirements: content.requirements.enumerated().map { .init(index: $0.offset, text: $0.element.text,
                origin: $0.element.origin.rawValue, sourceIDs: $0.element.sourceIDs, locked: requirementLocked.contains($0.offset)) },
            checks: content.checks.enumerated().map { .init(index: $0.offset, text: $0.element.text,
                origin: $0.element.origin.rawValue, sourceIDs: $0.element.sourceIDs, locked: checkLocked.contains($0.offset)) },
            questions: content.questions.enumerated().map { .init(index: $0.offset, text: $0.element.question,
                origin: nil, sourceIDs: $0.element.sourceIDs, locked: questionLocked.contains($0.offset)) })
        return .init(input: input, content: content, requirementLocked: requirementLocked,
                     checkLocked: checkLocked, questionLocked: questionLocked)
    }

    private static func generatedMaterial(candidates: [GeneratedTask], content: TaskContent) -> FeedbackConsolidationMaterial {
        let input = FeedbackConsolidationInput(titles: candidates.map(\.title), behaviors: candidates.map(\.behavior),
            titleLocked: false, behaviorLocked: false,
            requirements: content.requirements.enumerated().map { .init(index: $0.offset, text: $0.element.text,
                origin: $0.element.origin.rawValue, sourceIDs: $0.element.sourceIDs, locked: $0.offset == 0) },
            checks: content.checks.enumerated().map { .init(index: $0.offset, text: $0.element.text,
                origin: $0.element.origin.rawValue, sourceIDs: $0.element.sourceIDs, locked: false) },
            questions: content.questions.enumerated().map { .init(index: $0.offset, text: $0.element.question,
                origin: nil, sourceIDs: $0.element.sourceIDs, locked: false) })
        return .init(input: input, content: content, requirementLocked: [0], checkLocked: [], questionLocked: [])
    }

    private static func isRecoverable(_ error: Error) -> Bool {
        if let local = error as? LocalProviderError { return local == .invalidOutput }
        if error is DecodingError { return true }
        if case .invalid = error as? TaskContextError { return true }
        return false
    }
}
