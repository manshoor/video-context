# Saved-key recovery — build 9

The user reported repeated API-key entry and could not find the additional providers.

## Observed

The running app was build 8 from `dist/Video Context.app`. Its video-analysis dropdown contained OpenAI, LM Studio, Claude, and DeepSeek. The OpenAI credential existed in Keychain. The main window initially reported that no key was loaded; opening Settings subsequently loaded the key. The user confirmed they did not paste or re-enter it.

A noninteractive diagnostic returned success for the saved item's metadata and data lookup, both with and without an authentication context. It printed only status codes and result-presence booleans. No key was displayed, exported, or transmitted. The earlier underlying Keychain response was not captured, so its system-level cause remains unproven.

## Changes

- Retry a temporary missing result once after 350 ms, only for noninteractive lookups.
- Retry unavailable selected-provider credentials when the app becomes active again, including after Mac unlock. Ready credentials and user edits are preserved.
- Prevent duplicate OpenAI background loads and clear finished load-task references.
- Add **Load saved key** for the missing OpenAI state, preserving explicit edits and the existing **Unlock API key** action for permission failures.
- Do not show processing-credential warnings on completed, current recordings.
- Show all available analysis-provider names and the installed build number in Settings.

The fix does not change Keychain access controls, credential storage, signing identity, provider choices, or recording artifacts. macOS may still require permission to access a saved key; that is different from entering the API key again.

## Verification

A failing regression first demonstrated that one temporary missing result left the loader in `.missing`. It now passes with a second noninteractive lookup. App tests verify recovery after unlock without opening Settings, no reload of ready keys, and preservation of user edits. The full default test run passed: Swift Testing reported 120 core tests in 23 suites and 29 app tests in 10 suites (live acceptance suites retain their opt-in skips). No inference calls were made for this fix.

Build 9 was rebuilt and ad hoc signature verification and app compatibility checks passed. The MCP smoke test passed all eight tools. The normal app was closed before its executable was replaced, then reopened. Its process start time (20:14:33 local) followed the rebuilt executable timestamp (20:13:48). The reopened Settings reported “OpenAI API key is ready” without key entry by the agent. The user was actively navigating the app during the final check; their provider selection was not changed.
