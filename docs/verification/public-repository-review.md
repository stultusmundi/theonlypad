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

Checkpoint package audit: intermediate82132 executable899d19 contained128 ASCII volume-path markers in linker debug-map metadata. A real check-package.py run rejected it. An owned strip -S probe removed those markers, then packaging was changed to strip only the staged distributable before signing, preserving the original local build output. Final24772 executable SHA256 ed55142031206a0048a0ac806e979baf62c3ab7505801a77e95252608b8777fb passed strict ad-hoc signature verification, exact six-file ZIP/bundle comparison, final SBOM hash, safe archive paths and the specified ASCII marker scan. Checker runs before promotion. Six promotion tests passed. Independent source review found no material issue; these are narrow artifact/privacy checks, not a general secret scan or packaged runtime test. At that checkpoint, packaged desktop acceptance was blocked by macOS UI automation authentication. Later actual packaged results are recorded in [September30 desktop verification](packaged-desktop-2026-09-30.md).

Visible-pane package8023 has executable SHA256 `99c723708461eb02424019127fc4a200f2aa18ae2e9f695f7c478fec4e59ae97`. Release build, strict ad-hoc signature, exact six-file archive/bundle matching, final SBOM hash and narrow ASCII marker checks passed. A source import inventory found the existing UniformTypeIdentifiers system API missing from notices/SBOM metadata; both now list it, and the package was regenerated to include the corrected notices. No external dependency or asset was added. At that checkpoint, desktop tests compiled but execution was blocked on authentication; that package had no packaged workflow acceptance claim. Later package evidence is separate and does not retroactively verify this binary.

## Current source and workflow review — 2026-09-10

A source-based review confirmed that the current Swift package declares no external SwiftPM dependencies. The packaged inventory documents original MIT code/artwork, macOS-provided frameworks and no bundled third-party assets. The installed automated supply-chain collector does not support Swift; no package-advisory scan or clean vulnerability verdict is claimed.

CI uses immutable [checkout v4.2.2](https://github.com/actions/checkout/commit/11bd71901bbe5b1630ceea73d27597364c9af683) and [dependency-review v4.7.3](https://github.com/actions/dependency-review-action/commit/595b5aeba73380359d98a5e087f648dbb0edce1b) revisions. Their pinned [checkout license](https://github.com/actions/checkout/blob/11bd71901bbe5b1630ceea73d27597364c9af683/LICENSE) and [dependency-review license](https://github.com/actions/dependency-review-action/blob/595b5aeba73380359d98a5e087f648dbb0edce1b/LICENSE) are MIT. Read-only repository permissions, disabled checkout credential persistence and ordinary pull-request triggers remain unchanged; there is no workflow secret mapping, release or signing job.

The review found and resolved one CI coverage gap: the workflow now invokes the pure search-child watchdog/harness tests and the frozen deterministic lifecycle harness. Those commands have local execution evidence; hosted CI has not been run or claimed. Real channel/helper fault tests remain separately gated. Contributor guidance, private vulnerability-reporting instructions, templates, version-support policy and README limitations were reviewed without another material finding in this scope.

The public-source checker remains limited hygiene. History-wide secret scanning, remote advisory-reporting availability, final release-candidate review, and broader application security acceptance remain outstanding. Exact private findings and source provenance are retained in `.local/public-repository-current-review.md`; this review did not inspect or publish raw diagnostics or personal data.
