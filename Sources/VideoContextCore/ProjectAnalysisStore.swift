import Foundation
import GRDB

public enum ProjectAnalysisStoreError: Error, LocalizedError, Equatable, Sendable {
    case schemaUnavailable
    case projectNotFound(String)
    case invalidSelection(String)
    case sourceNotSelected(String)
    case sourceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .schemaUnavailable:
            "Project analysis selections are unavailable in this library. Open it once in the current app to apply the additive migration."
        case .projectNotFound(let id):
            "Project not found: \(id)."
        case .invalidSelection(let message):
            message
        case .sourceNotSelected(let id):
            "The document source is not selected for project analysis: \(id)."
        case .sourceUnavailable(let message):
            message
        }
    }
}

extension VideoContextStore {
    static func createProjectAnalysisSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS project_analysis_selections (
                project_id TEXT PRIMARY KEY REFERENCES feedback_projects(id) ON DELETE CASCADE,
                selection BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
    }

    public func projectAnalysisSelection(projectID: String) throws -> ProjectAnalysisSelection? {
        try pool.read { database in
            guard try database.tableExists("project_analysis_selections"),
                  let data = try Data.fetchOne(database, sql: "SELECT selection FROM project_analysis_selections WHERE project_id=?", arguments: [projectID]) else {
                return nil
            }
            return try JSONDecoder().decode(ProjectAnalysisSelection.self, from: data)
        }
    }

    public func saveProjectAnalysisSelection(projectID: String, selection: ProjectAnalysisSelection) throws {
        let normalized = ProjectAnalysisSelection(
            documentIDs: selection.documentIDs,
            recordingIDs: selection.recordingIDs,
            documentSourceIDs: selection.documentSourceIDs
        )
        try pool.write { database in
            guard try database.tableExists("project_analysis_selections") else { throw ProjectAnalysisStoreError.schemaUnavailable }
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM feedback_projects WHERE id=?)", arguments: [projectID]) == true else {
                throw ProjectAnalysisStoreError.projectNotFound(projectID)
            }
            try Self.validateAnalysisSelection(normalized, projectID: projectID, database: database)
            if normalized.isEmpty {
                try database.execute(sql: "DELETE FROM project_analysis_selections WHERE project_id=?", arguments: [projectID])
            } else {
                try database.execute(
                    sql: "INSERT INTO project_analysis_selections(project_id,selection,updated_at) VALUES(?,?,?) ON CONFLICT(project_id) DO UPDATE SET selection=excluded.selection,updated_at=excluded.updated_at",
                    arguments: [projectID, try JSONEncoder().encode(normalized), Date.now.timeIntervalSince1970]
                )
            }
        }
    }

    public func projectAnalysisSourceStatuses(projectID: String, paths: LibraryPaths) throws -> [ProjectAnalysisSourceStatus] {
        let stored: (ProjectAnalysisSelection?, [ProjectDocumentation], [ProjectDocumentationRevision], [VideoRecord], [ProjectDocumentSource], [ProjectDocumentSourceRevision], Set<String>) = try pool.read { database in
            guard try database.tableExists("project_analysis_selections"),
                  let selectionData = try Data.fetchOne(database, sql: "SELECT selection FROM project_analysis_selections WHERE project_id=?", arguments: [projectID]) else {
                return (nil, [], [], [], [], [], [])
            }
            let selection = try JSONDecoder().decode(ProjectAnalysisSelection.self, from: selectionData)
            let documentation = try Self.projectDocumentationSnapshot(projectID: projectID, db: database)
            let videos = try Self.allProjectVideos(database).filter { $0.projectID == projectID }
            let transcriptVideoIDs = Set(try String.fetchAll(database, sql: "SELECT DISTINCT video_id FROM transcript_segments"))
            return (selection, documentation.documentation, documentation.revisions, videos, documentation.sources, documentation.sourceRevisions, transcriptVideoIDs)
        }
        guard let selection = stored.0 else { return [] }
        let documents = Dictionary(uniqueKeysWithValues: stored.1.map { ($0.id, $0) })
        let documentRevisions = Dictionary(grouping: stored.2, by: \.documentID)
        let recordings = Dictionary(uniqueKeysWithValues: stored.3.map { ($0.id, $0) })
        let sources = Dictionary(uniqueKeysWithValues: stored.4.map { ($0.id, $0) })
        let sourceRevisions = Dictionary(grouping: stored.5, by: \.sourceID)
        var statuses: [ProjectAnalysisSourceStatus] = []

        for id in selection.documentIDs {
            guard let document = documents[id] else {
                statuses.append(.init(sourceID: id, title: id, kind: .documentation, status: .missing, message: "The selected project document no longer exists."))
                continue
            }
            guard let reviewedRevision = document.reviewedRevision,
                  documentRevisions[id]?.contains(where: { $0.revision == reviewedRevision }) == true else {
                statuses.append(.init(sourceID: id, title: document.title, kind: .documentation, status: .needsReview, message: "Review this document before using it for analysis."))
                continue
            }
            guard document.currentRevision == reviewedRevision else {
                statuses.append(.init(sourceID: id, title: document.title, kind: .documentation, status: .needsReview,
                                      message: "The selected document changed after its reviewed revision. Analysis will keep the reviewed revision as a pinned baseline."))
                continue
            }
            statuses.append(.init(sourceID: id, title: document.title, kind: .documentation, status: .current))
        }

        for id in selection.recordingIDs {
            guard let recording = recordings[id] else {
                statuses.append(.init(sourceID: id, title: id, kind: .recording, status: .missing, message: "The selected recording is not available in this project."))
                continue
            }
            let mediaURL = paths.absoluteURL(relativePath: recording.mediaRelativePath)
            guard FileManager.default.isReadableFile(atPath: mediaURL.path) else {
                statuses.append(.init(sourceID: id, title: recording.title, kind: .recording, status: .unavailable,
                                      message: "The selected recording's original media file is unavailable."))
                continue
            }
            guard stored.6.contains(id) else {
                statuses.append(.init(sourceID: id, title: recording.title, kind: .recording, status: .unavailable,
                                      message: "The selected recording has no transcript to analyze."))
                continue
            }
            statuses.append(.init(sourceID: id, title: recording.title, kind: .recording, status: .current))
        }

        for id in selection.documentSourceIDs {
            guard let source = sources[id],
                  let revision = sourceRevisions[id]?.first(where: { $0.revision == source.currentRevision }) else {
                statuses.append(.init(sourceID: id, title: sources[id]?.name ?? id, kind: .importedDocument, status: .missing, message: "The selected imported document no longer exists."))
                continue
            }
            guard revision.isUsable else {
                statuses.append(.init(sourceID: id, title: source.name, kind: .importedDocument, status: .unavailable, message: "The current imported revision is not usable."))
                continue
            }
            let sourceURL = URL(fileURLWithPath: source.sourceKey)
            guard FileManager.default.isReadableFile(atPath: sourceURL.path),
                  let sourceData = try? Data(contentsOf: sourceURL) else {
                statuses.append(.init(sourceID: id, title: source.name, kind: .importedDocument, status: .unavailable, message: "The original file is unavailable. The last imported revision remains preserved."))
                continue
            }
            let preservedURL = paths.absoluteURL(relativePath: revision.originalRelativePath)
            guard let preservedData = try? Data(contentsOf: preservedURL) else {
                statuses.append(.init(sourceID: id, title: source.name, kind: .importedDocument, status: .unavailable, message: "The preserved imported file is unavailable."))
                continue
            }
            let changed = DocumentSourceImporter.sha256(sourceData) != DocumentSourceImporter.sha256(preservedData)
            statuses.append(.init(sourceID: id, title: source.name, kind: .importedDocument, status: changed ? .changed : .current,
                                  message: changed ? "The original file changed. Refresh it explicitly to create a new revision." : nil))
        }
        return statuses
    }

    public func refreshProjectAnalysisSource(projectID: String, sourceID: String, paths: LibraryPaths) async throws -> ProjectDocumentImportResult {
        guard let selection = try projectAnalysisSelection(projectID: projectID), selection.documentSourceIDs.contains(sourceID) else {
            throw ProjectAnalysisStoreError.sourceNotSelected(sourceID)
        }
        guard let (source, revision) = try projectDocumentSource(projectID: projectID, sourceID: sourceID) else {
            throw ProjectAnalysisStoreError.sourceUnavailable("The selected imported document no longer exists: \(sourceID).")
        }
        let sourceURL = URL(fileURLWithPath: source.sourceKey)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ProjectAnalysisStoreError.sourceUnavailable("The original file is unavailable: \(source.name).")
        }
        let baseURL = sourceURL.deletingLastPathComponent()
        let attachments = revision.assets.compactMap { asset -> URL? in
            guard asset.status == .copied else { return nil }
            let url = baseURL.appending(path: asset.sourcePath).standardizedFileURL
            return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
        }
        return try await importDocumentSourceAsync(projectID: projectID, sourceURL: sourceURL, paths: paths, selectedAttachments: attachments)
    }

    public func validateProjectAnalysisEvidence(
        _ references: [ProjectEvidenceReference],
        projectID: String
    ) throws -> [ProjectEvidenceValidation] {
        try pool.read { database in
            try references.map { try Self.analysisEvidenceValidation($0, projectID: projectID, database: database) }
        }
    }

    public func projectAnalysisContext(projectID: String, paths: LibraryPaths) async throws -> ProjectAnalysisContext? {
        guard let selection = try projectAnalysisSelection(projectID: projectID), !selection.isEmpty else { return nil }
        let statuses = try projectAnalysisSourceStatuses(projectID: projectID, paths: paths)
        var warnings = statuses.compactMap(Self.warning(for:))
        var missing = statuses.filter { $0.status == .missing || $0.status == .unavailable }.map(\.sourceID)
        var stale = statuses.filter { $0.status == .changed || $0.status == .needsReview }.map(\.sourceID)

        let assembled: ([ProjectAnalysisPassage], [ProjectAnalysisFrameDescriptor], [ProjectDecision], [ProjectAnalysisTaskContext], [ProjectAnalysisSourceRevision], [ProjectAnalysisWarning]) = try await pool.read { database in
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM feedback_projects WHERE id=?)", arguments: [projectID]) == true else {
                throw ProjectAnalysisStoreError.projectNotFound(projectID)
            }
            let documentation = try Self.projectDocumentationSnapshot(projectID: projectID, db: database)
            let documents = Dictionary(uniqueKeysWithValues: documentation.documentation.map { ($0.id, $0) })
            let revisions = Dictionary(grouping: documentation.revisions, by: \.documentID)
            let sources = Dictionary(uniqueKeysWithValues: documentation.sources.map { ($0.id, $0) })
            let sourceRevisions = Dictionary(grouping: documentation.sourceRevisions, by: \.sourceID)
            var passages: [ProjectAnalysisPassage] = []
            var frames: [ProjectAnalysisFrameDescriptor] = []
            var sourceManifest: [ProjectAnalysisSourceRevision] = []
            var assemblyWarnings: [ProjectAnalysisWarning] = []

            for id in selection.documentIDs {
                guard let document = documents[id], let reviewed = document.reviewedRevision,
                      let revision = revisions[id]?.first(where: { $0.revision == reviewed }) else { continue }
                sourceManifest.append(.init(sourceID: "documentation:\(id)", kind: .reviewedDocumentation, revision: "r\(reviewed)"))
                for section in revision.sections.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }) {
                    let directReference = ProjectEvidenceReference.reviewedDocumentation(
                        documentID: id,
                        revision: reviewed,
                        sectionID: section.id
                    )
                    passages.append(.init(id: "documentation:\(id):r\(reviewed):\(section.id)", sourceID: "documentation:\(id)",
                                          title: "\(revision.title) — \(section.title)", kind: .reviewedDocumentation, revision: "r\(reviewed)",
                                          text: section.body, classification: section.classification,
                                          evidence: ProjectAnalysisContext.uniqueEvidence([directReference] + section.evidence)))
                }
                if revision.sections.isEmpty && !revision.markdown.isEmpty {
                    let directReference = ProjectEvidenceReference.reviewedDocumentation(documentID: id, revision: reviewed, sectionID: nil)
                    passages.append(.init(id: "documentation:\(id):r\(reviewed)", sourceID: "documentation:\(id)", title: revision.title,
                                          kind: .reviewedDocumentation, revision: "r\(reviewed)", text: revision.markdown,
                                          evidence: [directReference]))
                }
            }

            for id in selection.documentSourceIDs {
                guard let source = sources[id], let revision = sourceRevisions[id]?.first(where: { $0.revision == source.currentRevision }), revision.isUsable else { continue }
                let revisionValue = "r\(revision.revision):\(revision.contentHash)"
                sourceManifest.append(.init(sourceID: "document:\(id)", kind: .importedDocument, revision: revisionValue))
                for unit in revision.units.sorted(by: { $0.ordinal < $1.ordinal }) {
                    let reference = ProjectEvidenceReference.document(sourceID: id, revision: revision.revision, locator: unit.locator)
                    passages.append(.init(id: "document:\(id):r\(revision.revision):\(unit.id)", sourceID: "document:\(id)",
                                          title: unit.title ?? source.name, kind: .importedDocument, revision: "r\(revision.revision):\(revision.contentHash)",
                                          text: unit.text, evidence: [reference]))
                }
                for asset in revision.assets where asset.status == .copied {
                    guard let relativePath = asset.relativePath else { continue }
                    let imageURL = paths.absoluteURL(relativePath: relativePath)
                    guard FileManager.default.isReadableFile(atPath: imageURL.path) else {
                        assemblyWarnings.append(.init(sourceID: "document:\(id):asset:\(asset.id)", kind: .unavailable,
                                                      message: "An imported document image is unavailable."))
                        continue
                    }
                    let reference = ProjectEvidenceReference.document(sourceID: id, revision: revision.revision, locator: .init(asset: asset.sourcePath))
                    let pageText = revision.units.filter { unit in
                        guard let page = unit.locator.page else { return source.kind == .image }
                        return asset.sourcePath.contains("page-\(page).")
                    }.map(\.text).joined(separator: "\n")
                    frames.append(.init(id: asset.id, documentSourceID: id, title: source.name,
                                        documentRevision: revision.revision, contentHash: revision.contentHash,
                                        imageURL: imageURL, ocrText: pageText, evidence: reference))
                    if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        passages.append(.init(id: "document:\(id):asset:\(asset.id):ocr", sourceID: "document:\(id)",
                                              title: "Extracted OCR — \(asset.sourcePath)", kind: .ocrExtraction,
                                              revision: revisionValue, text: pageText, evidence: [reference]))
                    }
                }
            }

            for id in selection.recordingIDs {
                guard let video = try Self.fetchVideo(id: id, from: database), video.projectID == projectID else { continue }
                sourceManifest.append(.init(sourceID: "recording:\(id)", kind: .transcript, revision: Self.revisionString(video.revisions)))
                let transcript = try Row.fetchAll(database, sql: "SELECT * FROM transcript_segments WHERE video_id=? ORDER BY start_time,id", arguments: [id]).map(Self.transcript(from:))
                let evidenceItems = try Row.fetchAll(database, sql: "SELECT * FROM evidence_items WHERE video_id=? ORDER BY timestamp,id", arguments: [id]).map(Self.evidence(from:))
                for segment in transcript {
                    let reference = ProjectEvidenceReference.recording(videoID: id, sourceRevision: video.revisions, timestamp: segment.start, evidenceID: segment.id)
                    passages.append(.init(id: "recording:\(id):transcript:\(segment.id)", sourceID: "recording:\(id)", title: "\(video.title) transcript at \(Self.analysisTime(segment.start))",
                                          kind: .transcript, revision: Self.revisionString(video.revisions), text: segment.text, evidence: [reference]))
                }
                for item in evidenceItems {
                    let imageURL = paths.absoluteURL(relativePath: item.imageRelativePath)
                    guard FileManager.default.isReadableFile(atPath: imageURL.path) else {
                        assemblyWarnings.append(.init(sourceID: "recording:\(id):frame:\(item.id)", kind: .unavailable,
                                                      message: "An original recording frame is unavailable."))
                        continue
                    }
                    let reference = ProjectEvidenceReference.recording(videoID: id, sourceRevision: video.revisions, timestamp: item.timestamp, evidenceID: item.id)
                    frames.append(.init(id: item.id, videoID: id, title: video.title, sourceRevision: video.revisions,
                                        timestamp: item.timestamp, imageURL: imageURL, ocrText: item.ocrText, evidence: reference))
                    if !item.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        passages.append(.init(id: "recording:\(id):frame:\(item.id):ocr", sourceID: "recording:\(id)",
                                              title: "Extracted OCR at \(Self.analysisTime(item.timestamp))", kind: .ocrExtraction,
                                              revision: Self.revisionString(video.revisions), text: item.ocrText, evidence: [reference]))
                    }
                }
            }

            let decisions = documentation.decisions.filter { $0.state == .confirmed }.sorted { $0.id < $1.id }
            for decision in decisions {
                sourceManifest.append(.init(sourceID: "decision:\(decision.id)", kind: .confirmedDecision, revision: "r\(decision.revision)"))
                passages.append(.init(id: "decision:\(decision.id):r\(decision.revision)", sourceID: "decision:\(decision.id)", title: decision.question,
                                      kind: .confirmedDecision, revision: "r\(decision.revision)", text: decision.answer,
                                      classification: .confirmedDecision, evidence: decision.evidence))
            }

            let workspace = try Self.projectWorkspace(projectID: projectID, db: database)
            let taskContexts = workspace.tasks.filter { !$0.archived }.sorted { $0.reference.id < $1.reference.id }.map { task in
                ProjectAnalysisTaskContext(id: task.taskID, sourceID: task.reference.source.id, title: task.content.title,
                                           behavior: task.content.behavior, requirements: task.content.requirements, checks: task.content.checks,
                                           questions: task.content.questions, revision: task.revision, sourceRevision: task.sourceRevision,
                                           reviewed: task.reviewed, isStale: task.isStale)
            }
            for task in taskContexts {
                var lines = [task.behavior]
                lines += task.requirements.map { "Requirement [\($0.origin.rawValue)]: \($0.text)" }
                lines += task.checks.map { "Acceptance check [\($0.origin.rawValue)]: \($0.text)" }
                lines += task.questions.map { "Question: \($0.question)\($0.answer.isEmpty ? "" : " Answer: \($0.answer)")" }
                passages.append(.init(id: "task:\(task.id):r\(task.revision)", sourceID: task.sourceID, title: task.title,
                                      kind: .existingTask, revision: "r\(task.revision)", text: lines.filter { !$0.isEmpty }.joined(separator: "\n")))
            }
            sourceManifest = Array(Set(sourceManifest)).sorted { $0.id < $1.id }
            return (passages, frames, decisions, taskContexts, sourceManifest, assemblyWarnings)
        }

        guard try projectAnalysisSelection(projectID: projectID) == selection else { throw TaskContextError.conflict }
        warnings.append(contentsOf: assembled.5)

        let allEvidence = ProjectAnalysisContext.uniqueEvidence(assembled.0.flatMap(\.evidence) + assembled.1.map(\.evidence))
        let validations = try validateProjectAnalysisEvidence(allEvidence, projectID: projectID)
        for validation in validations where validation.status != .valid {
            let kind: ProjectAnalysisWarningKind = validation.status == .missing ? .missing : .stale
            warnings.append(.init(sourceID: validation.reference.sourceID, kind: kind, message: validation.message ?? "Selected evidence is not current."))
            if validation.status == .missing { missing.append(validation.reference.sourceID) }
            else { stale.append(validation.reference.sourceID) }
        }
        warnings = Array(Dictionary(grouping: warnings, by: \.id).values.compactMap(\.first)).sorted { $0.id < $1.id }
        missing = Array(Set(missing)).sorted()
        stale = Array(Set(stale)).sorted()
        let passages = assembled.0.sorted { $0.id < $1.id }
        let frames = assembled.1.sorted { ($0.sourceID, $0.timestamp, $0.id) < ($1.sourceID, $1.timestamp, $1.id) }
        let fingerprint = try ProjectAnalysisContext.makeFingerprint(projectID: projectID, selection: selection, passages: passages, frames: frames,
                                                                    warnings: warnings, confirmedDecisions: assembled.2, existingTasks: assembled.3)
        let sourceFingerprint = try ProjectAnalysisContext.makeSourceFingerprint(projectID: projectID, selection: selection, sourceManifest: assembled.4,
                                                                                 passages: passages, frames: frames, warnings: warnings,
                                                                                 confirmedDecisions: assembled.2)
        return .init(projectID: projectID, selection: selection, fingerprint: fingerprint, sourceFingerprint: sourceFingerprint,
                     sourceManifest: assembled.4, evidence: allEvidence,
                     passages: passages, frames: frames, warnings: warnings, missingSourceIDs: missing, staleSourceIDs: stale,
                     confirmedDecisions: assembled.2, existingTasks: assembled.3)
    }

    /// Rebuilds the selected evidence snapshot and returns the fingerprint used
    /// for task freshness. Existing task edits are intentionally excluded.
    public func projectAnalysisSourceFingerprint(projectID: String, paths: LibraryPaths) async throws -> String? {
        try await projectAnalysisContext(projectID: projectID, paths: paths)?.sourceFingerprint
    }

    private static func validateAnalysisSelection(_ selection: ProjectAnalysisSelection, projectID: String, database: Database) throws {
        for id in selection.documentIDs {
            guard try String.fetchOne(database, sql: "SELECT project_id FROM project_documentation WHERE id=?", arguments: [id]) == projectID else {
                throw ProjectAnalysisStoreError.invalidSelection("The selected project document is missing or belongs to another project: \(id).")
            }
        }
        for id in selection.recordingIDs {
            guard try fetchVideo(id: id, from: database)?.projectID == projectID else {
                throw ProjectAnalysisStoreError.invalidSelection("The selected recording is missing or belongs to another project: \(id).")
            }
        }
        for id in selection.documentSourceIDs {
            guard try String.fetchOne(database, sql: "SELECT project_id FROM project_document_sources WHERE id=?", arguments: [id]) == projectID else {
                throw ProjectAnalysisStoreError.invalidSelection("The selected imported document is missing or belongs to another project: \(id).")
            }
        }
    }

    private static func analysisEvidenceValidation(
        _ reference: ProjectEvidenceReference,
        projectID: String,
        database: Database
    ) throws -> ProjectEvidenceValidation {
        switch reference {
        case .recording(let videoID, let revision, _, let evidenceID):
            guard let video = try fetchVideo(id: videoID, from: database), video.projectID == projectID else {
                return .init(reference: reference, status: .missing, message: "The cited recording is missing or belongs to another project.")
            }
            guard video.revisions == revision else {
                return .init(reference: reference, status: .stale, message: "The cited recording has newer transcript or frame revisions.")
            }
            if let evidenceID,
               try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM evidence_items WHERE id=? AND video_id=? UNION SELECT 1 FROM transcript_segments WHERE id=? AND video_id=?)",
                                 arguments: [evidenceID, videoID, evidenceID, videoID]) != true {
                return .init(reference: reference, status: .missing, message: "The cited transcript segment or original frame is unavailable.")
            }
            return .init(reference: reference, status: .valid)
        case .feedback(let batchID, let revision, let commentID, _):
            guard let data = try Data.fetchOne(database, sql: "SELECT document FROM feedback_batches WHERE id=?", arguments: [batchID]),
                  let batch = try? JSONDecoder().decode(FeedbackBatch.self, from: data), batch.projectID == projectID else {
                return .init(reference: reference, status: .missing, message: "The cited feedback is missing or belongs to another project.")
            }
            guard batch.revision == revision else {
                return .init(reference: reference, status: .stale, message: "The cited feedback has a newer revision.")
            }
            if let commentID, !batch.comments.contains(where: { $0.id == commentID }) {
                return .init(reference: reference, status: .missing, message: "The cited feedback comment is unavailable.")
            }
            return .init(reference: reference, status: .valid)
        case .document(let sourceID, let revision, let locator):
            guard let source = try Row.fetchOne(database, sql: "SELECT project_id,current_revision FROM project_document_sources WHERE id=?", arguments: [sourceID]),
                  source["project_id"] as String == projectID,
                  let value = try documentSourceRevision(sourceID: sourceID, revision: revision, db: database) else {
                return .init(reference: reference, status: .missing, message: "The cited imported document revision is missing or belongs to another project.")
            }
            guard value.isUsable, locatorExists(locator, in: value) else {
                return .init(reference: reference, status: .missing, message: "The cited imported document location is unavailable.")
            }
            let currentRevision: Int = source["current_revision"]
            return .init(reference: reference, status: currentRevision == revision ? .valid : .stale,
                         message: currentRevision == revision ? nil : "The cited imported document has a newer revision.")
        case .reviewedDocumentation(let documentID, let revision, let sectionID):
            guard let row = try Row.fetchOne(database, sql: "SELECT project_id,current_revision,reviewed_revision FROM project_documentation WHERE id=?", arguments: [documentID]),
                  row["project_id"] as String == projectID,
                  let data = try Data.fetchOne(database, sql: "SELECT document FROM project_documentation_revisions WHERE document_id=? AND project_id=? AND revision=?", arguments: [documentID, projectID, revision]),
                  let frozen = try? JSONDecoder().decode(ProjectDocumentationRevision.self, from: data) else {
                return .init(reference: reference, status: .missing, message: "The cited reviewed documentation revision is missing or belongs to another project.")
            }
            if let sectionID, !frozen.sections.contains(where: { $0.id == sectionID }) {
                return .init(reference: reference, status: .missing, message: "The cited reviewed documentation section is unavailable.")
            }
            let currentRevision: Int = row["current_revision"]
            let reviewedRevision: Int? = row["reviewed_revision"]
            let isCurrent = currentRevision == revision && reviewedRevision == revision
            return .init(reference: reference, status: isCurrent ? .valid : .stale,
                         message: isCurrent ? nil : "The cited project documentation is no longer the current reviewed revision.")
        }
    }

    private static func warning(for status: ProjectAnalysisSourceStatus) -> ProjectAnalysisWarning? {
        let kind: ProjectAnalysisWarningKind
        switch status.status {
        case .current: return nil
        case .changed: kind = .stale
        case .unavailable: kind = .unavailable
        case .missing: kind = .missing
        case .needsReview: kind = .needsReview
        }
        return .init(sourceID: status.sourceID, kind: kind, message: status.message ?? "The selected source is not current.")
    }

    private static func revisionString(_ revision: ArtifactRevision) -> String {
        "transcript:\(revision.transcript):evidence:\(revision.evidence):brief:\(revision.brief)"
    }

    private static func analysisTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
