# Search Admission Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans task by task. Use genuine behavioral red/green for new behavior and independent review of each deliverable. BUILD_PROMPT waives repeated human plan/implementation approval; root owns execution scheduling and commits.

**Goal:** Implement policy-injected, process-wide search admission and retained-result ownership with truthful nonterminal driver settlement.

**Architecture:** Add a bounded handle-fenced settlement query to the existing driver/lifecycle. Build a MainActor, view-free generic owner in SearchExecution that queues metadata, reserves before capture, owns preparation/driver cancellation to actual settlement and publishes opaque result leases. Production assembly, measured defaults and native activation remain outside this slice.

**Tech Stack:** SwiftPM, Swift 6 in Swift 5 language mode, macOS 14, Foundation, existing PadCore/SearchExecution. No dependency or wire change.

**Spec:** [Policy-injected search admission](../specs/2026-10-05-search-admission.md). Read that document and the allocation/supervised-search constraints before implementation.

## Global constraints and file ownership

- Eight outstanding logical jobs process-wide; one per consumer; one driver request. Active/stopping work counts until actual resource settlement.
- No text captured while queued. No policy default or production accumulator adopted. Preserve supported 100,000,000 UTF-16 input/output units and match/capture ceilings.
- Do not add another child owner/reaper, terminal-shutdown availability hack, panel task chain, arbitrary deadline or source-bearing progress stream.
- Production snapshot/context/navigation/replace authority remains native-owned in the later integration. No panel/AppDelegate/Package.swift routing edits in this plan.
- Workers are not alone in the repository; preserve unrelated changes. Tasks 1 and 2 may be independently assigned after interfaces are frozen; Tasks 3 and 4 depend on both. Root exclusively schedules any builds, actual processes and GUI; these tasks use no real helper or windows.
- Task 1 owns `Sources/SearchExecution/SearchParentWireDriverTypes.swift`, `SearchParentWireDriver.swift`, `SearchChildLifecycle.swift`, `SearchChildLifecycleTypes.swift`, existing driver/lifecycle tests and bounded driver harness changes necessary for those tests. It does not refactor launch/reap/channel algorithms.
- Tasks 2–4 own new `Sources/SearchExecution/SearchAdmissionTypes.swift`, `SearchAdmissionLedger.swift`, `SearchAdmissionController.swift`, `Tests/SearchExecutionTests/SearchAdmissionLedgerTests.swift`, `SearchAdmissionControllerTests.swift`, and `SearchAdmissionTestHarness.swift`.
- Root owns public progress/verification records and scoped commits. Each task reports exact edited files, exercised tests, preserved failures and limitations; no unconditional completion from a build.

## Task 1 — Nonterminal settlement observation

**Consumes:** current one-shot driver receipts, source-scope coordinator exit, lifecycle serial control lane and exact child release predicate.

**Produces:**

```swift
package enum SearchParentWireSettlement: Sendable, Equatable {
  case pending
  case settled(admissionClosed: Bool)
}
// SearchParentWireDriving and concrete driver forward to retained state:
func settlement(after handle: SearchParentWireHandle?) async throws
  -> SearchParentWireSettlement
```

- [x] Inventory every protocol declaration/conformance/reference with `rg -n SearchParentWireDriving Sources Tests` and a bounded search in the current candidate/runner directories. Current public source has only the concrete driver conformance. Update newly introduced doubles and exact-source transformations in the new candidate; never alter historical frozen evidence or install a permissive protocol default.
- [x] Add compiling negative behavior tests in existing `SearchParentWireDriverTests`: before-first-submit nil returns settled/open; nil after first admission and foreign/older handles throw staleHandle; active source/upload/expect/read callback returns pending; unconsumed success or failure receipt returns pending; consumed healthy success returns settled/open while same child/idle read remain alive. A minimal provisional implementation returning pending provides a behavioral red rather than merely a missing symbol.
- [x] Add separate held-reap and held-close tests using actual driver plus injected lifecycle collaborators. After cancel returns, readiness remains pending while the source-bearing coordinator, session discard/read, consuming reap, or close acknowledgment is separately held. Let wait return failure before reap to exercise the real distinction. Release the final gate and prove settled/open without another signal/reap/close. Retain exact historical reap assertions separately from the observation's current absence.
- [x] Add the lifecycle internal value and query, on its existing control queue:

```swift
enum SearchChildAdmissionInspection: Sendable, Equatable {
  case unsettled
  case absent(admissionClosed: Bool)
  case healthy(generation: UUID)
}
// Module-internal read-only facade; owner computes without OS calls.
func admissionInspection() async -> SearchChildAdmissionInspection
```

  Healthy requires no lifecycle operation, no shutDown, and an owned child with no stopping/reaped/unconfirmed state. Absent reflects `.absent` and current shutDown. Pending launch or any physical cleanup returns unsettled. Add deterministic controls that query neither invokes system methods nor restarts timers, including shutdown while close is held. Do not reuse `cleanupSnapshot`'s `.stopping` label to describe a healthy idle child.
- [x] Retain only `lastAdmittedHandle` in driver state, assigned at actual submit. Query checks it before/after awaiting inspection, then rechecks local operation/waiter/receipt/bridge/session/lane state. Match a healthy inspection generation to the current healthy session. No session plus absent inspection is settled. Healthy idle reading/available state is allowed only after request payload has left; staged/consuming/retiring state remains pending. A mismatched session generation or local transition returns pending/stale as specified. Do not read codec-thread mutable fields from the actor; rely on its completed callback/phase receipts.
- [x] Test query interleaving with newer submit, healthy idle retirement, byte recycling, begin refusal and terminal shutdown. `settled(true)` requires actual parent/adopted cleanup; pending grace return cannot produce it. Query after close must not create a replacement driver. Assert system signal/poll/launch counters and timer set remain unchanged by inspection. Keep pre-adoption quarantine explicitly outside claim.
- [x] If a held source-scope query needs existing frozen-only instrumentation, extend the exact-token driver tests/transform inventory; do not insert sleep gates or production test switches. Use the existing runner's fixed test-class selection, and preserve its original named tests and mutation controls.
- [x] Run driver runner, lifecycle focused suite and pure runner contracts using the commands below. Review source and behavior; root records/commits only the accepted scope. No concrete helper is launched.

## Task 2 — Bounded descriptors, trusted accounting and ledger

**Consumes:** existing SearchQuery/operation/limits; no driver execution.

**Produces:** spec IDs/descriptor/capture/delivery/failure/accounting/retry types and internal ledger. Declare controller signatures exactly as the spec; do not introduce a native model dependency or an initializer that silently installs test policy.

Use these internal ledger operations (tokens have no caller initializer):

```swift
struct SearchAdmissionCharge: Sendable, Equatable {
  let active: UInt64
  let retained: UInt64
}
struct SearchAdmissionReservation: Hashable { fileprivate let id: UUID }
struct SearchAdmissionLedger {
  init(activeLimit: UInt64, retainedLimit: UInt64, resident: UInt64) throws
  mutating func reserve(_ charge: SearchAdmissionCharge) throws -> SearchAdmissionReservation
  mutating func abandon(_ reservation: SearchAdmissionReservation)
  mutating func retain(_ reservation: SearchAdmissionReservation, as lease: SearchResultLeaseID) throws
  mutating func release(_ lease: SearchResultLeaseID)
}
```

Ledger stores bounded reservations/leases issued through the owner; abandon/release are idempotent for missing IDs. `retain` rejects an absent/consumed reservation, duplicate lease or arithmetic violation without partial mutation. Sum committed leases plus future retained reservations when checking retainedLimit. Resident remains in active ledger throughout this component's lifetime. Add internal read-only numeric snapshot solely for diagnostics/tests; no source-bearing state.

- [ ] Red-test exact-limit admission, limit+1 refusal, UInt64 overflow, resident>limit, retained future reservation pressure, simultaneous old lease/new reservation, and refusal leaving every numeric value unchanged. Use tiny explicit policies; never allocate a maximum document to test arithmetic.
- [ ] Red-test reserve→retain transfers exactly once, release twice, abandonment twice, wrong/foreign token, duplicate lease, and independent consumer ordering. Preserve previous lease charge until its actual release. Example observable contract:

```swift
let old = try ledger.reserve(.init(active: 8, retained: 6))
try ledger.retain(old, as: oldLease)
let before = ledger.snapshot
XCTAssertThrowsError(try ledger.reserve(.init(active: 8, retained: 6)))
XCTAssertEqual(ledger.snapshot, before) // retainedLimit is 10
```

  The test helper issues oldLease through an internal fixture accessor available only to tests; production callers cannot forge IDs.
- [ ] Implement checked integer transitions and descriptor validation. Bound query/template to wire limits, reject negative/oversized estimate and unsafe scope arithmetic before invoking capture. Keep existing typed semantic errors where appropriate; replace arbitrary capture Error with compact captureRefused.
- [ ] Run ledger focused tests and review invariants. This task does not prove String capacities, selected budget eligibility or any engine execution.

## Task 3 — Metadata queue, lazy capture and cancellation-owned execution

**Consumes:** Task 1 driver protocol and Task 2 types/ledger; injected `SearchAdmissionRetryScheduler`.

**Produces:** MainActor `SearchAdmissionController<Context>` registration/submit/cancel, one retained worker and bounded cleanup reconciliation; queued and running state is internal and inspectable through lightweight test events, not a user-facing source-bearing event stream.

- [ ] Build a deterministic scripted driver with explicit gates for submit return, wait outcome and settlement response. It records exact jobs only while the scripted driver actually owns them, then clears them; a separate trace stores IDs/counts only. Supply a manual retry scheduler with one pending action/token and explicit fire/cancel observations. No fake that automatically marks settlement on cancel.
- [ ] Red-test eight total outstanding including active/stopping, ninth refusal with capture count zero, one job per consumer, FIFO, unregister queued source deallocation, and one retry/query maximum when settlement is pending. Retained results alone do not occupy job capacity. Reentrant capture cancel/unregister/new submit must not double-reserve, double-capture or submit stale content.
- [ ] Implement synchronous admission and weak-callback contract. Before capture, query last-handle settlement; reserve active+future retained while old lease remains. Set capturing state first. Return through a helper scope before abandoning a rejected capture's credit.
- [ ] Add one retained preparation task validating actual text length off-main via bounded prefix. Use a test-only injected preparation gate through the frozen-test mechanism if necessary; alternatively a narrow internal preparation collaborator returning verified size is acceptable only if the real bounded-count implementation is separately tested and always used by production initializer. Test estimate growth and mismatched capture count; old lease remains unchanged. Test cancellation while preparation is held retains its credit and job slot until scope acknowledgment.
- [ ] On successful preparation, return to MainActor and recheck exact job/consumer/reservation. Keep context exclusively on MainActor. Commit old-lease retirement only after driver submit returns its owned handle and the same job is still current; a busy/refused submit preserves the old result. Store that handle before any reentrant callback. Keep one driver submit/wait task with explicit capture/job/helper scopes. Owner cancellation never cancels its sole wait observer. If cancel precedes handle receipt, store intent and cancel that exact handle immediately when it arrives. Repeated cancellation shares one task; stale cancellation cannot affect successor.
- [ ] Red-test cancellation during capture, preparation, suspended submit, wait, post-wait/pre-settlement and delivery. In each held state assert capacity remains occupied and a same-consumer restart refuses; release the exact gate and require eventual single completion or fenced discard. Query failure/staleHandle is fail-closed, retains unresolved ownership and emits compact internal failure; do not free credits speculatively or enter a busy retry loop.
- [ ] Compact driver/semantic failure after consumption is staged without retaining source in closures or completed tasks. Clear external outcome scopes before releasing active credit. For `.settled(false)` continue FIFO; `.settled(true)` prohibits new admission. Pending cleanup uses one metadata-only scheduled retry, never a new driver. Successful source/output waits under active ownership for actual settlement before lease publication.
- [ ] Test weak sentinel release for queued capture owner, preparation scope, worker/outcome holder and completion closure. Tests must distinguish 'counter says released' from actual retaining scope exit. Add root-approved frozen gates only where existing public interfaces cannot expose the timing safely.
- [ ] Run focused controller plus ledger tests, then Task 1 regressions. Independently review cancellation/reentrancy and ownership before root commit.

## Task 4 — Result leases, reentrant borrows and terminal shutdown

**Consumes:** controller execution state and ledger.

**Produces:** `withResult`, release/unregister integration, completion delivery, and idempotent bounded shutdown. No quit-veto resume/factory API.

- [ ] Red-test completed output becomes one exact lease after settlement, publication only after credit transfer, failure retains no result, and refusal preserves old result identity/data/charge. Completion reentrancy may immediately release, cancel or unregister without double-release.
- [ ] Implement per-lease validity, borrow depth and deferred destruction. `withResult` synchronously lends context/source/output and returns false for invalid/foreign lease. release invalidates immediately; retain payload and ledger entry until the last borrow returns. Local borrow scope must exit before final destruction acknowledgment. Do not hand raw outcomes through completion.
- [ ] Red-test release/unregister/new admission inside a nested borrow: second access fails immediately, weak payload owner and charge remain during the outer callback, then leave together. Include another consumer's valid lease and wrong-ID release. Retained budget must account for an invalidated borrowed old result while a replacement is captured; refuse rather than undercharge.
- [ ] Add shutdown tests with queued job, held preparation, held submit, post-terminal retained lease, nested borrow, held reap and held channel/read lane. Admission closes and callbacks fence before first await; only one driver shutdown command occurs. Repeated calls return/inspect the same bounded command state without resetting grace. Snapshot pending counts remain nonzero while held resources exist; eventual cleanup can be inspected without reactivating admission.
- [ ] Verify a durable-quit-veto simulation cannot submit or install a fresh driver through this API, and late prior callbacks cannot revive a result. This is a no-resurrection component control, not completed native veto UX. Keep launcher quarantine limitation in API documentation.
- [ ] Run all new tests against the uninstrumented component and the actual-driver suite against the same source set. Run broad integrated tests only under root's accepted watchdog and serialize with other builds. Independent review must specifically audit source/callback aliases, token fencing, idle resident charge, unknown accounting limits and absence of route activation.

## Commands and evidence

The following existing coordinators own their watchdog directly; never wrap them:

```sh
scripts/test-search-parent-driver.sh
scripts/test-search-child-lifecycle.sh --filter SearchChildLifecycleTests
python3 -m unittest discover -s Tests/SearchParentDriverIntegration -p 'test_*.py'
python3 -m unittest discover -s Tests/SearchChildIntegration -p 'test_*.py'
```

New focused test filters are proposed, not yet proven commands. Run only after the files exist, under root's runtime/build ownership. Use an exclusive unused output directory per invocation; retain behavioral RED, GREEN and mutations separately. Freeze matching sources before running if other agents edit shared inputs. Example direct-watchdog command (do not wrap a coordinator):

```sh
python3 scripts/run-owned-search-tests.py --timeout 180 --output .local/search-admission/green-ledger -- scripts/swift.sh test --scratch-path .build/search-admission --filter SearchAdmissionLedgerTests
python3 scripts/run-owned-search-tests.py --timeout 180 --output .local/search-admission/green-controller -- scripts/swift.sh test --scratch-path .build/search-admission --filter SearchAdmissionControllerTests
```

Adjust finite build timeout only with a recorded reason, never reinterpret watchdog termination as passing. Run strict formatting on changed Swift files, `python3 scripts/check-public.py`, and `git diff --check`; review exact test counts, no skips/warnings, source inventories and full owned-process receipts before completion claims. Full integrated app/core verification and public evidence update are root-owned follow-through, not a reason to activate unavailable helper routes.

## Completion boundary and integration handoff

This component is complete only when all four task behaviors and neighboring driver/lifecycle regressions pass on exact recorded inputs and independent review has no material unresolved findings. Planned / implemented / tested / blocked remain separate. No real helper, native panel, selected accumulator, maximum-size budget, memory bound, production retry interval, package or desktop claim follows.

Later application integration retains one instance per process and supplies native weak context/capture, measured policy, concrete retry scheduler and fixed production driver factory. It must implement native authority revalidation, folder batch scheduling/reader ownership, packaged helper routing and safe quit-veto recovery before activation. Those applicable requirements remain outstanding and must not be relabeled optional.
