# Search child lifecycle state verification

Task 1 is implemented and independently approved at `eb3f1e177ccec82135c2251af7c6c7355f00dfd8`. This is the injected lifecycle state machine. Real launch, pipes, waitpid, helper integration and native search routing remain outstanding.

## Implemented boundary

`Sources/SearchExecution/SearchChildLifecycle.swift` confines control state to one serial queue. Admission stores the operation and monotonic deadline before invoking launch/timer seams. One request owns the slot; cancellation/deadline decisions can return while exact child ownership remains retained through both reap and channel-close acknowledgment. Facade loss requests cleanup without abandoning a pending launch or idle child. Unconfirmed cleanup stays quarantined and receives bounded background observation.

Typed policy, ticket, outcome, cleanup and internal collaborator contracts live in `SearchChildLifecycleTypes.swift`. Construction remains internal and injected until the real collaborators exist. No public fake launcher or claimed OS receipt is included. Waiter cancellation detaches only that observer; continuation state is removed before delivery. Generations, tickets, ordinals and timer tokens fence stale callbacks. Completed results survive later idle exit. Repeated shutdown inspects the original bounded cleanup attempt.

Background observation uses a fixed 100 ms cadence, with earlier one-time grace/idle deadlines when necessary. This is a scheduling policy, not a measured real-time guarantee. Pending launch conservatively reports channel closure unconfirmed. A recycling request tracks its physical cleanup generation separately from its new request identity.

## Evidence

`Tests/SearchExecutionTests/SearchChildLifecycleTests.swift` contains 32 deterministic cases. Synchronized gates and fixtures cover late launch after cancellation, signal/reap/close ordering, pre/exact/post deadline terminal handling, observer cancellation and refusal, installed-continuation reentry, healthy reuse/recycling, stale callbacks after simulated PID reuse, EINTR/ECHILD quarantine, idle/active exit, facade loss, shutdown, overflow and malformed URL admission. These are scripted effects, not real OS process tests.

- Final full core plus search suite: 563 tests, zero failures; 15.609 seconds suite elapsed, 17.94 seconds owned-watchdog command; no timeout.
- Final exact lifecycle source: 32 tests, zero failures; 3.723 seconds owned-watchdog command; no timeout.
- Strict scoped Swift formatting, public-source checks and diff checks passed.
- Independent specification and code-quality review approved the final source after all three material findings were resolved.

The review findings were reproduced before fixes: stale cleanup receipt during cancelled/deadlined recycling, excessive polling under a 1 ns grace policy, and premature channel-closure reporting during held launch. The regression run failed six assertions, then all 32 cases passed. Earlier idle-expiry, overflow-signalling and encoded-NUL issues also have retained behavioral red/green evidence. The original repeated-shutdown hang and unsynchronized test fixtures remain recorded as failures; they were replaced with one retained shutdown deadline and explicit synchronized gates.

The full 563 run preceded only relocation of one test comment. Production bytes are identical; the exact final test file was additionally checked by the 32-case run. Final SHA-256 values:

```text
b45f03bf7b681da2b93d793cbeed4010e48c7ff6f416ace0c0e9e0ce92df7c15  SearchChildLifecycle.swift
10493af1a5d9951141dce2767a675904044d67a8ca7946108f376e0cf01113d8  SearchChildLifecycleTypes.swift
7318712f4a61218f541f9d489d06782625cf37222ea4d0dd4c9848f9844b737c  SearchChildLifecycleTests.swift
```

Reproduce the focused deterministic suite with:

```sh
env NSUnbufferedIO=YES scripts/swift.sh test --scratch-path .build/search-child-lifecycle-repair --filter SearchChildLifecycleTests
```

Development verification wrapped every invocation in the private owned-process watchdog. Raw logs, manifests and reports remain ignored under `.local/search-child-lifecycle-task-1/` and `.local/search-child-lifecycle-repair-review/`. Full/adversarial suites continue to require an outer watchdog. Task 2 must add the checked-in real-process watchdog before running hostile child fixtures.

No dependency, public helper executable, package, GUI routing or release changed in this slice. It does not demonstrate hard regex termination, real descriptor closure, 100 MB memory bounds, performance targets or complete C-07/C-08 acceptance.
