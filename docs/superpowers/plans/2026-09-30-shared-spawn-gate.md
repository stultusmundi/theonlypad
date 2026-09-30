# Shared Spawn Protection Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans, preserve compiling behavioral RED and obtain independent review after each implementation slice.

**Goal:** Prevent app-owned external commands from inheriting transient unprotected search pipe descriptors, including uncertain-close failure paths.

**Architecture:** One package-level PadCore gate coordinates short descriptor-protection regions and the two actual launch sites. Search's existing serial coordinator and descriptor cells keep ownership; the shared gate stores only monotonic unsafe-state refusal. Engine work, channel I/O, waits and asynchronous cleanup stay outside it.

**Tech Stack:** Existing Swift5-mode SwiftPM/macOS14, Foundation NSLock/Process, Darwin. No dependency or public product added.

**Spec:** `docs/superpowers/specs/2026-09-30-shared-spawn-gate.md`.

## Global constraints

- Exact ownership and once-only close authority are unchanged. Never retry an uncertain descriptor integer or reset shared poison.
- Fresh injected gate instances isolate deterministic tests; production defaults share `.process`.
- User documents, arbitrary executables and command strings are never test fixtures. Root alone executes reviewed actual-child cases under the accepted watchdog.
- No public lifecycle initializer, helper executable, accumulator, app routing or hard-regex completion claim follows from this slice.
- Never hold the gate across engine work, transport, waiting, channel adoption, completion callbacks or asynchronous cleanup. Short synchronous close calls settling newly created unprotected descriptors are required inside the gate.

## Task1 — Shared gate and both consumers

**Files:** create `Sources/PadCore/ProcessSpawnGate.swift`, `Tests/PadCoreTests/ProcessSpawnGateTests.swift`; modify `Sources/PadCore/ExternalCommand.swift`, `Sources/SearchExecution/SearchChildLauncher.swift`, and `Tests/SearchChildIntegration/SearchChildLauncherTests.swift`; add external-runner admission tests in its existing test target. Keep existing package targets unchanged.

**Interfaces:** package `ProcessSpawnGate.process`, fresh `init()`, `withCriticalRegion<T>((inout ProcessSpawnPermit) throws -> T) throws -> T`, `run(Process, unlessCancelled: () -> Bool = { false }) throws -> Bool`. Permit exposes only `quarantine(Int32)`; initialization/state remain fileprivate. `ProcessSpawnGateError.quarantined(Int32)` preserves first unsafe error. External command maps shared refusal to actionable `spawnSafetyUnavailable`; search maps it to `.launchFailed(error)`.

- [ ] Write compiling behavioral gate tests before implementation. A region setting poison then throwing must prevent a following region from setting an admission flag. A healthy throw must release the lock and permit a following region.

```swift
let gate = ProcessSpawnGate()
XCTAssertThrowsError(try gate.withCriticalRegion { permit in
  permit.quarantine(EIO)
  throw SampleError.expected
})
var admitted = false
XCTAssertThrowsError(try gate.withCriticalRegion { _ in admitted = true })
XCTAssertFalse(admitted)
```

- [ ] Implement lock admission and defer ordering. Acquire lock, reject existing poison before body, create permit, then defer copies first poison before unlock on every exit. `run(Process, unlessCancelled:)` checks the bounded private cancellation query in the admitted region and returns false without spawning if cancelled; otherwise calls `Process.run()` and returns true.
- [ ] Inject one gate into the search coordinator and external runner; default both to `.process`. External used/cancelled lock must be released before shared admission. Keep Process output/cancel/wait behavior after shared admission. Add a narrow internal launch seam only if deterministic consumer tests need it; real default must call the reviewed Process adapter.
- [ ] Add `closeOnExecConfirmed` to each search descriptor cell. Each raw pipe transaction acquires the gate before allocation, adopts both results, verifies each flag and records its fact. On any failure, consume close authority for both new cells inside the gate, then poison if any unprotected cell has uncertain closure. Preserve the outer search quarantine and diagnostic origin; later cleanup cannot retry consumed cells.
- [ ] Leave low-FD normalization outside the gate once both originals are protected; O_CLOEXEC/F_DUPFD_CLOEXEC results are protected by construction. Only verified-protected uncertainty must retain search quarantine without blocking Foundation launches.
- [ ] Gate the exact search spawn call separately, releasing before channel adoption. A poison arriving after setup but before spawn must refuse launch and clean already protected descriptors without fabricated PID authority.
- [ ] Add explicit overlap tests in both directions using entered/release signals and bounded waiters: raw pipe return blocks Foundation admission until both protections; active Foundation admission blocks raw pipe creation. Gate waiters must be released in failure cleanup; no sleep is the ordering oracle.
- [ ] Add each endpoint flag-failure/close-failure combination (including EINTR/EBADF/EIO), protected-only uncertainty, shared poison across fresh facades, error preservation, and launch refusal before allocation. Retain accepted ownership/ancillary-gate/startup tests.
- [ ] Run accepted frozen tests. Gate-only and poison-commit-only mutants must produce explicit failed assertions, not watchdog timeout. Restore source, rerun GREEN, verify manifests/strict receipts, format and independently review. Proposed commands use accepted watchdog directly for SwiftPM core filters and the existing self-owned harness for integration:

```sh
python3 scripts/run-owned-search-tests.py --timeout 120 --output .local/spawn-gate-core -- scripts/swift.sh test --scratch-path .build/spawn-gate --filter ProcessSpawnGateTests
scripts/test-search-child-lifecycle.sh --filter 'SearchChildLauncherStateTests|SearchChildLifecycleTests'
```

These output/scratch directories are illustrative first-run locations; use unique retained outputs and frozen actual source inventories. Do not nest another watchdog around `test-search-child-lifecycle.sh`. Existing external-command regressions require their accepted direct watchdog too. Root scopes commits only after review/evidence.

## Task2 — Actual Foundation peer overlapping protected helper launch

**Files:** add fixed peer source `Tests/SearchChildIntegration/SpawnPeerMain.swift` and `SearchChildSpawnInheritanceTests.swift`; update the same frozen integration coordinator's exact inventory and peer-binary receipt plus corresponding pure harness tests. Do not change the benign search fixture's accepted modes.

**Interfaces:** real search launcher and lifecycle share a fresh gate with the same `ProcessSpawnGate.run` adapter used by ExternalCommandRunner. A test-only decorator forwards actual launcher operations but holds return of the lifetime pipe operation before flag protection. Peer accepts no input payload: readiness marker, blocking stdin, exit0 on EOF,70 on data/error. Fixture binaries and complete source inputs are frozen/hash-bound.

- [ ] Write the synthetic peer and bounded owner fixture, then source-review before any process execution. The fixture signals Foundation's admission attempt outside the gate; it must remain excluded until protection. Do not let a test wait depend on a child that cannot yet spawn.
- [ ] Release setup, observe bounded readiness from both children, and retain the peer stdin writer while closing the helper's actual parent control connection. Require helper exit0, exact generation reap and channel closure while peer is still alive. Its ongoing lifetime distinguishes this from an ordinary sequential happy run.
- [ ] Only afterward close peer stdin; require normal exit0 and its one Foundation owner's wait. On every failure, settle exactly owned children/pipes; never raw-wait the Foundation PID or kill broad process groups outside the accepted watchdog.
- [ ] Root executes the separately filtered actual test using the accepted self-owned harness, then verifies stage receipts/source/fixture/test-bundle hashes and positive test count. Proposed command after runner support exists:

```sh
scripts/test-search-child-lifecycle.sh --filter SearchChildSpawnInheritanceTests
```

- [ ] Rerun pure harness controls and matching injected ownership/overlap/poison regressions. Record any platform behavior that already closes unknown descriptors without relying on it for application safety.
- [ ] Independently review, record matrix C-08 partial evidence and AGENTS/continuation commands, and commit the tested slice. Full helper/public factory/production routing remain separate.

## Root design review

Per-pipe protection was selected over holding the gate through all launcher setup/adoption: it keeps the accepted ownership handoff intact and minimizes exclusion. Search-only quarantine was rejected because it leaves the unrelated Foundation launch site active after unsafe cleanup. Permit poison is committed before unlock, including thrown bodies. Lock order is search serial lane→shared gate, never the reverse; control-lane signal/reap never acquires this lock. NSLock and Process.run do not imply a real-time spawn bound. This plan is reviewed design, not implemented or tested behavior.


## Independent review correction: deterministic contention oracle

An outside-gate “attempt submitted” signal alone does not prove the competing lane reached admission; scheduler delay can falsely preserve ordering even with a missing gate. Before releasing the held region, the test must observe actual contention on that same lock, or unexpected early body entry. A bounded test-level wait records explicit failed assertions if neither occurs; the outer watchdog is cleanup, not the intended red oracle.

Use a narrow optional test-only contention observer on a fresh package gate: production's default nil takes the normal `NSLock.lock()` path; an observed test path first tries the same lock with `try()`, calls the observer only after a failed try, then blocks on that same lock. A successful try already owns the lock and must not acquire twice. The observer only records/signals and must not reenter, wait or mutate gate ownership. It is not part of the public app API. The held owner releases only after the fixture distinguishes confirmed contention from early body entry; gate-removal mutation produces an explicit wrong-event assertion. A missing poison-commit mutation still produces a direct incorrect-admission assertion.

Real overlapping-child fixtures use this observation too; outside submission signals remain bookkeeping, never exclusion evidence. No timing sleep becomes an ordering oracle. Preserve default-nil production behavior and test both healthy/poisoned unlock paths.


### Additional Task1 cancellation regression

- [ ] Hold the shared gate, start ExternalCommandRunner, wait for its exact lock-contention observation, cancel it and release. Assert no fake Process.run call and the existing cancelled result with no PID or output. Capture behavioral RED for the missing query.
- [ ] Add the bounded internal cancellation query to the exact shared Process adapter; no public closure or state lock held through Process.run. Root reviewed lock ordering and the non-atomic post-query cancellation boundary in the spec. Rerun the complete core admission controls and preserve the original shared-poison priority.


## Task1 accepted component checkpoint

Implemented and independently reviewed2026-09-30. Core11/0, launcher/lifecycle/timer68/0, explicit lock/poison mutants and cancellation RED verified. Root actual external regressions6/0 and existing real launcher/lifetime3/0 also pass on matching frozen sources. See `docs/verification/shared-spawn-gate.md` for precise inputs and limitations. Task2 controlled real unrelated-peer overlap remains outstanding; no full search/helper claim.
