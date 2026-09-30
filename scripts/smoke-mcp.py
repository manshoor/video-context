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
            estimated_cost_usd REAL NOT NULL DEFAULT 0,
            project_id TEXT
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
        CREATE TABLE feedback_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT NOT NULL UNIQUE
        );
        CREATE TABLE project_document_sources (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            source_key TEXT NOT NULL,
            kind TEXT NOT NULL,
            current_revision INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(project_id, source_key)
        );
        CREATE INDEX project_document_sources_project ON project_document_sources(project_id, updated_at, id);
        CREATE TABLE project_document_source_revisions (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            content_hash TEXT NOT NULL,
            extraction_version TEXT NOT NULL,
            original_relative_path TEXT NOT NULL,
            status TEXT NOT NULL,
            document BLOB NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(source_id, revision)
        );
        CREATE INDEX project_document_source_revisions_hash ON project_document_source_revisions(project_id, content_hash);
        CREATE INDEX project_document_source_revisions_project ON project_document_source_revisions(project_id, source_id, revision);
        CREATE TABLE project_document_import_jobs (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            source_key TEXT NOT NULL,
            source_path TEXT NOT NULL,
            source_id TEXT,
            status TEXT NOT NULL,
            error TEXT,
            updated_at REAL NOT NULL
        );
        CREATE INDEX project_document_import_jobs_project ON project_document_import_jobs(project_id, status, updated_at, id);
        CREATE TABLE project_documentation (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            slug TEXT NOT NULL,
            title TEXT NOT NULL,
            current_revision INTEGER NOT NULL DEFAULT 0,
            reviewed_revision INTEGER,
            document BLOB NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(project_id, slug)
        );
        CREATE INDEX project_documentation_project ON project_documentation(project_id, updated_at, id);
        CREATE TABLE project_documentation_revisions (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            document BLOB NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(document_id, revision)
        );
        CREATE INDEX project_documentation_revisions_project ON project_documentation_revisions(project_id, document_id, revision);
        CREATE TABLE project_documentation_proposals (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            document_id TEXT NOT NULL,
            expected_revision INTEGER NOT NULL,
            state TEXT NOT NULL,
            stale INTEGER NOT NULL DEFAULT 0,
            document BLOB NOT NULL,
            diff BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX project_documentation_proposals_project ON project_documentation_proposals(project_id, state, updated_at, id);
        CREATE TABLE project_decisions (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            document BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX project_decisions_project ON project_decisions(project_id, updated_at, id);
        CREATE TABLE project_question_group_proposals (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            state TEXT NOT NULL,
            document BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX project_question_groups_project ON project_question_group_proposals(project_id, state, updated_at, id);
    """)
    connection.executemany(
        "INSERT INTO feedback_projects VALUES (?, ?, ?)",
        [("project_alpha", "Alpha checkout", "alpha-checkout"), ("project_beta", "Beta billing", "beta-billing")],
    )
    video_values = (
        "Shared recording", "localFile", "fixture.mp4", 1.0, "ready",
        None, 0.0, 0.0, 0, 0, 0, 0, 0, 0.0,
    )
    connection.execute(
        "INSERT INTO videos VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("vid_alpha", *video_values[:3], "videos/vid_alpha/video.mp4", *video_values[3:], "project_alpha"),
    )
    connection.execute(
        "INSERT INTO videos VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("vid_beta", *video_values[:3], "videos/vid_beta/video.mp4", *video_values[3:], "project_beta"),
    )
    connection.executescript("""
        CREATE TABLE video_tasks(id TEXT PRIMARY KEY, video_id TEXT NOT NULL, position INTEGER NOT NULL, document BLOB NOT NULL);
        CREATE TABLE task_proposals(id TEXT PRIMARY KEY, video_id TEXT NOT NULL, document BLOB NOT NULL);
        CREATE TABLE feedback_batches(id TEXT PRIMARY KEY, updated_at REAL NOT NULL, document BLOB NOT NULL);
        CREATE TABLE feedback_tasks(id TEXT PRIMARY KEY, batch_id TEXT NOT NULL, document BLOB NOT NULL);
        CREATE TABLE feedback_proposals(id TEXT PRIMARY KEY, batch_id TEXT NOT NULL, document BLOB NOT NULL);
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
    for suffix in ["alpha", "beta"]:
        source_id = f"fsrc_{suffix}"
        comment_id = f"fcom_{suffix}"
        batch_id = f"fb_{suffix}"
        source = {"id": source_id, "url": f"https://example.com/{suffix}.jpg", "kind": "image", "status": "ready", "localPath": f"{suffix}.jpg", "ocrText": f"Only {suffix}"}
        if suffix == "alpha":
            source.update({
                "url": "https://jam.dev/c/alpha",
                "kind": "jam",
                "localPath": None,
                "jam": {
                    "sourceURL": "https://jam.dev/c/alpha",
                    "recordingID": "alpha",
                    "state": "ready",
                    "importedAt": 0.0,
                    "items": [
                        {"id": "jam_transcript", "component": "transcript", "timestampMilliseconds": 1250, "text": "Only alpha Jam transcript", "toolName": "getVideoTranscript"},
                        {"id": "jam_frame", "component": "frame", "timestampMilliseconds": 1500, "localPath": "alpha.jpg", "mimeType": "image/jpeg", "toolName": "getFrames"},
                        {"id": "jam_request", "component": "failedRequests", "timestampMilliseconds": 1600, "text": "POST /pay -> 422", "toolName": "getNetworkRequests"},
                    ],
                    "availability": [
                        {"component": "transcript", "status": "available", "message": "Transcript imported."},
                        {"component": "consoleErrors", "status": "unavailable", "message": "No console errors returned."},
                    ],
                },
            })
        comment = {"id": comment_id, "text": f"Only {suffix} feedback", "reviewer": "qa", "sourceIDs": [source_id], "isShared": False}
        project_id = "project_alpha" if suffix == "alpha" else "project_beta"
        batch = {"id": batch_id, "videoID": f"vid_{suffix}", "projectID": project_id, "title": "Shared feedback title", "project": "Alpha checkout" if suffix == "alpha" else "Beta billing", "rawText": comment["text"], "revision": 1, "comments": [comment], "sources": [source], "createdAt": 0.0, "updatedAt": 0.0}
        connection.execute("INSERT INTO feedback_batches VALUES (?, ?, ?)", (batch_id, 0.0, json.dumps(batch).encode()))
        content = {"title": "Feedback task", "behavior": f"Only {suffix}", "requirements": [{"id": "requirement", "text": comment["text"], "origin": "feedback", "sourceIDs": [comment_id]}], "checks": [{"id": "check", "text": f"Verify {suffix}", "origin": "interpretation", "sourceIDs": [source_id]}], "questions": [], "sourceIDs": [source_id, comment_id], "annotations": []}
        task = {"id": f"ftask_{suffix}", "batchID": batch_id, "revision": 2, "sourceRevision": 1, "content": content, "approvedRevision": 2, "archived": False}
        connection.execute("INSERT INTO feedback_tasks VALUES (?, ?, ?)", (task["id"], batch_id, json.dumps(task).encode()))
    source_revision = {
        "id": "pdocsrc_alpha:r1", "sourceID": "pdocsrc_alpha", "projectID": "project_alpha", "revision": 1,
        "contentHash": "hash-alpha", "extractionVersion": "1", "originalRelativePath": "documents/project_alpha/pdocsrc_alpha/revision-1/requirements.md",
        "status": "ready", "units": [{"id": "unit_alpha", "ordinal": 0, "kind": "heading", "locator": {"kind": "heading", "value": "Checkout"}, "title": "Checkout", "text": "Only alpha documentation"}],
        "assets": [], "errors": [], "createdAt": 0.0,
    }
    connection.execute("INSERT INTO project_document_sources VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       ("pdocsrc_alpha", "project_alpha", "requirements.md", "requirements.md", "markdown", 1, 0.0, 0.0))
    connection.execute("INSERT INTO project_document_source_revisions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       ("pdocsrc_alpha:r1", "pdocsrc_alpha", "project_alpha", 1, "hash-alpha", "1", source_revision["originalRelativePath"], "ready", json.dumps(source_revision).encode(), 0.0))
    document = {"id": "pdoc_alpha", "projectID": "project_alpha", "title": "Alpha reference", "slug": "alpha-reference", "currentRevision": 1, "reviewedRevision": 1, "markdown": "# Alpha reference\n\nOnly alpha documentation", "sections": [], "sourceSignature": "source-alpha", "updatedAt": 0.0}
    revision = {"id": "pdoc_alpha:r1", "documentID": "pdoc_alpha", "projectID": "project_alpha", "revision": 1, "title": document["title"], "slug": document["slug"], "markdown": document["markdown"], "sections": [], "sourceSignature": document["sourceSignature"], "isManualEdit": False, "createdAt": 0.0}
    connection.execute("INSERT INTO project_documentation VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       ("pdoc_alpha", "project_alpha", document["slug"], document["title"], 1, 1, json.dumps(document).encode(), 0.0))
    connection.execute("INSERT INTO project_documentation_revisions VALUES (?, ?, ?, ?, ?, ?)",
                       ("pdoc_alpha:r1", "pdoc_alpha", "project_alpha", 1, json.dumps(revision).encode(), 0.0))
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


def main() -> None:
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
                "get_feedback_batch", "list_feedback_tasks", "get_feedback_task", "get_feedback_evidence", "get_feedback_jam_context",
                "list_projects", "get_project_context", "search_project", "get_project_document", "get_project_evidence",
                "list_video_tasks", "get_video_task", "get_task_frame",
                "list_videos",
                "get_video_brief",
                "search_video",
                "get_video_segment",
                "get_video_frame",
            ]
            assert names == expected, names
            assert all(tool["annotations"]["readOnlyHint"] for tool in listing["result"]["tools"])
            assert "submit_document_proposal" not in names
            tools_by_name = {tool["name"]: tool for tool in listing["result"]["tools"]}
            locator = tools_by_name["get_project_evidence"]["inputSchema"]["properties"]["locator"]
            assert locator["required"] == ["kind"]
            assert set(locator["properties"]) == {"kind", "page", "startLine", "endLine", "value"}
            assert "markdownLine" in locator["properties"]["kind"]["enum"]
            for name in ["get_video_brief", "search_video", "get_video_segment", "get_video_frame"]:
                tool = tools_by_name[name]
                assert "Context ID" in tool["description"], tool["description"]
                context_id_description = tool["inputSchema"]["properties"]["video_id"]["description"]
                assert "exact match is required" in context_id_description, context_id_description

            projects = call_tool(process, 6, "list_projects", {})
            assert {item["id"] for item in projects["structuredContent"]["projects"]} == {"project_alpha", "project_beta"}
            project_context = call_tool(process, 7, "get_project_context", {"project_id": "project_alpha", "limit": 100})
            assert project_context["structuredContent"]["projectID"] == "project_alpha"
            assert "vid_alpha" in json.dumps(project_context)
            assert "vid_beta" not in json.dumps(project_context)
            project_search = call_tool(process, 8, "search_project", {"project_id": "project_alpha", "query": "Only alpha", "limit": 100})
            assert project_search["structuredContent"]["hits"]
            assert all("beta" not in json.dumps(hit).lower() for hit in project_search["structuredContent"]["hits"])
            project_document = call_tool(process, 9, "get_project_document", {"project_id": "project_alpha", "document_id": "pdoc_alpha", "expected_revision": 1})
            assert project_document["structuredContent"]["documentID"] == "pdoc_alpha"
            document_evidence = call_tool(process, 10, "get_project_evidence", {
                "project_id": "project_alpha", "kind": "document", "source_id": "pdocsrc_alpha", "revision": 1,
                "locator": {"kind": "heading", "value": "Checkout"},
            })
            assert document_evidence["structuredContent"]["text"] == "Only alpha documentation"
            assert document_evidence["structuredContent"]["freshness"] == "current"
            cross_project = call_tool(process, 11, "get_project_evidence", {
                "project_id": "project_beta", "kind": "document", "source_id": "pdocsrc_alpha", "revision": 1,
                "locator": {"kind": "heading", "value": "Checkout"},
            })
            assert cross_project["isError"] is True

            reviewed_evidence = call_tool(process, 12, "get_project_evidence", {
                "project_id": "project_alpha", "kind": "reviewedDocumentation", "source_id": "pdoc_alpha", "revision": 1,
            })
            assert "Only alpha documentation" in reviewed_evidence["structuredContent"]["text"]
            assert reviewed_evidence["structuredContent"]["freshness"] == "current"
            assert call_tool(process, 13, "get_project_evidence", {
                "project_id": "project_beta", "kind": "reviewedDocumentation", "source_id": "pdoc_alpha", "revision": 1,
            })["isError"] is True
            assert call_tool(process, 14, "get_project_evidence", {
                "project_id": "project_alpha", "kind": "reviewedDocumentation", "source_id": "pdoc_alpha", "revision": 2,
            })["isError"] is True

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

            feedback = call_tool(process, 27, "get_feedback_batch", {"batch_id": "fb_alpha"})
            assert feedback["structuredContent"]["batchRevision"] == 1
            assert feedback["structuredContent"]["videoID"] == "vid_alpha"
            listed = call_tool(process, 28, "list_feedback_tasks", {"batch_id": "fb_alpha", "expected_batch_revision": 1})
            assert listed["structuredContent"]["tasks"][0]["id"] == "ftask_alpha"
            args = {"batch_id": "fb_alpha", "task_id": "ftask_alpha", "expected_batch_revision": 1, "expected_revision": 2}
            task = call_tool(process, 29, "get_feedback_task", args)
            assert "Only alpha feedback" in json.dumps(task)
            assert "Only beta feedback" not in json.dumps(task)
            evidence = call_tool(process, 30, "get_feedback_evidence", {**args, "source_id": "fsrc_alpha"})
            assert evidence["structuredContent"]["jam"]["state"] == "ready"
            jam = call_tool(process, 34, "get_feedback_jam_context", {**args, "source_id": "fsrc_alpha"})
            assert jam.get("isError") is not True, jam
            assert jam["structuredContent"]["sourceID"] == "fsrc_alpha"
            assert "Only alpha Jam transcript" in json.dumps(jam)
            assert "Only beta" not in json.dumps(jam)
            assert len([item for item in jam["content"] if item["type"] == "image"]) == 1
            comment = call_tool(process, 33, "get_feedback_evidence", {**args, "source_id": "fcom_alpha"})
            assert comment["structuredContent"]["text"] == "Only alpha feedback"
            assert call_tool(process, 31, "get_feedback_task", {**args, "batch_id": "fb_beta"})["isError"] is True
            assert call_tool(process, 32, "get_feedback_task", {**args, "expected_revision": 1})["isError"] is True

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
            proposal_process = subprocess.Popen(
                [str(executable), "--library", str(library), "--allow-document-proposals"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                send(proposal_process, {
                    "jsonrpc": "2.0", "id": 101, "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {"name": "video-context-smoke-proposals", "version": "1.0"},
                    },
                })
                assert receive(proposal_process)["result"]["serverInfo"]["name"] == "video-context"
                send(proposal_process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
                send(proposal_process, {"jsonrpc": "2.0", "id": 102, "method": "tools/list", "params": {}})
                proposal_listing = receive(proposal_process)
                proposal_tool = next(tool for tool in proposal_listing["result"]["tools"] if tool["name"] == "submit_document_proposal")
                assert proposal_tool["annotations"]["readOnlyHint"] is False
                assert proposal_tool["annotations"]["idempotentHint"] is True
                assert "path" not in json.dumps(proposal_tool["inputSchema"]).lower()
                proposal = {
                    "id": "provider-random-one", "projectID": "project_alpha", "documentID": "pdoc_alpha", "expectedDocumentRevision": 1,
                    "title": "Alpha reference", "slug": "alpha-reference", "markdown": "Provider wording is retained for review.",
                    "sections": [], "diff": {"addedSectionIDs": [], "changedSectionIDs": [], "removedSectionIDs": []},
                    "sourceSignature": "source-alpha", "evidence": [], "state": "pending", "isStale": False,
                    "createdAt": 111.0, "updatedAt": 222.0,
                }
                first_proposal = call_tool(proposal_process, 103, "submit_document_proposal", {
                    "project_id": "project_alpha", "document_id": "pdoc_alpha", "expected_revision": 1,
                    "request_id": "proposal-smoke-1", "proposal": proposal,
                })
                proposal["id"] = "provider-random-two"
                proposal["createdAt"] = 999.0
                proposal["updatedAt"] = 1_000.0
                repeated_proposal = call_tool(proposal_process, 104, "submit_document_proposal", {
                    "project_id": "project_alpha", "document_id": "pdoc_alpha", "expected_revision": 1,
                    "request_id": "proposal-smoke-1", "proposal": proposal,
                })
                assert first_proposal["structuredContent"] == repeated_proposal["structuredContent"]
                inbox = sqlite3.connect(library / "document-proposal-inbox.sqlite")
                assert inbox.execute("SELECT COUNT(*) FROM document_proposal_inbox").fetchone()[0] == 1
                assert sqlite3.connect(library / "library.sqlite").execute("SELECT current_revision FROM project_documentation WHERE id='pdoc_alpha'").fetchone()[0] == 1
                inbox.close()
                proposal_process.stdin.close()
                assert proposal_process.wait(timeout=5) == 0, "Opt-in MCP must exit when its client closes stdin"
            finally:
                proposal_process.terminate()
                proposal_process.wait(timeout=5)
            print("MCP project discovery, exact evidence, opt-in proposals, Context ID tools, and clean disconnect passed:", ", ".join(names))
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    main()
