# Document transfer and independent pane tab groups — F-02 design

Status: reviewed architecture; only the initial view-free registry ownership slice is entering implementation. Native integration, close leases, movement, independent groups and streaming transfer remain planned and unverified. The user has committed to moving documents between panes/windows; this is not optional future scope. Delivery is staged, but the architecture must support the full requirement. Existing pane-persistence work remains uncommitted with an intermittent failure under investigation; its acceptance is a separate prerequisite, not presumed here. Routine design approval ceremony is waived by BUILD_PROMPT. Root and independent review resolved close fencing, callback admission, pin authority, pure receipts, staged-window handoff and stable admission notification requirements before the initial ownership slice.

## Alternatives for the known full scope

1. **Chosen: application-owned document registry with exclusive group assignment.** The registry owns each document handle once for its lifetime; an editable handle retains its EditorDocument and a streaming handle retains its bounded read-only owner. Every document has exactly one assignment `(windowID, groupID)`; groups contain ordered document IDs and a selected ID. Windows render groups and borrow models from the registry. Initial windows have one group; the next stage adds two independent pane tab groups. Moving a document changes its assignment/order, never its storage/history/file authority. This does not enable concurrent multiwindow views of the same document. Registry ownership stays unchanged through every delivery stage.
2. **Window-owned model plus coordinator escrow.** This makes initial whole-window transfer smaller, but full independent groups require inventing group ownership, replacing window arrays, and revisiting close/recovery/callback authority a second time. A generic owner-slot abstraction could reduce that rewrite, but then it is already a registry-like layer without a clear lifetime owner. Rejected for the committed full scope, not merely deferred because a small first release is easier.

Stage A introduces the registry and exclusive single-group assignments while preserving current UI. Stage B exposes Move Document to Window with existing/new window destinations. Stage C introduces independent pane tab groups and Move Document to Other Pane/New Pane using the **same registry assignment transaction**. Stage D adds accessible drag/drop as another frontend to the same command if required by the reviewed UX; menu/keyboard actions remain available. F-02 is not reported complete at Stage B.

## Presentation model: groups versus views

A workspace group is an independent tab group with its own selected document. A document's existing one/two shared views are document presentation, not separate owners. Add a window group host with either one group or two groups laid out side-by-side/stacked. Each group has its own tab strip and a document pane host. Both groups may show different documents; each document's existing shared-view split is retained within its group. This bounded nesting avoids silently destroying an already-split document on transfer. Maximum two groups per window and two views per displayed document: at most four visible editor views, with existing additional-view admission limits retained. Resource/geometry acceptance for four views is mandatory before Stage C UI is enabled; no claim that existing two-view measurements prove it.

Move means the entire logical document and its ordered tab entry move to the destination group. It is not copying an individual view while leaving another view owning the same document elsewhere. Existing same-document split state, preferred view, both selections/origins, dormant deferred split metadata and detached undo-target pool travel with the model. Pane UI must distinguish “Split View of This Document” from “New Document Pane” in user-facing terms. Group orientation and document-view orientation are separate typed values; never infer group assignment from layout-manager attachment.

## Registry and exact internal contract

New `ApplicationDocuments` is MainActor, application-lifetime, and the sole authority for live handle identity, group membership, ordering and selected IDs. It is injected, not a process-global singleton. Root integrates all new/open/recovery/reopen/copy/backup paths into registerDocument before replacing native window arrays with projections. No path may silently construct an unregistered live model. Window controllers do not create another save/recovery owner.

```swift
struct DocumentAssignment: Equatable {
  let windowID: UUID
  let groupID: UUID
}
struct DocumentGroupSnapshot: Equatable {
  let id: UUID
  let documentIDs: [UUID]
  let selectedDocumentID: UUID?
}
struct DocumentWindowSnapshot: Equatable {
  let id: UUID
  let groups: [DocumentGroupSnapshot]
  let focusedGroupID: UUID?
  let axis: SessionPaneAxis
}
enum DocumentMoveError: Error {
  case workspaceBusy, staleRequest, operationActive, compositionActive
  case invalidDestination, duplicateDocument, capacityExceeded, sessionUnavailable
  case projectionFailed, workspaceRecoveryRequired
}
struct DocumentMoveRequest {
  let id: UUID
  let documentID: UUID
  let source: DocumentAssignment
  let ownershipGeneration: UUID
  let workspaceRevision: UUID
}
enum DocumentMoveDestination {
  case group(windowID: UUID, groupID: UUID, insertionIndex: Int)
  case newWindow
  case newGroup(windowID: UUID, axis: SessionPaneAxis)
}
@MainActor final class ApplicationDocuments {
  var workspaceRevision: UUID { get }
  var isMoving: Bool { get }
  func handle(id: UUID) -> (any WorkspaceDocumentHandle)?
  func editableModel(id: UUID) -> EditorDocument?
  func assignment(of documentID: UUID) -> DocumentAssignment?
  func window(id: UUID) -> DocumentWindowSnapshot?
  func registerWindow(id: UUID, initialGroupID: UUID) throws
  init(services: DocumentRegistryServices)
  func metadata(id: UUID) -> WorkspaceDocumentMetadata?
  func allows(_ action: DocumentAdmission, documentID: UUID) -> Bool
  func registerDocument(_ handle: any WorkspaceDocumentHandle, metadata: WorkspaceDocumentMetadata,
                        in assignment: DocumentAssignment, at index: Int, select: Bool) throws
  func selectDocument(_ documentID: UUID?, in assignment: DocumentAssignment,
                      expectedRevision: UUID) throws
  func focusGroup(_ groupID: UUID, in windowID: UUID, expectedRevision: UUID) throws
  func reorderDocument(_ documentID: UUID, to index: Int, expectedRevision: UUID) throws
  func setPinned(_ pinned: Bool, documentID: UUID, expectedRevision: UUID) throws
  func createGroup(in windowID: UUID, id: UUID, axis: SessionPaneAxis,
                   expectedRevision: UUID) throws
  func setGroupAxis(_ axis: SessionPaneAxis, windowID: UUID, expectedRevision: UUID) throws
  func closeEmptyGroup(_ groupID: UUID, in windowID: UUID, expectedRevision: UUID) throws
  func unregisterEmptyWindow(_ windowID: UUID, expectedRevision: UUID) throws
  func requestClose(documentID: UUID) throws -> DocumentCloseRequest
  func beginClose(_ request: DocumentCloseRequest,
                  disposition: DocumentCloseDisposition) throws -> DocumentCloseTicket
  func completeClose(_ ticket: DocumentCloseTicket, result: Result<Void, Error>) throws
  func reopenLastClosed(in assignment: DocumentAssignment, at index: Int,
                        expectedRevision: UUID) throws -> UUID
  func requestMove(documentID: UUID) throws -> DocumentMoveRequest
  func move(_ request: DocumentMoveRequest, to destination: DocumentMoveDestination) throws
  func captureWindows() throws -> [DocumentWindowSnapshot]
}
```

These interfaces are a design, not existing callable APIs. Model IDs remain document/recovery IDs. Groups get separate fresh UUIDs with validated uniqueness. Global registry removal occurs only after explicit logical-document close and authorized recovery cleanup; transferring or closing an empty group/window never removes the model or recovery snapshot. Runtime group/window projections may temporarily hold strong model references during a call, but neither has independent close authority.

### Metadata, dependencies and native adapters

Pin is solely registry metadata, including initial import, history/reopen and streaming handles. Add `WorkspaceDocumentMetadata(pinned: Bool)` as required registration input and expose `metadata(id:)`; group/window rendering and session capture read this value. Remove the independently writable EditorDocument.pinned field during native migration, replacing legacy reads with the registry projection. Rollback receipts retain affected metadata values; restoring assignments cannot silently change pin. Imported pin and failed move/reopen must be tested before setPinned is ever called.

```swift
struct WorkspaceDocumentMetadata: Equatable { let pinned: Bool }
enum DocumentAdmission { case edit, select, undoRedo, fileOperation, baselineAdoption, transfer, close, paneInstall }
struct DocumentHandleState: Equatable {
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
struct ReopenedDocument {
  let handle: any WorkspaceDocumentHandle
  let metadata: WorkspaceDocumentMetadata
}
@MainActor struct PreparedDocumentWindow {
  let windowID: UUID
  let groupID: UUID
  let endpoint: any DocumentMoveEndpoint
  let adopt: () throws -> Void
  let dispose: () -> Void
  let show: () -> Void
}
@MainActor struct DocumentRegistryServices {
  let endpoint: (UUID) -> (any DocumentMoveEndpoint)?
  let prepareWindow: (UUID, UUID) throws -> PreparedDocumentWindow
  let capacity: ([DocumentWindowSnapshot]) throws -> WorkspaceCapacitySnapshot
  let capacityRevision: () -> UUID
  let readState: (any WorkspaceDocumentHandle) -> DocumentHandleState
  let admissionChanged: (UUID) -> Void
  let cloneClosed: (any WorkspaceDocumentHandle, WorkspaceDocumentMetadata) throws -> ReopenedDocument
  let changed: () -> Void
}
```

Services are MainActor synchronous collaborators; no callback may secretly await/run a modal. Endpoint lookup returns the currently app-owned endpoint, held strongly only for transaction duration. Root owns endpoint registration/removal alongside registerWindow/unregisterEmptyWindow; registry must reject a registered window lacking its endpoint when a move needs it. PreparedDocumentWindow owns its provisional endpoint until committed or disposed exactly once. Its explicit adopt callback transfers a strong reference into AppDelegate endpoint/window ownership and registers lookup before the local wrapper is released; this happens under the active transaction before success publication, not in show. adopt failure triggers rollback/dispose; dispose must also unregister a partially adopted provisional endpoint idempotently. After successful adoption, app owns the endpoint until unregisterEmptyWindow and actual close. show is only a final presentation effect. Services capture app/endpoint owners weakly to avoid cycles; registry owns live/history handles strongly. readState is implemented by real kind-specific adapters, not dummy replacement EditorDocument classes. cloneClosed creates a fresh native model and metadata under the gate, registers it before popping history, and leaves history untouched on throw/duplicate-ID/capacity refusal. The core-only test package uses protocol fake handles and injected closures; native convenience `editableModel` downcasting and native receipt conversion live in separate adapter extensions, not fake native classes.

Native audit clarification: existing reopenClosed creates a fresh UUID/model and does not copy pin or pane presentation. Preserving registry-owned pin on reopen is a deliberate behavior change requiring native adapter tests; do not describe it as already implemented parity. Registration must also distinguish an explicitly resolved session import from a new handle whose UUID collides with an unresolved reserved record. Union counts alone do not detect that collision.

The registry's close lease and global transaction token are authoritative for allows(). readState callbacks can reenter, so they execute while the short/global token is held and state is rechecked after returning. admissionChanged and changed are stable-state notifications: settle persistent close/admission state and release the short/global token first, then invoke them so allows() reports the committed state. No registry mutation or stale-result return construction follows notification; construct immutable receipt/result beforehand. Reentry may start a later valid operation, and earlier notification cleanup must not clear it. If notifications require multiple recipients, pass immutable revision-tagged snapshots and never assume later recipients see the same live revision. Close cleanup starts only after stable admission publication; a reentrant handler cannot release another ticket. Native adapter tests are mandatory before claiming model editing/close safety even if fake-handle registry tests pass.

### Total mutation surface and test injection

All mutators above reject the active-transfer/recovery-required gate and stale expectedRevision before mutation, then publish one fresh workspaceRevision after success. selectDocument accepts nil only for an empty group, otherwise requires membership. focusGroup requires registered group in that window. reorderDocument delegates current TabOrder validation then stable-partitions pinned/unpinned as the existing controller does. setPinned performs that same stable partition atomically and preserves selectedID. Register/move insertions respect the pinned prefix; returned snapshots expose the final partitioned position, so a requested unpinned index inside the pinned prefix cannot silently unpin the document. Group creation enforces2groups/window; closeEmptyGroup only accepts an empty nonfinal group (the final empty group is removed with unregisterEmptyWindow). Neither closes a document. setGroupAxis changes group geometry only, not document-view axis.

AppDelegate constructs exactly one ApplicationDocuments and injects it into every normal/recovery/new/staged editor window and streaming viewer adapter. Standalone controller harnesses construct their own registry instance plus initial window/group registration through a convenience factory. No controller silently falls back to a different singleton when an injected registry is present. Two-controller transfer tests explicitly share one registry. Root removes independent mutable `documents`, `selectedID` and `closedDocuments` authority; transitional computed accessors may project registered IDs but have no setter. Presentation callbacks request select/focus mutations; they cannot assign private arrays directly.

Concrete current-path map (line numbers move; method names are the contract):

| Current operation | Registry mutation |
|---|---|
| newDocument, file.duplicate, restoreBackup, openCheckedDiskCopy | Construct intended fresh editable handle, then registerDocument once; select via registry. |
| successful open async new buffer | Register after existing read/operation guards, before monitor adoption/presentation; failure leaves no registration. Existing-buffer selection uses selectDocument, not re-register. |
| restoreSessionTab and legacy restoreRecovery loop | Register the supplied recovery/session UUID once after validation; inactive imports use select:false. Selected session tab uses selectDocument. |
| display, tabBar.onSelect, tabs popup, switchTab, async source activation | selectDocument/focusGroup only after original context guards. Rendering an already-selected projection never mutates registry recursively. |
| tabBar.onPin / tabBar.onMove | setPinned / reorderDocument, preserving current stable pinned prefix semantics. |
| closeDocument, closeOthers, close-all, window close | Explicit confirmation followed by per-document beginClose/completeClose; window unregister only after no assignments/pending-close tickets remain. |
| reopenClosed | Registry-owned history path below; no controller array append. |
| source/target transfer | move only; no logical close or registration duplication. |
| startup newWindow, New Window menu, final NSWindow close | registerWindow / unregisterEmptyWindow; staged transfer endpoint stays provisional until commit. |
| large-file viewer opening/closing | Streaming handle stage below; interim adapter explicitly tracked as not transferable until integrated. |

Before StageA integration, a source audit must show every current `documents.append/insert/remove`, whole-array assignment, selectedID assignment and pin mutation mapped. Future direct model pin setters become registry-internal or validated read-only projections. App factory and standalone tests must exercise the same mutation implementation; only services/window presentation are injected.

### Close cleanup and closed-history ownership

```swift
enum DocumentCloseDisposition { case retainCleanHistory, discardWithoutHistory }
struct DocumentCloseTicket {
  let id: UUID
  let documentID: UUID
  let ownershipGeneration: UUID
  let assignment: DocumentAssignment
  let frozenState: DocumentHandleState
}
struct DocumentCloseRequest {
  let documentID: UUID
  let assignment: DocumentAssignment
  let state: DocumentHandleState
}
```

requestClose captures authoritative handle state before the caller's explicit confirmation. beginClose establishes an exact short admission token **before reading injected handle state or invoking any callback**, compares the captured request to current assignment/ownership/kind/mutation state, and installs a persistent per-handle closing lease before releasing the short token. `.retainCleanHistory` requires editable kind, currently clean, no pending publication/text processing and history-capable native adapter; it is not a caller assertion. `.discardWithoutHistory` requires the request bound to the state the user approved. No new file operation or already-running mutating callback may remain at admission. Selection/visibility may remain readable; editing, undo/redo, selection changes that participate in restoration, save/rebind/baseline adoption, transfer, another close, pane installation and late command completion all refuse while closing.

The native adapter wires `registry.allows(action,documentID:)` into actual canMutate/canFocus, operation begin/adoption and asynchronous completion entry guards; editable/selectable state and menu undo validation reflect it. Disabling NSTextView alone is insufficient because programmatic undo/storage callbacks bypass that property. A document `mutationGeneration` rotates on every content, encoding/BOM, baseline, pending-publication or presentation change relevant to a close; pending NSTextStorage character edits are also checked before processing notifications, so an open editing batch cannot conceal a new mutation. Native tests must prove these guards with real editor/operation entry points.

Close cleanup runs asynchronously only after the lease exists. Registry/group membership and strong model ownership remain. completeClose verifies exact ticket ID, assignment, ownership generation, kind and frozen mutation state before disposal. Repeated/stale completion is refused and cannot release a newer closing lease. Cleanup failure releases **only that lease**, restores native admission and retains the live model/assignment/content unchanged; it never deletes a new edit under the old disposition. Cleanup success permits removal/history only if the frozen state still matches. If an invariant violation/direct mutation changed state despite the lease, retain the model/assignment, mark `recoveryRequired`, veto quit and refuse destructive disposal until a fresh confirmed recovery checkpoint restores protection; the old cleanup may already have deleted the prior snapshot. Do not drop data or claim rollback recreated deleted recovery. This defensive path is tested through real NSTextStorage mutation and an unprocessed editing batch, not treated as a supported editing route.

Batch close uses independently completed tickets: successful items close once; failed items remain open. Quit final persistence is separate and does not create close-history entries. A handle stays frozen through its completion decision; callback notification occurs only after stable live/closed/recovery-required state.

Native OS close is a two-step delegate flow. The first windowShouldClose with assigned documents returns false, captures confirmation-bound requests and starts tickets while the window remains alive. Duplicate OS close attempts reuse/refuse the same active attempt, never start another cleanup. After every document succeeds and no closing lease/assignment remains, issue a window-close permit bound to window ID and current workspaceRevision; performClose then accepts only that permit. Any failure leaves remaining tabs/window visible and editable after lease release; successful siblings may already have closed. `windowWillClose` is final teardown only, never the first place asynchronous cleanup starts. Empty moved-from windows close without cleanup. Unexpected forced teardown without a valid permit retains registered handles in recovery-required state and surfaces another host/retry route; it must not erase live ownership. Actual application termination follows the distinct existing global recovery/session path, not this close-history flow.

Registry owns `closedHistoryByWindowID`, capacity10 clean editable models per window, preserving the current window-scoped LIFO eviction behavior. It retains the original closed model/pane pool/native undo targets until eviction/reopen/window-unregister, while that object is not a live assigned document and is excluded from recovery/session counts. Current production reopenClosed intentionally creates a fresh UUID/model from retained metadata/text and does **not** restore the old undo stack; preserve that behavior explicitly, rather than claiming undo resurrection. Clone all fields the current reopen path copies, register fresh model at requested group, and pop history only after registration succeeds. Failed capacity/open/registration retains the history item. Dirty discard never enters history. Closing/unregistering the original window releases its history as current controller lifetime does. Moving never appends/pops history. New enhanced closed-tab undo restoration would be a separate behavior change, not smuggled into F-02.

EditorDocument gains fresh `ownershipGeneration: UUID`, rotated on every assignment change and rollback; it is separate from editRevision/baselineRevision/recoveryRevision/pending-publication identity. PaneCommandContext and other owner-sensitive native action captures include this generation. Old source membership checks alone are insufficient after move-away-and-back. Root coordinates an exhaustive async mutation audit: save/reload/open callbacks, external-file actions, encoding, text transforms/bookmarks, search replace/navigation, utility/panel callbacks, macros, delayed presentation and success handlers. Each must be either blocked by preflight active-operation accounting or check captured ownership generation plus its original guards.

A document-owned weak `DocumentWindowBinding` points to the current rendering endpoint/group. Existing DocumentFileStateController liveContext/onChange closures use this relay rather than capturing a permanent source window. The bridge/registration, baseline bytes, bound target identity, observed facets, dismissal/manual/error state and monitor documentID are retained; transfer is not adoptBaseline or invalidateFileState. Old-window action contexts are canceled/fenced without discarding observation state. Relay resolves no rendering endpoint while the workspace transaction is active, and reconciles in the target only after commit.

## Transferable streaming handles — explicit required stage

Current LargeFileWindowController privately owns its LargeFileReader, bounded65536-byte page, byte offset, page/search request UUIDs and tasks; AppDelegate owns it in a separate largeViewers array. It is not an EditorDocument, has no editable whole-file storage/undo/recovery and cannot currently be transferred. F-02 cannot be declared complete while this remains an unmapped exception.

Freeze registry identity independent of model kind now:

```swift
enum WorkspaceDocumentKind: Equatable { case editable, streaming }
@MainActor protocol WorkspaceDocumentHandle: AnyObject {
  var id: UUID { get }
  var ownershipGeneration: UUID { get }
  var workspaceKind: WorkspaceDocumentKind { get }
  func advanceOwnershipGeneration()
}
```

`StreamingDocument` is a new app-layer owner extracted from LargeFileWindowController in Stage C2: fresh stable document ID/ownership UUID, existing reader handle, page bytes/offset/query/result state, existing bounded tasks/request IDs and read-only capability. It stores no100MB+ text snapshot. Choose the protocol representation now: EditorDocument and StreamingDocument conform; registry holds `any WorkspaceDocumentHandle`. Registry tests use fake handles of both kinds from StageA in a MainActor test package without constructing native views. Native editableModel is a convenience downcast for editor-only commands, never the generic move path. Until real extraction passes, production streaming admission/transfer is unavailable with explicit outstanding status, not a fabricated editor adapter. Pin/order/assignment are registry metadata independent of kind; editable capture reads the registry pin through a coordinated adapter rather than maintaining a second independently mutable pin field.

Endpoints render handle-specific views; DocumentMoveViewState becomes a tagged value, editable presentation/pane IDs versus streaming byteOffset/current-page selection. The exact byte-offset subtype is frozen in StageC2 without changing assignment or transaction signatures (use a `WorkspaceViewState` enum in endpoint arrays from StageA). No UTF16 whole-document validation is applied to byte offsets. Streaming transfer reuses the existing reader, does not reopen or rematerialize the file, and refuses while page/search work is active until safely drained; late completion requires ownership/request identity. Closing releases reader/tasks exactly once, invokes no editable recovery delete, and does not enter editable closed history unless a separately reviewed read-only reopen receipt is implemented.

StageC2 migrates AppDelegate largeViewers into the same registry/endpoints, removing independent ownership. It requires explicit session metadata kind plus bounded byte offset/current source identity/reopen error handling in the same reviewed group-schema migration, preserving old editor schemas and unsupported versions. Reopening a streaming file after process restart necessarily reopens its path and revalidates identity; changed/missing bytes cannot be treated as the prior file. Until that stage passes, report streaming transfer/session persistence as outstanding rather than claiming all F-02 covers EditorDocument only.

## Capacity preflight: no staging to discover limits

The persistence limit is **128 total live plus unresolved documents application-wide**, not128 per destination. A move adds zero document IDs. A new window adds one window; a new group adds zero windows/documents. Existing32-window limit includes windows containing only unresolved records. If current restored state already exceeds persistence capacity, the bounded initial move operation refuses with an explicit resolve-capacity message; it does not worsen or truncate that state.

SessionCoordinator supplies a pure MainActor snapshot before transaction:

```swift
struct WorkspaceCapacitySnapshot {
  let sessionRevision: UUID
  let windowIDs: Set<UUID>
  let documentIDs: Set<UUID> // union of live registry IDs and preserved unresolved IDs
  let cleanupPending: Bool
}
func transferCapacity(liveWindows: [DocumentWindowSnapshot]) throws -> WorkspaceCapacitySnapshot
```

The method does no I/O, creates no state/window, and refuses pending removals, startup-incomplete or preserved corrupt/future session errors. Recheck its revision at final admission. Proposed newWindow/newGroup destinations are pure values: compute post-move window/group sets and counts before any NSWindow or group allocation. Only after capacity succeeds prepare a hidden endpoint. This covers32 existing windows with unresolved-only entries and128 documents at capacity: moving to an existing window remains zero growth; a33rd window is rejected without creating one. A staged hidden window is not registered as a lasting app/session window until commit.

## Transaction, reentry and rollback

The same synchronous transaction serves windows now and groups later. No await, modal UI, source file I/O or recovery cleanup occurs between final admission and commit/rollback. `DocumentMoveRequest` captures the exact workspaceRevision; any workspace mutation while the chooser is open conservatively invalidates it.

Native endpoints expose an exact preparation/rollback protocol:

```swift
@MainActor protocol DocumentMoveEndpoint: AnyObject {
  var windowID: UUID { get }
  func preflightMove(documentID: UUID, groupID: UUID, receiving: Bool) throws
  func captureMoveViewState(documentID: UUID) throws -> WorkspaceViewState
  func applyWorkspaceProjection(_ snapshot: DocumentWindowSnapshot,
                                movedDocumentID: UUID,
                                viewStates: [WorkspaceViewState]) throws
  func restoreWorkspaceProjection(_ snapshot: DocumentWindowSnapshot,
                                  viewStates: [WorkspaceViewState]) throws
  func focusMovedDocument(_ documentID: UUID, groupID: UUID) -> Bool
}
enum WorkspaceViewState {
  case editable(DocumentMoveViewState)
  case streaming(StreamingMoveViewState)
}
struct StreamingMoveViewState {
  let documentID: UUID
  let byteOffset: Int64
  let pageSelection: NSRange
}
struct DeferredPresentationReceipt {
  let presentation: SessionPresentation
  let livePaneID: UUID
  let liveSlot: Int
  let resolvedAtRevision: UInt64
  let presented: Bool
}
struct DocumentMoveViewState {
  let documentID: UUID
  let presentation: SessionPresentation
  let attachedPaneIDs: [UUID]
  let preferredPaneID: UUID?
  let deferredPresentation: DeferredPresentationReceipt?
  let presentationWarning: String?
}
struct DocumentMoveRollback {
  let requestID: UUID
  let documentID: UUID
  let sourceAssignment: DocumentAssignment
  let sourceWindow: DocumentWindowSnapshot
  let targetWindow: DocumentWindowSnapshot?
  let sourceViewState: WorkspaceViewState
  let targetSelectedViewState: WorkspaceViewState?
}
```

`ApplicationDocuments` retains models even if native projection fails. The rollback receipt contains registry snapshots and view metadata only, no source text copies. Target's previously selected view state must also be captured before its host is replaced; target may be empty, hence optional. Source receipt includes exact tab order/selection and registry-owned pin metadata, document pane identity/state, and a value copy of pending deferred state (liveSlot/livePaneID/presented/revision) plus warning. Rollback restores that metadata as well as live view origins, without resurrecting a canceled task. A missing target snapshot identifies newly prepared window/group rollback.

1. After only non-callback inspection of the registry's own active-token field, allocate an exact transaction UUID and set `isMoving=true` **before any endpoint lookup, capacity provider, handle-state getter, factory, preflight or view-capture callback**. Then validate the captured workspace/ownership/close states and take rollback snapshots. After each callback recheck the same transaction UUID, exact workspace revision, source/target membership, ownership generations and absence of closing leases; changes refuse the request before further effects. Capacity revision is checked again after endpoint preflight/factory preparation. A refusing preflight clears only its own gate, publishes no revision or notification, and disposes any provisional target. Reentrant move/register/close/capture/quit commands return typed `.workspaceBusy`; read-only model lookup may return existing model but cannot grant mutation authority. `captureWindows` refuses during transfer. Focus/editor callbacks use the same registry gate in canMutate/canFocus and must not commit tab-selection/session changes while moving.
2. Break typing coalescing without adding undo actions. Close source document-specific transient panels and fence their captured authority. Rotate ownership/presentation interaction generations. Relay temporarily has no active owner. Do not cancel away a still-running resolver and pretend its memory slot drained; preflight requires it already idle.
3. Prepare post-move immutable source/target snapshots locally. Registry changes from old assignment to new assignment in **one non-callback internal assignment**; there is no period where both group arrays are authoritative owners. Registry model dictionary never removes the document. Apply source and target native projections with the full new snapshot under the busy gate, reinstalling delegates/callbacks for every pooled pane and source/target selected-document observer.
4. After each endpoint call, assert the same transaction UUID and busy state; endpoint calls cannot mutate registry through its guarded APIs. If any preparation/projection throws, restore old registry snapshots/assignment, rotate ownership generation again, restore both endpoints from the receipt, retire the staged target. Restoration is attempted for both even if the first throws. No user notification/modal until stable restoration or explicit failure state.
5. If rollback projection fails, retain the document in the registry under its restored source assignment and retain the rollback receipt; expose a `workspaceRecoveryRequired` state, disable affected editing/transfer and veto quit until explicit Retry Layout succeeds. Do not report a completed move, discard recovery or drop the model. Retry only rebuilds projections from already-owned models; no source reads or .string copies. An app-lifetime strong registry avoids escrow-loss even when both NSWindows fail.
6. On success switch relay owner to target, clear active transaction, publish one workspace revision/metadata notification, then reconcile monitor rendering. Focus/order the destination as the final user effect. Failure to become key/focused is a visible focus warning, not rollback of already committed ownership. MRU unchanged; no file was opened.

The transaction token remains live throughout rollback; nested command attempts during rollback are also rejected. Finish clears only the exact token; callback reentry cannot clear a newer transfer. Tests inject endpoint callbacks attempting move/close/checkpoint/quit at each phase. Endpoint code must never call arbitrary completion closures in the middle of unguarded mutation.

## Guards and window behavior

Require the requested document is still selected in its source group. Reject source/target closing/preparing quit, app startup restoration or preserved session failure, loading, pending recovery close, any active file operation/saving, unresolved publication uncertainty, macro recording/replay/unsaved-recording save, marked text/composition in moved or target-selected document, pane resolution worker not drained, stale ownership/workspace revision, malformed index, unknown/duplicate group/document ID. Same-group moves are a separately validated reorder operation; initial cross-window UI does not disguise them as transfer. Refuse target group containing another model with identical standardized URL, leaving both buffers untouched; filesystem alias detection remains the existing save/open policy, not a new filesystem scan.

Empty source window stays open with zero documents and a New/Open empty state. Empty source group in Stage C remains a valid focusable empty group until explicit Close Pane; closing it does not close another group's document. Closing the final empty group/window affects workspace only. Do not fabricate a scratch tab or invoke closeDocuments/windowWillClose while the moved document is still enumerated there. The registry determines logical-document close exactly once.

Stage B preserves pin flag and places the document at the explicitly chosen/validated target index; source selects nearest surviving neighbor, target selects moved document. Stage C applies the identical rule to group order and focusedGroupID. New destination creation is prepared hidden after pure admission and registered only on commit, then shown as the final user action.

## Pane geometry/settings and persistence

Move the existing complete pane pool; no new storage, layout manager or UndoManager. Do not use EditorPane.detach to remove a scrollview from its host: that would detach its layout manager. Reparent host views only, preserving attached/detached state and deferred split mapping.

Capture live per-pane ranges/origins and deferred presentation before host changes. Retain current document font/wrap settings on both panes rather than silently applying different destination defaults. Reapply exact scalar-safe selections after reparenting without text mutation; make one ordinary bounded layout/origin application using native constrainBoundsRect. Persist actual constrained geometry afterward and preserve dormant deferred slots unchanged. If geometry is unavailable, retain the authoritative pre-move presentation as deferred view state with an explicit warning until one normal presentation attempt; no polling/full glyph layout/late replay after user interaction. New interaction must merge live pane state rather than overwrite it with the captured origin. Use the pane persistence request/generation rules for any asynchronous revalidation, not another restoration mechanism. Actual smaller/larger target-window fixtures must prove both panes' selections and resulting scroll metadata; no silent loss or claims of identical top line under changed geometry.

Stage B can encode registry's single group per window to existing SessionWindow.tabs/selectedTabID without a schema change. Stage C extends window metadata with ordered1...2 groups, each ordered document IDs and selection, plus focusedGroupID/group axis; document records/presentation remain exactly once per window or in a separate top-level keyed table within the same session envelope. Choose the concrete wire in Stage C review; it must migrate actual v1/v2 canonical schemas in memory, preserve unsupported data and retain unresolved records with their group assignment. This is a bounded persistence extension, **not another document-ownership rewrite**. Recovery remains one record per document UUID.

Transfer creates no immediate durable disk write. Existing ordered checkpoint follows stable workspace notification; crash before confirmed checkpoint may reopen previous placement, while same document recovery remains. Quit uses global registry snapshot once, writes recovery then session through existing coordinator and vetoes on failure. Full F-02 acceptance includes independent group transfer and restart; Stage B alone is partial.
