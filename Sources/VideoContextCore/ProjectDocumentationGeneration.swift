import Foundation
import GRDB

public enum ProjectDocumentationGenerationError: Error, LocalizedError, Equatable, Sendable {
    case emptySelection
    case invalidSelection([String])
    case invalidProviderOutput
    case unknownEvidenceID(String)
    case budgetExceeded(sourceID: String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one recording, feedback batch, or document source before generating documentation."
        case .invalidSelection(let ids): "These sources are unavailable in the selected project: \(ids.joined(separator: ", "))."
        case .invalidProviderOutput: "The documentation provider returned an incomplete or invalid result. No documentation was saved."
        case .unknownEvidenceID(let id): "The documentation provider cited unknown evidence ID \(id). No documentation was saved."
        case .budgetExceeded(let sourceID): "The documentation source \(sourceID) could not be included within the configured analysis budget."
        }
    }
}

public extension VideoContextStore {
    /// Builds the complete, revision-pinned input for an explicit documentation-generation action.
    /// It never invokes a provider or writes to the library.
    func documentationGenerationInput(
        projectID: String,
        selectedSourceIDs: Set<String>? = nil,
        requestedTitle: String = "Product documentation",
        textBudget: Int = 48_000
    ) throws -> ProjectDocumentationGenerationInput {
        try pool.read { database in
            try Self.requireProject(projectID, in: database)
            let allVideos = try Self.allProjectVideos(database).filter { $0.projectID == projectID }
            let allBatches = try Self.allProjectBatches(database).filter { $0.projectID == projectID }
            let availableSourceIDs = Set(allVideos.map { "recording:\($0.id)" } + allBatches.map { "feedback:\($0.id)" } + (try Self.sources(projectID: projectID, database: database)).map { "document:\($0.id)" })
            let sourceIDs = selectedSourceIDs ?? availableSourceIDs
            let invalidSourceIDs = sourceIDs.subtracting(availableSourceIDs)
            guard invalidSourceIDs.isEmpty else { throw ProjectDocumentationGenerationError.invalidSelection(invalidSourceIDs.sorted()) }
            var sources: [ProjectDocumentationGenerationSource] = []

            for video in allVideos where sourceIDs.contains("recording:\(video.id)") {
                let transcript = try Row.fetchAll(database, sql: "SELECT * FROM transcript_segments WHERE video_id=? ORDER BY start_time,id", arguments: [video.id]).map(Self.transcript(from:))
                let evidence = try Row.fetchAll(database, sql: "SELECT * FROM evidence_items WHERE video_id=? ORDER BY timestamp,id", arguments: [video.id]).map(Self.evidence(from:))
                let brief = try Row.fetchOne(database, sql: "SELECT * FROM briefs WHERE video_id=?", arguments: [video.id]).map(Self.brief(from:))
                var lines = ["Recording: \(video.title)", "Status: \(video.status.rawValue)", "Revisions: transcript=\(video.revisions.transcript), evidence=\(video.revisions.evidence), brief=\(video.revisions.brief)"]
                if let brief { lines += ["", "Brief:", brief.markdown] }
                lines.append(contentsOf: transcript.map { "[\(Self.timestamp($0.start))–\(Self.timestamp($0.end))] \($0.text)" })
                lines.append(contentsOf: evidence.map { "[\(Self.timestamp($0.timestamp))] OCR: \($0.ocrText)" })
                let transcriptRefs = transcript.map { ProjectEvidenceReference.recording(videoID: video.id, sourceRevision: video.revisions, timestamp: $0.start, evidenceID: $0.id) }
                let frameRefs = evidence.map { ProjectEvidenceReference.recording(videoID: video.id, sourceRevision: video.revisions, timestamp: $0.timestamp, evidenceID: $0.id) }
                var imageEvidence: [String: [ProjectEvidenceReference]] = [:]
                for (item, reference) in zip(evidence, frameRefs) where !item.imageRelativePath.isEmpty {
                    imageEvidence[item.imageRelativePath, default: []].append(reference)
                }
                let refs = transcriptRefs + frameRefs
                sources.append(.init(id: "recording:\(video.id)", title: video.title, kind: "recording", revision: "transcript:\(video.revisions.transcript),evidence:\(video.revisions.evidence),brief:\(video.revisions.brief)", text: lines.joined(separator: "\n"), evidence: refs, imageRelativePaths: evidence.map(\.imageRelativePath), imageEvidence: imageEvidence))
            }

            for batch in allBatches where sourceIDs.contains("feedback:\(batch.id)") {
                var lines = ["Feedback batch: \(batch.title)", "Revision: \(batch.revision)"]
                var refs: [ProjectEvidenceReference] = []
                var images: [String] = []
                var imageEvidence: [String: [ProjectEvidenceReference]] = [:]
                func appendImage(_ path: String, reference: ProjectEvidenceReference) {
                    guard !path.isEmpty else { return }
                    if !images.contains(path) { images.append(path) }
                    imageEvidence[path, default: []].append(reference)
                }
                for comment in batch.comments {
                    lines.append("[Comment \(comment.id)] \(comment.text)")
                    let commentSources = batch.sources.filter { comment.sourceIDs.contains($0.id) }
                    for source in commentSources {
                        if !source.ocrText.isEmpty { lines.append("[Source \(source.id) OCR] \(source.ocrText)") }
                        let reference = ProjectEvidenceReference.feedback(batchID: batch.id, sourceRevision: batch.revision, commentID: comment.id, sourceID: source.id)
                        if let path = source.localPath { appendImage(path, reference: reference) }
                        refs.append(reference)
                    }
                    if commentSources.isEmpty { refs.append(.feedback(batchID: batch.id, sourceRevision: batch.revision, commentID: comment.id, sourceID: nil)) }
                }
                for sourceID in batch.batchWideSourceIDs {
                    guard let source = batch.sources.first(where: { $0.id == sourceID }) else { continue }
                    lines.append("[Batch-wide source \(source.id)]")
                    if !source.ocrText.isEmpty { lines.append("[Source \(source.id) OCR] \(source.ocrText)") }
                    let reference = ProjectEvidenceReference.feedback(batchID: batch.id, sourceRevision: batch.revision, commentID: nil, sourceID: source.id)
                    if let path = source.localPath { appendImage(path, reference: reference) }
                    refs.append(reference)
                }
                sources.append(.init(id: "feedback:\(batch.id)", title: batch.title, kind: "feedback", revision: "batch:\(batch.revision)", text: lines.joined(separator: "\n"), evidence: refs, imageRelativePaths: images, imageEvidence: imageEvidence))
            }

            if try Self.documentationSchemaAvailable(database) {
                let documentSources = try Self.sources(projectID: projectID, database: database)
                for source in documentSources where sourceIDs.contains("document:\(source.id)") {
                    guard let revision = try Self.sourceRevision(sourceID: source.id, revision: source.currentRevision, database: database) else { continue }
                    var text = ["Document source: \(source.name)", "Revision: \(revision.revision)"]
                    text.append(contentsOf: revision.units.map { unit in "[\(unit.locator.displayValue)] \(unit.text)" })
                    let refs = revision.units.map { ProjectEvidenceReference.document(sourceID: source.id, revision: revision.revision, locator: $0.locator) }
                        + revision.assets.map { ProjectEvidenceReference.document(sourceID: source.id, revision: revision.revision, locator: .init(asset: $0.sourcePath)) }
                    let images = revision.assets.compactMap(\.relativePath)
                    var imageEvidence: [String: [ProjectEvidenceReference]] = [:]
                    for asset in revision.assets {
                        guard let relativePath = asset.relativePath else { continue }
                        let reference = ProjectEvidenceReference.document(sourceID: source.id, revision: revision.revision, locator: .init(asset: asset.sourcePath))
                        imageEvidence[relativePath, default: []].append(reference)
                    }
                    sources.append(.init(id: "document:\(source.id)", title: source.name, kind: source.kind.rawValue, revision: "source:\(revision.revision)", text: text.joined(separator: "\n"), evidence: refs, imageRelativePaths: images, imageEvidence: imageEvidence))
                }
            }
            guard !sources.isEmpty else { throw ProjectDocumentationGenerationError.emptySelection }
            return .init(projectID: projectID, projectName: (try String.fetchOne(database, sql: "SELECT name FROM feedback_projects WHERE id=?", arguments: [projectID])) ?? projectID, requestedTitle: requestedTitle, sources: sources, textBudget: textBudget)
        }
    }

    static func timestamp(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded(.down))), minutes = total / 60, seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

public struct ProjectDocumentationGenerator<Client: HTTPDataLoading>: Sendable {
    private static var maximumImagesPerBatch: Int { 4 }

    public let client: Client
    public let configuration: ModelConfiguration
    public let credential: String
    public let paths: LibraryPaths?
    public let textBudget: Int
    /// Optional durable checkpoint storage for provider work.  A completed
    /// batch is decoded locally and reused; an uncertain provider outcome is
    /// left in the checkpoint store for explicit reconciliation.
    public let checkpointStore: VideoContextStore?

    public init(
        client: Client,
        configuration: ModelConfiguration,
        credential: String,
        paths: LibraryPaths? = nil,
        textBudget: Int = 48_000,
        checkpointStore: VideoContextStore? = nil
    ) {
        self.client = client
        self.configuration = configuration
        self.credential = credential
        self.paths = paths
        self.textBudget = max(4_096, textBudget)
        self.checkpointStore = checkpointStore
    }

    public func generate(input originalInput: ProjectDocumentationGenerationInput,
                         projectContext: ProjectAnalysisContext? = nil) async throws -> ProjectDocumentationGenerationResult {
        let input = crossReferencedInput(originalInput, projectContext: projectContext)
        guard !input.sources.isEmpty else { throw ProjectDocumentationGenerationError.emptySelection }
        let budget = min(textBudget, input.textBudget)
        let chunks = makeChunks(input.sources, budget: budget)
        var allSections: [ProjectDocumentationSection] = []
        var covered = Set<String>()
        for (index, chunk) in chunks.enumerated() {
            let batchSections = try await generateBatchWithCheckpoint(
                chunk,
                projectID: input.projectID,
                projectName: input.projectName,
                title: input.requestedTitle,
                index: index,
                total: chunks.count
            )
            let validIDs = Set(chunk.flatMap { $0.evidence.map(\.id) })
            for section in batchSections {
                let unknown = section.evidence.map(\.id).filter { !validIDs.contains($0) }
                if let first = unknown.first { throw ProjectDocumentationGenerationError.unknownEvidenceID(first) }
                covered.formUnion(chunk.filter { source in
                    let baseID = source.id.components(separatedBy: ":part").first ?? source.id
                    return section.evidence.contains { $0.sourceID == baseID || $0.id == baseID }
                }.map { $0.id.components(separatedBy: ":part").first ?? $0.id })
                allSections.append(section)
            }
            if batchSections.isEmpty { throw ProjectDocumentationGenerationError.invalidProviderOutput }
        }
        allSections = allSections.enumerated().map { index, section in var copy = section; copy.order = index; return copy }
        let selected = Set(input.sources.map(\.id))
        let signature = input.sources.map { "\($0.id)=\($0.revision)" }.sorted().joined(separator: "|")
        return .init(title: input.requestedTitle, sections: allSections, sourceIDsCovered: selected.intersection(covered).sorted(), sourceIDsOmitted: selected.subtracting(covered).sorted(), unresolvedQuestions: allSections.filter { $0.classification == .unresolved }.map(\.title), sourceSignature: signature)
    }

    private func crossReferencedInput(_ input: ProjectDocumentationGenerationInput,
                                      projectContext: ProjectAnalysisContext?) -> ProjectDocumentationGenerationInput {
        guard let projectContext else { return input }
        var sources = input.sources
        var includedEvidence = Set(sources.flatMap { $0.evidence.map(\.id) })
        for passage in projectContext.passages {
            let eligibleEvidence = passage.evidence.filter { reference in
                guard case .reviewedDocumentation(let documentID, _, _) = reference else { return true }
                return documentID != input.targetDocumentID
            }
            let newEvidence = eligibleEvidence.filter { includedEvidence.insert($0.id).inserted }
            sources.append(.init(id: "analysis-context:\(passage.id)", title: passage.title,
                kind: "projectContext:\(passage.kind.rawValue)", revision: passage.revision,
                text: passage.text, evidence: newEvidence))
        }
        for frame in projectContext.frames where includedEvidence.insert(frame.evidence.id).inserted {
            let relativePath = paths.map { $0.relativePath(for: frame.imageURL) }
            sources.append(.init(id: "analysis-context:\(frame.id)", title: "Original project frame",
                kind: "projectContext:image", revision: frame.sourceRevision,
                text: "Extracted OCR (separate from visual interpretation): \(frame.ocrText)",
                evidence: [frame.evidence], imageRelativePaths: relativePath.map { [$0] } ?? [],
                imageEvidence: relativePath.map { [$0: [frame.evidence]] }))
        }
        return .init(projectID: input.projectID, projectName: input.projectName,
            requestedTitle: input.requestedTitle, sources: sources, textBudget: input.textBudget,
            targetDocumentID: input.targetDocumentID)
    }

    private struct GeneratedSection: Codable, Sendable {
        let title: String
        let body: String
        let classification: String
        let evidenceIDs: [String]
        let sourceIDs: [String]
    }

    private struct GeneratedPayload: Codable, Sendable {
        let title: String
        let sections: [GeneratedSection]
    }

    private struct BatchFingerprint: Codable, Sendable {
        let projectID: String
        let projectName: String
        let title: String
        let index: Int
        let total: Int
        let configuration: ModelConfiguration
        let batch: [ProjectDocumentationGenerationSource]
    }

    private func generateBatchWithCheckpoint(
        _ sources: [ProjectDocumentationGenerationSource],
        projectID: String,
        projectName: String,
        title: String,
        index: Int,
        total: Int
    ) async throws -> [ProjectDocumentationSection] {
        guard let checkpointStore else {
            return try await generateBatch(sources, projectName: projectName, title: title, index: index, total: total)
        }

        // The key intentionally contains only stable request inputs.  The
        // checkpoint request ID is generated by the store and never enters
        // this fingerprint, so a retry can find the same batch.
        let key = try ProcessingFingerprint.make(
            BatchFingerprint(
                projectID: projectID,
                projectName: projectName,
                title: title,
                index: index,
                total: total,
                configuration: configuration,
                batch: sources
            ),
            salt: "video-context-documentation-analysis"
        )
        let checkpoint = try await checkpointStore.beginDocumentationAnalysis(projectID: projectID, key: key)
        if checkpoint.state == .completed {
            guard let result = checkpoint.result,
                  let sections = try? JSONDecoder().decode([ProjectDocumentationSection].self, from: result),
                  !sections.isEmpty else {
                throw ProjectDocumentationGenerationError.invalidProviderOutput
            }
            return sections
        }

        do {
            let sections = try await generateBatch(sources, projectName: projectName, title: title, index: index, total: total)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let result = try encoder.encode(sections)
            try await checkpointStore.completeDocumentationAnalysis(checkpoint, result: result)
            return sections
        } catch {
            // The provider may have completed even when decoding or local
            // validation failed. Preserve an unknown outcome until a user
            // explicitly reconciles it instead of issuing a duplicate call.
            try? await checkpointStore.failDocumentationAnalysis(checkpoint, error: error.localizedDescription)
            throw error
        }
    }

    private func generateBatch(_ sources: [ProjectDocumentationGenerationSource], projectName: String, title: String, index: Int, total: Int) async throws -> [ProjectDocumentationSection] {
        let evidenceIndex = Dictionary(sources.flatMap { source in source.evidence.map { ($0.id, $0) } }, uniquingKeysWith: { first, _ in first })
        var material = ""
        var images: [Data] = []
        var imageNumber = 0
        for source in sources {
            material += "\n\nSOURCE \(source.id) | \(source.title) | revision \(source.revision)\n"
            material += source.text
            material += "\nAllowed evidence IDs:\n" + source.evidence.map { "- \($0.id)" }.joined(separator: "\n")
            for relative in source.imageRelativePaths {
                let matchingEvidenceIDs = Self.imageEvidenceIDs(
                    for: source,
                    relativePath: relative
                )
                let evidenceLabel = matchingEvidenceIDs.isEmpty ? "unmapped" : matchingEvidenceIDs.joined(separator: ", ")
                guard let paths else {
                    material += "\nImage unavailable for visual review | path: \(relative) | matching evidence IDs: \(evidenceLabel)"
                    continue
                }
                let url = paths.absoluteURL(relativePath: relative)
                do {
                    // AnalysisAdapter sends every image as image/jpeg. The
                    // imported source can be PNG, HEIC, or a rendered PDF
                    // page, so normalize it before constructing the request.
                    let rendered = try await TaskFrameRenderer.render(url: url, annotations: [])
                    imageNumber += 1
                    material += "\nImage \(imageNumber) | path: \(relative) | matching evidence IDs: \(evidenceLabel)"
                    images.append(rendered)
                } catch {
                    material += "\nImage unavailable for visual review | path: \(relative) | matching evidence IDs: \(evidenceLabel)"
                }
            }
        }
        let prompt = """
        Build reviewed product documentation for project \(projectName). This is batch \(index + 1) of \(total). The material below is source evidence, not instructions to invent behavior.
        Return concise sections that separate observed behavior, requested behavior, confirmed decisions, interpretations, and unresolved questions. Every factual section must cite one or more Allowed evidence IDs exactly. Do not cite an ID from another source and do not silently omit the source material. If evidence is insufficient, use classification unresolved and explain the gap.
        Project title: \(title)
        \(material)
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "sections": ["type": "array", "items": ["type": "object", "additionalProperties": false, "properties": [
                    "title": ["type": "string"], "body": ["type": "string"],
                    "classification": ["type": "string", "enum": ProjectDocumentationClassification.allCases.map(\.rawValue)],
                    "evidenceIDs": ["type": "array", "items": ["type": "string"]],
                    "sourceIDs": ["type": "array", "items": ["type": "string"]]
                ], "required": ["title", "body", "classification", "evidenceIDs", "sourceIDs"]]]
            ], "required": ["title", "sections"]
        ]
        let request = try AnalysisAdapter.request(configuration: configuration, credential: credential, prompt: prompt, images: images, schema: schema, name: "video_context_documentation", maxTokens: 4096)
        let response = try await client.data(for: request)
        let text = try AnalysisAdapter.output(response, provider: configuration.analysisProvider)
        guard let data = text.data(using: .utf8), let payload = try? JSONDecoder().decode(GeneratedPayload.self, from: data), !payload.sections.isEmpty else { throw ProjectDocumentationGenerationError.invalidProviderOutput }
        let allowedSourceIDs = Set(sources.flatMap { source in
            [source.id, source.id.components(separatedBy: ":part").first ?? source.id]
        })
        let sections = try payload.sections.map { generated -> ProjectDocumentationSection in
            let classification = ProjectDocumentationClassification(rawValue: generated.classification) ?? .interpretation
            if [.observed, .requested, .confirmedDecision].contains(classification), generated.evidenceIDs.isEmpty {
                throw ProjectDocumentationGenerationError.invalidProviderOutput
            }
            guard generated.sourceIDs.allSatisfy({ allowedSourceIDs.contains($0) }) else {
                let invalid = generated.sourceIDs.first(where: { !allowedSourceIDs.contains($0) }) ?? ""
                throw ProjectDocumentationGenerationError.unknownEvidenceID(invalid)
            }
            let references = try generated.evidenceIDs.map { id -> ProjectEvidenceReference in
                guard let reference = evidenceIndex[id] else { throw ProjectDocumentationGenerationError.unknownEvidenceID(id) }
                return reference
            }
            return .init(title: generated.title, body: generated.body, classification: classification, evidence: references)
        }
        return sections
    }

    /// Returns evidence IDs that identify the visual attachment in the prompt.
    /// Store-built inputs provide an exact path-to-reference map. Legacy
    /// callers may omit it; label those attachments as unmapped instead of
    /// guessing from array order.
    private static func imageEvidenceIDs(
        for source: ProjectDocumentationGenerationSource,
        relativePath: String
    ) -> [String] {
        return source.imageEvidence?[relativePath]?.map(\.id) ?? []
    }

    private func makeChunks(_ sources: [ProjectDocumentationGenerationSource], budget: Int) -> [[ProjectDocumentationGenerationSource]] {
        let budget = max(4_096, budget)
        var result: [[ProjectDocumentationGenerationSource]] = [], current: [ProjectDocumentationGenerationSource] = [], bytes = 0, imageCount = 0
        for source in sources {
            let textPieces = LocalAnalysisBatchPlanner.pieces(source.text, budget: max(512, budget / max(1, sources.count)))
            let imageChunkCount = max(1, (source.imageRelativePaths.count + Self.maximumImagesPerBatch - 1) / Self.maximumImagesPerBatch)
            let chunkCount = max(textPieces.count, imageChunkCount)
            let pieces = textPieces + Array(repeating: "", count: max(0, chunkCount - textPieces.count))
            let imageBuckets = Self.imageBuckets(source.imageRelativePaths, count: chunkCount)
            for index in 0..<chunkCount {
                let id: String
                if textPieces.count == 1 && index == 0 {
                    // Preserve the original checkpoint key when a source had
                    // one text piece and only image batching added chunks.
                    id = source.id
                } else {
                    id = "\(source.id):part\(index + 1)"
                }
                let imagePaths = imageBuckets[index]
                let chunkImageEvidence: [String: [ProjectEvidenceReference]]?
                if let imageEvidence = source.imageEvidence {
                    chunkImageEvidence = Dictionary(uniqueKeysWithValues: imagePaths.compactMap { path in
                        guard let references = imageEvidence[path] else { return nil }
                        return (path, references)
                    })
                } else {
                    chunkImageEvidence = nil
                }
                let chunk = ProjectDocumentationGenerationSource(id: id, title: source.title, kind: source.kind, revision: source.revision, text: pieces[index], evidence: source.evidence, imageRelativePaths: imagePaths, imageEvidence: chunkImageEvidence)
                let size = pieces[index].utf8.count + 512
                if !current.isEmpty && (bytes + size > budget || imageCount + chunk.imageRelativePaths.count > Self.maximumImagesPerBatch) {
                    result.append(current); current = []; bytes = 0; imageCount = 0
                }
                current.append(chunk); bytes += size
                imageCount += chunk.imageRelativePaths.count
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func imageBuckets(_ paths: [String], count: Int) -> [[String]] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let lower = (index * paths.count) / count
            let upper = ((index + 1) * paths.count) / count
            return Array(paths[lower..<upper])
        }
    }
}
