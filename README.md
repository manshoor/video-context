# Video Context

Video Context is a personal macOS app and local MCP server. It turns video recordings into searchable coding context for Codex, Claude Code, and Cursor.

The app imports an MP4 or an accessible online recording, extracts its complete timestamped transcript, selects screenshots, reads visible text with Apple Vision, and creates an evidence-linked coding brief. The bundled MCP executable reads library content through stdio. By default it opens the library read-only, makes no inference calls, and never changes recording content. An explicitly enabled `--allow-document-proposals` capability writes only a separate local proposal inbox for app review; diagnostics remain opt-in.

## Requirements

- Apple Silicon Mac with macOS 15 or later
- Xcode with Swift 6.2 or later
- `yt-dlp`, `ffmpeg`, and `ffprobe`
- Local Whisper or an OpenAI API key for speech; LM Studio, OpenAI, Claude, or DeepSeek for screenshot analysis and tasks

The default executable paths are:

```text
/usr/local/bin/yt-dlp
/opt/homebrew/bin/ffmpeg
/opt/homebrew/bin/ffprobe
```

You can change these paths in **Video Context > Settings**. The app checks that each path is executable. The default models are `whisper-1` for transcription and `gpt-5.6-terra` for image analysis and brief generation.

## Analysis providers and AI Usage

Settings provides independent choices for **Screenshots and coding brief** and **Task generation**. Tasks follow video-analysis settings by default. Turn off **Use video-analysis settings** to choose a separate task provider/model. Each run freezes its choices. Changing Settings does not reprocess completed recordings, change active requests, or silently select another provider.

Documentation analysis and evidence review have separate model selections. The optional **Accuracy profile** sets Sol `high` for visual analysis, Astra `high` for documentation and task analysis, and Claude Opus `high` for independent evidence review. It preserves the speech pipeline and only takes effect when you choose and save it. Existing settings keep their saved values. These defaults require evaluation on your recordings; see the [offline comparison workflow](docs/analysis-model-evaluation.md).

In **Documentation → Reference sources**, designate reviewed documentation, original recordings, and imported repository Markdown/PDF sources. Task and documentation generation use this shared project context, preserving revision-aware citations. Use **Refresh file** explicitly after editing an imported source. Review findings, source warnings, dependencies, and visual/OCR comparisons appear with task drafts and are included in MCP handoffs. See the [project reference workflow](docs/product-documentation-guide.md).

- **LM Studio:** loopback server, loaded vision model, optional local token. Local Whisper + LM Studio keeps inference local.
- **OpenAI:** API key and an image-capable model with structured output.
- **Claude:** separate Anthropic API key, native Messages API, image-capable model supporting structured JSON output.
- **DeepSeek:** separate API key. Image-dependent work is enabled for `deepseek-flash` and the compatible legacy `deepseek-v4-flash-vision-exp` identifier. Unsupported models fail before recording evidence is sent.

Use **Refresh models**, select or enter the exact model ID, then **Test model**. Cloud model tests are explicit API calls using a bundled synthetic image, and their usage is recorded separately. Chat subscriptions do not supply API credentials. Model access depends on your provider account. No model download or paid test starts automatically. Keys are stored in separate Keychain accounts. Unlock controls and background loading apply to each key. **Save settings** closes Settings after successful persistence and shows confirmation in the main window.

Provider wire formats follow [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) and [DeepSeek vision](https://api-docs.deepseek.com/guides/vision/). Test the selected model before sending recording evidence; compatibility and availability can change.

Open **AI Usage** in the toolbar for the library, or **View usage** in recording details. Filter by recording, provider, model, operation, and date. The library defaults to 30 days; recording and generation links use all time. Expand a run to see its stages and inference attempts. Task and proposal details link to **View generation usage**; these totals are shared across the cards created by that run. Manual tasks have no generation usage.

Input/output counts come from provider responses. Total is derived only when both counts are present. Claude input includes uncached input, cache writes, and cache reads; cache and reasoning breakdowns are already included and are not added again. Missing counts show **Not reported**, and aggregates with missing data show **Partial total**. Whisper uses audio duration and elapsed time when token counts are not meaningful. No live token estimates, monetary estimates, or invented per-card counts are shown.

Each processing, task-generation, and model-test invocation gets a permanent run ID. Responses are accounted for before content validation, including invalid output and failed HTTP responses that report usage. Retried requests are separate attempts; cached batches add no new inference tokens and link to earlier runs where available. Interrupted requests may have unknown usage. Older records remain under **Earlier usage — run details unavailable**, without guessed task associations. Storage failures appear in the app and mark accounting incomplete.

Usage history is saved locally regardless of the diagnostic logging switch. Its records contain IDs, provider/model identity, counts, timestamps, duration, and outcomes. They do not contain prompts, credentials, transcripts, screenshots, or response bodies. Library titles are read separately for display. MCP tools and Context IDs remain unchanged.

## Build and run

Run:

```bash
./scripts/build-app.sh
open "dist/Video Context.app"
```

The build script creates an ad hoc signed app at `dist/Video Context.app`. It includes both the SwiftUI app and `video-context-mcp`.

The icon is rendered from vector drawing instructions in `scripts/generate-icon.swift`. The build generates all standard icon sizes and packages them as `AppIcon.icns` before signing.

The local library is stored at:

```text
~/Library/Application Support/VideoContext/
```

Imported files are copied into this library. The source MP4 is not changed. The OpenAI API key is stored in macOS Keychain under service `app.videocontext.mac`.

## Use the app

1. Open Settings, choose providers for speech and analysis, complete their setup, confirm media tool paths, and save.
2. Drop an MP4 into the library, select **Import MP4**, or select **Import Link** for an accessible Loom, YouTube, or direct video URL.
3. Keep the app open while the recording processes. One recording processes at a time.
4. Review the video, transcript, screenshots, OCR, and coding brief.
5. Correct transcript text, edit the brief, or save the current video frame when needed.
6. Select **Copy ID only** when you need the identifier by itself, or select **Copy context message** for a complete handoff containing the title, permanent Context ID, current processing status, and exact MCP retrieval instructions.

If a link needs authentication or blocks `yt-dlp`, download its MP4 and import the file. Completed transcript and evidence checkpoints remain in the database when a later step fails. The app resumes unfinished work when its required providers are available. Select **Resume processing** after completing local model setup.

Transcript corrections preserve the extracted text. Corrected rows show both versions. Transcript corrections and manual frames advance the artifact revision and mark the generated brief as stale. Saving an edited brief records it as user edited and associates it with the current transcript and evidence revisions.

Every imported recording receives a permanent Context ID in the form `vid_<UUID>`. The ID remains unchanged after processing, corrections, brief edits, and app restarts. Separate imports receive separate IDs even when their titles are identical.

The copied context message tells the coding agent to use this exact ID for every MCP call, avoid `list_videos`, and never switch to another recording as a fallback. It also reports whether processing is active, paused, failed, ready, or ready with a stale brief. If the selected recording is unavailable or lacks evidence, the agent must report that limitation.

When an OpenAI provider is selected, Video Context checks Keychain without opening an authentication prompt during launch. Fully local startup skips OpenAI Keychain access. The app retries a temporary missing lookup once and rechecks unavailable selected-provider credentials when it becomes active after unlock. If a key still has not loaded, use **Load saved key** in Settings. If macOS requires authentication, select **Unlock API key** in the workspace or Settings. You do not need to paste a saved key again. Settings lists all four analysis providers and shows the installed build number. Interrupted recordings appear as paused until processing actually resumes. Screenshot OCR runs in timestamp order and shows completed and total counts; quitting the app pauses unfinished work while preserving completed checkpoints.

## Workspace and processing indicators

The workspace keeps video, transcript, formatted brief, and screenshots visible together. Drag the dividers to resize each pane. Select **Edit** on the brief to make corrections, then **Save** or **Cancel**. Incoming processing updates do not overwrite a draft being edited.

While copying, downloading, or processing a recording, the workspace shows its stage and elapsed time and the Dock icon displays an activity ring. A progress bar shows completed units within the current stage when counts are available; it is not an overall completion estimate. Paused work and credential requests do not animate as active processing. Cancelling a local copy waits for the file copy to finish, preserves the completed import, and prevents processing from starting.

For UI acceptance without paid calls, launch the app with `--ui-fixture`. This creates a separate temporary library with multiple projects, both task types, requests, and Inbox content. It skips Keychain access, routes processing to the simulator, and disables provider task generation. Add `--ui-processing` to show simulated processing stages; `--ui-minimum` sets the 1080×720 minimum window. `--ui-light` and `--ui-dark` override appearance only for that launch. Normal launches use the real library and system appearance.

## Fully local setup

1. In **Settings > Processing providers**, choose **Local Whisper** and **LM Studio · Local**.
2. Select **Download speech model**. This explicitly downloads Whisper Large v3 Turbo (`openai_whisper-large-v3-v20240930_626MB`) and its tokenizer once, under the library's `models` directory. Allow time for the initial Core ML preparation. A damaged or missing tokenizer fails locally instead of triggering an implicit download.
3. In LM Studio, download a vision model and load it in the Developer tab. Start the local server. For the M4 Max with 48 GB memory, use a **32K context window**. **Gemma 4 12B QAT GGUF** passed the reviewed-task sample after consolidation; **Qwen3.8 27B MLX 4-bit** ran but omitted key requirements in that sample. Start with Gemma for task extraction and review its drafts. See the [acceptance report](docs/acceptance-2026-09-15.md) for evidence and limits; this is not a general model benchmark.
4. Leave the server address at `http://127.0.0.1:1234`, or enter another loopback address and port. Remote hosts, credentials embedded in URLs, and HTTP redirects are rejected. Use a locally downloaded model; LM Link and cloud routing are outside this local integration.
5. If LM Studio requires authentication, enable **Server requires a token** and enter its token. It is stored separately from OpenAI in Keychain (`lm-studio-token`). An untouched empty field does not delete a saved token.
6. Select **Refresh models**, choose a loaded vision model, then **Test model**. The test sends a bundled synthetic image and checks image reading plus structured JSON output. It does not send a recording.
7. Save Settings and import a recording, or resume an incomplete one. Changing providers does not automatically regenerate completed recordings. Saved transcripts and OCR are reused, even if a model or key for that completed stage is unavailable.

Speech and video-analysis selectors are independent, and task generation can override the video-analysis provider. Existing settings continue to select OpenAI until changed. A running job uses the provider settings captured when it started. Generated artifact revisions record provider/model provenance in **Recording details**. **AI Usage** shows requests and token counts; earlier records retain their original provider labels.

The local analysis adapter uses LM Studio's `/api/v1/models` and `/v1/chat/completions`. It processes complete chronological transcript coverage and up to two images per initial batch, splits oversized image batches, and combines large collections of summaries in bounded stages. Missing images, invalid JSON, and truncated responses prevent brief publication. Corrections made during generation prevent outdated output from replacing the user's changes.

Keep Video Context and LM Studio running during local analysis. Once processing is complete, MCP retrieval needs neither app nor any model server. Online video downloads still require Internet access; local-file processing works offline after model setup.

References: [LM Studio structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output), [model discovery](https://lmstudio.ai/docs/developer/rest/list), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), [Qwen3.8 27B](https://lmstudio.ai/models/qwen/qwen3.8-27b), [Gemma 4 12B QAT](https://lmstudio.ai/models/google/gemma-4-12b-qat).

## Connect coding clients

The app's Settings window creates copyable configuration with the MCP path for the current build. For the bundled app in this repository, the executable is:

```text
/absolute/path/to/videoTranscripts/dist/Video Context.app/Contents/MacOS/video-context-mcp
```

Codex configuration:

```toml
[mcp_servers.video-context]
command = "/absolute/path/to/Video Context.app/Contents/MacOS/video-context-mcp"
args = []
```

Claude Code and Cursor configuration:

```json
{
  "mcpServers": {
    "video-context": {
      "command": "/absolute/path/to/Video Context.app/Contents/MacOS/video-context-mcp",
      "args": []
    }
  }
}
```

Each client starts its own MCP server instance. The process opens the shared SQLite database in read mode for retrieval operations. SQLite WAL and bounded read transactions let agents retrieve a consistent artifact revision while the app publishes or corrects another revision. Completed context remains available while the app is closed.

For an alternate library location, add `--library` and the absolute directory path to the MCP `args` array. If `ffmpeg` is elsewhere, add `--ffmpeg` and its absolute path.

## MCP tools

| Tool | Result |
|---|---|
| `list_videos(query?, cursor?)` | Recording status, duration, permanent Context IDs, revisions, and pagination |
| `get_video_brief(video_id, cursor?)` | About 500 words from the exact Context ID and a continuation cursor |
| `search_video(video_id, query, cursor?)` | Paginated full-text matches within the exact Context ID |
| `get_video_segment(video_id, start_seconds, end_seconds, cursor?)` | Timestamped transcript and evidence within the exact Context ID and time range |
| `get_video_frame(video_id, timestamp_seconds, crop?)` | One JPEG frame from the exact Context ID, optionally cropped using normalized top-left coordinates |

For all scoped tools, `video_id` means the permanent Context ID shown in the app. Lookup uses an exact ID. Unknown IDs return an error, and unmatched searches return no results without falling back to another recording. Every text tool returns structured JSON plus a readable JSON text equivalent. Frame calls return structured metadata, readable text, and one image. Recorded content is treated as evidence and is never executed by the server.

## Processing and privacy

The app uses local `ffmpeg` media processing and Apple Vision OCR. Local Whisper performs speech recognition on this Mac; LM Studio receives transcript and image batches only through its loopback server. With OpenAI transcription selected, audio chunks are uploaded to OpenAI. With OpenAI analysis selected, transcript text and selected screenshots are uploaded to the OpenAI Responses API. There is no automatic cloud fallback. Original video files, transcripts, screenshots, briefs, corrections, and the search index remain in the local Application Support library.

Long recordings are split near silence with a two-second overlap and a ten-minute target. The merger restores recording-relative timestamps and removes duplicate overlap segments. Screenshot candidates combine scene changes, periodic checkpoints, and timestamps near narrated actions. Apple Vision feature prints remove visually similar frames while retaining frames connected to narrated actions.

## Development and verification

Run the automated suite:

```bash
./scripts/test.sh
```

Smoke-test the bundled stdio MCP handshake and tool list:

```bash
./scripts/smoke-mcp.py
```

Check the signed app bundle and guard against the private SwiftUI AVKit bridge that caused a macOS 26 runtime crash:

```bash
./scripts/check-app.sh
```

The tests use fixture media metadata and mocked provider responses. They cover chunk boundaries, overlap merging, screenshot planning, OpenAI request formats, pipeline checkpoint recovery, cancellation state, SQLite revisions and FTS, MCP pagination, and frame crop validation.

A live OpenAI end-to-end run consumes API credits and requires a recording that the operator is authorized to upload. A fully local acceptance run needs downloaded models and a running LM Studio server, and makes no paid API calls. Run that acceptance step before treating provider compatibility or a specific Loom/YouTube link as verified. The automated suite does not make paid provider calls.

### Opt-in local speech acceptance

The normal suite skips real model inference and model downloads. To run speech acceptance against an authorized recording, set `VIDEO_CONTEXT_LOCAL_SPEECH_ACCEPTANCE=1`, `VIDEO_CONTEXT_ACCEPTANCE_ROOT` to an isolated absolute cache directory, and `VIDEO_CONTEXT_ACCEPTANCE_MEDIA` to the recording's absolute path. Set `VIDEO_CONTEXT_DOWNLOAD_SPEECH_MODEL=1` only when explicitly downloading the model, then run `./scripts/test.sh --filter LocalSpeechAcceptanceTests`. The test uses the first 25 seconds, checks timestamp offsets, and expects the word `calendar` from the approved walkthrough sample.

WhisperKit 1.1.0 is pinned. Real Core ML acceptance needs normal macOS audio, GPU, and cache access. To verify offline operation after downloading the assets, run the cached test under a sandbox profile that allows native framework access but denies outbound networking; the tightly restricted development filesystem sandbox is unsuitable for this native-framework test.

## Reviewed tasks and focused handoffs

Open a project in the sidebar to see its **Tasks**. The project also contains **Recordings** and **Feedback & Requests**. Recording tasks and feedback/request tasks share one list, grouped by source. Search titles or choose **All**, **Needs review**, **Open questions**, or **Ready for handoff**; use **Archived** to access saved archived tasks. Task generation is optional and uses the analysis provider shown above the button on a source. It reuses the saved transcript, OCR and images; it does not run Whisper again. With LM Studio selected, no OpenAI key or cloud inference is used.

Local structured extraction disables model reasoning so MLX models return their JSON in the final response. The task schema restricts evidence references to IDs supplied in each batch. Brief timestamps are linked back to primary transcript passages, including long-recording timestamps. Generated text can use **Recording statement** or **AI interpretation/suggestion**; only app edits and answers can add **User clarification**.

After extraction, the selected provider consolidates duplicate drafts and identifies conflicting requirements as blocking review questions. It can only propose groups and questions: the app preserves the original requirements, checks, provenance and evidence. Missing or repeated group members invalidate the result. Consolidation is cached and bounded; if the recording requires separate consolidation batches, affected drafts receive a blocking question to check overlap and conflicts across those boundaries.

1. Finish processing the recording. If corrections made the brief stale, select **Refresh brief** first.
2. Select **Generate tasks**. Validated batches are cached, so a retry can reuse completed work when the source and provider settings match.
3. Open a proposed change in the project task list to compare current and proposed requirements. **Apply change** accepts it; **Reject** preserves the existing task. **Keep wording** reconciles a recording task against refreshed evidence without accepting replacement wording. Missing evidence must be relinked before the task can be reviewed.
4. Select a task to edit its requirements and acceptance checks, answer questions, and select supporting evidence in the inline detail pane. All new questions block review until answered or marked non-blocking with a reason. Navigation away from unsaved edits offers Save, Discard, or Cancel. Failed saves retain the draft and error.
5. Select **Annotate** beside a screenshot to add rectangles, arrows or notes. Drag a shape to move it, use its corner or numeric sliders to resize it, and use flip controls to change arrow direction. Give every annotation a description. Save annotations, then save the task. Original images and OCR stay unchanged. Each image supports up to 12 annotations of 500 characters each.
6. Save the task and select **Mark reviewed**. Review approves the requirements; it does not mean implementation is complete. Task edits and source corrections clear approval.
7. Check tasks from any recordings or batches within the current project and choose **Copy for Cursor**. The preview defaults to **Plan**. **Investigate** and **Plan** instruct the agent not to modify code. **Implement** requires every selected task to be current, reviewed, active, and free of unresolved blockers.

The handoff includes permanent Context ID, permanent task IDs, exact revisions and MCP retrieval instructions. Keep these fields when editing the preview. A later edit invalidates an older revision; the agent must request an updated handoff. Review is an app handoff rule, not access control on a coding client.

**New Task** opens a written request with the current project fixed. Saving creates a request batch; generation starts only when you choose **Generate tasks** from that request. Tasks can be archived and restored. Existing source task order is preserved. Archived tasks remain retrievable and retain their IDs and revision history. User edits, original generated content and prior task revisions are stored locally. **Open questions** collects unanswered questions across task cards. Analysis never automatically approves tasks, resolves questions, or marks code complete.

### Project ownership and moving sources

New imports require a project. Imports and feedback attachments capture their destination before background work starts, so switching projects cannot redirect their saved results. New links to existing recordings must stay within the same project.

On the first app launch after this update, SQLite creates a consistent backup beside `library.sqlite`, named `library.sqlite.before-projects-<UUID>.sqlite`, before the transactional `projectWorkspaceOwnership` migration. Connected recordings and feedback with one unambiguous existing project inherit it without changing their approvals. Unassigned content appears in **Inbox**. Conflicting assignments remain readable and show a resolution action. MCP stays read-only and can retrieve tasks from libraries that have not run this migration.

**Move source group to Project** previews every connected local recording, batch, and task. The move is atomic and blocked while content is processing or being edited. Moving ownership preserves media paths, IDs, content, archives, and history, clears approvals, and invalidates previous handoffs. Pending proposals remain visible as outdated. Current evidence can be reviewed again; stale evidence still needs reconciliation.

### Additional MCP tools

Restart an existing MCP connection after installing the rebuilt app so its client discovers the additional tools. Existing connection configuration and recording tools remain valid.

| Tool | Inputs and behavior |
|---|---|
| `list_video_tasks` | `video_id`, optional `cursor`; lists task IDs, revisions, states and blocker counts within the exact recording. |
| `get_video_task` | `video_id`, `task_id`, optional `expected_revision` and `cursor`; returns bounded structured context blocks for requirements, checks, clarifications and evidence. |
| `get_task_frame` | `video_id`, `task_id`, `evidence_id`, optional `expected_revision` and `crop`; returns one bounded annotated JPEG plus annotation text and metadata. Without annotations it renders the original. |

Pass the handoff's `expected_revision` on task and frame requests. Follow continuation cursors until absent; each is bound to its recording, task or task list, and revisions. Unknown IDs, cross-recording references and revision mismatches return errors without selecting substitutes. All three tools are retrieval-only, require no API key, and work after Video Context and LM Studio quit.

The app owns the additive `reviewedTasks` migration. Task documents include acceptance checks, question answers and normalized annotation shapes. Separate tables preserve revisions, pending proposals and validated generation checkpoints. Opening an older library through MCP returns an empty task list until the app has migrated and populated it; MCP never migrates it.

Project context tools keep the reusable product reference in one project scope. Start with `list_projects`, then pass the exact returned ID to `get_project_context` or `search_project`. Use `get_project_document` for concise reviewed documentation and `get_project_evidence` for the cited transcript segment, screenshot, feedback comment, attachment, or document page/line. Every result includes source or document revisions, freshness, citations and continuation cursors. Historic evidence is returned as `stale` when its retained revision is available; newer or missing revisions fail closed. Cross-project IDs are rejected.

The default server exposes `list_projects`, `get_project_context`, `search_project`, `get_project_document`, and `get_project_evidence` as read-only tools. A client can submit a documentation change only when the server is started with `--allow-document-proposals`; `submit_document_proposal` writes a review inbox beside the library and does not approve or apply anything. Its request ID is idempotent, its payload contains document sections and evidence references, and it accepts no arbitrary file paths. Review and acceptance stay inside Video Context.

### Task acceptance checks

Automated tests use mock providers and disposable libraries. Run the native task demo without changing your library:

```bash
"dist/Video Context.app/Contents/MacOS/VideoContext" --ui-fixture --ui-tasks --ui-minimum --ui-light
```

For live local generation, start LM Studio, load a vision model with a 32K context window, then run the opt-in test with a **new output directory**:

```bash
VIDEO_CONTEXT_TASK_ACCEPTANCE=1 \
VIDEO_CONTEXT_SOURCE_LIBRARY="$HOME/Library/Application Support/VideoContext" \
VIDEO_CONTEXT_SOURCE_ID="vid_17be76da-f212-4e79-ab16-16fadc11ecf4" \
VIDEO_CONTEXT_TASK_OUTPUT="$PWD/.build/task-acceptance-$(date +%s)" \
VIDEO_CONTEXT_TASK_MODEL="your-loaded-model-key" \
./scripts/test.sh --filter TaskLocalAcceptanceTests
```

This copies the approved recording, transcript and screenshots into a separate library, runs task generation through loopback LM Studio, and verifies saved task retrieval and source preservation. It does not retranscribe or call OpenAI. It expects a local server without token authentication; normal app generation supports the separate optional LM Studio token in Settings. Review the resulting `task-acceptance-results.json` for task quality. A passing mock suite is not a substitute for this live model acceptance or native UI/client checks.


## Local diagnostic capture

In **Settings → Diagnostics**, choose **Enable logging for 24 hours**, reproduce the problem, then choose **Export diagnostics**. Keep the recording's Context ID and approximate failure time with your report. Capture starts off and cannot reconstruct events that happened before it was enabled.

The app and every MCP process using the same library share the capture window. Existing MCP connections pick up changes without reconnecting. **Stop logging** ends capture early; the 24-hour expiry also applies with the app closed. The main window shows an indicator while capture is on. This setting does not enable verbose WhisperKit or MCP transport logging.

Logs are stored under `~/Library/Application Support/VideoContext/diagnostics/logs`. Custom `--library` roots keep their own diagnostics. Logs rotate at 2 MiB and are capped at 50 MiB; files older than seven days are removed when capture writes or an export reads them. Logging failures do not stop video processing or MCP retrieval. Settings shows local capture failures; recovered writers report dropped-event counts in later events. No background daemon runs while all clients are closed.

A diagnostic ZIP contains JSON Lines events, a readable timeline, build/OS information, recording status/revisions and checkpoint counts, and safe crash summaries. Export defaults to the selected Context ID and the last 24 hours, with all-recording and three/seven-day options. Application-wide events and crashes are included for either scope. Missing components and incomplete log tails are identified in the manifest. Elapsed time is not evidence of progress, and a missing completion event does not prove a crash.

Normal logs and exports exclude credentials, recording titles, source URLs, paths, transcript/OCR text, briefs, task wording, images, prompts, provider responses, and subprocess output. Model identifiers are validated before inclusion. Errors use fixed categories and numeric codes rather than raw messages. **Include full macOS crash reports** is unchecked by default: raw reports can contain private details, so inspect the ZIP before sharing when that option is selected. Nothing is automatically uploaded or added to a coding-agent handoff.

Run `python3 scripts/smoke-diagnostics.py` after building the app to exercise dynamic capture, two concurrent MCP processes, text/image retrieval, error privacy, and unchanged library data using disposable fixtures. The check makes no model or paid API calls. Diagnostics tests are included in `./scripts/test.sh`; filter with `--filter Diagnostic` for focused checks.

### Clear AI usage history

Open **AI Usage**. Expand a run and choose **Clear this run…**, or use **Clear usage history → This recording… / Entire library…**. Recording and library actions include all dates, providers, and operations, including history hidden by filters. Entire-library clearing also includes model tests and earlier usage.

The confirmation lists finished runs, inference requests, earlier usage entries, and active runs being retained. Clearing is permanent. Active runs and history created or finished after the confirmation preview remain; clear them later if needed. Cancel makes no deletion. If confirmed records change, the app requests a fresh confirmation.

Only local usage records and their accounting links are removed. Videos, transcripts, briefs, tasks, screenshots, annotations, review states, and processing caches remain intact. Tasks keep their generation-run IDs; links to removed usage show **Usage history no longer available**. Clearing does not change provider billing, erase diagnostic exports, or stop future usage capture.

## QA and manager feedback

Open a project and choose **Add Feedback**. Its batches appear in **Feedback & Requests** and can exist without a recording. Older unassigned sources remain accessible in **Inbox** for assignment through a source-group move. Give the batch a title, paste feedback with one comment per line, and optionally select several PNG, JPEG, WebP, or MP4 files. You can also use **Add Media** on a saved batch. Files added at the batch level link to every comment; the button below a comment links files only to that comment. The app keeps the pasted text, extracts links, and groups each link with its comment. A comment without a link in a batch that has linked evidence starts as a shared instruction; you can change that in **Edit Feedback**. That screen also lets you correct comments, label a reviewer as QA or Manager, change source links, or associate a ready recording. You can replace a failed link with a local file.

Public Screencast image shares are read as their original images, including visible annotations. Apple Vision reads their text. Accessible video links use the recording pipeline; linked ready recordings reuse their saved evidence. Each source shows its state and can be retried separately. Failed evidence stays linked to the comment and creates a blocking question on dependent generated tasks.

Select **Generate tasks** to use the task provider chosen in Settings. The selected recording's brief and saved tasks provide context. New tasks are saved as drafts. The app shows proposed changes to existing feedback tasks for review and keeps your edits until you apply a proposal. Open **Tasks**, resolve each task’s questions, choose **Mark reviewed**, then select tasks for **Copy for Cursor**. The default mode is Plan; Implement is available only for approved current tasks. The copied message contains each selected task’s exact recording or batch ID, task ID, and source/task revisions. The app revalidates membership and revisions immediately before copying.

Cursor reads feedback through the local read-only MCP tools `get_feedback_batch`, `list_feedback_tasks`, `get_feedback_task`, and `get_feedback_evidence`. It should follow continuation cursors and use the returned recording Context ID when a source links to a recording. The share URL, saved image, OCR, task checks, and user clarifications remain associated with the feedback batch. MCP retrieval works after the app closes. The app does not read a project's repository; instructions to compare with existing Ideolab work go to Cursor in the task handoff.
