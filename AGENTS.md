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
