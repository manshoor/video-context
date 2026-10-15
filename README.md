# Video Context

Turn screen recordings, QA feedback, and product docs into searchable, evidence-linked coding context for AI agents.

Video Context is a macOS app plus a local [MCP](https://modelcontextprotocol.io) server. The app processes a recording into a timestamped transcript, screenshots, OCR text, a coding brief, and reviewed tasks. Codex, Claude Code, or Cursor then read that context through the bundled `video-context-mcp` server.

## Features

- **Import** an MP4 or a Loom, YouTube, or direct video link.
- **Transcribe** with local Whisper or OpenAI.
- **Analyze** screenshots and generate briefs and tasks with LM Studio (local), OpenAI, Claude, or DeepSeek.
- **OCR** visible text with Apple Vision.
- **Review** and edit transcripts, briefs, and tasks. Each change creates a new revision.
- **Organize** recordings, feedback, and reference docs into projects.
- **Hand off** a task to a coding agent with a permanent ID and exact revision.
- **Track** token usage per provider, model, and run.
- **Run fully local**: Local Whisper + LM Studio sends nothing to the cloud.

## How it works

```text
 recording / link / feedback
            |
            v
 +---------------------+   ffmpeg, Whisper, Apple Vision,
 |  Video Context app  |   LM Studio / OpenAI / Claude / DeepSeek
 +---------------------+
            |  writes
            v
 ~/Library/Application Support/VideoContext/  (SQLite + media)
            |  reads (read-only)
            v
 +---------------------+   stdio
 |  video-context-mcp  | <-------> Codex / Claude Code / Cursor
 +---------------------+
```

The MCP server opens the library read-only, makes no model calls, and works while the app is closed.

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Xcode with Swift 6.2 or later
- `yt-dlp`, `ffmpeg`, and `ffprobe`
- A speech provider: Local Whisper or an OpenAI API key
- An analysis provider: LM Studio, OpenAI, Claude, or DeepSeek

```bash
brew install yt-dlp ffmpeg
```

## Build and run

```bash
./scripts/build-app.sh
```

```bash
open "dist/Video Context.app"
```

The script builds an ad hoc signed app at `dist/Video Context.app`, with `video-context-mcp` inside it.

Then open **Settings**, choose your providers, and import a recording. API keys are stored in the macOS Keychain.

## Connect a coding agent

**Settings > Agent connections** shows the exact command for your build. The app never edits client config files.

Claude Code and Cursor:

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

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.video-context]
command = "/absolute/path/to/Video Context.app/Contents/MacOS/video-context-mcp"
args = []
```

Add `--library <dir>` or `--ffmpeg <path>` to `args` for non-default locations.

Main MCP tools: `list_projects`, `get_project_context`, `search_project`, `list_videos`, `get_video_brief`, `search_video`, `get_video_segment`, `get_video_frame`, `get_video_task`, `get_feedback_task`. See the [user guide](docs/user-guide.md#mcp-tools) for the full list.

## Privacy

Media, transcripts, screenshots, and briefs stay in the local library. Data leaves your Mac only when you select a cloud provider:

- **OpenAI transcription:** audio chunks are uploaded.
- **Cloud analysis:** transcript text and selected screenshots are uploaded.

There is no automatic cloud fallback. Diagnostics are opt-in.

## Development

```bash
./scripts/test.sh
```

```bash
./scripts/smoke-mcp.py
```

```bash
./scripts/check-app.sh
```

Tests use mocked providers and disposable libraries. They make no paid API calls.

## Documentation

- [User guide](docs/user-guide.md): full reference for every feature
- [Product documentation guide](docs/product-documentation-guide.md)
- [Analysis model evaluation](docs/analysis-model-evaluation.md)

## Project layout

```text
Sources/VideoContextApp    SwiftUI macOS app
Sources/VideoContextCore   Pipeline, storage, providers (shared library)
Sources/VideoContextMCP    Read-only MCP server
Tests/                     Swift Testing suites
scripts/                   Build, test, and smoke scripts
```

## License

[MIT](LICENSE)
