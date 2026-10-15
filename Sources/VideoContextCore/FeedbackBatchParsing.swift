import Foundation

extension FeedbackBatch {
    public mutating func reparseOriginalText() {
        let previousComments = self.comments
        let previousSources = self.sources
        let (comments, sources) = FeedbackBatch.parse(self.rawText)
        let mapped: [FeedbackSource] = sources.map { candidate in
            if candidate.kind == .transcript {
                var value = previousSources.first(where: { $0.kind == .transcript }) ?? candidate
                value.ocrText = candidate.ocrText
                return value
            }
            return previousSources.first(where: { $0.url == candidate.url }) ?? candidate
        }
        let attachedSources = previousSources.filter { $0.url == nil && $0.kind != .transcript }
        let attachedIDs = Set(attachedSources.map(\.id))
        self.comments = comments.enumerated().map { index, item in
            let old = previousComments.first(where: { $0.text == item.text })
                ?? (index < previousComments.count ? previousComments[index] : nil)
            var value = old ?? item
            value.text = item.text
            value.lineNumbers = item.lineNumbers
            let linkedIDs: [String] = item.sourceIDs.compactMap { candidateID -> String? in
                guard let candidate = sources.first(where: { $0.id == candidateID }) else { return nil }
                return mapped.first(where: { $0.url == candidate.url })?.id
            }
            value.sourceIDs = Array(Set(linkedIDs + (old?.sourceIDs.filter { attachedIDs.contains($0) } ?? []))).sorted()
            return value
        }
        self.sources = mapped + attachedSources
        let assignedIDs = Set(self.comments.flatMap(\.sourceIDs))
        let allIDs = Set(self.sources.map(\.id))
        self.batchWideSourceIDs = self.batchWideSourceIDs.filter { allIDs.contains($0) }
        if !self.transcriptSources.isEmpty {
            self.batchWideSourceIDs = Array(Set(self.batchWideSourceIDs + mapped.map(\.id).filter { !assignedIDs.contains($0) })).sorted()
        }
        preparationSuggestions = []
    }
}
