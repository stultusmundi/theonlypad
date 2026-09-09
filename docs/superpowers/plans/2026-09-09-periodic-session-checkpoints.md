# Periodic Session Checkpoints Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Preserve concurrent edits and obtain a source/build handoff before integration. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist bounded, ordered recovery and session checkpoints during ordinary editing, without writing original files or overtaking the final quit save.

**Architecture:** One main-actor scheduler captures a coherent text/metadata pair and submits it to the existing recovery actor. That actor validates recovery dispositions and performs the recovery barrier and session publication without an intervening suspension. It returns an explicit publication receipt; only then may the scheduler report a completed generation.

**Tech Stack:** Swift, Foundation, AppKit, existing private RecoveryStore and SessionStore; no new dependency.

**Spec:** `docs/superpowers/specs/session-checkpoint-ordering.md` and its review below.

**Status:** Production integration outstanding. Task1 exists only as an ignored candidate with red–green real-store/legacy recovery harness evidence and independent re-review after fixes. Task2 isolated scheduler work is in progress. Checkboxes below remain unchecked until integrated verification.

## Constraints and guarantee

- Start after startup restoration and unresolved-record merge complete. Preserve unreadable/future session metadata; do not overwrite it to clear a warning.
- Keep one active checkpoint and one pending generation, not one retained full-text task per notification. Keep existing store bounds: 32 session windows, 128 tabs, 50 recent paths, 100 million recovered UTF-16 units total.
- No new whole-text equality check on every keystroke. Capture immutable text only at a checkpoint boundary; separately measure that capture and serialization overhead.
- Checkpoint completion means the captured metadata was published after its accepted recovery batch, not that every subsequent edit is durable. Later ordinary recovery may contain newer text; restoration continues to prefer that text and validate/clamp positions.
- Existing UUID recovery files and Session.json are separate publications. A crash between them can combine newer recovery with older metadata. Do not promise an atomic multi-file snapshot or exact selection/bookmark correspondence across that crash interval.
- In-memory close tombstones prevent old writes from resurrecting discarded recovery during this process. A crash before post-close metadata publication can still expose an old clean-file tab or unresolved scratch record. Strong durable close semantics require a separate persistent tombstone/journal design; do not silently delete unresolved records to hide this limitation.

## Findings in the current implementation

1. `EditorWindowController.recoveryBatch()` increments `recoveryRevision` on capture, including unchanged content. It is an issuance order, not an edit revision. Comparing it before/after typing cannot prove that text is unchanged.
2. `RecoveryCoordinator.persist`, `clear`, and `persistBatch` silently skip closed/older revisions. A successful Void return does not prove the requested snapshot was written. Batch failure can follow successful partial writes; there is no rollback.
3. `SessionCoordinator.persist(windows:)` accepts already-captured windows, then awaits removal tasks before merging current unresolved state and history. Periodic use would mix capture moments. The existing frozen quit path limits this problem; an ordinary live checkpoint does not.
4. Each SessionCoordinator save launches a detached store operation. Main-actor isolation and SessionStore's filesystem lock do not prevent reentrant callers from publishing generations in reverse order.
5. Per-window recovery currently captures a full batch before waiting for previous work. Repeated slow writes can retain multiple batches in a task chain; adding a second periodic full-text producer would worsen this.
6. `finishPendingCloses()` presents quit-specific modal errors. A periodic coordinator needs a throwing, nonmodal cleanup barrier, while quit can retain its existing presentation wrapper.

## Interface decisions

These are proposed interfaces, not existing APIs. Keep the types near the native coordinators; no AppKit objects cross into the actor.

```swift
struct RecoveryCheckpointItem: Sendable {
  let id: UUID
  let revision: UInt64 // capture issuance order only
  let snapshot: RecoverySnapshot? // nil acknowledges a clean-file clear
}
struct SessionCheckpointCapture: Sendable {
  let generation: UInt64
  let liveTabIDs: Set<UUID> // exact IDs requiring recovery receipts
  let recovery: [RecoveryCheckpointItem]
  let session: EditorSession // immutable, captured with the recovery array
}
struct SessionCheckpointReceipt: Sendable {
  let generation: UInt64
  let recoveryRevisions: [UUID: UInt64]
}
enum CheckpointFailure: Error {
  case superseded, closedDocument, notReady
}
```

Expose main-actor `EditorWindowController.captureSessionCheckpoint()` returning window metadata plus its recovery items synchronously. Build selection/bookmarks from the same editor state as the captured text; do not recapture metadata after waiting for recovery. `SessionCoordinator.captureSession(windows:) throws -> EditorSession` must synchronously merge unresolved records/history and check restoration/preservation status. Move removal awaiting to `drainPendingRemovals() async throws`, called before capture; if the unresolved revision changes while draining, drain again before capture.

Add `RecoveryCoordinator.commitSessionCheckpoint(_ capture: SessionCheckpointCapture) throws -> SessionCheckpointReceipt`. Actor calls remain asynchronous from the caller, but this method has **no internal await**. It preflights every live item against tombstones/revisions, persists the bounded batch, checks that each requested revision has the requested disposition, then calls synchronous SessionStore.save. Only return a receipt after save succeeds. A newer receipt may not be inferred from a skipped older request. Equal revisions must have a single immutable meaning: keep capture issuance unique and never reuse a revision for changed text/disposition.

Store the injected synchronous session writer on the recovery actor for tests; do not pass an async main-actor closure into this transaction. This is reuse of the existing recovery writer, not a second recovery actor. Unresolved recovery records are preserved by SessionCoordinator and need no invented new write acknowledgement. Validate that only live tab IDs require new receipts.

The scheduler exposes `requestCheckpoint()`, `startAfterRestoration()`, `pauseAndDrain() async`, `resumeAfterVeto()`, and `commitFinal(_ capture:) async throws`. A single task owns all calls to commit, including quit. `pauseAndDrain` stops timers and waits for an already-started commit; cancellation alone cannot retract a synchronous rename or prevent an already-resumed task from saving later.

## Task 1: Recovery dispositions and publication boundary

**Files:** modify `Sources/TheOnlyPad/RecoveryCoordinator.swift`; create `Tests/NativeIntegration/SessionCheckpointStoreHarness.swift`; extend `Tests/NativeIntegration/RecoveryHarness.swift` only for shared disposition assertions.

- [ ] Write a real temporary-store regression: persist revision 2, request revision 1 in a checkpoint, assert `.superseded` and no session writer call. Close an ID, submit its captured snapshot, assert `.closedDocument` and no session publication.
- [ ] Run the harness through the existing native script after adding its compile entry; observe expected missing API failures before implementation.
- [ ] Implement the immutable capture/receipt types and non-suspending actor commit. Use the existing bounded batch logic and quotas; a partial recovery failure never invokes the session writer.
- [ ] Inject a throwing session writer and assert no receipt, while already-written recovery remains loadable. Inject a pre-publication store failure and verify old Session.json bytes remain unchanged. Treat `committedButNotSynced` as publication uncertainty, never as a durable success receipt; reload/validate before a subsequent retry.
- [ ] Assert successful receipt generation/revisions and reload both real stores. Keep original user-file fixture bytes unchanged.
- [ ] Review and make a scoped local commit only after the root integration handoff permits it.

## Task 2: Coherent capture and one scheduler

**Files:** create `Sources/TheOnlyPad/SessionCheckpointCoordinator.swift`; modify `Sources/TheOnlyPad/SessionCoordinator.swift` and the recovery/capture portions of `Sources/TheOnlyPad/EditorWindowController.swift`; create `Tests/NativeIntegration/SessionCheckpointHarness.swift`.

- [ ] Inject a suspended commit closure. Request generations 1 through 100 while generation 1 is blocked. Assert one active capture plus one scalar pending generation, and exactly one fresh capture after release, rather than 100 retained text arrays.
- [ ] Assert startup-gated requests do not capture or save until restoration completes; a corrupt/future metadata preservation error prevents publication and produces a persistent status.
- [ ] Add synchronous paired capture and synchronous unresolved/history merge. Do not use an `await` between the window metadata and text captures. Extract a throwing removal drain from the current persist operation so a completed removal cannot reappear in the next merged payload.
- [ ] Implement the state machine: stopped until startup, idle, debouncing, writing, paused, failure. Debounce ordinary events at 750 ms; a 15-second maximum interval requests a checkpoint during continuous editing. Failure retries on explicit Retry or a new changed generation, with a minimum 15-second delay; an idle failure must not spin.
- [ ] Replace production per-window periodic recovery scheduling with the shared app checkpoint route when installed. Preserve a standalone fallback for existing isolated controller harnesses. Do not run both producers in the app. Coalesce fallback recovery captures too if the shared route cannot completely replace them.
- [ ] Retain exact-text/position capture tests for emoji, mixed line endings, marked-text intermediate state and bookmark changes. State the snapshot interval policy; do not claim a physical IME was tested.
- [ ] Run targeted harnesses and inspect allocation behavior: no background closure may retain NSTextView or mutable NSTextStorage.

## Task 3: App events, close and quit ordering

**Files:** modify `Sources/TheOnlyPad/AppDelegate.swift`, `Sources/TheOnlyPad/EditorWindowController.swift`, `Sources/TheOnlyPad/SessionCoordinator.swift`; extend `SessionCheckpointHarness.swift` and `SessionWindowHarness.swift`.

- [ ] Route successful open/save/reload, actual text changes, tab creation/close/order/pin/selection, window membership, bookmark/language/selection changes, recent history changes and unresolved repair/removal through a lightweight callback. Notifications only mark a generation; they do not inspect full text.
- [ ] Test close before recovery admission: tombstone rejects old capture; the next capture omits the tab. Test close while a commit runs: the actor finishes that admitted generation, then applies cleanup; an immediate pending checkpoint publishes post-close membership. Never reuse that closed document UUID for a newly created tab.
- [ ] Test cleanup failure: retain actionable error and no false post-close acknowledgement. Keep failed recovery cleanup pending for retry, including when its originating window closes.
- [ ] At quit, set the app's existing preparingQuit guard, pause/drain checkpoint scheduling, then prepare/freeze editors and drain pending close/removal operations. Capture once after these barriers; invoke the same writer for the final recovery/session commit. No periodic session writer may run after it.
- [ ] At each existing quit veto branch, restore editor/panel state and resume with a fresh requested generation, even if no later user edit occurs. Test veto after blocked background save, file-operation veto, recovery failure, session failure and uncertain session publication.
- [ ] Test a history Remove/Clear during quit remains rejected; a history change before quit enters the final captured payload.
- [ ] Show persistent nonmodal checkpoint failure status with a Retry action, and clear it only after acknowledged success. Existing quit failure can still veto with its explicit dialog; caret movement must not create repeated modal alerts.

## Task 4: Crash and performance evidence

**Files:** add a scoped checkpoint case to `Tests/DesktopUI/GUIProbe.swift` and a standalone synthetic checkpoint/crash harness; update `scripts/test-native-integration.sh`, `docs/verification/periodic-session-checkpoints.md`, and the requirements matrix after evidence exists.

- [ ] Run the complete core and native suites with `scripts/swift.sh test` and `scripts/test-native-integration.sh` in the coordinated build/GUI slots. The new harness entries are added before claiming these commands cover checkpoints.
- [ ] In isolated application state, await an observable acknowledged checkpoint, then terminate only the owned synthetic process without normal quit. Relaunch and assert exact acknowledged text, order, pin, selected tab and recent history when no later edits occurred. This is the narrow exact-restoration claim supported by the existing storage layout.
- [ ] Separately interrupt between recovery publication and metadata publication. Assert newest available content is retained and any stale/missing metadata is preserved as unresolved or validated on restore; do not assert a cross-file atomic snapshot.
- [ ] Measure 10 MB and 100 MB synthetic documents: main-actor capture latency, in-flight retained snapshot count, serialization latency and continued edit responsiveness. Record actual values and reject unbounded queued captures. Keep acknowledged-text comparisons off the per-keystroke path.
- [ ] Review the implemented state machine against every interleaving above. Mark planned/implemented/tested/blocked independently; keep A-06 partial if packaged crash evidence or bounded capture evidence is missing.

## Explicit design boundary requiring a separate plan

A product guarantee that an acknowledged close/discard can never reappear after an immediate crash, or that metadata always identifies an exact immutable recovery generation, requires persistent tombstones or a versioned checkpoint manifest with retained recovery generations and garbage collection. The current mutable UUID files cannot supply that guarantee through actor ordering alone. Do not broaden this subsystem into that storage migration without writing and reviewing its crash protocol first.
