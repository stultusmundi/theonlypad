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

The harness freezes actual sources and invokes the reviewed owned-process watchdog directly for each build/test stage. Do not wrap it in another process-group watchdog. Its current default suite has 32 deterministic lifecycle tests; it does not yet validate a real helper or channel implementation. Raw evidence stays under ignored `.local/search-child-integration/`.

Injected channel state: `scripts/test-search-child-lifecycle.sh --filter SearchChildChannelStateTests` passes20 tests; the unchanged default lifecycle filter passes32 using the same frozen source manifest. The channel initializer requires explicit descriptor/source collaborators and verified adoption preconditions. No concrete adapter, actual pipe, helper or production routing is established by these tests. See `docs/verification/search-child-lifecycle.md`.

Native runner prerequisite is verified: `scripts/test-native-close-model.sh` now builds a frozen matching application itself; no build-path argument is required. Transfer/projection/close share the accepted same-process watchdog coordinator with exact input inventories. Pure contracts: `python3 -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py` (26 passed). See `docs/verification/native-regression-runners.md`. Never wrap these coordinators in another session-owning watchdog.
