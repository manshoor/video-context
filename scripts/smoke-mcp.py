#!/usr/bin/env python3
import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path


def send(process: subprocess.Popen[str], message: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def receive(process: subprocess.Popen[str]) -> dict:
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("MCP process ended before returning a response")
    return json.loads(line)


def create_fixture_library(library: Path) -> None:
    videos = library / "videos"
    alpha_video = videos / "vid_alpha" / "video.mp4"
    beta_video = videos / "vid_beta" / "video.mp4"
    alpha_video.parent.mkdir(parents=True)
    beta_video.parent.mkdir(parents=True)
    ffmpeg = "/opt/homebrew/bin/ffmpeg"
    for destination, color in ((alpha_video, "red"), (beta_video, "blue")):
        subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", f"color=c={color}:s=64x64:d=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", str(destination),
            ],
            check=True,
        )

    connection = sqlite3.connect(library / "library.sqlite")
    connection.executescript("""
        CREATE TABLE videos (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            source_type TEXT NOT NULL,
            source_value TEXT NOT NULL,
            media_path TEXT NOT NULL,
            duration REAL NOT NULL,
            status TEXT NOT NULL,
            error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            transcript_revision INTEGER NOT NULL DEFAULT 0,
            evidence_revision INTEGER NOT NULL DEFAULT 0,
            brief_revision INTEGER NOT NULL DEFAULT 0,
            brief_source_transcript INTEGER NOT NULL DEFAULT 0,
            brief_source_evidence INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE transcript_segments (
            id TEXT PRIMARY KEY,
            video_id TEXT NOT NULL,
            start_time REAL NOT NULL,
            end_time REAL NOT NULL,
            original_text TEXT NOT NULL,
            corrected_text TEXT
        );
        CREATE TABLE evidence_items (
            id TEXT PRIMARY KEY,
            video_id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            image_path TEXT NOT NULL,
            ocr_text TEXT NOT NULL,
            origin TEXT NOT NULL
        );
        CREATE TABLE briefs (
            video_id TEXT PRIMARY KEY,
            markdown TEXT NOT NULL,
            is_user_edited INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE api_usage (
            id TEXT PRIMARY KEY,
            video_id TEXT NOT NULL,
            stage TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            total_tokens INTEGER,
            audio_seconds REAL,
            created_at REAL NOT NULL
        );
    """)
    video_values = (
        "Shared recording", "localFile", "fixture.mp4", 1.0, "ready",
        None, 0.0, 0.0, 0, 0, 0, 0, 0, 0.0,
    )
    connection.execute(
        "INSERT INTO videos VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("vid_alpha", *video_values[:3], "videos/vid_alpha/video.mp4", *video_values[3:]),
    )
    connection.execute(
        "INSERT INTO videos VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("vid_beta", *video_values[:3], "videos/vid_beta/video.mp4", *video_values[3:]),
    )
    connection.executescript("""
        CREATE TABLE video_tasks(id TEXT PRIMARY KEY, video_id TEXT NOT NULL, position INTEGER NOT NULL, document BLOB NOT NULL);
        CREATE TABLE task_proposals(id TEXT PRIMARY KEY, video_id TEXT NOT NULL, document BLOB NOT NULL);
    """)
    revisions = {"transcript": 0, "evidence": 0, "brief": 0, "briefSourceTranscript": 0, "briefSourceEvidence": 0}
    for suffix in ["alpha", "beta"]:
        frame = library / f"{suffix}.jpg"
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(videos / f"vid_{suffix}" / "video.mp4"), "-frames:v", "1", str(frame)], check=True)
        connection.execute("INSERT INTO evidence_items VALUES (?, ?, ?, ?, ?, ?)", (f"ev_{suffix}", f"vid_{suffix}", 0.5, frame.name, "Save", "manual"))
        annotation = {"id": f"annotation_{suffix}", "evidenceID": f"ev_{suffix}", "kind": "rectangle", "x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5, "text": f"Only {suffix}"}
        content = {"title": "Shared task title", "behavior": f"Only {suffix}", "requirements": [], "checks": [{"id": "check", "text": f"Verify {suffix}", "origin": "user", "sourceIDs": []}], "questions": [], "sourceIDs": [f"ev_{suffix}"], "annotations": [annotation]}
        document = {"id": f"task_{suffix}", "videoID": f"vid_{suffix}", "revision": 2, "sourceRevision": revisions, "content": content, "reviewedRevision": 2, "wasReviewed": True, "archived": False, "order": 0}
        connection.execute("INSERT INTO video_tasks VALUES (?, ?, ?, ?)", (f"task_{suffix}", f"vid_{suffix}", 0, json.dumps(document).encode()))
    connection.commit()
    connection.close()


def call_tool(process: subprocess.Popen[str], request_id: int, name: str, arguments: dict) -> dict:
    send(process, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })
    return receive(process)["result"]


project_root = Path(__file__).resolve().parent.parent
executable = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    project_root / "dist/Video Context.app/Contents/MacOS/video-context-mcp"
)

with tempfile.TemporaryDirectory(prefix="video-context-mcp-") as library_value:
    library = Path(library_value)
    create_fixture_library(library)
    process = subprocess.Popen(
        [str(executable), "--library", str(library)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        send(process, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                # Codex advertises object-valued optional extensions during thread startup.
                "capabilities": {"experimental": {"codex/auth-change": {}}, "elicitation": {"form": {}, "url": {}}},
                "clientInfo": {"name": "video-context-smoke", "version": "1.0"},
            },
        })
        initialized = receive(process)
        assert initialized["result"]["serverInfo"]["name"] == "video-context"

        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        listing = receive(process)
        names = [tool["name"] for tool in listing["result"]["tools"]]
        expected = [
            "list_video_tasks", "get_video_task", "get_task_frame",
            "list_videos",
            "get_video_brief",
            "search_video",
            "get_video_segment",
            "get_video_frame",
        ]
        assert names == expected, names
        assert all(tool["annotations"]["readOnlyHint"] for tool in listing["result"]["tools"])
        tools_by_name = {tool["name"]: tool for tool in listing["result"]["tools"]}
        for name in ["get_video_brief", "search_video", "get_video_segment", "get_video_frame"]:
            tool = tools_by_name[name]
            assert "Context ID" in tool["description"], tool["description"]
            context_id_description = tool["inputSchema"]["properties"]["video_id"]["description"]
            assert "exact match is required" in context_id_description, context_id_description

        task_list = call_tool(process, 20, "list_video_tasks", {"video_id": "vid_alpha"})
        assert task_list["structuredContent"]["tasks"][0]["id"] == "task_alpha"
        task_text = call_tool(process, 21, "get_video_task", {"video_id": "vid_alpha", "task_id": "task_alpha", "expected_revision": 2})
        assert task_text["structuredContent"]["canImplement"] is True
        assert "Only alpha" in json.dumps(task_text)
        assert "Only beta" not in json.dumps(task_text)
        for request_id, args in [(22, {"video_id": "vid_beta", "task_id": "task_alpha"}), (23, {"video_id": "vid_alpha", "task_id": "task_alpha", "expected_revision": 1}), (24, {"video_id": "vid_alpha", "task_id": "missing"})]:
            assert call_tool(process, request_id, "get_video_task", args)["isError"] is True
        task_frame = call_tool(process, 25, "get_task_frame", {"video_id": "vid_alpha", "task_id": "task_alpha", "evidence_id": "ev_alpha", "expected_revision": 2})
        assert task_frame.get("isError") is not True, task_frame
        assert len([item for item in task_frame["content"] if item["type"] == "image"]) == 1
        assert task_frame["structuredContent"]["annotations"][0]["text"] == "Only alpha"
        assert call_tool(process, 26, "get_task_frame", {"video_id": "vid_alpha", "task_id": "task_alpha", "evidence_id": "ev_beta"})["isError"] is True

        alpha = call_tool(process, 3, "get_video_frame", {"video_id": "vid_alpha", "timestamp_seconds": 0.5})
        beta = call_tool(process, 4, "get_video_frame", {"video_id": "vid_beta", "timestamp_seconds": 0.5})
        missing = call_tool(process, 5, "get_video_frame", {"video_id": "vid_missing", "timestamp_seconds": 0.5})
        alpha_image = next(item["data"] for item in alpha["content"] if item["type"] == "image")
        beta_image = next(item["data"] for item in beta["content"] if item["type"] == "image")

        assert alpha["structuredContent"]["videoID"] == "vid_alpha"
        assert beta["structuredContent"]["videoID"] == "vid_beta"
        assert alpha_image != beta_image
        assert missing["isError"] is True
        assert "Recording not found: vid_missing" in missing["content"][0]["text"]
        process.stdin.close()
        assert process.wait(timeout=5) == 0, "MCP must exit when its client closes stdin"
        print("MCP Context ID tools, exact-video retrieval, and clean disconnect passed:", ", ".join(names))
    finally:
        process.terminate()
        process.wait(timeout=5)
