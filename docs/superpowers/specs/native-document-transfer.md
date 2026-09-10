# Native document transfer integration

Status: reviewed for implementation against the build brief by the root agent after the managed integration source freeze. Registry interface approved; monitor and native adapter interfaces are being coordinated. No transfer runtime evidence or F-02 completion is claimed. This is an executable integration supplement to [document-transfer.md](document-transfer.md), using the process owner and managed publisher now present. Existing canonical requirements remain authoritative. Independent subsystem review and a new integration source freeze are required before integration acceptance.

## First vertical slice

Move the selected editable tab from one existing application-owned window into the sole group of another existing window. Preserve the same EditorDocument, document UUID, complete pane pool, storage, layout managers, UndoManager, recovery authority/issuance fence, original bytes, URL, encoding/BOM, bookmarks, pin, settings and deferred presentation. Dirty documents are allowed; publication uncertainty, active work and composition are not. This is a move, not intake, close, history reopen, disk copy, reload or recovery re-adoption.

The source selects its nearest surviving neighbor; an emptied source stays open and empty. The destination selects the moved tab. Preserve pinned-first ordering: an explicit insertion index must be inside the moved tab's permitted pinned/unpinned segment, otherwise refuse before side effects. No MRU/open notification is emitted. An existing destination with another model using the same standardized file URL is refused without filesystem I/O; this does not promise filesystem-alias detection.

Stage 1 excludes new-window creation, same-group reorder, streaming handles and independent document groups. These are explicit subsequent stages, not exceptions that close F-02. Current `EditorPane` means a view of one document; it is not an independent document tab group.

## Current contracts and gaps

- `ApplicationDocuments` permanently retains models and one assignment. It supports reorder, pin and two-group metadata, but has **no cross-assignment transfer API**. `Record.assignment` is immutable; replace the internal record atomically while preserving handle, metadata and `.active` readiness. Never unregister/register or invoke adoption to simulate movement.
- `NativeApplicationDocuments` owns endpoints, intake, close, detached monitor bindings and the one `ApplicationSessionCheckpoints`. Its endpoint/controller and native projection contracts currently require one group. `SessionWindow` capture likewise cannot persist independent groups.
- `EditorWindowController.applyRegistryProjection` can remove/attach owned models, but invokes ordinary monitor detach/reattach and uses ordinary registry admission. It is not yet a transfer transaction endpoint. Transfer needs exact-token projection/selection authorization while ordinary mutation remains blocked, not a generic admission bypass.
- `advanceOwnershipGeneration()` changes ownership and close mutation generations without changing recovery authority. Rotation is necessary even when a document returns to its original window, so old async commands cannot regain authority.
- `NativeDocumentEndpointBindings.Fence`, `FileStateEndpointDetachment.binding` and the bridge's stored binding all include ownership generation. Their current exact checks correctly prevent using a pre-move token after rotation. Rotating before ordinary detach also fails the bridge's original binding check. A dedicated ownership-transition contract is required; removing these checks or adopting the same baseline again is unacceptable.
- Native presentation is now synchronous. Historical plan references to draining a native pane resolver worker do not describe current production. Reject an active `DocumentPanePresentation.installing` token and unfinished text processing; preserve all pending presentation values without inventing an async resolver seam.
- `captureCloseState()` evaluates exact dirty state and can fall back to full comparison. Transfer does not need dirty classification. Introduce a bounded transfer-state read instead of using close capture or `storage.string` as a cheap preflight.

## Proposed interfaces

Names below are proposed, not callable APIs. Final fields must be reviewed with the registry and controller owners before code changes.

```swift
struct NativeDocumentTransferRequest {
  let documentID: UUID
  let source: DocumentAssignment
  let target: DocumentAssignment
  let targetIndex: Int
  let workspaceRevision: UUID
  let ownershipGeneration: UUID
}
// Opaque registry-owned exact request token; no public memberwise initializer.
struct DocumentTransferLease { /* registry ID + unique request ID */ }

// Registry operations, all MainActor; transaction snapshots retain the same handles.
func reserveTransfer(_ request: NativeDocumentTransferRequest) throws -> DocumentTransferLease
func transferSnapshot(_ lease: DocumentTransferLease) throws -> DocumentTransferSnapshot
func stageTransfer(_ lease: DocumentTransferLease) throws
func restoreTransferAssignment(_ lease: DocumentTransferLease) throws
func cancelUnstagedTransfer(_ lease: DocumentTransferLease) throws
func completeTransfer(_ lease: DocumentTransferLease, willNotify: () -> Void) throws
func settleRestoredTransfer(_ lease: DocumentTransferLease, willNotify: () -> Void) throws
func retainTransferFailure(_ lease: DocumentTransferLease, error: Error) throws

// Process-owned orchestration; cancellation of a waiter cannot discard its transaction.
func start(_ request: NativeDocumentTransferRequest) throws -> DocumentTransferID
func wait(for id: DocumentTransferID) async throws -> DocumentTransferResult
func retryLayout(_ id: DocumentTransferID) throws
func requireSettled() throws
func endpointClosed(windowID: UUID)
```

`reserveTransfer` first checks only private registry state, installs its gate before any supplied callback, and validates structural request fields under that gate. No notification escapes an incomplete reservation. Generic capture, admission, metadata/group mutation, intake and close reject while reserved or retained-failed. `transferSnapshot(lease)` is the narrow internal read path for the process/endpoint adapters; it grants no unrelated edit permission. Duplicate/foreign/completed lease use refuses. Read-only handle identity lookup may remain available.

`cancelUnstagedTransfer` is available only before placement/ownership effects and emits no workspace mutation. Successful move or fully restored rollback settles through its own exact method. The `willNotify` boundary is a trusted process-internal, nonthrowing state assignment: it marks the process result settled before registry notification, runs while the private mutation fence still excludes public reentry, and may not invoke UI or service callbacks. Keep pause release as a separate exact-owned cleanup step with explicit publication-held status until it succeeds; do not advertise final-checkpoint readiness prematurely. Tests must prove ordering, and an alternative deferred notification receipt is acceptable only with equivalent exact-token ordering.

A scalar `NativeTransferDocumentState` captures identity, ownership/close-mutation/edit revisions, operation ID, saving, pending-publication ID, composing/marked-text status, macro/loading/preparation state, baseline revision and actual recovery authority/highest-issued fence. Pane geometry captures at most two pane IDs, attached membership/order, preferred ID, selections/origins, axis, pending presentation and warning. No full text/byte copy, comparison, hashing, decoding, file read, glyph traversal or bookmark scan occurs in the move transaction. Dirty and undo contents remain on the model untouched.

Endpoints need token-bound `captureTransferView`, `prepareTransferProjection`, `applyTransferProjection` and `restoreTransferProjection` methods. Their implementation should share existing projection logic, with a specific validated transfer capability threaded through registry validation and owned selection installation. A blanket boolean permitting ordinary commands is not acceptable. Break typing coalescing, dismiss/fence source transient commands, reinstall callbacks for **every pooled pane**, and reparent host views without `EditorPane.detach()` or rebuilding TextKit storage/history.

## Publication, reservation and synchronous commit

1. The process installs its strong transaction record before callbacks. Reserve the registry transfer gate; synchronously acquire one exact publisher pause. Refuse startup, quit, pending intake, close, history preparation, another transfer or unsettled application recovery before any endpoint effect. Capture selected source and exact destination incarnation; require both `.active` editable assignments.
2. Refresh affected native admission under the transfer token and drain the existing publisher pause/legacy tail. This preparation may suspend; no placement change has occurred. Recheck exact registry token, endpoint incarnations, scalar state, geometry, session capacity revision and source selection afterward. Cancellation or endpoint loss cannot release ownership or forget the pause.
3. The scheduler must not wait for this transfer from its own prepareCapture callback: do **not** add a transfer-drain wait to capture. A checkpoint already holding a capture may finish old placement. A not-yet-captured worker may receive a busy refusal; retain its truthful error and request a fresh checkpoint after settlement. Test this boundary explicitly. There is no second writer and no recovery close lease.
4. Inside one synchronous MainActor commit section, with no await/modal/event pump/I/O: capture rollback values; retire old endpoint action authority; rotate ownership; stage assignment/source-target snapshots in one registry mutation; apply both endpoint projections under the exact lease; install monitor ownership transition; revalidate after each callback-capable boundary. Only known internal changes advance the expected state. Never refresh expectations from arbitrary callback mutations.
5. On success, close the transaction's registry gate and publish one coherent workspace revision. Use the trusted pre-notification boundary to expose a coherent committed result before external notifications; publication-held status still prevents competing process work/final quit until exact cleanup. Consume the drained pause exactly once; other holds/final gates still control publication. Request the existing paired checkpoint. Destination focus/show is a final effect; inability to become key is a reported focus warning, not rollback of ownership.
6. On failure before assignment change, restore admission and drain/release any acquired unused pause. On failure after staging, restore source assignment/order/selection and both view receipts; attempt both restorations even if the first fails. Rotate ownership again to invalidate failed-target callbacks. Never restore the old ownership UUID. Do not overwrite genuine reentrant text/selection changes with old snapshots; such a violation is a retained reconciliation failure.
7. Failed rollback retains the registry-owned model, immutable rollback receipt, exact token and publisher pause. Affected mutation and final quit remain blocked with an actionable Retry Layout state. Explicit retry validates current endpoints and rebuilds projections/monitor ownership from the retained same model; no read, new model, adoption, actor repair or history mutation. If endpoints disappear, process ownership survives and explicit recreation must remain retryable after a failed recreation attempt.

Process `requireSettled` must be connected to user admission, intake/close admission, managed final checkpoint and quit. This is an explicit process contract addition; a window-only busy flag is insufficient. Release/notification reentry tests must prove an old completion cannot clear a new transfer.

## Monitor ownership transition

Implement and test this dependency before moving models. Keep ordinary endpoint detach/reattach semantics unchanged for same-ownership endpoint loss and history retention.

A dedicated transfer receipt must capture the exact bridge, old binding identity, old ownership UUID, accepted parent identity and transfer lease **before** changing model ownership. Revoke old endpoint actions/callbacks first. Retain the process-owned service registration and epoch; an independent endpoint-delivery UUID, sampled before the MainActor hop and rotated at suspend/attach, rejects old and in-transition queued deliveries. Cancel in-flight manual requests without erasing accepted facets/manual notices. A trusted process operation validates the registry lease and expected pre/post model ownership, then rekeys only the bridge's ownership context and supplies new weak endpoint callbacks. Baseline bytes, literal URL, file binding/baseline revision, retained parent/replacement continuity, manual/error facets and dismissal policy are preserved. Do not invoke adoptBaseline, clear original bytes, decode a file or manufacture an observation token. The existing registered token source and parent identity remain authoritative. Endpoint action authority rotates separately, including same-ownership pre-stage cancellation. No new observation token or service epoch is manufactured.

The existing detachment token cannot simply be reused with a fabricated binding. New transfer operations should have separate opaque receipts and exact single-consumption rules. Retain receipt/accepted ownership phase before any callback can fail. Rollback performs another validated ownership transition under the same process lease, including the case where target reattachment already consumed its first token. A consumed-token failure becomes explicit reconciliation-required state, never an implicit new registration with lost parent continuity. Final native install may remain manual-only after a watch failure, but must show its notice/retry action.

## Persistence and later scope

The move does not change document recovery authority or revision issuance. A checkpoint captured before reservation may acknowledge the same content under old placement; the next confirmed paired checkpoint/final quit must contain exactly one moved UUID in the target and no duplicate recovery item. A crash before that later acknowledgment may restore old placement. Failure to publish later metadata does not roll back the live transfer; existing retry/quit veto applies.

Stage 2 adds a new-window target only after aggregate live+unresolved capacity preflight. A prepared hidden endpoint is not registered/shown before commit; refusal disposes only that provisional endpoint and never the source. This requires a staged endpoint factory rather than calling current `createEndpoint`, which registers immediately.

Stage 3 implements independent document groups. Registry group metadata exists, but native projection/capture rejects more than one group; new group hosts, focused-group command routing, two tab strips and a reviewed session group schema are required. Preserve each document's own two-view split; four visible views need measured resource/geometry acceptance. Stage 4 extracts streaming ownership without whole-file text materialization and gives byte offsets a separate view-state type. These stages and actual desktop acceptance remain required for full F-02.


## Implemented monitor dependency boundary

`NativeDocumentEndpointBindings.reserveTransfer(document, transactionID:)` performs pure reservation and returns an opaque optional receipt (nil means no file-state bridge exists). Reserve it inside the process `suspendMonitor` port, after that process has latched cleanup responsibility; native `capture` remains side-effect free. The process retains it before `suspendTransfer`; every effectful operation requires a validation closure using `registry.validateTransferSnapshot(lease)`, never diagnostic `transferSnapshot`. The store remains a weak model owner.

`suspendTransfer` is exact-receipt idempotent. `attachTransfer` takes expectedPreviousOwnership and newOwnership plus weak live/render callbacks and validates the lease before/after callback-capable work. The previous value means the bridge's last accepted ownership, which can lag registry/model ownership after a refused attachment. `transferOwnership` is diagnostic phase information, not authorization. A second rotation supports rollback; same-ownership attachment supports explicit cancellation before staging. If suspension refused before any effects, that cancellation retires the pure reservation's callbacks under a newly valid lease before restoring them. It does not assume the failed operation completed.

`finishTransfer` consumes only its receipt and then releases buffered rendering. Process finalization must latch a distinct registry-settlement retry phase immediately after successful monitor finish; it must not attempt to replay a consumed receipt if later registry settlement refuses. Native rendering remains subject to the global registry mutation gate.

Ordinary detach/adopt/action methods refuse or remain unavailable while reserved. Ordinary invalidate records a fresh deferred request UUID. Finish refuses until `resolveTransferInvalidation` explicitly accepts the live attached endpoint, or `invalidateTransfer` validates terminal bridge disposal. Reentrant newer invalidation cannot be erased by an older resolution. Weak-model purge uses that explicit disposal path to cancel the otherwise process-owned registration. All normal same-ownership endpoint/history APIs retain their original checks.
