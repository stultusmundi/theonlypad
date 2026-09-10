# Continuation

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and exact next action

Branch `build/native-editor`. The three-task new-window transfer slice is implemented, independently approved and locally packaged at `55a7b1bb9ee50b6ea5f94b64cae5657a25e9dd5b`. It transfers the existing model/storage/undo/recovery authority into an existing or new window, with retained exact cleanup ownership and generation-fenced presentation. Aggregate F-02 and the full application remain incomplete. See `docs/verification/new-window-integrated.md`.

A clean detached worktree `.local/new-window-integrated` contains that exact source. Provenance records 580 tracked files in `.local/new-window-integrated-evidence/source-provenance.json`. Final integrated tests: 404 core/0, 71 managed/0, 44 new-window/0; actual app build passed. Final chooser15/0 and existing transfer12/0 each have 126 production-source hashes matching that commit. Task2 process17/owner9/projection9 and monitor evidence remains applicable to unchanged components. Do not repeat these completed checks without relevant changes or failures.

Exact next actions:

1. Single-enumeration semantic Task1 is committed at `28e2a9fbcf3daaa2c5087559d02e07143ad18235`, independently approved for specification and quality without findings. Private report/review: `.superpowers/sdd/2026-09-10-search-single-enumeration/`. Focused execution12/0, engine8/0, full core425/0 under owned watchdog (15.663s command, no timeout), actual app build and both hidden native error-panel scenarios pass. See `docs/verification/search.md`. Native Replace All still composes two wrapper calls; do not claim routing is complete.
2. Wire Task1 is independently approved at `aa3aa82` (19 framing tests). Task2 is independently approved at `10c4dd4a66e50c5f1a1113ef63a9ec2ad25cd016` (20 UTF16 tests plus19 framing regressions, module build/scoped checks). Reports/diffs/reviews: `.superpowers/sdd/2026-09-10-search-wire-protocol/`; public evidence `docs/verification/search-wire.md`. Root verified final hashes. Clean detached `.local/search-wire-unicode-integrated` at05cab51 records598 tracked hashes; full464 tests/0 pass under watchdog (16.023s suite,28.169s command), explicit app build passes. Raw evidence `.local/search-wire-unicode-integrated-evidence/`. Avoid rerunning unchanged completed checks. Task3A is committed at `f59522219c5698c66ec53045343bb8eef8a51e2c`, with28 request tests/0,19 framing/0,20 UTF16/0, module build and scoped checks. Root verified three final hashes. Independent reviewer `/root/search_request_review` found one Important error-precedence defect in the exact05cab51..f595222 source diff. Fix round1/5 is dispatched to original worker `/root/search_wire_requests`: input UTF16 callback reentry must preserve outer poisoned over the nested decoder sinkRejected wrapper. Own RequestCodec/RequestTests only, add uncaught and caught-then-throw input callback regressions, retain red/green, scoped commit, then exact re-review. No other findings. Report/brief/source-review.diff are in the wire workspace. Raw TDD/check output is in tool transcripts, not separate logfiles. New reviewed rules reject partial trailing frames after execute (implemented3A) and after response hello/terminal (planned3B); provisional callbacks cannot authorize work if the same outer consume fails. Resolve3A review, then dispatch fresh3B worker from prepared task-3b-brief.md; Response/Terminal types remain absent. Root owns docs; one implementation worker at a time.
3. Reviewed architecture: `docs/superpowers/specs/2026-09-10-supervised-search.md`. Async admission deliberately rejects out-of-cap text/pattern/template before launch, with documented error-priority difference for oversized template plus invalid regex; direct core semantics remain unchanged. Generation bootstrap is bounded nonsecret `--generation <UUID>`. Root adopted `docs/superpowers/plans/2026-09-10-search-child-lifecycle.md` after independent drafting and root review; it is planned, undispatched and depends on complete wire approval. The independently approved packaging design is `docs/superpowers/specs/2026-09-10-search-helper-packaging.md`; its executable implementation plan remains outstanding. The independently approved allocation preflight is `docs/superpowers/specs/2026-09-10-search-text-allocation.md`; no measurements or implementation yet. Its conservative formula rejects the earlier640MB active candidate; no replacement budget adopted. The helper-runtime plan is now `docs/superpowers/plans/2026-09-10-search-worker-runtime.md`, with staged dependencies, fixed bootstrap, injected unit composition and an actual-allocation gate before production sink/executable adoption. No runtime implementation is dispatched. Parent-driver notes/review remain private at `.local/search-parent-wire-driver-{notes,review}.md`; its sync/async bridge, exclusive admission/idle-read handoff and memory settlement still need an executable contract. Allocation/native/folder stages remain outstanding. Continue hard regex containment, all remaining search scopes and the full requirements matrix. Desktop testing remains blocked by locked console. No milestone is product completion.
4. Prior error source9d54295 remains independently reviewed; detached `.local/regex-errors-integrated` has587 source hashes and412 passing core tests. Avoid rerunning unchanged historical checks. All adversarial suites need an outer watchdog; private `.local/run-verified-command.py` has verified timeout/success controls.

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
