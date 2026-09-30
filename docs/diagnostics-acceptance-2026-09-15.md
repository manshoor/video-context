# Diagnostics acceptance — 15 September 2026

Delivered locally in Video Context 1.0.0, build 5. Capture remains off for the normal library. No paid inference, model downloads, or user-recording reprocessing was performed.

## Verified

- `./scripts/test.sh`: 125 tests passed across 27 suites. The existing opt-in live inference tests remain skipped in the normal suite. New coverage includes default-off behavior, dynamic capture/expiry, concurrent writers, rotation, retention, partial/corrupt logs, lock contention, storage failure and recovery, 30-second progress throttling, HTTP/error privacy, scoped export, crash summaries/raw opt-in, export cancellation, mid-import capture, failed review, task-provider failure, and existing checkpoint recovery.
- `python3 scripts/smoke-mcp.py`: all eight existing retrieval tools, exact-recording isolation, task revisions, text/images, and clean disconnect passed against the bundled executable.
- `python3 scripts/smoke-diagnostics.py`: two already-running MCP processes produced 76 valid events after capture was enabled. Stop and expiry took effect without reconnecting. Request content and fixture text stayed out of logs; the disposable database remained unchanged.
- `./scripts/check-app.sh`: signature, plist, icon, arm64 app/MCP executables, and the AVPlayerLayer playback compatibility check passed.
- Native UI: inspected the light minimum-size workspace, a larger dark workspace, and Settings. Verified the active-capture indicator, 24-hour expiry display, enable/stop controls, Context ID/time-range defaults, unchecked full-report option and privacy notice, native save dialog, and successful export with capture on and off. Controls expose accessible names through the macOS accessibility tree.
- Final native ZIP contains exactly six intended files plus the enclosing directory. No raw `.ips` files or macOS resource-fork/extended-attribute sidecars were included. The two existing crash reports were represented as safe summaries; no omissions were reported. Full-report inclusion was tested only with synthetic reports.
- The original library's logical SHA-256 remained `18038325297d9359bed00afacff627bcbeb2b3cf24f739b108dd7f05825a8b17` before and after the native checks. Demo capture was stopped and demo apps were closed.

## Build identification

- App UUID: `21270E8B-CC91-32BC-B63E-5C226668A700`.
- MCP UUID: `377195F4-B585-381E-839C-4835CF8E0544`.
- Signing remains local ad hoc signing, as in previous builds; this is not a notarized public release.

## Limits

Expiry and long retention intervals were exercised using an injected clock, not a 24-hour wait. Disk errors and contention were induced using disposable test paths. Logging cannot reconstruct earlier processing events, and crashes may leave an incomplete final log line. App-wide crashes cannot reliably be assigned to one Context ID.

Accessibility labels and native keyboard/save behavior were inspected; a full spoken VoiceOver session was not performed. Existing long-recording/model-quality acceptance gaps and full Claude/Cursor agent conversations remain separate from this diagnostics change.
