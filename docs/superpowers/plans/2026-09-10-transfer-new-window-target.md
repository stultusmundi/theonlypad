# Transfer to a new window implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task. Delegate only with separately assigned ownership. Retain genuine behavioral red/green evidence and request independent review before integration.

**Goal:** Add a New Window destination that moves the existing selected editable document into one new application-owned window without creating, decoding, adopting, or copying a document.

**Architecture:** A small process-owned preparation record reserves admission and an existing publisher pause before constructing an empty endpoint. It hands the actual source and registered destination to the existing transfer coordinator. It retains ownership of provisional-window cleanup until the transfer and endpoint cleanup settle; cancellation of a waiter does not discard that record.

**Tech stack:** Swift 5 mode, Foundation, AppKit, existing registry/transfer/publisher services. No dependency, schema, actor authority, or filesystem-monitor redesign.

**Spec:** [native-document-transfer.md](../specs/native-document-transfer.md), extending its explicitly deferred new-window stage only. [document-transfer.md](../specs/document-transfer.md) remains the full F-02 scope.

**Status:** Root-reviewed plan in execution. Task 1 admission/preparation is implemented and independently approved after review fixes, with 23 preparation and 10 native-open tests passing; Task 2 handoff is also implemented and independently approved (44 new-window tests plus matching compatibility); Task 3 chooser/presentation is independently approved (15 chooser and 12 transfer tests pass). Final committed-source core 404, managed 71 and new-window 44 tests pass; local package refresh is verified. See `docs/verification/new-window-integrated.md`. Physical desktop acceptance remains blocked. Existing-window evidence does not certify this stage.

## Constraints and current source mapping

- Move the same EditorDocument, UUID, storage, undo manager, pane pool, baseline, encoding/BOM, bookmarks, recovery authority and monitor. No factory, seed, intake, history, close, reload, disk-copy, or recovery adoption operation creates the destination document.
- At most 32 aggregate live plus unresolved window IDs, including unresolved-only windows. Creating a window adds no document ID; preserve the exact aggregate document-ID set. Do not apply a new 128-document growth check to an operation that adds zero documents or hide truthful over-limit startup sets. Refuse new-window growth when the existing window union already exceeds the limit.
- Use `SessionCoordinator.transferCapacity(liveWindows:)`, which refuses unfinished restoration, preservation errors and pending recovery removals. Its returned `sessionRevision` and exact sets are authoritative only for the validated snapshot; re-read after every await or callback that can change capacity.
- `NativeApplicationDocuments.createEndpoint` currently combines register/create/decorate and invokes `onWindowCreated`; its `forTransfer` path recreates an existing registry window, not a new one. Do not call `createWindow()` (which can create a scratch document) or repurpose `forTransfer` to skip new-window capacity checks.
- `ApplicationDocuments.unregisterEmptyWindow(_:expectedRevision:)` is the only removal primitive. Do not introduce generic unregister or delete models/history to clean up a provisional window.
- `ApplicationDocumentTransfer` already owns registry/monitor phases and a publisher pause, including explicit endpoint-recreation retry. Reuse that state machine. Do not duplicate its rotations, rollback, monitor reservation or settlement logic in the new-window wrapper.
- Existing `NativeDocumentMoveChoices` captures source document/ownership/window/endpoint. A new-window row is a typed choice, not an invented existing destination UUID.
- No filesystem I/O, full dirty comparison, string copy, glyph traversal, or bookmark scan in capacity/admission. Native transfer scalar preflight remains bounded.
- Aggregate F-02 remains incomplete: independent document groups, streaming-handle transfer, remaining full metadata/pane clauses and physical desktop acceptance are separate work.

## Proposed interfaces to freeze before implementation

Place the small new-window operation types in a new `NativeNewWindowTransfer.swift`; keep process orchestration beside the existing NativeApplicationDocuments owner, without duplicating owner state in a second singleton.

```swift
enum NativeDocumentMoveTarget: Equatable {
  case existing(NativeDocumentMoveDestination)
  case newWindow
}
struct NativeNewWindowMoveID: Equatable { /* opaque owner-issued UUID */ }
enum NativeNewWindowMoveResult {
  case moved(NativeDocumentMoveDestination) // actual final endpoint, only after cleanup
  case restored(Error)
  case retained(Error)
}
// NativeApplicationDocuments, MainActor:
func startMoveToNewWindow(_ choices: NativeDocumentMoveChoices) throws -> NativeNewWindowMoveID
func waitForNewWindowMove(_ id: NativeNewWindowMoveID) async throws -> NativeNewWindowMoveResult
```

A synchronous `start` installs a process-owned record before callback-capable admission and returns its own real operation ID. It must not manufacture an ApplicationDocumentTransferID before `transferring.start` succeeds. The record stores the captured source, freshly minted window/group IDs, exact created endpoint incarnation, capacity snapshot, outer pause, optional actual inner transfer ID, outcome and cleanup phase. Only one such record may be unfinished. `retryRecovery` retries the recorded phase/inner ID; it never starts a second move or creates a second destination.

Add a pure owner query for new-window availability, returning an optional actionable refusal reason. The chooser may use it for a disabled New Window row, but `startMoveToNewWindow` always repeats authoritative admission. Existing destinations remain available when new-window capacity is exhausted. `NativeDocumentMoveChoices` may carry that display reason; it is not an authorization token.

Internal endpoint construction must separate **register**, **construct/configure**, and **announce/show**. Current `AppDelegate.decorateEditor` applies settings, installs callbacks **and shows the window**. Split its nonpresenting configuration from presentation: add a constructor collaborator `configureWindow: (EditorWindowController) -> Void` (legacy/test callers may use the existing default configuration), and have the production AppDelegate supply the settings/callback configuration explicitly. Apply it to the exact empty provisional endpoint under the preparation gate before moving a model. It must not call `showWindow`, create a document, or invoke an original-file write. Existing ordinary window creation still presents through its current creation callback after configuration; new-window transfers present only through the generation-fenced completed-move path. Do not call both the existing presenting `onWindowCreated` and the post-move presenter for one new destination. Keep internal creation-commit bookkeeping distinct from a claim that a visible presentation occurred. Suppress this legacy callback only for the exact provisional target and its recorded replacement endpoints. Preserve the existing ordinary source-replacement callback and its current-endpoint validation; otherwise surviving source tabs can be left hidden. A source-replacement callback still runs under the generic-operation gate and does not authorize a second move.

Use a private exact provisional record to identify effects before any throwing step. Reuse existing controller creation/routing/settings code through a private helper instead of copying it. The new-window path does not invoke the legacy presenting creation callback; the final generation-fenced presenter alone shows the exact settled destination. Configuration and endpoint bookkeeping remain separate from presentation.

## Admission and failure order

1. Check immutable request shape, then install `preparingNewWindow` before supplied callbacks. Validate ready/not quitting, no pending new-window operation, existing transfer/intake/close/external-open/history work settled, and exact selected source model/ownership/window/endpoint. A new choice accepted after ordinary text edits uses the current existing buffer; ownership/selection/endpoint changes invalidate it.
2. Read registry live window/document sets and `session.transferCapacity`. Mint destination IDs absent from both window and document domains; require `windows.union([newWindowID]).count <= 32` and identical before/after document sets. Store both registry and session revisions with the private proposed destination before effects.
3. Acquire and retain an **additional exact publisher pause**, drain it and legacy writers, then revalidate source and capacity. The scheduler supports multiple pause leases. Acquisition/drain failures leave no untracked window or token. Already captured publication may finish; no capture may observe a newly created provisional window.
4. Register the new empty one-group window and construct its endpoint under the preparation gate. Record registration immediately after its nonthrowing mutation phase and endpoint installation before callback-capable configuration. Do not announce it, create a tab, or install/re-adopt the source model. Revalidate exact capacity/source/registration after callbacks. Reentry into start/open/intake/close/quit must refuse, never create a second record.
5. Submit the ordinary selected-source transfer request with this exact destination and current registry revision. Permit only this internal handoff through preparation admission: a private scoped operation identity must match the recorded source/destination, and no callback gets a general bypass. `transferring.start` returning an ID is the handoff receipt; retain it before any further callback. Failure before receipt goes to unused-provisional cleanup.
6. Await the inner owned transfer. Its native ports, ownership rotations, monitor receipts, endpoint recreation, no-effects projection and rollback remain unchanged. The outer record and outer publisher pause remain alive across retained failures and waiter cancellation. If the inner transaction retains, keep the provisional registry window even if empty; its rollback still needs that assignment.
7. On inner `.moved`, mark the provisional window committed before announcement. Validate actual current destination endpoint, source model's target assignment and selection; return its real descriptor after outer cleanup. On `.restored`, clean up only the exact unused provisional window. Never remove a committed/nonempty/reused/replaced window to make an error disappear.
8. Release only the outer pause after cleanup is coherent. Retain the exact token until `releasePause` returns, then clear it; existing release methods throw only before consumption. Keep the operation and cleanup-running gate installed across synchronous renderer callbacks so reentry cannot consume another token or start new work. Clear the preparation record before completion callbacks and requesting a new checkpoint. Return the real destination to the generation-fenced AppDelegate presenter; do not show through an unfenced owner creation callback. Revalidate exact endpoint after any nonpresenting completion callback. Presentation failure leaves ownership committed and reports that distinction; it does not roll back the move. Failed pause release or cleanup retains an explicit retry phase and quit veto, not a successful result.

### Two gates must remain distinct

New-operation admission (`start`, intake, close, history, external destination selection, new windows and quit) and managed capture must consider the unfinished new-window wrapper. Publisher preparation must **refuse**, not await that wrapper, to avoid drain cycles. Its extra pause prevents a provisional empty window from being published between inner settlement and outer cleanup.

Native projection/admission is not the same gate. While the wrapper has handed off, the existing inner transfer's `allowsNativeAdmission` must still permit its exact cleanup projection/refresh once its lease is settled; otherwise the wrapper deadlocks waiting for a transfer whose cleanup it blocks. After inner settlement, ordinary edits allowed by that existing contract remain valid and must be preserved. The wrapper must never revalidate an old dirty/text snapshot to approve terminal cleanup. Generic new operations remain blocked until the wrapper settles.

Use explicit private phase predicates, not temporarily clearing the record or setting callbacks to nil. Add tests for this distinction before accepting the handoff implementation.

A file-open request accepted into the bounded FIFO during preparation must retain its original envelope when destination admission is temporarily unavailable. Explicit retry after cleanup must import that same request once, preserving FIFO order and creating no extra endpoint. Re-enqueueing the request is not evidence of retryability. Classify only this transient no-side-effect admission failure as retained; malformed and permanent failures retain their existing treatment.

### Exact unused-window cleanup

Cleanup requires the same owner operation, original provisional window/group, current endpoint incarnation or a separately recorded owner recreation successor, empty document membership, no closed history, and no external commitment/announcement. A changed or used window is retained with an actionable error; do not silently claim rollback completed. Endpoint loss alone does not authorize removal of a different replacement endpoint.

Under the owner preparation gate, validate emptiness/identity, unregister the exact empty registry window using the current checked revision, then remove only its matching endpoint record and close only that captured controller. Record each completed effect before invoking window callbacks. Expected close callbacks must observe that cleanup already owns the removal and become exact idempotent cleanup, not unregister again or erase a newer endpoint. A failure after unregister cannot resurrect the registry window or repeat its unregister on retry. No callback may make cleanup release another operation's publisher token.

## Task 1 — Provisional admission and capacity

**Files:** new `Sources/TheOnlyPad/NativeNewWindowTransfer.swift`; narrow nonpresenting configuration split in `AppDelegate.swift`; narrow owner changes in `NativeApplicationDocuments.swift`; new `Tests/NativeIntegration/NativeNewWindowTransferTests.swift` and `scripts/test-native-new-window-transfer.sh` (new runner, not yet a verified command).

- [x] Freeze the existing-window production sources and agree exact operation/phase interfaces with root. Give nonoverlapping ownership to endpoint, chooser and owner contributors.
- [x] Add compiling refusal seams and tests using the actual SessionCoordinator/registry/publisher: 31 aggregate windows admits the 32nd; 32 refuses before controller construction; live/unresolved overlap counts once; unresolved-only windows count; >32 existing union refuses growth; 128 existing document IDs still permit a move when window capacity allows.
- [x] Add corrupt-session, pending-removal, foreign/stale source, source-selection/ownership ABA and capacity-revision change during held drain tests. Count controller construction and document-factory/adoption calls: refused admission creates none, successful new-window move creates one controller and zero models/adoptions.
- [x] Run actual behavioral reds, separating compilation/setup failures. Implement the minimal capacity/preparation gate and exact outer-pause lifecycle, then rerun unchanged assertions.
- [x] Reenter open/intake/close/quit/new-window move from admission/register/configuration callbacks. Assert one retained operation and no second endpoint; test publisher preparation refuses rather than waits.
- [x] Independently review before adding handoff behavior.

## Task 2 — Existing transfer handoff and exact cleanup

**Files:** owner/new-window types above; same new native tests/runner. Modify existing process/native ports only if a concrete failing contract requires it and ownership is coordinated.

- [x] Write real hidden-controller red: move dirty Unicode/CRLF source to a new window; assert same UUID/model/storage/undo/panes/authority and no extra scratch. Verify source neighbor selection, pinned target ordering, original bytes/encoding/BOM and one final paired recovery identity.
- [x] Gate actual paired publisher before capture and after old-placement capture. Ensure preparation drains and both pause tokens release exactly once; final store readback contains the new target only after settlement, never a leaked provisional window.
- [x] Exercise failure before registration, after registration before controller return, after endpoint installation, before inner start, during source/target projection, and in rollback. Assert either exact unused cleanup or retained same inner transfer/endpoint, never duplicate creation/read/adoption on retry.
- [x] Cancel a waiting task without cancelling operation ownership. Reenter a second operation during final notifications; old cleanup must not erase its state.
- [x] Close the provisional endpoint before staging, after staging and during terminal refresh. Reuse the real file-backed monitor tests: source-close-before-reservation, target-afterstage, final endpoint reattachment, original parent continuity and external-change detection after retry.
- [x] After inner settlement but before wrapper cleanup, edit the surviving moved model. Cleanup/presentation must preserve the latest text and undo; no old receipt may overwrite it.
- [x] Force cleanup refusal by populating/replacing the provisional endpoint via an explicit test boundary; it must remain retained. Test already-unregistered cleanup retry and reentrant close callback. Never weaken registry admission merely to create this fixture.
- [x] Implement, obtain independent review, and rerun existing owner/process/monitor compatibility suites from a frozen source snapshot.

## Task 3 — Product chooser and presentation

**Files:** `NativeDocumentMoveChoices.swift`, `DocumentMoveDestinationController.swift`, `AppDelegate.swift`, `DocumentMoveDestinationTests.swift` and its test-only access. Canonical `file.moveToWindow` remains the sole command; no new shortcut or macro action.

- [x] Write an actual-control red for the typed New Window option. It must work when no other window exists; show a clear capacity/restoration refusal when unavailable, not a fake destination or silent no-op. Existing destination selection/cancel behavior remains unchanged.
- [x] AppDelegate branches on the exact typed target: existing uses current APIs; new starts/waits the new-window operation. Keep exact chooser identity, source ownership, quit and presentation-generation fences. Route retained outcomes to existing Retry Recovery status.
- [x] Test actual hidden dispatch through chooser New Window into real owner; Cancel makes no controller/window/model; stale chooser refuses; capacity changes while chooser open are caught at acceptance; newer chooser/quit invalidates late presentation.
- [x] Announce/show only the settled real destination once. Show failure never reverses a committed move. Hidden injected presenter verifies the exact controller and selected moved document; it is not desktop-focus evidence.
- [x] Run formatter, shell syntax, diff checks and independent source review. Preserve red/green logs privately and record verified runner commands only after they actually work.

## Validation and completion boundaries

Established commands to retain unchanged alongside the proposed new runner:

```sh
bash scripts/test-native-application-document-transfer.sh
bash scripts/test-application-document-transfer-process.sh
scripts/test-application-document-transfer-publisher.sh
bash scripts/test-document-move-destination.sh
scripts/test-session-capacity.sh
```

These commands are existing entry points; passing historical runs do not certify the new stage. Before integration, run the affected core/native compatibility suite from a coordinated source freeze with owned-child watchdogs and source hashes. Use only synthetic private files. Retain failed partial evidence and distinguish test-fixture issues from behavioral failures.

Final verification must state separately: planned interfaces; implemented new-window behavior; actual hidden/native and real paired-store tests; compile-only desktop tests; blocked physical GUI tests. Physical desktop acceptance still needs choosing New Window, visible target/focus, independent editing/undo, closing the original window and normal quit/relaunch. No hidden test or successful build closes groups/streaming or aggregate F-02.

Root design review: approved for implementation after the existing-window integration commit. Keep the preparation token and handoff predicates explicit; tests must prove the inner cleanup remains admitted while generic new work is blocked. The configuration split is required to avoid premature or duplicate presentation. No new dependency or schema change is approved by implication.
