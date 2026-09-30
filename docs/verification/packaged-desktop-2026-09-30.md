# Packaged desktop validation — 2026-09-30

The user requested actual computer-use testing. Root reserved exclusive GUI execution and used the actual macOS XCTest UI runner against an isolated copy of the packaged application. No browser preview substitutes for native behavior. Test state and documents are synthetic; raw diagnostics remain ignored.

## Source and package

Source commit: `f4d9207dd78813853bd4e1f9312db9fa1d73a223`. The retained archive inventory contains661 tracked files and was checked before the desktop run. Frozen source, full-suite receipts, package receipts and desktop evidence are under `.local/integrated-search-20260930/`.

- Fresh integrated SwiftPM suite:650 tests,0 failures;16.020s test execution. This is correctness evidence, not input-latency acceptance.
- Release package build succeeded; ad-hoc signature and archive/SBOM checks passed.
- Executable SHA256: `5556069aad3d15fb0178137394587afa2c8b4188818414a52f2f99a6cabae3fb`.
- macOS26.6.2, ARM64, Swift6.3.3, macOS14 deployment target. No Intel runtime validation, DeveloperID signing or notarization claimed.

## Desktop run

All five selected real XCUITests passed, with0 failures and0 skips. The XCTest result bundle independently reports5/5, and xcodebuild exited0. Test execution total261.019s; these workflow durations include automation waits and are not app performance measurements.

| Workflow | Result | XCTest duration |
| --- | --- | --- |
| Custom shortcut, relaunch persistence and reset | Passed |75.617s |
| Native open/edit/save/quit/relaunch/reopen | Passed |60.408s |
| Option-held File/New creates exactly one tab | Passed |28.065s |
| Scratch content restored after graceful Command-Q | Passed |30.637s |
| Shared-pane Unicode editing, undo, orientation, collapse, save and restoration | Passed |66.291s |

The exact command is retained in `desktop/command.json`; source tests come from the same frozen archive. Parallel testing is disabled and individual timeouts are enabled. Final inspection found0 remaining editor instances. All661 source hashes and the tested executable were checked again after execution.

The tested app, ZIP and SBOM were promoted to local `dist/` using the checked promotion script and revalidated. The previous package is preserved under ignored `previous-dist/` in the evidence directory. Nothing was published. Launch with `open dist/TheOnlyPad.app`.

The first sandboxed result-summary extraction was refused because xcresulttool writes a report cache; the approved outside-sandbox invocation succeeded without rerunning tests. Raw results remain private because they include machine identifiers and paths.

The separately identified AXPress client and physical IME/VoiceOver acceptance remain outside this pass. Existing intermittent Locate failures and large Unicode paragraph latency remain unresolved; no product-completion claim follows from these tests.

## Assertion boundaries reviewed independently

The file test explicitly reopens the path after relaunch; it does not prove automatic file-session restoration. Scratch restoration uses graceful Command-Q, not force termination. Shortcut override persistence crosses a relaunch; reset-to-default is checked in the same session, without a second restart. Option-held menu activation asserts exactly one new tab and a one-second stability interval; it is not standalone AXPress or physical keyboard evidence.

The shared-pane test checks Unicode content in both editors, menu and keyboard undo/redo, pane identity and geometry across both split orientations, focus movement and independent carets, collapse, exact saved bytes, one persisted logical tab and two editors after relaunch. These are representative workflows, not exhaustive accessibility, IME, transfer, performance or parity acceptance.

## Reproduction

Build and validate a package with `scripts/package.sh --ad-hoc-sign`. `scripts/test-desktop-ui.sh` runs the broader checked-in desktop suite against a private copy; it is not equivalent to this five-test selection. To reproduce this selection, use `xcodebuild test -project Tests/DesktopUI/GUIProbe.xcodeproj -scheme GUIProbe -destination 'platform=macOS'`, an ignored derived-data/result-bundle directory, `-parallel-testing-enabled NO`, test timeouts enabled, and `GUI_PROBE_APP_PATH` pointing to an absolute isolated packaged app path. Add these filters:

```text
-only-testing:GUIProbe/GUIProbe/testOpenEditSaveQuitRelaunch
-only-testing:GUIProbe/GUIProbe/testScratchRecoveryAfterCommandQuit
-only-testing:GUIProbe/GUIProbe/testCustomShortcutRecordingPersistenceAndRestoreDefaults
-only-testing:GUIProbe/GUIProbe/testOptionHeldFileNewMenuClickAddsExactlyOneTab
-only-testing:GUIProbe/SharedPanesTests/testSharedEditsUndoOrientationCollapseSaveAndRestart
```

Reserve exclusive GUI ownership and check for existing editor instances first. Do not terminate a user-owned editor. The retained exact command includes the private app path and is intentionally not published verbatim.

## Additional file-conflict workflows

A separate actual XCUITest run against the same verified package selected two existing external-file tests. Final xcresult reports1 passed,1 failed,0 skipped; xcodebuild exits65. The clean external-file workflow passes: the changed file produces a notice without replacing the buffer, explicit reload adopts the new bytes, and quit/relaunch preserves that content. The dirty-reload/cancel/disk-copy workflow fails while XCTest types the synthetic path in the native Open dialog, before its conflict assertions; it also exceeds its120-second test allowance. That workflow is not accepted by this run.

The retained hierarchy shows the native Go To sheet and its focused path field. The app's sampled main thread is waiting in the native modal event loop. These observations narrow the failure location but do not establish its cause or justify a product fix. An unchanged isolated retry and comparison are the next diagnostic step; do not hide this failure if a retry passes.

Raw results, activities, system-generated diagnostics and attachments remain private under ignored `.local/desktop-external-20260930/`; they must not be published wholesale. The final result summary, copied executable hash and zero-editor-instance postflight were verified. An early attempt to read the result before xcodebuild finished failed; only the finalized xcresult supplies these counts. No system privacy, signal, input-source or display setting was changed.

An unchanged isolated retry subsequently passed the dirty-buffer workflow (1 test,0 failures/skips,65.310 seconds; xcodebuild0). It reused the same verified copied app and existing test binary via `test-without-building`, with fresh synthetic state. Cancel preserved the unsaved buffer; opening a disk copy retained both the disk bytes and original dirty text. The finalized result, unchanged executable hash and zero-editor-instance postflight were verified. The original timeout remains an unresolved intermittent event-delivery failure, not a fixed defect or an all-green full-suite result. Retry evidence is retained under the same ignored directory's `retry/` child.

## Regex replacement workflow

A new actual XCUITest against the same packaged executable passed: one test, zero failures and zero skips,65.274 seconds. The finalized xcresult, complete owned-watchdog receipt, six frozen desktop-source inputs, unchanged app hash and zero-editor postflight were independently verified. Evidence remains private under `.local/desktop-search-20260930/popup-click/`, including `root-verification.json`.

The test opens a synthetic Unicode file containing emoji, a decomposed combining sequence and an uppercase control. It selects ICU regex mode and match case, replaces `(alpha)` with `$1!`, verifies two-match navigation status, cancels the first confirmation and checks unchanged editor/disk bytes, confirms the second replacement and checks unsaved content, closes the panel, verifies one-step undo and redo, then saves and compares exact UTF-8 bytes. This establishes that specific document Replace All workflow; it does not test incremental find, actual selection ranges, replace-one, folder replacement or isolated regex cancellation.

Two earlier runs remain failures. The first used a Window selector, while the retained actual hierarchy exposes Find and Replace as a Dialog; the selector was corrected without removing assertions. The second timed out during native popup keyboard handling/value query. A private exact-owned-app sample showed the ordinary AppKit event loop, but the underlying XCTest timeout cause is unresolved. That timeout left the isolated app running; exact-bundle termination and a zero-editor check completed cleanup. The successful diagnostic selected the visible regex menu item by click rather than End/Return. No production application change, privacy change or broad keyboard-reliability claim follows.

Reproduce the focused workflow with the existing desktop project and `-only-testing:GUIProbe/GUIProbe/testRegexReplaceConfirmationUndoAndSave`, following the isolated-app and exclusive-GUI rules above. Keep raw result attachments private.
