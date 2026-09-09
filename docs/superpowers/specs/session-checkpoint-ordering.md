# Periodic session checkpoint ordering

Status: reviewed design; isolated storage candidate implemented/tested and independently re-reviewed. Production integration and scheduler remain outstanding. Requirement A-06 remains partial. This document addresses periodic session metadata, separately from optional automatic saving of original files.

## Existing behavior and constraints

Editor recovery already captures periodic text snapshots through a serial RecoveryCoordinator. Its per-document revisions and close tombstones reject obsolete writes. Normal quit freezes editors, persists a global recovery batch, then saves session metadata. Recent paths are currently persisted only at quit. SessionCoordinator preserves unresolved entries and refuses writes over unreadable/future metadata.

Periodic checkpoints must preserve that content-before-metadata relationship without freezing normal editing. They must not write original user files. They must also coexist with explicit close/discard, recovery removal, startup restoration, recent-history changes and the final quit snapshot.

## Proposed sequence

1. Notify a single application checkpoint coordinator of document/tab/window/view-state/history changes. Debounce ordinary notifications and coalesce them into a monotonically increasing requested generation. Do not start before startup restoration is complete. Keep at most one write in flight and one pending generation, rather than one task per keystroke.
2. After draining pending removals, synchronously capture recoverable document snapshots, window/tab metadata and recent history together on the main actor. Include an explicit set of live tab IDs; unresolved records remain in metadata without an invented recovery acknowledgement. Revisions identify immutable capture issuance, not edit counters.
3. Submit the capture to one non-suspending method on the existing RecoveryCoordinator. Before any mutation, require exact unique recovery coverage of live tabs, nonnil snapshots for live scratch tabs, fresh revisions and absence of close tombstones. Persist recovery before synchronously saving the captured session. Return a receipt only after both succeed. Do not recapture metadata after waiting for recovery. A partial failure can leave newer recoveries but cannot produce a success receipt.
4. Serialize the SessionStore write. A later requested generation cannot be overtaken by an older save. After completion, immediately process one pending generation if needed. Surface failures through a persistent actionable status, with bounded retry on new changes; do not repeatedly open modal alerts on each caret move.
5. At quit, stop scheduling ordinary checkpoints and drain/cancel them at a defined boundary before the existing final frozen snapshot. The final quit save must be the last session write. On veto, resume normal checkpoint scheduling with the newest generation.
6. Closing/discarding a document during an in-flight checkpoint must not resurrect its recovery record. Retain RecoveryCoordinator tombstones and schedule the post-close metadata generation. The admitted actor operation has no internal suspension; cleanup queued after admission follows it. Do not label a session generation committed until its store write succeeds.

## Required evidence before adoption

Use injected suspended recovery/session saves to exercise older/newer generations, close/discard during a checkpoint, startup delay, corrupt metadata, write failure, quit overtaking pending work, quit veto and shutdown with no later edits. Real temporary stores must establish that metadata never refers to unacknowledged new scratch content and obsolete saves cannot overwrite newer state. Force-terminate the packaged app after a completed checkpoint and demonstrate exact acknowledged content, tab order and history without a prior normal quit. Measure snapshot overhead for large documents and avoid introducing a new main-thread full-text comparison.

Optional autosave of original files is separate: it needs an explicit preference, AtomicFileStore conflict/backup protection, bounded concurrent writes and a clear policy for edits arriving during save. This metadata design does not implement or imply that feature.

## Implementation review (2026-09-09)

The current recovery revision is a capture counter, not an edit counter. A successful `persistBatch` can silently skip stale or tombstoned entries, so it cannot acknowledge the exact requested content. SessionCoordinator's current async `persist(windows:)` also merges state after waiting for removals; it is safe to reuse only after separating its drain and synchronous capture stages. SessionStore's locks protect individual writes, not application generation order.

Refine steps 2–3 to capture text and metadata together on the main actor, then publish through a single non-suspending recovery-actor method with explicit accepted-revision receipts and synchronous SessionStore publication. Do not recapture newer metadata after awaiting the recovery barrier. New changes request one pending generation. Pause and drain this writer before the final frozen quit capture; cancellation is not a publication barrier.

The existing stores do not provide an atomic multi-file crash snapshot. Newer recovery can coexist with older metadata, and a crash before post-close metadata publication can leave a closed file tab or unresolved scratch record. In-memory tombstones prevent obsolete recovery writes during the current process, not durable metadata resurrection. Exact recovery after an acknowledged checkpoint is testable when no later edit/write occurred. Stronger immutable-generation or durable-close guarantees require a separately reviewed persistent journal/manifest design.

Executable subsystem plan: [Periodic Session Checkpoints](../plans/2026-09-09-periodic-session-checkpoints.md). Production files and GUI behavior were not changed or tested as part of this review.

## Isolated storage candidate review

The ignored Task1 candidate passed its real-store harness and the existing RecoveryHarness. Independent review found two gaps and then verified their corrections: exact live-tab receipt coverage prevents omitted/cleared scratch recovery; uncertain session publication blocks all subsequent commits until matching readback, followed by a fresh generation and save. Readback compares metadata and exact UTF-8 paths, does not retroactively issue a receipt, and a mismatch retains the block. Before-publication fault coverage preserves exact prior Session.json bytes. This is candidate evidence, not integrated app or crash acceptance. Task2 scheduling is being implemented separately in the ignored candidate area.
