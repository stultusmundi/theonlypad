# Packaged desktop checkpoint — 2026-10-12

Source `f45f1e9` was packaged locally and tested with the actual macOS XCTest UI runner after the user explicitly confirmed that the desktop was unlocked. All five selected tests passed, with zero failures, expected failures or skips. Synthetic documents and isolated app state were used; raw logs, result attachments and machine identifiers remain ignored.

## Source and package

The matching public source snapshot previously passed 1,159 default SwiftPM tests and a warning-free app/helper build with warnings as errors. The 19 hidden native macro cases are a separate selection and are not added to that count. See [session codec verification](custom-language-session-codec.md) and [native macro verification](native-macro-recording.md).

The actual `scripts/package.sh --ad-hoc-sign` invocation succeeded. Release builds, helper/app ad-hoc signatures, strict package validation, archive, SBOM, path scanning and local promotion passed; the standalone package check also returned zero. The release build was not a warnings-as-errors build. The package is local, with no remote publishing, Developer ID signing or notarization.

| Artifact | SHA256 |
| --- | --- |
| App executable | `710d5d664610828388d6c01e41fe70304a601e958748db546e107ecf13a76673` |
| ARM64 ZIP | `051362566789177b35c03745f88e3d4f738a738ec10d0ac02d8cc9e397cfb40c` |
| SBOM | `e441052861cfc3982756731dd9919c1d28ca3375a197911890fba4f8569d33ae` |

Environment: ARM64 macOS 26.6.2, Swift 6.3.3 in Swift 5 language mode, with deployment target macOS 14. This is runtime evidence on the stated machine, not Intel or macOS 14 runtime verification.

## Actual desktop selection

| XCTest identifier | Verified workflow |
| --- | --- |
| `GUIProbe/GUIProbe/testOpenEditSaveQuitRelaunch` | Open, edit, save, quit, relaunch and explicitly reopen the file |
| `GUIProbe/GUIProbe/testScratchRecoveryAfterCommandQuit` | Scratch restoration after graceful Command-Q |
| `GUIProbe/GUIProbe/testCustomShortcutRecordingPersistenceAndRestoreDefaults` | Shortcut override survives relaunch; restore defaults in the same session |
| `GUIProbe/GUIProbe/testOptionHeldFileNewMenuClickAddsExactlyOneTab` | Option-held menu action adds exactly one tab |
| `GUIProbe/SharedPanesTests/testSharedEditsUndoOrientationCollapseSaveAndRestart` | Shared-pane Unicode editing, undo/redo, both orientations, collapse, exact save and restart |

The complete output records exactly five starts and passes. The primary XCResult reports total 5, passed 5, failed 0, skipped 0 and expected failures 0. The selected ARM64 destination is recorded independently of the build's multiple-destination warning. The AppIntents metadata-extraction warning contains “skipped”; it is not a skipped test.

The run used a fresh frozen copy of the packaged app and desktop client, preserving all 13 declared input files. Independent review checked their hashes, the actual runner/test bundle and complete owned-process receipt. The watchdog consumed its exact leader with natural exit zero and complete captures; its singleton/EPERM cleanup result has the narrower `exitedLeaderOnly` scope. A separate exact-path postflight found no remaining owned app or UI runner. Total supervised duration was 305.33944 seconds, including build/automation work; this is not a performance measurement.

An earlier attempt timed out during automation initialization with zero cases reached. That failure remains recorded. This unlocked retry is a separate run; no application fix or privacy setting change is inferred from it.

## Reproduction scope

`scripts/test-desktop-ui.sh` invokes the broader checked-in desktop suite; its default is not this five-test selection and was not established by this run. The verified selection used `xcodebuild test` with a frozen desktop project and private packaged app, scheme `GUIProbe`, destination `platform=macOS`, separate derived-data/result directories, parallel testing disabled, test timeouts enabled with 90-second default and 120-second maximum allowances, and `GUI_PROBE_APP_PATH` set to that copied app. The five identifiers above were passed as `-only-testing:` filters. The exact private command and artifacts are retained without publishing machine-specific paths.

Reserve exclusive GUI ownership and use an unlocked desktop with the existing user-owned UI Automation authorization. Preserve user-owned editor instances. Local package reproduction uses `scripts/package.sh --ad-hoc-sign`; validate its current identity/version artifact names with `scripts/check-package.py`. Raw UI evidence and synthetic state must remain ignored.

## Limits

This verifies five of the eighteen current desktop methods. The tested package includes the adopted public macro/session implementation but excludes the private native custom-language state, catalog owner and highlighter candidates. These workflows do not establish a physical macro recording/playback workflow, broader native custom-language propagation, manager/picker behavior or complete BUILD acceptance.

Direct AXPress, physical IME, VoiceOver, broader lifecycle/transfer, Intel/macOS 14 runtime, memory and typing latency remain separate. No release was published.
