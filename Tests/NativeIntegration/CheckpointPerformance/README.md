# Real checkpoint/edit performance diagnostic

The retained wrapper built and executed on 2026-09-09. Its writer failed initial admission because the application remained inactive after bounded activation; no edits or restore were admitted. The separate earlier experiment produced one successful corrected smoke and three non-admitted repetitions. This is diagnostic tooling, not repeatability evidence.

From the checkout root:

```sh
scripts/benchmark-checkpoint-edits.sh
scripts/benchmark-checkpoint-edits.sh --full
```

Default is one writer/restore pair. `--full` requests three fresh pairs; run only after reviewing smoke success and reserving an exclusive CPU/GUI slot. Native windows use synthetic documents. No physical keyboard, pixel, minimum-machine or release-app performance assertion.

The public wrapper applies umask077, creates a unique ignored `.local/checkpoint-performance/run.*` directory, and ACTUALLY executes `scripts/swift.sh build -c debug`. It obtains the matching debug path only after that build succeeds. It prepares a private source copy, compiles an optimized native probe against the debug PadCore objects, and supervises owned children. Mixed debug-core/optimized-native configuration is explicitly recorded; it is not equivalent to a packaged Release app.

prepare.py never modifies checkout sources. Each tracing anchor must occur exactly once or preparation fails for review. Private copies wrap the original real RecoveryStore.save/SessionStore.save calls; no fake receipt/writer, timing gate, shortened debounce or quota change. One logical application checkpoint bridge is wired as in ApplicationCheckpointHarness. This bypasses AppDelegate launch/menu plumbing, not the real session/recovery services.

Evidence includes original/instrumented native-source hashes, instrumentation.diff, hashes for all six tool assets, linked PadCore object/module hashes, debug/native compile configuration, Swift version and probe binary hash. Compiler output/exit and every child log/result are preserved under unique directories. A missing object/module fails before linking. No shipping instrumentation hooks are introduced.

Protocol: real100MB open, strict active/key/visible/occlusion/focus/full viewport and screen geometry admission, initial real metadata ack, one same-length dirty edit, wait for observed real recovery.save, then eight native undo/redo operations with real snapshot publication. Require actual operation/write interval overlap, higher ack with no pending/error, real on-disk metadata and exact recovery readback, unchanged source file, then separate-process SessionCoordinator restore to safe scratch with exact text/selection. No original-file autosave or final checkpoint manufactures the tested result. Source length stays exactly100MB within current quotas.

Each owned child has60seconds, then only that child is killed/reaped. Failed writer suppresses its restore. Diagnostic/marker files are in sibling evidence/, NEVER inside state/ recovery storage. Partial rows persist before assertions, with validated flags afterward; event snapshots during waits preserve failure context. Explicit static gate reasons precede visibility precondition traps. Predicates remain strict and no hidden-layout fallback exists.

MainActor full-text oracle and small diagnostic writes occur outside edit timers but affect event spacing, ack processing and I/O contention. Store-call intervals include encoding/publication, not raw disk-only timing. Capture, commit-await, actual store invocation and ack events have distinct meanings. Report overlap and non-overlap samples separately, first/max/p95 andRSS, with these overheads. Never sum overlapping stages or attribute all ack lag to application code.

The prior three opaque repetitions remain unclassified at the individual-gate level. The new retained run identified application inactivity only for that run. Do not retroactively assume every earlier failure had the same cause. See docs/verification/checkpoint-edit-interaction.md for outcomes and limits.
