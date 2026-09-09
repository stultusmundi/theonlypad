# Managed session publisher implementation plan

> **For agentic workers:** Use superpowers:executing-plans task by task. Preserve unrelated concurrent edits and obtain independent review before integration.

**Goal:** Provide a single authorized paired publisher with activation and close/quit admission.

**Architecture:** Retain the existing scheduler and actual RecoveryCoordinator writer. Separate native compatibility closures from the Foundation publisher so the real registry/session/actor can be tested without showing windows.

**Tech Stack:** Swift 5 mode, macOS 14+, Foundation, existing PadCore; AppKit only in the native adapter's dependent controller.

**Spec:** [Managed session publisher](../specs/managed-session-publisher.md).

## Component scope

Owned files: ApplicationSessionCheckpoints.swift, ApplicationSessionCheckpointBoundary.swift, ApplicationSessionCheckpoints+Native.swift, ApplicationSessionCheckpointsTests.swift, scripts/test-application-session-checkpoints.sh. AppDelegate and native controller remain unchanged.

- [x] Write compiling seam and six real-store behavioral tests; observe six runtime failures before implementing activation.
- [x] Implement exact activation/pause ownership, all-active managed capture validation, and existing legacy initializer adapter.
- [x] Exercise reentrant quit-preparation acknowledgement before drain; fix by explicit completed-drain readiness and synchronous transition guard.
- [x] Exercise real unresolved cleanup, real registry/actor close, and confirmed post-close publication; use fresh recovery reader for exact remaining content.
- [ ] Complete retained formatted suite, independent review, and actual native compilation compatibility before integration.

## Retained verification

Run `scripts/test-application-session-checkpoints.sh`. It freezes production core/publisher/registry/session/scheduler/recovery sources into a private temporary package, records SHA-256 provenance, and runs tests under an owned 180-second process-group watchdog. It does not show windows, launch the application, or substitute commit receipts.

Required cases: pre-activation stopped publication; failed activation retry with original token; unmanaged record refusal; zero-document close guard and actual final receipt; native-freeze acknowledgement; missing authority refusal; projection reentry and pin mismatch; exact previous session bytes on final write failure; unrelated pause preservation; held unresolved removal drains without close cycle; failed metadata permits adopted recovery-only scratch but preserves exact bytes and refuses publication; unrepresentable groups refused; activation token cannot be released by close API; startup intake owns a separate exact-authorized hold; managed compatibility pause/resume works; activation failure offers no misleading retry; actual legacy paired writer compatibility.

## Native integration obligations (planned, separate ownership)

- [ ] Root intake installs application routing before any app model creation; freezes/drains legacy work, owns adoption receipts, and finishes activation only after all model/registry projections settle.
- [ ] Controller adapter validates every registry handle/endpoint/order/pin/focus and captures one authorized item per shared document; resource preflight precedes copies.
- [ ] AppDelegate quit calls prepareQuit, freezes controllers without standalone persistence, marks native preparation, commits final, and thaws before veto cancellation.
- [ ] Actual native hidden lifecycle compatibility and real desktop startup/close/quit/relaunch acceptance. GUI-locked execution is not claimed.

Independent final review clear. Root runner passed 18 tests; frozen native build and instrumented-probe compile passed. See [verification](../../verification/managed-session-publisher.md). Managed AppDelegate activation remains planned.
