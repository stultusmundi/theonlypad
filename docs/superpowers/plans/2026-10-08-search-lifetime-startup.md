# Checked search parent-lifetime startup implementation plan

> For agentic workers: use superpowers:subagent-driven-development for scoped source tasks and independent SPEC/QUALITY review. Root exclusively owns serial runtime.

**Goal:** Start the dedicated parent-loss watcher with checked thread-creation/cleanup outcomes and fail worker admission when startup fails.

**Architecture:** SearchExecution hosts package startup with detached pthread attrs, a retained immutable fd/body context and a consuming C trampoline. The worker Program's throwing startup seam refuses70 before input work; the existing busy-main fixture exercises actual startup.

**Tech Stack:** Darwin/Foundation/XCTest; macOS14; Swift6 toolchain in Swift5 mode; no external dependencies.

**Spec:** `docs/superpowers/specs/2026-10-08-search-lifetime-startup-design.md`

## Global constraints

- Root exclusively owns real process/compiler/GUI tests; synthetic fixtures only.
- Borrowed blocking lifetime descriptor; no FD close/duplication, signals/reaper, join/cancel/retry or readiness semaphore.
- Detached attr before create; exactly one context retain; success transfers even if callback finishes first; failure reclaims exactly once.
- Preserve primary pthread error plus optional attr-cleanup code; failed init never destroys; successful create cleanup failure has threadCreated=true and is fatal to Program.
- No helper product/editor/RSS/desktop or minimum-OS-runtime claim; keep macOS14 floor and Swift5 mode.

## Task1: Checked starter and Program admission

Files: create `Sources/SearchExecution/SearchParentLifetimeStarter.swift`, `Tests/SearchExecutionTests/SearchParentLifetimeStarterTests.swift`; modify only starter parameter/catch in `Sources/PadSearchWorkerRuntime/SearchWorkerProgram.swift`; append tests to `Tests/PadSearchWorkerRuntimeTests/SearchWorkerProgramTests.swift`.

Interfaces: exact package/internal types and error fields in the spec; new package `SearchParentLifetime.start(controlFD: Int32) throws`; internal overload takes operations/run; Program callback becomes throwing and returns70 on any error.

- [x] Write deterministic tests against real retained context/C trampoline with literal pthread error codes and exact call order. Example behavior:

```swift
let fault = SearchParentLifetimeStartError(
  stage: .creation, code: EAGAIN, attributeCleanupCode: nil, threadCreated: false)
// A failed create must not enter body, must release its actual context,
// and must destroy initialized attrs exactly once.
```

The test operations capture a weak actual context during create and body checks absence before execution. Cover the finite schedules and failures listed in the spec; all expected errors/calls are independent literal fixtures. Test-only helpers remain in Tests.

- [x] Root observes missing-interface compiler RED, adds only a minimal compiling shell, then observes behavioral RED. Program throwing-signature mismatch is compiler evidence; missing error containment must have an executable failing assertion before final catch. Root commands run through direct `scripts/run-owned-search-tests.py --timeout 240 --output <fresh ignored directory> -- scripts/swift.sh test --scratch-path .build/lifetime-startup --filter 'SearchParentLifetimeStarterTests|SearchWorkerProgramTests'`.
- [x] Implement negative validation, attrs init/detach/cleanup, retain/create/transfer/reclaim, static C trampoline and explicit prebody context ownership end. Actual Darwin operations call pthread APIs with returned-code semantics and PTHREAD_CREATE_DETACHED. No extra host-lifetime manager.
- [x] Change Program starter to throwing; catch only this setup boundary and return70 before reader work. Root reruns focused GREEN, then existing SearchWorker/parent lifetime regressions, with complete source and owned-command receipts.
- [x] Independent reviewer checks actual sources, finite tests, context ownership and error precedence. Resolve important findings before fixture activation.

## Task2: Frozen harness and actual independent lifetime

Files: modify only busy-main block in `Tests/SearchChildIntegration/FixtureMain.swift`; add exact starter test input in `Tests/SearchChildIntegration/run_harness.py`; update corresponding synthetic inventory fixture/control in `Tests/SearchChildIntegration/test_harness.py`.

Consumes: package starter from1, original existing busy-main mode and real lifecycle test. Produces: frozen package includes actual starter+tests; actual occupied-main test runs production startup without semaphore.

- [x] Write pure inventory controls proving exact new test source is mandatory and frozen. Root runs `python3 -m unittest discover -s Tests/SearchChildIntegration -p 'test_*.py'`; baseline refusal precedes harness modification.
- [x] Replace fixture startup exactly:

```swift
do { try SearchParentLifetime.start(controlFD: 3) }
catch { refuse() }
```

Preserve following readiness metadata, main-loop body and all other fixture modes.
- [x] Root runs harness deterministic starter/lifetime/launcher/timer selection and then explicitly selects `SearchChildLifetimeProcessTests` with fresh source/fixture/bundle hashes under its own watchdog. Preserve exact exited0 consuming reap/channels cleanup; do not wrap the harness in another watchdog.
- [x] Root runs shared-spawn peer regression when source inventory changed. Independent review checks fixture/harness delta and actual evidence scope; no benign helper search claim.

## Task3: Integrated evidence/local checkpoint

Files: add `docs/verification/search-lifetime-startup.md`; update AGENTS, continuation, spec/plan states.

- [x] Root full app/core test under owned watchdog600s, strict format lint, public-source and staged-diff checks. No platform, GUI or memory success inferred.
- [x] Record compiler/behavioral failures, deterministic/actual process results and scope limits separately; preserve ignored raw evidence.
- [x] Scoped local commit; continue helper entrypoint/product/packaging. No remote publication/merge/push and no stop at this checkpoint.
