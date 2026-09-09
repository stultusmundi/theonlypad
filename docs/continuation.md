# Continuation checkpoint

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and next action

Branch `build/native-editor`. Local commits: `5ad963d` pane metadata and bounded selection validation; `cd2d679` document registry; `ab79268` session restoration flow and capacity; `e331f3b` synchronous native pane restoration; `11d2a25` registry close leases and correlated repair. Native transfer and registry/recovery close integration remain unimplemented.

Final integrated hidden native verification passed against current sources: all 24 pane scenarios (199 assertions) in `.local/pane-session/run.LFh2hY7D` and the real-save harness (26 assertions) in `.local/pane-save/run.Kd90NmLF`. Current application build passed in 3.45 seconds. Frozen candidate full core suite passed 392 tests in 16.113 seconds, with source provenance retained in `.local/pane-candidate.2o9eg75i`; only the then-independent registry close addition differed. That addition subsequently passed 30 tests in 0.010 seconds. Session flow passed 9 tests and capacity passed 7. Monitor/Reload/Copy/Locate/quit compatibility passed. Desktop pane tests compile only. See verification records for limits and historical failures.

Exact next actions:

1. Latest local commits: `fad9b3f` ordinary session import claims; `cfc628b` process-owned close; `f7cd796` recovery-only claims preserving corrupt session metadata; `fe1df6e` registry pending adoption. Previous `e6dd533`, `02815ca`, `eb7afe7`, `8839fc9` provide actor, scheduler, model and monitor verification. No AppDelegate managed activation yet.
2. Fresh frozen `.local/adoption-close-integrated` built the full app in 8.94 seconds and passed 404 core tests in 16.368 seconds. It includes close/adoption and committed ordinary SessionCoordinator, excluding later recovery-only extension. Registry root runner passed 41 tests; close compatibility passed 19 with the new registry; recovery-only claim runner passed 11. Provenance/raw logs retained under `.local`. Current dist still source `6c7fb68`.
3. Root now owns pre-factory import capacity tests/implementation in SessionCoordinator and SessionImportClaimsTests. The expanded runner passed 13 tests in `.local/import-capacity-final.log`, with coherent 127 resolved/live records before 128th admission and 129th refusal. Independent review passed; commit verified scope, then implement reviewed process intake owner from `.local/process-intake-owner-design.md`. No root test remains active. Claims remain provenance, not reservations. Native intake must separately revalidate callbacks and registry ownership.
4. document_core implements the reviewed Foundation-testable ApplicationSessionCheckpoints managed wrapper plus boundary/native legacy initializer adapter/tests/runner. Preserve existing initializer behavior; actual actor commits only. Intake alone owns adoption receipts; publisher owns activation hold/phase. FinalReady permits only owning final capture after native freeze; ordinary capture remains blocked. engine_spike implements isolated EditorDocumentFactory/seed initialization and hidden tests for eight source paths; no native routing activation. requirements reviews these slices. Coordinate shared files and frozen builds.
5. Root native intake design `.local/native-intake-transaction-design.md` collects startup prepared records as unresolved, then imports via exact claims after restoration. Recovery-only claim permits validated scratch content while preserving corrupt-session write refusal. Budget admission replaces only original-window reservations without growing union; live limits still apply. Native disk-copy handoff consumes source operation before returning and retains separate target identity plus bounded payload ownership; no created announcement before projection. Complete process intake/projection/legacy drain/managed close activation together, then F02 groups/window moves/streaming and all remaining requirements.
6. No GUI launch while access remains blocked. Refresh package from an isolated committed snapshot after integration verification; never treat foundation tests as native desktop acceptance.

## Architecture and invariants

AppKit/TextKit1, Foundation/CryptoKit/Darwin PadCore; no external runtime dependencies. macOS 14 minimum; Swift 6.3.3 in explicit Swift 5 mode. Runtime evidence: ARM64 M4 Pro, 48 GiB, macOS 26.6.2 only. Committed `6c7fb68` additionally cross-compiled for x86_64/macOS 14 in 25.69 seconds; no Intel runtime or packaging claim (docs/verification/intel-cross-compilation.md). Engine remains provisional pending full multicursor, performance, IME and accessibility acceptance.

- One shared text storage and undo manager per document; at most two editor views, stable identities and retained detached undo targets. Composition excludes competing edits. Above 2,000,000 UTF-16 units, saved split restoration is explicitly deferred.
- Session v2 persists ordered pane ranges, point scroll origins, axis and focused slot once per logical document. Exact canonical v1 migration is read-only. Native range clamp is synchronous and bounded using existing NSString; full startup/bookmark validation stays off-main. No asynchronous native restore worker or full glyph-layout flush remains. Scroll placement is best effort across font/wrap/geometry changes.
- Registry owns exclusive document/group/window metadata, but native controllers have not migrated. Live limits are 32 windows/128 handles; capacity snapshot also counts unresolved records. Aggregate admission and transfers still require wiring. Close-state tests use synthetic receipts and do not prove durable recovery repair.
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

Current artifacts are source `6c7fb68`: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. Executable SHA-256 `6c818622cdce7c595ddea76183768768ea18f11d42c34b1f0d609cb48328b4b6`. An isolated committed-source release build took 25.23 seconds; ad-hoc signature and all six bundle/archive/SBOM checks passed before and after promotion. Log `.local/pane-package-build.log`. This includes pane persistence, not concurrent recovery-close development. No Developer ID, notarization, publication or current packaged desktop acceptance. Historical six-test packaged GUI evidence belongs to an older executable and is not current acceptance.

## Remaining acceptance

Every outstanding matrix item remains scope: autosave and remaining save faults; advanced editing/multicursor/rectangle/overwrite; folder replacement previews/backups; folding/completion/snippets/custom languages/formatters; workspace/group/window transfer; complete macro bindings/localization/accessibility/IME; repeated cold-launch/100 MB/1 GB/pathological-line performance; security/supply-chain/parity and failure review; clean packaged desktop testing. Historical dirty-edit and checkpoint interaction measurements cover only their recorded operations, not full performance acceptance. Glyph warnings reproduced on baseline and candidate remain unresolved. Intel/minimum-OS runtime and physical IME/VoiceOver are untested. Signing and release require separate external steps.
