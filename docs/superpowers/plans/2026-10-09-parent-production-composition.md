# Fixed production parent composition implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development task by
> task with independent specification/quality review. Root owns all compiler,
> helper, package and GUI execution; source agents never execute them.

**Goal:** Supply a fixed bundled-helper constructor for the existing parent
driver and prove its ordinary and observed shared-recipe paths separately.

**Architecture:** A package convenience initializer delegates to one internal
recipe over existing launcher/clock/timer/observer contracts. It selects explicit
operational defaults and the production response collector. No new service
owner or native activation is included.

**Tech Stack:** Swift5 language mode, Swift6 toolchain, macOS14 deployment,
Foundation/Dispatch, original MIT; no external dependency.

**Spec:** docs/superpowers/specs/2026-10-09-parent-production-composition-design.md.

## Global constraints

- Base collector `ab5360f`; reuse the existing isolated worktree and preserve
  unrelated main-checkout changes. No remote push, merge or release.
- Operation10,000,000,000ns; reap grace2,000,000,000ns; idle10,000,000,000ns;
  eight completed requests per child; completed-I/O retirement268,435,456bytes.
- The wire threshold includes handshake/stream completions, permits an active
  request to exceed it and is neither a payload nor RSS limit.
- Bundle URL only: no executable/env/PATH/shell/chooser/fixture arguments.
- Resolve structurally during construction; final-entry filesystem validation
  and spawning remain on the existing preparation lane after deadline arming.
- No collector/wire/driver/lifecycle/launcher/admission/native source edits;
  retain existing injection APIs and every original regression assertion.
- Root directly invokes the accepted watchdog; never nest the helper coordinator
  under another session-owning watchdog. Synthetic fixtures only.
- Ordinary constructor's logical receipt exposes no PID/signal/reap counters.
  Five observed cases retain all exact child diagnostics; never transfer those
  counts to the ordinary path. No hard-regex/physical-release/memory/UI claim.

### Task 1: Fixed construction and deterministic/package-access behavior

**Files:**

- Create `Sources/SearchExecution/SearchParentWireDriver+Production.swift`.
- Create `Tests/SearchExecutionTests/SearchParentProductionTests.swift`.
- Create `Tests/SearchExecutionTests/SearchParentProductionPackageAccessTests.swift`.

**Interfaces:**

- Consume existing SearchChildSystem, SearchChildTimer, SearchChildPolicy,
  SearchWorkerBundleResolver, SearchParentResponseAccumulator and injected
  SearchParentWireDriver initializer unchanged.
- Produce the package `SearchParentWireDriver(applicationBundle: URL) throws`
  and internal collaborator overload with applicationBundle/system/now/schedule/
  observe signatures from the spec. Produce internal
  `SearchParentProductionPolicy.childPolicy() throws -> SearchChildPolicy` and
  `maximumWireBytesPerChild: UInt64`.

- [ ] Independent design review resolves API/default/lifetime/test feasibility.
- [ ] A different test author derives independent literal oracles before code.
  A minimum policy test reads the actual recipe:

```swift
let policy = try SearchParentProductionPolicy.childPolicy()
XCTAssertEqual(policy.operationNanoseconds, 10_000_000_000)
XCTAssertEqual(policy.reapGraceNanoseconds, 2_000_000_000)
XCTAssertEqual(policy.idleNanoseconds, 10_000_000_000)
XCTAssertEqual(policy.maximumRequestsPerChild, 8)
XCTAssertEqual(SearchParentProductionPolicy.maximumWireBytesPerChild, 268_435_456)
```

  Use the existing injectable contracts to test malformed bundle URL refusal,
  normalized fixed candidate, no launch/timer during construction of a missing
  bundle, deadline armed before launch, exact Unicode output through real codec,
  operation deadline and reap-grace refusal, ten-second idle expiry and eight
  terminals then next-generation ninth request. Never allocate256MiB merely to
  hit the constant: use original reduced-threshold counter/driver mechanics and
  explicitly separate value selection from retirement mechanics. Existing
  failure/quarantine/receipt assertions remain unchanged.

  The ordinary package-access test uses no @testable import or private extension:

```swift
import Foundation
import SearchExecution
import XCTest

let syntheticMissingBundle = FileManager.default.temporaryDirectory
  .appendingPathComponent("TheOnlyPadMissing-\(UUID().uuidString).app", isDirectory: true)
let driver = try SearchParentWireDriver(applicationBundle: syntheticMissingBundle)
guard case .completed(let receipt) = await driver.shutdownJoined(after: nil) else {
  return XCTFail("Expected actual joined owner completion")
}
XCTAssertEqual(receipt.ownership, .admitted)
XCTAssertEqual(receipt.laneStop, .acknowledged)
XCTAssertTrue(receipt.shutdown.child.stopped)
XCTAssertTrue(receipt.shutdown.child.channelsClosed)
XCTAssertEqual(receipt.shutdown.child.cleanup, .noChild)
XCTAssertTrue(receipt.shutdown.parentLaneSettled)
XCTAssertEqual(receipt.shutdown.retainedParentLanes, 0)
```

  Tests must always call real joined shutdown on constructed drivers, including
  assertion/throwing failure. No silent pending receipt, thread sleep or timeout
  skip is accepted as success.
- [ ] Root freezes actual sources/tests and records missing-API compiler RED
  separately. A second ignored generated extension uses deliberately wrong
  policy literals/eager missing-bundle refusal with existing injection APIs for
  behavioral RED. Preserve original literals and all already-passing controls;
  never adopt the generated shell or change production sources for this baseline.
- [ ] A single source implementer writes the shared recipe after RED:

```swift
extension SearchParentWireDriver {
  package convenience init(applicationBundle: URL) throws {
    let timers = DispatchQueue(label: "TheOnlyPad.search-parent.timers")
    try self.init(
      applicationBundle: applicationBundle, system: SearchChildLauncher(),
      now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { SearchChildDispatchTimer(deadline: $0, queue: timers, action: $1) })
  }

  convenience init(
    applicationBundle: URL, system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> any SearchChildTimer,
    observe: (@Sendable (SearchParentDriverEvent) -> Void)? = nil
  ) throws {
    let candidate = try SearchWorkerBundleResolver.candidate(in: applicationBundle)
    let lifecycle = try SearchChildLifecycle(
      executable: candidate, policy: SearchParentProductionPolicy.childPolicy(),
      system: system, now: now, schedule: schedule)
    try self.init(
      lifecycle: lifecycle,
      accumulatorFactory: { SearchParentResponseAccumulator(request: $0) },
      maximumWireBytesPerChild: SearchParentProductionPolicy.maximumWireBytesPerChild,
      observe: observe)
  }
}

enum SearchParentProductionPolicy {
  static func childPolicy() throws -> SearchChildPolicy {
    try SearchChildPolicy(
      operationNanoseconds: 10_000_000_000,
      reapGraceNanoseconds: 2_000_000_000,
      idleNanoseconds: 10_000_000_000,
      maximumRequestsPerChild: 8)
  }
  static let maximumWireBytesPerChild: UInt64 = 268_435_456
}
```

  The same file defines childPolicy using the five exact operational settings
  above and the existing throwing policy constructor, never try! or fallback.
  Imports are Foundation and Dispatch. The scheduler captures its queue directly,
  not self. No files are opened, launched or preflighted here.
- [ ] Root executes focused GREEN under the direct watchdog, verifies exact
  frozen membership/hashes/receipts and gets independent source review. Proposed
  public reproduction filter (frozen runs supply absolute package/scratch paths):

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/parent-production-focused -- scripts/swift.sh test --scratch-path .build/parent-production --filter SearchParentProduction
```

### Task 2: Ordinary constructor and observed real-helper recipe

**Files:** Modify only `Tests/SearchWorkerIntegration/RealSearchWorkerTests.swift`,
`Tests/SearchWorkerIntegration/run_harness.py` and
`Tests/SearchWorkerIntegration/test_runner.py`.

**Interfaces:** Consume Task1 package constructor and internal collaborator
overload; produce new packaged-only `production-defaults` selection plus explicit
ordinary/observed evidence scopes. Reuse the accepted artifact verifier and sole
direct-watchdog coordinator.

- [ ] Test author adds pure runner controls before validator/selection changes:
  new case without application bundle refuses before setup; default built selects
  the unchanged five; default packaged selects six; ordinary cleanup cannot
  masquerade as observed PID/reap/signals; malformed/missing logical cleanup and
  scope records refuse. All original pure assertions remain unchanged.
- [ ] Root executes discriminating pure RED, preserving wrong-selector/no-new-API
  setup outcomes separately from assertion failures. No helper is launched by
  these pure cases.
- [ ] Source owner updates the original five harness's packaged construction
  using the shared recipe and actual ObservedHelperSystem/clock/timers/observer:

```swift
let authenticatedBundle = URL(fileURLWithPath: try XCTUnwrap(artifact.applicationBundle))
driver = try SearchParentWireDriver(
  applicationBundle: authenticatedBundle,
  system: ObservedHelperSystem(observations: observations, fragment: fragment),
  now: { DispatchTime.now().uptimeNanoseconds },
  schedule: { SearchChildDispatchTimer(deadline: $0, queue: timers, action: $1) },
  observe: {
    if case .sessionReleased(let generation) = $0 {
      observations.update { $0.released.append(generation) }
    }
  })
```

  Preserve built-mode injected construction explicitly, because its fixed
  executable is not a bundle. Preserve every literal/source/UUID/ordinal/live
  PID/pre-result signal/reap/strict joined cleanup assertion. Add a sixth actual
  method calling only `SearchParentWireDriver(applicationBundle:)`, which covers
  literal supplementary find, regex capture replacement, semantic error and
  subsequent same-generation healthy request with independent exact oracles.
  Use unchanged artifact verification before/after and always real joined close.

- [ ] Validator distinguishes the ordinary summary's generation and actual
  ownership/acknowledgement/stopped/channels/noChild/settled/zero-lane facts from
  observed exact PID/signal/reap rows. It never fills missing counters or emits a
  synthetic PID. Original five validators remain strict and source/artifact/test
  bindings apply to all six. Reject ordinary selection without an authenticated
  bundle rather than skip or invent one from a standalone executable path.
- [ ] Root runs pure GREEN, independent helper/runner source review, local fresh
  package and all six actual final nested methods. Validate each selected XCTest
  identity/count, all direct-watchdog stages and whole source/helper/test-bundle
  bindings. The five observed shared-recipe cases and one ordinary case are
  distinct evidence records. Proposed actual invocation uses the existing runner:

```sh
scripts/package.sh --ad-hoc-sign
scripts/test-search-worker.sh --application-bundle "$PWD/dist/TheOnlyPad.app"
```

### Task 3: Integrated checkpoint and continuation

**Files:** Update `AGENTS.md`, `docs/continuation.md`, this spec/plan and create
`docs/verification/search-parent-production-composition.md`.

- [ ] Root runs the relevant composition/resolver/lifecycle/driver/codec/admission
  selectors on exact frozen inputs, then a fresh public app/core build/test:

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/parent-production-integrated-owned -- scripts/swift.sh test --scratch-path .build/parent-production-integrated
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

- [ ] Record exact policies/commands/pins, genuine ordinary-versus-observed
  scopes, actual failing histories, limitations and planned/implemented/tested/
  blocked states. No RSS/hard-regex/GUI or native routing inference.
- [ ] Independent final SPEC/QUALITY evidence review resolves findings. Root
  rechecks tested inputs/public/whitespace, makes a scoped local commit and
  continues admission accounting/retry ownership before native activation.
