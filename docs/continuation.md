# Continuation checkpoint

The application is incomplete. The entire BUILD_PROMPT remains scope; no final completion, remote publication, Developer ID signing, notarization, Intel runtime or minimum-macOS runtime claim is authorized by this checkpoint.

## Latest checkpoint — supersedes the older detail below

- Integrated session startup/quit, recovery-safe Retry, explicit Locate/removal, tab AX IDs and scroll extent fixes are now in production source. Full native suite43842 passed. Full core190 passed at15:24:32 (19093). Strict formatting/public/diff checks and six packaging rollback tests passed.
- Package30417 succeeded, ad-hoc only. Current executable SHA256 `4654c5fc0744d6b4e094c2f7cd35b3257656866db91f34eab3ca15cc01fe18cf`. Actual desktop suite95125 passed all4tests/0failures181.300s: open/edit/save/quit/reopen; scratch recovery; session-directory obstruction→quit veto→continued editing→repair→quit/recovery; menu/shortcut Undo/Redo, stable tab identity and separate histories, appearance persistence/reset. Raw ignored results `.local/desktop-ui/run.3Oy70j/results.xcresult`.
- Root is preparing a scoped local checkpoint commit. No current root tool process. No remote action. The entire build brief remains incomplete.
- `document_core` now owns ONLY isolated Recent Files work under `.local/recent-files` (proposed AppDelegate/SessionCoordinator changes plus new native panel/tests). Root must add the normal-open callback API after checkpoint: optional `onFailure`, optional `shouldAccept`, `onOpened` remains last for trailing closures; callback completion exactly once across failures/cancel/closed window; `onOpenedURL` fires only after successful user open, never restoration. Reuse existing-buffer fast path and actual editor loader. Recents persisted in existing SessionStore atquit; metadata debounce still separate/outstanding. Do not copy while root builds.
- `requirements` finished literal-comparison investigation (ignored; no productionchange; 361 semantics pass,10MB~97→43ms ASCII, still not100MB acceptance), then CodeMirror WKWebView firstgate. Actual gate33checks/27pass: multicaret+undo, rectangle syntheticDOMdrag, Unicode cursorleft, JSON safety, syntheticcomposition pass; default/strict backspace and mixedEOL semantics differ from required behavior. NativeNSTextView baseline deletes whole tested graphemes. Tighter CSP event assertion rerun pending; report in `docs/superpowers/specs/codemirror-feasibility.md`. No adoption. Dependency artifacts stayignored,13exactMIT npm packages/notices inspected. Coordinate any GUIrun.
- `engine_spike` finished longline comparison, no activeprobe. `docs/verification/long-lines.md`: correctedTextKit p95~764–1570ms; displayedScintilla~257–263ms, readiness~339–370ms, allvisibility/exacttext checks pass. KnownScintillaZWJbehavior unresolved. Timingsdiagnostic; briefconcurrentcompile, notfinalperformanceacceptance. No newengineadopted.
- Next: finishcheckpoint; implement/test open completion API and integrate RecentFiles; then debounced session metadata/content ordering, engine-adapter decisions, panes and remaining fullscope. Existing package and fourGUItests establish a development checkpoint, not product completion.

## Current implementation and verification

- Branch: `build/native-editor`. Local baseline commit `60eaaf7`; extensive later work remains uncommitted. Preserve all current changes. No remote push/merge/release occurred.
- Native AppKit/TextKit1 editor and PadCore services; macOS14 minimum, Swift6 toolchain in Swift5 language mode. ARM64 macOS26.6.2 / M4Pro /48GiB machine verified. No third-party runtime packages.
- Added line commands/comments, document statistics, inert Markdown preview, bounded comparison, private original-byte backups/manager, bounded recovery quotas and global quit batching, bookmarks/gutter, lexical outline, exact changed-span application, session metadata/merge/view-state cores and unresolved-file panel. README/matrix remain partial; many feature families are outstanding.
- Bookmark metadata now respects provisional composition, nested unmarkText, ordinary typing coalescence and responder Undo/Redo. Real field-editor Undo isolation passes. Physical IME remains unverified. Multi-region anchor preservation remains incomplete.
- Dirty state caches exact UTF16 comparison and invalidates on synchronous NSTextStorage character edits; length changes avoid a full comparison. Direct assignment, unfinished batches, normalization, encoding/BOM, save baseline and native undo/marked-text regressions pass. Same-length first comparison remains expensive.
- Independent review found four strong document captures in undo closures retaining closed editors. Weak captures fixed them; retained actual controller/window/editor lifecycle tests pass. Reverting only those captures reproduces the leak. See `docs/verification/merged-dirty-bookmark-review.md`.
- Session view-state initially rejected valid legacy/recovery text above100MB UTF8. Native validation now uses100M UTF16 units and reports invalid bookmarks rather than guessing them. Exact33.3MB Windows1252/recovery regression passes. See `docs/verification/session-restoration-review.md`.
- **Full core190 tests passed**, tool timestamp2026-09-09 15:02:55, session81232 exit0. **Full native suite53303 passed**, including all prior harnesses plus dirty state, six lifetime cases, session window import/capture, unresolved-record panel and SIGKILL recovery. Strict Swift formatting, public-source pattern check, diff check and six package-promotion rollback tests passed immediately before the latest small insertion-index change.
- Root added optional `insertionIndex:Int?=nil` to `restoreSessionTab` and native test assertions after53303; full Swift build/core pass but those new native assertions await the next native run. No root tool process currently running at this checkpoint.

## Real packaged UI evidence

`dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, and SBOM were regenerated with ad-hoc signing after bookmark/cache fixes. Executable SHA256 `ac27f8ac5a5d2b7e846c7a0cb4463b62ad18ffa5f49a362531b5281368d1000d` passed two actual XCUITests: native Open dialog, real typed edit, Command-S exact saved bytes, Command-Q/relaunch/reopen; and separate scratch recovery after quit/relaunch. Two tests, zero failures,92.040s. Current source has later session/lifetime changes not in that package.

Use `scripts/test-desktop-ui.sh` after packaging. It copies the exact supplied app to ignored `.local/desktop-ui`, uses a real Xcode runner with isolated synthetic state, and retains raw results privately. **Host AXIsProcessTrusted=false is not a blanket XCTest blocker.** No permission/security settings changed. Physical IME/VoiceOver, full UI matrix, clean-machine install and all display/platform tests remain outstanding.

## Active ownership and exact next actions

1. `document_core` owns isolated AppDelegate session orchestration plus new SessionCoordinator, SessionIntegrationHarness, additive SessionRestorationController/Harness updates and minimal AppCommands session-repair command. Read `docs/superpowers/specs/session-restoration.md` and `docs/superpowers/plans/2026-09-09-native-session-integration.md`. Agent coordinator tests cover ordered successful tabs, retained missing paths, scratch recovery, persisted unresolved order, corrupt-write blocking, injected quit failure and canceled startup. App wiring in progress, not yet copied. Agent must notify before copying existing AppDelegate during builds.
   - Startup loads metadata and claims recovery once; restored windows are separate from user-created windows. Missing records remain repairable; corrupt/future metadata blocks writes.
   - Quit persists metadata after the existing all-window freeze/pending-close drain/global recovery batch. Failures veto quit.
   - Panel removal is becoming async so associated recovery cleanup succeeds before metadata removal. Explicit dialog must disclose discarded recovery data. Late UI cancellation must not undo a completed authorized coordinator removal.
   - Root-provided controller APIs: `init(id:UUID=UUID(),restoreStartup:Bool=true)`; false creates empty window and suppresses recovery claim. `sessionMetadata:SessionWindow`; `restoreSessionTab(_:decoded:originalBytes:url:viewState:insertionIndex:)throws`; `selectSessionTab(UUID?)`. Recovery imports always nil URL/bytes. `RestoredViewState.resolve` runs off-main. Root owns EditorWindowController/SessionWindowHarness; agent requests changes rather than overwriting them.
2. `requirements` owns an extra actual DesktopUI test for menu/shortcut Undo/Redo, independent tab histories and appearance/reset. Currently running against the frozen packaged hash above. No production edits. Review of session cores/panel found the now-fixed capacity issue, no second material issue.
3. `engine_spike` owns ignored long-line performance investigation and `docs/verification/long-lines.md`; no production edits. Coordinate actual GUI probes with requirements so focus-sensitive tests do not overlap. Existing measured report `docs/verification/native-editor-performance.md`: optimized100MB append11.89–13.93ms in isolated actual-controller runs, open~1.1s;10MB same-length first comparison86.83ms; pathological10MB longline open~5s/edit~1.1s. Targets have not been lowered.
4. Root: receive session app wiring, review/integrate and run fresh core/native suites (including insertion-index assertions), extend packaged session tests, fix material findings, refresh artifacts/docs, make a scoped local checkpoint commit. Continue full scope afterward. No routine user approval checkpoint needed.

## Proven commands

```sh
scripts/swift.sh build
scripts/swift.sh test
scripts/test-native-integration.sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
python3 scripts/test-package-promotion.py
scripts/package.sh --ad-hoc-sign
scripts/test-desktop-ui.sh
```

Toolchain, AppKit and formatter atomic writes may need approved unsandboxed execution in this restricted environment. Keep diagnostics/cache/synthetic state ignored; never expose credentials or personal files. Do not modify source while another agent compiles it. Native GUI harnesses and XCTest should not run concurrently.

After sessions, outstanding work still includes shared panes, advanced selections/overwrite/pairs, full folder replacement previews/backup recovery, folding/completion/snippets/custom languages, recent/drop/autosave/external-change watching, workspace persistence/tree, preferences/shortcut/localization completeness, accessibility, remaining performance/fault/security and full parity acceptance. Existing shared-view spike/design is in `docs/superpowers/specs/shared-editor-views.md`; it is not a production pane implementation.
