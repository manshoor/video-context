import Foundation
import VideoContextCore

struct FixtureJamConnection: JamConnectionControlling {
    func connect(interactive: Bool) async throws -> Set<String> { throw JamConnectionError.authorizationRequired }
    func disconnect() async throws { }
    func hasStoredCredentials() async -> Bool { false }
}

extension AppModel {
    func installProjectWorkspaceFixture(videoID: String, projectID: String) async throws {
        guard let store, let paths else { return }
        let source = try await store.taskSnapshot(videoID: videoID)
        if source.tasks.isEmpty && source.proposals.isEmpty {
            var question = TaskQuestion(question: "How many retries should be allowed?")
            question.isBlocking = true
            let content = TaskContent(title: "Explain payment errors", behavior: "Show a useful error and let the customer try again.", requirements: [.init(text: "Keep the order summary visible", origin: .recording, sourceIDs: [source.transcript[2].id])], checks: [.init(text: "A failed payment shows a retry action", origin: .interpretation, sourceIDs: [source.transcript[1].id])], questions: [question], sourceIDs: source.evidence.map(\.id))
            _ = try await store.saveTask(.init(videoID: videoID, sourceRevision: source.video.revisions, content: content, provenance: .init(provider: .lmStudio, model: "fixture")), expectedRevision: nil, expectedSource: source.video.revisions)
        }
        let request = try await store.createProjectRequest(projectID: projectID, title: "Receipt improvements", text: "Make the receipt download easier to find")
        let requestTask = FeedbackTask(batchID: request.id, issueID: request.comments[0].id, sourceRevision: request.revision,
            content: .init(title: "Add a receipt download action", behavior: "Show a clear download action after payment.", requirements: [.init(text: "Make receipt download easy to find", origin: .request, sourceIDs: [request.comments[0].id])], checks: [.init(text: "The confirmation screen provides a receipt download")], sourceIDs: [request.comments[0].id]))
        _ = try await store.saveFeedbackTask(requestTask, expectedRevision: nil, expectedBatchRevision: request.revision)
        try await store.approveFeedbackTasks(batchID: request.id, expectedBatchRevision: request.revision, expectedTaskRevisions: [requestTask.id: 1])
        let project = try await store.listFeedbackProjects().first { $0.id == projectID }
        let batch = FeedbackBatch(videoID: videoID, projectID: projectID, title: "QA review", project: project?.name ?? "", rawText: "The payment button wraps on narrow windows")
        try await store.createFeedback(batch)
        _ = try await store.saveFeedbackTask(.init(batchID: batch.id, issueID: batch.comments[0].id, sourceRevision: batch.revision,
            content: .init(title: "Keep the payment action readable", behavior: "Keep the payment action visible at narrow widths.", checks: [.init(text: "Payment action fits at the supported minimum width")], sourceIDs: [batch.comments[0].id])), expectedRevision: nil, expectedBatchRevision: batch.revision)
        let inbox = VideoRecord(id: "vid_ui_inbox", title: "Older unassigned walkthrough", source: .localFile, sourceValue: "fixture", mediaRelativePath: "fixture.mp4", duration: 125, status: .ready)
        try await store.createVideo(inbox)
        _ = try await store.saveTask(.init(videoID: inbox.id, sourceRevision: inbox.revisions, content: .init(title: "Review the older navigation request", behavior: "Review the older request", checks: [.init(text: "Request reviewed")])), expectedRevision: nil, expectedSource: inbox.revisions)
        let workspace = try await store.projectWorkspace(projectID: projectID)
        workspaceLocation.task = workspace.tasks.first?.reference

        // Keep the fixture useful for validating the product-reference
        // workspace as well as the task workspace. The imports are
        // deterministic and idempotent, so a fixture reload reuses the same
        // source revisions instead of adding duplicate documents.
        let markdownURL = paths.root.appending(path: "fixture-product-requirements.md")
        let markdown = """
        # Checkout Requirements

        The checkout must keep the order summary visible while payment is processing.

        ## Requested behaviour

        - Explain payment failures in plain language.
        - Let the customer retry once without losing the order details.

        | State | Required reference |
        | --- | --- |
        | Payment failed | Retry action and support guidance |

        ```swift
        let retryLimit = 1
        ```

        ![Missing screenshot](missing-checkout.png)
        ![Remote reference](https://example.com/checkout.png)
        """
        try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
        let markdownImport = try await store.importDocumentSourceAsync(projectID: projectID, sourceURL: markdownURL, paths: paths)

        let pdfURL = paths.root.appending(path: "fixture-product-requirements.pdf")
        try fixtureRequirementsPDF().write(to: pdfURL, options: .atomic)
        let pdfImport = try await store.importDocumentSourceAsync(projectID: projectID, sourceURL: pdfURL, paths: paths)
        let markdownEvidence = ProjectEvidenceReference.document(
            sourceID: markdownImport.source.id,
            revision: markdownImport.revision.revision,
            locator: .init(heading: "Checkout Requirements")
        )
        let pdfEvidence = ProjectEvidenceReference.document(
            sourceID: pdfImport.source.id,
            revision: pdfImport.revision.revision,
            locator: .init(pdfPage: 1)
        )
        let decision = try await store.saveProjectDecision(.init(
            id: "fixture-checkout-retry-limit",
            projectID: projectID,
            key: "checkout-retry-limit",
            question: "How many retries should checkout allow?",
            answer: "Allow one retry without losing the order details.",
            aliases: ["retry limit", "payment retry"],
            evidence: [markdownEvidence, pdfEvidence],
            state: .confirmed
        ))
        let section = ProjectDocumentationSection(
            order: 0,
            title: "Checkout requirements",
            body: "Keep the order summary visible while payment is processing. Explain failures and allow one retry.",
            classification: .requested,
            evidence: [markdownEvidence, pdfEvidence],
            decisionIDs: [decision.id]
        )
        let markdownDocument = ProjectDocumentationFormatting.markdown(title: "Checkout product reference", sections: [section])
        let currentDocumentation = try await store.projectDocumentation(projectID: projectID).documentation.first
        let document: ProjectDocumentation
        if let currentDocumentation {
            document = currentDocumentation
        } else {
            document = try await store.createDocumentationDraft(
                projectID: projectID,
                title: "Checkout product reference",
                slug: "checkout-product-reference",
                markdown: markdownDocument,
                sections: [section],
                sourceSignature: "\(markdownImport.revision.contentHash):\(pdfImport.revision.contentHash)"
            )
        }
        let guidanceLocator = markdownImport.revision.units.first { $0.text.contains("Retry action and support guidance") }?.locator ?? markdownImport.revision.units[0].locator
        let guidanceEvidence = ProjectEvidenceReference.document(sourceID: markdownImport.source.id,
            revision: markdownImport.revision.revision, locator: guidanceLocator)
        let proposedSections = document.sections + [ProjectDocumentationSection(id: "fixture-support-guidance",
            order: document.sections.count, title: "Payment failure guidance",
            body: "Show a retry action and support guidance when a payment fails.", classification: .requested, evidence: [guidanceEvidence])]
        let proposal = ProjectDocumentationProposal(
            projectID: projectID,
            documentID: document.id,
            expectedDocumentRevision: document.currentRevision,
            title: document.title,
            slug: document.slug,
            markdown: ProjectDocumentationFormatting.markdown(title: document.title, sections: proposedSections),
            sections: proposedSections,
            diff: ProjectDocumentationFormatting.diff(before: document.sections, after: proposedSections),
            sourceSignature: "fixture-documentation-proposal",
            evidence: proposedSections.flatMap(\.evidence)
        )
        _ = try await store.proposeDocumentation(proposal, requestID: "fixture-checkout-documentation")
    }
}

/// Produces a small selectable-text PDF without depending on a writable app
/// bundle or an external fixture file. The object offsets are calculated so
/// PDFKit can parse the generated data on every machine.
private func fixtureRequirementsPDF() -> Data {
    let content = "BT\n/F1 20 Tf\n72 700 Td\n(Checkout requirements) Tj\n0 -36 Td\n(Keep the order summary visible.) Tj\n0 -36 Td\n(Allow one retry after payment failure.) Tj\nET\n"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    var data = Data("%PDF-1.4\n".utf8)
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(data.count)
        data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
    }
    let xrefOffset = data.count
    data.append(contentsOf: "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
    for offset in offsets.dropFirst() {
        data.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
    }
    data.append(contentsOf: "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
    return data
}
