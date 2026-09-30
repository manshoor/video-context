# Project workspace acceptance — 2026-09-28

The application now opens projects into a shared task workspace. Recording tasks and feedback/request tasks retain their existing stores, IDs, evidence, and revision history. New tasks start as written requests. Generation remains explicit.

## Data and compatibility

- Recordings have nullable, indexed project ownership. Existing unassigned content is visible in Inbox.
- A SQLite backup includes committed WAL data before the transactional, one-time `projectWorkspaceOwnership` migration. Unambiguous legacy ownership preserves approvals; conflicting groups remain readable for resolution.
- Source-group moves traverse linked local recordings and feedback recursively. Preview and commit compare a fresh group snapshot. Moves invalidate reviews and old handoffs while preserving history and marking pending proposals outdated.
- Project reads use one database snapshot. Detailed evidence loads on selection. Route tokens reject obsolete results; drafts survive background updates and failed saves.
- Cursor handoffs can combine both task types within one project. Copy revalidates membership, task/source revisions, and review eligibility. Existing MCP names and parameters are unchanged, including retrieval before project migration.

## Automated verification

- `./scripts/test.sh`: 200 core tests and 65 app tests passed after the ownership, archive, fixture, and source-navigation changes.
- The final `ProjectNavigationTests` run adds regressions for retaining the project workspace during child navigation and opening legacy sources under their actual owner with a return route. All 11 navigation tests pass, including controlled delayed loads, failed saves, import destinations, attachment destinations, request provenance, isolated fixtures, source-scoped detail, and archive staleness.
- `ProjectWorkspaceTests`: 11 tests cover migration, repeated startup, backup and migration failure, conflicts, requests, source groups, stale previews, outdated proposals, handoffs, and read-only legacy retrieval.
- `./scripts/build-app.sh` produces the signed app and MCP executable in `dist/Video Context.app`.
- `./scripts/check-app.sh` verifies the bundle, resources, signatures, arm64 executables, and playback-linkage guard.
- `python3 scripts/smoke-mcp.py` passes all 13 tools, exact recording retrieval, and clean disconnect using a disposable library.
- `git diff --check` passes.

The bundle script retained the existing icon after this machine's `iconutil` rejected its regenerated iconset. The resulting icon and signed bundle passed the bundle checks.

## Native UI verification

Both appearance variants use temporary fixture libraries:

```sh
"dist/Video Context.app/Contents/MacOS/VideoContext" --ui-fixture --ui-minimum --ui-light
"dist/Video Context.app/Contents/MacOS/VideoContext" --ui-fixture --ui-minimum --ui-dark
```

Checked at the 1080×720 minimum content size:

- Projects, both task types, requests, and Inbox appear in the expected workspace. Native row selection and keyboard project navigation work.
- Selecting another task preserves the title search and checked handoff tasks. The Open questions filter shows only tasks with unanswered questions.
- Unsaved task navigation offers Save, Discard, and Cancel. Cancel retains the draft; Save persists it before changing projects. Failed-save and discard behavior have automated coverage.
- A mixed recording/request handoff contains exact source/task IDs and revisions. Implement is disabled when a selected task is ineligible.
- The move preview lists the connected recording, QA batch, and both tasks. Moving the fixture group places them together in the destination project.
- New Task opens on its first attempt with the project fixed. Saving produces a Request comment and zero generated tasks.
- Source images open correctly. A timestamp link seeks to 00:18. Back to task restores the selected task. Feedback evidence opens its exact batch and comment.
- Light/dark layouts, the recording workspace, Settings, and AI Usage remain readable. Accessibility inspection confirms named controls and selected states; keyboard navigation was exercised. A full spoken VoiceOver session was not performed.

Acceptance uses fixture libraries and mocked providers. The real library was not migrated or edited during verification. No paid generation, publishing, commits, or pushes were performed. Existing uncommitted work was preserved.
