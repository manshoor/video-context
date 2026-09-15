# Native task workflow acceptance — 15 September 2026

This acceptance uses copies and disposable libraries. The original recording is `vid_17be76da-f212-4e79-ab16-16fadc11ecf4`. No paid inference calls are authorized or used.

## Repairs found during live acceptance

- LM Studio's Qwen MLX runtime routed structured JSON into `reasoning_content` with an empty final answer. Structured extraction now requests `reasoning_effort=none`. Empty final answers produce an actionable error; reasoning traces are never published.
- Task schemas constrain source references to supplied IDs and do not let model output label itself as a user clarification. Generation instructions and recording content use separate message roles. Local task sampling uses temperature 0.7, following the focused local extraction probe.
- Brief citations resolve to primary transcript evidence. Requests retain bounded chronological batches and source checks. Both MM:SS and HH:MM:SS are supported, including recordings over 99 minutes.
- A final local consolidation pass groups duplicate drafts and adds blocking questions for conflicting claims. Required per-draft assignments prevent omitted or repeated membership. The app unions original requirements, checks and evidence rather than letting the model rewrite them. Oversized consolidation splits preserve all drafts and require review across batch boundaries.
- The minimum-size Tasks pane now leaves room for a complete task card. Its compact toolbar retains accessible action names.
- The task editor captures its task and source revision together. Native saving previously reported a false conflict; saving, review, annotation changes and further review now work.
- Implement is a disabled native control when review is required. The backend independently revalidates the handoff at copy time.
- The Swift MCP SDK rejects object-valued experimental initialization metadata from Codex. The retrieval transport ignores unsupported experimental metadata while preserving ordinary capabilities and all tool arguments.
- MCP now exits when its client closes stdin, using the SDK's completion lifecycle.

## Native UI evidence

A separate fixture app (`app.videocontext.acceptance`) was used for UI work. The exercise verified:

- All four panes and a complete task card at the minimum window size in light appearance, and a larger window in dark appearance.
- A clarification saved from revision 1 to 2, review advanced to revision 3, and an Implement message copied that exact task ID and revision.
- A rectangle annotation with a text description moved using normalized coordinates. The width control and Undo worked. Original view hid the annotation without changing the original file.
- Saving the annotation advanced the same task to revision 4 and Needs review. Implement was disabled. Transcript seeking moved playback to 00:38.
- Codex retrieved that saved task, its clarification, and a readable annotated JPEG from the fixture library after its owning app instance quit.

After the Mac was unlocked again, a disposable fixture copied from the final signed build showed all four panes at the minimum window size, real stage counts, elapsed time and cancellation. Selecting the other recording left activity attached to the processing recording. After invoking Minimize, the observed activity continued and later returned to idle with import controls enabled. The fixture then quit cleanly. The final normal app was relaunched and its Tasks pane inspected against the preserved recording.

Full VoiceOver interaction and manual Reduce Motion remain untested. Visual inspection of the minimized Dock indicator remains unavailable: the Dock is not exposed through the native UI tool, and the OS screenshot helper reported that Screen Recording permission was not granted. No OS permission was changed and no Dock screenshot was produced. Automated activity and accessibility-label checks remain part of the suite.

## Client evidence

- Codex: an ephemeral local app-server context retrieved task text and one annotated image at the exact requested revision. No model turn was started.
- Claude Code: connected through a disposable project MCP configuration.
- Cursor: discovered all eight tools through a disposable project MCP configuration.

Claude Code and Cursor agent-driven text/image conversations were not run; doing those would require cloud inference. No permanent client configuration was changed.

The final signed MCP executable also retrieved the fixture's revision-4 task and its annotated screenshot under `sandbox-exec` with all networking denied. It returned one 77,375-byte JPEG, preserved the annotation metadata, rejected unknown recording IDs and wrong revisions, and exited with code 0 when stdin closed.

The follow-up closed both Video Context and LM Studio. Process inspection found no target app processes, and a socket check confirmed port 1234 was closed (`.build/apps-closed-check.json`). With that state preserved, the signed MCP executable retrieved all 28 consolidated tasks across 43 text pages plus a screenshot under a network-denied sandbox. An ephemeral Codex context separately retrieved the exact saved fixture task revision and its annotated image through the signed executable. No model conversation or paid inference was started.

After verification, the normal app and LM Studio were reopened. The local server and the previously loaded Gemma model were restored with a 32K context. The app's existing provider preference remains OpenAI; select LM Studio in Settings to use local analysis. The normal recording remains unchanged and its Tasks pane remains empty because acceptance generation used separate libraries.

## Source preservation

The original library still contains one recording, 37 transcript passages, 28 evidence items, one brief and seven usage records. Its logical data digest remains:

`1359ed74d6153b1d92f4e840842defa03f926de47afa0aea51999a70c9b8123c`

Recipe: select rows ordered by rowid from `videos`, `transcript_segments`, `evidence_items`, `briefs`, `api_usage`; collect tuples under each table name; hash `json.dumps(tables, sort_keys=True)` using SHA-256. The live test also compares the original recording, transcript, evidence and brief before and after generation.

## Final verification

- The final automated suite reported 109 tests across 24 suites passing. The two opt-in live tests were skipped in that run; task generation was exercised separately against LM Studio. The new tests cover consolidation membership, distinct saved IDs, evidence preservation, blocking questions, overflow, cache reuse and failed publication for both analysis adapters.
- `scripts/check-app.sh` passed for the signed Apple Silicon app and bundled MCP executable, including icon, plist and playback compatibility checks.
- `scripts/smoke-mcp.py` passed all eight tool discovery checks, exact-recording retrieval, wrong-ID and revision rejection, image retrieval, Codex experimental metadata compatibility, and clean client disconnect.
- The app uses a local ad-hoc signature. This is a locally runnable build, not a notarized distribution release.

Earlier Qwen runs returned valid structured output but omitted requested behaviors. The strengthened recording-specific test checks coverage of the style picker, captions, approval, layout and editing/regeneration. Valid JSON alone is not treated as extraction quality acceptance.

## Local generation result

The installed `google/gemma-4-12b-qat` GGUF model, loaded with a 32K context, completed 16 extraction batches in 647.089 seconds. The first output contained 47 cards with overlapping wording and an incorrect approval-count claim. That exposed the missing consolidation step; the initial result was not treated as quality acceptance.

The final retry reused all 16 extraction checkpoints in another disposable copy. One local consolidation call completed in 45.374 seconds. The strengthened acceptance test passed with 28 draft tasks, 78 distinct requirements, 57 distinct checks and 21 questions. A separate comparison confirmed every original requirement and check retained its text, origin and evidence references. No transcript or OCR stage reran.

The output now asks this blocking question explicitly: “Does 'Approve & Create Posts' create the studio instance with ONLY the approved posts, or does it include the remaining unapproved posts from the batch as well?” The draft claims remain visible so the reviewer can resolve them against the recording. Some task scopes still overlap; this is reviewed source material, not an automatically approved implementation specification. This single recording supports trying Gemma for task extraction; it is not a general model-quality benchmark.

The final signed MCP executable retrieved all 28 tasks across 43 text pages and one readable screenshot from the saved copy with all networking denied. Unknown IDs and stale revisions failed as expected, and the process exited cleanly. The test Context ID is `vid_8ba240c0-eb71-4287-8cc1-5ed1fe099d46`; it belongs to the disposable acceptance library, not the normal library.

Evidence files are under `.build/task-acceptance-20260915-reconciled/`: `task-acceptance-results.json`, `offline-mcp-results.json` and `offline-task-frame.jpg`. Final suite and build logs are `/tmp/vc-final-tests.log` and `/tmp/vc-final-build.log`. No paid API calls were made. Live Whisper transcription was not repeated in this task-generation acceptance run.
