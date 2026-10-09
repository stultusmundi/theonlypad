# Fixed Admission Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to execute reviewed tasks. Root assigns bounded ownership, source/spec reviews and all runtime gates. Implementation begins after independent spec/plan review.

**Goal:** Add one fixed MainActor generic facade that exposes consumer/job/lease operations and exact typed joined termination over the actual existing admission chain.

**Architecture:** SearchAdmissionService<Context> holds one private actual controller, which transitively retains the fixed parent/accounting/retry. Its package initializer fixes composition; one module-internal controller initializer supports source-bound forwarding tests. Native app ownership and activation remain separate designs.

**Tech Stack:** Swift6 toolchain in Swift5 mode, Foundation/Dispatch, actual SearchExecution/PadCore, XCTest; checked-in Python owned-process watchdog for Root-only harness execution. No external runtime dependency.

**Spec:** `docs/superpowers/specs/2026-10-09-search-admission-service-design.md`

**State:** Task1 facade IMPLEMENTED, component TESTED and independently
source/evidence APPROVED. Documentation adoption and scoped local commit remain
PENDING at this record. The service design and this plan have
independent specification/quality approval. Authenticated compiler API RED is
followed by focused6/0, required neighboring7 classes96/0, and two actual-facade
controls reaching exactly3 parent and2 settlement assertions with genuine cleanup.
Retained recursive strict formatting passes with394 exact inputs/empty captures;
all498 protected existing source/test/script/manifest bytes and modes match.
Fresh matching public package999/0 binds399 inputs in28.200549s, includes all six
formatted facade tests and builds app/helper executables without launch. See
`docs/verification/search-admission-service.md`. Baseline remains committed
`42513c0`; distribution remains `4841d89`, and editor search stays in-process.
Task1 is locally committed at `5b5ad8c`; the preceding Task1 pending-commit
paragraph records the earlier checkpoint. Current Tasks2/3 are IMPLEMENTED,
TESTED and independently source/evidence
ACCEPTED within the fixed constructor/compiler and scripted native scopes. The
canonical `scripts/test-search-admission-service.sh` passes pure50, ordinary
positive/five independent negative clients and constructor4/0; its separate
copied eager-entry control authenticates1 intended assertion/0 unexpected.
`scripts/test-search-admission-service-native.sh` passes pure51 and native2/0.
Counts remain distinct from the prior full999/0. Task2/3 test/runner checkpoint is locally committed at `0f7c96e`; no optional native DTO rewrite mutant was added. Earlier failed
runs remain preserved/uncredited. The exact Task4 corrective normative supplement
is source-approved and adopted; ABI/prototype/fixture/finite-cleanup/runtime gates
remain unchecked and unaccepted. No helper/runtime proof follows from adoption.

## Global constraints and sequence

- Root owns compiler, import/runtime, pure tests, Swift/AppKit/helper processes, watchdog, format, public checks and final evidence review. Authors perform only the explicitly assigned work; parallel source ownership never overlaps.
- Protect exact existing production, tests/harnesses, native modules, public manifest, formulas/default policies, common/watchdog and old runner bytes. New facade is the only production file. No AppDelegate or app-target dependency change.
- Public macOS14/Swift5 unchanged. Genuine Task.immediate native reentry runs only in a separately generated macOS26/Swift5 hidden package, explicitly rejecting older hosts without skips.
- Fixed helper remains Contents/Helpers/PadSearchWorker; no package executable/PATH/driver/accounting/retry/prepare/observer override or implicit Bundle.main selection.
- Child operation10_000_000_000ns, reapGrace2_000_000_000ns, idle10_000_000_000ns, maximumRequestsPerChild8 and maximumWireBytesPerChild268_435_456 unchanged.
- ActiveLimit1_610_612_736, retainedLimit1_342_177_280, resident1_048_576; charge formulas unchanged. Per-instance logical ledger is not an aggregate budget or whole-memory claim. Retry25_000_000ns unchanged.
- Preserve all raw refusal/observation fields, immutable parent and refreshed settlement/residuals. withResult Bool is borrow acceptance, never terminal success. No service Task/cache/state-machine/legacy terminal/deinit join.
- Required order: reviewed new tests → absent-API compiler RED → thin actual production facade → focused GREEN → reviewed frozen mutants of that actual facade with reached intended failures and genuine cleanup → neighboring/source/evidence review. API RED is not behavioral RED.
- No source/test adoption from wrong-control prototypes. Preserve every failed attempt and distinguish source/permission/toolchain/cleanup/deadline failure from behavioral RED. No nested watchdog.

## Task 0 — review and protect the implementation boundary

**Owner:** Root. No application/source edit in this task.

**Inputs:** exact V2 spec, this draft, original source author report, current accepted joined controller/driver/native checkpoint.

**Outputs:** adopted reviewed spec/plan, bounded author tasks and ignored immutable before-inventory.

- [x] Review V2 and this plan; resolve scope/signature/cleanup findings before implementation. Native-owner/quit/context/input producer decisions stay excluded.
- [x] Record actual branch/HEAD/worktree, inventory/hash/mode of every existing recursive PadCore/SearchExecution source, old SearchExecution test/harness, native runner/test, Package.swift, scripts/swift.sh, common parser/watchdog and relevant current docs. Protect old bytes rather than treating a source-backed transformation as an ordinary edit.
- [x] Assign tests/runner authors their new paths first. Production author owns only NEW Sources/SearchExecution/SearchAdmissionService.swift and starts after Root authenticates API RED. Tell every author they are not alone and must preserve other edits. Source report bytes remain separately pinned.
- [ ] Root chooses one task at a time for actual runtime; log planned/implemented/tested/blocked independently. A scoped commit occurs only after its review/evidence gates, never from this private authoring task.

## Task 1 — reviewed facade tests, compiler API RED, actual facade, behavioral controls

**Files:**
- NEW `Tests/SearchExecutionTests/SearchAdmissionServiceTests.swift` (focused test methods only).
- NEW `Tests/SearchExecutionTests/SearchAdmissionServiceTestHarness.swift` (private fixture/task/cleanup helpers).
- NEW `Sources/SearchExecution/SearchAdmissionService.swift` (only production edit).
- Existing SearchAdmissionTestHarness.swift and SearchAdmissionJoinedTestHarness.swift are read-only dependencies.

**Interfaces consumed:** actual SearchAdmissionController<Context> initializer and methods; existing SearchAdmissionDescriptor/Capture/Delivery/Failure/IDs; existing SearchParentWireJoining and typed joined DTOs; JoinedAdmissionDriver, JoinedAdmissionGate, AdmissionTestAccounting and AdmissionManualRetry. No new driver protocol.

**Interfaces produced:** exact package facade below; test-only ServiceFixture<Context> submission/registration/cleanup owner inside the new harness.

### Step1 — author a genuine facade fixture and six focused methods

- [x] Build one test-owned actual controller with the existing JoinedAdmissionDriver/AdmissionTestAccounting/AdmissionManualRetry. Pass that actual controller into the proposed module-internal facade initializer. All exercise methods submit/register/cancel/unregister/release/borrow/close through the service, not through a controller stand-in.
- [x] Install async XCTest teardown synchronously immediately after fixture construction and before driver configuration, task creation or any suspension. Store every consumer/job ID, preparation/query/join gate and task handle independently of the service result. Cleanup can invoke the known actual test controller directly to cancel/release genuine fixture work when a facade mutant fails forwarding; this is cleanup authority, not an assertion outcome.
- [x] Before final driver/rescue-registration sealing, retain and await an independently owned actual controller terminal/helper-return fence; rescuing backend/preparation gates and callback counts alone cannot prove no future controller task entry. Use existing genuine controller operations as cleanup authority, separate from candidate facade outcomes. Preserve the requestless unsupported/legacy-selected cases and their raw refusal assertions; do not infer a general legacy helper-join guarantee. No production hooks, polling, empty-slot inference or ignored late-entry checks.
- [x] The existing JoinedAdmissionFixture private scope counters cannot be reused around direct service.submit: its own submit wrapper alone increments expected captures. New ServiceFixture counts successful capture outer returns, preparation entries/returns and genuine existing workerExited observations itself, and drives through service.submit. Do not edit old fixture counters or treat missing worker slots as actual returns.
- [x] Reuse JoinedAdmissionDriver.beginRescue/drainForwardedScopes/sealAndJoinRescueWaits with their existing real backend late-wait rescue. Cleanup first cancels actual known jobs, disables retry actions, releases all actual held gates, completes genuine sole wait if needed, awaits preparation/worker return, joins independently registered facade caller tasks, drains forwarded driver scopes and finally seals/joins actual rescue registration. Require no outstanding tasks/scopes or registrations-after-seal; no result-based early exit.
- [x] A successful completed scripted handle also needs its actual fixture-only cancel before the existing driver's forwarded-scope drain: that predicate requires real returned cancel for every submitted handle. After genuine worker/sole-wait return, snapshot exact submitted/returned-wait/cancelled handles; for each genuinely completed submitted handle lacking cancel, call that exact driver's real cancel and await its actual return, once. Never guess a handle, compete with an unfinished cancel, or mark return synthetically. For this facade fixture, genuine sole backend completion, consumed sole wait, exact exclusively owned handle and actual preparation/worker returns authorize fixture-only cancellation independently of candidate callback delivery. Keep delivery assertions in the body. The native policy is reused only for exact handle/return/ownership safeguards, not delivery-dependent rescue authority; protected native fixtures remain unchanged. Report those cancels as fixture-only, distinct from facade runtime behavior.

Required exact class `SearchAdmissionServiceTests` method names and narrow oracles:

| Method | Genuine setup/action | Required facade-boundary assertion |
| --- | --- | --- |
| testConsumersShareControllerAndForwardQueueCancellation | Hold first consumer's actual wait; same consumer re-submit and another consumer queued; cancel queued ID through facade | Same-consumer consumerBusy precedes capture; other consumer uses same controller queue; cancelled queued capture/completion never run; exact job identity preserved |
| testLeaseBorrowPreservesContextAndReleaseInvalidates | Actual delivered lease, reference Context with supplementary-Unicode label; service.withResult and service.release | Same Context identity and exact source/output values from the actual driver; no extra callback/alias; subsequent borrow false without body; reference releases after true outer borrow return |
| testActiveCancelAndUnregisterUseExactConsumerAndHandle | Hold real cancel independently of wait; service.cancel active ID then service.unregister its consumer | Exact submitted/waited/cancelled handle equality, one real cancel, completion suppressed; different registered consumer remains usable; cleanup joins both independent returns |
| testRawParentRefusalAndFreshSettlementAreForwarded | Driver raw callerRefused(.legacyModeSelected), current pending then actual closed query; second service joined call | Exact outer observed parent refusal, unchanged complete parent value, pending then refreshed closed settlement, all genuine residual fields; no driver legacy call/rewritten result |
| testUnsupportedAndLegacyControllerRefusalsAreForwarded | Actual unsupported controller then separate actual legacy-selected controller injected into facade | Exact outer unsupportedDriver and legacyModeSelected; no mutation/upgrade/new parent join; ordinary public submit still usable after unsupported refusal |
| testMatchingCancelledFacadeCallersShareActualOwner | Actual held preparation/late submit/cancel/wait returns; retain two service joined tasks, cancel one caller | No facade-cached/fabricated return; one uncancelled parent owner after actual scopes, final real handle, same immutable parent for both callers; cleanup returns regardless of assertion failure |

The lease test may use exact x/y values of the unchanged scripted backend and a
Unicode Context label; it must not claim to prove Unicode worker text processing.
The actual Unicode request/source/output obligation is completed in Task4 through
the real public helper. If author elects a Unicode scripted request in Task1,
Root reviews its declared exact outcome/sole-wait fixture separately; never
rewrite the old driver's outcomes or add a synthetic result in the facade.

Example no-request forwarding oracle, with actual existing collaborator APIs:

```swift
let fixture = try makeFixture()
// makeFixture registers async teardown synchronously before returning.
let raw = SearchParentJoinedShutdownResult.callerRefused(.legacyModeSelected)
await fixture.driver.configureJoin(raw)
await fixture.driver.configureCurrentQuery(.success(.pending))
let first = await fixture.service.shutdownJoined()
guard case .observed(let a) = first else {
  XCTFail("actual raw parent refusal must remain an observed parent fact")
  return
}
XCTAssertEqual(a.parent, raw)
XCTAssertEqual(a.driverSettlement, .pending)
await fixture.driver.configureCurrentQuery(.success(.settled(admissionClosed: true)))
let second = await fixture.service.shutdownJoined()
guard case .observed(let b) = second else { return XCTFail("missing observation") }
XCTAssertEqual(b.parent, a.parent)
XCTAssertEqual(b.driverSettlement, .settled(admissionClosed: true))
XCTAssertEqual(a.driverSettlement, .pending) // prior value is immutable
```

The test class defines `makeFixture()` to construct the actual test fixture and
register its unconditional cleanup before returning, without suspension:

```swift
private func makeFixture() throws -> ServiceFixture<JoinedAdmissionContext> {
  let fixture = try ServiceFixture<JoinedAdmissionContext>()
  addTeardownBlock { await fixture.cleanup() }
  return fixture
}
```

`cleanup()` is the genuine fixture-owned rescue/drain contract described above;
it is not a production method or a receipt-dependent shortcut. ServiceFixture is
a new private test helper defined by the new harness; it is not a new production seam. Tests also compare counts/charges to actual test accounting
and snapshot calls once, without a polling/inverted expectation oracle.

### Step2 — Root source review and absent-API compiler RED

- [x] Root/spec reviewer reads every new test/helper method and failure cleanup. Freeze all old/current dependencies with the exact new tests and an isolated generated Swift5/macOS14 test manifest; record protected membership/modes/origins. No public Package.swift edit.
- [x] Root invokes the accepted direct watchdog to compile that exact selection before the facade source exists. Require failures at intended SearchAdmissionService API references and record the actual compiler diagnostics; no dummy facade/prototype is introduced. Preserve receipt/source/error artifacts. Toolchain/dependency failure cannot be credited API RED.
- [x] Root authenticates RED and dispatches only the new facade source ownership.

Proposed focused command vector inside a reviewed direct coordinator (not an
established command claim):

```text
scripts/swift.sh test --package-path <frozen Package> --scratch-path <owned Build> --filter SearchAdmissionServiceTests
```

### Step3 — implement the exact thin facade, then Root focused GREEN

- [x] Production author creates this one class; no other production edit:

```swift
import Foundation
import PadCore

@MainActor package final class SearchAdmissionService<Context> {
  private let controller: SearchAdmissionController<Context>

  package convenience init(applicationBundle: URL) throws {
    let parent = try SearchParentWireDriver(applicationBundle: applicationBundle)
    let accounting = SearchAdmissionProductionAccounting()
    let retry = SearchAdmissionDispatchRetryScheduler()
    let controller = try SearchAdmissionController<Context>(
      driver: parent, accounting: accounting, retry: retry)
    self.init(controller: controller)
  }

  init(controller: SearchAdmissionController<Context>) {
    self.controller = controller
  }

  package func register() -> SearchConsumerID { controller.register() }
  package func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    try controller.submit(
      consumer: consumer, descriptor: descriptor, capture: capture, completion: completion)
  }
  package func cancel(_ id: SearchJobID) { controller.cancel(id) }
  package func unregister(_ consumer: SearchConsumerID) { controller.unregister(consumer) }
  package func release(_ id: SearchResultLeaseID) { controller.release(id) }
  package func withResult(
    _ id: SearchResultLeaseID, _ body: (Context, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    controller.withResult(id, body)
  }
  package func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    await controller.shutdownJoined()
  }
}
```

- [x] Author source self-review verifies only private controller storage, module-internal injection initializer, exact DTO/errors/callbacks/IDs, no wrapping/cache/Task/legacy method or package override. Root runs matching focused6 and requires exact6 starts/passes, zero failures/skips/compiler warnings and strict input/receipt closure.

### Step4 — reviewed actual-facade mutants, then neighboring acceptance

- [x] Only now freeze the actual new facade and identical reviewed tests in two independent ignored copies. Root/source reviewer approves one mutation per copy, recording original adopted source bytes/hash separately and exact transformed source pins. No prototype source substitutes for the actual facade.
- [x] MutantA: in that actual shutdownJoined body, retain `await controller.shutdownJoined()` and all real cleanup; only when the observed parent is .callerRefused(.legacyModeSelected), rewrite it to .callerRefused(.differentJoinOwner), forwarding every other observation field unchanged. Expected method testRawParentRefusalAndFreshSettlementAreForwarded reaches exact raw-parent equality failures. Do not change controller/driver/test bytes or other branches.
- [x] MutantB: retain actual await and exact parent; only for observed parent .callerRefused(.legacyModeSelected), force driverSettlement to .settled(admissionClosed:true), forwarding other fields. The same named test reaches its explicit first-pending assertion; require full first DTO/current freshness witnesses as reviewed. No second join or cached synthetic task.
- [x] Root reviews actual full mutation diff and source closure before execution. Direct owned runtime must show all6 unique named starts/finishes, intended assertion scope, zero unexpected/cleanup/emergency/deadline failures or compiler warnings/skips, and exact wait/capture/group-cleanup receipts. Nonzero alone is not RED. Independent fixture cleanup must return for both mutants, preserving every failed attempt.
- [x] Run unchanged neighboring SearchAdmissionControllerTests, SearchAdmissionJoinedShutdownTests, SearchAdmissionJoinedDriverIntegrationTests, SearchAdmissionProductionAccountingTests, SearchAdmissionProductionIntegrationTests, SearchAdmissionProductionRetryIntegrationTests and SearchAdmissionDispatchRetrySchedulerTests from matching source. Run old parent/default policy compatibility as required by actual findings; do not duplicate their full state-machine matrix in facade tests.
- [ ] Independent source/evidence review gates Task1 acceptance. Root broadens to matching full public app/core build/tests, strict format and public checks at the planned checkpoint. Record exact executed commands/versions/counts only afterward.

- [x] Matching fresh public package999/0 completed with399 exact inputs and the final formatted six tests; both app/helper executables built without launch.
- [x] Retained recursive strict formatting exited0 in5.015s, with394 matching inputs and empty captures; all498 protected existing source/test/script/manifest bytes and modes remain unchanged.
- [ ] Complete final independent Task1 source/evidence review, public-check evidence and documentation adoption before the scoped local commit. Constructor/package-access/native/real-helper acceptance is not supplied by the component or full-package run.

## Task 2 — package capability compiler contracts and actual fixed constructor

**Ownership:** separate test/runner author owns only new SearchAdmissionServiceIntegration directory and new shell below. Production facade author does not broaden source scope.

**New files:**
- `Tests/SearchAdmissionServiceIntegration/run_harness.py`
- `Tests/SearchAdmissionServiceIntegration/test_runner.py`
- `Tests/SearchAdmissionServiceIntegration/SearchAdmissionServiceConstructionTests.swift`
- `Tests/SearchAdmissionServiceIntegration/Fixtures/AllowedClient.swift`
- `Tests/SearchAdmissionServiceIntegration/Fixtures/ForbiddenLegacy.swift`
- `Tests/SearchAdmissionServiceIntegration/Fixtures/ForbiddenController.swift`
- `Tests/SearchAdmissionServiceIntegration/Fixtures/ForbiddenDriver.swift`
- `Tests/SearchAdmissionServiceIntegration/Fixtures/ForbiddenDriverInitializer.swift`
- `Tests/SearchAdmissionServiceIntegration/Fixtures/ForbiddenControllerInitializer.swift`
- `scripts/test-search-admission-service.sh`

**Inputs:** Task1 actual facade; real fixed parent/resolver/launcher/default accounting/retry; actual Package.swift as protected provenance; scripts/swift.sh, common parser/watchdog. All existing runners unchanged.

**Outputs:** exact package-access compiler contract and real fixed constructor/error tests, without helper process or native activation claims.

**Accepted checkpoint:** matching default coordinator0 with11 strict receipts,
97 origins/522 copies/6 generated; pure50 and constructor4/0. Separate actual
copied eager-entry control retains raw exit1 with1 intended assertion/0 unexpected,
coordinator0 and4 strict receipts/87 origins/89 copies/2 generated. Final
independent Task2 source/evidence review accepts this bounded scope. Compiler
clients are compile-only; no successful helper execution is claimed. Historical
fixture/parser failures remain retained and uncredited as intended RED.

### Step1 — test-only sibling compiler client and discriminating pure parser controls

- [x] Generate an isolated Swift5/macOS14 package with actual recursive PadCore/SearchExecution and a sibling client target in the same package. AllowedClient imports SearchExecution normally, never @testable. First compile it to prove generic/package/module/API validity. The positive client's source should contain:

```swift
import Foundation
import PadCore
import SearchExecution

@MainActor func allowed(bundle: URL, descriptor: SearchAdmissionDescriptor) async throws {
  let service = try SearchAdmissionService<String>(applicationBundle: bundle)
  let consumer = service.register()
  let id = try service.submit(
    consumer: consumer, descriptor: descriptor,
    capture: { SearchAdmissionCapture(text: "x", inputUTF16: 1, context: "synthetic") },
    completion: { delivery in
      if case .completed(let lease) = delivery {
        _ = service.withResult(lease) { _, _, _ in }
        service.release(lease)
      }
    })
  service.cancel(id)
  service.unregister(consumer)
  let result: SearchAdmissionJoinedShutdownResult = await service.shutdownJoined()
  _ = result
}
```

- [x] Each negative fixture is compiled separately, not added to passing XCTest or linked together. Use known typed function parameters to avoid undefined driver/controller expressions:

```swift
@MainActor func forbiddenLegacy(_ service: SearchAdmissionService<String>) async {
  _ = await service.shutdown()
}
@MainActor func forbiddenController(_ service: SearchAdmissionService<String>) {
  _ = service.controller
}
@MainActor func forbiddenDriver(_ service: SearchAdmissionService<String>) {
  _ = service.driver
}
@MainActor func forbiddenDriverInitializer(_ driver: any SearchParentWireJoining) throws {
  _ = try SearchAdmissionService<String>(driver: driver)
}
@MainActor func forbiddenControllerInitializer(_ controller: SearchAdmissionController<String>) throws {
  _ = try SearchAdmissionService<String>(controller: controller)
}
```

- [x] Root reviews diagnostic parser pure synthetic controls before any actual compiler stage. Require intended fixture path/line plus wrong-member/access/initializer diagnostic and nonzero actual receipt, after positive client success from identical inputs/toolchain. Generic module/package lookup failure, wrong diagnostic line, syntax error, compiler timeout or extra unrelated error rejects contract evidence. Bind exact observed wording during Root's actual first run; do not fabricate a diagnostic.
- [x] Pure runner tests discriminate missing/duplicate/wrong starts, zero tests, skips/failures/warnings, changed origins/modes/membership/generated manifest, symlink roots, wrapper/common/watchdog/fixture changes, wrong artifact source binding, receipt wait/return/capture/truncation/cleanup/timeouts, and negative compiler falsely passing due unrelated errors. Pure tests use temporary synthetic bytes only; Root executes them.

### Step2 — actual package constructor tests and finite no-eager companion

Required `SearchAdmissionServiceConstructionTests` exact4 methods:

| Method | Action and factual result |
| --- | --- |
| testAbsentBundleConstructsAndJoinedClosePreservesResidentCharge | Actual package init from absent absolute synthetic bundle; register but no submit; root remains absent; full raw actual parent and closed settlement, jobs/leases/reserved0, resident1_048_576. Current noChild is not historical zero-launch proof |
| testInvalidBundleURLsPropagateResolverInvalidURL | HTTPS/remote file host/relative-base/query/fragment/encodedNUL actual factory fixtures synchronously throw exact existing invalidURL; no capture/input/launch operation is requested |
| testMissingFixedHelperDeliversActualLaunchFailedENOENTWithoutFallback | Fresh synthetic bundle without fixed helper; inert sibling/build/PATH markers; real production accounting/capture/prepare/parent/launcher receives tiny request; async exact child launchFailed(ENOENT), no completion lease, clean actual joined facts; no in-process fallback |
| testActualParentConstructionDoesNotEnterInjectedLauncherBeforeBegin | Existing internal actual parent ctor(system:now:schedule:) with finite launch-entry counter and real existing parent begin/submit transition discriminator; zero launch entries before actual lifecycle begin; injected lower-seam evidence explicitly distinct from public factory process history |

- [x] Install async cleanup before any test setup suspension. Actual package service is retained independently; store every consumer/job and completion task; cancel/unregister exact IDs even after setup failure and await typed joined separately without interpreting it as successful cleanup. Missing-path case creates no owned helper; unexpected PID/process evidence or quarantine/first-outcome mismatch is infrastructure failure, retained for review.
- [x] For injected no-eager companion use an event/counter on existing SearchChildSystem.launch and declared clock/timer gates, no new production hook/state mutation. Constructor calls no begin; first real submit establishes launch entry. A source-reviewed eager-launch mutation in a copied actual constructor chain must fail the before-entry oracle with finite fixture cleanup. Avoid proving absence by sleeping, polling or an inverted expectation.
- [x] Fresh launcher condition includes real nonquarantined start and standard reapable SIGCHLD precondition; do not alter signal policy to force GREEN. Validate missing helper on the retained spawn lane before pipes; preserve ENOENT mapping only if it actually wins. Root records any deadline/cancel/quarantine/error as failure to reach this intended case, not as an alternate expected outcome.

### Step3 — runner source/evidence closure and Root execution

- [x] Runner freezes exact actual recursive PadCore/SearchExecution, Task1 new tests/harness and constructor4, ordinary compiler fixtures, runner/pure/shell bytes, public manifest, unchanged wrapper/common/watchdog. Classify compiled versus runner-only provenance explicitly. Seal generated manifest/sources inventories, preserve public macOS14 and Swift5.
- [x] Copy frozen Python bytes directly for common parser/watchdog without stale pyc. Invoke watchdog.main directly for each exact toolchain/build/compiler/test stage in the coordinator process. No outer supervisor, arbitrary filter/skip-build or source-transform escape. Only declared generated Build/wrapper cache roots exempted from source membership; no adopted input under them.
- [x] Root source-reviews runner/test failure paths, runs matching pure cases, then positive compiler, independent negatives, actual constructor4. Require exact named4 execution, zero warnings/skips/errors on positive stages, strict genuine receipts and before/after origin/mode/hash/membership. Negative diagnostic stages retain expected nonzero and their original logs, never rewritten GREEN receipts.
- [x] Proposed new command `scripts/test-search-admission-service.sh` becomes a proven command only after this exact source passes. Record generated manifest and executed command vectors in evidence; do not update AGENTS with an invented command before success.

## Task 3 — exactly two facade-native boundary cases in a separate host

**New files/ownership:** a native test author owns only
`Tests/SearchAdmissionServiceNativeIntegration/NativeAdmissionServiceTests.swift`.
A separate runner author owns only new `run_harness.py`, `test_runner.py` in that
directory and `scripts/test-search-admission-service-native.sh`. Existing joined
native sources/runner/shell stay unchanged.

**Interfaces:** actual Task1 facade, actual generic controller via its internal
test seam, existing joining collaborator/finite gates. No AppDelegate or native
document context choice. Generated isolated host macOS26/Swift5 only.

- [x] Author exact `NativeAdmissionServiceTests.testCaptureRefusalThroughFacadePreservesAdmission` and `testJoinedFacadeInsideBorrowPreservesResidualCreditUntilRealReturn`.
- [x] First case enters the real controller capture callback through service.submit, genuine Timer/action/modal loop, public Task.immediate registered BEFORE construction; the facade returns exact synchronousCallbackActive while real callback/loop remain live. Verify actual public consumer disposition/credit unchanged and genuine outer callback return before outside close. The task's actual handle is retained even if synchronous construction returns or suspends.
- [x] Second case completes a real service lease, uses Timer-owned actual service.withResult plus native loop and registered inner facade joined task; two inside observations preserve parent/lease1/retained3 under tiny test accounting. Stop loop on actual inner returns, join task and let true outer borrow return; later facade observation preserves parent and observes lease0/retained0. No wait for own destructor or simulated scope marker.
- [x] Test-only native helpers are independent new private helpers or reviewed source-relative reuse of accessible existing collaborators; old native fixture helpers are private and cannot simply be imported. Install rescue before scheduling native actions; invalidate timers, stop actual loop on reached intended failure boundary, release genuine gates and join every task independently. Emergency stop/loop deadline/unfinished cleanup rejects both GREEN and behavioral RED.
- [x] Root source-reviews finite failure branches and native runner. New runner freezes actual sources/native2/dependencies only, owns direct watchdog, rejects old hosts with no skip. Require exact2 unique starts/passes and source/receipt closure. A frozen actual-facade result-rewrite mutant must reach an exact new native DTO assertion if added; do not rerun whole previous ten-case controller matrix as facade acceptance.

**Accepted checkpoint:** corrected matching native coordinator0, pure51 and
exact native2/0;90 origins/90 copies/1 generated and5 strict receipts/artifact
audited, with final independent Task3 source/evidence acceptance. The original
native2/1/0 run remains preserved/uncredited. The conditional optional native DTO
rewrite mutant was not added; the completed review/execution step does not claim
that control ran. Counts remain distinct from Task2 selections and full999/0.
Scripted native evidence is not successful helper or editor routing acceptance.

Task3 supplements Task1 forwarding with the two genuine boundary contexts named
by V2. It does not duplicate every accepted controller callback/retirement test or
raise the app deployment floor.

## Task 4 — separately reviewed actual public-helper harness and runtime proof

**Prerequisite:** Tasks1–3 source/evidence reviews accepted. This phase cannot run
until its process-observation source and finite-cleanup design receive a separate
Root/spec/quality review. The exact Task4 observer supplement below is an adopted source contract after
Tasks1–3 acceptance; prototype ABI/error/status/host-selection and concrete
fixture/cleanup/runtime gates remain unaccepted. No runtime follows from it.

**New files/ownership:** proposed bounded directory
`Tests/SearchAdmissionServiceProcessIntegration/` with `SearchAdmissionServiceProcessTests.swift`,
`run_harness.py`, `test_runner.py`, `ProcessObserver.swift`,
`ProcessObserverBridge/include/ProcessObserverBridge.h`,
`ProcessObserverBridge/ProcessObserverBridge.c`, and new
`scripts/test-search-admission-service-process.sh`. The bridge is original test-only
C source, with the same bridge filenames first privately prepared in
`task-4-observer-api-prototype-drafts/` under generated C target ProcessObserverBridge
and executable ObserverABIProbe. No production hook or
existing helper/launcher/runner edit is authorized.

**Inputs:** actual public worker target PadSearchWorkerMain + actual
PadSearchWorkerRuntime/PadCore/SearchExecution, new facade; public manifest and
fixed helper location. **Outputs:** a matching tiny real public-helper/facade
protocol/artifact/process proof, separately labeled from injected construction.

### Step1 — Task4 observer supplement and separately reviewed prototype gates

- [x] Review/adopt this narrow supplement while retaining original spec/plan/design
   history. It replaces witnessed birth for the three ordinary-factory cases with
   exact sampled live parent/child PID/kernel-start identities, child PPID and
   helper path/declared-argv generation bracketed
   around acknowledged child kqueue exit registration, one nonconsuming exit event,
   genuine facade join and current post-join absence. No second wait/reaper, observer
   signal, production hook or convenient repeated discovery. Identity samples are
   not witnessed spawn, all history, continuous liveness or consuming-wait proof.
- [ ] Carry the timing limit into every classifier/receipt: last live sample and
   empty preflight queue precede actual async join entry but leave a gap; kevent
   supplies no exact exit timestamp here. Reject observed early exit without
   claiming no unseen gap exit or that join caused termination.
- [ ] First author/review original bounded C/header and Swift prototype/manifest
   sources, then Root proves exact imports/linkage/native ABI widths/alignment,
   child-count versus bytes, errno/absent-PID/path/argv contracts, acknowledgment
   versus termination flags and raw-status mapping. Proposed bounds: child65,
   argv16_384, SDK path maximum<=4096, event capacity2, queue1. Saturation/refusal/
   unknown flags/status fail, with no guessed constants or fallback. Declared
   argv3 validation must discard environment tail without decoding/hash/logging.
   Compile-only proof and installed headers do not establish syscall behavior;
   any controlled process probe needs separate exact source/cleanup/runner review.
- [ ] Review actual XCTest selection/launch syntax in that isolated gate. Bind the
   project-built test BUNDLE and helper to matching project source/build receipts;
   separately bind actual OS XCTest HOST executable path/bytes/mode/platform
   provenance. It may be platform xctest, not bundle Mach-O; no project-source
   requirement for platform host and no proc_pidpath substitution. Missing or
   unclassified host refuses; no arbitrary executable override or invented command.
- [ ] Preserve optional spawn/raw consuming-wait proof as a separately reviewed
   transparent actual-default-launcher operations companion, forwarding every call/
   result once unchanged. Its process/generation/receipts cannot fill the public
   case's missing observation. No expected exit0/signal9 is inferred from signal
   submission, request outcome or join; only reviewed actual raw-status mapping
   may classify observed termination. Final noChild cannot prove unseen history.
- [ ] The facade's consumer/job/lease IDs are opaque and do not expose wire requestUUID.
   The OS observer may bind PID/executable/argv generation. Associate the exact
   submitted test case through exact source/output plus this single owner's actual
   protocol chain; do not claim independent recovery of the wire requestUUID or
   add a production seam to obtain it. Record this limit even on a successful run.
- [ ] Author/review pure event/artifact/receipt discriminators and finite cleanup
   controls before launching actual worker. Missing parent/child identity, wrong
   helper bytes/argv generation, wrong submitted-case association, observed exit without genuine owned cleanup and late
   registrations must fail the evidence classifier. Record observer choice and
   measured proof boundary in the adopted plan supplement.
- [ ] Review the concrete observer executor and owner before execution: one retained
   serial Dispatch queue plus exact C-worker completion acknowledgment, no
   Task.detached blocking. Retain handles before starting; compute remaining timeout
   from the fixed absolute join-phase deadline at actual worker start, with no
   EINTR retry, fresh deadline or extension. Proposed delivery12s/registration1s/
   event2.5s-from-join-phase/owner20s-from-submit/outer60s limits do not preempt
   arbitrary blocked work or certify its return. Cleanup disables future producers/
   timer/executor registrations synchronously before its first await, joins all
   actual workers and the one retained normal-or-rescue service terminal owner,
   then consumes queue ownership for exactly one close requiring return0. Unknown
   close fails without retry; no FD-number nonreuse or post-close F_GETFD authority.
   Outer watchdog kill is infrastructure containment, not successful inner cleanup.

### Step2 — exact source/artifact build and three tiny actual tests

- [ ] Root coordinator freezes full actual recursive PadCore/SearchExecution/
   PadSearchWorkerRuntime/PadSearchWorker, Task1 facade and exact process fixture/
   observer/runner/common/watchdog/wrapper/manifest inputs. Generated test manifest
   is separately pinned; actual public manifest is unchanged provenance.
- [ ] Direct watchdog stages build actual public PadSearchWorker and matching
   test bundle from the identical inventory. Bind bundle/helper hashes/modes and
   complete project compiler receipts; separately bind actual platform XCTest host
   path/bytes/mode/provenance before execution. No private
   accumulator/echo/script/engine fixture can substitute for public worker code.
- [ ] Place only exact built helper bytes at the synthetic bundle's
   Contents/Helpers/PadSearchWorker; call the ordinary package factory with that
   bundle. No driver/timer/executable override; record original/built/copied helper
   pins before/after stage and reject symlink/extra source/manifest changes.

Required exact `SearchAdmissionServiceProcessTests` methods:

1. `testPublicHelperFindPreservesSupplementaryUTF16Ranges`: capture `A😀B😀`,
   UTF16 count6, literal pattern😀; actual result matches (1,2)/(4,2), replacementnil,
   exact source and Context/lease identity; release lease, actual typed join facts.
2. `testPublicHelperReplacementPreservesExactSourceAndOutput`: same source,
   replace😀 withΩ; exact `AΩBΩ` UTF16 count4, exact source, ranges and lease lifetime;
   close exact service and inspect actual immutable/current DTOs separately.
3. `testPublicHelperSemanticInvalidPatternDoesNotFallback`: regex `(` with tiny
   valid text/limits reaches actual worker semantic invalidPattern delivery,
   no lease; require real helper/process binding and no in-process fallback;
   actual typed joined cleanup preserves raw facts.

- [ ] Every test installs unconditional service/consumer/job/task/observer rescue
   before first setup suspension, with finite event registrations and no result-
   dependent cleanup. Requests use maxTextUTF166, maxOutputUTF166, maxMatches4,
   cooperativeMilliseconds1000 (existing valid SearchWireLimits), not large/adversarial
   regex or real files. No application window or input posting occurs.
- [ ] After genuine request/lease/borrow retirement require resident
   activeCharge == 1_048_576; retainedCharge/reservedRetainedCharge/retainedActiveJobs/
   retainedLeases/retainedParentLanes0 and actual admitted/acknowledged/closed/
   settled returned facts. Preserve immutable raw parent/child.cleanup separately
   from refreshed settlement; no fabricated generation/reap or accounting change.
   Clean exit cannot replace facade join and clean join cannot replace observation.
- [ ] Root runs exact3 selected methods with public-helper proof and all direct
   owned-process receipts. Require correct expected outputs, exact parent/helper
   artifact/source/argv-generation/process binding and declared submitted-case association, real exit/cleanup evidence,
   zero warnings/skips/deadlines, before/after membership/mode/hash/origin closure.
   An artifact mismatch, observer failure or cleanup failure preserves the run as
   infrastructure failure; never reinterpret it as success/behavioral RED.

### Step3 — final source/evidence review and bounded checkpoint

- [ ] Independently review Task4 actual artifacts/receipts versus source and
   observer limitations; keep injected facade6, native2, constructor4, compiler
   capability contracts and actual helper3 evidence separately labeled.
- [ ] Root runs matching neighboring/full tests and app build/public/format checks
   appropriate to the actual new source, records executed counts/commands/limits,
   then creates scoped local checkpoint after review. No remote publication.
- [ ] Write final status: tiny real facade/helper protocol proof only, not aggregate
   memory/RSS/adversarial regex acceptance, native routing/selection/quit correctness,
   packaged editor, GUI/macOS14/Intel runtime or async file reservation.

## Coverage and unresolved decisions

| V2 requirement | Concrete task |
| --- | --- |
| Fixed joined-only package facade and exact callbacks/IDs/DTOs | Task1 implementation + six focused tests + actual-facade mutants |
| No legacy terminal/controller/driver/override package capability | Task2 positive and five independent negative sibling compiler clients |
| Actual structural constructor, precise invalidURL/missing-helper mapping/no fallback | Task2 constructor4 plus source-traced fixed chain |
| Genuine callback refusal and live borrowed residual via facade | Task3 native2/macOS26 only |
| Actual fixed public-helper source/artifact/process proof | Task4 reviewed observer and real helper3 |
| Protected old bytes, matching inventories/receipts/cleanup | Every Root gate; Task0 before-inventory |
| No native activation/global budget/input/quit/memory claim | Scope exclusions and final checkpoint limits |

Assumptions: Task1 uses existing controller internal test seam and existing joining
driver with independent new fixture cleanup; public negative clients are same-
package sibling targets with normal import; generated manifests remain private
and do not change app floor. Scripted backend x/y is a forwarding proof only;
actual Unicode input/output proof occurs in Task4. Native immediate fixture has
the explicit separate26 host. Runtime ownership remains serial Root-only.

Task4 observer supplement selects a candidate bounded sampled-live-identity/
nonconsuming-exit boundary; its adoption, exact bridge/prototype ABI/error/status/
host-selection proof, concrete observer/fixture/cleanup sources and any distinct
transparent launcher companion remain reviewed gates before real execution. This is a
declared blocking gate for Task4 runtime, not permission to leave fabricated
commands or source hooks. It does not block authoring/review of the thin Task1
facade or Task2 constructor/API tests after V2 approval. No subsequent native-owner
or quit policy is selected in this plan.
