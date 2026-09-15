# Video Context

Video Context is a personal macOS app and local MCP server. It turns video recordings into searchable coding context for Codex, Claude Code, and Cursor.

The app imports an MP4 or an accessible online recording, extracts its complete timestamped transcript, selects screenshots, reads visible text with Apple Vision, and creates an evidence-linked coding brief. The bundled MCP executable reads the local library through stdio. It does not call OpenAI or modify the library.

## Requirements

- Apple Silicon Mac with macOS 15 or later
- Xcode with Swift 6.2 or later
- `yt-dlp`, `ffmpeg`, and `ffprobe`
- Either LM Studio plus the downloaded Whisper speech model, an OpenAI API key, or a combination of local and OpenAI providers

The default executable paths are:

```text
/usr/local/bin/yt-dlp
/opt/homebrew/bin/ffmpeg
/opt/homebrew/bin/ffprobe
```

You can change these paths in **Video Context > Settings**. The app checks that each path is executable. The default models are `whisper-1` for transcription and `gpt-5.6-terra` for image analysis and brief generation.

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

When an OpenAI provider is selected, Video Context checks Keychain without opening an authentication prompt during launch. Fully local startup skips OpenAI Keychain access. If macOS requires authentication, select **Unlock API key** in the workspace or Settings. Interrupted recordings appear as paused until processing actually resumes. Screenshot OCR runs in timestamp order and shows completed and total counts; quitting the app pauses unfinished work while preserving completed checkpoints.

## Workspace and processing indicators

The workspace keeps video, transcript, formatted brief, and screenshots visible together. Drag the dividers to resize each pane. Select **Edit** on the brief to make corrections, then **Save** or **Cancel**. Incoming processing updates do not overwrite a draft being edited.

While copying, downloading, or processing a recording, the workspace shows its stage and elapsed time and the Dock icon displays an activity ring. A progress bar shows completed units within the current stage when counts are available; it is not an overall completion estimate. Paused work and credential requests do not animate as active processing. Cancelling a local copy waits for the file copy to finish, preserves the completed import, and prevents processing from starting.

For UI acceptance without paid calls, launch the app with `--ui-fixture`. This creates a separate temporary library with demo content and simulated stages, skips Keychain access, and routes processing to the simulator. `--ui-light` and `--ui-dark` override appearance only for that launch. Normal launches use the real library and system appearance.

## Fully local setup

1. In **Settings > Processing providers**, choose **Local Whisper** and **LM Studio · Local**.
2. Select **Download speech model**. This explicitly downloads Whisper Large v3 Turbo (`openai_whisper-large-v3-v20240930_626MB`) and its tokenizer once, under the library's `models` directory. Allow time for the initial Core ML preparation. A damaged or missing tokenizer fails locally instead of triggering an implicit download.
3. In LM Studio, download a vision model and load it in the Developer tab. Start the local server. For the M4 Max with 48 GB memory, use a **32K context window**. **Gemma 4 12B QAT GGUF** passed the reviewed-task sample after consolidation; **Qwen3.8 27B MLX 4-bit** ran but omitted key requirements in that sample. Start with Gemma for task extraction and review its drafts. See the [acceptance report](docs/acceptance-2026-09-15.md) for evidence and limits; this is not a general model benchmark.
4. Leave the server address at `http://127.0.0.1:1234`, or enter another loopback address and port. Remote hosts, credentials embedded in URLs, and HTTP redirects are rejected. Use a locally downloaded model; LM Link and cloud routing are outside this local integration.
5. If LM Studio requires authentication, enable **Server requires a token** and enter its token. It is stored separately from OpenAI in Keychain (`lm-studio-token`). An untouched empty field does not delete a saved token.
6. Select **Refresh models**, choose a loaded vision model, then **Test model**. The test sends a bundled synthetic image and checks image reading plus structured JSON output. It does not send a recording.
7. Save Settings and import a recording, or resume an incomplete one. Changing providers does not automatically regenerate completed recordings. Saved transcripts and OCR are reused, even if a model or key for that completed stage is unavailable.

Both provider selectors are independent, so you can use local speech with OpenAI analysis or OpenAI speech with local analysis. Existing settings continue to select OpenAI until changed. A running job uses the provider settings captured when it started. Generated artifact revisions and inference usage record the actual provider and model in **Recording details**; old usage records remain labeled OpenAI.

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

Select **Tasks** beside **Brief** in the coding-brief pane. The other three panes stay visible. Task generation is optional and uses the analysis provider shown above the button. It reuses the saved transcript, OCR and images; it does not run Whisper again. With LM Studio selected, no OpenAI key or cloud inference is used.

Local structured extraction disables model reasoning so MLX models return their JSON in the final response. The task schema restricts evidence references to IDs supplied in each batch. Brief timestamps are linked back to primary transcript passages, including long-recording timestamps. Generated text can use **Recording statement** or **AI interpretation/suggestion**; only app edits and answers can add **User clarification**.

After extraction, the selected provider consolidates duplicate drafts and identifies conflicting requirements as blocking review questions. It can only propose groups and questions: the app preserves the original requirements, checks, provenance and evidence. Missing or repeated group members invalidate the result. Consolidation is cached and bounded; if the recording requires separate consolidation batches, affected drafts receive a blocking question to check overlap and conflicts across those boundaries.

1. Finish processing the recording. If corrections made the brief stale, select **Refresh brief** first.
2. Select **Generate tasks**. Validated batches are cached, so a retry can reuse completed work when the source and provider settings match.
3. Open each proposal to compare current and proposed requirements. **Add task** creates a draft; **Apply proposal** updates an existing task; **Reject proposal** preserves it. **Keep current wording** reconciles the task against refreshed evidence without accepting replacement wording. Missing evidence must be relinked before the task can be reviewed.
4. Open a task with **Edit** or **Review**. Edit its requirements and acceptance checks, answer questions, and select supporting evidence. All new questions block review until answered or marked non-blocking with a reason.
5. Select **Annotate** beside a screenshot to add rectangles, arrows or notes. Drag a shape to move it, use its corner or numeric sliders to resize it, and use flip controls to change arrow direction. Give every annotation a description. Save annotations, then save the task. Original images and OCR stay unchanged. Each image supports up to 12 annotations of 500 characters each.
6. Save the task and select **Mark reviewed**. Review approves the requirements; it does not mean implementation is complete. Task edits and source corrections clear approval.
7. Select task cards and choose **Copy selected tasks**. The preview defaults to **Plan**. **Investigate** and **Plan** instruct the agent not to modify code. **Implement** requires every selected task to be current, reviewed, active, and free of unresolved blockers.

The handoff includes permanent Context ID, permanent task IDs, exact revisions and MCP retrieval instructions. Keep these fields when editing the preview. A later edit invalidates an older revision; the agent must request an updated handoff. Review is an app handoff rule, not access control on a coding client.

Tasks can be added manually, reordered and archived. Archived tasks remain retrievable and retain their IDs and revision history. User edits, original generated content and prior task revisions are stored locally. **Open questions** collects unanswered questions across task cards. Analysis never automatically approves tasks, resolves questions, or marks code complete.

### Additional MCP tools

Restart an existing MCP connection after installing the rebuilt app so its client discovers the additional tools. Existing connection configuration and recording tools remain valid.

| Tool | Inputs and behavior |
|---|---|
| `list_video_tasks` | `video_id`, optional `cursor`; lists task IDs, revisions, states and blocker counts within the exact recording. |
| `get_video_task` | `video_id`, `task_id`, optional `expected_revision` and `cursor`; returns bounded structured context blocks for requirements, checks, clarifications and evidence. |
| `get_task_frame` | `video_id`, `task_id`, `evidence_id`, optional `expected_revision` and `crop`; returns one bounded annotated JPEG plus annotation text and metadata. Without annotations it renders the original. |

Pass the handoff's `expected_revision` on task and frame requests. Follow continuation cursors until absent; each is bound to its recording, task or task list, and revisions. Unknown IDs, cross-recording references and revision mismatches return errors without selecting substitutes. All three tools are retrieval-only, require no API key, and work after Video Context and LM Studio quit.

The app owns the additive `reviewedTasks` migration. Task documents include acceptance checks, question answers and normalized annotation shapes. Separate tables preserve revisions, pending proposals and validated generation checkpoints. Opening an older library through MCP returns an empty task list until the app has migrated and populated it; MCP never migrates it.

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
