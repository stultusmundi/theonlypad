# Local packaging verification

## Latest verified artifact

Source checkpoint `6c7fb68` was packaged on 2026-09-10 from an isolated `git archive` snapshot, so concurrent recovery-close development could not enter the artifact. `scripts/package.sh --ad-hoc-sign` exited successfully; release compilation took 25.23 seconds. The generated bundle/archive/SBOM passed independent validation and strict deep signature verification before promotion to `dist/`, and both checks passed again after promotion. Private build log: `.local/pane-package-build.log`.

Executable SHA-256: `6c818622cdce7c595ddea76183768768ea18f11d42c34b1f0d609cb48328b4b6`. Outputs are `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip` and `dist/TheOnlyPad.sbom.json`. Checks covered all six bundle files, exact archive/bundle contents, executable SBOM hash, safe archive paths and specified ASCII machine-path markers. This is a local ad-hoc ARM64 build, without Developer ID, notarization or publication. No external dependency or asset was added.

This package includes verified pane persistence and the view-free document registry, whose native transfer/close integration remains outstanding. See [pane evidence](persisted-pane-presentation.md) and [registry evidence](document-registry.md). Current packaged desktop execution remains blocked by the locked screen and unavailable UI Automation access; desktop test sources compile only. Earlier workflow passes apply only to their historical binary hashes. The previous `b25a07a` package with executable `93111f08…` is historical. The following sections retain earlier packaging development evidence.

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
