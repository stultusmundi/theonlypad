# External File Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Routine approvals are waived by BUILD_PROMPT; independent review and evidence remain required.

**Goal:** Implement A-07/A-08 proactive external-file status and explicit safe reload/locate actions without weakening atomic-save or recovery guarantees.

**Architecture:** A bounded Foundation probe produces immutable disk observations. One process service owns cancellable vnode registrations and off-main checks for logical documents; native document state accepts versioned results and presents document-bound actions independently of pane focus.

**Tech Stack:** Existing Swift/AppKit, Foundation/Darwin, DispatchSource, XCTest; current macOS 14 floor and Swift language mode retained. No new package dependency.

**Spec:** [external-file-monitoring.md](../specs/external-file-monitoring.md).

**Status:** Tasks1/2/3 production components are implemented and tested (full328 core tests). Task4 native ownership/status and Task5 checked reload/copy have hidden AppKit integration evidence; explicit Locate and full desktop acceptance remain outstanding. The original detailed checklists below are retained as acceptance obligations; their unchecked entries must not be interpreted as evidence of absence or completion. Current implementation/test records are in [component and native evidence](../../verification/external-file-monitoring.md) and the action execution plan.

## Global constraints

- No automatic original-file autosave, dirty/pending reload, force overwrite, permission changes or silent symlink following.
- Monitoring observations never authorize a save or modify originalBytes, savedText, pendingPublication or recovery ownership.
- One registration per EditorDocument, zero additional registrations for panes. Monitor only original URL; distinct pending Save As destination remains subject to existing explicit retry verification.
- Preserve exact Unicode/encoding/BOM/endings and all existing save uncertainty tests. Plain read-only disk state does not prohibit editing a buffer.
- 128 registrations, two workers, 64 KiB read chunks, 100,000,000-byte content cap, 250 ms debounce with two-second maximum deferral, 30-second reconciliation. Cancellation/deadlines are cooperative, not a promise to interrupt blocked filesystem syscalls.
- Descriptor budget is 268 explicitly monitor-owned FDs: 256 reserved watch leases plus six transient slots per each of two workers. It includes prepared/revalidation/cancellation-in-flight leases; no system-wide FD bound is claimed. Local regular-file policy and unsupported states must be explicit.
- Only synthetic fixtures; logs/screenshots private and ignored. No remote actions or benchmark execution without the coordinated slot.
- Source-only test scaffolding/compile failures are not behavioral red. Establish a compiling seam, then record a failing behavior assertion before each change; record first-run passes as compatibility evidence.

## Files and ownership boundaries

| Owner | Files | Responsibility |
| --- | --- | --- |
| Foundation worker | New Sources/PadCore/ExternalFileProbe.swift, ExternalFileState.swift; Tests/PadCoreTests/ExternalFileProbeTests.swift, ExternalFileStateTests.swift | Stable bounded observation/read, pure result/action admission types. No AppKit, watch threads or writes. |
| Watcher worker | New Sources/TheOnlyPad/FileMonitorService.swift; Tests/NativeIntegration/FileMonitorHarness.swift | Descriptor/event/queue lifetime, bounded work, epoch invalidation and cancellation. No document mutations. |
| Root integration owner | EditorDocument.swift, EditorWindowController.swift, AppDelegate.swift; new DocumentFileStateController.swift; Sources/PadCore/AppCommands.swift | One logical registration, nonmodal status/actions, save/reload/close/quit integration, command routing. |
| Verification owner | New Tests/NativeIntegration/ExternalFileLifecycleHarness.swift; Tests/DesktopUI/ExternalFilesTests.swift; scripts/test-native-integration.sh and DesktopUI project inclusion | Meaningful real-file lifecycle and later packaged desktop tests. Coordinate with root before editing shared script/project. |

Do not concurrently assign different workers EditorWindowController or the shared script. Every worker is not alone and must preserve unrelated changes. Start in an ignored isolated package/copy; copy green source only during a root-approved compile gap. New docs/verification/external-file-monitoring.md is created by the implementation owner after actual execution, not pre-filled with claimed results.

## Task 1: Bounded stable file observations

**Interfaces:** Define the following public PadCore contract; all values are Sendable. `FileTargetIdentity` contains parentDevice/parentInode/fileDevice/fileInode UInt64. `FileMetadata` contains identity, byteCount:Int64, mode:UInt32, flags:UInt32, modificationSeconds/nanoseconds and changeSeconds/nanoseconds:Int64. Store permission/access advice separately from content relation.

```swift
public enum DiskContentRelation: Sendable, Equatable {
  case matchesBaseline, differsFromBaseline, unavailable
}
public enum DiskLocationProblem: Sendable, Equatable {
  case missing, inaccessible, symbolicLink, nonregular, parentChanged
  case changedDuringRead, unsupportedVolume, tooLarge, checkDelayed
}
public struct DiskObservation: Sendable {
  public let metadata: FileMetadata?
  public let content: DiskContentRelation
  public let locationProblem: DiskLocationProblem?
  public let readOnlyHint: Bool
  public let movedCandidate: URL?
}
public struct DiskRead: Sendable {
  public let bytes: Data
  public let observation: DiskObservation
}
public struct ExternalFileProbe: Sendable {
  public init()
  public func observe(_ url: URL, expected: Data,
    boundIdentity: FileTargetIdentity?, forceContents: Bool,
    previous: DiskObservation?, isCancelled: @Sendable () -> Bool) throws -> DiskObservation
  public func read(_ url: URL, matching: DiskObservation,
    isCancelled: @Sendable () -> Bool) throws -> DiskRead
}
```

`forceContents=false` permits metadata fast-path reuse only for a previous fully accepted observation with identical bound target/path metadata. Unavailable/missing/error states never become matches through that fast path. Initial binding is always a forced comparison. `read` checks the currently offered observation, bounds content, and returns exact bytes plus fresh matching identity; it throws if the target moved/changed during admission. No successful read of an unavailable observation. Errors distinguish cancellation and unsafe/mutating targets without embedding private paths in diagnostics.

- [ ] **Step 1:** Add compile-only models/probe seam and a test fixture helper creating one private temporary directory per test. Cleanup only its own directory. No success claim from compiling the interface.
- [ ] **Step 2:** Record behavioral red for real same-size external replacement against saved baseline, and preservation of file bytes by observation:

```swift
func testExternalReplacementDoesNotBecomeBaseline() throws {
  let file = directory.appendingPathComponent("document.txt")
  let saved = Data("alpha\r\n".utf8)
  try saved.write(to: file)
  let first = try probe.observe(file, expected: saved, boundIdentity: nil,
    forceContents: true, previous: nil, isCancelled: { false })
  try Data("omega\r\n".utf8).write(to: file, options: .atomic)
  let changed = try probe.observe(file, expected: saved,
    boundIdentity: first.metadata?.identity, forceContents: true,
    previous: first, isCancelled: { false })
  XCTAssertEqual(changed.content, .differsFromBaseline)
  XCTAssertEqual(try Data(contentsOf: file), Data("omega\r\n".utf8))
}
```

- [ ] **Step 3:** Implement canonical-parent/openat/no-follow regular-file validation and exact chunk comparison. Metadata observation of a replacement inode is allowed when parent binding still holds; do not require the old file inode for ordinary change detection. Preserve the old retained inode only for move hints. Revalidate path/descriptor/parent after reads; cancelled/short/error reads cannot return matches. Use internal injected read/stat/clock boundaries for deterministic EINTR, partial read, cancellation and race tests; production defaults perform real syscalls.
- [ ] **Step 4:** Add real-file tests: unchanged, in-place changed, same-byte inode replacement, restored mtime with changed bytes under forced check, missing versus EACCES, chmod without byte change, FIFO, final symlink, stable parent symlink versus retarget, parent rename/recreation, exact legacy/BOM/control/combining bytes. Assert no data writes or permission changes. Invalid local URL/path length and unsupported volume must produce explicit refusal. Use injected errors where the executing user's privileges make a real permission scenario unreliable; label them separately.
- [ ] **Step 5:** Verify 100 MB limit without large committed fixtures; generated sparse/streamed oversized file refused before allocation. Small-chunk test seams prove matching data across boundaries and partial read/EINTR handling. Assert cancellation during comparison, source changing after last chunk and before path check, and cleanup of all probe FDs on every failure.
- [ ] **Step 6:** Run the owned Foundation filter in isolation, review exact tests/results, then request an integration gap. Existing save code remains unchanged.

Planned command using the existing wrapper: `scripts/swift.sh test --scratch-path .build/external-files --filter ExternalFileProbeTests`. This command is a future test invocation, not executed evidence in this draft.

## Task 2: Pure document disk-state reducer

**Files:** ExternalFileState.swift/tests. **Consumes:** DiskObservation. **Produces:** immutable `FileObservationToken(documentID:UUID, epoch:UInt64, baselineRevision:UInt64, sequence:UInt64)`, `ObservedFileState`, and action admission decisions. `ObservedFileState` retains disk facets, dismissed observation sequence and whether pending publication exists; document dirty disposition stays owned by EditorDocument.

```swift
public enum FileConflictAction: Sendable {
  case reload, openDiskCopy, keepBuffer, saveAs, locate, checkAgain
}
public enum FileActionAdmission: Equatable, Sendable {
  case allowed, requiresDiscardConfirmation, refused
}
// Intended pure entry points on ObservedFileState:
// mutating accept(_:token:currentToken:) -> Bool
// admission(for:dirty:pendingPublication:busy:composing:quitting:) -> FileActionAdmission
// mutating dismiss(token:)
```

- [ ] Write red tests for accepting a result from an old URL epoch, old saved baseline and an older sequence: state must remain unchanged. Matching bytes with pending publication must retain uncertainty. Keep Buffer must retain conflict and saved-byte baseline; changed+read-only must retain both facets.
- [ ] Implement lexicographic admission only within the exact registration epoch/baseline; no wraparound comparison assumptions. Epoch replacement creates a fresh token context; old sequence values cannot reactivate it.
- [ ] Write action-table tests matching every row in the spec. Dirty/pending Reload requires explicit confirmation, no location-error reload, Open Disk Copy cannot create file-write authority, Locate cannot redirect uncertainty. No event action sets clean state.
- [ ] Run `scripts/swift.sh test --scratch-path .build/external-files --filter ExternalFileStateTests`, review, copy only green owned files in an agreed gap.

## Task 3: One bounded native monitor service

**Interface:** `FileMonitorService` owns queue state. Registration request has document UUID, URL, shared baseline Data and baselineRevision. A token offers thread-safe `cancel()` and invalidates callbacks immediately; source cancellation transfers its descriptor lease to worker cleanup; actual close is off the control queue and completes once all borrowers release it. Native consumers receive a Sendable `FileObservationToken` plus DiskObservation, never a pane reference. Injection accepts a Probe closure, event-source factory and monotonic clock for tests.

```swift
// Original planning sketch; consult FileMonitorService.swift for the implemented API.
func register(documentID: UUID, url: URL, baseline: Data, baselineRevision: UInt64,
  receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void)
  throws -> FileMonitorRegistration
func requestCheck(documentID: UUID, forceContents: Bool) // Registered documents only.
func checkOnce(requestID: UUID, documentID: UUID, url: URL, baseline: Data,
  baselineRevision: UInt64,
  receive: @escaping @Sendable (UUID, Result<DiskObservation, FileCheckError>) -> Void)
  -> FileCheckToken
func rebind(documentID: UUID, url: URL, baseline: Data, baselineRevision: UInt64)
func suspendDelivery()
func resumeAndReconcile()
```

`FileCheckError` distinguishes cancellation, manual-capacity refusal and probe failure. `FileCheckToken.cancel()` is thread-safe; every one-shot callback, including cancellation/capacity refusal, completes exactly once with the supplied request UUID. The native owner matches that UUID plus its captured document/URL/baseline context before accepting. Up to 16 manual queued/running requests share the two-worker pool and reserve no persistent watch FDs. `register` can synchronously reject capacity/invalid in-memory inputs, but path/volume/open validation is asynchronous; setup failure is delivered explicitly rather than blocking the caller.

- [ ] Write first behavioral red: real atomic replacement must trigger a changed observation, then a second replacement must still be detected after rearming. Wait for semantic results with an external watchdog, not exact native event counts. Assert splitting is not involved in service API.
- [ ] Implement in-memory control-queue source configuration/rearm with file+parent descriptors prepared on workers. ALL resolution (including resolvingSymlinksInPath), volume, access, open/stat/read/F_GETPATH/revalidation and close work stays off the control queue and MainActor. Probe descriptor used to initialize watch identity must be revalidated; descriptor registration cannot silently bind a later file whose bytes were never checked. Resume every newly created source exactly once. Cancel handler transfers its FD lease to worker cleanup, enqueued only when its in-memory borrower count is zero (never block a worker waiting for borrowers), before exactly-once close; callbacks use weak service/token and immutable epoch. A weak token cannot be resurrected by an event.
- [ ] Implement two-worker dispatcher, one queued bit per registration, fair scheduling, 250 ms debounce/two-second max and 30-second exact-byte reconciliation (metadata-only reuse was rejected during tests). Manual/activation/file hints force bytes. At capacity or registration failure, emit explicit unavailable state and maintain manual check access. Never spin retry on a failed source or blocked probe.
- [ ] Test using a gated probe: 100 events produce at most one running and one queued reconciliation, a new epoch rejects both old completions, different documents are not starved, the two-worker limit holds, suspend/resume does not emit during quit, cancelled registrations produce no callback, repeated rebind waits/accounting keep descriptor count bounded including pending cancellation.
- [ ] Add exact descriptor reservations: at most 256 watch leases covering pending preparation, installation, retirement and cancellation; six transient slots per worker for primary parent/file, revalidation parent/file, candidate parent/file. Volume checks reuse FDs. Reserve before open, release only after close, no uncounted dup. If preparation lacks slots, defer it and expose delayed monitoring. Assert live plus reserved counts during failed setup, rebind storms, cancellation and deliberately stalled cleanup; max 268 monitor-owned descriptors, not a process-wide claim.
- [ ] Gate path resolution, volume lookup and open in separate tests while both worker slots are occupied. Cancellation and in-memory epoch invalidation on the control queue must still complete without waiting; new work stays bounded, no substitute worker is spawned, and stale results cannot deliver. Cleanup has priority once a worker becomes free; do not claim a hard deadline for the blocked syscall.
- [ ] Register 128 synthetic document identities, request `checkOnce` for a 129th URL and verify exact changed observation without another source. Repeat after an injected watcher-open failure. Queue 16 one-shots, reject the next explicitly; cancel queued/running requests and assert one completion each and no stale native adoption. All use synthetic files or gated probe seams, no real-state exhaustion.
- [ ] Test rename candidate from F_GETPATH against a real renamed open FD, then replacement/symlink at that candidate. Only stable same-inode candidate offered; missing/deleted/ambiguous returns Locate UX state. Candidate does not change requested URL. Do not infer destination from basename heuristics.
- [ ] Add retained FileMonitorHarness entry to existing native script only through root. Script must give each real-file process a bounded external watchdog and isolated state. Run focused modes then existing lifetime harness; retain source/results before copying integration.

## Task 4: Native document state, save lifecycle and status

**Root-owned files:** EditorDocument, controller, AppDelegate, new DocumentFileStateController, AppCommands. No worker independently edits these in parallel with pane integration.

`DocumentFileStateController` is MainActor, owned by EditorDocument, stores registration token/current token/observation and weak UI notification closure. It takes baseline bytes/revision and logical URL; it does not own EditorPane. Start after successful initial open, session file restoration and acknowledged reload/save. Recovered scratch has no original URL/watch even if historical metadata carries a path.

- [ ] First red native harness: open one synthetic file, split twice/change axes, mutate disk externally, assert exactly one registration/result state and unchanged shared text, baseline, undo and pending-publication metadata. Status row exposes the applicable action rather than a modal event alert.
- [ ] Add one logical registration on successful file adoption. Opening same file as distinct documents/windows may have independent logical registrations; do not collapse their dirty ownership. Close stops registration once; closed-tab snapshots do not keep monitors alive. Reopened/restored documents use new registration epochs.
- [ ] Wire nonmodal status with the spec IDs. Compose read-only/missing/content facets; don't replace checkpoint failure status. New registry commands resolve captured logical document and do not change the command focus model. Document toolbar commands use the same admission decisions as menus/palette.
- [ ] On save start defer result presentation; on success retain the existing exact save completion ordering, then rebind baseline/URL. On failure preserve monitoring baseline; uncertain evidence remains independently dirty. A forced post-save observation detects subsequent external changes. No timing-based “ignore own writes” interval.
- [ ] Test uncertain own publication observed on disk: no clean receipt, pending Save As URL remains unadopted, recovery remains included. Test normal successful save followed by external replacement before watcher rebind; replacement must not become baseline. Keep Buffer then Save must still be refused by AtomicFileStore expected bytes.
- [ ] Suspend delivery before quit capture; do not wait on probes. Cancelled quit resumes forced reconciliation. Late callbacks after close must not touch UI, recovery or documents. Assert no extra checkpoint for repeated identical observation/status redraw; filesystem observation is not a buffer edit.

## Task 5: Safe explicit reload, disk-copy and Locate transactions

**Interface:** New native `DocumentFileActionContext` captures documentID, FileObservationToken, URL, editRevision, baselineRevision, encoding/BOM, pending-publication identity and pane selections keyed by UUID. Helpers receive that immutable context; they never resolve current.editor after await.

- [ ] Add red regression: click Reload for document A, switch to B while read is gated, release; A's admitted logical transaction either completes in A without stealing B focus or explicitly rejects according to lifecycle state, never replaces B. Dirty/pending confirmation uses Cancel default. A composition or active macro recording in A refuses reload admission before read/selection mutation. Invoke the actual external reload callback while recording and assert no read, storage replacement, baseline/undo change, or recorded edit; the current reload-recording refusal remains visible.
- [ ] Integrate a safe read/decode stage using ExternalFileProbe.read and a BOM-first external decoder: recognize/reject unsupported UTF-32 markers first; supported UTF-8/UTF-16 LE/BE BOMs call DocumentCodec.decode with no explicit encoding, while BOM-less bytes pass savedEncoding. Do not alter explicit Reopen with Encoding semantics. Add LE-BOM→BE-BOM and Windows-1252→UTF-8-BOM regressions for both reload and disk copy, asserting exact decoded text/encoding/BOM and byte roundtrip; include BOM-less legacy fallback and unsupported-prefix refusal. Freeze all A panes after transaction admission and keep original buffer/baseline untouched until every required read/decode/confirmation/revalidation succeeds. Recheck closed/quit/membership/context and the existing macro-recording veto after each await and modal return. Unchanged native undo setter semantics are not used as a substitute for completion admission.
- [ ] Test bytes changing during confirmation: fresh read/revalidation refuses, original dirty buffer/undo/pending evidence retained, all live panes become editable. Test decode failure, missing file, too-large target, revoked access and observation-epoch replacement with the same guarantees.
- [ ] Successful explicit reload updates exactly one storage/baseline, clears undo/bookmarks/pending metadata as existing semantics require, preserves attached pane IDs/axis, clamps each selection with existing scalar-safe validation, preserves current focus and triggers one logical language/recovery update. Test mixed CRLF/CR/LF, emoji boundaries, UTF16 BOM and Windows-1252.
- [ ] Open Disk Version creates a new scratch document, has no original URL/write authority, and preserves the source and disk byte-for-byte. Test A dirty+uncertain and invalid decode; failure creates no empty placeholder document.
- [ ] Locate chooses a file through the native picker; verify regular target and exact baseline before allowing explicit URL-only rebind. Same bytes preserve dirty buffer/undo/settings and emit one MRU/session change. Different bytes cannot silently bind; offer disk copy or explicit reload. Pending publication cannot be redirected. Retarget candidate after picker but before validation must fail safely.
- [ ] Retain actual callback harnesses for each action and teardown; use injected chooser/read barriers instead of fake dialog acceptance. Existing `reload`/open callbacks still complete exactly once. Do not let a display refusal select an unrelated current document for reload.

## Task 6: Independent review and integrated evidence

- [ ] Independent reviewer inspects scope, original-byte authority, final-symlink/parent identity, cancellation FD ownership, no unbounded retry, weak lifetime, explicit action context, dirty/pending conflict UX and test quality. Fix material findings with genuine red–green regressions.
- [ ] Run all owned Foundation tests, then `scripts/test-native-integration.sh` in the coordinated native slot with authorized host access. Required compatibility: SaveFailure, DirtyState, Recovery, WindowCheckpoint, SessionCapture, Launch, shared-pane ownership/routing/highlighting/visible tests, and native lifetime. Report exact executed commands/counts, not forecasts.
- [ ] Add packaged DesktopUI tests only after source integration: external writer changes clean and dirty synthetic file, nonmodal notice observed, explicit clean reload, dirty Cancel retains text, disk-copy preserves source, rename Locate, permission error, and quit/relaunch preservation. Reuse private GUIProbe fixtures and actual selectors; no authentication/security-setting changes. If automation remains unavailable, retain tests as unexecuted and keep desktop acceptance outstanding.
- [ ] Run local packaging/privacy checks through existing scripts only after core/native green; inspect resulting bytes/hash. Publishing remains separately unauthorized. Record monitor load/latency measurements later under an exclusive slot; neither synthetic event tests nor this draft establishes a two-second real-filesystem SLA.
- [ ] Write factual verification record with planned/implemented/tested/blocked states and reviewed limitations. Only root updates A-07/A-08 matrix entries after accepted evidence; no feature-complete claim from compilation alone.

## Self-review checklist and deferred work

- [ ] Every A-07/A-08 condition maps to a state, action and real-file/injected test above.
- [ ] Monitor cannot change save authority; no observed bytes replace expected bytes outside acknowledged load/save or explicit reload/Locate adoption.
- [ ] Partial read, data size, unsupported volume and blocked syscall limits are disclosed.
- [ ] Fresh epoch/lifetime admission protects every UI completion; two panes share one logical monitor.
- [ ] No private path/document logs, recursive rename search, third-party dependency, remote operation or permission prompt is introduced.

Deferred: automatic clean reload preference, overwrite-on-conflict, three-way merge, inode-following automatic rename adoption, network/cloud coordination, full recursive filesystem inventory and a process-isolated hard I/O deadline. These are not hidden substitutes for the specified safe explicit actions.

## Review response and remaining status

All five independent design findings are addressed in the spec and Tasks 3/5: BOM precedence, one-shot manual API, macro-recording reload veto, explicit 268-FD reservation budget, and worker-only filesystem operations with gated-stall tests. This is a documentation revision, not runtime validation or implementation. The new tests, capacity limits and queue guarantees still require independent implementation review and actual execution; no code, matrix, continuation or acceptance state changed.

## Integration notes after component review

Full-token dismissal supersedes the original sequence-only proposal; stale epoch/baseline regressions passed after the correction. The service must expose a bounded thread-safe live latest-issued token snapshot (including cancellation), because result admission must not compare a captured token to itself. Issue a sequence when a probe starts; queued coalescing alone need not invalidate the current issued result. Metadata-only observation reuse is currently disabled after a false-clean regression; any later cache needs reviewed immutable baseline provenance and explicit tests.


### Decoder component checkpoint

The standalone `ExternalDocumentDecoder` portion of Task 5 is implemented and independently reviewed. Genuine forwarding-seam red preceded implementation; five new tests cover supported-BOM precedence, exact round trips, saved BOM-less fallback, unsupported/ambiguous UTF-32 prefixes, malformed marked Unicode and unchanged explicit codec interpretation. Full production core session 48984 passed 263 tests. Native reload/disk-copy wiring and associated lifecycle/desktop tests remain unchecked above. See the native integration map and external-file-monitoring verification record.
