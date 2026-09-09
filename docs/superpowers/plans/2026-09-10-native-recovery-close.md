# Native recovery close implementation plan

Design: [native recovery close specification](../specs/native-recovery-close.md). Approach A preserves the existing paired-checkpoint durability boundary; no durable close journal is introduced.

## Status and ownership

- Reviewed design: complete, including pause-before-registry admission, drained cleanup of unused tokens, fresh-epoch re-leasing after rejected repair acceptance, and initially serialized close batches with actor-authoritative capacity preflight before revocation.
- Scheduler pause tokens: implemented/tested separately; application adoption remains planned.
- Authority-bearing receipt acknowledgement: implemented/tested separately; commit waits for actor value prerequisites.
- Recovery actor/store authority, checked deletion, repair and capacity preflight: separate implementation in progress. Do not infer completion from native planning.
- Model ownership/capture adapter: implemented and passed focused hidden model + existing shared-pane ownership tests; independent review and final integration are pending. No live registry, window projection, close UI or publisher migration yet. Repair installation remains deferred.
- Native registry/publisher/close integration and full acceptance: planned. Desktop acceptance remains subject to available authenticated automation; hidden model tests are not desktop evidence.

## Task 1 — model ownership and immutable recovery capture

Own EditorDocument plus a separate workspace-protocol conformance adapter and new hidden model harness. Keep registry protocol dependencies out of standalone model compilation. Agree exact API before changes. Add tests first for stable ownership generation, first-only adoption receipt correlation (repair installation deferred until exact mutation/process context exists), immutable captured authority, checked monotonic issued revisions, overflow refusal, exact scratch/dirty/clean disposition, encoding/BOM and pending-publication behavior. Exercise real shared NSTextStorage/native undo and two-pane identity without showing windows. Observe meaningful red before implementation; preserve original source hashes and outputs. Run scoped harness and existing ownership/dirty compatibility. Do not switch any controller writer in this task.

## Task 2 — process admission and strong registry ownership

After actor APIs are stable, add a process-owned close coordinator and model close-state adapter. Registry strongly owns logical documents; windows expose presentation endpoints. Begin with one serialized close batch, settling each document prepare/delete/repair fully before the next item preflight or revocation; do not run parallel items without actual capacity reservations. Acquire publication pause and retain provisional process transaction before beginClose can notify. On rejected begin, drain and release the unused token exactly once. Gate legacy quit admission independently from finalTask. Add reentrant callback/endpoint teardown and canceled-waiter tests. No managed close may enter the legacy pendingCloses queue.

## Task 3 — atomic production writer migration

Freeze model mutation/capture and stop/drain standalone legacy timers, debounce, recoveryWork and conflicting unresolved removals before adoption. Install returned authority on the exact owner. Switch coherent capture, authorized paired actor commit and authority-bearing acknowledgement together. Reject legacy managed writes before any mixed-batch mutation. Preserve genuinely never-managed standalone fixtures. Resource guards precede text copies; revisions never wrap. Test stale capture before/after repair and exact live-ID receipt coverage.

## Task 4 — native freeze and close/repair settlement

Wire every actual edit/undo/selection/composition/file/baseline/pane/tab admission and delayed completion to registry ownership. On close, acquire/drain, preflight actor-authoritative repair capacity before revocation/delete, then use exact lease/checked deletion receipt. Keep model and pause until registry+actor settlement. After actor repair success, retain new authority before callbacks; rejected registry acceptance obtains a fresh lease under that authority rather than retrying the invalid old lease. Test actual file mutations, uncertain deletion/publication, direct unsupported mutation detection, reentrant acceptance, secondary close requests and quota failures. Never write the original document path from recovery repair.

## Task 5 — close/quit/reopen endpoint integration

Route close-current/others/right/all/window through the owner. Normal window close waits asynchronously for settlement; successful empty endpoint teardown cannot delete a moved document. Forced endpoint loss retains process model/repair state. Preserve clean history bound10 and fresh UUID on reopen. Quit refuses unsettled close/repair, releases only its own pause on veto and uses the existing final paired publisher. Streaming close cancels its reader tasks without fabricated editable recovery payloads.

## Task 6 — retained integration and durability acceptance

Run new model/process tests plus existing native ownership, dirty, save, checkpoint, lifetime, session restoration and pane tests. Use the existing scripts/test-native-integration.sh after registering verified new runners; run scripts/swift.sh test for core compatibility. Retain real-file deletion/repair failure injections, paused-preparation deadlock checks, reverse-order lease release, receipt mismatch and post-repair rejection recovery. Fresh-process restore after a confirmed post-close checkpoint must exclude the closed ID and restore all other acknowledged bytes/layouts. Preserve and explicitly classify crash-before-receipt mixed-generation behavior as the existing limitation. Finish strict formatting/lint/public checks and independent review before app adoption claims.

Every task records planned/implemented/tested/blocked separately. A compiled adapter or view-free registry test is not proof that native ownership is live. Use synthetic fixtures and private unique evidence directories; do not publish raw buffers or machine paths.
