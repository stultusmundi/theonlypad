# Document transfer process verification

Implemented separately from native composition: a process-owned existing-window transfer reserves the registry, drains one exact publisher pause, retains native receipts before effects, and stages both projections. Failures restore both endpoints where possible; failed restoration retains the same model, lease and pause for explicit retry. Cancelling a waiter does not cancel ownership. No command or completed native window-transfer feature is claimed here.

The coordinator distinguishes monitor completion from registry settlement. Once a monitor receipt is consumed, a transient registry read failure retries only settlement. Cleanup releases its own pause once, then refreshes native admission; a failed refresh retries without repeating the committed move. Native admission can resume only after registry settlement and pause release; competing process operations remain blocked until refresh succeeds. No cleanup runs after the final checkpoint callback, which may start a newer transfer.

Command: `bash scripts/test-application-document-transfer-process.sh`. The runner snapshots actual registry, recovery and scheduler sources plus the process coordinator and test fixtures, records source hashes, and uses an owned-child watchdog. The synthetic handles are adopted through the real recovery actor. Native projections use explicit test ports; these tests do not substitute for real controller or desktop acceptance.

Retained private evidence:

- Initial test setup failures (throwing assertion inference and missing temporary directory) remain separate from behavioral results.
- The compiling initial seam failed with `pendingLayout`, then the first transfer test passed.
- Five rollback tests failed before implementation; all five passed after restoration and cleanup handling.
- Eight tests passed after cancellation, invalid reservation and notification reentry coverage.
- Independent review found consumed-monitor settlement retry could remain stuck. The ninth test failed, then passed after dedicated settlement phases.
- Eleven tests passed with exact registry rotation receipts, including transient reads after move and rollback; retry does not rotate a third time.
- Admission-refresh regression: 12 tests, two failures before the fix; final formatted run passed all 12 with zero failures in 0.010 seconds (`.local/transfer-process-admission-green.log`).

A subsequent monitor integration review found that a rollback attachment could succeed before monitor finish refused. The thirteenth test failed with the accepted attachment retained; explicitly suspending it before retry fixed the failure. Final formatted run: 13 tests passed, zero failures, in 0.011 seconds (`.local/transfer-process-reattach-green.log`).

Independent review cleared the settlement and final admission-refresh changes; review of the final attachment retry delta is pending. Actual publisher capture/drain interaction, native endpoint integration, endpoint recreation, public command access, full F-02 scope and desktop acceptance remain outstanding.

## Attachment retry variant review

Root cause: a failed finish can leave the native monitor attached; repeating attachment requires explicit suspension first. A repository search for adjacent `attachMonitor`/`finishMonitor` calls found the pre-stage cancellation variant. Expanding to all three process attachment calls and the native store/bridge attachment calls found no additional process variant: the forward move is executed once, restored rollback already suspends on retry, and the store/bridge intentionally reject replay rather than silently resetting authority. The remaining pre-stage variant was reproduced (14 tests, one failure), then fixed by the same exact-lease suspension. Severity: medium reliability impact in an unexposed feature; confidence: reproduced. No corruption or privilege escalation is claimed.

Final formatted run: 14 tests passed, zero failures, 0.011 seconds (`.local/transfer-process-prestage-green.log`). Independent review cleared both rollback branches. The CI-ready regression command is `bash scripts/test-application-document-transfer-process.sh`; the phaseful native fixture rejects replay and covers both finish-refusal paths. Static matching alone cannot establish this state-machine invariant, so the behavioral suite is the regression guard.
