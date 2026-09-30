import Foundation
import GRDB

public struct ProjectDocumentationExportManifest: Codable, Equatable, Sendable {
    public enum EvidenceStatus: String, Codable, Sendable {
        case available
        case partial
        case missing
    }

    public struct DocumentEntry: Codable, Equatable, Sendable {
        public let documentID: String
        public let revision: Int
        public let markdownPath: String
        public let reviewed: Bool

        public init(documentID: String, revision: Int, markdownPath: String, reviewed: Bool) {
            self.documentID = documentID; self.revision = revision; self.markdownPath = markdownPath; self.reviewed = reviewed
        }
    }

    public struct SourceEntry: Codable, Equatable, Sendable {
        public let sourceID: String
        public let revision: Int
        public let revisionID: String
        public let name: String
        public let contentHash: String
        public let status: ProjectDocumentSourceStatus
        /// Relative path inside the export bundle. An empty value means the
        /// original was unavailable and the notice explains why.
        public let originalPath: String
        /// The path held by the library, retained for traceability only.
        public let libraryOriginalPath: String
        public let assetPaths: [String]
        public let notices: [String]

        public init(sourceID: String, revision: Int, revisionID: String? = nil, name: String, contentHash: String, status: ProjectDocumentSourceStatus, originalPath: String, libraryOriginalPath: String = "", assetPaths: [String], notices: [String] = []) {
            self.sourceID = sourceID; self.revision = revision; self.revisionID = revisionID ?? "\(sourceID):r\(revision)"; self.name = name; self.contentHash = contentHash; self.status = status
            self.originalPath = originalPath; self.libraryOriginalPath = libraryOriginalPath; self.assetPaths = assetPaths; self.notices = notices
        }

        private enum CodingKeys: String, CodingKey { case sourceID, revision, revisionID, name, contentHash, status, originalPath, libraryOriginalPath, assetPaths, notices }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceID = try container.decode(String.self, forKey: .sourceID)
            revision = try container.decode(Int.self, forKey: .revision)
            revisionID = try container.decodeIfPresent(String.self, forKey: .revisionID) ?? "\(sourceID):r\(revision)"
            name = try container.decode(String.self, forKey: .name)
            contentHash = try container.decode(String.self, forKey: .contentHash)
            status = try container.decode(ProjectDocumentSourceStatus.self, forKey: .status)
            originalPath = try container.decode(String.self, forKey: .originalPath)
            libraryOriginalPath = try container.decodeIfPresent(String.self, forKey: .libraryOriginalPath) ?? ""
            assetPaths = try container.decode([String].self, forKey: .assetPaths)
            notices = try container.decodeIfPresent([String].self, forKey: .notices) ?? []
        }
    }

    public struct EvidenceEntry: Codable, Equatable, Sendable {
        public let referenceID: String
        public let sourceID: String
        public let sourceRevision: String
        public let relativePaths: [String]
        public let status: EvidenceStatus
        public let notices: [String]

        public init(referenceID: String, sourceID: String, sourceRevision: String, relativePaths: [String] = [], status: EvidenceStatus, notices: [String] = []) {
            self.referenceID = referenceID; self.sourceID = sourceID; self.sourceRevision = sourceRevision; self.relativePaths = relativePaths; self.status = status; self.notices = notices
        }
    }

    public let projectID: String
    public let exportedAt: Date
    public let documents: [DocumentEntry]
    public let sources: [SourceEntry]
    public let evidence: [EvidenceEntry]

    public init(projectID: String, exportedAt: Date = .now, documents: [DocumentEntry], sources: [SourceEntry], evidence: [EvidenceEntry] = []) {
        self.projectID = projectID; self.exportedAt = exportedAt; self.documents = documents; self.sources = sources; self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey { case projectID, exportedAt, documents, sources, evidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        documents = try container.decode([DocumentEntry].self, forKey: .documents)
        sources = try container.decode([SourceEntry].self, forKey: .sources)
        evidence = try container.decodeIfPresent([EvidenceEntry].self, forKey: .evidence) ?? []
    }
}

public struct ProjectDocumentationExportResult: Codable, Equatable, Sendable {
    public let destination: URL
    public let manifestURL: URL
    public let documentationURLs: [URL]
    public let copiedAssetURLs: [URL]
    public let notices: [String]

    public init(destination: URL, manifestURL: URL, documentationURLs: [URL], copiedAssetURLs: [URL], notices: [String] = []) {
        self.destination = destination; self.manifestURL = manifestURL; self.documentationURLs = documentationURLs; self.copiedAssetURLs = copiedAssetURLs; self.notices = notices
    }
}

public extension VideoContextStore {
    /// Writes a portable Markdown bundle without changing the library. All links are relative to the export directory.
    func exportProjectDocumentation(projectID: String, destination: URL, paths: LibraryPaths) throws -> ProjectDocumentationExportResult {
        let (snapshot, plan) = try pool.read { database -> (ProjectDocumentationReadSnapshot, DocumentationExportPlan) in
            let snapshot = try Self.projectDocumentationSnapshot(projectID: projectID, db: database)
            let plan = try DocumentationExportSupport.makePlan(projectID: projectID, snapshot: snapshot, database: database, paths: paths)
            return (snapshot, plan)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProjectDocumentationStoreError.invalidInput("Choose a directory for the documentation export.")
            }
            guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw ProjectDocumentationStoreError.invalidInput("Choose a new or empty directory for the documentation export.")
            }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let docsDirectory = destination.appending(path: "documentation", directoryHint: .isDirectory)
        let assetsDirectory = destination.appending(path: "assets", directoryHint: .isDirectory)
        let sourceDirectory = destination.appending(path: "sources", directoryHint: .isDirectory)
        let evidenceDirectory = destination.appending(path: "evidence", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        var documentationURLs: [URL] = []
        var copiedAssetURLs: [URL] = []
        var documentEntries: [ProjectDocumentationExportManifest.DocumentEntry] = []
        var sourceEntries: [ProjectDocumentationExportManifest.SourceEntry] = []
        var evidenceEntries: [ProjectDocumentationExportManifest.EvidenceEntry] = []
        var referenceLinks: [String: [String]] = [:]
        var referenceNotices: [String: [String]] = [:]
        var notices: [String] = []
        var usedDocumentNames = Set<String>()
        var usedDestinationPaths = Set<String>()
        var copiedByCandidate = [String: String]()

        func copy(_ candidate: DocumentationExportCandidate) -> String? {
            let key = candidate.libraryPath + "\u{1f}" + candidate.destinationRelativePath
            if let existing = copiedByCandidate[key] { return existing }
            let sourceURL = DocumentationExportSupport.libraryURL(candidate.libraryPath, paths: paths)
            guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
                notices.append("\(candidate.label): source file is unavailable (\(candidate.libraryPath)).")
                return nil
            }
            var relative = candidate.destinationRelativePath
            let baseExtension = URL(fileURLWithPath: relative).pathExtension
            let stem = URL(fileURLWithPath: relative).deletingPathExtension().path
            var index = 2
            while usedDestinationPaths.contains(relative) || FileManager.default.fileExists(atPath: destination.appending(path: relative).path) {
                let suffix = "-\(index)"
                relative = baseExtension.isEmpty ? stem + suffix : stem + suffix + "." + baseExtension
                index += 1
            }
            let target = destination.appending(path: relative)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: target)
                usedDestinationPaths.insert(relative)
                copiedByCandidate[key] = relative
                copiedAssetURLs.append(target)
                return relative
            } catch {
                notices.append("\(candidate.label): could not copy the source file (\(error.localizedDescription)).")
                return nil
            }
        }

        for document in snapshot.documentation {
            let base = Self.safePathComponent(document.slug.isEmpty ? document.id : document.slug)
            var filename = "\(base).md"
            var suffix = 2
            while usedDocumentNames.contains(filename) { filename = "\(base)-\(suffix).md"; suffix += 1 }
            usedDocumentNames.insert(filename)
            let url = docsDirectory.appending(path: filename)
            let refs = document.sections.flatMap(\.evidence)
            let links = refs.reduce(into: [String: [String]]()) { result, reference in
                result[reference.id] = referenceLinks[reference.id] ?? []
            }
            let noticesByReference = refs.reduce(into: [String: [String]]()) { result, reference in
                result[reference.id] = referenceNotices[reference.id] ?? []
            }
            try Self.render(document: document, links: links, notices: noticesByReference).write(to: url, atomically: true, encoding: .utf8)
            documentationURLs.append(url)
            documentEntries.append(.init(documentID: document.id, revision: document.currentRevision, markdownPath: "documentation/\(filename)", reviewed: document.isReviewed))
        }

        // Copy every current project source and every historical document revision
        // cited by the exported documentation. The latter is required for a
        // citation to remain exact after a source is edited in the library.
        for sourcePlan in plan.sources {
            var assetPaths: [String] = []
            var sourceNotices = sourcePlan.notices
            let originalPath = sourcePlan.original.flatMap(copy)
            if sourcePlan.original != nil && originalPath == nil {
                sourceNotices.append("The original source file was not included in the export.")
            }
            for asset in sourcePlan.assets {
                if let relative = copy(asset.candidate) {
                    assetPaths.append(relative)
                } else {
                    sourceNotices.append(asset.notice)
                }
            }
            sourceEntries.append(.init(sourceID: sourcePlan.source.id, revision: sourcePlan.revision.revision,
                revisionID: sourcePlan.revision.id, name: sourcePlan.source.name, contentHash: sourcePlan.revision.contentHash,
                status: sourcePlan.revision.status, originalPath: originalPath ?? "", libraryOriginalPath: sourcePlan.revision.originalRelativePath,
                assetPaths: assetPaths, notices: sourceNotices))
        }

        for evidence in plan.evidence {
            var pathsForEvidence: [String] = []
            var evidenceNotices = evidence.notices
            if let generated = evidence.generated {
                let target = destination.appending(path: generated.destinationRelativePath)
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try generated.text.write(to: target, atomically: true, encoding: .utf8)
                    pathsForEvidence.append(generated.destinationRelativePath)
                    copiedAssetURLs.append(target)
                } catch {
                    evidenceNotices.append("\(generated.label) could not be written (\(error.localizedDescription)).")
                }
            }
            for candidate in evidence.candidates {
                if let relative = copy(candidate) {
                    pathsForEvidence.append(relative)
                } else {
                    evidenceNotices.append("\(candidate.label) was not included in the export.")
                }
            }
            var uniquePaths: [String] = []
            for path in pathsForEvidence where !uniquePaths.contains(path) { uniquePaths.append(path) }
            referenceLinks[evidence.reference.id] = uniquePaths
            referenceNotices[evidence.reference.id] = evidenceNotices
            let status: ProjectDocumentationExportManifest.EvidenceStatus
            if uniquePaths.isEmpty { status = .missing }
            else if evidenceNotices.isEmpty { status = .available }
            else { status = .partial }
            evidenceEntries.append(.init(referenceID: evidence.reference.id, sourceID: evidence.reference.sourceID,
                sourceRevision: evidence.sourceRevision, relativePaths: uniquePaths, status: status, notices: evidenceNotices))
            notices.append(contentsOf: evidenceNotices)
        }

        // The documents are written before evidence is copied so they can be
        // produced even when a source disappeared. Rewrite them once the link
        // map is complete; this keeps missing evidence visible in Markdown.
        for (index, document) in snapshot.documentation.enumerated() {
            let filename = URL(fileURLWithPath: documentEntries[index].markdownPath).lastPathComponent
            let refs = document.sections.flatMap(\.evidence)
            let links = refs.reduce(into: [String: [String]]()) { result, reference in result[reference.id] = referenceLinks[reference.id] ?? [] }
            let noticesByReference = refs.reduce(into: [String: [String]]()) { result, reference in result[reference.id] = referenceNotices[reference.id] ?? [] }
            try Self.render(document: document, links: links, notices: noticesByReference).write(to: docsDirectory.appending(path: filename), atomically: true, encoding: .utf8)
        }

        let manifest = ProjectDocumentationExportManifest(projectID: projectID, documents: documentEntries, sources: sourceEntries, evidence: evidenceEntries)
        let manifestURL = destination.appending(path: "manifest.json")
        let data = try JSONEncoder.prettySorted.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        return .init(destination: destination, manifestURL: manifestURL, documentationURLs: documentationURLs, copiedAssetURLs: copiedAssetURLs, notices: Array(Set(notices)).sorted())
    }

    static func render(document: ProjectDocumentation) -> String {
        if !document.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return document.markdown + "\n" }
        var output = "# \(document.title)\n\n"
        for section in document.sections.sorted(by: { $0.order < $1.order }) {
            output += "## \(section.title)\n\n"
            output += "<!-- classification: \(section.classification.rawValue) -->\n\n"
            output += section.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            if !section.evidence.isEmpty {
                output += "Evidence:\n\n"
                output += section.evidence.map { "- `\($0.id)`" }.joined(separator: "\n") + "\n\n"
            }
        }
        return output
    }

    private static func render(document: ProjectDocumentation, links: [String: [String]], notices: [String: [String]]) -> String {
        var output: String
        if document.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = "# \(document.title)\n\n"
            for section in document.sections.sorted(by: { $0.order < $1.order }) {
                output += "## \(section.title)\n\n"
                output += "<!-- classification: \(section.classification.rawValue) -->\n\n"
                output += section.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            }
        } else {
            output = document.markdown.hasSuffix("\n") ? document.markdown : document.markdown + "\n"
        }

        var references: [ProjectEvidenceReference] = []
        var seen = Set<String>()
        for reference in document.sections.flatMap(\.evidence) where seen.insert(reference.id).inserted {
            references.append(reference)
        }
        guard !references.isEmpty else { return output }
        output += "\n## Evidence\n\n"
        for reference in references {
            let relativeLinks = links[reference.id, default: []].map { path in
                let relative = "../" + path
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "webp", "heic", "gif", "tif", "tiff"].contains(ext) {
                    return "![Evidence \(reference.id)](\(relative))"
                }
                return "[Open evidence](\(relative))"
            }
            let detail = relativeLinks.isEmpty ? "unavailable" : relativeLinks.joined(separator: " ")
            output += "- `\(reference.id)` — \(detail)\n"
            for notice in notices[reference.id, default: []] {
                output += "  - Notice: \(notice)\n"
            }
        }
        return output + "\n"
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private struct DocumentationExportCandidate: Sendable {
    let libraryPath: String
    let destinationRelativePath: String
    let label: String
}

private struct DocumentationExportAssetPlan: Sendable {
    let asset: ProjectDocumentAsset
    let candidate: DocumentationExportCandidate
    let notice: String
}

private struct DocumentationExportSourcePlan: Sendable {
    let source: ProjectDocumentSource
    let revision: ProjectDocumentSourceRevision
    let original: DocumentationExportCandidate?
    let assets: [DocumentationExportAssetPlan]
    let notices: [String]
}

private struct DocumentationExportEvidencePlan: Sendable {
    let reference: ProjectEvidenceReference
    let sourceRevision: String
    let candidates: [DocumentationExportCandidate]
    let notices: [String]
    let generated: DocumentationExportGeneratedArtifact?

    init(reference: ProjectEvidenceReference, sourceRevision: String, candidates: [DocumentationExportCandidate], notices: [String], generated: DocumentationExportGeneratedArtifact? = nil) {
        self.reference = reference; self.sourceRevision = sourceRevision; self.candidates = candidates
        self.notices = notices; self.generated = generated
    }
}

private struct DocumentationExportGeneratedArtifact: Sendable {
    let destinationRelativePath: String
    let text: String
    let label: String
}

private struct DocumentationExportPlan: Sendable {
    let sources: [DocumentationExportSourcePlan]
    let evidence: [DocumentationExportEvidencePlan]
}

/// Builds an export plan from one database read. File copying happens after the
/// read, so a slow or missing source file cannot hold the library transaction.
private enum DocumentationExportSupport {
    static func makePlan(projectID: String, snapshot: ProjectDocumentationReadSnapshot, database: Database, paths: LibraryPaths) throws -> DocumentationExportPlan {
        let references = snapshot.documentation.flatMap { $0.sections.flatMap(\.evidence) }
        let documentReferences = references.compactMap { reference -> (String, Int)? in
            guard case .document(let sourceID, let revision, _) = reference else { return nil }
            return (sourceID, revision)
        }

        var sourcePlans: [DocumentationExportSourcePlan] = []
        var sourcePlanKeys = Set<String>()
        func appendSource(_ source: ProjectDocumentSource, revision: ProjectDocumentSourceRevision) {
            let key = "\(source.id):\(revision.revision)"
            guard sourcePlanKeys.insert(key).inserted else { return }
            var notices = revision.errors.map(\.message)
            let original: DocumentationExportCandidate?
            if revision.originalRelativePath.isEmpty {
                original = nil
                notices.append("The source revision has no stored original file path.")
            } else {
                original = DocumentationExportCandidate(
                    libraryPath: revision.originalRelativePath,
                    destinationRelativePath: "sources/\(safeComponent(source.id))/r\(revision.revision)/original-\(safeFilename(revision.originalRelativePath, fallback: source.name))",
                    label: "Document source \(source.name) revision \(revision.revision)"
                )
            }
            let assets = revision.assets.map { asset -> DocumentationExportAssetPlan in
                guard let relativePath = asset.relativePath, !relativePath.isEmpty else {
                    return .init(asset: asset, candidate: .init(libraryPath: "", destinationRelativePath: "", label: "Document asset \(asset.id)"), notice: "Document asset \(asset.id) has no stored local path.")
                }
                let filename = safeFilename(relativePath, fallback: asset.id)
                let candidate = DocumentationExportCandidate(
                    libraryPath: relativePath,
                    // Keep Markdown attachment names beside the copied
                    // original. Relative image links inside that original
                    // therefore remain usable from the portable bundle.
                    destinationRelativePath: "sources/\(safeComponent(source.id))/r\(revision.revision)/\(safeRelativePath(asset.sourcePath, fallback: filename))",
                    label: "Document asset \(asset.id) from \(source.name) revision \(revision.revision)"
                )
                return .init(asset: asset, candidate: candidate, notice: "Document asset \(asset.id) was unavailable.")
            }
            sourcePlans.append(.init(source: source, revision: revision, original: original, assets: assets, notices: notices))
        }

        // Include current source revisions so the exported bundle can be used
        // as a product reference even when a document section cites a video or
        // feedback item only. Then add every historical revision cited by docs.
        for source in snapshot.sources {
            if let revision = snapshot.sourceRevisions.first(where: { $0.sourceID == source.id && $0.revision == source.currentRevision }) {
                appendSource(source, revision: revision)
            }
        }
        for (sourceID, revisionNumber) in documentReferences {
            guard let source = snapshot.sources.first(where: { $0.id == sourceID }),
                  let revision = snapshot.sourceRevisions.first(where: { $0.sourceID == sourceID && $0.revision == revisionNumber }) else { continue }
            appendSource(source, revision: revision)
        }

        var sourcePlanByKey = [String: DocumentationExportSourcePlan]()
        for plan in sourcePlans { sourcePlanByKey["\(plan.source.id):\(plan.revision.revision)"] = plan }

        var evidencePlans: [DocumentationExportEvidencePlan] = []
        var evidenceIDs = Set<String>()
        for reference in references where evidenceIDs.insert(reference.id).inserted {
            switch reference {
            case .document(let sourceID, let revisionNumber, let locator):
                let key = "\(sourceID):\(revisionNumber)"
                guard let sourcePlan = sourcePlanByKey[key] else {
                    evidencePlans.append(.init(reference: reference, sourceRevision: "source:\(revisionNumber)", candidates: [], notices: ["Document source \(sourceID) revision \(revisionNumber) is unavailable."]))
                    continue
                }
                var candidates: [DocumentationExportCandidate] = []
                if let original = sourcePlan.original { candidates.append(original) }
                let selectedAssets: [DocumentationExportAssetPlan]
                switch locator.kind {
                case .asset:
                    selectedAssets = sourcePlan.assets.filter { asset in
                        asset.asset.id == locator.value || asset.asset.sourcePath == locator.value || asset.asset.relativePath == locator.value
                    }
                case .pdfPage:
                    selectedAssets = sourcePlan.assets.filter { asset in
                        let value = (asset.asset.sourcePath + " " + (asset.asset.relativePath ?? "")).lowercased()
                        return value.contains("page-\(locator.page ?? 0)") || value.contains("page_\(locator.page ?? 0)")
                    }
                default:
                    selectedAssets = sourcePlan.assets
                }
                candidates.append(contentsOf: selectedAssets.compactMap { $0.candidate.libraryPath.isEmpty ? nil : $0.candidate })
                var notices = sourcePlan.notices
                if locator.kind == .asset && selectedAssets.isEmpty { notices.append("The cited document asset \(locator.displayValue) was not found in the source revision.") }
                evidencePlans.append(.init(reference: reference, sourceRevision: "source:\(revisionNumber)", candidates: candidates, notices: notices))

            case .reviewedDocumentation(let documentID, let revisionNumber, let sectionID):
                guard let revision = try VideoContextStore.documentationRevision(documentID: documentID, revision: revisionNumber, projectID: projectID, database: database) else {
                    evidencePlans.append(.init(reference: reference, sourceRevision: "documentation:\(revisionNumber)", candidates: [], notices: ["Project documentation \(documentID) revision \(revisionNumber) is unavailable."]))
                    continue
                }
                let text: String
                let suffix: String
                if let sectionID {
                    guard let section = revision.sections.first(where: { $0.id == sectionID }) else {
                        evidencePlans.append(.init(reference: reference, sourceRevision: "documentation:\(revisionNumber)", candidates: [], notices: ["Project documentation section \(sectionID) is unavailable at revision \(revisionNumber)."] ))
                        continue
                    }
                    text = "# \(revision.title)\n\n## \(section.title)\n\n\(section.body)\n"
                    suffix = "section-\(safeComponent(sectionID))"
                } else {
                    text = revision.markdown.isEmpty
                        ? "# \(revision.title)\n\n" + revision.sections.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }).map { "## \($0.title)\n\n\($0.body)" }.joined(separator: "\n\n") + "\n"
                        : revision.markdown + (revision.markdown.hasSuffix("\n") ? "" : "\n")
                    suffix = "complete"
                }
                let generated = DocumentationExportGeneratedArtifact(
                    destinationRelativePath: "evidence/documentation/\(safeComponent(documentID))/r\(revisionNumber)-\(suffix).md",
                    text: text,
                    label: "Project documentation \(documentID) revision \(revisionNumber)"
                )
                evidencePlans.append(.init(reference: reference, sourceRevision: "documentation:\(revisionNumber)", candidates: [], notices: [], generated: generated))

            case .recording(let videoID, let sourceRevision, let timestamp, let evidenceID):
                var candidates: [DocumentationExportCandidate] = []
                var notices: [String] = []
                guard let video = try VideoContextStore.fetchVideo(id: videoID, from: database) else {
                    evidencePlans.append(.init(reference: reference, sourceRevision: recordingRevision(sourceRevision), candidates: [], notices: ["Recording \(videoID) no longer exists."]))
                    continue
                }
                guard video.projectID == projectID else {
                    evidencePlans.append(.init(reference: reference, sourceRevision: recordingRevision(sourceRevision), candidates: [], notices: ["Recording \(videoID) is outside project \(projectID)."]))
                    continue
                }
                if !video.mediaRelativePath.isEmpty {
                    candidates.append(.init(libraryPath: video.mediaRelativePath,
                        destinationRelativePath: "evidence/recordings/\(safeComponent(videoID))/media-\(safeFilename(video.mediaRelativePath, fallback: "recording.mp4"))",
                        label: "Recording \(videoID)"))
                } else {
                    notices.append("Recording \(videoID) has no stored media path.")
                }
                let evidence = try recordingEvidenceItems(video: video, revision: sourceRevision, evidenceID: evidenceID, timestamp: timestamp, database: database)
                let transcriptAvailable = try recordingTranscriptExists(video: video, revision: sourceRevision, evidenceID: evidenceID, timestamp: timestamp, database: database)
                if evidence.items.isEmpty && !transcriptAvailable {
                    let requested = evidenceID.map { "evidence \($0)" } ?? "a screenshot at \(timestamp)s"
                    notices.append("The cited \(requested) is unavailable for recording revision \(recordingRevision(sourceRevision)).")
                } else {
                    for item in evidence.items {
                        guard !item.imageRelativePath.isEmpty else { continue }
                        candidates.append(.init(libraryPath: item.imageRelativePath,
                            destinationRelativePath: "evidence/recordings/\(safeComponent(videoID))/r\(sourceRevision.evidence)/\(safeComponent(item.id))-\(safeFilename(item.imageRelativePath, fallback: "frame.png"))",
                            label: "Recording screenshot \(item.id)"))
                    }
                }
                evidencePlans.append(.init(reference: reference, sourceRevision: recordingRevision(sourceRevision), candidates: candidates, notices: notices))

            case .feedback(let batchID, let sourceRevision, let commentID, let sourceID):
                var candidates: [DocumentationExportCandidate] = []
                var notices: [String] = []
                guard let batch = try feedbackRevision(batchID: batchID, revision: sourceRevision, database: database) else {
                    evidencePlans.append(.init(reference: reference, sourceRevision: "batch:\(sourceRevision)", candidates: [], notices: ["Feedback batch \(batchID) revision \(sourceRevision) is unavailable."]))
                    continue
                }
                guard batch.projectID == projectID else {
                    evidencePlans.append(.init(reference: reference, sourceRevision: "batch:\(sourceRevision)", candidates: [], notices: ["Feedback batch \(batchID) is outside project \(projectID)."]))
                    continue
                }
                var sourceIDs: [String] = []
                if let sourceID {
                    sourceIDs = [sourceID]
                } else if let commentID, let comment = batch.comments.first(where: { $0.id == commentID }) {
                    sourceIDs = comment.sourceIDs
                } else if commentID != nil {
                    notices.append("Feedback comment \(commentID ?? "") is unavailable in batch \(batchID) revision \(sourceRevision).")
                }
                for sourceID in sourceIDs {
                    guard let source = batch.sources.first(where: { $0.id == sourceID }) else {
                        notices.append("Feedback source \(sourceID) is unavailable in batch \(batchID) revision \(sourceRevision).")
                        continue
                    }
                    if let localPath = source.localPath, !localPath.isEmpty {
                        candidates.append(.init(libraryPath: localPath,
                            destinationRelativePath: "evidence/feedback/\(safeComponent(batchID))/r\(sourceRevision)/\(safeComponent(sourceID))-\(safeFilename(localPath, fallback: "attachment"))",
                            label: "Feedback source \(sourceID)"))
                    }
                    if let jam = source.jam {
                        for item in jam.items {
                            guard let localPath = item.localPath, !localPath.isEmpty else { continue }
                            candidates.append(.init(libraryPath: localPath,
                                destinationRelativePath: "evidence/feedback/\(safeComponent(batchID))/r\(sourceRevision)/\(safeComponent(sourceID))-jam-\(safeComponent(item.id))-\(safeFilename(localPath, fallback: "evidence"))",
                                label: "Feedback source \(sourceID) Jam evidence \(item.id)"))
                        }
                    }
                    if source.localPath == nil && (source.jam?.items.allSatisfy { $0.localPath == nil } ?? true) {
                        notices.append("Feedback source \(sourceID) has no local attachment in batch \(batchID) revision \(sourceRevision).")
                    }
                }
                evidencePlans.append(.init(reference: reference, sourceRevision: "batch:\(sourceRevision)", candidates: candidates, notices: notices))
            }
        }
        return .init(sources: sourcePlans, evidence: evidencePlans)
    }

    static func libraryURL(_ path: String, paths: LibraryPaths) -> URL {
        guard path.hasPrefix("/") else { return paths.absoluteURL(relativePath: path).standardizedFileURL }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func safeComponent(_ value: String) -> String {
        let replaced = value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return replaced.isEmpty ? "item" : String(replaced.prefix(100))
    }

    private static func safeFilename(_ path: String, fallback: String) -> String {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return safeFilenameComponent(filename.isEmpty ? fallback : filename, fallback: fallback)
    }

    private static func safeRelativePath(_ path: String, fallback: String) -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("\\") else { return safeFilename(path, fallback: fallback) }
        let decoded = path.removingPercentEncoding ?? path
        var components: [String] = []
        for part in decoded.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() } else { return safeFilename(path, fallback: fallback) }
                continue
            }
            let safe = safeFilenameComponent(String(part), fallback: "item")
            if !safe.isEmpty { components.append(safe) }
        }
        return components.isEmpty ? safeFilename(path, fallback: fallback) : components.joined(separator: "/")
    }

    private static func safeFilenameComponent(_ value: String, fallback: String) -> String {
        let filtered = String(value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "/" && scalar != "\\"
        })
        guard !filtered.isEmpty, filtered != ".", filtered != ".." else { return fallback }
        return String(filtered.prefix(255))
    }

    private static func recordingRevision(_ revision: ArtifactRevision) -> String {
        "transcript:\(revision.transcript),evidence:\(revision.evidence),brief:\(revision.brief)"
    }

    private static func recordingEvidenceItems(video: VideoRecord, revision: ArtifactRevision, evidenceID: String?, timestamp: TimeInterval, database: Database) throws -> (items: [EvidenceItem], exact: Bool) {
        let values: [EvidenceItem]
        var exact = true
        if video.revisions.evidence == revision.evidence {
            values = try Row.fetchAll(database, sql: "SELECT * FROM evidence_items WHERE video_id=? ORDER BY timestamp,id", arguments: [video.id]).map(VideoContextStore.evidence(from:))
        } else if try database.tableExists("source_artifact_history"),
                  let data = try Data.fetchOne(database, sql: "SELECT artifact_data FROM source_artifact_history WHERE video_id=? AND stage=? AND revision=?", arguments: [video.id, SourceArtifactHistoryStage.evidence.rawValue, revision.evidence]),
                  let historical = try? JSONDecoder().decode([EvidenceItem].self, from: data) {
            values = historical
        } else {
            values = []
            exact = false
        }
        if let evidenceID {
            return (values.filter { $0.id == evidenceID }, exact)
        }
        let closest = values.min { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }
        return (closest.map { [$0] } ?? [], exact)
    }

    private static func recordingTranscriptExists(video: VideoRecord, revision: ArtifactRevision, evidenceID: String?, timestamp: TimeInterval, database: Database) throws -> Bool {
        guard let evidenceID else { return false }
        let values: [TranscriptSegment]
        if video.revisions.transcript == revision.transcript {
            values = try Row.fetchAll(database, sql: "SELECT * FROM transcript_segments WHERE video_id=? ORDER BY start_time,id", arguments: [video.id]).map(VideoContextStore.transcript(from:))
        } else if try database.tableExists("source_artifact_history"),
                  let data = try Data.fetchOne(database, sql: "SELECT artifact_data FROM source_artifact_history WHERE video_id=? AND stage=? AND revision=?", arguments: [video.id, SourceArtifactHistoryStage.transcript.rawValue, revision.transcript]),
                  let historical = try? JSONDecoder().decode([TranscriptSegment].self, from: data) {
            values = historical
        } else {
            return false
        }
        return values.contains { $0.id == evidenceID && timestamp >= $0.start - 0.01 && timestamp <= $0.end + 0.01 }
    }

    private static func feedbackRevision(batchID: String, revision: Int, database: Database) throws -> FeedbackBatch? {
        guard let current = try? VideoContextStore.feedbackBatch(batchID, in: database) else { return nil }
        if current.revision == revision { return current }
        guard try database.tableExists("feedback_source_history"),
              let data = try Data.fetchOne(database, sql: "SELECT document FROM feedback_source_history WHERE batch_id=? AND revision=?", arguments: [batchID, revision]) else { return nil }
        return try? JSONDecoder().decode(FeedbackBatch.self, from: data)
    }
}
