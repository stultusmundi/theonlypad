# Executable registry close slice — proposed next boundary

Status: view-free close implementation tested; independent final review pending. Native integration and two-phase recovery close leases remain planned. Canonical scope is docs/superpowers/specs/document-transfer.md and its2026-09-10 plan. This narrows the next implementation to view-free registry close/admission state; native editor enforcement and recovery service changes remain mandatory later gates. Existing13 basic registry tests/APIs remain intact.

## Small API migration

Do not add the future move/factory/capacity service bag. Add one optional collaborator:

```swift
@MainActor struct DocumentCloseServices {
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentCloseState
}
init(closeServices: DocumentCloseServices? = nil)
```

Existing `ApplicationDocuments()` remains valid for its implemented basic operations. Close request/begin/repair APIs without closeServices throw `.closeUnavailable` before mutation; no default fake clean/dirty state. Actual app supplies a real kind-specific adapter only when native enforcement is integrated. Tests use honest fake handles with observable state; these prove registry bookkeeping, not NSTextView safety.

```swift
struct DocumentCloseState: Equatable {
  let kind: WorkspaceDocumentKind
  let ownershipGeneration: UUID
  let mutationGeneration: UUID
  let operationID: UUID?
  let isDirty: Bool
  let hasPendingPublication: Bool
  let hasPendingTextEdits: Bool
  let isComposing: Bool
  let canRetainCleanHistory: Bool
}
enum DocumentCloseDisposition { case retainCleanHistory, discardWithoutHistory }
struct DocumentCloseRequest {
  let admissionGeneration: UUID
  let id: UUID
  let documentID: UUID
  let assignment: DocumentAssignment
  let state: DocumentCloseState
  let metadata: WorkspaceDocumentMetadata
}
struct DocumentCloseTicket {
  let id: UUID
  let request: DocumentCloseRequest
  let disposition: DocumentCloseDisposition
}
enum DocumentAdmission { case edit, select, undoRedo, fileOperation, baselineAdoption, transfer, close, paneInstall }
enum DocumentCloseStatus {
  case open
  case closing(ticketID: UUID)
  case recoveryRequired(repairID: UUID)
  case repairing(repairID: UUID, attemptID: UUID)
}
enum DocumentCleanupResult {
  case removed
  case notRemoved(Error)
  case uncertain(Error)
}
enum DocumentCloseCompletion {
  case closed
  case retained(Error)
  case recoveryRequired(Error?)
}
func allows(_ action: DocumentAdmission, documentID: UUID) -> Bool
func closeStatus(documentID: UUID) -> DocumentCloseStatus?
func requestClose(documentID: UUID) throws -> DocumentCloseRequest
func beginClose(_ request: DocumentCloseRequest,
                disposition: DocumentCloseDisposition) throws -> DocumentCloseTicket
func completeClose(_ ticket: DocumentCloseTicket,
                   result: DocumentCleanupResult) throws -> DocumentCloseCompletion
```

Tickets/requests have fileprivate/internal construction controlled by registry, no public memberwise authoring; callers receive immutable receipts. All methods are MainActor. Getter `closeStatus` returns nil for unknown/unregistered documents. Basic live structural caps stay unchanged and are not expanded into aggregate unresolved-session admission here.

## Request, lease and completion semantics

requestClose enters the registry's short mutation/admission guard **before** invoking readState or any protocol getter. No revision/notification changes for successful pure capture. Require handle kind/ownership match cached registration identity; no active operation, composition, pending storage edit or existing close/repair lease. Do not infer clean from kind. readState may throw: release only short guard, leave state unchanged. Its callback cannot reenter mutation/capture because the guard is already held. A request is the state to which the user's confirmation is bound; do not manufacture another after confirmation without new approval.

beginClose enters guard, re-reads state, compares exact request state/assignment/registry metadata and identity, then installs fresh closing ticket. Dirty/changed text or pin/presentation change between request and begin rejects stale request without cleanup. retainCleanHistory additionally requires editable kind, actual clean state, no pending publication and history capability; reject if any condition false. discardWithoutHistory requires matching request but can close dirty state after caller confirmation. Pending publication is conservatively refused in this increment even for discard, preserving existing recovery resolution UI. The lease blocks **all** DocumentAdmission actions. Keep registry handle/assignment/group selected record until completion; public view state may remain readable.

Use existing onChange(UUID) as the only stable admission notification; avoid a second unused admissionChanged callback. Begin/complete/repair state changes advance workspaceRevision and publish once. Set persistent state and construct the return receipt first; release guard before onChange so allows() sees the correct committed state. No state cleanup or result reconstruction after notification. Reentry may legitimately request another unrelated operation; old completion never clears it. A reentrant listener can inspect closeStatus but cannot derive an unissued ticket to finish someone else's cleanup.

Existing basic mutations must honor leases: registration cannot duplicate a closing/repair handle, pin/reorder/selection/focus/axis changes involving its group refuse; empty-group/window removal already refuses assigned handles. Conservative group presentation refusal while any member is closing avoids changing confirmation/captured metadata. Unrelated windows/groups can continue. captureWindows stays allowed in stable closing state and includes the still-owned document; actual app checkpoint adapter later must not race the recovery-close lease. Registry provides status so that adapter can defer capture/admission rather than assume cleanup and checkpoint may run concurrently.

completeClose enters guard and verifies exact active ticket ID, cached object/document identity, assignment and frozen state. Duplicate/stale ticket throws without side effects, including after a newer close starts. For `.removed`, re-read authoritative state before disposal. Only exact match closes: remove live record and assignment only; reserve the document UUID permanently, and reserve its object identity while retained in history, remove ID from its group, choose the same-index next survivor or preceding last, and retain clean history if requested. No text/state mutation or recovery call happens in registry.

For `.notRemoved(error)`, the cleanup caller guarantees both original recovery content and old lifecycle write admission remain valid. Release the exact closing lease; preserve current model/assignment/metadata, return underlying error and notify stable admission. If an unsupported direct mutation occurred, retain that newer state rather than restoring old captured bytes. For `.uncertain(error)`, or `.removed` plus state mismatch/readState error, never dispose: retain the handle/assignment and enter recoveryRequired with a fresh repairID. This covers direct mutation and unprocessed storage batches that bypassed native admission. Cleanup may already have deleted recovery. Do not reinterpret failure as proof nothing was removed.

Clean history is owned by registry as bounded10-per-window entries retaining handle+metadata after successful cleanup only. Read-only `closedHistoryCount(windowID:)` is sufficient for tests; no fake reopen method in this slice. Existing future reopen adapter will create a freshUUID/model and preserve pin intentionally (current old clone resets pin; this is a reviewed new behavior to test). History object reservations release on empty-window unregister/eviction; retired document UUID reservations never release during the registry lifetime; no live assignment or recovery snapshot is counted for a history entry. Dirty discard and streaming kind do not enter clean editable history.

## A real recovery exit, not a permanent dead end

**Current implementation hazard:** RecoveryCoordinator.close inserts UUID into its permanent `closed` set *before* storage.remove. Both successful cleanup and removal failure can leave it tombstoned. Ordinary persist/checkpoint for that UUID refuses. Therefore an adapter must not map a thrown current close call to `.notRemoved`, and an ordinary checkpoint cannot clear recoveryRequired. Do not wire this registry slice directly to current close until the recovery transaction below is implemented/tested.

Prefer a **two-phase recovery close lease** in the later integration: prepareClose(id,expectedRevision) returns an unforgeable actor-issued lease, suspends writes for that identity and removes/syncs the current record; it does not permanently tombstone before registry's final decision. On registry `.closed`, finalizeClose(lease) retires the identity. On failure/changed state, restoreAfterClose(lease,freshSnapshot,newRevision) validates the exact lease and publishes+syncs a fresh snapshot, then releases suspension and returns a receipt. If publication is uncertain, retain lease and pending evidence, refuse normal writes/quit, and use exact validation+fresh confirmed publication. No arbitrary reset of a UUID tombstone. Existing queued old-revision writes remain stale and cannot revive removed content. This recovery API is a separately reviewed/implemented dependency, not a method added to this view-free registry task.

The registry's minimum retry surface:

```swift
struct DocumentRecoveryAttempt {
  let id: UUID
  let repairID: UUID
  let documentID: UUID
  let assignment: DocumentAssignment
  let state: DocumentCloseState
}
struct DocumentRecoveryReceipt {
  let attemptID: UUID
  let repairID: UUID
  let documentID: UUID
  let mutationGeneration: UUID
  let publicationID: UUID
}
func beginRecoveryRepair(documentID: UUID) throws -> DocumentRecoveryAttempt
func completeRecoveryRepair(_ attempt: DocumentRecoveryAttempt,
                            result: Result<DocumentRecoveryReceipt, Error>) throws -> Bool
```

beginRecoveryRepair is allowed only in recoveryRequired; readState under short guard, capture actual latest state and issue one attempt while keeping admission frozen. On readState failure remain recoveryRequired and expose error, allowing explicit retry. `completeRecoveryRepair` matches current attempt+repairID+document/assignment and current exact state; receipt matches attempt/repair/document/mutation identity. Only verified **fresh durable** recovery publication plus restored actor lifecycle admission may produce that receipt. Readback alone is not acknowledgement. Failure, stale receipt or changed current state retains recoveryRequired, releases only that attempt slot, and permits another explicit attempt. Successful completion returns open without closing the document; another user close starts with a fresh request/confirmation. Notification comes after guard release with bool result computed before reentry.

Receipt creation belongs to a later trusted native/recovery adapter, not UI. The isolated registry can validate typed correlation but cannot prove filesystem durability; tests use synthetic receipts and label that boundary. Before native adoption, restrict receipt construction to the adapter path/verified actor result and test actual uncertain publication/lease restoration. There is no fallback button that simply clears recoveryRequired. App action is Retry Recovery; on failure retain content and actionable error. Forced shutdown remains OS behavior, not claimed durable protection.

## Native integration gate (not implemented by this slice)

Actual handle adapter supplies mutationGeneration updated by all content/encoding/BOM/baseline/pending/publication/presentation changes plus pending NSTextStorage editedMask. Native canMutate/canFocus, menu/responder undo/redo, operation begin/adoption and each suspended completion consult registry.allows. Disable edit/select controls in closing/repair states, but also guard programmatic mutation APIs. Real tests hold cleanup, invoke actual NSTextView edit/undo/save/baseline and stale callback paths, then verify refusal; failure restores admission. Direct storage bypass inside beginEditing must trigger final mismatch and retained recoveryRequired, never data disposal.

OS windowShouldClose first vetoes while tickets drain; duplicate requests do not duplicate cleanup. Failed cleanup keeps remaining window/tab visible. Only empty assignment list and revision-bound close permit authorize second native close; windowWillClose is final teardown, not cleanup initiation. Global quit must drain/refuse close leases and respect recoveryRequired; checkpoints must coordinate recovery actor lease. Neither basic fake tests nor registry allows() alone prove these paths.

## TDD sequence and exact test boundary

Use existing `scripts/test-application-documents.sh` frozen two-source Foundation package, adding close state/types/tests in owned sources only after approval. No AppDelegate, editor, recovery actor or native view edits in this slice.

1. Compile-only request/begin seam, then behavioral red: held ticket leaves handle assigned and blocks allows for every action; basic metadata/group mutators affecting it refuse; unrelated group still works; stable onChange sees correct admission.
2. Request confirmation red: mutate fake state, pin, kind or ownership after capture; begin rejects and cleanup caller invocation remains0. `readState` nested registration/close/capture rejected from first callback; throwing state provider leaves no revision/lease.
3. Cleanup `.notRemoved` releases exact lease/retains model; `.removed` exact state removes once/history semantics; duplicate completion cannot remove newer record. Selection neighbor, permanent retired UUID refusal and retained-history object reservation validated.13 prior basic tests unchanged.
4. `.removed` changed fake mutationGeneration/pending edits or throwing state provider retains model in recoveryRequired; `.uncertain` likewise. All admissions/quit-query false. Fake-kind cases cover streaming cannot claim clean history.
5. Repair begin/failure/retry/correlation: at most one attempt; wrong repair/attempt/document/generation receipt cannot clear; state changes during held repair preserve recoveryRequired; valid receipt reopens admission, doesn't close; older completion cannot clear newer attempt. Underlying error retained in result.
6. Stable notification reentry on begin/complete/repair observes committed state and can operate on unrelated handle without old cleanup reverting it. Request/capture pure path emits0notices; refusals unchanged.
7. Independent review before marking view-free close slice tested. Actual cleanup durability, native mutation guards/OS close and recovery lease remain explicitly unimplemented until separate integration tests pass.

## Review amendments

Retired document UUIDs remain reserved even after history eviction or window closure; they must never reenter a recovery lifecycle. Retained history objects remain reserved even if their protocol ID changes. Reopen uses a fresh model and UUID. Window/group identity reuse remains unchanged. This corrects the original proposed index-release behavior. No new namespace compatibility problem is established: current SessionRestoration already requires disjoint window/tab/recovery namespaces.

Requests bind a per-document admission generation, rotated on begin/completion/repair; an old confirmation cannot start a new close cycle even when content is unchanged. Unrelated workspace changes do not invalidate that generation. Regression covers safe cleanup failure and successful recovery repair.

## Current verification boundary

`./scripts/test-application-documents.sh` passes 30 tests: 13 prior ownership tests and 17 close/admission tests. Initial unavailable seam produced 10 failing new tests; separate pin/selection/order/axis ABA regressions produced four assertion failures before the generation fix. Strict scoped swift-format lint and shell syntax checks pass. This proves view-free bookkeeping/correlation with synthetic handle state, not native editor admission or durable recovery. The required two-phase recovery-close dependency is still unimplemented and current RecoveryCoordinator.close must not be wired to this API.

Affected-group metadata, ordering and selection changes also rotate confirmation generations, including changes away and back. Unrelated groups remain independent. Caller retains the supplied underlying repair error; Boolean repair completion reports whether admission reopened, never claims filesystem validation. Retired UUID reservations grow with closed document identities for this registry lifetime by design.
