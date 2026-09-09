# Monitor reattachment plan

1. Add immutable binding identity and opaque single-use detachment token. Implemented; optional ownership generation preserves standalone compatibility.
2. Retire callbacks and authority before cancellation, retaining exact parent continuity. Implemented.
3. Validate replacement context before and after callback, then install fresh callbacks and register with retained identity. Implemented; failed preflight retains token, registration failure exposes manual fallback.
4. Retain deterministic tests for stale baseline/model, duplicate token, inline cancellation, queued old delivery, reentrant invalidation and callback lifetime. Retain actual service parent-retarget test. Implemented; final runtime result recorded separately.
5. Independent review, then controller detach/reattach migration by its owner. Pending; no GUI claim.

Command: `scripts/test-file-state-bridge.sh <existing-debug-build-path>`. Its real service harness uses synthetic file replacement and needs execution permissions for that fixture. Unique ignored evidence preserves failures and successes.
