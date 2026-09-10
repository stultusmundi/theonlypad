# Continuation checkpoint

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and next action

Branch `build/native-editor`. Managed AppDelegate activation is implemented in local commit `81db251`: one process registry, native intake/close, endpoint monitor ownership, one recovery/session publisher and a bounded external-open FIFO. The application remains incomplete; all outstanding requirements retain their scope.

Fresh frozen integration at `.local/native-managed-integrated` built in 5.71 seconds and passed 404 core tests (16.066 seconds), 71 combined hidden native tests (5.750 seconds), and the legacy monitor lifecycle compatibility harness. Exact base/overlay hashes are retained in `source-provenance.json`. Logs: `.local/native-managed-core.log`, `.local/native-managed-combined-green.log`, `.local/native-managed-monitor.log`. The combined runner initially omitted an existing test-access extension; that compile failure remains in `.local/native-managed-combined.log`. The corrected runner includes and hashes it. No desktop acceptance is implied.

Exact next actions:

1. Complete native document transfer using `docs/superpowers/specs/native-document-transfer.md` and its dated plan. First slice is one selected editable tab between existing one-group windows, retaining model, undo, recovery authority and monitor baseline. No integrated move command exists yet.
2. Monitor dependency committed locally as `58f78e7`, independently reviewed. Final bridge evidence: 142 deterministic, 29 real-service, 26 application checks; native bindings: 36. Preserve exact receipt phases and service epoch. Reserve monitor authority inside `suspendMonitor` AFTER the process records cleanup responsibility, never in pure native capture.
3. Registry source committed locally as `fc3eb4d`: 62 tests (49 unchanged +13 transfer). Dedicated nonthrowing rotation collaborator returns exact minted ownership/mutation tokens. `.rotated` records source placement after rotation; rollback records `.restored` before post-validation. Transient scalar-read failures can retry without rerotation; arbitrary mutations refuse. Independent registry rotation re-review is clear.
4. Root process source currently uncommitted/frozen: 14 tests passed in `.local/transfer-process-prestage-green.log`. Independent review cleared settlement, admission cleanup and both attachment retry branches. Dedicated settlement-only retry handles consumed monitor receipts; restored rollback retries explicitly suspend accepted attachments. Cleanup releases the exact pause before retryable admission refresh. Root owns ApplicationDocumentTransfer.swift/boundary/tests/runner and later NativeApplicationDocuments composition. Verification document records all red/green steps and the attachment variant audit. Commit the reviewed process files before native composition.
5. `document_core` owns EditorDocument.swift dedicated rotation method (12 native adapter tests passed), EditorDocumentTransferAdapter.swift, then EditorWindowController token-bound transfer projections and tests. Controller work is active. Agreed capture/validate/project/refresh and active/terminal explicit endpoint-reconcile APIs preserve receipts, defer full refresh/focus/settings/presentation installation, and never scan dirty/full text in the transfer commit. Terminal recovery preserves permitted edits. Monitor attachment needs bounded conservative context during the transfer; ordinary fileStateContext evaluates dirty and is unsuitable there.
6. `requirements` owns NEW ApplicationDocumentTransferPublisherTests.swift and its runner: two actual before/after-capture tests passed with real actor/store receipts and exact target readback. Independent review cleared evidence but found fixture closure cycles; test-only lifetime fix is underway before commit. No production edits without coordination.
7. Root must integrate concrete native receipt + monitor ports, endpoint recreation, process user/close/intake/quit gates, status/retry and command access after subsystem review. Owner.windows currently uses generic registry capture and would become empty during a transfer gate; use a safe identity-only endpoint enumeration before integration. Avoid a transfer wait inside publisher prepareCapture. Freeze sources before full app/core/native integration tests.
8. Continue all remaining matrix requirements after transfer. New-window targets, independent groups, streaming and desktop acceptance remain required for F-02. GUI remains blocked by locked console/no response: no visible apps, posted input, XCUITest or visible benchmarks until access is confirmed. No remote publication.

## Architecture and invariants

AppKit/TextKit1, Foundation/CryptoKit/Darwin PadCore; no external runtime dependencies. macOS 14 minimum; Swift 6.3.3 in explicit Swift 5 mode. Runtime evidence: ARM64 M4 Pro, 48 GiB, macOS 26.6.2 only. Committed `6c7fb68` additionally cross-compiled for x86_64/macOS 14 in 25.69 seconds; no Intel runtime or packaging claim (docs/verification/intel-cross-compilation.md). Engine remains provisional pending full multicursor, performance, IME and accessibility acceptance.

- One shared text storage and undo manager per document; at most two editor views, stable identities and retained detached undo targets. Composition excludes competing edits. Above 2,000,000 UTF-16 units, saved split restoration is explicitly deferred.
- Session v2 persists ordered pane ranges, point scroll origins, axis and focused slot once per logical document. Exact canonical v1 migration is read-only. Native range clamp is synchronous and bounded using existing NSString; full startup/bookmark validation stays off-main. No asynchronous native restore worker or full glyph-layout flush remains. Scroll placement is best effort across font/wrap/geometry changes.
- Registry owns exclusive document/group/window metadata and managed native projections. Live plus unresolved capacity is bounded to 32 windows/128 handles. Transfer is in progress. Actual native close tests include interrupted deletion and actor-authority repair; these do not establish crash-journal durability.
- Current legacy RecoveryCoordinator.close permanently tombstones an ID before deletion. Never map its thrown error to unchanged/write-enabled recovery. New managed captures must carry their original epoch; no late getter may upgrade stale work. Preserve model ownership on uncertainty and require fresh confirmed atomic repair before reopening admission.
- Exact dirty comparison retains its conservative fallback and pending-storage poison. No digest-only or unconditional dirty substitute.
- Atomic publication uncertainty retains opaque evidence and attempted bytes; readback is not acknowledgement. Fresh successful save only. Keep Buffer never authorizes overwrite.
- Paired recovery/session checkpoints use 750 ms debounce/15 s maximum, one worker plus pending capture, bounded retry and quit drain/final receipt. Preserve this single publication authority.
- Monitoring uses bounded registration/work queues, exact-byte reconciliation and explicit action ownership. Reload/Copy/Locate maintain final authority checks; monitoring never automatically overwrites files or reloads edits.
- Shortcut settings use one validated atomic catalog, preserve native protected commands and fence composition/extension revisions. Physical keyboard layout behavior is unverified.

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
