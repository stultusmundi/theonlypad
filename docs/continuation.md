# Continuation checkpoint

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and next action

Branch `build/native-editor`. Local commits: `5ad963d` pane metadata and bounded selection validation; `cd2d679` document registry; `ab79268` session restoration flow and capacity; `e331f3b` synchronous native pane restoration; `11d2a25` registry close leases and correlated repair. Native transfer and registry/recovery close integration remain unimplemented.

Final integrated hidden native verification passed against current sources: all 24 pane scenarios (199 assertions) in `.local/pane-session/run.LFh2hY7D` and the real-save harness (26 assertions) in `.local/pane-save/run.Kd90NmLF`. Current application build passed in 3.45 seconds. Frozen candidate full core suite passed 392 tests in 16.113 seconds, with source provenance retained in `.local/pane-candidate.2o9eg75i`; only the then-independent registry close addition differed. That addition subsequently passed 30 tests in 0.010 seconds. Session flow passed 9 tests and capacity passed 7. Monitor/Reload/Copy/Locate/quit compatibility passed. Desktop pane tests compile only. See verification records for limits and historical failures.

Exact next actions:

1. Recovery actor/store authority and repair leases are committed as `e6dd533`; scheduler receipt validation as `02815ca`; native model authority capture as `eb7afe7`; monitor harness delivery synchronization as `8839fc9`. Frozen integrated app build and 404 core tests passed, plus 25 actor/store tests, 12 scheduler tests and the old scheduler harness, 26 hidden model assertions and old shared-pane ownership. The original monitor failure remains retained; a controlled second-hop delivery race reproduced the harness issue, and the corrected full native monitor harness passed independently in `run.ql__aj89`. No production action guard changed.
2. Root session import claims passed nine tests in `.local/session-import-claims-final.log`, with seven capacity and nine restoration-flow compatibility tests. Commit its source, runner and reviewed records after public/format checks. Native import still uses the old callback until the registry intake transaction is implemented.
3. document_core owns new process-close owner files and tests. Initial 18 tests and independent review passed; it is adding a running real paired-publisher integration test before integration. engine_spike owns pending registry adoption, its tests/runners and one RecoveryCoordinator immutable identity accessor. Readiness must not cache a writer epoch that becomes stale after repair. requirements provides independent review. Preserve their concurrent edits.
4. Root owns native glue design `.local/application-registry-glue-design.md`. Resolve startup/intake reconciliation and aggregate admission, then activate registry projection, adoption, paired managed publication and close together. No AppDelegate activation has occurred. Continue F02 moves between windows, independent groups and streaming handles, then every outstanding requirement. The foundations do not complete F02.
5. Refresh package from an isolated committed snapshot after native integration checks; current validated artifacts remain source `6c7fb68`. Do not launch while GUI access is blocked.

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
