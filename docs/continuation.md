# Continuation checkpoint

TheOnlyPad is incomplete. The full BUILD_PROMPT remains scope. Continue autonomous implementation; no remote push/merge/release, credentials, or system security changes. Never claim notarization, Intel/minimum-OS runtime, physical IME/VoiceOver or clean-machine acceptance.

## Current work and exact next action

- Latest committed core scheduler: `43769ae` (earlier service `6a81de6`, reader `7226874`, guard `cb60ee0`). Native monitoring, status/conflict UI and checked Reload/Copy are committed as `b59bfab`. Root owns production controller/AppDelegate/model. Preserve all files; no temporary lifecycle/confirmation stubs remain.
- Latest committed components: `4e22b6b` shortcut core/profile/store; `1afb1d1` bounded transfer/native recorder; `593b5e5` application owner. Native editor/wiring and presentation-refresh fixes are now integrated in the working tree and verified, awaiting the next local commit/package. Current package remains `eaf5145` until rebuilt.
- Fresh final evidence: actual native build/core368 tests passed14.580s `.local/shortcut-final-integration.log`; production application12tests passed0.473s/build11.39s `.local/shortcut-application-tests/run.ZVGPxM6y`; editor39checks `.local/shortcut-editor-native/run.SW7q5Ws4`; recorder47checks `run.Ewxxj0CI`; owner18tests `run.sRzW59jh`. Hidden monitor lifecycle passed `run._9gs7uny`. Full strictformat/public/diff checks passed. All source reviews clear within documented scope.
- Presentation refresh variants are integrated: RecentFiles/SessionRestoration new refreshPresentation methods preserve same-target work; AppDelegate3presentationcallers use them, quit retains explicit update cancellation.26hidden scenarios/163assertions passed `.local/presentation-refresh-tests/run.XW0PSbtU` (empty compiler log). Real removal confirmation injected only in private fixture; existing visible Recent/Session harnesses remain unrun while locked.
- Root exact next: finish local commit, run scripts/package.sh --ad-hoc-sign and independent check-package, record current artifact hash/source. Do not execute GUI. Then continue full brief; not complete. Agent document_core now owns ignored `.local/pane-persistence-design` reviewed design proposal for F01 persisted split presentation (actual SessionStore v1→newversion; v0 remains unsupported and preserved; F02transfer separate). Other agents completed review/testing and are available. No production schema/pane edits yet.
- Desktop Locate and shortcut recording/persistence/reset sources compile (`.local/desktop-locate-compile/status-selector-build.log`), with macOS14 target/header-map alignment; no execution. New status is NSTextView with shortcuts.status identifier and success wording 'Shortcut settings saved.' Locate assertions prove no adoption write and post-relaunch save binding; shortcut old-key checks use inverted waits to avoid false attribution. Physical selectors/input/GUI remain unverified.
- Locate is committed in `eaf5145`: coordinator31 assertions; bridge111+20+26; final combined hidden lifecycle run.r0rwjt2e all phases/no warnings including one session/MRU notification on actual URL adoption and zero on refusal. Full core13575 passed328 tests in14.613s. Independent review clear.
- Real desktop Reload/Copy, Locate chooser/dirty undo/save/relaunch, and shortcut recording/persistence/reset sources now exist. They remain unexecuted while locked. Locate review tightened immediate no-write and post-relaunch binding assertions; shortcut review tightened delayed old-key false-pass checks.
- Latest multiselection spike `.local/multiselection-spike/run.nxkGzSBp` shows native typing only replaces first nonempty range, deletion all ranges, empty carets collapse;11cases exact shared undo/redo. Hidden semantic evidence only; current engine remains provisional. Prior Scintilla/CodeMirror evidence must be considered before a production selection-layer decision.
- After this checkpoint: continue other BUILD_PROMPT requirements with reviewed plans and actual evidence. Full desktop and visible benchmarks remain blocked; package verification alone cannot establish product completeness.

## Fresh evidence

- `scripts/swift.sh test --scratch-path .build/native-monitor-integration`: session91188, native build2.38s and328 tests/0 failures in14.538s. Strict repository swift-format, public-source patterns and diff checks passed.
- Final actual hidden lifecycle/action harness `.local/native-monitor-lifecycle-retained/run.lvkfdn7z`: compile/runtime0, no warnings, all phases passed. Includes real open/save/split/tab binding continuity, equal-byte acknowledgements, quit-veto deferred adoption, close/reopen fencing, status-only no checkpoint, Check/KeepBuffer/captured SaveAs, exact UTF16BE+BOM Reload/Copy, preserved unrelated focus, both-pane postreload typing/undo/redo, dirty Cancel, second disk change, stale panel and close during confirmation.
- Real directory-sync injected uncertain save fixture confirms disk equals attempted bytes while saved baseline remains old. Cancel and confirmation-time change preserve exact pending.id/bytes, dirty buffer and undo. Generic-warning red `run.kqdlp8t7` preceded dedicated wording. Native Cancel-first ordering source-reviewed; actual modal/default-key behavior untested.
- `.local/disk-action-coordinator/run.yEWHlxz5`:57 assertions passed. Independent review fixed terminal predicate reentry, including replacement that finishes before predicate returns. Bounded off-main selection preparation retains global permit until actual canceled job completion. Explicit coordinator cancellation before destruction required.
- `.local/file-state-bridge/run.SILVC6Wl`:105 semantic+18 real-service+26 application checks passed. `.local/file-state-owner-tests/run.khoeUOtB`:20 model+36 actual-controller checks passed. These precede final action wiring; expanded lifecycle above covers it.
- Fresh final compatibility `.local/monitor-compat/run.5setnkt3`: SaveFailureHarness, WindowCheckpointHarness and ApplicationCheckpointHarness all passed against current frozen sources. Earlier run.4ru_iv6f remains retained.
- Independent final lifecycle/script review found no material issues. All seven legacy operations use exact UUID ownership; baseline adoption precedes finish; AppDelegate quit/veto and close cancellation source-reviewed. Status rendering does not write checkpoints or files.
- These tests instantiate actual native controllers but never show/activate windows or native dialogs. Full native suite includes visible harnesses and has not been rerun while locked.

## Environment and proven commands

Branch `build/native-editor`; repository-local privacy-preserving commit identity. AppKit/TextKit1 plus Foundation/CryptoKit/Darwin PadCore; no external runtime packages. macOS14 minimum, Swift6.3.3 in Swift5 mode. Runtime evidence is ARM64 M4 Pro/48GiB/macOS26.6.2 only. Engine choice remains provisional pending complete performance/IME/accessibility acceptance.

Stable shortcut link products: `.build/shortcut-store-integration/arm64-apple-macosx/debug` (361 tests); requirements may be building `.build/shortcut-transfer-integration`. Stable monitor link products: `.build/native-monitor-integration/arm64-apple-macosx/debug`. Older `.build/external-action-service`, `.build/external-action-reader`, `.build/external-file-integration` are retained for isolated agents. Coordinate before rebuilding shared scratch directories. All raw fixtures/logs live in ignored `.local`; no public real documents or machine paths. Native toolchain and synthetic atomic file writes may need approved escalation; one spike compiler-mode change was rejected by automatic review, then resolved with evidence: Package.swift explicitly declares Swift5 language mode. The spike accidentally introduced Swift6; retry explicitly matching Swift5 was approved without source/test weakening. Preserve its initial setup failure and do not modify observer code to satisfy that mismatched spike configuration.

```sh
scripts/swift.sh test --scratch-path .build/native-monitor-integration
scripts/test-file-state-bridge.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-disk-action-coordinator.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-file-state-owner.sh --build-path .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-native-monitor-lifecycle.sh .build/native-monitor-integration/arm64-apple-macosx/debug
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
git diff --check
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

## GUI access and package

Read-only session probe reported console screen locked. User was asked to unlock and approve Enable UI Automation if prompted; no response yet. Do not retry visible benchmarks, open the app, or rerun XCUITest until access is confirmed. Three earlier XCUITest attempts failed before tests enabling automation; no credentials/settings were changed. The current lock does not retrospectively explain earlier visibility failures.

Current `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json` are source `eaf5145`, including native monitoring and checked Reload/Copy/Locate. Executable SHA256 `370926fd82402e7ef4978e54f1907de67dd4f01ac30adb637ae54618216350ce`. Package87796 release11.79s; ad-hoc signature, all6bundle/ZIP byte matches, SBOM hash, safe archive and specified ASCII path markers passed, including independent post-promotion check. No DeveloperID/notarization/publication/current desktop acceptance.

Historical earlier executable0324726… passed6 real packaged desktop tests in298.439s, `.local/desktop-ui/run.WdUWEz/results.xcresult`; not current runtime evidence. See `docs/verification/xcuitest-feasibility.md`.

## Invariants and limitations to preserve

- Shared NSTextStorage/UndoManager; max2panes, stable pane identities, retained detached undo targets. Composition owner excludes other pane mutations. Visible split cap2M UTF16; axis only in process; persistence/window transfer/synchronized scrolling outstanding.
- Exact aligned/suffix dirty proof has conservative fallback and pending-storage poison. Native40k edits/43,226 dirty/70,936 proof checks passed historically. No digest or unconditional dirty substitute.
- AtomicFileStore publicationUncertain retains opaque evidence and exact attempted bytes. Readback is not acknowledgement; fresh successful save only. SaveAs create-only and uncertainty preserves oldURL/baseline. Keep Buffer never authorizes overwrite.
- Paired immutable recovery/session checkpoints:750ms debounce/15smax, one worker+pending, bounded retry, quit drain/final receipt. Historical actual SIGKILL recovery passed. Full fault matrix remains outstanding.
- Monitor:128regs,2workers,16shared manual/action admissions through actual callback drain,256watch reservations+6transient/worker=268owned max.250msdebounce/2smax/30sexact-byte reconciliation. No metadata cache. Guard prevents dataless materialization on calling worker thread; no cloud-provider E2E claim. Cancellation is cooperative between syscalls.
- Native process action lease and exact context/operation/generation protect asynchronous reads; copy creates URL-less scratch. Reload confirmation precedes final revalidation and coherent adoption; no automatic reload or original-file writes from monitoring.
- Historical dirty100MB6fresh children108ops met under50ms for measured dirty edit scope, RSS~533MB. One checkpoint-interaction smoke measured8edits26.61ms median27.29max during5writes, RSS1.261GB, exact100MBrestore. Not repeated acceptance; later visibility-gated writers failed before measured edits.
- Glyph warnings reproduced unchanged baseline and candidate; root cause/rendering still unresolved. Corrected visible harness bootstrap source has not been run while locked. Do not weaken visibility gates.

Broader outstanding scope includes optional autosave/save races/metadata; split/workspace persistence and document transfer; multicursor/rectangular/overwrite/guides; folder replacement preview/backups; folding/completion/snippets/custom languages/formatters; shortcut customization/localization/full accessibility/IME; complete100MB/1GB/long-line/cold-launch benchmarks; security/supply-chain/parity/fault review; clean packaged desktop and external signing/release steps. Keep matrix statuses honest.
