# Monitor endpoint reattachment verification

Implemented bridge lifecycle only; controller callsite migration and native model/history integration remain separate.

- Compiled behavioral red: valid detach/reattach failed against throwing API seam (`run.6StInf4p`).
- Final retained command: `scripts/test-file-state-bridge.sh .build/recovery-close-integrated/arm64-apple-macosx/debug`.
- Final run `run.0gQyxyoZ`: 125 deterministic bridge assertions, 25 production service/bridge assertions, and 26 application monitoring checks; all passed.
- Strict Swift formatting and diff whitespace checks passed.

Deterministic cases cover cancellation after authority retirement, rejection of old queued delivery, baseline/ownership mismatch, failed-preflight retry, consumed token refusal, explicit manual fallback, reentrant terminal invalidation during new-context validation, and release of old callback captures on detachment. Existing action and own-operation authority tests remain intact.

The real service test binds an actual synthetic parent, detaches, renames the parent, recreates the old path with equal bytes, then reattaches. It receives parentChanged and refuses reload; only the new endpoint callback renders. No model text, undo or history object is exercised in that Foundation-only test, and no such integration claim is made.

All evidence remains in unique ignored private directories. No shown windows, activation, physical input or performance measurement occurred. Independent source review and root integration execution are separate gates.

Review regressions were observed independently: `run.HHGoVH62` failed recursive detachment from the context callback; `run.YDZpb00L` failed reattachment reporting success after a render callback replaced the baseline. The final run includes both fixes: transition guard before the first callback, and exact binding plus captured registration authority validation after rendering. Formatting-only changes followed the run; strict lint passed.

Root independently passed all 125 deterministic bridge assertions, 25 real-service assertions and 26 application-monitor checks in `.local/file-state-bridge/run.rYpFTo70` (`.local/monitor-reattachment-root.log`). Root review identified recursive detach and post-render baseline replacement gaps; each was reproduced as a behavioral failure before the final fixes. Final source review was clear. Native controller handoff and endpoint recreation remain integration requirements.
