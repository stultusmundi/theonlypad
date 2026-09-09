# Process-owned closing implementation

- [x] Compile boundary and real actor/registry/scheduler behavioral reds.
- [x] Implement serialized process ownership and noncancellable admitting phase.
- [x] Implement preflight/lease settlement, retained failures and phase-specific retry.
- [x] Verify waiter cancellation, source loss, reentrant callbacks, fresh-epoch repair re-lease and projection-only retry.
- [x] Independent review and retained runner evidence: 19 tests, including running paired publisher and same-process fresh-reader reload.
- [ ] Separate native/AppDelegate wiring and desktop acceptance; not this slice.
