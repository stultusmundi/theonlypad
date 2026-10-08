# Production admission collaborators implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supply explicit logical admission accounting and cancellable asynchronous MainActor retries through the existing controller interfaces.

**Architecture:** Add two independent package collaborators; the existing controller/ledger owns queue, reservations and leases. Accounting computes bounded descriptor charges; Dispatch retry owns one cancellable action per returned token. Legacy terminal ownership and native routing remain a separate mandatory design.

**Tech Stack:** SwiftPM, Swift6 toolchain in Swift5 language mode, Foundation/Dispatch/XCTest, macOS14 deployment target, no external runtime packages.

**Spec:** `docs/superpowers/specs/2026-10-09-admission-production-collaborators-design.md`

## Global constraints

- Base accepted production construction commit `4841d89`; existing isolated worktree and new `feat/search-admission-production-collaborators` branch.
- SwiftPM, Swift6 toolchain in Swift5 language mode; macOS14 deployment target; no external runtime packages.
- activeLimit1,610,612,736; retainedLimit1,342,177,280; resident1,048,576. Active fixed65,536; retained fixed4,096; retry25,000,000ns.
- active=65,536+6*I+6*O+32*M+(I+8)/8+3*(Q+T); retained=4,096+3*I+3*O+16*M. O/T exactly0 for find; full I regardless of scope.
- I/output<=100,000,000; M<=100,000; Q/T<=4,096 UTF16. Exact conversion and checked arithmetic; no wrap/saturation/silent-zero fallback.
- No controller/driver/protocol/wire/worker/native/manifest changes, production test hooks, new ledger, scheduler registry or configurable unlimited defaults.
- Synthetic documents only; never commit raw diagnostics, home paths, real documents, credentials or buffers. Preserve unrelated changes and original assertions.
- Root alone owns serial compiler/runtime. Test/source/review agents are source-only, with explicit ownership; they are not alone and must preserve others' work. No visible GUI, real helper, descriptor or child process required for these components.
- Root records compiler RED separately from reached behavioral RED, freezes exact actual input bytes, runs direct owned watchdog without nesting, checks exact outcomes and resolves independent review before each gate.
- Legacy shutdown does not become joined service close. No physical allocation/RSS, hard-regex, performance, current desktop/IME/VoiceOver/Intel/macOS14-runtime or whole-product acceptance. No remote push/merge/release.

---

## Preflight and review

- [x] Root validates complete draft source pins and selected constants, reads spec/plan whole, self-reviews for scope/type consistency and placeholders.
- [x] Different reviewer reads actual protocols/ledger/controller/driver and both documents, reviews specification and quality source-only, and seals findings/pins. Resolve blockers before test authoring. BUILD_PROMPT waives repeated human approval ceremony.
- [x] Commit accepted spec/plan locally with public/whitespace checks; retain immutable review and private task ledger. Planned/implemented/tested/blocked remain separate.

### Task 1: Production charge model and admission budgets

**Files:**

- Create `Sources/SearchExecution/SearchAdmissionProductionAccounting.swift`.
- Create `Tests/SearchExecutionTests/SearchAdmissionProductionAccountingTests.swift`.
- Create the accounting/controller-budget portion of `Tests/SearchExecutionTests/SearchAdmissionProductionIntegrationTests.swift`.
- Read unchanged `SearchAdmissionTypes.swift`, `SearchAdmissionLedger.swift`, `SearchAdmissionController.swift`, `SearchWireTypes.swift`, `SearchWireUTF16.swift`, original admission tests/harness.

**Interfaces:**

- Consumes `SearchAdmissionAccounting` properties `activeLimit`, `retainedLimit`, `resident`, method `charge(for: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge`.
- Consumes immutable descriptor query/operation/estimatedInputUTF16/scope/limits; charge init(active:UInt64,retained:UInt64).
- Produces package `SearchAdmissionProductionAccounting: SearchAdmissionAccounting, Sendable`, `package init()`, package computed properties and package charge method. Internal helpers stay private.
- Existing controller budget tests use `AdmissionScriptedDriver`, `AdmissionManualRetry`, `SearchAdmissionController<String>` and its internal existing snapshot; no source visibility widening.

- [x] **1. Independent author writes meaningful literal tests before implementation.** Example actual empty find oracle:

```swift
let limits = try SearchWireLimits(
  maxTextUTF16: 0, maxOutputUTF16: 100_000_000,
  maxMatches: 0, cooperativeMilliseconds: 0)
let descriptor = try SearchAdmissionDescriptor(
  query: .init(pattern: "", mode: .literal), operation: .find,
  estimatedInputUTF16: 0, scope: nil, limits: limits)
let accounting = SearchAdmissionProductionAccounting()
XCTAssertEqual(try accounting.charge(for: descriptor),
  SearchAdmissionCharge(active: 65_537, retained: 4_096))
XCTAssertEqual(accounting.activeLimit, 1_610_612_736)
XCTAssertEqual(accounting.retainedLimit, 1_342_177_280)
XCTAssertEqual(accounting.resident, 1_048_576)
```

  Cover bitmap0/7/8/100M, supplementary Q/T UTF16, find ignoring maxOutput,
  replacement zero-output versus find, maxMatches0/positive, scope/full-input,
  query/template4,096, literal max charges615,777,825/301,604,096 and
  1,215,790,113/601,604,096. Build descriptors, not large source strings.
  Genuine malformed construction remains descriptor coverage, not impossible
  scalar-overflow execution. Preserve original UInt64.max ledger tests.

  Feed actual max charges into the ledger with production budgets: reserve,
  retain as a genuine `SearchResultLeaseID()`, repeat, then snapshot and refuse
  a third reservation without mutation. Use separate ledgers at exact and
  one-byte-short active and retained budgets; preserve counters on refusal.
  Idempotent release must return to resident only.

  Controller integration uses actual accounting with manual retry and scripted
  driver. Two consumers publish tiny `x`->`y` synthetic replacement results with
  genuine100M estimate/output ceiling and100k match cap. Retain both leases;
  a third consumer must get resultBudget before its capture is invoked.
  Borrow both prior leases and verify literal source/output/context, counters,
  refusal invariance and release to zero retained. This is conservative
  metadata-budget execution, not100M source/memory/helper acceptance.

- [x] **2. Root reviews tests; different reviewer approves SPEC/QUALITY.** Hash all
  new tests and original collaborators, preserve authored bytes before any
  formatting, and do not edit assertions to accommodate implementation.

- [x] **3. Root executes compiler RED, then a reached behavioral control.** Proposed
  focused public command, with fresh output/scratch paths or exact frozen package:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-accounting-red-owned -- scripts/swift.sh test --scratch-path .build/admission-accounting-red --filter SearchAdmissionProductionAccounting
```

  Missing type/API with0 executed methods is compiler RED only. A separately
  generated ignored implementation shell using valid wrong coefficients/defaults
  runs a bounded literal subset and must fail intended assertions without
  timeouts/unexpected errors. It may conform through existing protocols; never
  replace actual old sources or assertions to manufacture RED. Keep every
  generated input explicit, hashed and excluded from adoption.

- [x] **4. Source owner implements only the accounting file.** Checked helpers:

```swift
private func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
  let result = lhs.addingReportingOverflow(rhs)
  guard !result.overflow else { throw SearchAdmissionFailure.resultBudget }
  return result.partialValue
}
private func multiply(_ value: UInt64, by factor: UInt64) throws -> UInt64 {
  let result = value.multipliedReportingOverflow(by: factor)
  guard !result.overflow else { throw SearchAdmissionFailure.resultBudget }
  return result.partialValue
}
```

  Validate/exactly convert bounded dimensions; use prefix4,097 blob counts.
  Compute bitmap via checkedI+8, then divide8. Compose every term through the
  checked helpers, with the exact spec constants; invalid dimensions produce
  invalidDescriptor. Use no platform capacity guesses or raw-dimensions API.

- [x] **5. Root runs unchanged focused and accounting/controller tests GREEN.**

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-accounting-green-owned -- scripts/swift.sh test --scratch-path .build/admission-accounting-green --filter 'SearchAdmissionProductionAccounting|SearchAdmissionProductionIntegration'
```

  Verify frozen membership/bytes, exact started/passed method identities,
  no skips/warnings and complete direct watchdog receipt. Existing controller
  teardown must drain held scripted continuations, acknowledge settlement and
  release all leases; neither fake joined receipt nor infinite retry teardown.
  Separate source review checks actual formula/arithmetic/copy qualifications.
  Resolve blockers before next task; scoped code commit can follow final
  integrated evidence rather than claim whole checkpoint completion now.

### Task 2: Dispatch retry and concrete collaborator integration

**Files:**

- Create `Sources/SearchExecution/SearchAdmissionDispatchRetryScheduler.swift`.
- Create `Tests/SearchExecutionTests/SearchAdmissionDispatchRetrySchedulerTests.swift`.
- Add retry/actual-driver scenarios to the new `SearchAdmissionProductionIntegrationTests.swift`, preserving Task1's reviewed methods.
- Read unchanged controller retryID/inline defense and original scripted/actual-driver harnesses.

**Interfaces:**

- Consumes MainActor `SearchAdmissionRetryScheduler.schedule(_ action:@escaping @MainActor ()->Void)->any SearchAdmissionRetryToken`, `SearchAdmissionRetryToken.cancel()`.
- Produces MainActor package final `SearchAdmissionDispatchRetryScheduler`, package init and schedule; fresh private MainActor token per call, no internal timer access.
- Integration supplies `SearchAdmissionProductionAccounting()` plus actual scheduler through unchanged controller initializer. It may use current injected driver/system/channel/test gates; no process/helper/GUI.

- [x] **1. Independent author writes tests before source.** Real adapter ordering:

```swift
let scheduler = SearchAdmissionDispatchRetryScheduler()
let delivered = expectation(description: "actual retry after return")
var returned = false
var calls = 0
let started = DispatchTime.now().uptimeNanoseconds
let token = scheduler.schedule {
  XCTAssertTrue(returned)
  XCTAssertTrue(Thread.isMainThread)
  XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - started, 25_000_000)
  calls += 1
  delivered.fulfill()
}
returned = true
await fulfillment(of: [delivered], timeout: 2)
XCTAssertEqual(calls, 1)
token.cancel()
```

  Test cancel-before-delivery, repeated cancel, cancellation from callback,
  independent tokens and weak captured-context release on cancel/fire/token drop.
  For negative delivery, await a separately retained later uncancelled token's
  callback/main-queue sentinel, then assert cancelled calls0. No sleeps/spin loops,
  no production hooks, no reliance on an unfulfilled expectation to prove cancel.
  Keep token retained until verified delivery, as required by the actual API.

  Concrete controller integration starts scripted driver pending, submits a job,
  then makes settlement healthy and awaits actual retry-driven capture, exact
  lease delivery/borrow/release. Cancellation/unregister while pending must
  prevent capture after a later real scheduler turn. Use event gates and bounded
  async expectations, not timing loops. Drive at least one real parent codec
  output using current injected DriverHarness, literal wire source/output and
  generation-qualified session-release observation; use concrete accounting and
  scheduler, keeping original legacy settlement rules. Release gates in all
  failure paths; preserve prior Task1 methods/harnesses verbatim.

- [x] **2. Root and independent reviewer approve new tests.** Record author pins,
  unchanged prior tests/dependencies and MainActor/lifetime sensitivity before
  source implementation.

- [x] **3. Root records missing-API compiler RED and bounded reached RED.**

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-retry-red-owned -- scripts/swift.sh test --scratch-path .build/admission-retry-red --filter SearchAdmissionDispatchRetry
```

  Separate ignored inline scheduler shell must fail returned/call-order assertions
  in a finite method; a wrong cancellation shell must fail suppression after an
  actually delivered sentinel, not timeout. Never run unsafe infinite loops or
  let wrong transport call assumeIsolated from another queue. No assertion/source
  adoption change; Root names each reached mutation/control narrowly.

- [x] **4. Source owner implements only retry file.** Token stores optional action
  and DispatchWorkItem, queue captures token weakly, and queueing is only:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(25_000_000), execute: item)
```

  On main queue, `MainActor.assumeIsolated` invokes private fire. Fire extracts
  action, clears both references, then invokes. Cancel clears action first,
  extracts/clears item and calls item.cancel. Repeated cancel/delayed no-op entry
  is safe. No new strong cycle, registry, detached task or alternate transport.

- [x] **5. Root runs real adapter and both-collaborator integration GREEN.**

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-production-green-owned -- scripts/swift.sh test --scratch-path .build/admission-production-green --filter 'SearchAdmissionProduction|SearchAdmissionDispatchRetry'
```

  Confirm actual callback/method identities, frozen source inventories, complete
  owned receipt, clean teardown and no warnings/skips. Different source reviewer
  verifies fire/cancel ordering, weak capture, direct main-queue isolation and
  independence, preserving controller fencing and physical-release qualifications.

### Task 3: Integrated checkpoint and next terminal design

**Files:** Update `AGENTS.md`, `docs/continuation.md`, spec/plan, and create
`docs/verification/search-admission-production-collaborators.md`.

- [x] **1. Root runs neighboring admission/ledger/controller/parent/wire/resolver/
  collector selections, then fresh full public app/core.** Fresh ignored paths;
  exact frozen source snapshots are permitted and must be bound explicitly:

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/admission-production-full-owned -- scripts/swift.sh test --scratch-path .build/admission-production-full
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
git diff --check
```

  Both app and helper must link in public build; no actual helper execution or
  new packaged desktop claim follows. Do not repeat successful checks without
  new changes/failures/concerns. These output directories must be fresh because
  the watchdog refuses overwriting earlier evidence.

- [x] **2. Record exact APIs/budgets/formula, tests and meaningful failures.**
  Separate source facts from finite actual callback/injected integration results.
  Preserve compiler RED, reached RED and harness setup failures separately;
  record exact limits/no memory/native/terminal acceptance. Current package
  remains the previous4841d89 source snapshot unless rebuilt/tested separately.

- [x] **3. Independent final SPEC/QUALITY evidence review.** Different reviewer
  reads complete source/reports/inventories/receipts/captures, checks original
  tests unchanged, all new identities and public states. Resolve every blocker.
  Root rechecks current tested pins/public/diff and commits exact scoped files
  locally. No pushes/merges/releases. Continue mandatory joined terminal-owner
  design before production controller/native activation; milestones do not end
  the authorized continuous build.

## Current execution checkpoint

Tasks1/2 are implemented and independently source-reviewed. Root actual focused
23/0, frozen neighboring357/0 and fresh public app/core962/0 pass, with complete
owned-watchdog receipts and unchanged input inventories. Independent final evidence
review approves the scoped local commit. Detailed preparation/RED/GREEN histories
are recorded in the verification document; no native/helper/terminal/RSS claim.
Root also corrects the current requirements-matrix header using a literal row
recount (67partial/9outstanding), preserving historical counts and all row states.
This is an additional documentation-only scope item for final review.
