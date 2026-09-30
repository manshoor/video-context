import Foundation
import CryptoKit

public enum ProjectDocumentationFormatting {
    public static func markdown(title: String, sections: [ProjectDocumentationSection]) -> String {
        (["# \(title)"] + sections.sorted { $0.order < $1.order }.map { section in
            let citations = section.evidence.map { "- Evidence: `\(citationID($0))`" }.joined(separator: "\n")
            return "## \(section.title)\n\n\(section.classification.rawValue)\n\n\(section.body)" + (citations.isEmpty ? "" : "\n\n\(citations)")
        }).joined(separator: "\n\n")
    }

    public static func citationID(_ reference: ProjectEvidenceReference) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(reference)) ?? Data(reference.id.utf8)
        return "cite_" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func diff(before: [ProjectDocumentationSection], after: [ProjectDocumentationSection]) -> ProjectDocumentationDiff {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return .init(addedSectionIDs: after.filter { old[$0.id] == nil }.map(\.id),
            changedSectionIDs: after.filter { old[$0.id] != nil && old[$0.id] != $0 }.map(\.id),
            removedSectionIDs: before.filter { new[$0.id] == nil }.map(\.id))
    }
}

public struct DocumentEditorProposalPayload: Codable, Equatable, Sendable {
    public let title: String
    public let sections: [ProjectDocumentationSection]
    public let evidence: [ProjectEvidenceReference]?
    public init(title: String, sections: [ProjectDocumentationSection], evidence: [ProjectEvidenceReference]? = nil) {
        self.title = title; self.sections = sections; self.evidence = evidence
    }
    public var sectionsIncludingSupportingEvidence: [ProjectDocumentationSection] {
        let attached = Set(sections.flatMap(\.evidence))
        var seen = Set<ProjectEvidenceReference>()
        let unattached = (evidence ?? []).filter { !attached.contains($0) && seen.insert($0).inserted }
        guard !unattached.isEmpty else { return sections }
        let key = unattached.map(ProjectDocumentationFormatting.citationID).sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return sections + [.init(id: "supporting_\(digest)", order: (sections.map(\.order).max() ?? -1) + 1,
            title: "Supporting evidence", body: "Additional source references submitted by the editor.", classification: .interpretation, evidence: unattached)]
    }
}
