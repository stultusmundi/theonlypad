# Complete native close state and repair installation

Model generation, close-state/capture adapter and atomic installer are implemented and independently tested; process/native integration and full pane-event admission remain deferred. The audit below distinguishes intended later wiring from this bounded model slice. Factory, shared-model ownership, exact dirty comparison and current controller routes remain unchanged. This prerequisite does not activate managed close. Root owns process/native boundary integration; actor owner retains its independent lease/publication protocol.

## Smallest practical implementation

Add one model-owned `closeMutationGeneration: UUID` and one private `noteCloseMutation()` that only replaces that UUID. No notifications, I/O, text copies, hashing or registry calls inside it. Add property observers to existing stored semantic fields and calls inside existing model transaction methods; reuse existing text observer. Put native close-state capture/repair context types in a separate adapter so base EditorDocument does not gain WorkspaceDocumentRegistryTypes dependencies. Do not rewrite every controller command into a new model architecture.

A generation is an invalidation fence, not an equality digest, save acknowledgment or recovery revision. Conservative extra invalidations are acceptable for actual semantic assignments. Do not change `editRevision`, `recoveryRevision`, managed highestIssued/next, fileBindingID/baselineRevision or panePresentation.interaction semantics. Each has a different owner/use. Equal-value saved-state adoption still rotates the close generation because it is a new authority event.

## Audited mutation map

Current EditorDocument stored values and controller entry families:

| Source | Minimal generation hook and rationale |
|---|---|
| Characters through typing, shared undo/redo, native transforms, format, reload, factory direct storage edits | Existing storage didProcessEditing observer rotates close generation when editedCharacters, alongside existing editRevision/dirty proof invalidation. No second full-text observer/scan. Current unfinished editedMask also blocks readState even before notification. |
| encoding / hasBOM | didSet when scalar changed. Covers convertEncoding/setEncoding undo, reload/disk reload, open/factory and recovery. Net change back still rotates twice, so held close cannot accept an intervening conversion. |
| url | didSet unconditionally. Avoid URL equality canonicalization hiding a path authority assignment. Covers Save As, Locate and reopen. No filesystem resolution. |
| originalBytes | didSet unconditionally, no Data comparison. Covers saved-byte replacement including identical byte adoption and nil transitions. |
| savedText | Extend existing didSet with noteCloseMutation; preserve all exact dirty proof invalidation. Never compare or reencode the whole baseline here. |
| savedEncoding / savedHasBOM | scalar didSet; normal successful save also rotates through savedText/bytes and acknowledgeFileBaseline. |
| acknowledgeFileBaseline | rotate even if text/bytes equal; current overflow rebinding remains untouched. |
| pendingPublication | didSet comparing only optional immutable id, or unconditional assignment; never inspect opaque inode evidence/Data. Fresh same-byte uncertain publication is a new close context. |
| beginFileOperation / finishFileOperation | rotate on every begin and successful matching finish; stale finish does not rotate/clear another operation. A complete save during an await cannot return to operation nil with old generation. |
| saving compatibility flag | scalar didSet; actual close state treats saving true OR operationID nonnil as busy. Flag-only legacy work must not slip through pending adoption integration. |
| ownershipGeneration | Keep separate exact ownership fence; advanceOwnershipGeneration also rotates closeMutationGeneration to conservatively invalidate retained model contexts. |
| composingPaneID | scalar didSet on begin/end; actual native marked/composing states additionally checked across ALL pooled panes. Never trust only controller current pane. |
| pendingBookmarks / compositionBookmarks / compositionOriginalText / pendingBookmarksHaveUndo / compositionUndoRegistered | Assignment/scalar hooks on in-progress editing state; avoid comparing String/arrays. `readState.hasPendingTextEdits` must include pending remapping/active native input transaction until finalization. Storage notification alone may precede bookmark application. |
| bookmarks | didSet unconditionally, so in-place mutating value calls (`removeAll`, remap/setBookmarks) also invalidate without array scans. Covers bookmark undo and composition restoration. |
| manualLanguage / language | scalar didSet; automatic detection changing language is a real persisted semantic change only when manual override is persisted. Simpler safe first implementation marks all actual language changes, never syntax token updates. |
| pinned | scalar didSet while legacy controller owns it. After registry projection, only changed pin value rotates; repainting identical metadata must not loop. Registry close request already captures metadata separately. |
| recoveredName | assignment hook, since close confirmation/history identity is user-visible; no full string equality needed. |
| preferredPaneID / splitAxis | scalar didSet. Explicit focus and split/collapse/restore transitions invalidate. |
| pane pool attach/detach/reorder | explicit model helper hook on actual membership/order change (≤2). Existing methods plus EditorPane attach/detach should notify model once; no resetting undo managers or rebuilding views. |
| saved pending pane presentation / Use One / explicit Restore/collapse | lightweight semantic-change hook from DocumentPanePresentation when pending record or explicit layout choice changes. Internal suppression/installation token/warning/one-shot presentation bookkeeping are not recovery-content changes by themselves. Preserve existing pane transaction guards. |
| selection and scroll | See the bounded distinction below. Do not make an arbitrary geometry notification a content-mutation generation. |

Exclusions: dirty cache fields, temporary syntax attributes, settingsApplied, warning/status text, callback installation, font/layout cache, selectableBeforeQuit, legacy/managed revision issuance and recoveryAuthority assignments. Recovery receipt installation must NOT rotate mutation generation: registry still needs to accept the exact captured semantic state. Authority/fence equality is checked independently. Ownership identity advances remain explicit, never hidden inside repair.

`typingBookmarkNextLocation` and native undo grouping hints do not represent durable content alone; they should not create generations during harmless responder bookkeeping. A native input operation must still remain busy until the actual composition/bookmark pipeline settles.

## Presentation versus incidental layout

Current pane bounds observer reports all bounds changes, including TextKit reflow after shrink and scroller appearance. Earlier failures proved these can arrive after synchronous controller work and are not proof of a user edit. Do not reuse every `presentationInteraction`/bounds notification as closeMutationGeneration: that would reintroduce fragile geometry-driven cancellation into actor repair.

Explicit focus, selection/navigation commands, split/collapse/restore/discard and user scroll entry events can mark semantic view changes through existing controller/pane callbacks. Selection callbacks may be conservative even for programmatic selection; no text scan is required. For full current-state comparison, a native scalar context can carry at most two pane IDs/attachment flags/ranges/origins plus preferred ID/axis/pending-presentation identity. Read ranges/origins only; no ensureLayout, glyph enumeration, scroll restoration or NSString conversion. Return-time view differences never get overwritten by repair, whose only mutation is authority/counters. They may conservatively refuse a close/admission transaction where required, but are not grounds to rewrite/reset the user's view.

Practical split: the model mutation fence protects semantic document/recovery/close decisions and explicit view interactions; incidental layout geometry is preserved live and is not a historical text mutation. A user move away and back must be observed by semantic callbacks, rather than attempting to infer its history by comparing two equal rects. Do not add a second asynchronous view-restore worker. F02 grouping/projection remains separate.

Before implementation, settle which native read-state wrapper owns the bounded view descriptor. Prefer it in native close context rather than adding AppKit geometry to the view-free registry. The already-tested view-free request holds mutationGeneration; the process/native wrapper may retain an additive descriptor if close confirmation policy needs it. Repair installation must never replay captured view values.

## Cheap truthful close state

Proposed separate adapter:

```swift
@MainActor extension EditorDocument {
  func captureCloseState() throws -> DocumentCloseState
  func captureCloseRecovery() throws -> DocumentClosingCapture
}
```

captureCloseState reads identity/ownership/generation, actual operation busy state, pending publication identity, editedMask and at most two panes' native composing/input flags. `isDirty` must use the existing exact `document.dirty` implementation. Its ordinary cached/incremental path is cheap; an initial unknown proof may perform an exact full comparison. Therefore this API promises no NEW String snapshot/independent scan, not universal O(1) dirty equality. Never replace it with hash/undo-token identity or an unconditional dirty bit. Reading state must not load a file or call layout.

DocumentCloseState.operationID currently holds only operationID. If legacy saving true with no token is still possible, do not fabricate a UUID inside each getter: captureCloseState must throw/refuse via an additional adapter guard or use a stable explicit busy field added to the boundary. Recommended minimal first adapter is `throws`, refusing saving-without-operation before returning state. The existing DocumentCloseServices already accepts a throwing reader. `hasPendingTextEdits` combines editedCharacters and pending remapping/native operation state; empty beginEditing with no changes is not falsely described as edited content. Direct unsupported storage mutation later is still caught by mask/generation revalidation, not prevented by a fake depth guarantee.

Capture reads beforeState, then authority + highestIssued fence, then one full RecoverySnapshot (even a clean file, because rejected deletion may require repair), then afterState and requires exact equality plus same authority/fence. No revision issuance here: it is a preflight/repair snapshot, not an ordinary checkpoint item. MainActor operation has no suspension; callbacks triggered by existing model getters are still fenced. The process preflights resource limits and serializes close items before this copy. Ordinary publisher uses captureAuthorizedRecovery separately and skips issued revisions on failed capture rather than rewinding.

## Immutable repair context before await

Current process repair does `capture = native.capture(handle)` before `await recovery.restoreAfterClose`, then calls installRepair(handle,attempt,receipt). Extend that callback minimally:

```swift
struct NativeRepairInstallationContext {
  let state: DocumentCloseState
  let modelAuthority: RecoveryWriteAuthority
  let highestIssuedRevision: UInt64
}
// Process creates from capture.state/authority/highestIssuedRevision BEFORE await.
let installRepair: (any WorkspaceDocumentHandle, DocumentRecoveryAttempt,
                    RecoveryRepairReceipt, NativeRepairInstallationContext) throws -> Void
```

No text needs to be duplicated into this context. Process retains its existing capture/snapshot only for the necessary operation lifetime, and independently verifies exact actor lease, attempt, mutation, publication/new authority and configured coordinator ID.

Native adapter first requires exact registered same object/assignment/repair attempt and current complete close state equal attempt.state/context.state; no operation, pending remapping or composition may be active. It validates context authority/document/coordinator and current model authority/highest-issued fence. Do not reconstruct expected fields from the model after the await.

Model installer proposal:

```swift
func installRecoveryRepair(
  _ receipt: RecoveryRepairReceipt,
  expectedAuthority: RecoveryWriteAuthority,
  expectedHighestIssuedRevision: UInt64,
  expectedOwnershipGeneration: UUID,
  expectedMutationGeneration: UUID
) throws
```

Precheck all expected model fields, nonzero nextRevision, receipt.documentID, expected coordinator matching receipt authority and lease coordinator, receipt mutation generation. Process/adapter validates exact registry attempt and lease correlation; the model has no registry access. After every check, perform ONLY consecutive nonthrowing assignments to private recoveryAuthority, nextManagedRecoveryRevision and highestIssuedRecoveryRevision. These fields have no observer/callback. Do not write storage, encoding, baseline, dirty cache, pending publication, bookmarks, view state or ownershipGeneration. No API can observe an intermediate assignment on MainActor because no callback/await occurs. Refusal leaves every field unchanged.

Reject duplicate installation once current authority no longer equals captured expected authority; also require receipt's new authority differs from expected authority, so a malformed same-authority receipt cannot reset issuance. The process recognizes its own completed installation stage if retrying later registry projection, rather than calling the setter again. No mutation-generation bump from installing recovery authority; subsequent registry completeRecoveryRepair must still see the original semantic state.

Important lagged-model case: model A0 can remain after actor publishes A1 but native install refuses. Process then prepares a fresh lease under retained A1 and receives A2. The valid native expectation is still captured model A0, NOT receipt.lease.authority A1. Check independent immutable model context and independent actor receipt chain; never equate them. If the first install succeeded but registry acceptance failed, the next context instead captures model A1. Both cases must pass controlled real-model tests. No stale ordinary checkpoint can have its captured authority upgraded.

## Minimal TDD increments

1. Add mutation generation and model-semantic property/method hooks only. Real model tests: text same-length Unicode edit/undo; encode/BOM change and revert; savedText/bytes assignment with equal contents; pending publication replacement same bytes; file operation complete cycle; stale finish; bookmark mutation; ownership change. Existing dirty differential and factory/shared-pane harnesses unchanged and green.
2. Add separate close-state adapter with actual native composition/unfinished-remap/legacy saving checks. Tests hold state, mutate one field at a time and restore its value: generation must still differ for semantic events. No allocations proportional to text in adapter except existing dirty oracle fallback; code review confirms absence of String(storage), UTF16 arrays or layout calls.
3. Add repair installer actual red then green. Check wrong owner/generation/authority/fence/coordinator/document/zero revision/equal-authority replay; snapshot all model fields and assert refusal changed none. Successful installation preserves storage object, exact text, baseline, pending identity, bookmarks, panes and undo target. Highest/next issue once under new authority, including max revision exhaustion rules.
4. Extend process boundary/test for lagged model A0→actor A1→lease A1→receipt A2 and install-success/registry-refusal variant. Retain existing actor and registry acceptance checks and exact pause ownership; no dummy receipt or caller-current context.
5. Wire native semantic pane callbacks/admission only in the later reviewed controller migration. This slice alone cannot claim forced native close, GUI, process freeze or registry projection enforcement. Avoid a large all-at-once setter rewrite before the small model/adapter tests prove the contract.

No implementation requested by this document; root review determines the next bounded source ownership.

## Implemented slice and retained verification

EditorDocument has scalar/semantic property hooks and the existing editedCharacters observer now invalidates closeMutationGeneration. Authority adoption/repair/issuance do not rotate it. EditorDocumentCloseAdapter provides throwing captureCloseState, full repair snapshot capture, bounded geometry values, and installCloseRepair using immutable expected state/authority/fence. This adapter does not perform registry/actor-attempt correlation; the trusted process boundary must validate those separately before calling it. No EditorPane, DocumentPanePresentation or controller hooks were changed, so native selection/bounds/membership event admission remains future integration work.

Retained command: `bash scripts/test-native-close-model.sh [existing-debug-build-path]`. It snapshots native/core inputs, runs hidden NativeCloseModelHarness plus unchanged factory and shared-pane ownership controls, and records hashes/status in unique ignored directories. No showing/activation/events.

Compile-seam runtime red: 29 checks, 27 failures. First implementation: 50 checks pass, factory115 and shared ownership pass. Expanded actual undo/redo, native marked text, same-byte pending publication identity and stale semantic-state repair checks pass; exact final count and compatibility evidence are in the execution plan. Native marked text tests are not physical IME acceptance. No whole-buffer digest, new text/undo engine, publisher or recovery writer was introduced.

The process boundary now carries `DocumentClosingRepairContext` as the fourth installRepair argument. It is created from the original repair capture before `stage(.repairing)` can notify and before the actor await. Native application glue must map these captured values to NativeRepairInstallationContext without rereading expected authority/fence. Model A0 versus actor lease A1 remains deliberate. Twenty Foundation process tests passed, including all19 prior cases and a new reentrant fence-change refusal. Live native close activation remains deferred.
