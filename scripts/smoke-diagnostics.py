#!/usr/bin/env python3
"""Real stdio processes, disposable library, no model/provider calls."""
import concurrent.futures
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import uuid

spec = importlib.util.spec_from_file_location("mcp_smoke", Path(__file__).with_name("smoke-mcp.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def policy(root, expires):
    root.mkdir(mode=0o700, exist_ok=True)
    value = {"captureID": str(uuid.uuid4()), "startedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(), "expiresAt": expires.isoformat()}
    temporary = root / "settings.tmp"
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o600)
    temporary.replace(root / "settings.json")
    return value["captureID"]


def connect(executable, library):
    process = subprocess.Popen([str(executable), "--library", str(library)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    smoke.send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "PRIVATE_CLIENT_NAME", "version": "1"}}})
    assert "result" in smoke.receive(process)
    smoke.send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    return process


def main():
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "dist/Video Context.app/Contents/MacOS/video-context-mcp"
    with tempfile.TemporaryDirectory(prefix="vc-diagnostics-mcp-") as directory:
        library = Path(directory)
        smoke.create_fixture_library(library)
        video_id, task_id = "vid_" + str(uuid.uuid4()), "task_" + str(uuid.uuid4())
        db = sqlite3.connect(library / "library.sqlite")
        row = list(db.execute("SELECT * FROM videos WHERE id='vid_alpha'").fetchone())
        row[0] = video_id
        db.execute("INSERT INTO videos VALUES(" + ",".join("?" for _ in row) + ")", row)
        doc = json.loads(db.execute("SELECT document FROM video_tasks WHERE id='task_alpha'").fetchone()[0])
        doc["id"], doc["videoID"] = task_id, video_id
        db.execute("INSERT INTO video_tasks VALUES(?,?,?,?)", (task_id, video_id, 0, json.dumps(doc).encode()))
        # No screenshot reference substitutions: the original fixture tools cover their frame ownership separately.
        db.commit()
        before = hashlib.sha256("\n".join(db.iterdump()).encode()).hexdigest()
        processes = [connect(executable, library), connect(executable, library)]
        diagnostics = library / "diagnostics"
        try:
            result = smoke.call_tool(processes[0], 2, "get_video_task", {"video_id": video_id, "task_id": task_id, "expected_revision": 2})
            assert not result.get("isError")
            assert not diagnostics.exists(), "Logging must be off by default"
            capture = policy(diagnostics, dt.datetime.now(dt.timezone.utc).replace(microsecond=0) + dt.timedelta(hours=24))
            def calls(process):
                for index in range(15):
                    response = smoke.call_tool(process, 10 + index, "get_video_task", {"video_id": video_id, "task_id": task_id, "expected_revision": 2})
                    assert not response.get("isError")
                mismatch = smoke.call_tool(process, 40, "get_video_task", {"video_id": video_id, "task_id": task_id, "expected_revision": 999})
                assert mismatch["isError"]
                invalid = smoke.call_tool(process, 41, "get_video_brief", {"video_id": "PRIVATE_SECRET_SK_TOKEN"})
                assert invalid["isError"]
                frame = smoke.call_tool(process, 42, "get_video_frame", {"video_id": "vid_alpha", "timestamp_seconds": 0.5})
                assert any(item["type"] == "image" for item in frame["content"])
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(calls, processes))
            lines = (diagnostics / "logs/events.jsonl").read_text()
            events = [json.loads(line) for line in lines.splitlines()]
            assert len({event["sessionID"] for event in events}) == 2
            assert {event["captureID"].lower() for event in events} == {capture.lower()}
            assert sum(event["entry"]["event"] == "toolFinished" for event in events) == 36
            assert any(event["entry"].get("error", {}).get("category") == "revisionConflict" for event in events)
            assert any(event["entry"]["context"].get("taskID") == task_id for event in events)
            assert "PRIVATE_SECRET" not in lines and "PRIVATE_CLIENT_NAME" not in lines and "Only alpha" not in lines
            (diagnostics / "settings.json").unlink()
            smoke.call_tool(processes[0], 50, "get_video_task", {"video_id": video_id, "task_id": task_id})
            assert (diagnostics / "logs/events.jsonl").read_text() == lines
            policy(diagnostics, dt.datetime.now(dt.timezone.utc).replace(microsecond=0) - dt.timedelta(seconds=1))
            smoke.call_tool(processes[1], 51, "get_video_task", {"video_id": video_id, "task_id": task_id})
            assert (diagnostics / "logs/events.jsonl").read_text() == lines
            assert hashlib.sha256("\n".join(db.iterdump()).encode()).hexdigest() == before
            print(f"Diagnostics MCP passed: two live processes, {len(events)} events, dynamic enable/stop/expiry, scoped text/images, privacy, unchanged database.")
        finally:
            db.close()
            for process in processes:
                process.stdin.close()
                try:
                    assert process.wait(timeout=5) == 0
                    assert process.stdout.read() == "", "Non-protocol data on stdout"
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
