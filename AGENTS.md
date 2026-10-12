# TheOnlyPad agent instructions

Read [docs/BUILD_PROMPT.md](docs/BUILD_PROMPT.md) before implementing the application. It contains the feature scope, autonomous Superpowers lifecycle, and acceptance criteria.

- This is a public repository. Assume every tracked file will be public.
- Preserve unrelated user changes. Use isolated branches/worktrees when appropriate.
- Use synthetic test documents. Never commit credentials, private documents, machine-specific home paths, recovery buffers, signed credentials, or unsanitized logs/screenshots.
- Original code is MIT-licensed. Check dependency and asset licenses before adoption; document attribution and redistribution obligations. Do not copy Notepad++ code or assets under an incompatible licensing assumption.
- Record planned, implemented, tested, and blocked states separately. A passing build is not proof of feature completeness.
- Use the installed Superpowers lifecycle. The build prompt explicitly authorizes routine decisions and replaces repeated human design approvals with documented review.
- Local implementation, testing, and scoped commits are authorized. A request to publish initial repository scaffolding does not authorize future release publishing, remote pushes, or merges; obtain authorization for those actions when needed.
- Never weaken tests, disable security checks, or claim an unavailable platform was tested.
- Add exact build, test, and run commands here once the architecture is established. Do not invent commands before they work.

## Established architecture and commands

Swift Package Manager; Swift 6 toolchain in Swift 5 language mode; deployment target macOS 14. `PadCore` contains non-UI services using Foundation, CryptoKit and Darwin; `TheOnlyPad` contains AppKit adapters. Branding/version lives in `Sources/PadCore/AppIdentity.swift`. No external runtime packages currently.

Proven commands (2026-09-09, ARM64 macOS 26.6.2 / Swift 6.3.3):

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

Current package source `9231fc3` passed actual XCUITests for open/edit/save/Command-Q/relaunch/reopen, shortcut customization/persistence/reset, and an Option-held menu action using isolated synthetic state. The separate direct AXPress check remains unverified: sandboxed XCTest is an unsuitable host and a separately identified native test client needs user-granted Accessibility access. Broader GUI, physical IME and VoiceOver acceptance remain outstanding. Launch the local bundle with `open dist/TheOnlyPad.app`. Never use real documents in harnesses. The native integration harnesses intentionally SIGKILL their own child to test recovery; the separate desktop UI script uses Xcode's actual XCTest runner and keeps raw diagnostics under ignored `.local/desktop-ui`.

SwiftPM and Foundation atomic file writes require an approved unsandboxed toolchain invocation in the current restricted environment. Keep caches in ignored project directories. Tests must not be skipped to mask a permission failure.

Checkpoint capture/publication cost probe (synthetic1/10/100 MB, release mode; not typing-latency or desktop acceptance): `scripts/benchmark-checkpoints.sh`. Results remain in ignored `.local/checkpoint-benchmarks/`; sanitize before sharing.

Visible pane adapter smoke: `scripts/benchmark-panes.sh`. The retained runner compiled and executed three cases; two passed and one failed foreground admission. It returns nonzero for any incomplete case. Run only with exclusive build/GUI ownership; raw synthetic results remain in ignored `.local/pane-benchmarks/`. See `docs/verification/shared-pane-performance.md` for scope, initial matrix failures and exclusions. A benchmark pass does not establish application input-latency acceptance.

Local packaging now verifies archive bytes, SBOM hash and specified machine-path markers before promotion. Standalone check: `python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json` (update artifact names when centralized identity/version changes).

Checkpoint/edit interaction diagnostic: `scripts/benchmark-checkpoint-edits.sh` (one writer/restore pair; `--full` requests three). The retained wrapper built and ran; latest writer failed strict admission because the application remained inactive, with no measured edits or restoration. Run only under exclusive CPU/GUI ownership. Raw synthetic evidence is ignored in `.local/checkpoint-performance/`; see `docs/verification/checkpoint-edit-interaction.md`. This is not repeated performance acceptance.

Hidden monitor/ownership integration checks (proven against a built debug directory; these do not replace desktop tests):

```sh
scripts/swift.sh test --scratch-path .build/native-monitor-integration --filter AppCommandsTests
scripts/test-file-state-bridge.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-disk-action-coordinator.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-locate-coordinator.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-file-state-owner.sh --build-path .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-native-monitor-lifecycle.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-disk-status-view.sh .build/native-monitor-integration/arm64-apple-macosx/debug
scripts/test-disk-conflict-panel.sh
```

Ordinary XCUITest automation is available. Root exclusively owns serial GUI execution and exact-owned-app cleanup; agents must not post input or launch visible harnesses concurrently. The user authorizes a separate Accessibility permission prompt, but the actual grant remains user-owned. Never change privacy settings or infer grant from silence.

Shortcut components: `scripts/swift.sh test --scratch-path .build/shortcut-store-integration` passed361 tests. `scripts/test-shortcut-recorder.sh .build/shortcut-store-integration/arm64-apple-macosx/debug` passed47 hidden checks using the declared Swift5 mode. Unposted native event/menu conversion and injected recorder lifecycle are separate evidence; this runner never shows windows or posts keyboard events and cannot establish physical keyboard acceptance.

`scripts/test-application-shortcuts.sh` passed18 Foundation owner tests using frozen production source copies in an ignored Swift5 package, including the real parent-replacement retry regression. `scripts/swift.sh test --scratch-path .build/shortcut-native-integration` built the actual app and passed368 core tests. Neither command establishes visible shortcut editor or keyboard dispatch acceptance.

`scripts/test-shortcut-editor.sh .build/shortcut-native-integration/arm64-apple-macosx/debug` passed39 hidden native controller checks. The runner freezes production source, appends a documented test-only extension and records both hashes. Draft/notification/error handling and layout geometry are tested without shown windows; desktop and physical input acceptance remain separate.

`scripts/test-shortcut-application.sh` passed12 hidden application/owner/UI tests using frozen production sources and explicit test-only private-access extensions. Native menus, real owner callbacks and synthetic stored files are covered; chooser responses are injected. No visible app or modal interaction is performed.

`scripts/test-native-presentation-refresh.sh .build/shortcut-native-integration/arm64-apple-macosx/debug` passed26 scenarios/163 assertions. Cosmetic panel refresh preserves current outcomes while explicit update/target-change/close still cancel. The runner injects one documented removal-confirmation boundary; it does not test a real sheet. See `docs/verification/presentation-refresh.md`.

`scripts/test-session-presentation-flow.sh` passed9 tests for file/recovery restoration, both-pane position validation, unresolved metadata, cancellation, legacy-reader refusal and failed-checkpoint retry. It freezes core plus the three session owners into a private Swift5 package. It performs synthetic file I/O without showing windows; it does not exercise AppDelegate or the native pane controller.

`scripts/swift.sh build --scratch-path .build/pane-native-integration` builds the current app. The matched frozen pane candidate passed 392 core tests,24 hidden pane modes/199 assertions,26 actual-save assertions, and monitor compatibility. `scripts/test-pane-session.sh .build/pane-native-integration/arm64-apple-macosx/debug` and `scripts/test-pane-save.sh .build/pane-native-integration/arm64-apple-macosx/debug` freeze native sources with explicit test-only access extensions and never show windows. The diagnosed asynchronous bounds race was removed by bounded synchronous range validation; historical failures remain in the evidence record. See `docs/verification/persisted-pane-presentation.md`.

`scripts/test-application-documents.sh` passed 30 registry tests (13 ownership and 17 close-state cases); `scripts/test-session-capacity.sh` passed7 coordinator tests with synthetic files. These freeze their actual sources into private packages and do not create native windows. Registry registration/metadata/selection and pure aggregate-capacity snapshots are tested independently; native document transfer, native close enforcement and the required two-phase recovery service remain unimplemented. Registry close leases alone do not establish native data safety.

`scripts/test-checkpoint-pause.sh` passed 12 deterministic scheduler pause/receipt tests and the existing scheduler regression harness. It uses frozen production sources, no native windows, and does not verify the new recovery actor or native close integration.

`scripts/test-recovery-close.sh` passed 25 actor/store tests; `scripts/test-document-recovery-ownership.sh .build/recovery-close-candidate/arm64-apple-macosx/debug` uses the verified core build for hidden model checks (26 assertions plus shared-pane ownership). Full integrated core suite passed 404 tests. Managed native close/publisher activation remains outstanding.

`scripts/test-session-import-claims.sh` passed 17 coordinator tests, including actual temporary recovery-file preservation. Claims are provenance and require caller revalidation after callbacks; native import activation remains outstanding.

`scripts/test-document-adoption.sh` passed 41 registry tests (11 adoption plus the original 30); `scripts/test-application-document-closing.sh` passed 19 process-owner tests including real paired publication and fresh same-process readers. These are Foundation integration tests, not native window-close acceptance.

`scripts/test-document-factory.sh .build/native-ownership-integrated/arm64-apple-macosx/debug` passed 133 hidden factory checks plus the shared-pane ownership control. Use a verified core build; managed AppDelegate activation remains outstanding.

`scripts/test-application-session-checkpoints.sh` passed 18 real-store publisher tests. The extracted legacy AppDelegate initializer builds; native managed activation remains outstanding.

`scripts/test-application-document-intake.sh` passed 26 process-owner tests, including actual startup publisher integration and a paired receipt/reload. Eight hidden actual-controller routing tests also pass; full process activation remains outstanding.

`scripts/test-native-close-model.sh .build/adoption-close-integrated/arm64-apple-macosx/debug` passed 106 close-model checks plus factory/shared controls; process-close suite now passes 20 tests with pre-await repair context. Complete native close admission remains outstanding.

`scripts/test-document-history.sh` passed 49 registry/history tests. History claims retain close-time source identity and require active replacement before consumption; native reopen remains separate.

`scripts/test-application-open-requests.sh` passed 10 tests for bounded FIFO/startup/quit/retry behavior. `scripts/test-editor-application-routing.sh` passed 32 hidden controller/actor/publisher workflows. These do not replace desktop testing.

`scripts/test-file-state-bridge.sh .build/native-ownership-integrated/arm64-apple-macosx/debug` passed 125 deterministic bridge, 25 real-service and 26 application-monitor checks. `scripts/test-native-admission-hooks.sh .build/native-ownership-integrated/arm64-apple-macosx/debug` passed 34 hidden selection/undo checks, including actual registry refusal during grouped replay.

Current managed integration supersedes earlier outstanding adapter notes above: `scripts/test-native-application-documents.sh` passed nine hidden actual-owner tests, including startup, native close/reopen, unresolved file import, new-window adoption and final paired checkpoint readback. `scripts/test-native-application-close.sh` passed five hidden actual close tests including real interrupted-deletion repair. `scripts/test-native-history-preparation.sh .build/native-ownership-integrated/arm64-apple-macosx/debug` passed seven checks. These commands do not show windows; AppDelegate activation and desktop acceptance remain outstanding.

`scripts/test-native-application-open.sh` passed ten hidden FIFO tests, including real intake/navigation and preserved imported documents on terminal positioning errors. Owner capacity tests include 32 unresolved windows and 128 unresolved documents. AppDelegate migration is in progress; use frozen source snapshots when agents edit shared files.

`scripts/test-managed-documents.sh` passed 71 combined hidden tests against one frozen source set (AppDelegate9, owner9, routing32, intake6, external-open10, close5). Full frozen app/core verification passed404 tests, and monitor compatibility passed. This runner is archive-compatible and now runs in CI. Managed AppDelegate routing is integrated; visible desktop and packaged runtime acceptance remain outstanding.

Transfer subsystem commands: `scripts/test-document-transfer-registry.sh` passed 62 tests; `bash scripts/test-application-document-transfer-process.sh` passed 15 tests; `scripts/test-native-document-transfer.sh` passed 12 bounded native adapter tests. These do not establish integrated transfer or desktop acceptance. Monitor dependency now passes 142 deterministic, 29 real-service, 26 lifecycle and 44 native binding checks. Freeze source sets while controller integration is in progress.

Existing-window transfer integration commands: `scripts/test-editor-transfer-projection.sh` exercises controller projection and replacement-endpoint receipts; `bash scripts/test-native-application-document-transfer.sh` exercises the real process owner, native models and recovery files; `bash scripts/test-document-move-destination.sh` exercises the File-menu command/chooser through the actual AppDelegate. All use hidden native tests and isolated synthetic state. They do not establish physical menu, keyboard, accessibility or packaged desktop acceptance. See `docs/verification/native-transfer-projection.md` and the integration evidence records for exact source snapshots and counts.

`scripts/test-native-new-window-transfer.sh` passed 23 hidden preparation tests against reviewed source `da8ef2e` (including cancellation settlement and same-request open retry); `scripts/test-native-application-open.sh` passed 10 actual coordinator regression tests on matching production. It tests aggregate capacity, retained preparation/pause ownership and exact unused-window cleanup; it does not yet prove new-window handoff or chooser behavior. See `docs/verification/new-window-preparation.md`.

Reviewed new-window handoff source `1c96b99` passes `scripts/test-native-new-window-transfer.sh` (44 tests), existing transfer (12), process (17), owner (9), projection (9), and monitor compatibility. `scripts/swift.sh build --scratch-path .build/new-window-handoff` builds the actual app. Typed chooser/presentation and packaged desktop acceptance remain separate; see `docs/verification/new-window-handoff.md`.

New-window chooser and integrated package checkpoint: `scripts/test-document-move-destination.sh` passes 15 tests; committed-source `scripts/swift.sh test --scratch-path .build/integrated` passes 404 and `scripts/test-managed-documents.sh` passes 71. `scripts/package.sh --ad-hoc-sign` and `python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json` pass at `55a7b1b`. Use an owned-process watchdog for suites containing adversarial regex. See `docs/verification/new-window-integrated.md`; desktop acceptance remains blocked.

Regex error verification at `9d54295`: build with `scripts/swift.sh build --scratch-path .build/search-engine-errors-final`; run `scripts/test-search-engine-error-panels.sh .build/search-engine-errors-final/arm64-apple-macosx/debug` for both hidden actual-controller failure paths. Focused `SearchEngineFailureTests` passes seven cases; full committed-source core passes 412 under an owned-process watchdog. These checks do not establish hard engine cancellation or desktop acceptance.

Search framing at `aa3aa82`: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireFrameTests` passes19 tests; `scripts/swift.sh build --scratch-path .build/search-wire --target SearchExecution` builds the module. These benign codec tests do not launch a helper or establish regex containment. See `docs/verification/search-wire.md`.

UTF-16 codec at `10c4dd4`: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireUTF16Tests` passes20 tests, and the framing filter above still passes19. These are bounded Unicode/index correctness tests, not desktop or memory benchmarks.

Request codec at `2a76168`: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireRequestTests` passes30 tests after independent review fixes. These tests validate protocol/Unicode/phase behavior only; the app is not yet routed through a helper.

Response codec at `869de1f`: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireResponseTests` passes28 tests; independent source review approves the scope. This is protocol evidence, not helper or desktop acceptance.

Wire semantic handoff at `e04f466`: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireSemanticTests` passes9 tests and `--filter SearchWire` passes106. Clean committed-source full test531/0 and app build pass; see docs/verification/search-wire.md. Broad adversarial core tests still require the owned outer watchdog.

Search lifecycle at `eb3f1e1`: `env NSUnbufferedIO=YES scripts/swift.sh test --scratch-path .build/search-child-lifecycle-repair --filter SearchChildLifecycleTests` passes32 deterministic tests; full suite563/0. Development runs used the owned outer watchdog. No real helper process or native search integration is claimed. See `docs/verification/search-child-lifecycle.md`. Real child fixtures must wait for the planned checked-in watchdog.

Search-child infrastructure commands verified locally (macOS):

```sh
python3 -m unittest discover -s Tests/SearchChildIntegration -p 'test_*.py'
scripts/test-search-child-lifecycle.sh --build-only
scripts/test-search-child-lifecycle.sh
```

The harness freezes actual sources and invokes the reviewed owned-process watchdog directly for each build/test stage. Do not wrap it in another process-group watchdog. Its current default suite has 36 deterministic lifecycle tests; that default does not execute the separately filtered actual-pipe suite or a real helper. Raw evidence stays under ignored `.local/search-child-integration/`.

Injected channel state: `scripts/test-search-child-lifecycle.sh --filter SearchChildChannelStateTests` passes20 tests; the unchanged default lifecycle filter passes32 using the same frozen source manifest. The injected initializer accepts explicit descriptor/source collaborators and requires verified adoption preconditions. These injected tests alone do not establish concrete I/O. The separately accepted Darwin/Dispatch default initializer and StageA real-pipe smoke are documented below; helper and production routing remain outstanding. See `docs/verification/search-child-lifecycle.md`.

Native runner prerequisite is verified: `scripts/test-native-close-model.sh` now builds a frozen matching application itself; no build-path argument is required. Transfer/projection/close share the accepted same-process watchdog coordinator with exact input inventories. Pure contracts: `python3 -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py` (26 passed). See `docs/verification/native-regression-runners.md`. Never wrap these coordinators in another session-owning watchdog.

Applied document settings: `scripts/test-document-applied-settings.sh` passes 24 hidden native tests for effective typography/wrap, pane inheritance, transfer receipts and configuration admission. Existing transfer/projection/close regressions also pass; the shared coordinator's pure suite now has 28 tests. The native runner freezes sources and invokes the accepted watchdog directly; do not nest another session-owning watchdog. No GUI or performance acceptance is established. See `docs/verification/document-applied-settings.md`.

Concrete search-channel StageA: `scripts/test-search-child-lifecycle.sh --filter SearchChildChannelPipeTests/testDefaultConstructorReadsOwnedResponseByte` passed one actual synthetic-pipe test with complete owned-process receipts, matching source inventory, exact byte read, channel close, lifetime EOF/cancel acknowledgment and confirmed peer close. Original20 injected plus9 fixture controls also passed. The broader accepted channel suite is recorded below. See `docs/verification/search-child-lifecycle.md`.

Preferred pane focus: `scripts/test-editor-transfer-projection.sh` passes 20 hidden native tests, including actual responder insertion/undo after managed startup, both split orientations and refusal rollback. Matching settings (24), transfer (12), close (106), factory (133) and shared-pane controls pass; the shared native coordinator pure suite now has 30 tests. Complete owned-process receipts and frozen inputs were verified. No packaged desktop or physical input acceptance is established. See `docs/verification/preferred-pane-focus.md`.

Concrete search channels: `scripts/test-search-child-lifecycle.sh --filter SearchChildChannelPipeTests` passes nine actual synthetic-pipe tests for exact stream/EOF, FIFO/backpressure, admitted read/write cancellation, sticky EOF, per-FD EPIPE survival with unchanged SIGPIPE, source-acknowledged close and safe exact descriptor reuse. The matching injected channel/fixture suite passes 40 tests. Complete source inventories and all direct-watchdog receipts were verified; use the approved outside-sandbox toolchain invocation where SwiftPM requires it, without nesting another watchdog. No child launcher/reap, helper, production search routing or memory/performance acceptance is established. See `docs/verification/search-child-lifecycle.md`.

Startup-failure lifecycle contract: the default `scripts/test-search-child-lifecycle.sh` passes 36 deterministic tests, preserving the original 32 and adding failed-startup PID ownership, connector suppression, first-outcome and held-cleanup controls. Behavioral red was four tests/five failed assertions; all frozen-input and owned-watchdog receipts were verified. The optional internal failure does not implement a launcher or pre-adoption quarantine. See `docs/verification/search-child-lifecycle.md` for the narrowed cleanup receipt scope and remaining integration gates.


Concrete launcher checkpoint (2026-09-30): injected `SearchChildLauncherStateTests` passes14 and default lifecycle36 on matching frozen inputs; harness/watchdog pure checks pass50. A gate-removal mutant fails1/7 explicitly. Root then executed the separately selected actual `SearchChildLauncherTests/testImmediateExit17UsesSoleLifecycleReaper` and `SearchChildLauncherTests/testBenignBootstrapEchoAndExactExitCleanup` from the reviewed frozen package using `--skip-build` under the accepted watchdog; each passes1/0 with exact source/fixture/bundle bindings and cleanup receipts. This proves the benign launcher/bootstrap/reap slice, not a production helper, lifetime watcher, Foundation inheritance protection or app routing. See `docs/verification/search-child-lifecycle.md`. Historical obsolete search compiler scratch directories were reclaimed after disk exhaustion; rebuild any missing `.build` path before using it as a dependency. Sources, recorded evidence and distribution artifacts were retained.


Search worker Task1 (2026-09-30): package-only injected sequential loop/collector passes21 focused tests in a frozen minimal package built from actual PadCore, SearchWire and runtime sources. `scripts/swift.sh build --scratch-path .build/search-worker-runtime-task1 --target PadSearchWorkerRuntime` passed against the public manifest under the accepted watchdog. Genuine RED12/31 and final21/0 receipts/inventories were verified; independent review approved Task1. No production accumulator, fixed engine adapter, helper executable/process, memory acceptance or app routing follows. See `docs/verification/search-worker-runtime.md`.

Timer/lifetime component: final frozen injected suite passes60 tests (10 timer/read-loop,14 launcher,36 lifecycle), and `scripts/test-search-child-lifecycle.sh --filter SearchChildLifetimeProcessTests` selects the actual busy-main child EOF check. Root verified that actual test1/0 using the matching frozen build with `--skip-build` and absolute package/scratch paths; exact exit0/reap/channel shutdown and all receipts are recorded in `docs/verification/search-child-lifecycle.md`. This is not production helper, inheritance protection or hard regex containment acceptance.

Worker engine adapter: the frozen Task2 command `scripts/swift.sh test --package-path .local/search-worker-engine-task2/green --scratch-path .build/search-worker-engine-task2 --filter SearchWorker` passed42 tests under the accepted direct owned-process watchdog. All explicit request limits and single execute are implemented; source review and logical release ordering are verified. See `docs/verification/search-worker-runtime.md`. This does not establish helper runtime, memory bounds or app routing.

Worker bootstrap/channel injected component now passes60 combined tests (4 bootstrap,14 channel,42 earlier runtime/adapter). Frozen evidence and exact source hashes: `docs/verification/search-worker-runtime.md`. Borrowed bounded channel and Darwin adapter compile; these injected tests do not execute concrete descriptor I/O, EPIPE or a helper. Program composition/exit mapping remain outstanding.

Worker Program composition passes72 frozen component tests (12 new,60 prior), including startup ordering, fixed engine and exit mappings. See `docs/verification/search-worker-runtime.md`; the executed snapshot intentionally excludes concurrent shared-gate drafts. Injected placeholder descriptors never reach Darwin. Actual lifetime-thread/helper/channel integration remains outstanding.

Shared process spawn-gate Task1: final core admission11/0 and frozen launcher/lifecycle/timer68/0 pass; root actual external-command regressions6/0 and existing real launcher/lifetime3/0 pass with source/bundle bindings and strict watchdog receipts. See `docs/verification/shared-spawn-gate.md` for commands, scope, mutation controls and retained setup failures. Controlled unrelated-peer overlap (Task2), public lifecycle/helper and packaging remain outstanding.

Packaged desktop checkpoint at `f4d9207` (2026-09-30): frozen integrated suite650/0; release package/archive/SBOM verified; five actual XCUITests passed with0 failures/skips (native open/edit/save/reopen, graceful scratch restoration, shortcut override persistence/reset, Option-held menu action, shared-pane Unicode editing/undo/orientation/save/restoration). Tested artifacts now reside in local `dist/`; no release publication or notarization. See `docs/verification/packaged-desktop-2026-09-30.md` for reproduction, hashes and exact limits. Raw evidence is ignored under `.local/integrated-search-20260930/`.

Shared spawn peer and typed channel prerequisite: the frozen final combined selection passed80/0 (79 deterministic,1 real helper/peer) with verified source and both artifact bindings. Reproduce with `scripts/test-search-child-lifecycle.sh --filter 'SearchChildSpawnInheritanceFixtureTests|SearchChildLauncherStateTests|SearchChildLifecycleTests|SearchChildLifetimeStateTests|SearchChildDispatchTimerTests|SearchChildSpawnInheritanceTests'`. The default lifecycle filter now has45 tests. Reserve root-exclusive real child execution; do not nest another watchdog. See `docs/verification/shared-spawn-gate.md` and `docs/verification/search-child-lifecycle.md`. This does not establish app search routing or regex containment.

Parent wire Task1: `scripts/swift.sh test --filter SearchParentWireBridgeTests` covers20 tests; final frozen integrated suite passes679/0 and builds the app. Three explicit mutation controls verify acknowledgement, consumer settlement and token fencing. See `docs/verification/search-parent-wire-bridge.md`. This is an internal primitive; production search remains unrouted. Use the owned watchdog for the broad adversarial suite.

Parent codec and byte-retirement components: the frozen integrated source passes721 tests/0 failures with676 input hashes and complete owned-watchdog receipts verified. `scripts/swift.sh test --filter 'SearchParentWireCodecSessionTests|SearchWire'` covers21 codec behavior and114 wire tests; byte/lifecycle focused verification passes57. Run under the accepted owned watchdog where required. See `docs/verification/search-parent-codec-session.md` and `docs/verification/search-byte-recycling.md`. These do not establish driver integration, real byte retirement, helper routing, allocation/RSS or desktop acceptance. The locally tested package remains source `f4d9207`.

Concrete worker FD adapter verification: `scripts/swift.sh test --filter PadSearchWorkerRuntimeTests`, run under the checked-in owned watchdog, passes77 tests including four actual tiny-pipe checks. These verify real EOF/byte fidelity, borrowed descriptor ownership and per-FD EPIPE survival under unchanged default SIGPIPE. Tests fail explicitly if that signal precondition is unavailable. No helper is launched; partial-write/EINTR coverage remains injected. See `docs/verification/search-worker-runtime.md`.

Fixed helper resolver: `SearchWorkerBundleResolverTests` and `SearchWorkerResolverLaneTests` add13 checks; focused resolver/lifecycle64/0 and integrated738/0 pass with681 matching frozen inputs and strict owned-watchdog receipts. The resolver performs fixed structural lookup and final-entry regular/executable checks. Default launcher forwarding, helper assembly and actual packaged helper execution remain outstanding. See `docs/verification/search-worker-resolver.md`.

Default launcher forwarding is integrated. The combined resolver/launcher/lifecycle/channel-release/actual-child selection in `docs/verification/search-worker-resolver.md` passes83/0, warning-free, with77 matching frozen sources and all owned-process/fixture/test-bundle bindings checked. Actual child cases cover bootstrap/echo/exit0 and exit17 cleanup, not a search helper. The user-facing app still has no supervised-search routing.

Parent driver: `python3 -m unittest discover -s Tests/SearchParentDriverIntegration -p 'test_*.py'` passes19 pure runner checks. `scripts/test-search-parent-driver.sh` passes44 cases in an isolated repository layout using exact adopted bytes (27 ordinary plus17 frozen-only); it directly owns its watchdog and must not be nested under another. Uninstrumented driver27/0, combined components142/0 and fresh integrated app765/0 pass. No actual search helper or editor search routing is claimed. See `docs/verification/search-parent-driver.md`.

A private release-mode real parent/helper pilot passed one1MB supplementary-Unicode zero-match replacement with exact source/output digests, observed consuming reap, final absent child slot, closed channels and settled parent lane. The corrected measurement predicate passed6 tests after a discriminating RED; earlier compiler and cleanup-harness failures remain preserved. See `docs/verification/search-allocation-pilot.md` for exact hashes and scope. This is not a public benchmark command, selected accumulator, paired memory peak, adversarial-regex proof or production editor search integration.

Packaged search workflow: `GUIProbe/testRegexReplaceConfirmationUndoAndSave` passed1/0/0skip against f4d9207, covering ICU capture replacement, match-case, count/navigation status, confirmation cancel/accept, grouped undo/redo and exact UTF-8 save. The Find panel is an XCUI Dialog and the popup item is selected by click. Earlier selector failure and keyboard-popup timeout remain documented in `docs/verification/packaged-desktop-2026-09-30.md`; no broad search or keyboard acceptance follows.


Shutdown preservation controls (2026-10-05): `scripts/test-search-child-lifecycle.sh --filter 'SearchChildLifecycleTests/testSuccessfulSignal'` passes2 tests; matching default lifecycle passes53. Successful signal followed by exact exit0 or signal9 retains ownership until channel acknowledgment. A frozen premature-release mutant fails6 assertions. Root verified78 input hashes and strict direct-watchdog receipts; independent review approved the test scope. Production and the private allocation predicate are unchanged; this does not explain historical OS scheduling or establish app routing. See `docs/verification/search-child-lifecycle.md`.


Nonterminal driver settlement (2026-10-05): `scripts/test-search-parent-driver.sh` passes54 tests; default `scripts/test-search-child-lifecycle.sh` passes57; parent runner pure contracts pass23. Matching source inventories, direct-watchdog receipts and stale-handle mutation failure were verified. Inspection preserves healthy reuse and waits for exact request/adopted cleanup; it does not certify launcher quarantine. See `docs/verification/search-parent-driver.md`. No admission policy, production helper routing or packaged acceptance follows.


Native search replacement safety: `scripts/test-search-replacement.sh` passes12 hidden actual-controller tests, neighboring `scripts/test-editor-transfer-projection.sh` passes20 and native runner contracts pass32. Exact frozen sources and direct-watchdog receipts verified. The replacement stages bookmark/macro bookkeeping until final callback revalidation. See `docs/verification/native-edit-revalidation.md`; other edit routes and visible acceptance remain separate. Do not nest another watchdog around these coordinators.


Native callback revalidation checkpoint (2026-10-05): `scripts/test-search-replacement.sh` passes32 hidden actual-controller tests across search, minimal document transforms, line endings, Text Utilities, JSON and replay; `scripts/test-editor-transfer-projection.sh` passes20 matching neighboring checks. The shared native edit boundary preserves original async context/operation/cancellation and stages bookkeeping after precommit callbacks. Pure native runner checks pass37. Frozen integrated app build and839 core/component tests pass under the accepted direct watchdog. No windows/input or packaged desktop acceptance follows; see `docs/verification/native-edit-revalidation.md`.

Search admission component (2026-10-05): `scripts/swift.sh test --filter SearchAdmission` passes56 focused tests in a frozen actual-source package; `scripts/test-search-parent-driver.sh` passes54 matching actual-driver/instrumented regressions. Frozen integrated app build and839 tests pass under the accepted direct watchdog. Two cleanup/borrow mutation controls fail as intended. The controller has explicit injected policy, bounded metadata queue, lazy capture, cancellation settlement and deferred result leases; no app route/default budget is installed. Native/modal and controller-held-physical-cleanup composition remain separate gates. See `docs/verification/search-admission.md`.

Actual admission/driver composition: `scripts/swift.sh test --filter SearchAdmissionDriverIntegrationTests` passes3 tests against actual owners and injected OS/channel collaborators, with78 complete frozen bindings. Premature cleanup-release mutant fails1 test/12 assertions. Matching full app/core snapshot passes842 tests and builds the app warning-free. This proves tested reservation/shutdown composition, not kernel reap, helper execution, native modal borrowing or app route activation. See `docs/verification/search-admission.md`.


Search admission native borrow: `scripts/test-search-admission-native-borrow.sh` passes three mandatory hidden AppKit cases; `python3 -B -m unittest discover -s Tests/SearchAdmissionNativeIntegration -p test_runner.py` passes24 pure runner checks. The runner freezes actual sources and directly owns the accepted watchdog; do not nest another. Root exclusively owns this native execution. No shown windows, posted input or helper; injected driver/policy and actual nested run-loop target/action test retained borrowing, refusal/unregister and joined shutdown. See `docs/verification/search-admission.md`; production routing, measured budgets and desktop acceptance remain separate.


Folder-result navigation: `scripts/test-folder-navigation.sh` passes10 hidden actual-controller tests; shared native runner pure suite now passes38. Managed documents71 and native search/edit32 regressions pass, as do both error-panel harnesses against the fresh `.build/folder-navigation-final` app/core build. The folder runner directly owns its accepted watchdog; do not nest another. Exact target/authority survives completion callbacks, and reload captures its intended document before admission callbacks. See `docs/verification/folder-result-navigation.md`; no shown UI, helper routing or packaged acceptance is claimed.

Private campaign prerequisites (2026-10-06): combined engine-counter component33/0, three focused discriminating mutants, tiny actual native self-only smoke1/0, and journal settlement repair21/0 are verified with exact frozen inputs and complete direct-watchdog receipts. Journal RED21/4 and the pre-test copied-cache failure are retained. See `docs/verification/search-campaign-components-2026-10-06.md`. There is no public campaign runner yet; helper composition, physical-facts/finalization, release-role assembly, allocation comparison and production search routing remain outstanding. Do not treat the native self check as paired peak or memory acceptance.

Private cold source-submit helper18/0 now passes against the corrected journal, with97 bound inputs and independent final review. Same-journal and same-length source-substitution mutants are detected; the latter throws `sourceMismatch`, recorded as XCTest unexpected1. Root verified exact98-input mutant derivations and complete watchdog receipts/binaries. Builder count is source-callgraph evidence, not allocation/release measurement. See the component checkpoint above; actual helper/process execution and cold physical-facts/finalization remain outstanding.

Private cold physical projection51/0 now passes (12new plus39 unchanged controls), with99 frozen inputs, two100-input mutants1/1 each, and independent final review. It captures one journal snapshot, preserves actual associations and reports the first missing prerequisite; close return is not lifecycle acknowledgement. Accepted journal/adapters/verifier bytes remain unchanged. Root verified full input/mutation/SDK/receipt and post-run executable bindings. See the component checkpoint; no kernel process, finalization or campaign eligibility acceptance follows.

Private external journal decoder18/0 and three focused mutants1/1 each are independently reviewed. Actual Swift writer compatibility1/0 produced four files accepted and independently checked through the frozen decoder, with85 bound inputs/82 inherited journal inputs, exact SDK and complete owned-watchdog receipts. The diagnostic-width row is explicitly constructed, not process observation. Root also verified exact Python commands/CWD/membership and all mutation derivations; Python runs use ordinary bounded subprocesses. See the component checkpoint. No production parser, finalization, campaign eligibility or public campaign command follows.


Joined terminal driver checkpoint (2026-10-06): `python3 -B -m unittest discover -s Tests/SearchParentDriverIntegration -p 'test_*.py'` passes31 pure contracts; `scripts/test-search-parent-driver.sh` passes78 named cases (24 joined plus54 unchanged driver controls). The coordinator directly owns the accepted watchdog; never nest another session-owning wrapper. Frozen driver/lifecycle/lane transforms, complete membership and canonical SDK inputs are checked. A matching frozen full application/core snapshot passes847 tests and builds without warnings. Six finite private mutants discriminate the new mode/cleanup/preservation/publication guards. See `docs/verification/search-parent-joined-shutdown.md`. No actual helper, memory acceptance, cold finalizer, packaged desktop or user-facing supervised search follows.

Private epoch adapter checkpoint (2026-10-06): uninstrumented73/0 and counted77/0 pass; nine focused mutants terminate with explicit assertions and zero unexpected failures. Root audited exact103/109 input inventories,112 per mutant, four inherited SDK header pins, source-transform/mutation replay and complete direct-watchdog receipts/binaries. Counted tests use frozen-only entry counters/hooks, with original sources preserved and fixture cleanup excluded from adapter entry counts. Initial behavioral RED and review regressions, the counted snapshot compiler failure and audit-only parser corrections remain retained. Independent final review accepted opaque pre-outcome identity binding and one compact validated phase/drain owner only; no native query, helper, finalizer, memory or app-routing acceptance follows. See `docs/verification/search-campaign-components-2026-10-06.md`. There is still no public campaign command; do not nest another watchdog around the retained private coordinators.


Private cold finalizer checkpoint (2026-10-06): uninstrumented109/0 and counted121/0 pass; five focused mutants each terminate with6,2,1,1,1 explicit assertions and zero unexpected failures. Initial compiling RED6/18 preceded implementation; candidate source remains unchanged since GREEN. Root audited exact138/155 inventories,161 per mutant (pending replacement164), SDK4 header pins, original tests/dependencies, exact seam/mutation replay, complete direct-watchdog receipts and binaries. Counts precede fixture teardown. Independent final review accepts the one compact wait/cleanup/result owner only. Original pending joined evidence cannot be upgraded by later clean state; cancelled joining callers do not cancel the owner. No actual helper/native sampling, whole-cell publication, memory or editor-routing acceptance follows. See `docs/verification/search-campaign-components-2026-10-06.md`. Sources/evidence remain private; there is no public campaign command and no newer tested package. Never nest another watchdog around the retained private runners.


Private tiny input-schema checkpoint (2026-10-06): initial25/0 and corrective28/0 pass after a discriminating pre-encode root guard RED28/1, with original25 controls unchanged. Root audited exact40 final members/origins, command/interpreter/captures, minimal source replay and accepted decoder bytes; independent spec/quality rereview approved the fix. These pure Python runs use an ordinary bounded subprocess, not a process-group watchdog, and launch no helper. Task2 synthetic filesystem publication/read/32-FD checks remain unimplemented; no compiled-role, whole-cell, memory or public campaign acceptance follows. See `docs/verification/search-campaign-components-2026-10-06.md`.


Private initial tiny filesystem checkpoint (2026-10-06):49/0 initial controls and52/0 after a discriminating uncertain-close RED52/20 pass with actual synthetic files/descriptors and injected faults. Cleanup retires a descriptor before its sole close attempt; unknown acknowledgment stays charged/failed and never authorizes numeric retry or a clean closed/zero claim. Root audited65 exact members/origins, unchanged52 tests/fixtures/dependencies, command/interpreter/captures and actual frozen module resolution; scoped spec/quality review approved the initial scope. Full24-component/FD32/iterator/stream/race/fault matrix and Task3 mutants remain pending. Role work is128MiB per pass/256MiB for two full passes, with fixed64MiB/file limits; this is not memory/performance acceptance. See `docs/verification/search-campaign-components-2026-10-06.md`. No source adoption, helper, public campaign or new tested package follows.


Private complete tiny filesystem checkpoint (2026-10-06):109/0 (28 schema and81 boundary controls) passes with independent Task2 requirement mapping/spec/quality approval. Expanded groups passed63/0,83/0 and109/0; an iterator cleanup-acknowledgment regression produced RED86/16 then GREEN86/0 with all prior tests unchanged. Both enumeration reservations remain charged through the sole cleanup call; failure transfers them into sticky uncertainty, drains definite handles and never claims clean zero or retries a numeric descriptor. Root verified105 final members,95 preserved copies, exact commands/interpreter/captures and frozen imports. Actual maximum-depth native enumeration observed ledger31/native30 under cap32; this is not a total-process or memory bound. Task3 decoder variants and three finite mutants remain pending. Pure Python runs use ordinary bounded subprocesses, launch no helper and require no additional platform access. Source/evidence remain private; no public campaign command or new tested package follows. See `docs/verification/search-campaign-components-2026-10-06.md`.


Private tiny Task3 checkpoint (2026-10-07): the unchanged120-method baseline passes120/0 (109 inherited, three decoder bridge and eight safe read-guard methods). Three candidate-only frozen mutants each run one fixed method and produce2/1/5 expected assertion failures with zero errors/skips/timeouts. The literal omitted-size read is intercepted before forwarding through the authenticated borrowed-file guard; never run its unguarded discovery suite. Root audited each138-member packet/123 unchanged copies/all120 preserved methods, unique source replay, exact commands/CWD/interpreter/captures and frozen imports. Independent final review accepts Task3 and the private filesystem component only. Real Swift publication, role/helper/sidecar assembly, allocation comparison and production routing remain outstanding. Current synthetic-file tests need no extra testing access; future Accessibility permission remains user-owned. There is no public campaign command, source adoption or new tested package; see `docs/verification/search-campaign-components-2026-10-06.md`.

Searchable offline Help checkpoint (2026-10-08): `scripts/test-help-reference.sh` passes one frozen native XCTest covering the complete effective command reference, literal UTF-16 search, navigation/wrapping and unchanged read-only guide. The native coordinator pure suite passes40 tests. The shown Help viewport subset passes original size/scrolling assertions after its selector was corrected to the unique guide rather than the search field editor. Current full app/core848/0 passes; the desktop bundle builds, but Help XCUITest execution awaits user-owned macOS UI Automation authentication. The wrapper already owns its watchdog; never nest another session-owning watchdog. See `docs/verification/searchable-help.md` for retained RED, regression and scope limits. No complete H-09, VoiceOver or packaged desktop acceptance is implied.

Editable disk admission checkpoint (2026-10-08): full current core852/0 and focused50/0 pass. The matching-source `scripts/test-native-close-model.sh` selection with a verified debug directory passes198 factory checks,106 close checks and shared-pane ownership. The new frozen session suite passes12/0 using Root's direct accepted watchdog; a separate old disk-routing control fails3 intended startup assertions. This checkpoint did not execute or nest the legacy session-owning shell runner. Decoder refuses decodedNUL/four unsupported Unicode prefixes at fresh disk ingress; rawcodec/recovered/backup/history text remains lossless. See `docs/verification/binary-text-admission.md` for exact limits; dirty native Reopen, visible error presentation and broader binary classification remain outstanding.


Production worker accumulator checkpoint (2026-10-08): `scripts/swift.sh test --scratch-path .build/worker-accumulator --filter 'SearchWorkerUTF8AccumulatorTests|SearchWorkerAccumulatorRuntimeTests'` passes29 tests; `--filter SearchWorker` passes119 worker/resolver checks; the full matching app/core suite passes881/0. Root runs these through the checked-in direct owned watchdog, with600s for broad adversarial neighbors; do not nest existing coordinators. The first compiler exposed a macOS15-only initializer; strict-transcode validation/materialization preserves the macOS14 floor. A frozen Foundation BOM-stripping mutation fails1/1 against the unchanged literal Unicode oracle. These are concrete component/real wire-runtime checks, not helper process, editor routing, memory/performance or desktop acceptance. See `docs/verification/search-worker-accumulator.md`.

Checked lifetime startup (2026-10-08): `scripts/swift.sh test --scratch-path .build/lifetime-startup --filter 'SearchParentLifetimeStarterTests|SearchWorker'` passes133 tests; full app/core895/0 and pure search-child harness56/0 pass. Run broad SwiftPM under the checked-in owned-process watchdog. `scripts/test-search-child-lifecycle.sh --filter 'SearchParentLifetimeStarterTests|SearchChildLifecycleTests|SearchChildLauncherStateTests|SearchChildLifetimeStateTests|SearchChildDispatchTimerTests|SearchChildSpawnInheritanceFixtureTests'` passes104 frozen tests. Separately selected `--filter SearchChildLifetimeProcessTests` and `--filter SearchChildSpawnInheritanceTests` each pass one actual process check, with exact generation-qualified reap/channel closure and matching artifact bindings. The coordinator directly owns its watchdog; never nest another. See `docs/verification/search-lifetime-startup.md`. Helper executable, editor routing, hard regex containment, memory/performance and desktop acceptance remain separate.


Fixed production helper checkpoint (2026-10-08): public `PadSearchWorker` product
and `Contents/Helpers/PadSearchWorker` packaging are implemented. Proven commands:

```sh
python3 -m unittest discover -s Tests/SearchWorkerIntegration -p 'test_*.py'
scripts/test-search-worker.sh --build-only
scripts/test-search-worker.sh
scripts/test-search-worker.sh --application-bundle "$PWD/dist/TheOnlyPad.app"
python3 scripts/test-package-validation.py
python3 scripts/test-package-promotion.py
```

Coordinator20/0; built and final nested real-protocol selections each5/0 with all
owned receipts and exact source/helper/test-bundle/app bindings. The coordinator
directly owns each watchdog; never nest it inside another process-group watchdog.
Full public app/core895/0 and native ad-hoc package/signatures/archive/SBOM pass.
Package validation29/0 and promotion6/0 preserve original rollback controls; four
copied real-package cases independently refuse at checker and promotion while
preserving prior outputs. Helper tampering fails its direct signature check;
shallow app verification is separate, so explicitly verify both. Retained fixture
and harness corrections, hashes and scope are in
`docs/verification/search-helper-production.md`. Editor/folder search still run
in-process. Production parent collector/composition/admission, hard cancellation,
memory/performance and current desktop acceptance remain outstanding. No remote
publication, notarization or additional platform acceptance is claimed.


Production parent response accumulator checkpoint (2026-10-09): direct/codec32/0, neighboring173/0 and current full app/core927/0 pass warning-free. The new owner-thread collector retains compact request metadata, bounded ranges and strict scalar-complete UTF8; source scalar authentication remains the existing reader's responsibility. Real-helper factory now uses the production collector: `scripts/test-search-worker.sh --application-bundle "$PWD/dist/TheOnlyPad.app"` passes all five actual methods against the freshly packaged final nested helper, with ten direct-watchdog receipts, exact source/artifact/test-bundle bindings and sole consuming cleanup verified. All five exits use actual owned SIGKILL after result credit; this does not establish catastrophic-regex containment. Local package/archive/SBOM and explicit helper/app signatures pass. Full test command executed directly under the accepted watchdog: `python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/parent-response-integrated-owned -- scripts/swift.sh test --scratch-path .build/parent-response-integrated`. Do not nest another watchdog around the helper coordinator. See `docs/verification/search-parent-response-accumulator.md`. Default parent composition/admission/native routing, allocation/RSS and current desktop acceptance remain outstanding.


Production parent composition (2026-10-09): focused `SearchParentProduction`12/0,
neighbor331/0, pure runner32/0 and full public app/core939/0 pass. Run focused/full
Swift tests under the accepted direct owned watchdog as documented in
`docs/verification/search-parent-production-composition.md`. Fresh package/checker
and explicit strict helper/app signatures pass. `scripts/test-search-worker.sh
--application-bundle "$PWD/dist/TheOnlyPad.app"` passes six actual methods using
91 matching sources/two generated inputs and eleven direct watchdog receipts;
never wrap this coordinator in another session-owning watchdog. Five observed
shared-recipe methods retain exact PID/owned signal/sole consuming reap/session
release. The sixth ordinary constructor method has genuine logical joined
cleanup and no PID/reap counters; never transfer observed counts to it. Production
admission accounting/retry and native search routing remain outstanding. Final
independent checkpoint review approves the scoped local commit; no new desktop, hard-regex,
RSS/performance or physical release acceptance is inferred.


Production admission collaborators (2026-10-09): standalone checked logical
accounting and default cancellable main-queue retry now pass focused23/0, frozen
neighbor357/0 and full public app/core962/0, warning-free. Both public executables
link; existing controller, driver, native routing, manifest and original tests
remain unchanged. Source/test reviews approve the components; independent final checkpoint
evidence review also approves the scoped local commit. Full command executed under the
sole direct owned watchdog:

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/admission-production-full-owned -- scripts/swift.sh test --scratch-path .build/admission-production-integrated
```

Use fresh watchdog output paths. Strict recursive Swift formatting and
public-source checks pass. Logical content allowances are not RSS/capacity or a
process-global budget; default retry delay is25ms and dropped/cancelled tokens do
not certify physical queue release. Current distribution remains source4841d89.
Legacy admission shutdown still prevents joined service cleanup; terminal ownership
and native search routing remain next. See
`docs/verification/search-admission-production-collaborators.md`. No new helper
process, desktop, hard-regex, memory/performance or unavailable-platform acceptance.


Joined admission terminal checkpoint (2026-10-09): implementation and source/test reviews cover retained joined ownership, raw parent diagnostics, genuine helper-return fencing and residual borrow credit. Fresh exact public-package selection passes993/0 and links app/helper; native10 and unchanged native3 pass separately. `scripts/test-search-admission-joined-native.sh` directly freezes and runs all10 hidden AppKit cases (8 admission +2 retirement); it explicitly requires macOS26/Swift5 test host while public app floor14 remains. Pure runner command `env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/SearchAdmissionJoinedNativeIntegration -p 'test_*.py' -v` passes52. Neither native coordinator may be nested under another process-group watchdog. Two copied native controls reach14/15 intended assertion failures with genuine cleanup; actual-parent held-read control reaches2. The initial full frozen snapshot failed one existing example test because its resource was omitted; corrected exact-resource snapshot passes993/0. Task2 and final whole-branch SPEC/QUALITY/evidence/documentation/privacy reviews approve the scoped checkpoint; the local commit remains pending. See `docs/verification/search-admission-joined-terminal.md`. Native/editor service composition, helper routing, GUI, physical input and memory/performance acceptance remain separate; editor search stays in-process.


Fixed admission service Task1 (2026-10-09): the thin MainActor `SearchAdmissionService<Context>` facade is implemented and component-tested, building on committed joined source `42513c0`. Authenticated absent-API compiler RED is followed by focused6/0 and required neighboring7 classes96/0. Two copied actual-facade controls reach exactly3 raw-parent and2 current-settlement assertions; all6 methods finish, other5pass, with genuine cleanup and no unexpected/warning/skip/timeout failures. Fresh matching public package999/0 binds399 inputs in28.200549s and builds both executables without launching them. Retained recursive strict formatting passes with394 matching inputs and empty captures; all498 protected existing source/test/script/manifest bytes and modes match. Final independent source/evidence review approves Task1; scoped local commit remains pending at this record. See `docs/verification/search-admission-service.md` and the reviewed service spec/plan. Ordinary package compiler contracts, actual fixed constructor/missing-helper behavior, native facade callbacks and real helper via facade remain planned; constructor/client/runner preparation remains source-only and unexecuted. No new public command is established. Editor search remains in-process; distribution stays4841d89, UI Automation authentication is user-owned and pending. No new desktop, hard-regex, memory/performance or whole-product acceptance follows.


Fixed admission service Tasks2/3 checkpoint (2026-10-09): Task1 is committed at `5b5ad8c`; its full public999/0 remains separate prior evidence. Task2 final independent source/evidence review accepts the fixed constructor/compiler/runner scope. `scripts/test-search-admission-service.sh` passes its corrected matching default: pure50, one ordinary sibling compiler client, five separate expected-negative clients and constructor4/0, with11 strict receipts and97 origins/522 copies/6 generated manifests. The separately authenticated copied eager-entry control has raw exit1 with1 intended assertion/0 unexpected; its coordinator exits0, with4 receipts and87/89/2 bindings. Earlier pure/parser/eager fixture failures remain retained and uncredited as intended RED. `scripts/test-search-admission-service-native.sh` now has an actual exit0 run: pure51 and exactly2 hidden native facade cases/0 failures, with90 origins/90 copies/1 generated manifest, all5 receipts and the actual XCTest artifact audited. It uses an isolated macOS26/Swift5 host; public deployment floor14 is unchanged. Capture refusal preserves admission, and joined calls inside a real native result borrow retain credit until actual outer return; the backend is scripted, with no helper or shown windows. The earlier native2/1/0 run remains preserved and uncredited. Task3 final independent source/evidence review accepts these two scripted native cases. The Task2/3 test/runner checkpoint is locally committed at `0f7c96e`. Both coordinators own their watchdog directly; never nest another process-group watchdog. Task4's exact corrective normative supplement is source-approved and adopted; ABI/prototype/fixture/finite-cleanup/runtime gates remain unaccepted, with no observer implementation or prototype/runtime proof. See `docs/verification/search-admission-service.md`. This entry supersedes earlier Task1 pending-commit and later-task preparation states. Editor search remains in-process; distribution stays `4841d89`; UI Automation authentication remains user-owned and pending. No new full-suite result, helper routing, desktop, hard-regex, memory/performance or additional-platform acceptance follows.

Prepared UTF-8 component (2026-10-09): the internal synchronous decoder and fixed UTF-16 builder have compiler RED followed by17/0, matching public neighbors122/0 and full1016/0 (prior999 retained plus17). Three copied defects cause exactly one failed method each, with1/4/2 intended assertions and0 unexpected errors; complete watchdog receipts and source/artifact bindings are verified. The initial mutation result-parser infrastructure failure remains preserved. Final independent specification, quality, evidence and cleanup review accepts the bounded inactive component. The actual contributor command below passes17/0; choose a fresh output directory when repeating it. It builds the public package without showing windows or launching a helper. See `docs/verification/search-prepared-utf8-decoder.md`. Caller admission, producer/worker integration and accounting formula/RSS acceptance remain separate; editor search stays in-process.

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/search-prepared-utf8-public-command/owned -- scripts/swift.sh test --scratch-path .build/search-prepared-utf8-public-command --filter SearchPreparedUTF8DecoderTests
```


Same-ledger pair component (2026-10-09): `scripts/swift.sh test --scratch-path .build/search-reservation-pair-public --filter 'SearchAdmissionReservationPairTests|SearchAdmissionLedgerTests'` passes23/0 (new9 plus unchanged legacy14). Matching frozen public neighbors125/0 and full1,025/0 preserve all prior1,016 methods. Three reviewed finite source controls fail as intended with all9 methods completed and0 unexpected failures: rollback4 assertions/2 methods, producer guard3/1, token alias20/8. Source snapshots, artifacts and direct owned-process receipts were verified; recursive strict format/public checks pass. This internal unused primitive adds synchronous paired admission/rollback and independent retirement only; producer/formula/worker/helper/editor/native/memory/desktop integration remain separate. See `docs/verification/search-reservation-pair.md`. Broad adversarial suites still require the accepted direct watchdog; never nest session-owning watchdogs.


Prepared file reader component (2026-10-09): the inactive synchronous Input/I/O/Reader implementation has authentic compiler RED followed by unchanged16/0. Matching frozen public neighbors141/0 and full1,041/0 preserve all prior1,025 methods; app/helper builds pass without launch. Three copied actual-reader faults finish all16 tests and reach52/2/13 intended assertions across6/1/2 failed methods, with0 unexpected failures. The actual focused public command below passes16/0; exact source/artifact/direct-watchdog receipts and whole-candidate strict formatting were verified. Final independent component acceptance remains pending at this record. See `docs/verification/search-prepared-file-reader.md`. Concrete Darwin I/O, admitted producer/worker, task-return/quarantine, helper/editor routing, memory and desktop acceptance remain separate. Editor search remains in-process, distribution4841d89 unchanged.

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/search-prepared-file-reader-public-command/owned -- scripts/swift.sh test --scratch-path .build/search-prepared-file-reader-public-command --filter SearchAdmissionFileReaderTests
```

Use a fresh output directory when repeating; never nest this direct process-group watchdog.


Prepared reader final review supersedes the pending state above: independent specification, quality, evidence, cleanup and privacy review accepts this inactive component and its matching tests. The source-only native adapter recipe still requires authentic compiler RED and separately reviewed implementation/GREEN before concrete acceptance. No producer, editor or memory/desktop acceptance follows.


Concrete prepared-file Darwin adapter checkpoint (2026-10-09): `scripts/test-search-admission-file-darwin.sh` passes nine separately packaged native tests against frozen actual sources. `/usr/bin/python3 -B -m unittest discover -s Tests/SearchAdmissionFileDarwinIntegration -p test_runner.py` passes35 runner tests. A separate fresh integrated core suite passes1,041 tests and the app/helper build passes; neither executable was launched by these build checks. All exact source/artifact and complete direct-watchdog receipts were independently reviewed. The native wrapper owns its watchdog directly; never nest it inside another session-owning watchdog. See `docs/verification/search-prepared-file-reader.md` for finite fixture coverage and reproduction. The internal adapter remains inactive in production; asynchronous admission ownership, supervised editor search, hard cancellation, memory and current desktop acceptance remain outstanding. Raw synthetic evidence stays ignored.

Application search owner checkpoint (2026-10-10): `scripts/test-application-search-owner.sh` passes all sixteen original component tests against frozen current sources. It accepts no arguments, owns its watchdog directly and must not be nested under another process-group watchdog. A separate fresh public package passes 1,041 existing tests and builds both app and helper without warnings. Different actual reviews authenticate sources, objects, link inputs, artifacts and complete cleanup receipts. The new owner and closure adapter compile in the application but remain inactive; native source construction, panel/AppDelegate routing and supervised editor search are outstanding. No new GUI, packaged runtime, physical input, memory or hard-regex acceptance follows. See `docs/verification/application-search-owner.md`. Raw synthetic evidence remains ignored; distribution stays source `4841d89`.

Windows plugin feedback (2026-10-11): the integrated public manifest builds the actual app and passes 1045 tests after adding four catalog controls (13 focused total). Full suite command: `scripts/swift.sh test --scratch-path .build/extension-windows-integrated-20261011`, executed through the direct owned-process watchdog; use the guarded fresh-directory reproduction in `docs/verification/windows-plugin-feedback.md` for broad adversarial tests. The unchanged hidden extension harness also passes against the matched controller and 50 Core objects. This is not visible chooser/error, packaged desktop, physical input or platform-14 runtime acceptance. No new release/package is claimed.

Checkpoint preparation deferral (2026-10-12): `scripts/test-application-session-checkpoints.sh` now passes23 tests (original18 plus5 close-deferral regressions); `scripts/test-application-document-intake.sh` passes26 and `scripts/test-application-document-closing.sh` passes20. The two publisher/intake source inventories include the original `DocumentClosingBoundary.swift`. Frozen compatibility55/0 and a matching private controller/scheduler native conjunction6/0 pass separately. See `docs/verification/checkpoint-close-deferral.md`; these do not establish visible desktop or complete macro/transfer adoption. Existing Foundation script timeout receipts are unchanged.


Custom-language store/lexer component checkpoint (2026-10-12): matched store/compatibility104/0, lexer/language35/0 and separate real post-publication readback faults2/0 pass. The reviewed formatted public package passes 1,122 tests and builds app/helper without warnings with 435 unchanged input hashes. Use the fresh-directory direct-watchdog commands in `docs/verification/custom-languages-components.md`; do not nest another process-group watchdog. Strict parser, stable revisions, loaded-read receipts and bounded cancellable literal spans are implemented as core components. Native editing policy, catalog owner/manager/picker, persistence/transfer/highlighter integration and desktop acceptance remain outstanding. A readback receipt does not prove written-inode ownership; logical lexer limits do not establish RSS or input latency. No new package/release is claimed.

Custom-language editing core checkpoint (2026-10-12): the authentic45-test baseline reaches99 ordinary failures; the reviewed implementation passes54 focused tests. After formatting, the current application passes1,143 tests and builds app/helper warning-free under the checked-in direct owned-process watchdog with474 unchanged input hashes. Reproduce using fresh output/scratch paths and the commands in `docs/verification/custom-language-editing.md`; do not nest another watchdog. Profile comment rules and bounded selection-aware indentation are implemented as core APIs. Native Tab/admission/undo, session selection, manager/highlighter and desktop acceptance remain outstanding. Logical4,096-unit cancellation polling is not allocation/RSS or latency evidence. No new package or release is claimed.


Native macro and custom-language session working-tree checkpoint (2026-10-12):
`scripts/test-native-macro.sh` passes 19 unique hidden native cases; the shared
runner's `python3 -B -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py`
passes 50 pure controls. The coordinator freezes the actual graph, appends five
declared test-only access payloads and directly owns its watchdog; never wrap it
in another session-owning watchdog. No windows are shown or input posted. The
reviewed ten-file native implementation, two Foundation fixture updates and
seven public harness files are adopted locally.

Core session version 3 preserves authoritative custom-language IDs, while
automatic/built-in choices retain canonical version 2. The reviewed component
passes 35 tests after an authentic 35-test/51 ordinary-failure baseline. The
current formatted working-tree snapshot passes 1,159 default SwiftPM tests and
builds app/helper warning-free with warnings as errors and 484 unchanged frozen
inputs. The following build is incremental; native19 is a separate result, not
part of the default SwiftPM count. This record describes the verified local source.
Use fresh, isolated-state direct-watchdog commands in
`docs/verification/custom-language-session-codec.md` and see
`docs/verification/native-macro-recording.md` for the supported native scope.
Native custom-language propagation/manager/missing-profile UI, visible macro
workflows, broader lifecycle, physical IME/VoiceOver and current packaged desktop
acceptance remain outstanding. No package or release is claimed.

Packaged desktop checkpoint (2026-10-12): source `f45f1e9` passes local ad-hoc
package/archive/SBOM validation and five selected actual XCUITests, with zero
failures or skips after the user confirmed the desktop was unlocked. The prior
zero-case automation timeout remains recorded. The matching public 1,159-test
suite and hidden native19 selection are separate evidence. See
`docs/verification/packaged-desktop-2026-10-12.md` for exact selected identifiers,
artifact hashes and scope. `scripts/test-desktop-ui.sh` defaults to the broader
suite; this result does not certify all eighteen desktop methods. Private native
custom-language state/catalog/highlighter candidates, physical macro workflows,
IME/VoiceOver/AXPress and other platforms remain unaccepted. No remote release
was published. This supersedes earlier current-packaged-desktop outstanding
notes only for these five workflows.

Catalog inspection component checkpoint (2026-10-12): five actual temporary-file inspection tests and the matching 35-test store/codec/revision/readback conjunction pass. The formatted current application candidate passes 1,164 tests with zero failures, unexpected errors or skips, and a cold test dependency build of the app/helper with warnings treated as errors; the following build is incremental confirmation. Independent full-run audit accepted this Core-only scope. The scope is the Core inspection addition and its five tests; original load/save source is unchanged. Inspection never writes. Future/unknown schemas and parser-invalid or duplicate-key input cannot gain a repair token. Repair/retry, native owner/policy/manager activation and new packaged desktop acceptance remain outstanding. See `docs/verification/custom-language-catalog-inspection.md`; raw evidence is ignored.

Adopted-tree focused inspection confirmation also passes five tests. Exact inner invocation, executed under the owned watchdog:

```sh
env NSUnbufferedIO=YES scripts/swift.sh test --scratch-path .build/catalog-inspection-public --filter CustomLanguageCatalogInspectionTests -Xswiftc -warnings-as-errors
```


Catalog repair/evidence component (2026-10-12): actual synthetic-file repair, original pending-evidence validation and exact-byte republication pass 47 focused tests, including all original 30 store/codec/revision/readback tests. The formatted full current app/helper candidate passes 1,176 unique tests with zero failures, unexpected errors or skips and warnings treated as errors. The test dependency build was cold; the following same-scratch build was incremental confirmation. Original load/save and inspection source remain unchanged. Repair requires a genuine known-format token and unchanged owned endpoint; validation returns no publication acknowledgment; retry writes the original attempted bytes without advancing generation/revision. Readback-unconfirmed outcomes lack pending evidence. See `docs/verification/custom-language-catalog-repair.md` for retained RED results, source review, read-only/fault coverage and limits. Owner recovery, native policy/manager activation and new packaged desktop acceptance remain outstanding.


Adopted-tree repair/evidence confirmation passes twelve tests. Exact inner invocation, executed under the owned watchdog:

```sh
env NSUnbufferedIO=YES scripts/swift.sh test --scratch-path .build/catalog-repair-public --filter 'CustomLanguageCatalogRepairTests|CustomLanguageCatalogEvidenceTests' -Xswiftc -warnings-as-errors
```


Pane runner repair checkpoint (2026-10-12): `scripts/benchmark-panes.sh` now derives the matching SwiftPM package identity and links SearchExecution for its full native source set. The actual restored command passed three visible 1 MB multiline cases with 20 samples each under the direct owned-process watchdog. The edit/display p95 proxy was 78.147/80.013/127.807 ms; this is not application typing-latency acceptance. Full matrix, long-line and larger-file acceptance remain outstanding. Run only with exclusive build/GUI ownership; see `docs/verification/shared-pane-performance.md` for source, failure chronology and limits.


Standalone profile transfer: `scripts/swift.sh test --scratch-path .build/profile-transfer-integration --filter LanguageProfileTransferTests -Xswiftc -warnings-as-errors` passes 14 real-file Core tests. The exact formatted candidate also passes the current 1,190-test app/helper suite and builds with warnings as errors under the owned watchdog. Imports enforce the 64 KiB metadata limit before matching reads; exports create exclusively and retain genuine joined success/uncertainty after late cancellation. This does not establish manager UI, native custom-language editing, packaged desktop or performance acceptance. See `docs/verification/custom-language-profile-transfer.md`.


Managed startup routing repair (2026-10-13): `scripts/test-managed-admission.sh` selects four exact hidden actual-owner/startup/callback tests, freezes the full native graph and directly owns its watchdog. The same formatted candidate passed all36 including original32 routing regressions, complete app/helper1190/0, and separate projection20, macro19 and real close-owner5. `python3 -m unittest discover -s Tests/NativeIntegration -p 'test_*.py'` passes54 pure runner checks. Never nest another process-group watchdog. This preserves installed current routes and cleans revoked membership; it does not activate private custom-language manager/comment candidates or establish desktop acceptance. See `docs/verification/native-managed-admission.md`.
