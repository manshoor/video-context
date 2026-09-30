# Product documentation and task deletion acceptance

Date: 2026-09-28

## Delivered behavior

- Projects accept PDF, Markdown, images, and recordings. Document imports retain original files, versioned text, page or line locations, selected local attachments, and explicit missing-asset or extraction errors.
- The Documentation workspace supports explicit generation, proposed differences, manual drafts, review, history, exact evidence navigation, shared decisions, and requests created from reviewed requirements.
- Permanent task deletion has one preview and confirmation for individual or selected recording, feedback, and request tasks. Deletion removes active task content and history, retains source material, blocks late writes, and excludes deleted work from generation until explicitly reset.
- Completed extraction and provider stages have durable checkpoints. Uncertain provider outcomes require reconciliation. Silent recordings retain visual analysis and explicit audio coverage.
- Project MCP discovery, context, search, document retrieval, and evidence retrieval retain revisions and project scope. Existing tool contracts remain available. Documentation proposals require explicit server opt-in and local review.
- Portable exports contain Markdown, referenced material, and a revision manifest with relative links.

## Verification

`./scripts/test.sh` passed: 256 core tests in 43 suites and 74 app tests in 18 suites. Three opt-in media/model tests remain skipped: `approvedRecordingInSeparateLibrary`, `imageAndTaskUsageInDisposableLibrary`, and `realSpeechUsesCachedModelsAndRestoresRecordingOffsets`. The existing OAuth callback test used its local loopback listener.

| Check | Result |
| --- | --- |
| `./scripts/build-app.sh` | Passed; rebuilt the app and bundled MCP executable |
| `./scripts/check-app.sh` | Passed; signature, resources, executable format, and framework check |
| `python3 scripts/smoke-mcp.py` | Passed; project discovery, exact evidence, existing task tools, opt-in proposals, and clean disconnect |
| `python3 scripts/smoke-diagnostics.py` | Passed; two stdio processes, 76 events, dynamic enable/stop/expiry, privacy, and unchanged canonical database |
| `git diff --check` | Passed |

The build used its existing packaged icon after `iconutil` rejected the regenerated iconset on this Mac. The final bundle passed its icon and signing checks. The local output is `dist/Video Context.app`.

Acceptance uses temporary libraries, controlled failures, and mocked providers. It does not migrate or delete data in the user's active library and does not call live analysis providers.

The automated scenarios cover migration backups and rollback; repeated startup; all task kinds and active, reviewed, and archived states; deletion cancellation and failure; stale saves and generation results; scanned and text PDFs; Markdown attachments and revisions; processing restart; documentation drafts, decisions, and review gates; ownership moves; exact historical evidence; MCP pagination and proposal idempotency; and portable links.

Two deletion regressions first reproduced removal of unrelated proposals from sources with ambiguous task identities. After the fix, task-specific proposals are removed while unrelated proposals remain visible as outdated and cannot be applied. Both regressions pass in the complete suite.

## Native UI and client limits

The isolated UI fixture includes two projects, three recordings including Inbox content, feedback and request tasks, PDF and Markdown sources, documentation, a proposal, and a shared decision. The fixture app launched and its seeded records were verified in its temporary library.

Native UI access became available during final verification. The packaged fixture was inspected in light and dark appearance at the 1080 × 720 content minimum. Checks exercised PDF citations and the return path, document draft protection, Tab navigation, Escape cancellation, bulk task deletion confirmation, mixed-source handoff review gates, the usage view, and settings without saving configuration changes. No active-library content was used.

Accessibility labels were inspected through the native accessibility tree for task selection, controls, evidence links, editors, and dialogs. A spoken VoiceOver session was not run. The fixture supports `--ui-fixture --ui-minimum --ui-light` and `--ui-fixture --ui-minimum --ui-dark` for repeatable checks.

The visual check identified raw citation IDs crowding the proposal comparison and a demo proposal without a real content change. The comparison now shows readable sections, change labels, and clickable evidence; technical IDs are expandable. The fixture contains a real proposed addition. Accepting a proposal opens its saved document while respecting changes to the current workspace route.

The rebuilt comparison was inspected in both appearances. Its new citation opened the exact Markdown table line, the return action restored the proposal, and accepting the fixture proposal opened the saved document with its added section. The new-request composer showed the current project and cancelled without creating work. Disposable fixture processes were stopped after verification.

MCP smoke tests exercise the bundled server through actual stdio processes. They are separate from testing inside Claude, Codex, or Cursor; those client integrations and live-provider output quality have not been tested in this acceptance run.

## Preservation and delivery

Existing uncommitted work remains in place. No commit, push, publication, provider call, or active-library migration was performed. The app creates a consistent SQLite backup before its additive documentation upgrade when the user next opens an existing library.

See [the workflow guide](product-documentation-guide.md) for daily use, deletion exclusions, editor proposals, and interrupted-work recovery.
