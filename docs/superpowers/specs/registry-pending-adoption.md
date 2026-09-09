# Registry pending adoption prerequisite

Status: registry API implemented and tested independently; no native intake/AppDelegate activation is claimed. Existing unmanaged registration and close behavior remains compatible. Root owns integration. Process-owned intake and UI described below remain planned.

## Recommendation and alternatives

Add an explicit pending-adoption lease inside each registry record. Insertion, strong ownership, assignment, metadata, admission state and retry correlation become visible atomically before `onChange`. Retain a failed record for explicit Retry. This closes the interval where ordinary `registerDocument` currently publishes an editable record before an external process owner can mark it pending.

An external-only pending dictionary is insufficient: registry callbacks can directly call registry APIs. Adopting before insertion would instead require a reservation and an actor-aware abort protocol; it is larger and offers no safe generic rollback after actor adoption. Keep ordinary `registerDocument` as explicitly unmanaged compatibility. Never use it then upgrade asynchronously for managed intake.

## Proposed exact interface

The following registry API is implemented. These types live in the native registry boundary; RecoveryAdoptionReceipt/RecoveryWriteAuthority remain the existing actor value types.

```swift
struct DocumentAdoptionLease: Equatable {
  // Registry-created immutable values; no public memberwise initializer.
  let registryID: UUID
  let requestID: UUID             // caller creates BEFORE registration
  let attemptID: UUID             // registry creates, changes on Retry
  let documentID: UUID
  let assignment: DocumentAssignment
  let ownershipGeneration: UUID
}
enum DocumentAdoptionStatus: Equatable {
  case unmanaged
  case pending(DocumentAdoptionLease)
  case failed(DocumentAdoptionLease) // diagnostic text kept by process owner
  case active
}
struct DocumentAdoptionState: Equatable {
  let documentID: UUID
  let ownershipGeneration: UUID
  let authority: RecoveryWriteAuthority?
  let highestIssuedRevision: UInt64
}
@MainActor struct DocumentAdoptionServices {
  let coordinatorID: UUID // actual process RecoveryCoordinator.coordinatorID
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentAdoptionState
}
// Add optional adoptionServices to registry init; legacy users need no adapter.
func registerPending(
  _ handle: any WorkspaceDocumentHandle,
  requestID: UUID, expectedRevision: UUID,
  metadata: WorkspaceDocumentMetadata,
  in assignment: DocumentAssignment, at index: Int, select: Bool
) throws -> DocumentAdoptionLease
func adoptionStatus(documentID: UUID) -> DocumentAdoptionStatus?
func failAdoption(_ lease: DocumentAdoptionLease) throws
func retryAdoption(_ failed: DocumentAdoptionLease) throws -> DocumentAdoptionLease
func activateAdoption(_ lease: DocumentAdoptionLease,
                      receipt: RecoveryAdoptionReceipt) throws
func captureReadyWindows() throws -> [DocumentWindowSnapshot]
```

New errors: adoptionUnavailable, adoptionBlocked, staleAdoption, invalidAdoptionReceipt. A request UUID is globally single-use within this registry, including failed/retired requests; duplicate requests do not insert or reset state. Initial scope supports editable handles only; streaming intake needs its own future explicit readiness policy rather than a fabricated recovery authority.

`registerPending` validates all ordinary capacity/ID/object/group/index rules, expected workspace revision, editable kind, stable ID/ownership and unadopted state under `mutating`. Read protocol getters/services under that fence, cache values, then recheck exact handle identity/ID/generation after callback-capable reads. All validation precedes structural insertion. Record and lease become authoritative in the same mutation, then normal stable-state notification occurs. The owner already retains a provisional intake transaction keyed by requestID before calling this method; returning a lease after onChange is not the point at which process ownership begins.

`failAdoption` accepts only that current pending attempt, marks failed without releasing model/assignment/IDs/group freeze, and notifies once. Repeated/stale failure is refused. `retryAdoption` accepts only exact failed attempt and same handle/assignment/ownership, rotates attemptID before notification, preserving all other state. It does not call the actor or clear an installed authority. Only the process owner chooses the next actor step from its retained receipt state.

`activateAdoption` is a synchronous trusted-owner handshake, not durability proof. Require exact registry/attempt/request, pending state, same strongly held object, ID/assignment/ownership, receipt.documentID matching the record, nonzero nextRevision, and readState reporting that exact installed authority. The managed fence must equal receipt.nextRevision - 1: no revision may have been issued while pending. The process owner additionally validates the expected RecoveryCoordinator identity before model installation; the registry must receive that expected coordinator identity through configured adoptionServices.coordinatorID and compare it rather than accepting any same-document actor receipt. Recheck registry lease/handle/ownership after the service call under `mutating`. Invalid receipt leaves pending unchanged. Duplicate activation is staleAdoption, never a counter reset. Registry stores active readiness only (no cached writer epoch) and rotates admission generation before notifying. It never writes model authority, mutates undo/storage, starts a monitor, or requests a checkpoint itself.

No dependency on global workspaceRevision at async completion: independent groups may legitimately change. The lease's exact assignment/ownership/attempt is the authority; same-group changes are blocked while pending. The owner must re-read state after any notifying call, since an activation callback can immediately begin a valid close. An activation return does not promise the record is still open afterward. No cleanup after onChange may overwrite reentrant newer state.

## Admission, projection and capture

Pending AND failed records deny every DocumentAdmission action, including edit, undo, select, baseline adoption, file operation, pane install, transfer and close. Native facade also checks process quit/admission state; registry `allows` is not a replacement for composition/save guards.

Extend ensureGroupOpen to reject either a close lease or pending/failed adoption anywhere in the group. Thus sibling selection, insertion, reorder and pin mutations refuse even when their target sibling is active. Extend ensureWindowOpen-dependent operations consistently (focus/axis/group teardown). Do not silently add a global freeze to independent groups. For `allows(.select, siblingID)` consult the same group rule used by actual selectDocument so menu admission is truthful. Existing close policy may allow a sibling close: preserve that policy unless the process owner chooses a stricter serialized-intake gate; pending document close itself always refuses before creating any close request/ticket.

Keep `window`/`handle`/`metadata` and existing `captureWindows` available for stable presentation snapshots, including pending rows. Changing captureWindows to throw would prevent truthful Retry UI and break existing projection callers. New `captureReadyWindows` refuses if any pending/failed record exists, including in an inactive window, and otherwise returns the same ordered snapshot. Managed paired publisher must use this ready gate plus exact live-authority/revision coverage; merely reading captureWindows is not publication admission. Also require no close/recovery lease for ready capture. Unmanaged records remain representable for compatibility, but managed paired capture separately refuses any unmanaged live item rather than inventing an authority. No omitted pending records or compactMap-to-partial-session fallback.

Status UI renders preparing or actionable Retry while preserving the tab and its full document. No direct Discard/close escape is proposed: abandoning an actor-adopted document requires the reviewed close/recovery settlement. Forced endpoint teardown detaches presentation only; registry and process owner keep the model and pending operation. Quit while pending is vetoed before final commit; no indefinitely awaited pending operation inside publisher prepare. Shutdown settlement policy is a later integration task, explicitly not an implicit unregister.

## Ordered intake and failure ownership

1. Synchronously check independent quit admission and aggregate live+unresolved SessionCapacity/provenance. Acquire the existing checkpoint pause lease. Retain process transaction, strong model and reservation/requestID BEFORE registerPending can notify. Do not enqueue this transaction in legacy pendingCloses.
2. registerPending atomically inserts blocked record. If it throws before insertion, no actor call has occurred: retain pause transaction long enough to drain and release exact token; discard locally prepared model/reservation only after proving no inserted record. A callback cannot throw through onChange's Void signature; successful insertion followed by reentrant endpoint loss is not registration failure/rollback.
3. Drain publisher pause; recheck exact pending lease, model, endpoint policy and process generation. Await actor adoption, storing returned receipt on the process transaction immediately upon return, before callback-capable native work. No cancellation may erase a possibly successful actor result.
4. Install adoption on exact model using existing first-only owner-generation check. Activate with that exact receipt. On success project state, then release the drained pause exactly once if the current process state permits. Further checkpoint capture uses captured managed authority.
5. Failure retains registry record/model, installed or returned receipt, reservation, and process error. Mark exact pending attempt failed if still current. Do not retry actor adoption blindly: before actor success, retry actor; after returned receipt but before installation, retry exact installation; after installation but before registry activation, retry activation with retained receipt. `retryAdoption` changes registry attempt identity only, never recovery epoch/revision. If unexpected model ownership/authority prevents safe continuation, retain an actionable blocked state for reviewed reconciliation; do not claim automatic Retry always succeeds.
6. Keep publication paused while a pending transaction still owns it, including failure; independent pauses prevent accidental resume. This intentionally blocks periodic publication until resolved and requires visible persistent status. A future policy may release a drained pause while captureReadyWindows refuses, but is not part of this minimal design. Pauses/reservations are process-owned and not released merely because a window closes.

No post-registration generic unregister API. No duplicate model installation on Retry. Existing native monitor, undo manager, storage, pane IDs and saved baseline remain unchanged across pending/failed/active transitions.

## Acceptance coverage and later integration plan

1. **Registry tests executed:** onChange for insertion observes strong identical handle, exact assignment/order/pin, pending state and all admissions refused; weak reference survives endpoint release. Same callback attempts captureReadyWindows, pending close, sibling select/pin/reorder/insertion; all appropriate refusals precede mutation. Ordinary projection remains available.
2. **Registry tests executed for applicable public inputs:** wrong registry/attempt/request/handle ownership, wrong coordinator/document authority, zero next revision, unmatched installed authority and prematurely issued revision reject activation without state/counter changes. Duplicate success/failure/retry cannot reset or release a newer attempt.
3. **Registry tests executed:** getter/readState reentry tries mutation while mutating; it is refused. Getter changes its own generation; final validation rejects. onChange can issue retry/activation/close only when actual state admits it; outer return never clears newer state. Callback sees pending before any owner await.
4. **Deferred process-intake tests:** fake actor with held completion: native endpoint close/quit request retains record and blocks final capture; actor success followed by model-install failure retains receipt. Retry installs exactly once without second actor adoption. Installed-model/registry-activation refusal retries exact retained authority, never advances epoch or reissues old receipt as new work.
5. **Registry 128-capacity/stale-revision tested; aggregate/unresolved intake deferred:** capacity128/32 and unresolved-provenance refusal occur before actor adoption. Duplicate persisted UUID/object/request cannot overwrite or rename. Rejected register drains/releases pause exactly once; callback endpoint loss after insertion does not enter that rollback branch.
6. **Existing registry compatibility and new readiness tests executed; paired publisher migration deferred:** original registerDocument, unmanaged close/history/repair and scheduler tests stay unchanged; sibling-group metadata policy is tested explicitly. New ready capture rejects pending/failed/close/repair; exact active managed capture succeeds with one logical recovery identity per document.
7. **Deferred intake/model integration:** retained text/encoding/BOM, native undo, monitor object/binding and pane IDs identical across failed retry; first-only model receipt installation; actor rejects old legacy writers. This is separate from view-free registry tests and still does not claim live AppDelegate adoption.

## Scope decisions for review

Use a registry-owned pending state rather than an external-only gate; keep legacy projection capture distinct from publication-ready capture; configure expected coordinator identity explicitly; retain post-registration failures without an unsafe removal path. Application NativeIntake, payload capacity tokens, transactional history reopen and UI wiring remain later work. Implementation must coordinate current close-owner source ownership before changing registry types or policies.

The actual actor exposes its existing immutable coordinatorID as internal nonisolated let; no generated expected UUID or dummy adoption supplies production identity. Test doubles may explicitly choose IDs. Repair changes model/actor epoch without updating registry readiness.

## Verification recorded

Behavioral compile-seam red: 39 tests, 9 adoption failures, all 30 legacy tests passed. An earlier fixture compile error is retained separately and is not counted as behavioral red. First implementation green: 39/0. Final expanded and formatted source: 41/0 (11 adoption + 30 unchanged legacy), including real temporary-store actor adoption and synchronous access to its actual coordinator identity. Original standalone registry runner also passed 30/0 after its additive PadCore dependency update. Strict Swift formatting and shell syntax checks passed. No AppKit, live native intake, publication migration, GUI or performance acceptance is implied.
