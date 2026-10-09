# Joined Admission Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking. Root owns all serial runtime; source authors/reviewers never invoke Swift, helpers, GUI or watchdogs independently.

Status: Tasks 1–2 are implemented, tested and independently approved. Fresh
public neighbors496/0, full993/0 with app/helper linking, native10/0, unchanged
native3/0 and pure52/0 pass; exact native controls reach14/15 intended failures
with genuine cleanup. Task 3 final whole-branch review approves the scoped
checkpoint; the local commit remains pending.
Fixed service/native owner design is in progress; no routing is activated.

**Goal:** Add an admission terminal owner that drains actual request scopes before joining the parent and reports residual charged payloads without upgrading original diagnostics.

**Architecture:** Add `SearchParentWireJoining` without changing Driving conformers. The controller arbitrates legacy/joined mode, refuses synchronous callback reentry, retains one request-drain task, then composes the original parent result with fresh current settlement and ledger facts. Existing borrower destruction remains authoritative.

**Tech Stack:** Swift Package Manager, Swift6 toolchain in Swift5 mode, macOS14 deployment floor, Foundation/AppKit/XCTest, existing owned-process watchdog.

**Spec:** `docs/superpowers/specs/2026-10-09-admission-joined-terminal-design.md`

## Global Constraints

- macOS14 remains the deployment floor, Swift6 toolchain in Swift5 mode, no external runtime package.
- Preserve existing Driving conformers, all existing Swift test/harness bytes and every old oracle. Preserve unrelated changes.
- Public repository: synthetic documents only; no credentials, private buffers, machine-specific home paths or raw diagnostics in tracked files.
- No codec, worker, child lifecycle, ledger formula, native factory, AppDelegate routing, manifest, packaging script or default policy changes.
- `SearchParentWireJoining` has the existing `shutdownJoined(after: SearchParentWireHandle?) async -> SearchParentJoinedShutdownResult`; no default legacy fallback.
- Original parent caller/ownership refusal, original uncertain child cleanup and failed lane stop stay unchanged. New outer `observed` is not a success certificate.
- Synchronous callback refusal occurs before terminal mutations. Residual actual borrows stay invalid and charged through genuine outer return; never await borrower zero from inside that borrow.
- Never cancel or duplicate the sole wait, consume/discard a foreign receipt, guess a late handle or introduce another signal/reap authority.
- Join parent after actual request/cancellation/query drain, without waiting for full idle-session absence first.
- Resident transport stays charged for the ledger lifetime. Logical allowances do not establish allocation/RSS/global payload bounds.
- Root alone owns serial compilation/runtime/real children/GUI and exact-owned cleanup. Use the direct accepted watchdog; never nest a session-owning watchdog.
- Local scoped commits are authorized; no remote push/merge/release/security-setting changes. Preserve all ignored original/evidence trees.
- A passing build is not feature completeness. No new packaged desktop/IME/VoiceOver/Intel/macOS14 runtime/performance acceptance follows.

## Execution and preservation

Base local source `3bc4899de6d1e144fceb09c268fa9f6d03c927a9`; already isolated on
`feat/search-admission-joined-terminal`. Matching unchanged baseline962/0 and
387 tested input hashes were verified before documentary design work. Original
59 mixed source/test/manifest/native-runner inputs are privately sealed; the
three intended production edits may differ only after accepted TDD gates.
Every old Swift test/harness/native source remains exact. No repeated baseline
compiler run is required solely for prose changes.

Independent spec/plan review precedes test authoring. For each implementation
task, use fresh bounded test author, independent test SPEC/QUALITY review, Root
RED, fresh source implementer, Root GREEN and independent source SPEC/QUALITY
review. Compiler RED is distinct from reached behavioral RED. Root may keep a
reviewed task uncommitted until the integrated checkpoint; record each complete
state in the private progress ledger. Milestones do not end continuous work.

## File structure and interfaces

Production:

- Modify `Sources/SearchExecution/SearchParentWireDriverTypes.swift`: additive joining capability only.
- Modify `Sources/SearchExecution/SearchParentWireDriver.swift`: existing concrete conformance only.
- Create `Sources/SearchExecution/SearchAdmissionJoinedShutdownTypes.swift`: outer result/refusal/observation values, exact spec fields, Sendable/Equatable.
- Modify `Sources/SearchExecution/SearchAdmissionController.swift`: mode/retained owner, synchronous invocation scopes, actual request/query drain, refreshed current observations, conservative retirement and legacy projection.

Additive scripted and actual-driver tests:

- `Tests/SearchExecutionTests/SearchAdmissionJoinedTestHarness.swift`: bounded Joining forwarder, real existing scripted backend, held query/join gates and exact event/call observations. No production state access.
- `Tests/SearchExecutionTests/SearchAdmissionJoinedShutdownTests.swift`: mode/retained-owner/drain/diagnostic/credit tests.
- `Tests/SearchExecutionTests/SearchAdmissionJoinedDriverIntegrationTests.swift`: actual controller/parent/codec/lifecycle with injected process/channel collaborators and independent idle-read return gate.

Additive hidden native and pure runner contracts:

- `Tests/SearchAdmissionJoinedNativeIntegration/NativeJoinedAdmissionTests.swift`: separate hidden AppKit tests with native modal entry and tiny synthetic payloads; no edits to old native module.
- `Tests/SearchAdmissionJoinedNativeIntegration/NativeJoinedRetirementTests.swift`: two actual provisional Context destruction ordering tests, revised after the original nested-async scheduling experiment failed; preserve the original evidence.
- `Tests/SearchAdmissionJoinedNativeIntegration/run_harness.py`: explicit frozen native coordinator using existing common freeze/receipt utilities and direct watchdog.
- `Tests/SearchAdmissionJoinedNativeIntegration/test_runner.py`: pure synthetic execution/source/receipt rejection tests.
- `scripts/test-search-admission-joined-native.sh`: archive-compatible relative-root entry.

Documentation at final checkpoint: this plan/spec, `AGENTS.md`,
`docs/continuation.md`, `docs/verification/search-admission-joined-terminal.md`.
No requirement-row state change is authorized merely by this component evidence.

### Task 1: Joined controller owner and actual request drain

**Files:** Production four files and two scripted test files above. Existing
test files remain bytewise unchanged.

**Consumes:** `SearchParentWireDriving` methods, existing real parent
`shutdownJoined(after:)`, controller worker/cancellation/query/lease state,
`SearchAdmissionPreparing`, actual ledger reserve/abandon/retain/release.

**Produces:** Exact additive `SearchParentWireJoining` and
`SearchAdmissionJoinedShutdownResult`/`SearchAdmissionJoinedShutdownObservation`
from spec; `SearchAdmissionController.shutdownJoined()` for Task2 composition.
The existing package initializer and `shutdown()` signature remain unchanged.

- [x] **1. Author additive scripted tests and a finite event harness.**

Use a Joining forwarder over the unchanged `AdmissionScriptedDriver` for existing
actual submit/wait/cancel behavior. Forward identical handles, values and errors;
do not synthesize consumption. The forwarder independently records final join
key, call counts and an event sequence of real method returns. It may hold its
own query/join return to expose contract boundaries. Add methods to the new
harness only, never the protected backend. Public test state is fixture state,
not controller internals.

Harness interface:

```swift
actor JoinedAdmissionDriver: SearchParentWireJoining {
  let backing: AdmissionScriptedDriver
  // Production protocol methods forward unchanged; test controls below are fixture APIs.
  func configureJoin(_ result: SearchParentJoinedShutdownResult, hold: Bool,
                     onEntered: (@Sendable () -> Void)?)
  func releaseJoin()
  func configureQueryHold(onEntered: (@Sendable () -> Void)?)
  func releaseQuery()
  func snapshot() -> JoinedAdmissionDriverSnapshot
}
struct JoinedAdmissionDriverSnapshot: Sendable {
  let joinCalls: Int
  let legacyCalls: Int
  let lastJoinHandle: SearchParentWireHandle?
  let events: [String]  // hard cap64, no unbounded loop
}
```

Use actual existing `AdmissionPreparationGate`, `AdmissionManualRetry`, weak
boxes and `DriverTestGate` where useful. Configure tiny original result values
once per fixture. The new tests must cover these behavior groups with independent
method identities (names may expand when a genuinely different discriminator is
needed):

| Case | Real trigger and required outcome |
| --- | --- |
| `testUnsupportedDriverRefusesWithoutClosingOrConsumingState` | Plain unchanged Driving backend; joined callerRefused unsupported; original consumer/capture path remains usable and legacy shutdown still works. |
| `testLegacyFirstPermanentlyRefusesJoined` | Actual retained legacy command entered; joined callerRefused legacy before a joining command; no second command. |
| `testNeverAdmittedJoinUsesNilAndRepeatedCallsShareParentResult` | Joining driver, no request; one nil-key join; identical original parent value; resident2, no job/lease debt. |
| `testJoinedFirstLegacyUsesOriginalParentShutdownAndCurrentSettlement` | Joined completed then legacy; no legacy command, exact parent shutdown projection, actual current settled/pending value. |
| `testParentCallerRefusalRemainsRawAndLegacyAliasIsRetainedOnce` | Shared-parent caller refusal selected in fixture; repeated joined value retains refusal; legacy obtains one genuine fixture alias; no false admitted result. |
| `testMatchingCancelledCallerCannotCancelRetainedOwner` | Real held join, two callers; cancel one caller; release actual gate; one owner and unchanged original outcome, no wait cancellation. |
| `testCloseFencesQueuedCapturesAndReleasesQueuedWeakOwners` | Actual queued closures; close before first await, zero captures/deliveries, weak queued captures release, future submit throws shutdown. |
| `testHeldPreparationRetainsCreditUntilItsActualOuterReturn` | Capture into weak context, actual preparation gate held; reservation remains active6/reserved3/job1; no first parent join. Release prep after cancellation, no submit; parent join then retirement only under gate. |
| `testLateSubmitHandleDrainsSoleWaitAndExactCancellationBeforeJoin` | Backend submit-return held; close; release exact handle; independently held sole wait/cancel; joinCalls0 until both genuine returns; final actual nonnil handle, cancel1/wait1/no discard. |
| `testPrecloseQueryCannotPublishOrRetireAfterJoinedSelection` | Hold query while work transitions; close, release query; no new capture/delivery, actual query returned before join; final handle not old nil. |
| `testDelayedCancelledRetryCannotRestartJoinedAdmission` | Retain fixture's real original callback and invoke it after cancellation; identity fence prevents query/capture/publish. |
| `testOwnershipRefusalAndLaneFailureRetainReservationWithoutUpgrade` | Actual worker exits but raw parent refusal or laneStop.failed; retain Job/reservation and report actual credit even if fixture settlement says closed. |
| `testThrownSettlementReportsPendingAndKeepsReservation` | Actual post-join settlement throws; observed pending/unchanged parent, job and credit stay retained; later genuine settled observation may retire under the same gate. |
| `testCancelledNeverAttemptedPreparationRetainsReservationOnParentRefusal` | Held real preparation cancelled then returns without submit; raw parent refusal; no ordinary finishCapture rebate, reservation stays active6/reserved3/job1, no delivery. |
| `testPendingSettlementRetainsCreditAndLaterObservationRetiresIt` | Original admitted/acknowledged parent completion, first genuine current pending; later genuine closed observation retires payload/reservation; original result unchanged. |
| `testOriginalUncertainChildIsNotReplacedByLaterCurrentSettlement` | Original stopping/stopUnconfirmed parent child receipt remains identical; later closed observation updates only current fields/conditional credit. |
| `testConcurrentRefreshCoalescesHeldQueryButLaterCallIsFresh` | Hold post-join query with two matching callers; one query at a time, current stable facts; after release later explicit query can see new settled state. |

Representative initial test shape (new API must be absent before compiler RED):

```swift
@MainActor
func testUnsupportedDriverRefusesWithoutClosingOrConsumingState() async throws {
  let backend = AdmissionScriptedDriver()
  let owner = try SearchAdmissionController<String>(
    driver: backend, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
  addTeardownBlock {
    await backend.setSettlement(.settled(admissionClosed: true))
    _ = await owner.shutdown()
  }
  let consumer = owner.register()
  let refused = await owner.shutdownJoined()
  XCTAssertEqual(refused, .callerRefused(.unsupportedDriver))
  XCTAssertEqual(owner.accountingSnapshot.active, 2)
  await backend.setSettlement(.settled(admissionClosed: false))
  let delivered = expectation(description: "original consumer still receives capture failure")
  var captures = 0
  let limits = try SearchWireLimits(
    maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 8, cooperativeMilliseconds: 0)
  let descriptor = try SearchAdmissionDescriptor(
    query: .init(pattern: "x", mode: .literal), operation: .find,
    estimatedInputUTF16: 1, scope: nil, limits: limits)
  _ = try owner.submit(
    consumer: consumer, descriptor: descriptor,
    capture: {
      captures += 1
      throw SearchAdmissionFailure.captureRefused
    }, completion: {
      XCTAssertEqual($0, .failed(.captureRefused))
      delivered.fulfill()
    })
  await fulfillment(of: [delivered], timeout: 2)
  XCTAssertEqual(captures, 1)
  XCTAssertEqual(owner.accountingSnapshot.active, 2)
}
```

Admission usability is the discriminator for refusal before mutations. Register
cleanup before any suspending
setup. All held fixture gates must be released in unconditional teardown and
all fixture-created tasks joined on failure as well as success.

- [x] **2. Independent test review and Root RED.**

Review full new tests/harness and all protected originals against spec; freeze
exact sources/manifest in a fresh ignored minimal package or exact repository
snapshot. Root directly invokes the accepted watchdog, using unique output paths:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-joined-task1-red-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-task1-red --filter SearchAdmissionJoinedShutdownTests
```

Record absent-capability/API compiler RED separately. Reached behavioral RED
must discriminate at least early nil join before late submit/sole wait drain,
early reservation release and raw diagnostic upgrade, using ignored deliberately
wrong implementations in frozen copies only. Tests stay unchanged in production.
Root verifies method starts/failures, intended assertions, source bindings and
complete owned-process receipts. No compiler failure is counted as behavior.

- [x] **3. Fresh implementer writes the smallest accepted production change.**

Add protocol, result values and concrete conformance. In controller, select mode
and retain owner before callbacks/suspension; close/fence immediately. Implement
checked synchronous invocation depth with `defer`, whole `captureNext` scope plus
delivery/observation and retry collaborator scopes. Refuse joined calls within
those scopes even after joined selection. Do not mark `withResult` as refused.

Joined owner drains worker, then re-reads/drains cancellation and pre-close query.
The no-attempt preparation branch defers ordinary finishCapture retirement while
joined mode is selected; preserve its existing legacy/ordinary behavior.
Use helpers whose real return precedes parent join/credit release. Joined mode
suppresses pump/inspection result effects/retry scheduling. A late exact handle
still owns cancellation and original sole wait. Then call the joining capability
with the final handle; store raw result independent of caller cancellation.

After joined command, share only an in-flight current refresh query. On query
error report pending. After it actually returns, apply the spec's three-part
retirement gate. Clear local Job payload in a separate helper, return from it,
then abandon reservation and remove Job. Actual synchronous ledger observation
inside destruction retains credit; queued terminal calls are observed after the
real outer return. No unproven retirement guard requirement or original parent
enum rewriting.
Borrowed invalid leases remain until real outer return. Build new observation
from actual ledger snapshot/current counts without exposing mutable ledger state.

Legacy-after-joined projects completed parent shutdown, or caches one genuine
exceptional driver shutdown alias; its current observation uses the same fresh
refresh path. Legacy-first original path retains bounded semantics and all old
oracles. Do not introduce timer polling, second wait or a synthetic success.

Reachability correction: original nested async destructor tests did not run their
inner Task until outer destruction returned. Preserve the original tests/report/run
and withdrawn source finding. Rename/re-specify the two native ordering methods:
actual synchronous live ledger observation during destruction, followed by genuine
queued terminal results afterward. Independently review them, then require a
frozen credit-before-clear mutant to reach live6/3/reservation1 failures with complete
cleanup and unchanged-source GREEN. This neither credits the original failed recipe
nor justifies a private retirement guard. Resolve warnings in the revised new source.

- [x] **4. Root focused GREEN and independent source review.**

Freeze the final actual source with unchanged tests; run the same filter under
direct watchdog in a unique GREEN path. Verify exact unique methods/no unexpected
errors/warnings/skips/timeouts, all old bytes and source inventory. Strict format
only after fixing genuine errors; retain author's original bytes and any format
diff. Independent source SPEC/QUALITY review includes the whole new controller
ownership path and exact recorded RED/GREEN scope. Mark Task1 complete only when
all findings are resolved; commit may be deferred to Task3 integrated scope.

### Task 2: Actual parent and native reentrant acceptance

**Files:** New actual-driver test module, new native module/coordinator/pure tests
and shell entry. Task1 accepted production sources remain unchanged unless a
new witnessed bug requires separately reviewed regression/fix.

**Consumes:** Exact Task1 API; unchanged `DriverHarness`, `DriverTestConnection`,
`DriverTestWire`, `DriverTestGate`, lifecycle/codec/accumulator, existing common
runner freeze/receipt checks and checked-in watchdog.

**Produces:** Finite actual-codec/injected-process evidence and hidden AppKit
borrow/capture/accounting reentry evidence. No real helper or visible desktop.

- [x] **1. Add event-driven actual parent integration tests.**

Construct actual `SearchParentWireDriver` with unchanged harness lifecycle and
factory, then actual admission controller. Observe existing generation-qualified
parent events; never add a production observation hook. Exercise genuine wire
hello/request/terminal frames bound to actual ticket identity.

Required methods:

- `testActualNeverAdmittedJoinedOwnerClosesAndAcknowledgesLane`: no child; raw ownership admitted, noChild/channelsClosed, lane acknowledged, current closed and resident still charged.
- `testActualIdleReadMustReturnBeforeJoinedObservation`: tiny supplementary-Unicode completed result, consume/borrow/release; gate actual cancelled idle-read return independently after close and sole synthetic consuming reap. Observe first actual cancel/read event, assert joined Task has not returned via reached event trace, then open read gate and await genuine matching `sessionReleased`; final observation raw admitted/acknowledged/current closed. No prior idle-absence wait.
- `testActualCancelledActiveRequestPreservesSoleWaitAndExactJoinHandle`: real request/codec, close during active work; existing sole wait returns actual failed receipt before first join; one exact cancellation, no competing observer/receipt discard; final authentic ownership admitted.
- `testExternallySelectedParentLegacyIsPreservedAsRawRefusal`: actual parent legacy selected deliberately before controller entry; new observation embeds callerRefused legacy; no conversion. Controller caches its first actual exceptional shutdown() return once; do not require equality to an external caller's earlier potentially different bounded snapshot.

Use tiny strings/limits; process/channel collaborators are injected. Unconditional
cleanup opens every read/upload/close gate, prepares synthetic reaping and joins
fixture tasks. A failure deadline is an outer watchdog, never a timing oracle.

- [x] **2. Add hidden native cases and exact-source runner controls.**

Create separate class `NativeJoinedAdmissionTests` with:

- `testJoinedObservationsReturnInsideBorrowWithResidualCredit`: real AppKit target/action from Timer in `.modalPanel` mode inside actual `withResult`. A finite loop stops only after two matching joined observations returned. Both count lease1/retained3 with weak context alive; after actual outer borrow return weak nil/retained0; later observation leases0, original parent identical. Include legacy-afterjoined projection while borrowed; no physical window/input/helper.
- `testCaptureReentryRefusesBeforeModeOrReservationMutation`: actual synchronous capture enters native loop before returning captured value. Inner Task calls new joined API and gets synchronousCallbackActive, stops loop, proves capture still live/admission unchanged/credit6+reserved3. After genuine outer return, outside joined call drains real scope and reports truthful current state. No fabricated marker.
- `testAccountingReentryRefusesBeforeCaptureAndLeavesConsumerUsable`: existing-style reentrant accounting invokes native loop before reserve/capture; actual joined refusal returns without closing or consuming consumer. Native action verifies no premature capture/credit mutation, then outside original flow still completes; later joined close succeeds in exact defined scope.
- `testDeliveryReentryRefusesWhileOuterCompletionIsLive`: actual completed delivery enters native loop; refuse finite joined close while callback scope live, then outside callback observe joined cleanup. This guards a worker/query stack whose slot may already be cleared.
- `testObservationReentryRefusesBeforeWorkerCallbackReturns`: actual internal workerExited observer enters native loop after worker slot clears but before helper callback returns; new joined caller refuses synchronously, then outside observation genuine join drains scopes.
- `testRetryScheduleReentryRefusesBeforeTokenInstallation`: genuine pending query invokes a new test-only retry collaborator whose schedule method enters native loop before returning its actual token; inner joined refusal leaves admission/token disposition intact, later outside close cancels exact token once.
- `testRetryCancelReentryRefusesWhileJoinedCloseSetupIsLive`: actual pending retry token cancel enters native loop during accepted joined close; inner repeated joined caller gets finite synchronousCallbackActive rather than awaiting the owner's close stack; outer owner then finishes real join. Token cancellation/fixture loop state stay genuine.
- `testInlineRetryFailureCancelReentryRefusesBeforeFailClosedReturns`: test-only inline scheduler triggers existing failClosed path; its real token cancel invokes native loop. Inner joined caller sees scope refusal; no capture/delivery restart; outside caller subsequently observes authentic terminal state. Preserve old inline-failure oracle.

Also retain class `NativeJoinedRetirementTests`, revised at Task1 reachability reassessment:

- `testQueuedJoinedRequestObservesRetirementAfterDestructorReturns`: genuine provisional Context destruction enters `.modalPanel`; the real Timer action synchronously observes ledger active6/reserved3/reservation1 and registers a queued joined Task. After actual destructor/outer caller return, await that real task and require raw parent unchanged/current closed/job0/active2/reserved0. The earlier live ledger value remains immutable.
- `testQueuedLegacyRequestPreservesOriginalReceiptAfterDestructorReturns`: same real live ledger boundary and later queued legacy call; require exact original completion.shutdown, backend legacy0, and genuine post-return retired state.

Use genuine capture/request/sole-wait/provisional results, no production hooks or
marker mutation. Stop the ordering loop on the actual synchronous ledger/action
boundary, explicitly distinct from an async terminal return; join all fixture tasks.

For the seven refusal methods, use public `Task.immediate` from the real MainActor
Timer/action so the depth guard executes before an actual callback returns. Root
must prove this current-host behavior and a reached guard-removal control. A wrong
call can suspend: capture its real public mutation/result and release the loop on
an explicit action boundary, then await the actual task after outer return. An
emergency-only release is infrastructure, never accepted RED. Borrowed-result
positive join remains on the existing synchronous Timer-owned borrow pattern.

Private new native target/action/loop helpers have a bounded trace and one
emergency failure timer. Each loop stops on its declared authentic boundary:
actual returned refusal/borrow observation, or the ordering case's synchronous
live ledger/action boundary. A guard-removal control may stop on its explicit
reached mutation-failure boundary before joining the suspended caller afterward;
never treat emergency-only release as successful RED. No sleep/polling or success
based on timeout. Reserve task registration before synchronous-start construction,
then retain the actual returned handle before any further suspension. Register
rescue before native action;
invalidate timers and release/join Tasks on every exit. Keep old native module
and its own runner bytewise unchanged.

The new native runner freezes complete actual PadCore/SearchExecution, the two
new scripted test dependencies it needs, unchanged original harnesses, new native
module, its own Python/shell/common/watchdog sources and public manifest. Generate
only an isolated macOS26/Swift5 native test package, with explicit older-host
rejection for public immediate-task availability. The app/public manifest remains
macOS14 and the old native runner remains unchanged. No Swift source transformation or private
extension. Include only declared test modules required by its class; if original
native module is included to share helpers, select/require all three original
methods as well (never filter them out silently). Prefer independent tiny native
helpers so the new runner has exactly ten required new methods (eight admission
cases plus two retirement ordering cases).

Runner checks before/after stages: exact source membership/hash/modes and origin
bytes; declared class/methods no conditionals/skips/duplicates; matching manifest;
unique actual XCTest starts/passes, counts, zero errors/skips; full direct watchdog
process-group/wait/capture/cleanup receipts and no compiler warnings. Load frozen
Python bytes directly rather than stale timestamp bytecode. Root invokes it
directly; it owns supervision in the same process and refuses arbitrary filters.

Pure runner tests use synthetic temporary archives/receipts only. Prove ordinary
valid named execution accepted; missing/duplicate/wrong/skipped/failed/zero-test
logs rejected; changed source/manifest/origin/protected inventory refused; strict
receipt return/wait/cleanup/capture/timeouts rejected; frozen shell command and
generated Swift5/macOS26 native-test settings preserved; older-host refusal is
explicit and the public macOS14 manifest remains unchanged. They do not run Swift/AppKit.

- [x] **3. Independent tests/runner review, Root behavioral controls and GREEN.**

Absent behavior must be discriminated in frozen ignored copies: remove the
whole-capture callback guard and reproduce actual native refusal failure; replace
residual borrow with premature credit release and reach weak/ledger failure;
skip actual parent join or treat physical close/reap as read exit and fail the
actual held-read case. Every control is scoped/bounded and fixture cleanup still
returns; otherwise classify infrastructure failure rather than credited RED.

Root executes, sequentially, fresh paths or runner-generated unique directories:

```sh
python3 -m unittest discover -s Tests/SearchAdmissionJoinedNativeIntegration -p 'test_*.py'
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-joined-driver-green-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-driver --filter SearchAdmissionJoinedDriverIntegrationTests
scripts/test-search-admission-joined-native.sh
scripts/test-search-admission-native-borrow.sh
```

Verify exact source/fixture identities, actual method starts/passes and all
cleanup receipts. Original3 native tests must still pass unchanged. Record
injected versus native scope explicitly. Independent source/evidence review
approves matching source and runner; no compiler/helper execution by reviewers.
Resolve every material finding before marking Task2 complete.

### Task 3: Integrated verification, scoped checkpoint and next service owner

**Files:** Documentation above; no runtime changes without a new witnessed cause.

- [x] **1. Run focused neighboring and fresh full public app/core under Root supervision.**

Freeze exact current input hashes before commands and verify unchanged membership
after. Use unique paths; commands are the established public interface:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-joined-neighbors-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-integrated --filter 'SearchAdmission|SearchParent|SearchWire|SearchWorker'
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/admission-joined-full-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-integrated
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
git diff --check
```

Full app and helper must link; exact unique XCTest counts derive from selected
actual sources/logs rather than assumed baseline addition. Native/Python runner
counts are separate from ordinary public suite. Do not rerun passed checks absent
changes/failure/remaining concern; do not wrap native coordinators in another
watchdog. No new package/desktop result follows solely from public build.

- [x] **2. Record implemented/tested/pending/blocked states and independent final review.**

New verification record states exact terminal result grammar/refusal precedence,
mode/drain/borrow/credit boundaries, direct commands, meaningful RED/GREEN and
native scope. Preserve original first receipts and failed infrastructure attempts
separately. Record current distribution remains4841d89; current UI Automation
authentication is user-owned pending. Update AGENTS/continuation/spec/plan without
changing requirement row acceptance from mere component tests.

Final independent SPEC/QUALITY/evidence review reads complete branch diff,
reports/inventories/receipts/captures, all unchanged old tests and exact new
identities, plus source-bound limits. Resolve material findings. Root verifies
tested pins and fresh public/cached whitespace checks, stages exact scope and
makes a local commit. Preserve private evidence and progress ledger; no remote
action or automatic scratch deletion.

- [ ] **3. Continue fixed service/native owner design.**

Next subsystem composes the real production parent/accounting/retry with this
terminal owner and chooses native document/folder search cancellation/quit
ownership. Actual packaged helper and native activation receive their own
reviewed plan and acceptance. A retained borrower, refused ownership or uncertain
child cannot become whole-service success at the factory boundary. Do not stop
the authorized build at this component checkpoint.
