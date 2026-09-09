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

An earlier packaged build passed actual XCUITests for native open/edit/save/Command-Q/relaunch/reopen and scratch-buffer quit/relaunch recovery, using isolated synthetic state. Those results do not apply to the current shared-pane package, whose desktop execution awaits macOS automation authentication. Broader GUI, physical IME and VoiceOver acceptance remain outstanding. Launch the local bundle with `open dist/TheOnlyPad.app`. Never use real documents in harnesses. The native integration harnesses intentionally SIGKILL their own child to test recovery; the separate desktop UI script uses Xcode's actual XCTest runner and keeps raw diagnostics under ignored `.local/desktop-ui`.

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

While GUI access is pending, do not launch visible harnesses or repeat desktop authentication attempts. Continue independent hidden/native and core verification and record the distinction.

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

`scripts/test-document-factory.sh .build/adoption-close-integrated/arm64-apple-macosx/debug` passed 122 hidden factory checks plus the shared-pane ownership control. Use a verified core build; native intake routes remain unmodified.

`scripts/test-application-session-checkpoints.sh` passed 18 real-store publisher tests. The extracted legacy AppDelegate initializer builds; native managed activation remains outstanding.

`scripts/test-application-document-intake.sh` passed 16 process-owner tests, including actual startup publisher integration and a paired receipt/reload. Native controller routing remains separate.

`scripts/test-native-close-model.sh .build/adoption-close-integrated/arm64-apple-macosx/debug` passed 106 close-model checks plus factory/shared controls; process-close suite now passes 20 tests with pre-await repair context. Complete native close admission remains outstanding.

`scripts/test-document-history.sh` passed 49 registry/history tests. History claims retain close-time source identity and require active replacement before consumption; native reopen remains separate.
