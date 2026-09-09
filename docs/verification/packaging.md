# Local packaging verification

## Latest verified artifact

Source checkpoint `fdf0b3c` was packaged on 2026-09-09 after the exact dirty optimization passed the full native suite and the external decoder passed all 263 core tests. `scripts/package.sh --ad-hoc-sign` (local session 13719) exited 0; release compilation took 19.12 seconds. A separate post-promotion `scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json` also passed.

Executable SHA-256: `2ce6bc8feb840c2fbfc0d32a3c6c924f668d66ffbdf64e8b24e6e1f24a8bb710`. The app, ZIP and development SBOM are in `dist/`. Verification covered six bundle files, exact archive/bundle contents, executable SBOM hash, safe archive paths and the script's narrow machine-path markers. This remains a local ad-hoc ARM64 build, without Developer ID or notarization. No external dependency or asset was added. The file-monitor service/native actions are not integrated.

Current packaged desktop execution remains blocked by macOS UI Automation authentication. Earlier workflow passes apply only to their recorded historical binary hashes; this package has no packaged workflow acceptance claim. The following sections retain historical packaging development evidence.

## Implemented

`scripts/package.sh [--ad-hoc-sign]` builds the release configuration, constructs a native `.app`, copies the MIT license and third-party notices, validates its property list, optionally applies and verifies an explicit ad-hoc signature, and produces a ZIP using macOS `ditto`.

Bundle name, identifier and version come from executing `Sources/PadCore/AppIdentity.swift` in a temporary metadata helper. Minimum macOS comes from the package manifest. The numeric prefix of the development version becomes the standard bundle version, while the complete development version remains in the bundle information string and archive filename.

Outputs are generated beneath ignored `dist/`; no credentials or signing identity lookup is involved. Ad-hoc signing does not establish a Developer ID identity or notarization and is intended for local development. No remote publication occurs.

## Tested

On 2026-09-09, `scripts/package.sh --ad-hoc-sign` completed the release build and generated:

- `dist/TheOnlyPad.app`
- `dist/TheOnlyPad-0.1.0-dev-arm64.zip`

`sh -n scripts/package.sh` passed. `plutil -p dist/TheOnlyPad.app/Contents/Info.plist` confirmed identifier `org.theonlypad.editor`, numeric bundle version `0.1.0`, development version `0.1.0-dev`, minimum macOS `14.0`, the expected executable, and text/source document associations. `file dist/TheOnlyPad.app/Contents/MacOS/TheOnlyPad` identified an arm64 Mach-O executable. The packaging script's `codesign --verify --strict` succeeded; signature inspection showed `Signature=adhoc` and no TeamIdentifier. `unzip -t dist/TheOnlyPad-0.1.0-dev-arm64.zip` passed. The ZIP excludes Finder/resource-fork extended metadata.

The initial attempt caught a concurrent API integration failure; after the editor API landed, the actual release build passed. This report records the later successful result, without treating the earlier failure as a completed package.

## Outstanding

Launch was deliberately left to the main integration work using isolated application state; this packaging task did not launch or automate the GUI. Clean installation on another machine, Intel packaging, signing with a Developer ID identity, notarization, Gatekeeper acceptance for a downloaded distribution, and real packaged editing/recovery workflows are separate checks and are not implied by a local build.

## Later integrated artifact

The current app/ZIP rebuilt successfully after CLI, extensions, folder search, conversions and macro-safety integration. CFBundleURLTypes contains the centralized local-file scheme and codesign strict verification passed. A LaunchServices smoke is recorded in packaged-launch.md. Review found promotion ordering could leave mixed artifacts after an SBOM failure; the packaging worker is implementing staged generation and failure-consistent promotion. Reverify the packaging script after that change; artifact existence is not full acceptance.
