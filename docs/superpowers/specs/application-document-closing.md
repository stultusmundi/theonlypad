# Process-owned serialized document closing

Status: view-free implementation tested; independent final review passed. Native integration remains planned. Uses `docs/superpowers/specs/native-recovery-close.md`, current ApplicationDocuments close/repair APIs, SessionCheckpointCoordinator pause tokens and the approach-A RecoveryCoordinator. No additional recovery/session writer or durable-close journal.

## Boundary and public API

One MainActor application-owned instance retains the actual registry, recovery actor, publication control and native adapter. It owns one batch at a time, at most128 unique IDs, and at most one admitted document transaction. Completion of an external waiter is not ownership. A source endpoint is only a presentation target; losing it never releases a model/lease/pause.

```swift
struct DocumentClosingID: Hashable { let rawValue: UUID }
enum DocumentClosingStage {
  case confirming, acquiring, admitting, draining, preflighting, preparing, deleting
  case registrySettlement, retiring, capturingRepair, repairing
  case installingRepair, needsFreshLease, projecting, drainingUnusedPause
  case failed, settled
}
struct DocumentClosingStatus {
  let id: DocumentClosingID
  let documentID: UUID?
  let stage: DocumentClosingStage
  let recoveryPaused: Bool
  let error: Error?
}
enum DocumentClosingResult {
  case completed(closedIDs: [UUID])
  case cancelled(closedIDs: [UUID])
  case retained(closedIDs: [UUID], documentID: UUID, error: Error)
}
@MainActor final class ApplicationDocumentClosing {
  init(registry: ApplicationDocuments, recovery: RecoveryCoordinator,
       publication: DocumentClosingPublication, native: DocumentClosingNative)
  var status: DocumentClosingStatus? { get }
  var hasUnsettledTransactions: Bool { get }
  var onChange: (() -> Void)? { get set }
  func start(documentIDs: [UUID], sourceWindowID: UUID) throws -> DocumentClosingID
  func wait(for id: DocumentClosingID) async throws -> DocumentClosingResult
  func retry(_ id: DocumentClosingID) throws
  func cancelBeforeAdmission(_ id: DocumentClosingID) throws
  func requireSettledForFinalCheckpoint() throws
  func requireCaptureAdmission() throws
  func endpointDidClose(windowID: UUID)
}
```

`start` synchronously validates count/duplicates, process admission and existing batch absence. It installs the strong batch record **before any callback**, then starts its own MainActor Task. It never awaits a caller-owned Task. `wait` merely observes that task/result; cancellation of a waiter does not cancel it. No unbounded result history: retain the active record and most recent terminal result; older IDs throw expiredResult. `retry` only resumes a failed owned stage, never starts another batch or repeats already-confirmed deletion. Explicit cancel is admitted only before a registry ticket exists; once epoch revocation might have happened, cancellation means a bounded repair path, not throwing away the Task.

Initial scope is editable handles. `start` must explicitly refuse unsupported streaming kind without presenting a fake repair snapshot. Streaming close has a different paging-owner contract and remains a later typed branch; full F02 is not claimed by this coordinator slice.

## Concrete collaborators

```swift
@MainActor struct DocumentClosingPublication {
  let requireApplicationAdmission: () throws -> Void
  let acquirePause: () throws -> CheckpointPauseToken
  let drainPause: (CheckpointPauseToken) async throws -> Void
  let releasePause: (CheckpointPauseToken) throws -> Void
  let requestCheckpoint: () -> Void
}
struct DocumentClosingCapture {
  let state: DocumentCloseState
  let snapshot: RecoverySnapshot
  let authority: RecoveryWriteAuthority
  let highestIssuedRevision: UInt64
}
@MainActor struct DocumentClosingNative {
  let confirm: (DocumentCloseRequest, UUID) async throws -> DocumentCloseDisposition?
  let applyAdmission: (any WorkspaceDocumentHandle) throws -> Void
  let drainLegacyWrites: (any WorkspaceDocumentHandle) async throws -> Void
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentCloseState
  let capture: (any WorkspaceDocumentHandle) throws -> DocumentClosingCapture
  let installRepair: (any WorkspaceDocumentHandle, DocumentRecoveryAttempt,
                      RecoveryRepairReceipt) throws -> Void
  let projectRegistry: () throws -> Void
}
```

These are wiring closures over real owners, not mock receipt services. `confirm` receives a frozen registry request and source-window ID; it invokes a native confirmation or returns a policy-authorized clean close. Nil is user cancellation. Source disappearance may cancel confirmation; after admission it cannot cancel cleanup. Core tests can authorize explicit synthetic disposition while still using real registry, actor and scheduler. No service supplies a fabricated deletion/repair receipt: only the actual recovery actor does so. Actor fault injection is confined to real store operations in tests.

Publication closures delegate to the existing ApplicationSessionCheckpoints/scheduler, not another timer or writer. `requireApplicationAdmission` is independent from scheduler finalTask: it rejects application quit preparation before commitFinal is latched. `requireCaptureAdmission` is the synchronous guard used by ordinary/final coherent capture, including zero-window captures. Publisher prepare checks this owner and promptly refuses; it must not await its drain (would deadlock with this owner's publisher drain). Existing legacy pending cleanup drain stays distinct.

Native capture is exact-handle based, never active-tab based. It produces one immutable RecoverySnapshot even for a clean file, its complete close state, installed authority and highest-issued counter in that epoch. Native checks scalar bounds before bridging text, but actor preflight is authoritative. Capture does not increment the recovery revision, mutate text, clear undo or adopt a baseline. Recovery authority/counter installation is ephemeral ownership metadata and must not itself increment logical close-state mutationGeneration, otherwise every registry repair acceptance would be stale. Logical text/encoding/baseline/presentation changes still advance that generation.

`installRepair` checks actual handle identity, document ID, registry assignment/active repair attempt and exact complete current state against the attempt before changing authority/counter. It installs only the exact actor receipt. It must leave all old fields unchanged on refusal. Process stores receipt first, so even a callback throw after a partial erroneous install does not lose the fresh actor authority; this is tested and reported, not treated as acceptance. Actual implementation should perform checks first, then a nonthrowing field assignment.

`applyAdmission` renders disabled/enabled native controls by querying registry, without changing logical document state. It cannot be the only mutation defense: all real native handlers/undo/file operations consult the registry. `projectRegistry` updates attachments/tab list/history views from registry ownership; it never deletes recovery or writes a session. A projection failure retains process task and pause; retry only projection/retirement stages, not deletion. The registry remains authoritative even if a source endpoint disappears. Reattaching a retained model to a replacement endpoint is a separate native presentation action, not a registry identity change.

## Internal owned record

A Batch stores ID, requested document IDs/order, current index, sourceWindowID?, closedIDs, task, phase revision UUID, optional pause token plus `pauseDrained` flag, optional DocumentTransaction, and last error. A DocumentTransaction strongly retains handle, immutable request and ticket, initial coherent capture, optional actor lease, optional close receipt, optional registry repair attempt, latest actor repair receipt/new authority and its current highest-issued fence, and settlement stage.

Callback discipline: set stage/phase UUID and all strong ownership/evidence before callback. After each callback/await check exact active batch ID + phase UUID and expected registry membership/status. Callback reentry through `start`, `retry`, or cancel refuses while an operation is active. onChange runs only after stable state/result prepared; no unconditional cleanup after it. No global `defer { releasePause }`: failures may require indefinite hold. Release consumes one known drained token and is recorded before status callback. If release throws, retain token/evidence and fail explicitly.

One batch at a time avoids cross-batch recovery reservation/refcount complexity. Other scheduler owners may still hold tokens; releasing this exact token cannot override theirs or legacy quit pause. Checkpoint requests while paused coalesce scalar generations, never copies of closed documents.

## Exact ordered state machine

### Fresh item and confirmation

For each item, fetch the strong registry handle and call registry.requestClose immediately before its own confirmation. Do not capture all requests once: closing the first item changes the group's admission generation, making later pre-captured requests stale. A batch close-all confirmation may authorize an unchanged original content set only if a separately reviewed confirmation policy proves that; initial implementation confirms each currently dirty item independently. Clean items use the actual clean-history policy. No silently recaptured request reuses an old dirty approval.

After confirmation, recheck application admission and batch phase. For the first admitted item acquire a pause token synchronously and retain it **before** registry.beginClose can notify. Existing pause can remain held across later item confirmations. Call beginClose with that exact request/disposition; then store the returned ticket and apply native admission. The strong provisional record already exists during beginClose callbacks. Native/onChange reentry cannot start another batch.

If beginClose refuses, no actor authority changed. Drain the unused token before release even if caller canceled; releasePause before drain is invalid. Stop batch with prior closedIDs retained and an actionable result. A native admission-render failure after ticket but before actor prepare settles registry `.notRemoved` only because actor/bytes were not touched; keep projection error visible if rendering remains broken.

### Drain and preflight

Await publication.drainPause and native.drainLegacyWrites. An already-running paired commit can finish before this drain completes. No new managed capture/writer begins after the pause is acquired; never-managed standalone writers relevant to the model must drain too. Recheck exact ticket membership/model state and capture once. Require capture snapshotID, authority.documentID, state equal ticket.state, and same installed authority/highest-issued epoch. One actor preflightRepair uses this exact snapshot before prepareClose revokes anything. It checks actual UTF16/count/encoded-byte inventory without quarantining; normal empty private directory initialization is permitted. No capacity reservation is claimed.

All writer sources remain frozen and batch items are strictly serial: previous document fully settles before next preflight. If preflight refuses, registry.completeClose(.notRemoved(error)) is safe because authority/recovery records have not changed. Render/project current state, drain/release hold, report retained. Never call legacy close. Capture may be retained until final settlement for repair reuse; replace it with a fresh capture only after an exact newer registry repair attempt exists. At most one such large snapshot is held per active document (avoid retaining old plus new once no longer needed).

### Actor prepare and deletion

Call prepareClose(authority, highestIssuedRevision, registryTicketID). On thrown pre-admission failure, actor contract leaves epoch open; settle known `.notRemoved` only if actor operation definitely failed without returning/acquiring a lease. Current prepare performs only synchronous validation and memory transition; no failing external work follows revocation. Future changes must preserve that contract or return a lease-bearing failure. Store returned lease before callbacks. Recheck model state after await; mismatch routes to registry recoveryRequired and repair without deletion.

Call finalizeClose(exact lease). Regardless of external waiter cancellation, the process task receives/stores result. On error, lease is still owned and epoch revoked: registry.completeClose(.uncertain(error)), never `.notRemoved`. Hold pause/model and expose Retry Recovery. On receipt, store it, verify exact lease/document/ticket and pass `.removed` to registry.completeClose. Registry itself compares full state before disposal.

- `.closed`: store registry settlement before callbacks, call actor.retireClose with exact stored deletion receipt. If retirement fails, retain task/evidence and retry only retirement. Never recreate a model under its retired UUID. On success, project registry attachments/history and record closedID. A projection failure retries projection only. Strong process reference may release only after both registry/actor settled and projection handling established.
- `.recoveryRequired`: keep model/ticket/lease; enter failed repair state and retain pause. No automatic repeated retry loop.
- `.retained` after an actor deletion receipt is an invariant failure, not safe reopen; report and hold. Production adapter passes correct result variant, so this cannot occur in normal flow.

### Explicit repair and unaccepted fresh epoch

`retry` starts one bounded repair attempt. First ensure actual registry still owns the exact handle/assignment and is recoveryRequired (or the previous owned attempt can be completed as failed). Obtain registry.beginRecoveryRepair, then capture exact latest snapshot/state. Capture must match that attempt; mismatch completes this attempt as failed, retains frozen model/pause and waits another explicit retry. Need no preflight reservation now because no other writer progressed, but actor still enforces actual quota; unexpected external occupancy remains an explicit failure.

Call restoreAfterClose(owned lease, attemptID, mutationGeneration, snapshot). Store every returned receipt and fresh authority **before any native or registry callback**. On actor failure, complete current registry attempt as failed and retain same actor lease; publication uncertainty is not acknowledgment. Original receipt/error evidence stays in the process-owned transaction.

On actor success, verify exact lease, document, attempt/mutation identity. Call native.installRepair, then registry.completeRecoveryRepair with a DocumentRecoveryReceipt constructed only from that exact actor receipt. Never mint an independent publication UUID. If registry accepts and actual current state is still open, apply native admission/project and settle retained model; request next paired checkpoint only after releasing hold. Process authority was installed before registry onChange could expose open admission.

If installation/acceptance fails, the old actor lease is no longer valid. Retain fresh returned authority/counter in process state even if model refused installation. Mark needsFreshLease and complete only the matching registry attempt as failed if still active. On explicit retry, prepareClose using the retained fresh authority and highest-issued revision of its epoch (receipt.nextRevision-1 if never captured), with the same original logical registry ticket ID. No deletion in this re-lease step. Store new lease before another registry/native callback, then start a fresh registry attempt/capture and fresh publication. A failed re-lease retains current new authority and hold for retry; never retry the invalid old lease or “reset tombstone”. New capture's model authority may still be old if installation refused; during this owned re-lease repair path, process authority is authoritative for actor calls and capture is used only for text/state. This exception never upgrades an ordinary stale writer capture.

No automatic retry loop: each explicit Retry performs at most one re-lease and one fresh repair publication. Fresh registry acceptance after a newer actual model mutation still checks the latest attempt. If registry membership moved/disappeared outside the process owner, hold and report ownership violation rather than editing another document or synthesizing a replacement model. Actual app wiring must make this coordinator the sole live close/repair caller; registry.onChange subscribers may render or invoke this owner's admission-checked entry points, not secretly create unmanaged tickets.

### Completion, cancellation and quit

At batch end, project stable registry, release exact drained pause once, request one next paired checkpoint, and publish terminal result. If a batch is canceled between items, previous successes remain; release hold and request their post-close checkpoint. Later items remain untouched. Cancellation after a ticket exists cannot skip cleanup/repair; `cancelBeforeAdmission` refuses there with actionable instruction to finish recovery first.

`endpointDidClose` clears only source presentation reference. Transaction handle remains strongly owned. Native forced teardown cannot invoke legacy recovery deletion for managed IDs. Normal window close vetoes until its batch succeeds; a later empty endpoint teardown is explicit and performs no recovery cleanup.

`requireSettledForFinalCheckpoint` and `requireCaptureAdmission` are synchronous: any provisional, admitted, failed repair, pending retirement or undrained token refuses. Final checkpoint never awaits this owner's interactive repair. Independent application quit flag prevents close starting between legacy quit pause and final latch; scheduler acquire also refuses latched final. No hidden second writer or session save on error/status notification.

## Meaningful first test slice

Build a frozen Foundation package with actual ApplicationDocuments, RecoveryCoordinator, SessionCheckpointCoordinator and PadCore. Native adapter uses synthetic observable handles with exact generations; no AppKit claim. Confirmations are explicit test decisions; store faults perform actual private temp-file operations. Retain tests for:

1. Acquisition before callback: registry onChange reenters start/quit/capture, sees busy/paused and strong handle; no ticket if final/application quit already active. Unused token drains/releases after begin refusal.
2. Successful close uses real deletion, actor retirement, registry removal/history once, one explicit owner post-close checkpoint request (scheduler release may request another generation). Duplicate waiter/callback does not double-delete/release.
3. Real checked deletion failure retains model/assignment and pause; canceled waiter and simulated endpoint loss do not drop it. Retry exact Unicode/EOL/encoding/BOM snapshot succeeds with new authority installed before registry's open notification.
4. Actual preflight shortage before revocation leaves old authority writable, records unchanged, ticket retained safely then reopened, and token released. Batch first item fully settles before second preflight; no parallel snapshots/reservations.
5. Post-repair actor success followed by native refusal or direct synthetic state mutation: stale registry receipt refused; fresh returned authority retained, old lease not reused; second explicit retry obtains new lease and succeeds. Real actor's uncertainty-validation-by-B counterexample remains covered by actor tests independently.
6. Retirement/project failure retries only that phase, preserving completed disposition. No re-close or fresh UUID registration. Source loss during retirement does not leak hold.
7. Multi-item ordering with same group proves later requests captured freshly; new dirty state is not silently covered by old confirmation. Cancel before later admission preserves unprocessed IDs.
8. Original scheduler token tests remain unchanged; owner blocks capture/quit while unsettled without publisher↔close drain deadlock. Existing standalone legacy recovery harness remains unmanaged compatibility.

Actual native mutation gates, model adoption/authority installation, visible repair UI, real OS window closure/cancellation and post-checkpoint relaunch remain later acceptance. This design does not establish them and does not claim stronger pre-checkpoint crash behavior.

## Final review clarifications

Set noncancellable `admitting` before calling registry.beginClose. A nil stored ticket is not cancellation authority: the registry may already have installed its lease during synchronous onChange. Only confirming is explicitly cancellable; all other active stages reject cancel/retry. Begin failure still owns drain/release. Tests exercise cancellation during that exact callback.

After accepted registry repair, store settlement before projection. A subsequent render/project failure retries projection only and never reuses the old actor lease. Atomic all-managed activation and one paused publisher are prerequisites: draining only this handle's standalone writes does not freeze other standalone writers. Lightweight native readState is explicit so post-await checks need not recapture large text.

## Current evidence boundary

`scripts/test-application-document-closing.sh` passes 19 tests using actual actor, registry and scheduler with synthetic Foundation-native adapters. The initial compiled seam failed9 workflows; a separate confirming-cancellation assertion failed before its fix. Scoped formatting/shell checks pass. No existing controller/AppDelegate behavior changed, no GUI ran, and real native mutation enforcement remains a separate acceptance gate.

The running scheduler integration holds preparation, closes one of two documents, obtains an actual authorized paired receipt, and reloads exact remaining recovery/session data through fresh reader objects in the same process. It does not hold a filesystem commit or simulate process termination. Independent review passed; root rerun passed 19 tests. See [verification](../../verification/application-document-closing.md).
