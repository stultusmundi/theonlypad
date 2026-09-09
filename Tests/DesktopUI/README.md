# macOS desktop UI tests

Run from repository root after packaging:

```sh
scripts/package.sh
scripts/test-desktop-ui.sh
```

Or pass an existing local development bundle:

```sh
scripts/test-desktop-ui.sh path/to/TheOnlyPad.app
```

Requires full Xcode and an available macOS GUI login session. The script copies the app into a unique ignored `.local/desktop-ui/run.*` directory, then passes that exact URL through the shared scheme's `GUI_PROBE_APP_PATH` environment variable. Scheme macro expansion is intentionally tied to the test target. No installed app is selected by bundle identifier.

The Apple UI runner uses its sandbox temporary directory for synthetic documents and a fresh `THEONLYPAD_STATE_DIRECTORY`. It never loads real app preferences or recovery buffers. XCTest results, raw logs, local app copies and screenshots remain ignored. The script does not modify macOS privacy settings or approve system dialogs. Failed permissions should be reported, not bypassed.

Tests cover native file-open dialog, text editing, exact-byte save, Command-Q/relaunch/reopen and scratch recovery after Command-Q. They use actual XCUI events; no editor APIs or in-process test hooks replace these actions. Direct clicking of the Open menu item is avoided because the tested Xcode version raised a pointer-coordinate assertion; File menu visibility is checked and Command-O opens the native panel. Full UI feature coverage remains separate work.

For diagnostics, inspect the uniquely reported local result folder. Before sharing any logs or screenshots, remove private paths and unrelated desktop content. The retained tests contain only synthetic text. The default time limits bound a test to 90 seconds (maximum 120 seconds); framework teardown diagnostics may add time.

A focused additional test exercises Edit-menu Undo/Redo and their keyboard shortcuts, then checks document-tab undo isolation and preference appearance persistence/reset. Run it through Xcode's `-only-testing:GUIProbe/GUIProbe/testUndoRedoTabIsolationAndAppearanceReset` option when diagnosing that flow. Its validation result is recorded in `docs/verification/xcuitest-feasibility.md`; source presence alone is not a passing-test claim. Preferences assertions cover the selected control and saved setting, not screenshot color or contrast verification.

The expanded suite also covers session-write failure vetoing quit without losing editability, restoration of pinned tabs across two windows, and Recent Files open/clear/persistence. Recent Files is exposed as an accessibility Dialog; editor windows are selected through stable tab identifiers when focus can reorder them. Every fixture registers an XCTest teardown block so assertion failures still clean up the owned test app. Current results and unresolved intermittent failures are recorded in the verification report; the existence of six test methods is not a claim of full desktop acceptance.

`SharedPanesTests.swift` is registered for split acceptance: actual View-menu actions, both orientations and pane identities, independent caret/focus, shared exact Unicode edits and undo, collapse, saved bytes, and one logical session tab after restart. The expanded target compiled successfully with `xcodebuild build-for-testing`; these two tests have not executed. They require a newly packaged app. Current execution is blocked because macOS UI Automation requires user authentication; a build-only check is not desktop acceptance.
