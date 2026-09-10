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

`SharedPanesTests.swift` exercises actual View-menu actions, both orientations and pane identities, independent caret/focus, shared Unicode edits and undo, collapse, saved bytes, and one logical session tab after restart. Both workflows have executed successfully against the recorded earlier package after harness geometry corrections. Their results do not establish the separate persisted-origin remedy.

`PaneSessionTests.swift` exercises independent selections, axis, preferred focus, scratch identity, shared editing and undo across restarts. Both complete orientations passed against a private diagnostic candidate, but that candidate is not the distributed implementation. The production settings/focus/layout remedy and its clean packaged acceptance remain outstanding. Scroll assertions use native document coordinates, not a claim about visible top-line pixels. See `docs/verification/persisted-pane-presentation.md` and `docs/verification/pane-origin-layout-cost.md`.

External-file Reload/Copy, Locate, and shortcut tests also use real desktop actions. Current packaged shortcut customization/persistence/reset, Option-held File/New, and open/edit/save/quit/reopen passed against source9231fc3. Locate has an unresolved intermittent stale-context failure despite an unchanged isolated pass. See `docs/verification/keyboard-shortcuts.md` and `docs/continuation.md` for exact source/result records; do not infer a current full-suite pass.

Ordinary XCUITest automation works in the current authorized GUI session. The separate external AXPress experiment requires Accessibility trust for a native probe host; the sandboxed XCTest runner is unsuitable for that API. The native request was sent but no grant was observed. This does not prevent ordinary XCUITest. Do not modify privacy settings, automatically repeat prompts, or treat a skipped AX control as passing.

Root owns desktop execution: run only one GUI suite at a time and verify termination of its exact copied app before another launch. Shared bundle identifiers can otherwise cause LaunchServices to reuse an earlier test copy. Source reviews, screenshots, build-only checks and hidden AppKit tests are distinct evidence from real desktop execution.
