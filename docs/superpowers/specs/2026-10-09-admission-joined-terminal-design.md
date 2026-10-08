# Joined admission terminal ownership

Status: independent source-only SPEC/QUALITY/PLAN review approves this design
and its implementation plan. Implementation, new test execution, service factory
and native activation remain outstanding.
Baseline is local `3bc4899`: accounting/retry components23/0, neighboring357/0,
full app/core962/0. Existing distribution remains source4841d89.

## Problem and chosen boundary

The admission controller currently owns only `SearchParentWireDriving`. Its
retained `shutdown()` task selects the parent's legacy terminal mode. Calling
the concrete parent's joined entry afterward permanently refuses conversion.
A new production service cannot safely compose those two calls as joined close.

This is architectural because it changes coordination interfaces. The smallest
choice is an additive joining capability and a separate controller entry. The
controller already owns the request task, final handle, cancellation, queries,
retry and result leases. A Driving adapter would duplicate those authorities
and obscure parent refusal diagnostics. A separate external service would need
a new authenticated drain receipt plus another owner before this boundary is
usable. Neither alternative is selected for this slice.

Preserve the existing Driving protocol and all existing conformers. Add:

```swift
package protocol SearchParentWireJoining: SearchParentWireDriving {
  func shutdownJoined(after handle: SearchParentWireHandle?) async
    -> SearchParentJoinedShutdownResult
}
```

The existing `SearchParentWireDriver` declares this conformance using its already
implemented method. No default implementation, legacy fallback, concrete-only
downcast or parent engine/lifecycle behavior change is permitted.

## New controller result

Add types in `SearchAdmissionJoinedShutdownTypes.swift`:

```swift
package enum SearchAdmissionJoinedCallerRefusal: Sendable, Equatable {
  case unsupportedDriver, legacyModeSelected, synchronousCallbackActive
}

package enum SearchAdmissionJoinedShutdownResult: Sendable, Equatable {
  case callerRefused(SearchAdmissionJoinedCallerRefusal)
  case observed(SearchAdmissionJoinedShutdownObservation)
}

package struct SearchAdmissionJoinedShutdownObservation: Sendable, Equatable {
  package let parent: SearchParentJoinedShutdownResult
  package let driverSettlement: SearchParentWireSettlement
  package let retainedActiveJobs: Int
  package let retainedLeases: Int
  package let activeCharge: UInt64
  package let retainedCharge: UInt64
  package let reservedRetainedCharge: UInt64
}
```

The package controller entry is:

```swift
package func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult
```

`observed` describes facts, not a success certificate. It embeds the original
parent result unchanged, including parent caller/ownership refusal, original
uncertain child cleanup and failed lane stop. The counts, charges and current
driver settlement are separately refreshed observations. There is no convenience
`completed`, `stopped` or `fullyReleased` predicate on the new outer result.

Every observation is a value snapshot; later cleanup does not mutate earlier
values. Matching later calls retain the same parent result but may report later
settlement and fewer genuine residual leases/reservations. Resident transport
stays charged for the ledger lifetime, including after joined close.

## Entry arbitration and refusal precedence

The controller owns its driver exclusively for submit/wait/cancel/discard and
terminal selection. External sharing violates that production contract. Tests
must still preserve actual parent refusals under deliberately shared drivers;
sharing never authenticates new ownership or permits another receipt consumer.

An explicit controller terminal mode selects either legacy or joined exactly
once before close mutations, collaborator callbacks or suspension. A synchronous
scope refusal is checked first, including for repeated joined callers. Otherwise
legacy mode refuses the joined entry. Before selecting an unused joined mode,
check the additive capability; unsupported drivers are refused without closing
admission, consuming consumers/jobs, invalidating leases or selecting a mode.

For accepted joined selection, install one retained owner before any reentrant
close work. Close admission and fence capture/delivery/retry immediately before
the public entry's first suspension. The retained command does not inherit a
matching caller's cancellation and is never cancelled when a caller drops it.
Concurrent matching callers share that command. Dropping the facade while it
is draining does not destroy its request or cancellation authority.

An existing legacy-first call still has the same bounded historical receipt
and current settlement semantics. Preserve every old test and oracle bytewise.
Legacy-after-joined awaits the same retained joined command; on a completed
parent result its `driver` is precisely `completion.shutdown`. It refreshes the
same current admission/settlement facts without starting legacy retry progress.

If an externally shared parent instead returns `callerRefused`, preserve that
exact refusal in joined observations. The old nonoptional legacy receipt API
may obtain its receipt through one retained `driver.shutdown()` alias only for
this exceptional compatibility path. The joining-capability contract requires
that legacy entry reuse the parent's existing selected cleanup authority. In
joined mode the concrete driver returns the immutable completion.shutdown; in
legacy mode it returns a new bounded current snapshot through that same lifecycle
authority. The controller retains the one exceptional call's returned receipt.
This does not convert or upgrade
the refused joined result, and never introduces another signal/reap authority.
No fabricated shutdown value is permitted.

## Synchronous callback scopes

A native modal loop may reenter MainActor while capture is executing before
`worker` is installed. `worker == nil` is therefore not capture-scope exit.
Track real outer synchronous invocation scopes; refuse new joined entry while
any are active, before terminal mutations. The scope must include the entirety
of `captureNext`, covering arbitrary `accounting.charge`, invocation of capture,
local return/error aliases, validation and worker installation or failure
completion. Exiting `invokeCapture` alone is insufficient.

Also cover controller invocation of delivery/observation callbacks and retry
collaborator `schedule`/`cancel` calls. These may synchronously enter a native
loop while the owning stack has not returned. Scope markers use a checked depth
and `defer`, with no production test getter or manufactured state. Markers must
not wrap `withResult` itself: borrowing has the distinct residual policy below.
Unchanged legacy API remains available in its existing borrowed-result cases.

Refusal leaves mode/admission/credit and callback disposition unchanged. After
the genuine outer synchronous return an outside owner may call joined close.
Observe this both for capture and reentrant accounting using actual MainActor
native run-loop entry, not private marker mutation.

Progress still depends on genuine return of custom async collaborators. This
slice cannot force arbitrary `prepare`, driver or client code to return or break
a circular await constructed by that code. Owned async collaborators must not
await the terminal command that is waiting for their own scope. The fixed
production preparation and parent do not make that circular call. No timeout
or task-cancellation shortcut may masquerade as their return.

## Request drain and parent join

Joined close removes queued capture/completion closures, clears consumers,
marks active work cancelled, invalidates result leases and cancels the current
retry token. Preserve the active captured/provisional payload and reservation
until its actual scopes settle. Never cancel the sole worker/wait task, start
a competing wait, discard an unconsumed receipt or guess a request handle.

During joined selection, the no-attempt preparation exit must also defer its
ordinary `finishCapture` retirement to the gate below. Preserve the original
no-attempt branch for legacy/ordinary operation.

The retained command waits for the actual preparation/request helper to return,
including a late submit return. That return installs the real latest handle;
cancel it exactly once through the existing exact cancellation owner, and let
the existing sole wait consume its real result. Await the actual cancellation
helper return as well. No new submit/capture/publication occurs after close.

Await any already-running advisory query and fence its effects. A pre-close
query cannot publish, capture, release an active reservation or certify a late
handle after joined selection. Suppress legacy `pump`, inspection progress and
retry scheduling for joined mode; delayed cancelled callbacks remain fenced.
The joined task uses the final `lastHandle` only after these actual returns.

Call `joiningDriver.shutdownJoined(after: finalHandle)` directly after request
drain. Do not first await terminal settlement, idle reader exit or session
absence: the parent join owns closing that reader. Preserve the parent's first
immutable result. Its mechanics already join actual codec/bridge/session scopes
and logical lane-loop acknowledgment; no pthread join or allocator claim follows.

## Current settlement and reservation retirement

After the parent command, perform one bounded current
`driver.settlement(after: finalHandle)` observation. A thrown query reports
`pending`; it does not fabricate closed settlement or rewrite the parent result.
Concurrent refresh callers coalesce an in-flight refresh query. Completed
refreshes are not cached forever: a later explicit call can observe real progress.
No automatic joined retry loop or second parent command is added.

Retire an active Job/reservation only when all of these facts hold:

1. The preparation/request, cancellation and pre-close query helpers truly returned.
2. The original parent result is completed with ownership admitted, lane stop
   acknowledged and `shutdown.parentLaneSettled == true`.
3. Current settlement reports `settled(admissionClosed: true)` for the final handle.

Clear captured/provisional payloads in a separate helper and return from that
helper before abandoning the reservation/removing the Job. Do not invoke a
completion callback. This also covers attempted-submit errors conservatively.
On refused ownership/caller, failed lane stop or pending current settlement,
keep the Job/reservation and report its real credit/counts. A later observation
may retire a pending reservation only after the same gate genuinely holds;
immutable refusal or lane failure never upgrades. Existing original child
`pendingLaunch`, `stopping` or `stopUnconfirmed` remains unchanged even if a
separate current settlement later permits logical reservation retirement.

This is intentionally conservative for misuse/refusal. It does not certify
cleanup of external request owners, launcher quarantine, unconsumed foreign
receipts, arbitrary Context/callback aliases, undo/text storage or helper RSS.

## Borrow policy

An actual `withResult` borrow may run a modal loop until joined observations
return. Do not wait for its own outer return. Invalidate leases on close, but
retain payload and ledger credit while `borrowers > 0`, using the existing
checked borrow/deferred destruction. Join request/parent resources and return
an observation with those residual leases and their actual charge.

Two calls inside the same live borrow may therefore return the same parent
result with retainedLeases1/retainedCharge3 under the small test accounting.
After the true outer invocation helper returns, existing destruction removes
the lease and releases credit. A subsequent observation shows leases0/charge0.
Neither prior value changes. No new payload-release waiter or callback is added.

## Files and verification boundary

Production edits: new capability in `SearchParentWireDriverTypes.swift`, concrete
conformance only in `SearchParentWireDriver.swift`, new admission result types,
and controller terminal/scope/query coordination. No codecs, worker, lifecycle,
ledger formulas, native factory, AppDelegate routing, manifest, dependencies,
packaging scripts or default policy changes.

Tests are additive in separate new modules/harnesses. Preserve every existing
Swift test/harness bytewise, including42 controller,4 actual-driver,5 ordinary
parent-joined and3 native borrow methods. New scripted tests use actual finite
events/held continuations; unconditional cleanup releases all owned fixture gates.
No sleep/polling, inverted unfulfilled expectation or private production-state
mutation establishes a boundary.

Discriminators include unsupported/pre-close refusal, both mode orderings,
one retained owner/cancelled caller, queued weak releases, held preparation,
late handle, independent sole-wait and cancellation gates, old query fence,
preserved parent refusals/lane failures/uncertain child, and conservative charge.
Actual codec composition holds the idle read return independently of close/reap,
then requires genuine generation-qualified `sessionReleased` and lane acknowledgment.
Native hidden tests exercise joined residual borrow and real capture/accounting
modal refusal; no shown window, posted input or helper is required.

Root alone executes compilers, runtime, real child and GUI tests under accepted
direct owned-process supervision. No nested watchdog. Meaningful compiler RED
is separate from reached behavioral RED/mutation controls. Verify matching
inputs, exact method identities, captures and cleanup receipts, then neighboring
regressions/full public app build, strict format and public checks.

macOS14 remains the deployment floor, Swift6 toolchain in Swift5 mode, no external
runtime package. ARM64 current-host evidence is not Intel/macOS14 runtime,
physical input/IME/VoiceOver, memory/performance or whole-product acceptance.
Real packaged service/helper acceptance and native search activation remain
subsequent separate work. UI Automation authentication remains user-owned.
