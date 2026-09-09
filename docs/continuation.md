# Continuation checkpoint

TheOnlyPad is incomplete. The entire BUILD_PROMPT remains scope. Do not declare completion, publish remotely, or claim notarization, Intel/minimum-OS runtime, physical IME/VoiceOver or clean-machine acceptance.

## Repository and environment

- Branch `build/native-editor`. Latest local checkpoint `e8b8275` follows `5f8121c`, `0b92dfe`, `b79f231`, `49943b5`, `3c70180` and `60eaaf7`; no push/merge/release. Save-publication and checkpoint integration are committed locally; shared-pane ownership work is now starting. Preserve all changes.
- AppKit/TextKit1 native editor plus Foundation/CryptoKit/Darwin PadCore; no external runtime packages. macOS14 minimum, Swift6.3.3 in Swift5 mode. Tested Apple M4 Pro/48GiB/macOS26.6.2 only. Engine choice remains provisional.
- Native XCUITest previously worked despite AXIsProcessTrusted=false; its current authentication blocker is recorded below. No system privacy/security settings changed. Raw logs/fixtures/engine spikes remain ignored. Avoid sharing unsanitized xcresults or accessibility trees (system menus can contain unrelated data).

## Package state

Current local `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip` and SBOM were regenerated24772 with checkpoint wiring and pre-signing debug-map removal. Executable SHA256 `ed55142031206a0048a0ac806e979baf62c3ab7505801a77e95252608b8777fb`. Ad-hoc only; no Developer ID/notarization/publication. New check-package.py verifies six bundle files match ZIP bytes, final SBOM executable hash, safe archive paths and specified ASCII machine-path markers before promotion. Six promotion tests and public-pattern checks passed. Intermediate82132 package899d19 contained128 volume-path debug-map markers; observed check failure, confirmed strip -S removes them, and corrected packaging before final promotion. This narrow check is not a general secret scanner or packaged runtime proof.

Desktop automation is blocked. The prior save-publication packagea2d3e80 was attempted by suite9427 (`.local/desktop-ui/run.ACcFbH`), retry4478 and clean-DerivedData77546; all failed before tests enabling automation. Read-only automationmodetool says Automation Mode disabled and user authentication required. User was asked asynchronously to approve the native Enable UI Automation prompt; no response yet. No security preference or credential was changed. Do not retry XCUITest until access is confirmed. Historical desktop passes below do not apply to the latest package.

Historical preceding binary SHA256 was `0324726fcc89fbb0b54670efe713f7246ba23572ef4ae7e48c1a0f2e77a73526`.

Six real packaged desktop tests passed, zero failures,298.439seconds, xcodebuild exit0, ignored `.local/desktop-ui/run.WdUWEz/results.xcresult`. They cover open/edit/save/restart, scratch recovery, failed quit preserving edits, undo/tab/appearance, multiwindow pinned sessions, and Recent Files persistence. The preceding six-test run passed four and failed two: Recent used a Window query for a real Dialog, now corrected; one Command-A replacement appended, cause still unexplained. Focused two-test rerun and the final full run passed on the identical binary. Added selection17-unit and exact replacement assertions; preserved failed results. See `docs/verification/xcuitest-feasibility.md`.

Bundle inventory six files, archive eleven entries without unsafe paths; archive executable and SBOM hashes match; narrow strings home/volume marker scan found0. This is limited privacy/artifact review, not full security acceptance. The historical binary predates save-publication and checkpoint fixes; current package details above supersede earlier artifact state.

## Current save-publication integration

Reviewed plan `docs/superpowers/plans/2026-09-09-save-publication-uncertainty.md`; results `docs/verification/save-publication.md`.

- AtomicFileStore now throws publicationUncertain with opaque parent/published-file evidence after rename if sync/path validation fails. Bounded exact readback validates identity and bytes but is not an acknowledgement; retry needs a fresh successful save. Parent identity is checked pre/post; create-only exclusive rename is tested with a new file inserted after the final check.
- Core15 DocumentFileStoreTests passed. Partial-write/file-sync/directory-sync, parent rename/retarget, exact/inode/symlink readback and postrename failure coverage added without weakening existing tests.
- Editor retains pending bytes/evidence separately from saved baseline, keeps uncertain buffers dirty/recoverable, does not adopt uncertain Save As URL, validates before retry, refuses external changes, retains original backup and clears pending only after acknowledged save or explicit successful reload.
- Native SaveFailureHarness passed including undo, backup refusal, changed text after uncertainty, return to old saved text still recovered, initially untitled Save As, and failure lifecycle. Independent review found two actual regressions; separate red runs showed late alerts after close and saves admitted after a closed destination chooser. Both guarded and green. Harness registered in native script.
- Full core199 passed8.809seconds and full native integration57438 passed on this first save integration, including process-kill recovery. Subsequent recovery/preferences propagation fixes were covered by final run78405 below.
- PreferencesController now accepts injected save/store for real-store tests. Uncertain save reads back valid disk values, displays/applies those with explicit unconfirmed status; unreadable readback disables editing and offers existing Import/Reset. Prepublication error still says unchanged. Native PreferencesFailureHarness observed UIold/disknew red, then passed uncertainty, fresh retry, prewrite failure and unreadable readback. Registered in native script.
- Engine agent implemented RecoveryCoordinator quota/revision propagation: old cache could remain10 units after uncertain80-unit publication, allowing B50 over cap100; older revision could overwrite uncertain newer bytes. New narrow RecoveryStore save(fault:)/canonical validatePublication seams; actor reserves attempted revision, invalidates capacity and validates/reinventories before admission. Runtime old-revision and stalequota reds observed; expanded RecoveryHarness and15file-store+5bounds tests passed. Independent review foundno remainingmaterialissue; final fullcore/native78405 passed. Package15647 and local commit b79f231 followed; that package awaits desktop acceptance because of the authentication blocker.

## Ownership and exact next work

- Task1 shared document ownership is committed locally as5f8121c. Full core199/native50290 passed, including both process-kill recovery tests; final formatting/public/diff checks13037 passed. Current distribution remains the earlier checkpoint package ed551420; no extraction/visible-pane packaged runtime claim.
- Root copied the green reviewed host into EditorPaneHost.swift and its harness, registered in native script; production-copy compilation/formatting is pending. No visible split controls or focused-pane routing are exposed yet.
- Engine owns ignored .local/shared-pane-routing implementation, with copies of controller/model/view/pane. Actual runtime composition red showed another pane mutating provisional marked text. Implement stable focus/context, all-pane interactivity and composition exclusions; do not change production before targeted green/review/copy handoff. Host API is present(panes:axis:) throws.
- Requirements owns exclusive build/benchmark slot now: controlled legacy-versus-single-encode100 MB×3 release benchmark with identical frozen5f8121c native sources. Both versions already passed the same25 compatibility/fault tests. Root reviewed the helper with no material issue; no production RecoveryStore change yet.
- Document_core completed ignored host and phase profiler; no active build. Host hidden tests pass axes/resizes/keyboard event handling/labels/focus/lifetime, not physical mouse/keyboard/VoiceOver. Phase profiler identified double JSON encoding as roughly96% of the sampled100 MB checkpoint cost; exact bytes verified.
- After benchmark handoff: record results, verify production host copy, then run routing candidate targeted tests when engine is ready. Keep shared build/GUI slots coordinated. Desktop automation still requires the user's authentication reply; no security setting or credential changes.

## Other completed investigations and remaining scope

CodeMirror remains ignored, not adopted. Default gate27/33 retained six Unicode/mixed-ending differences. Bounded tuned adapter passed192 state assertions and31 actual WK checks; cap1M UTF16/10k separators. All18 fresh performance children exited0: plain1/10/100MB exact undo/visible EOF passed, adapter1MB passed and10/100MB explicitly limited. Full timings/caveats in `docs/superpowers/specs/codemirror-feasibility.md`; roughly33ms includes two-frame observer floor, no native bridge/dirty/IME/memory claim. Initial stalled smoke retained. No GUI process remains from spike.

Current TextKit100MB same-length dirty edits still roughly415–421ms median after exact NSString comparator improvement;50ms target missed. Long-line native/Scintilla trials also missed targets. Native common-language lexical guide is `docs/languages.md`; semantic features remain outstanding. Help sizing regression fixed and native scroll tests passed. Recent Files at-quit MRU is integrated; >100MB recent opens still require successful byte-viewer completion support.

Periodic checkpoint application wiring is implemented and undergoing review/verification; shared-document panes remain planned. Still outstanding: optional autosave/external watching; shared panes/workspaces/advanced selections/overwrite/pairs; folder replace preview/recovery; folding/completion/snippets/custom languages; configurable shortcuts/localization/accessibility; complete performance/fault/security/parity acceptance. Requirements matrix is authoritative; passing tests do not close entire feature families.

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

Toolchain/native GUI commands can require approved unsandboxed execution. Do not overlap GUI harnesses or performance sampling with other builds/tests. Use explicit synthetic state. Keep all raw diagnostics ignored. No remote actions are authorized.

## Latest checkpoint-layer progress

Storage/scheduler21477, paired capture4034, application25597/80941 and fullcore/native21497 passed. Independent pending-close barrier and frozen metadata findings were fixed and re-reviewed. New native process-kill harness restored three acknowledged scratch tabs with exact Unicode/mixed-ending text, tab order/pin/selection and recent history; final strengthened assertion passed32417 and is registered in native script. Fullsuite21497 predates this final added harness; that harness was run separately. Package24772 contains production checkpoint changes; its runtime/packaged crash acceptance awaits authentication. Persistent atomic cross-file snapshots/durable close tombstones and optional autosave remain unimplemented. See docs/verification/periodic-session-checkpoints.md and checkpoint-performance.md for evidence and limits.

## Current shared-pane extraction handoff

Production Task1 extraction is uncommitted: new DocumentTextView.swift, EditorDocument.swift and EditorPane.swift; downstream controller still uses temporary first-pane accessors, with no visible split controls. Ownership harness passed shared exact undo/redo, one edit observer, separate recovery capture revision, max-two reuse, detached-origin undo and eventual native deallocation. Immediate weak-release failure was harness timing; same bounded run-loop drain passes with no cleanup changes. No isolated-deinit or new OS runtime requirement adopted. Hidden WindowCheckpoint passed after extraction. SharedHighlightHarness runtime second-view-color red72016 then green21565; storage-owned highlighter now colors all attached managers. Both new harnesses registered in native script.

One actual integration failure is unresolved: existing DirtyStateHarness line42 force-unwrap attachedSheet was nil during encoding conversion after earlier dirty assertions passed. Engine is rerunning and comparing checkpoint0b92dfe in ignored sources to distinguish regression from harness/environment. Engine owns that diagnostic build slot; root owns production integration. Do not declare full native suite green on extraction. Requirements has frozen-source review underway. Document_core prepared ignored .local/checkpoint-phase-profile; do not execute it concurrently with builds/GUI. After diagnosing sheet failure, complete focused checks and source review, run isolated profiling if slot permits, then full native integration before enabling split routing.

DirtyState diagnosis complete: sandboxed current and checkpoint0b92dfe binaries both failed because AppKit's service connection was blocked, with beginSheet returning no attached panel. The exact unchanged retained binary passed the full DirtyState harness under require_escalated; no application/test change was made. Task1 source review found no material issue. Document_core now owns the exclusive ignored phase-profiler build/run slot; root must wait for its handoff before full native checks. Engine is preparing only an ignored routing test/design candidate while waiting. No visible split UI is exposed.

Task1 full verification50290 completed: core199 passed8.567seconds and every native harness passed, including new shared ownership/highlighting, existing dirty/save/lifetime and both process-kill recovery cases. Source stayed frozen during verification. Prepare scoped local extraction commit after formatting/public/diff checks; current dist package remains checkpoint0b92dfe (ed551420…), not this extraction. Next execute Task2 routing/composition with engine owning controller/model/view/pane files; host candidate and recovery optimization remain ignored until separately tested/reviewed. Profiling completed with exact bytes; two JSON encodes account for roughly96% of the sampled100 MB checkpoint time (see checkpoint-performance.md).

Recovery optimization adopted after exact legacy/candidate compatibility25+25 tests and controlled release comparison.100 MB publication median4.195→2.226seconds; maxRSS increased1,349,566,464→1,381,367,808bytes, no memory improvement claimed. Full production core65954 passed204 tests8.598seconds. Root now runs51449 production host + ApplicationCheckpoint harnesses; engine routing remains ignored source-only while this slot runs. New RecoveryEnvelopeCompatibilityTests preserves exact legacy wire bytes/limits/fault semantics. Current package remains ed551420 and does not contain this optimization or ownership/host changes.

Current handoff: recovery optimization committed as e8b8275; production host and application checkpoint harnesses51449 passed. Host component/harness/script are ready for a local component commit, without visible controls. Engine owns compile/native slot for ignored routing compatibility tests; first routing/composition/quit harness green, independent review underway by requirements. No production controller routing copy yet. Root holds native source edits while compatibility tests run.
