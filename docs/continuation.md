# Continuation

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and exact next action

Branch `build/native-editor`. The three-task new-window transfer slice is implemented, independently approved and locally packaged at `55a7b1bb9ee50b6ea5f94b64cae5657a25e9dd5b`. It transfers the existing model/storage/undo/recovery authority into an existing or new window, with retained exact cleanup ownership and generation-fenced presentation. Aggregate F-02 and the full application remain incomplete. See `docs/verification/new-window-integrated.md`.

A clean detached worktree `.local/new-window-integrated` contains that exact source. Provenance records 580 tracked files in `.local/new-window-integrated-evidence/source-provenance.json`. Final integrated tests: 404 core/0, 71 managed/0, 44 new-window/0; actual app build passed. Final chooser15/0 and existing transfer12/0 each have 126 production-source hashes matching that commit. Task2 process17/owner9/projection9 and monitor evidence remains applicable to unchanged components. Do not repeat these completed checks without relevant changes or failures.

Exact next actions:

1. Engine-error Task1 is committed at `9d542951f4e7d1a83bc1729157a54c88647e7a07`; worker `/root/regex_engine_errors` completed. Independent reviewer `/root/regex_error_review` approved specification and quality with no findings for `.superpowers/sdd/2026-09-10-regex-engine-errors/review-55a7b1b..9d54295-source.diff` (nine source/test/runner files; full original diff also retained). The same directory holds brief, report and ledger. Fresh worker `/root/search_single_enumeration` is active on the semantic successor, base `f191546fd6750987b3458d7da5907b80cc839876`. It owns only SearchService and the new core SearchExecutionTests plus narrow engine-failure tests. Root owns docs; no source overlap. Private brief/report/ledger: `.superpowers/sdd/2026-09-10-search-single-enumeration/`.
2. Focused engine tests7, search/folder substring tests15, folder5 and both real hidden panel failure scenarios pass, actual app build passes. Root detached `.local/regex-errors-integrated` at9d54295 records587 tracked-file hashes and passes412 core tests/0 in15.436s under owned watchdog; evidence `.local/regex-errors-integrated-evidence`. Review is approved; continue the active single-enumeration task, then independently review its exact diff. Avoid repeating unchanged checks. Every adversarial suite requires an outer watchdog; private `.local/run-verified-command.py` has verified success/timeout controls.
3. The supervised-search architecture is root-reviewed in `docs/superpowers/specs/2026-09-10-supervised-search.md`, with first semantic stage in `docs/superpowers/plans/2026-09-10-search-single-enumeration.md`. Read-only design worker `/root/document_core` completed the private proposal and root revisions; it completed `.local/search-wire-plan.md` and root-requested refinements without source edits; root reviewed and adopted the final refinements in `docs/superpowers/plans/2026-09-10-search-wire-protocol.md`; it remains undispatched until semantic approval. Root protocol notes are `.local/regex-protocol-notes.md`. Root completed the throwaway owned-child probe in `docs/verification/regex-supervisor-spike.md` (commit e709f94). Execute the semantic plan only after the active error task is independently approved; the protocol plan follows semantics; later supervisor/allocation/native/folder stages still need executable plans. Continue hard regex execution containment, all remaining search scopes and the full requirements matrix. Desktop testing remains blocked by the locked console. Do not treat the new-window milestone as product completion.

New-window task reports/reviews/ledger remain in ignored `.superpowers/sdd/2026-09-10-transfer-new-window-target/`. Task2 commit1c96b99 and Task3 commit55a7b1b are both independently approved with no findings. Final minimal pane fix preserves raw unhosted origins and uses valid four-option backing alignment for hosted expectations; strict exact validation and selected-only restoration remain. Current artifacts contain55a7b1b, not any subsequent search changes.

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

Current artifacts are source `55a7b1b`: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. Executable SHA-256 `f02db4960212814ea8cbf38b351f466081f310a4ec1db7135a2f6a62f70525eb`. Isolated committed-source release build:31.12 seconds; total packaging35.784 seconds. Six-file bundle/archive/SBOM checks and strict deep ad-hoc signature verification passed before and after promotion. See `docs/verification/new-window-integrated.md`. No Developer ID, notarization, publication or current packaged desktop acceptance. Earlier GUI and Intel evidence belong to older binaries. Launch when desktop access is available: `open dist/TheOnlyPad.app`.

## Regex review checkpoint

Read-only source/SDK review is preserved in `docs/verification/regex-execution-review.md`. It found ignored Foundation internal-error flags and missing completion reporting, which can misreport incomplete enumeration as success; no triggering real-engine failure was reproduced. Hard termination/backpressure and native selection/open-document scope remain outstanding. The report specifies a narrow typed-error propagation fix and a separate supervised-helper design; the narrow fix is committed and independently approved, and the supervised helper remains outstanding. Do not run adversarial regex directly in an unprotected runner. Continue the active regex task and preserve larger search gaps in the remaining C requirements. The narrow fix now has an executable plan at `docs/superpowers/plans/2026-09-10-regex-engine-errors.md`; implementation, 412-test integration and independent review pass.

## Remaining acceptance

Every outstanding matrix item remains scope: autosave and remaining save faults; advanced editing/multicursor/rectangle/overwrite; folder replacement previews/backups; folding/completion/snippets/custom languages/formatters; workspace/group/window transfer; complete macro bindings/localization/accessibility/IME; repeated cold-launch/100 MB/1 GB/pathological-line performance; security/supply-chain/parity and failure review; clean packaged desktop testing. Historical dirty-edit and checkpoint interaction measurements cover only their recorded operations, not full performance acceptance. Glyph warnings reproduced on baseline and candidate remain unresolved. Intel/minimum-OS runtime and physical IME/VoiceOver are untested. Signing and release require separate external steps.
