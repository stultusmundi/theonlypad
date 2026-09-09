# External file action execution

Status: action reader component verified; service admission and native actions outstanding.
This extends the reviewed external-file monitoring design and native integration map.

## Shared worker admission

Add explicit read and confirmation-revalidation job variants to the process-owned
FileMonitorService. Use the existing two workers and bounded manual admission rather
than detached tasks per document. A read invokes ExternalFileActionReader.read; a
confirmation job invokes revalidate on its retained snapshot. Both are synchronous
worker operations, include the scoped materialization guard, and honor cancellation.
Neither registers a watch, adopts a baseline, or writes original files.

The sixteen manual slots must be shared by checks and these actions, including
successful results waiting for callback consumption. A cancelled queued callback
must not release its admission while its closure still retains a large snapshot.
Release the slot only after worker and callback obligations finish. Limit simultaneous
action snapshots separately if native confirmation panels retain results after
delivery; the manual queue cap alone does not bound panel-owned memory. Start with
one process-wide active read/confirmation transaction, with explicit busy feedback;
release its lease on completion, cancellation, dismissal or owner invalidation.

Expose typed cancellation, capacity, observation-change, decoding and policy/read
failure to the caller. Never return empty content on failure. Test initial refusal,
inline cancellation, cancellation while a syscall is gated, late successful results,
stopped service, mixed check/read scheduling, blocked callback capacity and released
snapshot ownership. Keep descriptor accounting and close-only cleanup unchanged.

## Native transaction

1. Capture the bridge's live action context and every applicable pane selection.
   Claim the process action lease and a document operation UUID; retain the captured
   authority separately because setting busy changes the live context.
2. Freeze mutation in every pooled pane and enqueue the checked read. Switching tabs
   does not redirect the action. Validate document membership, binding, acknowledged
   revision, edit revision, current encoding/BOM, pending-publication UUID, recording,
   composition, app delivery generation and operation ownership after completion.
3. Open Disk Version creates a URL-less scratch only after successful decode and
   admission. It never changes source bytes, saved state, undo or save destination.
4. Reload with dirty or uncertain state uses an explicit discard confirmation with
   Cancel as default. Recheck owner authority after the nested dialog and enqueue
   exact snapshot revalidation; do not treat the pre-dialog read as current.
5. On admitted reload, replace the targeted model, retain pane identities/axis/focus,
   clamp each selection safely, reset undo/bookmark/composition bookkeeping, adopt
   bytes and decoded metadata together, acknowledge once, and rebind once. Only then
   finish the operation and reconcile deferred presentation. Capture a checkpoint
   for actual content adoption, never for status-only updates.
6. Failures preserve buffer, undo, acknowledged baseline and pending evidence.
   Release only this transaction's operation/action lease and restore interactivity
   only for live eligible panes. Recheck owner lifetime before presenting an error.

This is not an atomic transaction with arbitrary external writers. A source can
change after the final validated read; a future watch observation or safe-save
comparison reports that conflict. The buffer adopts exactly the validated snapshot,
never an unverified later source or an inferred save receipt.

## Verification and current evidence

The reader's seven real-file tests and full279 core tests passed; see
`docs/verification/external-file-monitoring.md`. Planned native acceptance includes
tab switch, all-pane selections, dirty/uncertain confirmation, changed disk during
dialog, late close/quit, recording/composition, action cancellation and failed decode.
The shared service and real desktop workflows remain unimplemented/unverified.

Proven component command:

```sh
scripts/swift.sh test --scratch-path .build/external-action-reader --filter ExternalFileActionReaderTests
```
