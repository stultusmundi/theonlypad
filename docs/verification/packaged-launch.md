# Packaged launch smoke — 2026-09-09

An ad-hoc signed ARM64 bundle at `dist/TheOnlyPad.app` was launched directly through its `Contents/MacOS/TheOnlyPad` executable with `THEONLYPAD_STATE_DIRECTORY` set to an ignored synthetic directory under `.local/`. The process remained running 27 seconds after launch, produced no stderr/stdout errors, and was then terminated using SIGTERM addressed to that exact process.

This verifies process startup from the packaged executable. It does not verify Finder registration, keyboard input, menus, dialogs, save/quit/reopen, visual appearance, accessibility, installation, or a clean external machine. The packaged open/edit/save/quit/reopen workflow remains outstanding. Signing is ad-hoc only; no Developer ID or notarization.

## Current protocol smoke — 2026-09-09

After rebuilding the app with CFBundleURLTypes, LaunchServices accepted a local-file protocol request for a newly launched packaged app with an isolated THEONLYPAD_STATE_DIRECTORY. The repository-local CLI then sent a second synthetic file/line/column request. Both commands returned success; the same single application process remained alive. The test stopped only its newly launched process with SIGTERM afterward. No existing application process was present at test start, and no real user documents were used.

This proves launch/request acceptance and single-instance behavior only. Text/caret state was not observed in the packaged process; full open/edit/save/quit/reopen, IME, VoiceOver and editable-buffer latency remain unverified. The separate native AppDelegate harness did observe exact Unicode caret positions and independent batch positions.
