# Policy-injected search admission and result ownership

Status: root independently reviewed the worker-authored design and execution plan on2026-10-05; Task1 implementation authorized. No implementation or new runtime evidence is claimed by this design. This is an architectural component of the [supervised-search design](2026-09-10-supervised-search.md). The BUILD_PROMPT authorizes routine design decisions and replaces repeated approval ceremony with documented independent review. Production accumulator/default-policy selection remains governed by [allocation Gate A](2026-09-10-search-text-allocation.md).

## Scope and alternatives

Implement a view-free, MainActor admission owner in SearchExecution, consumed by the later application-owned native adapter. It owns metadata scheduling, capture reservations, one driver operation, cancellation, result leases and terminal shutdown. It accepts accounting policy and driver explicitly. It does not construct a helper, choose a budget, modify panels, or activate routes. Native document authority, folder iteration, packaging and quit-veto driver replacement remain integration requirements, not completed features.

| Approach | Assessment |
|---|---|
| Wait for all allocation comparisons before writing ownership code | Unnecessary dependency: deterministic reservation/ownership behavior can be verified with explicit test accounting. Preserve measurements as the production-policy gate. |
| Inject accounting and the existing driver; add a narrow settlement query | Selected. Uses accepted transport/reaper owners and produces independently testable production code without adopting memory defaults. |
| Treat cancel return as settlement, or call shutdown to inspect availability | Rejected. Cancel joins command submission; shutdown is terminal. Neither substitutes for request-scope, parent-lane and physical-child cleanup. |

No dependency, engine, dialect, protocol-v1 or semantic-limit change. Preserve eight outstanding logical jobs process-wide, one outstanding job per consumer, one submitted driver request, and the eventual one folder reader. The 100,000,000 UTF-16 input/output ceilings and existing match/capture limits remain unchanged. This component is a required stage, not completion of search, performance or the application.

## Source-derived settlement boundary

`SearchParentWireDriver.coordinatorExited` clears the operation only after `driveAndStage` returns, including upload producer/consumer completion and the source-bearing scope. `wait` consumes its one receipt. On fatal paths the driver waits for session reader/discard exit, but lifecycle can still retain an unreaped physical child. On healthy paths a bounded idle read/session persists after request metadata, accumulator and boundary index were cleared. That idle state must not force termination before every new request.

Add exactly one package protocol method and result:

```swift
package enum SearchParentWireSettlement: Sendable, Equatable {
  case pending
  case settled(admissionClosed: Bool)
}
// Added to SearchParentWireDriving:
func settlement(after handle: SearchParentWireHandle?) async throws
  -> SearchParentWireSettlement
```

`nil` is valid only before the first driver submission. A nonnil handle must equal the most recently admitted handle, retained as bounded metadata even after wait/discard consumes its receipt. A foreign/older handle throws existing `staleHandle`; no unbounded receipt history. Recheck this fence after any cross-actor/control-lane await. An observation for an older request never releases newer credit.

`pending` applies while any request operation, waiter, unconsumed receipt, upload bridge, request codec scope, retiring session/read/discard scope, pending launch, stopping/unconfirmed child, or incomplete adopted-channel close remains. A healthy idle session may remain: only its bounded read/transport state, no request boundary index, accumulator, provisional output or source. A source-free idle read is not required to return EOF. Busy idle codec consumption is conservatively pending until its callback exits. The retained idle transport allocation is charged separately in injected accounting for the lifetime of the owner.

`settled(false)` means the queried request's internal parent ownership and the relevant adopted lifecycle obligations have settled, and this driver has not shut down. It permits a later admission attempt, not a guarantee that launch succeeds or that idle state cannot change. `settled(true)` has the same settlement requirement after terminal driver shutdown. Driver never returns settled merely because shutdown's bounded grace elapsed.

Implement a module-internal read-only lifecycle inspection on its existing serial control lane. Its value distinguishes `absent`, healthy idle generation, and unsettled, plus lifecycle shutdown state. Healthy requires no lifecycle operation and owned child neither stopping, reaped, nor unconfirmed. Absence follows existing exact consuming reap plus close release, or no-PID launch failure. This inspection performs no signal, waitpid, timer reset, launch or shutdown. Driver checks parent state after inspection, matches healthy lifecycle generation to a healthy current session, and refuses stale handle/session observations. If parent and lifecycle cannot be reconciled, return pending, never guess settled.

Launcher pre-adoption quarantine remains outside this receipt. A no-PID failed setup can be source/adopted-resource settled while its existing launcher permanently refuses a later launch. Keep that launcher; do not construct replacements to escape quarantine. The settlement query is not a process-resource destruction certificate, historic reap receipt, or permission to reset a production factory. A race with later idle retirement can make the next submit fail safely; reservations remain charged until that attempt's actual settlement.

## Frozen component interfaces

New files: `SearchAdmissionTypes.swift` and `SearchAdmissionController.swift` in SearchExecution. Types are package-visible. Native opaque context stays on MainActor and is not inspected by the engine module. The controller is generic over `Context`; actual native context must be lightweight and weakly reference its source model/pane, without a pre-captured String.

```swift
@MainActor package final class SearchAdmissionController<Context> {
  init(driver: any SearchParentWireDriving,
       accounting: any SearchAdmissionAccounting,
       retry: any SearchAdmissionRetryScheduler) throws
  func register() -> SearchConsumerID
  func unregister(_ consumer: SearchConsumerID)
  func submit(consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
              capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
              completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void) throws
    -> SearchJobID
  func cancel(_ job: SearchJobID)
  func release(_ lease: SearchResultLeaseID)
  func withResult(_ lease: SearchResultLeaseID,
                  _ body: (Context, String, SearchExecutionOutput) -> Void) -> Bool
  func shutdown() async -> SearchAdmissionShutdown
}
```

IDs are distinct opaque UUID-backed types, issued only by the controller; no caller initializer. Descriptor carries bounded `SearchQuery`, `SearchExecutionOperation`, estimated input UTF-16 count, optional scope and explicit `SearchWireLimits`. Capture carries immutable text, actual capture-time UTF-16 count and context. IDs/context never become protocol authority. Delivery is `completed(SearchResultLeaseID)` or `failed(SearchAdmissionFailure)`. Failure contains only compact typed admission/capture/driver/semantic errors; never arbitrary Error objects, source text or retained closures. Admission failures include queueFull, consumerBusy, unknownConsumer, invalidDescriptor, resultBudget, captureRefused, sourceChanged, cancelled, shutdown and driver/semantic cases preserving existing typed errors.

`SearchAdmissionAccounting` is a trusted injected package protocol with unsigned active/retained limits, fixed resident transport charge and `charge(for: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge`. Charge contains active and future-retained bytes. The controller initializer throws if resident charge exceeds the active limit; it never silently installs a policy. Validate resident charge fits active limit and use checked UInt64 arithmetic for every addition/subtraction. No zero-cost implicit default, measured-sounding factory or sample production policy is provided. Test accounting is explicitly named test accounting. Its values prove transitions, not physical memory. The later measured policy must cover metadata, source, output, indices, ranges, construction/bridge overlaps and uncertainty according to Gate A. Resident transport remains charged until adopted transport/parent cleanup ends; conservatively retaining that charge for the owner's entire lifetime is allowed.

`SearchAdmissionRetryScheduler` has MainActor `schedule(_ action: @escaping @MainActor () -> Void) -> any SearchAdmissionRetryToken`; token has `cancel()`. This slice supplies injected deterministic scheduler tests, not a production interval/default. At most one scheduled retry and one in-flight settlement query process-wide; callbacks are identity-fenced. Retry owns metadata only. Its purpose is to recheck pending cleanup/idle retirement, not to infer settlement from elapsed time. It does not schedule another capture, reader, launch, driver or cancellation task. Actual integration must supply a nonspinning, low-rate monotonic implementation.

`SearchAdmissionShutdown` contains the existing driver shutdown snapshot plus counts of retained active jobs and leases. It reports pending ownership honestly; it contains no source data. It does not decide durable-document quit.

## Admission and ownership rules

1. Register stores no native object. Submit validates bounded descriptor, registered consumer, capacity eight including active/stopping jobs, and consumer vacancy before retaining callbacks. Outstanding means queued, capturing, preparing, submitted or stopping; a completed retained lease alone is not an outstanding job. Only bounded metadata and weak-source capture/completion closures may be queued. There is no latest-request replacement chain.
2. FIFO schedules document jobs. The later folder batch adapter must submit one file turn without monopolizing this queue; this slice does not pretend a batch is eight unrelated jobs. Check settlement for the last handle before capture. Pending schedules one retry; it does not capture. Reserve active and future retained bytes while the previous consumer lease remains fully charged. Retained ledger includes both existing leases and all reserved future results.
3. Capture is synchronous MainActor. Mark the exact job/reservation as capturing before invoking it. Revalidate consumer, job generation, shutdown/cancel state and reservation after callback. Reentrant calls cannot seize that slot. Capture refusal/throw/cancel before commit releases new reservation only after callback scope exits and preserves the previous lease. A cancelled/unregistered consumer invalidates the old lease separately as requested.
4. Actual capture count must not exceed estimate. Keep the generic context on MainActor; only immutable text and numeric metadata cross to preparation. Off-main, in exactly one retained preparation task, validate the String's true UTF-16 count using a bounded prefix of estimate+1 (checked arithmetic), and validate scope against that length before driver submit. A mismatch/growth fails sourceChanged and preserves the prior lease. This task is cancellation-owned; do not release its String/credit until its scope exit acknowledgment. No NSTextStorage access occurs off-main.
5. A successful capture/admission transaction commits only after preparation validation succeeds, driver submit returns an owned handle, and the same owner/job remains current. Until then the old lease remains charged and valid; a driver admission refusal preserves it. Store a returned handle before any reentrant notification so cancellation always has an owner. Atomically invalidate/retire the previous lease and assign new job ownership. If an old lease is actively borrowed, its payload and charge remain until the borrow scope unwinds. No new job assumes that invalidating its ID has freed its memory. Refusal before this commit preserves the previous result.
6. Keep one owner task across submit and wait, and one joined cancellation task. A handle arriving after cancellation is immediately cancelled; a cancelled observer must not detach the owner's sole wait. Clear job/capture/source aliases through explicit helper scopes. Never cancel this retained task merely because a panel closes. Driver busy/refusal is a compact failure; no immediate unbounded retry loop with retained snapshots.
7. After wait returns, store an unpublished provisional result under active ownership. Do not retain the source-bearing completed Task after its handoff scope exits. Reconcile settlement using the exact handle. Even when wait has returned a failure, active credit remains until actual settlement. A successful result is published only after that settlement and all external preparation/delivery scopes have exited. Atomically exchange active/future-result reservations for the retained lease; no uncharged duplicate. If closed/cancelled meanwhile, discard output in a bounded owner scope and release only after it exits.
8. Completion executes at most once, after state and credit transitions. It may reenter. It receives only a lease ID or compact error. Unregister/cancel fences a late callback immediately; success cannot repopulate a closed consumer. Cancellation is a synchronous request, with cleanup retained independently.

`withResult` provides a synchronous borrow, not a detached value-returning API. A lease holds exactly one context/source/output tuple. Borrow depth is tracked. `release`, cancellation, successful new admission and unregister immediately invalidate further access but defer destruction and credit release until the last current borrow exits. Callers must not retain source/output beyond that borrow; the later native adapter review enforces this internal ownership contract. Nested AppKit modal loops/reentrant completion can invalidate a borrowed lease, so a future native adapter must recheck lease validity and native authority before mutation. The component does not certify arbitrary escaped Swift String aliases as tracked.

## Cancellation, shutdown and veto

Explicit cancel invalidates delivery, retires that consumer's result and cancels queued metadata immediately. Submitted/capturing/preparing work retains its logical slot and active credits until actual scopes and driver settlement; repeated cancel joins existing work. Unregister follows the same path and prevents future callbacks. A stale cancel/job ID affects nothing newer.

Shutdown synchronously closes admission and invalidates all consumers/deliveries before its first await, removes queued metadata, requests active cancellation and starts existing bounded driver shutdown. Repeated calls join one retained command; inspect later settlement without restarting shutdown grace. Pending cleanup remains owned by this controller and the existing driver. There is no user-facing indefinite quit veto: durable document/recovery ownership remains authoritative.

This slice has **no resume/factory replacement API**. After durable quit veto, integration retains this stopped controller and displays stopping/unavailable until a separately reviewed assembly can account for driver, reader and pre-adoption launcher quarantine. `settled(true)` alone never authorizes a fresh factory or revives stale deliveries. Native activation cannot land until its explicit quit-veto integration is implemented; deferring it here does not waive that acceptance gate.

## Acceptance and proof limits

Deterministic tests must hold preparation return, submit return, wait return, parent codec/read scope, consuming reap and close acknowledgment independently. Verify refusal preserves previous source/output identity and exact credits, cancel retains slot while resources remain, stale queries cannot release newer ownership, and synchronous borrow release cannot deallocate early. Weak sentinels demonstrate actual owner-scope release where possible; ledger counters alone are insufficient.

Actual-driver tests cover both healthy idle reuse and cancellation with separate held reap/close, unconsumed receipt, source-bearing coordinator and retiring read states. The nonterminal query must not signal, reap, close, launch, restart timers or shut the driver down. Original driver, codec, lifecycle and wire suites remain required. Existing frozen-only gates may be used with exact source transforms; no production sleeps or test-only behavior branches.

Implementation/test commands and source provenance are recorded in the [execution plan](../plans/2026-10-05-search-admission.md). Passing this slice establishes injected ownership and truthful observation, not adopted budgets, app routing, native text authority, real helper/memory bounds, packaged desktop acceptance or completion of the full product.

## Root design review — 2026-10-05

Checked Task1 against actual `submit`, `coordinatorExited`, `readOwnerExited`, terminal `shutdown` and lifecycle release behavior. The optional handle must be rechecked across the inspection await; only the last admitted handle is retained. A healthy idle reader is distinct from a source-bearing request or retiring reader. Inspection must not read codec-thread state or create process authority. The query keeps the original launcher and cannot authorize quarantine escape or quit-veto factory replacement. These constraints allow independent implementation before budget selection. Tasks2–4 and native activation remain planned; their completion requires separate tests and review.
