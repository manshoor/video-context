# Provider choices and AI Usage acceptance — 15 September 2026

## Delivered

Build 8 (1.0.0), Apple Silicon, macOS 15 minimum, ad hoc signed:
`dist/Video Context.app`.

Claude and DeepSeek are available alongside OpenAI and LM Studio. Task generation follows video-analysis settings by default and supports a separate override. Credentials use separate Keychain accounts. Recording data, Context IDs, task review gates, and existing MCP tools remain compatible.

AI Usage provides library/recording/run views, filters, reported input/output/total tokens, audio duration, stage attempts, cache/resumption links, partial accounting, and shared task/proposal generation usage. Additive migration keeps historical API usage without inventing run associations. Normal usage capture does not depend on opt-in diagnostics.

## Automated verification

- `./scripts/test.sh` exited 0. Swift Testing reported 119 core tests in 23 suites and 27 app tests in 9 suites. Opt-in speech, approved-recording generation, and live usage tests are skipped in this default run.
- Expanded parameterized extraction, consolidation, schema, endpoint, and image tests cover OpenAI, LM Studio, Claude, and DeepSeek.
- Accounting tests cover inclusive Claude cache counts, DeepSeek cache/reasoning fields, malformed/missing counts, duplicate prevention, repeated attempts, invalid output with reported usage, cancellation, interrupted runs, read-only storage failure, Whisper audio duration, recording isolation, legacy migration, cache links, and task revision provenance.
- App tests cover preference upgrades, independent/frozen task overrides, credential late-load protection, denied credentials, untouched empty keys, and saved recording readiness after failed task generation.
- `scripts/smoke-mcp.py` exited 0: all eight existing tools, exact Context ID and task retrieval, images, isolation, and clean disconnect.
- `scripts/smoke-diagnostics.py` exited 0: two processes, dynamic capture policy, text/images, privacy, and unchanged fixture database.
- `scripts/check-app.sh` exited 0: signed arm64 app and MCP binary, plist/icon/probe resources, and no AVKit/private SwiftUI playback bridge linkage.
- `git diff --check` passed.

## Live local acceptance

Ran `AIUsageLocalAcceptanceTests.imageAndTaskUsageInDisposableLibrary` explicitly against the loopback LM Studio server. Loaded the existing `google/gemma-4-12b-qat` model with a 32,768-token context and a 900-second idle unload timeout. No new model download or cloud inference occurred.

The test passed in 16.042 seconds. It read the synthetic image code, generated tasks from fixture transcript/brief content, persisted proposals with generation run IDs, accepted those proposals, and retrieved saved tasks through the read-only task service. It asserted that all requests were local, all token fields were reported, and legacy accounting was not duplicated.

| Run | Requests | Input | Output | Total |
| --- | ---: | ---: | ---: | ---: |
| Synthetic image model test | 1 | 114 | 24 | 138 |
| Fixture task generation | 3 | 1,036 | 582 | 1,618 |

These are measured fixture counts, not estimates or per-card allocations. They are not a recording-quality benchmark. The disposable test library was removed after the test. The user's normal library and recordings were not opened for writing by these checks.

## Native UI inspection

Used a separately signed test copy with bundle ID `app.videocontext.usage-check`, `--ui-fixture --ui-tasks --ui-task-proposals --ui-usage`, and an isolated temporary library. No real keys or provider calls are used in UI fixture mode.

Verified:

- Dark appearance at the 1080 × 720 minimum, and light appearance with an expanded workspace.
- AI Usage summary cards, partial totals, provider filter, expanded attempts, local/cloud labels, and exact generation-run navigation.
- Claude filtering changed fixture totals from 24,600 partial tokens across five requests to 10,300 tokens across two Claude requests.
- Proposal acceptance preserved the shared run link in task details.
- Opening and closing usage preserved an unsaved task-title edit.
- Independent Claude video-analysis and DeepSeek task selections, separate credential controls, explicit model-test notices, and accessible control labels.
- Save settings closed the window and displayed the main-window confirmation.

The UI test app was closed afterward. The user's original running app was left alone.

## Build evidence and limits

Xcode license acceptance was completed by the user. The first sandboxed release build could not generate dSYM files; rerunning the authorized build outside the sandbox succeeded.

Final binary SHA-256:

- `VideoContext`: `b5bca124fb584e975a77dc6e39cb07ff0fa2a20b7cf0e3c455e4988abeca303c`
- `video-context-mcp`: `3595cfe3cb06990122c6b45e3821013442b3de9abe0750bf5f8c965686269e48`

`codesign --verify --deep --strict` passed. Public distribution/notarization is outside this delivery.

No live Claude, DeepSeek, or OpenAI requests were made. Cloud compatibility has mocked request/response coverage but still needs an explicitly authorized live model test with the user's API credentials. Full-length media quality, speech-model inference, and coding-client integration were not repeated for this accounting update; their prior readiness limits remain separate. There was no commit or push.
