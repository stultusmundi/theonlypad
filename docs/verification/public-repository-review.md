# Public repository and artifact review

Date: 2026-09-09. Reviewed local checkpoint `3c70180`. This is a limited source/artifact review, not a completed security audit or permission to publish.

## Observed implementation

- `LICENSE` retains MIT. `docs/third-party-notices.md` identifies original source/artwork, Apple system frameworks and the absence of bundled third-party packages/assets. `Package.swift` has only internal targets and no external dependency resolution; there is no external SwiftPM lockfile to generate. Ignored engine spikes are not application dependencies.
- `SECURITY.md` documents the pre-release support policy, a private GitHub advisory URL and a fallback requesting a private contact without disclosing vulnerabilities. Remote availability of private reporting has not been tested. `CONTRIBUTING.md`, issue templates and the PR template are present.
- The repository-local commit identity uses a GitHub noreply address. This review did not modify global git identity or print private identity information.
- CI uses read-only repository permissions, SHA-pinned checkout/dependency-review actions and no persisted checkout credentials. There are no privileged pull-request triggers, release jobs, signing credentials or upload steps. Upstream pin evidence is in `ci-provenance.md`; hosted execution remains unverified. Source pattern checking is limited, and comprehensive secret scanning remains outstanding.
- README explicitly describes an incomplete development build, untested platforms, ad-hoc signing and outstanding features. No updater, telemetry or cloud service is implemented or advertised. The official manual is cited as a behavioral reference, without redistributed Notepad++ assets.

## Actual local artifact checks

The reviewed `dist/TheOnlyPad.app` contained six files: Info.plist, the executable, original icon, MIT license, third-party notices and ad-hoc signature metadata. Its archive had eleven directory/file entries and no absolute paths or parent-traversal components. No recovery data, test fixtures, diagnostics or engine-spike resources appear in that inventory.

The reviewed development SBOM executable SHA-256 matched the packaged binary: `4654c5fc0744d6b4e094c2f7cd35b3257656866db91f34eab3ca15cc01fe18cf`. A local `strings` marker check found zero machine-home or repository-volume path markers in this binary. This narrow check does not prove the absence of all sensitive information. The package remains ad-hoc signed, without Developer ID or notarization. See `xcuitest-feasibility.md` for actual desktop tests of this exact binary.

No remote push, release, merge or publication was performed. Remaining work includes comprehensive secret/history scanning, full source/distribution security review, clean-machine reproducibility, hosted CI verification, and final dependency/provenance review after the engine and feature scope are complete.

A later development package was generated with additional verified source changes. This inventory review applies to the exact hash above; later artifact verification must record its own hash and inventory.

## Subsequent package inventory

The later package with executable SHA-256 `0324726fcc89fbb0b54670efe713f7246ba23572ef4ae7e48c1a0f2e77a73526` was independently checked: the same six bundle files and eleven archive entries, no absolute/traversal archive paths, matching archive executable and SBOM hashes, and zero home/volume markers in the narrow binary strings check. Ad-hoc signing remains the only signing performed. Its first expanded desktop run passed four of six tests; desktop findings and reruns are tracked separately. Inventory success does not imply application acceptance.

## Save-publication package inventory

The rebuilt save-publication package has executable SHA-256 `a2d3e80e2bef8ac9bba9402191a31ef8b2486128fbb01539e754d686a4834a9f`. Its six bundle files and eleven archive entries were checked again: no unsafe archive paths; executable/ZIP/SBOM hashes match; narrow binary marker scan found zero home/volume markers. Local release build, plist validation and ad-hoc signature verification passed. Desktop tests of this exact binary are running; no Developer ID or notarization claim is made.
