# Checkpoint preparation during document close

An ordinary checkpoint could treat a managed document close in progress as a persistent publication error. The scheduler now defers only the typed preparation `closeInProgress` outcome without replacing an existing genuine error. It consumes that attempt, avoiding an idle retry loop; a subsequent request follows the normal delay. Final checkpoint and capture failures still propagate. The publisher maps `pendingRecovery` to this deferral only during ordinary managed preparation, after the existing intake guard. Other phases and errors retain their previous behavior.

The adopted changes are confined to `SessionCheckpointCoordinator.swift` and `ApplicationSessionCheckpoints.swift`. Original production close/recovery guards remain intact. Two regression files add five tests; the existing closing fixture changes only a weak local from `var` to `let` to satisfy warnings-as-errors, preserving its lifetime assertions.

## Verification (2026-10-12)

The corrected test-first baseline compiled and completed five cases with five ordinary failed assertions across three methods; two final/capture controls already passed. The unchanged five tests pass after the repair, including actual confirming-close cancellation, settlement, paired publication and fresh checkpoint readback.

A frozen Foundation compatibility run passes 55 tests: the five new cases, eight pause tests, four receipt tests, 18 publisher tests and 20 closing-owner tests. A matching private native candidate passes six hidden native cases: the original five close regressions and the unrelated-window recording-preservation case. The original interrupted-deletion repair, survivor recording, subsequent edit and undo/redo assertions all pass. These native results also depend on the separately reviewed private controller projection candidate; they do not establish public adoption of that controller change.

Current formatted public-source commands:

```sh
scripts/test-application-session-checkpoints.sh
scripts/test-application-document-intake.sh
scripts/test-application-document-closing.sh
xcrun swift-format lint --strict Sources/TheOnlyPad/SessionCheckpointCoordinator.swift Sources/TheOnlyPad/ApplicationSessionCheckpoints.swift Tests/NativeIntegration/ApplicationDocumentClosingTests.swift Tests/NativeIntegration/CheckpointCloseDeferralTests.swift Tests/NativeIntegration/ManagedCheckpointCloseDeferralTests.swift
python3 scripts/check-public.py
```

The publisher runner now includes the five regression cases in a separate module alongside its original 18 tests; it passes 23 tests. The unchanged intake suite passes 26 tests. Both runners explicitly include the existing close-boundary source required by the publisher. The current closing-owner runner passes 20 tests with the assertion-preserving weak-let fixture. These are three separate selections, not a one-process union. The full current application and helper also build without warnings, with 179 production/manifest input hashes unchanged. The existing runner timeout mechanisms are unchanged; these commands do not acquire the stricter search watchdog receipt guarantees merely by sharing this evidence record.

Independent review accepts the original source, formatted adoption and frozen results. Raw synthetic evidence remains ignored under `.local/`. Initial lazy-type and weak-variable compiler failures are retained as setup failures, not behavioral RED. No tests or error guards were disabled.

This is preparation/close correctness evidence, not visible desktop, performance, physical keyboard, IME or VoiceOver acceptance. Full macro/transfer integration and the remaining application scope are still outstanding.
