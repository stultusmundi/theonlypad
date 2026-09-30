# TheOnlyPad

An independent, offline text and code editor for macOS, built with Swift and AppKit.

**Status: incomplete development build. The full application brief is not yet implemented or verified.** There is no published release. Do not rely on this build as the only copy of irreplaceable work.

The current native app supports multiple editor windows and reorderable/pinnable tabs; new/open/save/save-as-to-new-path/save-all/duplicate/revert; native undo; line transforms; a command palette; literal/escaped/ICU-regex find and replace; lexical language colors; JSON formatting; searchable appearance/editor settings; encoding and line-ending conversion; macro recording and library management; a filtered folder file list; and private scratch recovery. It also includes explicit external commands, declarative text-transform extensions, conversion/checksum tools, bounded folder search, Unicode line/column navigation, and a native Print panel. Files above 100 MB open in a read-only byte-window viewer, with bounded literal UTF-8 search, up to 1 GB. This is not full large-file editing.

Document ownership in development source now lives at process scope, with one paired session/recovery publisher. Managed startup, queued external opens, close/reopen, interrupted close repair and lost-window recovery have native integration coverage. A frozen integrated run passed 404 core tests and 71 hidden managed-document tests, including AppDelegate callbacks. These results do not establish visible Finder delivery, physical input, packaged relaunch or full feature completeness. See [managed AppDelegate evidence](docs/verification/managed-appdelegate.md).

File → Move Document to Window moves the selected editable document and its undo history into an existing or new editor window. Hidden native tests cover scratch/file moves, stale destinations, window capacity, interrupted window recovery and subsequent disk-change monitoring. Independent document groups and visible desktop validation remain outstanding. See the [move guide](docs/document-moves.md) and [integration evidence](docs/verification/native-document-transfer-integration.md).

Local regular files now have bounded background change checks and a nonmodal conflict notice. Explicit Reload revalidates disk bytes after confirmation; Open Disk Copy creates an untitled buffer, and Keep Buffer preserves save-conflict protection. Explicit Locate validates the last saved bytes before changing a missing file’s path while retaining buffer edits. Hidden native tests cover these actions and uncertain-save cancellation; packaged desktop interaction remains outstanding. See [file-monitoring evidence](docs/verification/external-file-monitoring.md).

The View menu can show two views of one document, side by side or top and bottom, with shared text/undo and independent carets and scrolling. Adding a split is currently limited to 2 million UTF-16 units. Versioned session metadata now retains both pane selections, scroll coordinates, axis and preferred pane. Native restoration/save/undo tests pass. Settings/focus corrections are integrated. The current packaged app passes shared-pane Unicode editing, undo/redo, both split orientations, collapse, saving and two-pane session restoration. Exact independent selection/scroll restoration across both orientations still needs current-package validation; large-file safeguards and performance remain incomplete. Scroll coordinates are best effort when geometry or settings change. See the [pane evidence](docs/verification/persisted-pane-presentation.md).

Keyboard Shortcuts, also linked from Settings, now provides searchable draft assignments, recording, collision explanations, import/export and explicit save recovery. Menus, palette and help share the effective registry; standard native edit/Close bindings remain protected. Core and hidden native tests cover the integration. The current packaged app passes actual recording/customization/persistence/reset and modifier-held menu tests. Alternate layouts, direct accessibility activation and broader shortcut workflows remain unverified. See the [shortcut guide](docs/keyboard-shortcuts.md) and [evidence](docs/verification/keyboard-shortcuts.md).

Core tests and in-process AppKit harnesses cover portions of these features, including force-termination recovery. New source also includes advanced line commands, language-aware comments, bookmarks, lexical symbol outlines, document statistics, inert Markdown preview, and bounded side-by-side comparison. Six packaged XCUITests passed an earlier build for native open/edit/save/quit/reopen, scratch recovery, failed-quit edit preservation, undo/tab/appearance, multiwindow pinned-session restoration and Recent Files persistence. The current package passes five selected desktop workflows: open/edit/save/quit/reopen, graceful scratch restoration, shortcut customization/persistence/reset, modifier-held menu activation and shared-pane editing/restoration. Fresh integrated source passes765 automated tests; separate worker verification passes77, including four actual macOS pipe checks. Additional external-file desktop outcomes and a retained intermittent event-synthesis timeout are documented in the same desktop record. See the [September30 packaged desktop record](docs/verification/packaged-desktop-2026-09-30.md) for exact source and limits. UI automation works; a separate direct Accessibility API control remains unverified because the sandboxed XCTest runner is not a supported host. An earlier intermittent selection failure remains documented. Broader desktop workflows, physical IME and VoiceOver remain unverified. Test counts do not establish full feature acceptance. See the [requirements matrix](docs/requirements-matrix.md), [verification records](docs/verification/), and [continuation checkpoint](docs/continuation.md).

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain/Xcode. Development has been tested with Swift 6.3.3 on Apple Silicon macOS 26.6.2. Intel and the minimum OS runtime have not been tested. No third-party Swift packages are currently used; SwiftPM has no external resolution lockfile to produce.

```sh
scripts/swift.sh build
scripts/swift.sh test
scripts/test-native-integration.sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
scripts/package.sh --ad-hoc-sign
scripts/test-desktop-ui.sh
open dist/TheOnlyPad.app
```

For file and position arguments, see the [CLI guide](docs/cli.md). The repository-local launcher requires Python 3. See [extension API](docs/extensions.md) for its limited declarative capability model.

Packaging produces `dist/TheOnlyPad.app`, an architecture-named ZIP, and a development SBOM. Ad-hoc signing does not confer a Developer ID or notarization. Nothing in these commands publishes remotely or accesses signing credentials. The command-line build wrapper keeps compiler caches local; a restricted agent environment may require permission to run the toolchain outside its filesystem sandbox.

## Current limits

- Saved splits above the current size limit remain deferred in one pane, with explicit restore/discard actions; real desktop restart acceptance remains outstanding. Transfers between independent document groups and of streaming views, linked scrolling, persisted workspaces/hierarchical folder tree, full advanced editing, folder replacement previews, and many language tools remain outstanding. Periodic checkpoints capture recovery text and window/tab metadata, with a final checkpoint on normal quit; original-file autosave remains unimplemented. Edits replacing multiple separated regions still need better bookmark mapping. Physical tab dragging and complete encoding workflows still need desktop verification.
- Macro recording/replay and management are integrated. External commands, declarative extensions, printing and the repository-local CLI have partial automated coverage. Packaged CLI delivery, print-dialog workflows, localization and full accessibility remain unverified or outstanding.
- Save As refuses a different existing destination. Saving an opened file checks its original bytes; changed original bytes are backed up before replacement, and backups restore into new scratch tabs. Metadata preservation and races with uncooperative external writers still need work. Backup capacity or integrity failures stop saves until resolved through File → Saved File Backups. Development source now keeps unconfirmed post-rename saves dirty: Save validates the attempted file before retrying; Save As chooses a new path. See [save verification](docs/verification/save-publication.md) for evidence and remaining package/crash checks.
- Lexical colors are limited to documents of at most 2 million UTF-16 units. They are not complete grammars or semantic intelligence. JSON formatting preserves number/string/key lexemes and rejects excessive output.
- Regex uses ICU with cooperative cancellation, not process-isolated execution. Search and capture/output limits return explicit errors. Current language capabilities are listed in the [language guide](docs/languages.md). Full regex dialect details are in [search verification](docs/verification/search.md).
- Recovery restores unsaved files as scratch documents; historical paths are not automatically overwritten. Normal quit also records window/tab state. Missing session files remain in File → Unresolved Session Tabs for Retry, Locate or explicit removal; failed persistence refuses quit and preserves editing. Startup restoration has bounded capacity, so excess records remain unresolved. Window close asks about discarding changes, while app quit snapshots scratch/dirty documents.
- There is no updater, telemetry, account system, or cloud dependency.

## Project and licensing

Read [BUILD_PROMPT.md](docs/BUILD_PROMPT.md), [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md). The complete brief remains the scope; an initial working build is not completion.

Original code and geometric icon artwork are [MIT licensed](LICENSE). See [third-party notices](docs/third-party-notices.md). Apple frameworks are supplied by macOS. No Notepad++ code, branding or assets are copied; the [official manual](https://github.com/notepad-plus-plus/npp-usermanual) is a behavioral reference. TheOnlyPad is not affiliated with Notepad++ or Apple and does not support Windows plugin binaries.
