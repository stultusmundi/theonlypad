# Continuation checkpoint

TheOnlyPad is incomplete. The entire BUILD_PROMPT remains scope. Do not declare completion, publish remotely, or claim notarization, Intel/minimum-OS runtime, physical IME/VoiceOver or clean-machine acceptance.

## Repository and environment

- Branch `build/native-editor`. Latest local checkpoint `49943b5` follows `3c70180` and `60eaaf7`; no push/merge/release. Later save-publication changes are uncommitted task work. Preserve all changes.
- AppKit/TextKit1 native editor plus Foundation/CryptoKit/Darwin PadCore; no external runtime packages. macOS14 minimum, Swift6.3.3 in Swift5 mode. Tested Apple M4 Pro/48GiB/macOS26.6.2 only. Engine choice remains provisional.
- Native XCUITest previously worked despite AXIsProcessTrusted=false; its current authentication blocker is recorded below. No system privacy/security settings changed. Raw logs/fixtures/engine spikes remain ignored. Avoid sharing unsanitized xcresults or accessibility trees (system menus can contain unrelated data).

## Package state

`dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json` were regenerated successfully (15647), ad-hoc signed, executable SHA256 `a2d3e80e2bef8ac9bba9402191a31ef8b2486128fbb01539e754d686a4834a9f`. Six-test desktop suite9427 failed before any test: runner timed out enabling automation (`.local/desktop-ui/run.ACcFbH`). No leftover owned runner/app was found. Fresh-copy retry4478 and clean-DerivedData retry77546 both failed before tests with the same timeout. Read-only `automationmodetool` reports Automation Mode disabled and user authentication required. User was asked asynchronously to approve the native Enable UI Automation prompt; no response yet. No security preference or credential was changed. Inventory/ZIP/SBOM hashes match, sixbundlefiles/elevenarchiveentries/no unsafe paths/zero home-volume markers.

Historical preceding binary SHA256 was `0324726fcc89fbb0b54670efe713f7246ba23572ef4ae7e48c1a0f2e77a73526`.

Six real packaged desktop tests passed, zero failures,298.439seconds, xcodebuild exit0, ignored `.local/desktop-ui/run.WdUWEz/results.xcresult`. They cover open/edit/save/restart, scratch recovery, failed quit preserving edits, undo/tab/appearance, multiwindow pinned sessions, and Recent Files persistence. The preceding six-test run passed four and failed two: Recent used a Window query for a real Dialog, now corrected; one Command-A replacement appended, cause still unexplained. Focused two-test rerun and the final full run passed on the identical binary. Added selection17-unit and exact replacement assertions; preserved failed results. See `docs/verification/xcuitest-feasibility.md`.

Bundle inventory six files, archive eleven entries without unsafe paths; archive executable and SBOM hashes match; narrow strings home/volume marker scan found0. This is limited privacy/artifact review, not full security acceptance. **The historical binary predates the save-publication fixes; the newly generated a2d3e80 package includes them and awaits desktop acceptance.**

## Current save-publication integration

Reviewed plan `docs/superpowers/plans/2026-09-09-save-publication-uncertainty.md`; results `docs/verification/save-publication.md`.

- AtomicFileStore now throws publicationUncertain with opaque parent/published-file evidence after rename if sync/path validation fails. Bounded exact readback validates identity and bytes but is not an acknowledgement; retry needs a fresh successful save. Parent identity is checked pre/post; create-only exclusive rename is tested with a new file inserted after the final check.
- Core15 DocumentFileStoreTests passed. Partial-write/file-sync/directory-sync, parent rename/retarget, exact/inode/symlink readback and postrename failure coverage added without weakening existing tests.
- Editor retains pending bytes/evidence separately from saved baseline, keeps uncertain buffers dirty/recoverable, does not adopt uncertain Save As URL, validates before retry, refuses external changes, retains original backup and clears pending only after acknowledged save or explicit successful reload.
- Native SaveFailureHarness passed including undo, backup refusal, changed text after uncertainty, return to old saved text still recovered, initially untitled Save As, and failure lifecycle. Independent review found two actual regressions; separate red runs showed late alerts after close and saves admitted after a closed destination chooser. Both guarded and green. Harness registered in native script.
- Full core199 passed8.809seconds and full native integration57438 passed on this first save integration, including process-kill recovery. **Subsequent recovery/preferences propagation fixes below require another full run.**
- PreferencesController now accepts injected save/store for real-store tests. Uncertain save reads back valid disk values, displays/applies those with explicit unconfirmed status; unreadable readback disables editing and offers existing Import/Reset. Prepublication error still says unchanged. Native PreferencesFailureHarness observed UIold/disknew red, then passed uncertainty, fresh retry, prewrite failure and unreadable readback. Registered in native script.
- Engine agent implemented RecoveryCoordinator quota/revision propagation: old cache could remain10 units after uncertain80-unit publication, allowing B50 over cap100; older revision could overwrite uncertain newer bytes. New narrow RecoveryStore save(fault:)/canonical validatePublication seams; actor reserves attempted revision, invalidates capacity and validates/reinventories before admission. Runtime old-revision and stalequota reds observed; expanded RecoveryHarness and15file-store+5bounds tests passed. Independent review foundno remainingmaterialissue; final fullcore/native78405 passed. Newpackage/desktopacceptancepending. Do not package or commit this integration until resolved.

## Ownership and exact next work

- Root owns EditorWindowController, PreferencesController, their new harnesses, native script, integration/docs/package. Full final core/native78405 passed (199core,8.577seconds and allnative); package15647 passed and desktop9427/4478/77546 failed before tests; user authentication is now the recorded desktop blocker. Preferences28346 passed. Next: collect engine recovery green, review it independently, rerun core/native after sources freeze, regenerate package, rerun packaged desktop and artifact checks; then scoped local commit. Full scope continues afterward.
- `engine_spike` owns production RecoveryCoordinator/RecoveryHarness plus narrow RecoveryStore seams; its focused verification passed and the shared build slot is now root78405. No GUI. Coordinate module rebuilds before linking native harnesses.
- `document_core` owns ignored `.local/session-checkpoints` only. Task1 capture/receipt candidate passed real-store + legacy recovery harness and independent review after exact live-tab coverage and uncertain session readback fixes. Task2 scheduler passed initial deterministic harness but concurrent-final drain-window review found a race. Fix latches whole final operation before first suspension. An isFinalizing invariant red was observed; original duplicate itself did not reproduce in chosen executor ordering. A stronger behavioral red was then observed: resume while final callers waited behindW caused an extra publication in the old implementation. Fixed harness passes exact one-final count/identical receipts. Agent is rebasing the ignored candidate onto production recovery fixes before any copy. No scheduler/event/capture production integration yet.
- `requirements` is reviewing corrected save lifetime branches and Preferences uncertainty; no builds/GUI. It authored the shared-pane plan and earlier reviewed the scheduler/core save candidates.

## Other completed investigations and remaining scope

CodeMirror remains ignored, not adopted. Default gate27/33 retained six Unicode/mixed-ending differences. Bounded tuned adapter passed192 state assertions and31 actual WK checks; cap1M UTF16/10k separators. All18 fresh performance children exited0: plain1/10/100MB exact undo/visible EOF passed, adapter1MB passed and10/100MB explicitly limited. Full timings/caveats in `docs/superpowers/specs/codemirror-feasibility.md`; roughly33ms includes two-frame observer floor, no native bridge/dirty/IME/memory claim. Initial stalled smoke retained. No GUI process remains from spike.

Current TextKit100MB same-length dirty edits still roughly415–421ms median after exact NSString comparator improvement;50ms target missed. Long-line native/Scintilla trials also missed targets. Native common-language lexical guide is `docs/languages.md`; semantic features remain outstanding. Help sizing regression fixed and native scroll tests passed. Recent Files at-quit MRU is integrated; >100MB recent opens still require successful byte-viewer completion support.

Plans for periodic session checkpoints and shared-document panes are reviewed but not integrated. Still outstanding: optional autosave/external watching; shared panes/workspaces/advanced selections/overwrite/pairs; folder replace preview/recovery; folding/completion/snippets/custom languages; configurable shortcuts/localization/accessibility; complete performance/fault/security/parity acceptance. Requirements matrix is authoritative; passing tests do not close entire feature families.

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
