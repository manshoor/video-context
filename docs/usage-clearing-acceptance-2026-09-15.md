# Usage clearing acceptance — 15 September 2026

Delivered build 10 in `dist/Video Context.app`.

## Changes

AI Usage now offers a confirmed clear for an expanded run, the selected recording, or the entire library. Recording/library scopes include history hidden by filters. Confirmations freeze target IDs, show removal and retained-active counts, and do not include newly finished or new work. The store validates ownership and complete target snapshots in the deletion transaction, then removes only usage tables and accounting-cache links. No migration or MCP interface change was needed.

Active work remains intact. Actual generation caches, recording artifacts, proposals, task history, review state, and generation-run IDs are preserved. Removed run links display “Usage history no longer available” without misleading zero-token summary cards. Success and failure feedback is visible; filters remain selected.

## Verification

- Full default test suite passed: 126 core tests in 24 suites and 31 app tests in 11 suites, exit 0. Opt-in speech/model acceptance remains skipped; no paid calls were made.
- After the final unavailable-history display and singular/plural wording correction, the affected six core and two app clearing tests passed again, exit 0.
- Tests cover all scopes, older usage, exact recording isolation, active and abandoned runs, target freezing, stale attempts/ownership, duplicate confirmation, concurrent connections, rollback after a forced database failure, and continued task publication/accounting.
- Compared non-usage database rows before/after deletion and fixture media/screenshot hashes. Verified actual generation-cache contents survive, cleared generation links remain attached to accepted/edited tasks, and cache reuse can still be recorded.
- Native checks used separately signed copies with disposable `--ui-fixture --ui-tasks --ui-task-proposals --ui-usage` libraries. Exercised Cancel, selected-run removal, recording removal with a focused-run filter, entire-library removal including model tests, disabled empty-recording action, success totals, and preserved proposal links.
- Inspected dark appearance at the 1080 × 720 main-window minimum and the final light-appearance unavailable-history screen at a larger size. Confirmation text, accessible action names, keyboard Escape cancellation, and the visible response to actions were checked. A full spoken VoiceOver session was not performed.
- All eight MCP smoke tools passed, including text/images, exact-ID isolation, and clean disconnect.
- Final app checks passed: plist, icon/probe resources, arm64 app/MCP binaries, signature verification, and the existing no-AVKit/private-SwiftUI-bridge playback compatibility check.
- Release dSYM generation required the existing out-of-sandbox build route. Existing Keychain deprecation and manifest-cache warnings were unrelated to this change.

All clearing actions operated on disposable fixtures. The user's real usage history was not cleared. No provider inference, commit, or push was performed. The bundle uses the project's existing ad-hoc signing; notarization is outside this delivery.
