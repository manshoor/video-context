import Foundation
import Observation
import VideoContextCore

enum DocumentationSelection: Hashable {
    case document(String)
    case source(String)
    case proposal(String)
    case decisions
}

@MainActor @Observable
final class DocumentationDraft {
    var document: ProjectDocumentation
    var saved: ProjectDocumentation
    var saving = false
    var error: String?
    var dirty: Bool { document.title != saved.title || document.sections != saved.sections || document.markdown != saved.markdown }
    init(_ document: ProjectDocumentation) { self.document = document; saved = document }
    func discard() { document = saved; error = nil }
}
