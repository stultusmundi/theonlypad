# Exclusive Registry and Document Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task by task; independent review at every ownership boundary.

**Goal:** Deliver committed F-02 document movement between windows and independent pane tab groups without duplicate save/recovery ownership.

**Architecture:** ApplicationDocuments permanently owns models and exclusive group assignments. One guarded synchronous transaction changes assignment/order and native projections; window transfer ships before independent groups but uses the same ownership model.

**Tech Stack:** Swift5/macOS14, existing Foundation/AppKit/TextKit1 and session/checkpoint services. No dependencies.

**Spec:** [document-transfer.md](../specs/document-transfer.md). Initial view-free ownership tests are in progress; all unchecked work remains planned, with no native transfer runtime claim. Existing pane intermittency must be resolved before dependent integration.

## Global constraints

- Full different-document pane transfer is committed scope. Stages A/B do not fulfill all F-02.
- One registered EditorDocument/storage/UndoManager/baseline/monitor/recovery ID per logical buffer. One group assignment, no concurrent multiwindow ownership.
- 128 aggregate persisted live+unresolved document IDs,32 aggregate windows; moving adds0documents. Stage C maximum2groups/window,2views/document; at most4visible views, subject to additional resource acceptance before enabling.
- Preserve canonical v1/v2 session compatibility and unknown-version errors; Stage B changes no session wire, Stage C migration gets its own reviewed wire.
- Root owns AppDelegate/SessionCoordinator/application registry integration. One native owner controls EditorWindowController/EditorDocument/EditorPane; monitor owner handles relay/context changes. Isolate overlapping work, never revert other edits.
- No source text copying, file reopening or close/recovery-delete calls to implement move. No GUI execution while locked.

## Stage A1 — Registry lifetime and single-group projections

**Files:** new ApplicationDocuments.swift; root AppDelegate.swift and all document create/import/close registration paths; native controller membership accessors; new ApplicationDocumentsTests.swift.

**Interfaces:** exact complete registry/value/WorkspaceDocumentHandle protocol in README; windows initially register one group. StageA tests compile ApplicationDocuments with fake handles/endpoints in a temporary MainActor Swift5/macOS14 test package. Native types may import AppKit for declarations, but tests construct no NSWindow/NSTextView and run no executable entrypoint, event loop or GUI. Freeze required sources so compilation does not race the pane diagnosis. Actual AppDelegate injects one shared owner; standalone native tests get an explicit fresh owner and two-window tests share it. This registry red/green can run independently of the pending pane UI diagnosis once root freezes interfaces. All live model creation paths register once; native document arrays become projections of registry IDs.

- [ ] Write compiling seam then behavioral red for duplicate ownership: registering one document ID in two groups must fail while preserving first model identity/assignment. Existing independent window arrays cannot enforce this globally.
- [ ] Test source creation/open/restore/recovery/reopen/diskcopy/backup/scratch pathways retain their intended UUID rules, but each creates exactly one registered live model and assignment. Registering duplicateUUID refuses; paths are not substituted for identity.
- [ ] Test logical close removes one registration only after successful existing recovery cleanup; closing empty group/window removes no document. Pending failed cleanup retains model/assignment and error.
- [ ] Add pure capacity snapshot seam:128aggregate documents across multiple windows including unresolved IDs; transfer to existing is admitted, new129thdocument refused;32windows including unresolved-only window refuses New Window without any staged-window factory call. Pending cleanup/startup/corrupt session refuses snapshot without I/O.
- [ ] Freeze and test DocumentRegistryServices initializer callbacks/lifetimes: endpoint lookup, hidden factory, pure capacity+revision, actual handle-state adapter, admission update, history clone and change notification. Every injected callback attempts nested mutation before returning; gate must already be active even during initial lookup/capacity/preflight. Refusal yields exact old snapshot/revision/notification count and disposes provisional window once.
- [ ] Register pinned editable and streaming fake handles directly via required WorkspaceDocumentMetadata, never setPinned first. Assert projected pin/order/capture, history clone registration and rollback preserve that sole registry authority; failed clone/duplicate ID/capacity keeps history.
- [ ] Add pure registry red tests for all mutators: valid/invalid selectDocument and focusGroup; reorder/pin stable partition; createGroup cap2; empty-group/window unregister; stale revision and busy reentry refusals. Snapshot and callback counts must remain unchanged on refusal.
- [ ] Close tests capture a DocumentCloseRequest before confirmation, then beginClose installs a lease before held cleanup: model/assignment remain until success; failure retains live model, stale ticket cannot close newer assignment, batch independent results preserve failed items. Clean history capacity10/window retains original model/pane references; reopen constructs fresh model/UUID and matching current clone metadata, history popped only after successful registration; failed capacity retains item. Dirty discard nohistory, window unregister releases history, transfer never modifies it.
- [ ] Migrate every creation/mutation row in README and audit no remaining documents append/insert/remove/array setter, selectedID direct setter or independent pinned assignment in controller. Implement registry-backed single-group projections, preserve existing semantics, run session/recovery/close tests before move.

Representative invariant:

```swift
try registry.registerDocument(document, metadata: WorkspaceDocumentMetadata(pinned: true), in: sourceAssignment, at: 0, select: true)
XCTAssertThrowsError(try registry.registerDocument(document, metadata: WorkspaceDocumentMetadata(pinned: true), in: targetAssignment, at: 0, select: true))
XCTAssertTrue(registry.handle(id: document.id) === document)
XCTAssertEqual(registry.assignment(of: document.id), sourceAssignment)
```

## Stage A2 — Owner relay and stale-result fences

**Files:** new DocumentWindowBinding.swift; EditorDocument.swift, PaneCommandContext/controller async guards, DocumentFileStateController construction; new DocumentTransferOwnershipHarness.swift.

- [ ] Red: hold a source command, assign source→target→source, then complete with unchanged text/editRevision/selection. It must refuse mutation under the old ownershipGeneration. A membership-only seam must fail this assertion first.
- [ ] Add document ownership UUID rotation and registry mutation gate to canMutate/canFocus/close/quit/checkpoint. Do not reuse editRevision or reset baseline/recovery IDs.
- [ ] Audit every async mutator and success handler: open/reload/save; disk reload/copy/Locate; encoding; line/bookmark commands; search/outline navigation; utilities/panels; macro replay/save; delayed pane install. Record exact context field or preflight blocker per callsite. A task not using PaneCommandContext must explicitly check captured ownership UUID or be guaranteed drained before move.
- [ ] Real close-admission red/green: beginClose then hold actual recovery cleanup; attempt NSTextView edit, menu/responder undo/redo, file-operation begin/baseline adoption, transfer and a previously captured async mutator. Assert native handle admits none, frozen metadata/text remains, duplicate close refuses. Release cleanup failure and verify editing resumes unchanged. Release success under matching state and remove exactly once.
- [ ] Defensive native mutation regression: bypass normal editor entry with direct NSTextStorage change, including beginEditing before processed notification, while cleanup is held. Successful old cleanup must retain model/assignment and enter recoveryRequired, never remove newly dirty text. A fresh confirmed checkpoint is required before quit. This test proves final state guards in addition to fake ticket accounting.
- [ ] Bind actual monitor bridge once; deliver changed+read-only/manual/dismissed state, rehome relay, assert same registration/validated identity/baseline/state and target-only rendering. Held source actions rejected; ordinary document observations still eligible at target. No implicit adoptBaseline or invalidateFileState.
- [ ] Test weak relay/window release; close source after move cannot prevent target editing/monitoring. No new observer or recovery writer per move.

## Stage B1 — Shared assignment transaction, windows first

**Files:** registry transaction implementation, native DocumentMoveEndpoint methods, new DocumentTransferHarness.swift plus dedicated hidden runner. Root prepares staged-window factory and transfer/checkpoint gates.

- [ ] Red: dirty emoji/mixed-EOL source with bookmark/undo/two-pane presentation moves to target. Assert same model/storage/undo/all pane identities, exact source and target membership, zero recovery.close calls and one postcommit notification.
- [ ] Test every refusal leaves registry/projections unchanged: stale chooser revision, no longer selected source, samegroup, invalidindex, missing endpoint, closing/quit/startup, cleanup/load, saveoperation/pending uncertainty, macro state, marked text/composition source or target, draining pane worker, duplicateUUID/standardizedURL, aggregate capacities.
- [ ] Implement busy gate before ANY service/endpoint callback→final preflight and exact post-callback revalidation→rollback snapshots→single registry assignment change→native projections→relay→commit. No await/modal/I/O inside. Stage C group destination enum exists but UI stays unavailable until group host/resource tests pass.
- [ ] Inject source and target projection failures separately. Assert rollback restores exact registry order/selection/assignment and view state; attempt both endpoint restorations even if one fails. Inject rollback projection failure, assert registry still strongly owns exact model, retained receipt/recovery-required state and quit veto; Retry Layout repairs from models without file reads.
- [ ] Endpoint callbacks at preflight/projection/rollback attempt nested move, register, close, capture and quit. Assert workspaceBusy refusal and exact token cleanup. No callback sees an accepted duplicate/missing document capture.
- [ ] Move away/back while held callbacks attempt completion; old authority never resurrects. Test source-empty state and source-neighbor selection; keep pin/index, preserve target's previous selected-view state on rollback.
- [ ] Two-pane frame/settings fixture: destination different size/default wrap/font; moved document keeps actual settings and exact ranges, origins constrained once with recorded resulting metadata; deferred mapped slot+dormant slot remain. No new layout/storage/undo allocation, no delayed origin jump after user input.
- [ ] Actual hidden native undo through both moved panes after source closes retains exact text/history. Source closing invokes no moved-document recovery deletion.

## Stage B2 — Accessible window move and checkpoint persistence

**Files:** root AppDelegate/AppCommands; new DocumentTransferController.swift; empty-window view; ApplicationDocumentTransferTests.swift.

- [ ] Registry command `file.moveToWindow` / `Move Document to Window…`, no default shortcut. Menu/palette/help/custom shortcuts continue using one command authority.
- [ ] Native destination chooser existing non-source windows + New Window, disambiguated visible labels. AX IDs `documentTransfer.destinations`, `documentTransfer.move`, `documentTransfer.cancel`. Capture before chooser and validate workspace/ownership revisions after it. Actual hidden buttons test Cancel/no effect, stale source/target refusal and exactly-once move.
- [ ] NewWindow pure capacity test precedes factory invocation; hidden prepared endpoint enters lasting app/session registry only at commit and is disposed on failure. Show/focus only after stable commit. Focus failure reports warning without changing successful assignment. MRU unchanged.
- [ ] Actual window delegate flow: first windowShouldClose returns false while asynchronous tickets drain, duplicate request starts no second cleanup, failure keeps window and failed tab alive, mixed-success batch closes only successes. Guarded second close succeeds only after assignments empty/current revision permit; unexpected windowWillClose without permit retains registry-owned models and recovery-required state. Empty source window requests no cleanup; quit remains separate global persistence.
- [ ] Empty source window has New/Open and disabled document actions; it does not fabricate a scratch or destroy target recovery.
- [ ] Stage B flattens its sole group into existing SessionWindow tabs; capture occurs only outside busy transaction. Hold old checkpoint, move, release, then confirmed later checkpoint/finalquit must persist target assignment exactly once. Crash before later checkpoint may restore old placement; preserve one recovery identity and document content.
- [ ] Session-write failure vetoes quit without reverting transfer; repair/retry keeps target editable and final placement durable. Run reviewed root session/monitor/owner compatibility suites after freeze.

## Stage C — Independent document pane tab groups (required F-02 completion path)

**Files:** new WorkspaceGroupHost.swift and DocumentGroupController.swift; registry existing destination group/newGroup cases; root AppCommands/AppDelegate/session wire review; native routing; new DocumentGroupTransferHarness.swift and core group migration tests.

**Ownership continuity:** ApplicationDocuments still owns every model and same assignment struct. Existing move transaction and rollback receipt are reused; only endpoint projections render two groups. No window-to-app ownership conversion occurs here.

- [ ] Write source/target independent-group test that initially fails: two groups show different registered documents, each has independent tab selection/focus and exact one assignment. Move document from groupA togroupB preserves identity/history; empty groupA remains empty, no duplicate recovery.
- [ ] Implement at most two group controllers/window. Each group hosts its selected document's existing pane host; a two-view document stays two-view when transferred. Add separate focusedGroupID/axis, groups use separate tab strips. Both document splits can coexist as four views only after actual resource/geometry bounds testing; do not silently collapse one to satisfy a frame.
- [ ] Gate routing by focusedgroup/document/pane plus ownership generation. Native window undo resolves focused document; stale command from previously focused group cannot mutate the new group's document. Composition in either affected group vetoes move/focus according to existing policy.
- [ ] Review exact next session wire before editing: ordered groups/focusedgroup/groupaxis, document record exactly once, selected membership validation, unique IDs and2group cap. Freeze canonical v1/v2 fixtures before migration, preserve unresolved group assignment and no load rewrite. Update aggregate count logic without counting panes as documents. No new recovery format.
- [ ] Add `file.moveToOtherPane` and `view.newDocumentPane` real actions backed by group/newGroup destinations; label distinct from existing split view. No generic left/right drop accepted without a registered target group and valid request.
- [ ] Test nested layout min-size/clamping, both axis combinations, four-visible-view limit, collapse/close emptygroup, transfer to/from another window's group, rollback and one recovery/monitor perdocument. Resource acceptance is measured separately with watchdog; do not weaken limits or suppress pane diagnostic failures.

## Stage C2 — Read-only large-file ownership and transfer (required coverage)

**Files:** extract StreamingDocument.swift from LargeFileWindowController.swift; root AppDelegate largeViewers lifecycle; handle-specific move endpoint adapter; core session kind/byte-offset schema from Stage C reviewed migration; new StreamingDocumentTransferHarness.swift.

- [ ] Foundation fake streaming handle already passes the same registry assignment/order/close transaction tests. Add actual native red: current standalone large viewer cannot be moved while preserving reader identity; do not substitute an EditorDocument or read the whole file.
- [ ] Extract reader,65536-byte page state,offset/search state and request tokens to StreamingDocument conforming to frozen WorkspaceDocumentHandle. Keep view/controller construction separate; registry becomes sole lifetime owner and largeViewers becomes endpoint projection, then remove its independent ownership.
- [ ] Real synthetic sparse large-file fixtures: transfer idle view preserves exact reader identity/byte offset/page bytes and page selection, no second open/full allocation; pending page/search work refuses until drained and stale old-owner completion cannot paint after move-away/back. Close releases reader/tasks once, no RecoveryCoordinator.close for streaming ID.
- [ ] Persist explicit read-only handle kind/byte offset with group assignment in the reviewed same-envelope schema; startup reopens bounded reader and checks identity, retains missing/changed records unresolved and does not decode whole source. Legacy editable v1/v2 fixtures unchanged; futureversions refused. No falsely asserted recovery buffer for a read-only source.
- [ ] Native and actual desktop transfer/restart tests for the viewer must pass before F-02 is called covered for large files. Until then record this as a mapped outstanding part, not an editor-only scope waiver. Ownership transaction signatures remain unchanged.

## Stage D — Real desktop F-02 acceptance

**Files:** additive Tests/DesktopUI/GUIProbe.swift tests and verification records under root ownership. Unexecuted while locked.

- [ ] Actual Move to Window chooser moves dirty split document to existing/new window; source tab removal/target pin/order/focus, typing and CmdZ/redo in both views, originalfile untouched until explicitSave.
- [ ] Close now-empty source, continue target editing/undo, quit/relaunch: exact content, target window/group order, pane states and one recovery entry. Final sessionfailure veto retains transfer; repair/relaunch preserves it.
- [ ] Actual independent tabgroups workflow: select different docs in two panes, move tab to otherpane then anotherwindow, verify distinct content/selection/undo and exactly one location after restart. Group UI/menu keyboard actions required even if drag/drop added later.
- [ ] If drag/drop is included, carry document/request IDs through same validated transaction, reject external file payload as internal move, cancel leaves unchanged. It is not a second ownership implementation.
- [ ] Report blocked/unexecuted GUI status explicitly. Hidden AppKit checks are not physicalIME, VoiceOver, restart or latency acceptance. F-02 remains partial until independent-group, streaming-handle and real desktop workflow evidence satisfy the committed scope.

## Review gate

Root reviews registry migration and relay/async audit before implementation. The full F-02 path is an architectural commitment; staging only bounds review and testing. No user scope waiver is inferred from a first increment.

## Frozen first implementation boundary

Stage A1 first slice implements only view-free handle ownership, window/group metadata, selection/focus, stable pin partition/reorder and empty group/window removal. Close tickets/history, movement, service callbacks/capacity provider and native projections remain planned; no throwing placeholder methods ship for them. Pure DeferredPresentationReceipt replaces native pending types in future transaction receipts; staged endpoint adopt is explicit before success; notifications occur after token release with immutable results prepared beforehand.

## Initial ownership execution evidence

The view-free subset now implements window/group registration, unique UUID and object identity ownership, metadata/pin ordering, selection/focus/reorder, group axis and empty group/window removal. It has stale-revision and reentry guards, stable no-op revisions and notifications after commit. Current constructor/onChange are the minimal subset; the broader services, close/move and endpoint APIs above remain planned, with no placeholder methods. Limits here are live-only32windows/128handles.

Independent review found no material issues in that subset. A changed-UUID/same-object alias regression failed before the ObjectIdentifier guard; first assignment and metadata now remain unchanged. Root reran13tests with zero failures in0.005seconds (`.local/registry-root-verification.log`). The separate pure SessionCoordinator snapshot unions live and unresolved IDs, refuses incomplete/error/cleanup states and supplies an invalidation revision; root reran7tests with zero failures in0.007seconds (`.local/capacity-root-verification.log`). It truthfully returns over-limit sets and leaves admission to the future registry adapter. Neither test suite establishes native transfer or cleanup safety.

Proven commands: `scripts/test-application-documents.sh` and `scripts/test-session-capacity.sh`. Both freeze sources and propagate bounded test-process failures. No GUI, remote CI or native application integration was performed by these commands.

Close slice: [reviewed close/admission design](../specs/document-close.md). View-free implementation in progress; native cleanup and recovery lease integration remain planned.

The close-state extension is implemented in local commit `11d2a25` and independently reviewed: 30 tests pass, including the unchanged 13 basic tests. Its optional state adapter has no fake default; unsupported close requests fail explicitly. Native cleanup is not wired. Real two-phase recovery behavior, actor-issued durable repair receipts and native close admission remain required before application adoption. See [close design](../specs/document-close.md) and [registry evidence](../../verification/document-registry.md).
