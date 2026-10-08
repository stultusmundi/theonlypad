# Production search admission accounting and retry

Status: planned; not implemented or tested. Based on accepted parent construction
commit `4841d89`. BUILD_PROMPT authorizes routine design choices and independent
review in place of repeated human approval. This is an architectural integration
slice; tests and reached RED precede implementation.
Independent specification/quality review approves this design and plan with
no blockers. Implementation and runtime acceptance remain pending.

## Selected approach

Add two standalone package collaborators to the existing admission controller:
immutable `SearchAdmissionProductionAccounting` and MainActor
`SearchAdmissionDispatchRetryScheduler`. Keep the controller initializer,
protocols, queue, ledger, driver and native routes unchanged.

Three approaches were considered:

1. Two collaborators satisfying existing protocols. Selected: bounded and
   independently testable, preserving existing injection and ownership.
2. A bundle-only production controller factory. Deferred because the controller
   currently invokes legacy driver shutdown, which precludes joined shutdown.
3. A process-wide service with native consumers, folder scheduling and terminal
   ownership. Required later, but combines unresolved context/lease/close contracts.

This slice supplies accounting and retry implementations, not a complete service.
The current editor/folder paths still use in-process search. No new package
manifest dependency, external package, native activation or production test hook.

## Exact APIs and file ownership

Create `Sources/SearchExecution/SearchAdmissionProductionAccounting.swift`:

```swift
package struct SearchAdmissionProductionAccounting: SearchAdmissionAccounting, Sendable {
  package init()
  package var activeLimit: UInt64 { get }
  package var retainedLimit: UInt64 { get }
  package var resident: UInt64 { get }
  package func charge(for descriptor: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge
}
```

Create `Sources/SearchExecution/SearchAdmissionDispatchRetryScheduler.swift`:

```swift
@MainActor package final class SearchAdmissionDispatchRetryScheduler:
  SearchAdmissionRetryScheduler {
  package init()
  package func schedule(
    _ action: @escaping @MainActor () -> Void
  ) -> any SearchAdmissionRetryToken
}
```

Tests reside in new `SearchAdmissionProductionAccountingTests.swift`,
`SearchAdmissionDispatchRetrySchedulerTests.swift` and
`SearchAdmissionProductionIntegrationTests.swift` in `Tests/SearchExecutionTests`.
Use existing test collaborators without modifying original assertions. No raw
numeric charge API, timer accessor, injected production dispatch adapter, extra
ledger or scheduler registry is introduced. The package APIs are explicit;
callers can continue to inject different collaborators through existing protocols.

## Root-selected logical budgets

| Setting | Exact value | Meaning |
| --- | ---: | --- |
| activeLimit | 1,610,612,736 | 1.5 GiB of active logical reservations including resident |
| retainedLimit | 1,342,177,280 | 1.25 GiB of retained plus future retained credit |
| resident | 1,048,576 | 1 MiB lifetime policy allowance, not measured transport/RSS |
| active fixed allowance | 65,536 | Job/stream metadata policy allowance |
| retained fixed allowance | 4,096 | Lease/metadata allowance, including empty results |
| retry delay | 25,000,000 ns | 25 ms asynchronous inspection backoff |

For a genuine validated descriptor, define:

- I = estimatedInputUTF16, without discounting a smaller scope.
- O = maxOutputUTF16 for replace, exactly zero for find.
- M = maxMatches; Q = query pattern UTF16 count.
- T = replacement template UTF16 count for replace, zero for find.
- B = (I + 8) / 8, integer division; the actual boundary bitmap includes
  offset zero and the endpoint, so empty input costs one byte.

```text
active   = 65,536 + 6*I + 6*O + 32*M + B + 3*(Q + T)
retained = 4,096  + 3*I + 3*O + 16*M
```

Three bytes per UTF16 unit estimates strict UTF8 content; it does not measure
Swift String storage or capacity. Six reserves two logical text-content
allowances per source/replacement, without asserting actual copy counts. The
actual collector accumulates bounded UTF8 Data before String conversion. Ranges
have two 64-bit semantic fields: active32*M supplies two logical range-content
allowances and retained16*M supplies one. Neither measures array capacity. The
bitmap term follows the real SearchWireBoundaryIndex allocation formula.
Query/template terms cover bounded content, never arbitrary closure graphs.

Use `UInt64(exactly:)` after explicit nonnegative/bounded validation. Validate
I <= maxTextUTF16 <=100,000,000, output <=100,000,000, matches <=100,000 and
pattern/template <=4,096 UTF16 units. Count blobs through prefix(4,097), not an
unbounded input traversal. Check every formula addition/multiplication, including
I+8, with reporting-overflow operations. Invalid dimensions throw
`.invalidDescriptor`; arithmetic failure throws `.resultBudget`. Never wrap,
saturate or silently return zero. Genuine descriptor bounds make scalar formula
overflow unreachable today; source review checks arithmetic without pretending
invalid forged descriptors ran. Existing UInt64.max ledger controls remain.

Literal maximum derivation (metadata only, no large source allocation):

| Descriptor | Active | Retained |
| --- | ---: | ---: |
| Find I=100M, M=100k, Q=4096 | 615,777,825 | 301,604,096 |
| Replace I=O=100M, M=100k, Q=T=4096 | 1,215,790,113 | 601,604,096 |

B=12,500,001 at I=100M. Maximum replacement plus resident is1,216,838,689,
which fits activeLimit. Two retained maxima total1,203,208,192 and fit
retainedLimit; a third cannot fit. This permits an old result lease plus a future
replacement reservation before the old lease is retired. Publication retains
the conservative declared ceiling; no actual-size rebate is added.

The existing controller allows eight outstanding jobs TOTAL, including one
active (seven queued plus one active). It reserves before capture, independently
checks active and retained/future-retained limits, and preserves charges through
worker/cancellation/inspection and reentrant borrower scopes. These behaviors
and failure compaction remain unchanged. A descriptor estimate may exceed actual
captured text; maximum-budget tests may capture a tiny synthetic document and
must say they test logical charges, not100M-unit execution or memory fit.

Arbitrary Context, capture/completion closures, caller aliases, NSTextStorage,
undo/history, registered consumers, Foundation capacities, ARC/task objects,
kernel buffers, launcher quarantine, helper and regex work are not bounded by
this formula. The resident allowance is policy only. Multiple controllers each
have separate ledgers; process-wide ownership remains a later task.

## MainActor retry and cancellation

The default scheduler uses `DispatchQueue.main.asyncAfter` with a fixed25ms
DispatchTime delay. No synchronous callback, sleep, recursive polling, run-loop
spinning or detached Task loop. Every call returns a fresh private MainActor
token storing its action and DispatchWorkItem. Install the work item before
queueing, without await or client reentry. The item captures the token weakly.
On the actual main queue it enters `MainActor.assumeIsolated` to invoke the
private fire operation; this assertion is valid only because that sole transport
is the main queue. Swift5/macOS14 compilation is a verification gate.

Fire takes the action and clears both action and item references BEFORE invoking
it, giving at-most-once delivery. Cancel clears action first, clears item and
requests cancellation; repeated cancel is harmless. Dispatch cancellation alone
is insufficient because an item may still enter. Once synchronous fire has taken
an action, later cancellation cannot retroactively retract it. Controller retryID
fencing and its inline-scheduler fail-closed defense stay unchanged.

Token -> item -> weak token avoids a cycle. The caller must retain the returned
token for delivery; dropping it releases the captured action/context. Dispatch
can retain a cancelled/no-op item until its deadline, so cancellation is not a
physical queue-release or lane-stop receipt. Independent tokens do not share
cancellation state or introduce another queue/global-budget owner.

## Observable acceptance and verification

Independent test author and separate specification/quality review precede code.
Root owns all serial compilation/runtime, using the accepted direct owned
watchdog without nesting. No helper/process/GUI execution is needed for these
collaborators.

Accounting tests compare independent literal charges for empty, find/replace,
supplementary blobs, zero/positive match caps, maxOutput ignored for find, scope
not discounting full input, bitmap at0/7/8/100M and genuine maximum descriptors.
Use the existing ledger at exact and one-short limits; refusals preserve counters.
An old lease and future reservation fit two maxima; a third refuses. Controller
integration checks that the refusal occurs before capture and leaves prior
leases intact. Do not allocate100M text or widen production APIs for arithmetic
coverage.

Retry tests execute the real main-queue adapter: callback runs after schedule
returns, on MainActor/main thread, no earlier than25ms from a prior monotonic
start. Bound liveness with XCTest async expectations and the watchdog, not sleeps.
Check one delivery, repeated cancel, callback-local cancel, independent tokens,
weak captured-context release and token release. Observe cancelled suppression
only after a later uncancelled callback/main-queue sentinel has actually run.
Never pass simply because a callback has not arrived yet.

Integration uses both concrete collaborators with existing scripted-driver gates
and at least one actual driver/codec plus injected child/channel workflow.
Exercise pending settlement then healthy admission, cancel/unregister while retry
is scheduled, exact source/output lease borrow/release, and held-scope charge
preservation. Existing deterministic manual/inline retry and legacy terminal
regressions remain mandatory. Scripted results are component evidence; the actual
driver still has injected child/channel collaborators, no real process or helper.

Root records missing-API compiler RED separately from reached behavioral RED.
A generated ignored wrong but valid formula or inline/no-cancel scheduler can
establish bounded behavioral sensitivity without altering tests or adopted
sources. Do not run cancellation tests on an unbounded wrong loop. Final focused,
neighboring admission/ledger/driver/wire/resolver/collector and full app/core
runs bind exact frozen sources, method identities and complete watchdog receipts.
Strict formatting, public/whitespace checks and independent final evidence review
precede scoped local commit. Source review proves checked arithmetic and lifetime
ordering; tests establish their observable finite scope. No new package/helper
acceptance is inferred from compilation.

## Separate mandatory terminal-owner work

SearchAdmissionController.shutdown calls only legacy `driver.shutdown()` through
SearchParentWireDriving. SearchParentWireDriver permanently selects legacy mode
then refuses later joined shutdown with `.legacyModeSelected`. Calling controller
shutdown followed by concrete driver join cannot establish joined service close.
This slice leaves those contracts intact and never claims terminal completeness.

A later reviewed terminal design must select joined ownership before a legacy
command, close admission, fence callbacks, retain worker/cancellation/borrowed
leases, authenticate latest handle and reconcile the private lastHandle with
the driving protocol. Preserve original child cleanup; uncertain receipts cannot
be upgraded after later clean observations. It must discriminate active/idle/read/
write ownership, stale handles, concurrent callers and unconfirmed cleanup before
any production factory or native close/quit activation.

Native adapters additionally need delayed capture, revision/lifetime validation,
bounded contexts, lease ownership and a single process admission owner. Current
Desktop UI Automation access remains user-owned; continue independent work.
No hard-regex, RSS/allocation, performance, GUI/physical input/IME/VoiceOver,
Intel/macOS14 runtime or whole-product acceptance, remote push/merge/release.

## Draft provenance

Root read the source-only draft completely and verified all17 production/test
pins. Retained draft21388 bytes/SHA256
`c0599ae9dd18ced4aa7862971ede01fe18356e54527ce986b1c693413525dfd9`.
Its former HEAD14e426a and pending checkpoint/doc pins are historical: the
reviewed construction is now committed at4841d89. Root selects the values,
formula,25ms transport and collaborator-only scope above. No runtime evidence
for these new components follows from the previous939/6 construction checkpoint.
