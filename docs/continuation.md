# Continuation checkpoint

TheOnlyPad is incomplete. The entire BUILD_PROMPT remains scope. No final completion, remote publication, Developer ID signing, notarization, Intel runtime or minimum-macOS runtime claim is supported by this checkpoint.

## Current state

- Branch `build/native-editor`; latest local checkpoint commit `3c70180` follows `60eaaf7`. Later Recent Files, CSS, dirty-comparison, Help, desktop tests and records are uncommitted task work. Preserve all changes. No remote push, merge or release occurred.
- Native AppKit/TextKit 1 editor plus PadCore; macOS14 minimum, Swift6 toolchain in Swift5 language mode. Tested host: Apple M4 Pro,48GiB, macOS26.6.2, Swift6.3.3. No third-party runtime package dependencies. Engine choice remains provisional.
- Production includes session startup/quit, bounded unresolved repair, recovery-safe Retry, explicit Locate/removal, MRU Recent Files, independent document undo, bookmarks/gutter, outline, line/comment commands, statistics, inert Markdown preview, bounded file comparison and original-byte backups, alongside earlier search/encoding/macros/extensions/external-command/settings/workspace/printing features. These are partial feature families; the requirements matrix remains authoritative.

## Latest changes and verification

- Recent Files uses the existing editor loader, including selecting an already-open dirty buffer after its file was deleted. Open/reload callbacks complete once on success/error/cancel; stale and closed requests cannot append hidden tabs. Explicit encoding-open completion reselects its captured document. Native regressions observed that race red before the fix.
- Recent controls expose real accessibility identifiers. Quit freezes history actions and cancels pending recent opens; all veto branches restore interaction. Independent source review confirmed the previous quit/history race and success-status issue are addressed. See `docs/verification/recent-files-review.md`.
- Dirty cache misses now use exact `storage.mutableString.isEqual(to: savedText)`, retaining length/cache/observer/unfinished-batch and encoding/BOM checks. Additional native fixtures cover NUL, mixed endings, bidi controls and emoji. Eighteen isolated actual-controller trials demonstrated an improvement, but100MB same-length edits still take roughly415–421ms median. See `docs/verification/text-comparison.md`; the50ms target is not met.
- CSS URL slashes no longer start line comments. The new regression failed before the fix; all9 language tests and then all192 core tests passed. `docs/languages.md` documents the actual lexical subset and missing semantic features.
- Help window collapsed during content installation. Two sizing lines fix it; the retained full-registry HelpHarness checks initial viewport, start/end scrolling, resizing and exact text. Other inspected panels did not reproduce the earlier maxSize defect. See `docs/verification/scroll-extent-variants.md`.
- Full core192 passed at15:53:20 (session31109). Full native integration21675 passed after all production fixes, including DirtyState, Help, RecentFiles, RecentFilesEditor, session, lifetime, scroll, and process-kill/restart recovery checks. Strict formatting/public/diff checks69724 passed on the frozen integration source.

## Artifact and desktop evidence

Fresh local packaging22834 passed:

- `dist/TheOnlyPad.app`
- `dist/TheOnlyPad-0.1.0-dev-arm64.zip`
- `dist/TheOnlyPad.sbom.json`
- Executable SHA256: `0324726fcc89fbb0b54670efe713f7246ba23572ef4ae7e48c1a0f2e77a73526`

Ad-hoc only; no Developer ID/notarization. The full six-test packaged desktop suite completed with four passes and two failures in ignored `.local/desktop-ui/run.5qsntP/results.xcresult` (session55627). Recent Files was queried as a window despite its actual Dialog role; query corrected. Open/edit/save once appended instead of replacing selected text; cause remains unresolved. Focused rerun4391 passed both tests (115.960seconds, `.local/desktop-ui/run.3Q960E`). Full suite51753 passed all six tests/zero failures,298.439seconds (`.local/desktop-ui/run.WdUWEz`), including visible-selection and replacement-text assertions. The earlier intermittent selection failure remains unexplained. An earlier compile attempt54783 failed for the table row query and was corrected. It includes original open/save/restart, scratch recovery, quit failure/veto, tab undo/preferences, multiwindow pinned-session restoration and new Recent Files open/clear/persistence coverage. Do not report it passed until the process completes.

Historical package `4654c5fc0744d6b4e094c2f7cd35b3257656866db91f34eab3ca15cc01fe18cf` passed four original desktop tests and the new focused multiwindow test (one test/zero failures,39.700s, ignored `.local/desktop-ui/run.gDhAX0/results.xcresult`). That focused test verifies two windows, three exact buffers, stable IDs, pin/order/selection and native Window-menu focus. Earlier diagnostic failures were harness problems: missing-descendant queries, index-bound windows changing on focus, and failed-test cleanup bypassing Swift defer. Tests now bind windows through persistent descendant tab IDs and register XCTest teardown blocks. All original assertions were retained. Failed synthetic app PIDs were stopped specifically; no unrelated apps were terminated.

`AXIsProcessTrusted=false` does not block this working XCUITest harness. No system permission/security setting was changed. Physical IME/VoiceOver, broader desktop coverage, display scaling, Intel/minimum-OS runtime and clean-machine installation remain unverified.

## Active ownership

- Root owns current frozen integration, completed full desktop51753, packaging/evidence and local checkpoint. Next: inspect six-test result, diagnose failures without weakening assertions, review artifact/public inventory and update records. Then make a scoped local commit and continue full scope.
- `document_core` owns **only ignored** `.local/session-checkpoints` Task1 work: RecoveryCoordinator capture/receipt/publication candidate and SessionCheckpointStoreHarness. Production copies are not authorized during this freeze. It may compile isolated non-GUI tests alongside desktop work. Plan: `docs/superpowers/plans/2026-09-09-periodic-session-checkpoints.md`. Capture revisions are issuance order, not edit revisions; explicit receipts and serialized publication are necessary. Exact atomic cross-file snapshots and durable-close guarantees remain outstanding and require a separate journal protocol.
- `requirements` owns ignored CodeMirror/WK performance gate and `docs/superpowers/specs/codemirror-feasibility.md`. Initial smoke stalled and the main-loop watchdog did not exit; owned process stopped. Independent35s process timeout plus explicit activation produced one passing1MB plain smoke (five exact/visibility assertions; single preliminary timings only). **Full 18-run measurement matrix completed successfully**, with plain1/10/100MB visible edit/undo and exact checks; bounded adapter passed1MB and explicitly rejected10/100MB. See its report for frame-floor and native-integration limitations. No current owned GUI/process.
- `engine_spike` completed Help, independent Recent review and corrected Task1 checkpoint re-review with no remaining material finding. No active GUI/process. `document_core` is now implementing an isolated Task2 scheduler candidate and deterministic harness; production integration remains pending.

## Engine investigations

CodeMirror remains an ignored spike, not a production dependency. Locked13 npm packages were license-reviewed as MIT with obligations recorded locally. Default gate27/33 exposed grapheme backspace and mixed-EOL mismatches. Tuned adapter then passed192 state assertions and31 actual WK checks: exact mixed CRLF/CR/LF serialization with four logical lines, paste/delete/undo/redo and whole-grapheme deletion. Adapter caps1M UTF-16 units/10k separators; physical IME, accessibility, integration, crash recovery and large-file performance remain unverified. CSP blocking requires an actual enforced violation event; no network success is claimed.

Scintilla and TextKit long-line experiments remain diagnostic. Corrected TextKit10MB single-line p95 roughly764–1570ms; displayed Scintilla roughly257–263ms with readiness339–370ms. Both miss50ms; default Scintilla ZWJ behavior remains unsuitable. Shared TextKit panes have an ignored feasibility spike and reviewed ownership design, not production implementation.

## Proven commands and coordination

```sh
scripts/swift.sh build
scripts/swift.sh test
scripts/test-native-integration.sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
python3 scripts/test-package-promotion.py
scripts/package.sh --ad-hoc-sign
scripts/test-desktop-ui.sh
open dist/TheOnlyPad.app
```

Toolchain/native UI commands can require approved unsandboxed execution. Keep raw logs/results, synthetic state and engine dependencies ignored. Never expose credentials/private files. Do not run GUI harnesses together or overlap retained performance measurements with builds/tests. Source edits must respect active compile ownership. No remote actions are authorized.

After this checkpoint, outstanding work still includes periodic session metadata, optional autosave and external-change watching; complete shared panes/workspaces and advanced selections/overwrite/pairs; folder replacement previews/backup recovery; folding/completion/snippets/custom languages; shortcuts/localization/accessibility; remaining performance, fault, security and full parity acceptance. Recent large-file opens still need byte-viewer successful-load completion. All applicable requirements remain in scope; none is removed to declare completion.

## Next implementation priorities

Bounded save review found ignored post-rename directory fsync errors and missing parent-path identity revalidation. Reviewed plan: `docs/superpowers/plans/2026-09-09-save-publication-uncertainty.md`. Engine agent owns AtomicFileStore/core tests and the shared SwiftPM build slot; root owns subsequent native pending-publication/retry/recovery state and native harness. Current package predates these fixes. Candidate checkpoint scheduler has a concurrent-final drain-window review finding; document_core is adding a deterministic regression/fix in the ignored candidate. Pane plan is written but unimplemented. No GUI harness currently runs; do not overlap new GUI work without coordination.
