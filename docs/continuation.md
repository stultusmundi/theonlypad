# Continuation checkpoint

The complete requested application is **not finished**. Local branch `build/native-editor`; no remote push/merge/release. Initial repository was clean. Full scope remains `BUILD_PROMPT.md` and `requirements-matrix.md`; do not reduce scope to this checkpoint.

## Implemented current baseline

SwiftPM macOS14+ AppKit/TextKit1 editor with strict encodings, conflict-checked atomic saves, private checksummed recovery, native undo, line transforms, bounded ICU search/replacement, generic lexical highlighting/token-preserving JSON formatting, settings migrations, macro recording/library/replay, tab pin/reorder/close controls, encoding/endings panel, line numbers, command palette, filtered workspace list, bounded1GB read-only viewer, explicit external commands, declarative extension catalog/sample/registry, UTF8 folder search, conversion/checksum tools, Unicode navigation/CLI protocol, native printing and Help.

This is partial implementation, not complete feature acceptance. Native TextKit1 is still provisional: multi-cursor/rectangular selection and full performance/IME/accessibility acceptance are unresolved.

## Fresh evidence

- `scripts/swift.sh test`:104 tests passed at2026-09-09 13:23 UTC.
- `scripts/test-native-integration.sh`: all retained harnesses passed after the unsaved-macro regression fix: document/undo/encoding/JSON/language/settings/conversions/navigation, recovery ordering/SIGKILL restart, search, large viewer, external run/cancel/quit drain, sample extensions, workspace, folder search, application URL routing/batch caret positions.
- `xcrun swift-format lint --strict --recursive Sources Tests Package.swift`: passed.
- `python3 scripts/check-public.py`: passed (limited public-source pattern checks, not exhaustive secret scanning).
- `python3 scripts/test-package-promotion.py`:6 tests passed, including failure rollback and retained recovery backups.
- `scripts/package.sh --ad-hoc-sign`: current app/ZIP/SBOM generated and validated. Locations: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. SBOM/binary/ZIP/Info.plist/signature consistency checked.
- Packaged LaunchServices accepted a new-instance URL and running-instance CLI request using isolated synthetic state; one process remained alive, then only that test-owned process was stopped. Packaged text/caret was not observed.
- Earlier1/10/100/1000MB streaming benchmarks: docs/verification/large-files.md. Not100MB edit or GUI latency acceptance.

## Current work / ownership

Root: preserve and locally commit the verified baseline, then continue full scope. Owns AppDelegate, EditorWindowController, registry and integrated scripts. No new feature should be claimed complete from the baseline test count.

engine_spike: independently reassessing mature editor alternatives (official Scintilla Cocoa and CodeMirror6) because stock NSTextView lacks verified advanced selections. Owns only `docs/superpowers/specs/editor-engine-reassessment.md` and ignored `.local` spikes; no engine adoption or runtime dependency authorized by evidence yet.

requirements: developing `LineCommands` in ignored `.local/line-commands-spike` with TDD before copying green sources/tests into the main tree. New module covers duplicate/delete/move/join/tabs-spaces with selection and line-ending semantics. Will notify root before copying. Do not duplicate work.

document_core: completed packaging promotion consistency fix/tests; idle. Reviewed public distribution and licensing: no external runtime packages, original MIT assets, system libraries only. Hosted CI not run.

## Exact next actions

1. Inspect agent messages; finish scoped baseline local commit after checking staged privacy and branch identity. Do not push or publish.
2. Evaluate editor reassessment evidence; maintain provisional architecture honestly. Do not build a bespoke text engine without testing suitable mature alternatives.
3. Integrate green LineCommands through shared registry and native undo/macro transaction, preserving logical trailing-empty-line behavior. Run relevant core/native checks.
4. Continue missing families: multiple/rectangular cursors, advanced navigation/bookmarks, panes/shared documents, persisted workspace tree, preview/diff/folding/completion/snippets/outline, folder replacement preview/backups, recent/drop/autosave/full session restoration, preferences/shortcuts/localization, accessibility/performance/fault/security and packaged acceptance. Outstanding requirements are not optional future work.
5. Keep matrix, plans, README, verification and this checkpoint current. Rebuild artifacts after later implementation changes.

## Review fixes and remaining limits

Resolved: exact normalization dirty state, create-only Save As protection, bounded regex output/captures, linear lexical scanning, JSON lexeme preservation, native search close cancellation, macro storage concurrency/replay/quit guards, command-window retention/shutdown launch race, stale extension revalidation, folder-root result invalidation/open containment checks, bounded save-conflict reads, unsaved macro Stop→Cancel→Start loss, and staged package promotion.

Unsaved macro commands now require explicit Save/Discard before replacement/window-close/quit; they are not crash-persisted. Save As at a different existing path is refused. Final external-writer rename races, metadata/backups, large-edit latency and many matrix requirements remain unresolved. External commands have local user permissions and cannot guarantee termination of independently spawned descendants. Extensions are declarative built-in transformations, not executable-code plugins. Folder search lacks multi-file replacement and complete ignore/hidden/recursion controls.

AXIsProcessTrusted was false; user asked for Accessibility access, no response recorded. Physical desktop keyboard/dialog/IME/VoiceOver, full packaged open-edit-save-quit-reopen and GUI performance remain unverified. Do not substitute in-process checks for them. Ad-hoc only, no DeveloperID/notarization; Intel/macOS14 runtime/clean-machine acceptance absent.

Private synthetic state/logs/caches/artifacts are ignored in `.local`, `.cache`, `.build`, `dist`. Preserve LICENSE and unrelated changes. Public evidence must not expose home paths or real documents.
