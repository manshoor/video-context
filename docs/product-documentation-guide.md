# Product documentation workflow

Use one project for each product. Projects keep their recordings, written requests, feedback, imported source files, documentation, decisions, and tasks together.

## Add reference material

Choose a project, then **Add Sources → Import Files…**. Select PDF, Markdown, images, or MP4 recordings. You can also drop files into the workspace. The destination is captured when the import starts.

PDF sources retain the original file, page text, page images, and OCR for scanned pages. Markdown sources retain line references and formatting. Select local images alongside a Markdown file to allow those attachments to be copied. Remote images are not downloaded automatically. Missing assets and unreadable pages remain visible in the source details.

Importing PDF, Markdown, or images does not generate documentation or tasks. Open **Documentation → Generate / Update**, select sources, and explicitly generate a proposal using the configured analysis provider. Recording processing retains its existing explicit import-and-process workflow.

## Review and maintain the reference

Generated additions and changes appear under **Proposed changes**. Compare the current and proposed text, then accept or reject the changes. Accepting creates a saved version. **Mark reviewed** approves that version after you check its requirements and evidence.

Sections distinguish observed behavior, requested behavior, confirmed decisions, AI interpretations, and unresolved questions. Citation links open the cited source location and revision. When a source changes, affected references need review. Earlier document and source versions remain readable.

Manual edits use **Save** and **Cancel**. Navigation offers Save, Discard, or Cancel when a document or task has unsaved changes. Failed saves keep the draft and its error.

Use **Decisions & questions** to record a shared answer. **Group repeated questions** proposes groups for review; it does not merge questions automatically. Confirm an answer and apply it to linked unanswered questions. Existing answers and disagreements remain intact. Changed tasks require review again.

If a decision's source evidence changes, load its current evidence, inspect the citations, and confirm the answer again. An answer backed by stale evidence cannot be applied to more tasks.

To turn a reviewed requirement into work, use **Create request from section**. This saves a request with document provenance. Generate its tasks explicitly through the existing feedback/request workflow.

## Cross-reference new work

Open **Documentation → Reference sources**. Select the main reviewed documents, original reference recordings, and imported repository Markdown/PDF files, then save the selection. Recording tasks, feedback tasks, and documentation generation share these references, confirmed decisions, and existing project tasks. The current recording or request remains the scope of the work.

**Check sources** reports changed, missing, unavailable, or unreviewed references. **Refresh file** explicitly imports a new version of a saved selected file. Earlier revisions remain available. A changed source never silently replaces the revision used by a running analysis.

In Settings, choose the **Accuracy profile** to opt into separate visual, documentation/task, and independent-review models. You can edit each stage separately and keep Terra available for comparison. Save the settings to apply them to future runs. Transcription and Apple OCR keep their existing pipelines.

Task details show revision-aware evidence, frozen documentation and decision references, review findings, and dependency IDs. OCR extraction and visual interpretation remain separate. Conflicting evidence creates a blocking question with both references. AI suggestions remain labeled; an AI review never marks a task human-approved. Resolve questions and review the task before an Implement handoff. App planning ends at requirements and task breakdowns; the coding agent inspects the repository for an implementation plan.

If the review request fails or is interrupted, generated work remains available with an incomplete review state. Run generation again to reuse completed checkpoints. When the provider outcome is uncertain, reconcile the request through **Analysis requests need reconciliation** before allowing a retry. The app does not switch providers after a failure.

Editing a task invalidates its earlier AI review. Save your changes, then choose **Review evidence again** in task details. This reviews your saved requirements and answers against the sources without regenerating the task.

## Delete a task permanently

Use **Delete Task…** in task details or the context menu. Check multiple tasks and choose **Delete selected…** for a single confirmation. Archived and reviewed tasks can also be deleted.

The confirmation lists the affected tasks. Deletion removes their content, task history, task proposals, and generation cache content from the active library. Source files, recordings, documentation, existing backups, exports, and usage accounting remain intact. **Archive** is a separate, reversible action.

Deleted tasks stay excluded from generation. Legacy recording tasks do not have stable requirement identities, so their source may require explicit reconciliation before generation can publish more work. After reviewing the source, use **Allow generation again…** in source details to clear the exclusion. Newly generated tasks receive new IDs and need review; deleted history is not restored.

## Work with an AI editor

Configure the bundled `video-context-mcp` executable in the editor. Existing configurations remain read-only. Use **Copy context for AI** for project discovery and documentation retrieval, or **Copy for AI** on selected tasks for Investigate, Plan, or Implement handoffs.

Project retrieval tools return explicit IDs, revisions, citations, freshness, and continuation cursors. Follow the cursors and retrieve exact evidence on demand. A stale or missing revision requires an updated handoff.

An editor can submit documentation proposals only when its server configuration explicitly includes `--allow-document-proposals`. Submissions enter a separate local inbox; they cannot approve documentation, delete tasks, change settings, or select arbitrary files. Open or refresh the project's Documentation workspace to review them inside Video Context.

Proposals whose sources or revisions no longer match remain under **Editor proposals needing attention**. You can inspect the submitted content, resolve the conflict and refresh, or dismiss the proposal.

**Export** creates a new folder containing Markdown, referenced material, and a revision manifest. Keep the folder together so relative links continue to work.

## Interrupted work

Completed local extraction and analysis checkpoints are reused when work resumes. An uncertain provider outcome is held for reconciliation rather than automatically submitted again. Check the provider result before using **Allow retry…** in the recording's recovery details; retrying may incur another charge.

Before the additive library upgrade, the app makes a consistent SQLite backup beside `library.sqlite`. A failed upgrade preserves the existing database and opens it for reading where possible. Check disk space and permissions before restarting.
