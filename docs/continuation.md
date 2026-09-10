# Continuation

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and exact next action

Branch `build/native-editor`. Existing-window transfer integration is implemented and independently reviewed, pending its local commit and package refresh. The same native model/storage/undo/recovery authority moves through the process registry; captured destination identities and presentation generations reject stale completions. Endpoint-loss retry preserves file bytes, monitor continuity and newer edits. New-window destinations, groups, streaming and the remaining full brief are still outstanding.

Final frozen source: `.local/native-transfer-reviewed-integrated/source-provenance.json`. All 364 source/test/runner files match the working tree. App/core build: 10.86 seconds. Fresh tests: 404 core/0 (15.923s), 71 managed native/0 (5.881s), 11 actual transfer/0 (3.343s), 9 controller projection/0 (1.168s), 3 actual command/presentation/0 (0.404s), native bindings compile/runtime zero (44 checks). Logs: `.local/transfer-reviewed-{core,managed,owner,projection,chooser,bindings}.log`. Separate final process/registry snapshot `.local/native-transfer-final-integrated` passes 15 process/0 and 62 registry/0; it precedes only the final AppDelegate focus guard.

Exact next actions:

1. Legacy monitor compatibility passed (`.local/transfer-reviewed-monitor-lifecycle.log`, exit zero). Source formatting, public-pattern check and git diff check pass. Do not repeat broad tests without a change/failure.
2. Record final checks, commit the scoped reviewed integration locally, package from that committed source in an isolated private snapshot, verify archive/SBOM/hash/signature before promotion. Do not launch the app while console access remains blocked. Current dist still points to the older source listed below.
3. Execute the root-reviewed `docs/superpowers/plans/2026-09-10-transfer-new-window-target.md`. It requires an explicit retained provisional-window operation, aggregate live+unresolved capacity, exact outer publisher pause, reuse of the existing inner transfer, cleanup admission that cannot deadlock, and nonpresenting configuration separate from final presentation. No document copy/factory/adoption is permitted. Add actual red/green tests and independent review.
4. Continue all remaining applicable matrix requirements; this is an internal milestone, not completion.

Agents: document_core completed controller reconciliation and AppDelegate presentation fixes; engine_spike completed binding corrections and reviewed process/owner; requirements completed owner tests, independent presenter review and the new-window plan. All code ownership is released. Use followup_task for new bounded work.

## Important invariants

- Registry identity-only queries never authorize projection: use exact live leases and strict scalar/native validation. Immutable original view receipts are rebound, never recaptured as approval for unrelated changes.
- Monitor reservation occurs inside suspend after the process retains cleanup ownership. During a live transfer, ordinary window-close detachment of the exact moved model is suppressed because the transaction owns suspension, including before first reservation. Both cancellation and rollback restore both native projections before monitor attachment.
- Closed contexts retain exact identity for safe detachment only after binding activation; actions/new attachments still reject closed/quitting. Weak receipt loss during an active lease fails closed.
- Terminal cleanup permits newer edits after lease/pause release while intake, close, quit and new structural operations remain gated. Missing peer refresh must not leave a committed surviving editor read-only.
- Session/recovery retain one publisher and exact pause ownership. Never await transfer settlement from publisher capture. No callback cleanup may erase a newer operation.
- Presenter generations change at newer chooser and quit entry, including quit veto. Presentation failure does not roll back a committed move.

## Commands

```sh
scripts/swift.sh build --scratch-path .build/pane-native-integration
scripts/swift.sh test --scratch-path .build/pane-native-integration
scripts/test-managed-documents.sh
scripts/test-session-presentation-flow.sh
scripts/test-session-capacity.sh
scripts/test-application-documents.sh
scripts/test-pane-session.sh .build/pane-native-integration/arm64-apple-macosx/debug
scripts/test-pane-save.sh .build/pane-native-integration/arm64-apple-macosx/debug
scripts/test-native-monitor-lifecycle.sh .build/pane-native-integration/arm64-apple-macosx/debug
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
git diff --check
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

Coordinate shared scratch builds. Raw logs and synthetic fixtures stay ignored in `.local`; no real user documents, machine-specific paths or credentials belong in public records. Repository-local commit identity is configured.

## GUI access and artifacts

An approved read-only console probe on 2026-09-10 confirmed the screen remains locked. The user was asked to unlock and approve UI Automation if prompted; no response yet. Do not run visible apps, benchmarks, posted input or XCUITest until access is confirmed. Hidden AppKit tests and build-for-testing are allowed. Never change credentials/security settings. Earlier UI automation failures do not establish their cause from today's lock state.

Current artifacts are source `81db251`: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. Executable SHA-256 `03606c59b55d33b67f46d465ae1c4727492277480c3b67da45afa7a5a0675bb9`. Isolated committed-source release build: 29.41 seconds. Six-file bundle/archive/SBOM checks and strict deep ad-hoc signature verification passed before and after promotion. See `docs/verification/managed-package.md`. No Developer ID, notarization, publication or current packaged desktop acceptance. Earlier GUI and Intel cross-build evidence belong to older binaries.

## Remaining acceptance

Every outstanding matrix item remains scope: autosave and remaining save faults; advanced editing/multicursor/rectangle/overwrite; folder replacement previews/backups; folding/completion/snippets/custom languages/formatters; workspace/group/window transfer; complete macro bindings/localization/accessibility/IME; repeated cold-launch/100 MB/1 GB/pathological-line performance; security/supply-chain/parity and failure review; clean packaged desktop testing. Historical dirty-edit and checkpoint interaction measurements cover only their recorded operations, not full performance acceptance. Glyph warnings reproduced on baseline and candidate remain unresolved. Intel/minimum-OS runtime and physical IME/VoiceOver are untested. Signing and release require separate external steps.
