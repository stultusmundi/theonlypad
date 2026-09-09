# Local packaging verification

## Latest verified artifact

Source checkpoint `b25a07a` was packaged on2026-09-09 after shortcut customization and the presentation-refresh fixes passed core and hidden integration checks. `scripts/package.sh --ad-hoc-sign` (session65473) exited0; release compilation took21.82seconds. Independent post-promotion `python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json` and `codesign --verify --strict dist/TheOnlyPad.app` also passed. Private build log: `.local/shortcut-package.log`.

Executable SHA256: `93111f08c1cd8ba884aedefa24ed01c2944919217c04815c0560087fb7be8284`. App, ZIP and development SBOM are in `dist/`. Checks covered6bundle files, exact archive/bundle contents, executable SBOM hash, safe archive paths and specified ASCII machine-path markers. This is a local ad-hoc ARM64 build, with no DeveloperID/notarization/publication. No external dependency or asset was added.

Current packaged desktop execution remains blocked by GUI access and macOS UI Automation authentication. Earlier workflow passes apply only to their recorded historical binary hashes; this package has no desktop workflow acceptance claim. Reload/Copy, Locate and shortcut XCUITest sources passed build-for-testing only. See [shortcut evidence](keyboard-shortcuts.md), [presentation refresh](presentation-refresh.md) and [file monitoring](external-file-monitoring.md) for the exact core/hidden-native scope. Previous package `eaf5145` had executable hash370926fd…; it is historical. The following sections retain earlier packaging development evidence.

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
