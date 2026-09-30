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
