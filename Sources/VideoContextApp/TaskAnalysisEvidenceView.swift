import SwiftUI
import VideoContextCore

struct TaskAnalysisEvidenceView: View {
    let content: TaskContent
    var openEvidence: ((ProjectEvidenceReference) -> Void)?
    var openSource: ((TaskAnalysisSourceManifestEntry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let review = content.evidenceReview {
                Label(reviewLabel(review.status), systemImage: review.status == .passed ? "checkmark.shield" : "doc.text.magnifyingglass")
                    .font(.headline)
                if let reviewer = review.reviewer {
                    Text("\(reviewer.provider.displayName) · \(reviewer.model)").font(.caption).foregroundStyle(.secondary)
                }
                Text("AI review checks evidence. You still approve the requirements.").font(.caption).foregroundStyle(.secondary)
                if let error = review.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(review.findings) { finding in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(finding.message).textSelection(.enabled)
                        if finding.blocking { Label("Needs a decision", systemImage: "questionmark.bubble").font(.caption) }
                        citations(finding.evidence)
                        if !finding.conflictingEvidence.isEmpty {
                            Text("Conflicting evidence").font(.caption.bold())
                            citations(finding.conflictingEvidence)
                        }
                    }.padding(10).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                }
            }
            if !content.evidenceReferences.isEmpty {
                Text("Project evidence").font(.headline)
                citations(content.evidenceReferences)
            }
            if !content.analysisSourceManifest.isEmpty {
                DisclosureGroup("Reference source revisions") {
                    ForEach(content.analysisSourceManifest) { entry in
                        if let openSource {
                            Button("\(entry.sourceID) · \(entry.revision)", systemImage: "doc.text") { openSource(entry) }
                                .font(.caption)
                        } else {
                            Text("\(entry.sourceID) · \(entry.revision)").font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            if !content.visualEvidenceObservations.isEmpty {
                DisclosureGroup("OCR and visual verification") {
                    ForEach(content.visualEvidenceObservations) { observation in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(observation.assessment.rawValue.capitalized).font(.caption.bold())
                            Text("Extracted OCR: \(observation.extractedOCR)").textSelection(.enabled)
                            Text("Visual interpretation: \(observation.visualInterpretation)").textSelection(.enabled)
                            citations([observation.evidence])
                        }.padding(.vertical, 6)
                    }
                }
            }
            if !content.dependencyTaskIDs.isEmpty {
                Text("Dependencies").font(.headline)
                ForEach(content.dependencyTaskIDs, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }

    private func citations(_ references: [ProjectEvidenceReference]) -> some View {
        ForEach(Array(Set(references)).sorted { $0.id < $1.id }) { reference in
            if let openEvidence {
                Button(reference.displayName, systemImage: "link") { openEvidence(reference) }.font(.callout)
            } else {
                Text(reference.displayName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func reviewLabel(_ status: TaskEvidenceReviewStatus) -> String {
        switch status {
        case .awaitingReview: "Awaiting AI evidence review"
        case .passed: "AI evidence review complete"
        case .findings: "AI review found issues"
        case .failed: "AI evidence review incomplete"
        }
    }
}
