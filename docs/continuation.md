# Continuation

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and exact next action

Branch `build/native-editor`. Task2 new-window transfer ownership and cleanup is committed as `1c96b99e424caae18a9f9d1999fe7bf02c515e7f` and independently approved for specification and code quality with no findings. It reuses the exact document model, storage, undo and recovery authority, and retains exact operation ownership through failures. See `docs/verification/new-window-handoff.md`.

Verified Task2 evidence: 44 new-window, 12 existing-window transfer, 17 process, 9 native-owner and 9 projection tests, all zero failures; actual app build passed. Monitor bridge checks (142 deterministic, 29 service, 26 app) and hidden monitor lifecycle passed. Source/evidence manifests: `.local/task2-source-freeze.json` and `.local/task2-evidence.json`. Do not repeat these unchanged component checks without a relevant change or failure. Task1 preparation and cancellation/FIFO fixes are independently approved at `da8ef2e`; its historical evidence remains in `docs/verification/new-window-preparation.md`.

Task3 is active: worker `/root/new_window_chooser`, base `e9c9d28`, owns NativeDocumentMoveChoices, DocumentMoveDestinationController, AppDelegate, DocumentMoveDestinationTests and its runner. Root owns documentation and final verification/package orchestration. Do not overlap worker source edits. The brief, report, ledger and review packages are under ignored `.superpowers/sdd/2026-09-10-transfer-new-window-target/`. Latest intermediate chooser evidence is 12 tests/0 failures (`run.jxPVZht1`), following behavioral red 4 tests/1 failure (`run.8erZ5uVT`). Additional real failure/Retry coverage and final checks are in progress; this is not final reviewed evidence.

Exact next actions:

1. Finish Task3 from `docs/superpowers/plans/2026-09-10-transfer-new-window-target.md`: typed New Window chooser, authoritative acceptance, actionable failure and generation-fenced presentation after successful cleanup. Review the exact implementation diff independently for specification and quality, resolve findings, then commit scoped changes.
2. Verify the approved committed source in a detached worktree under ignored `.local`, including affected core, managed, chooser and transfer integrations and the actual app build. Native runners discover their repository root using git; do not run a plain nested source archive that resolves the parent repository by mistake. Use an owned-process watchdog for the core suite's adversarial regex tests; private helper `.local/run-verified-command.py` has passing success and timeout controls.
3. Refresh the local ad-hoc-signed app/archive/SBOM from the approved source, verify contents and signature before and after promotion, and record exact provenance. Current artifacts remain the older `324a3de` existing-window slice and do not contain new-window changes.
4. Continue the regex error-propagation plan and all outstanding matrix requirements. This is an internal checkpoint, not product completion. Desktop testing remains blocked by the locked console.

Historical existing-window integrated evidence at `324a3de` includes 404 core, 71 managed, 11 transfer, 9 projection, 3 chooser tests and 44 binding checks passing. Its 364-file snapshot in `.local/native-transfer-reviewed-integrated/source-provenance.json` describes that source only; it does not match the current working tree. The package record is `docs/verification/native-transfer-package.md`.

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

Current artifacts are source `324a3de`: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. Executable SHA-256 `0d58d1ea0e6cff4ac73bbc1461dc8a57f6d0784301def59f472f195fb2df0ce6`. Isolated committed-source release build: 30.82 seconds. Six-file bundle/archive/SBOM checks and strict deep ad-hoc signature verification passed before and after promotion. See `docs/verification/native-transfer-package.md`. No Developer ID, notarization, publication or current packaged desktop acceptance. Earlier GUI and Intel cross-build evidence belong to older binaries.

## Regex review checkpoint

Read-only source/SDK review is preserved in `docs/verification/regex-execution-review.md`. It found ignored Foundation internal-error flags and missing completion reporting, which can misreport incomplete enumeration as success; no triggering real-engine failure was reproduced. Hard termination/backpressure and native selection/open-document scope remain outstanding. The report specifies a narrow typed-error propagation fix and a separate supervised-helper design; neither is implemented. Do not run adversarial regex directly in an unprotected runner. Continue the active new-window handoff/chooser tasks; preserve this search work in the remaining C requirements. The narrow fix now has an executable plan at `docs/superpowers/plans/2026-09-10-regex-engine-errors.md`; implementation remains outstanding.

## Remaining acceptance

Every outstanding matrix item remains scope: autosave and remaining save faults; advanced editing/multicursor/rectangle/overwrite; folder replacement previews/backups; folding/completion/snippets/custom languages/formatters; workspace/group/window transfer; complete macro bindings/localization/accessibility/IME; repeated cold-launch/100 MB/1 GB/pathological-line performance; security/supply-chain/parity and failure review; clean packaged desktop testing. Historical dirty-edit and checkpoint interaction measurements cover only their recorded operations, not full performance acceptance. Glyph warnings reproduced on baseline and candidate remain unresolved. Intel/minimum-OS runtime and physical IME/VoiceOver are untested. Signing and release require separate external steps.
