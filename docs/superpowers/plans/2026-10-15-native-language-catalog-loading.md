# Native catalog loading owner implementation plan

> For agentic workers: use superpowers:subagent-driven-development or superpowers:executing-plans within the existing autonomy authorization. Root owns execution; independent review remains required. Read the linked spec and its API first.

Goal: complete the narrow standalone production catalog read owner, with authentic Core reads, observable truthful state and joined invalidation.

Architecture: synchronous MainActor admission; one actual utility detached read; one weak-owner MainActor settlement task; private authentic receipt and immutable state. Explicit busy rejection, no queue. Future application/manager wiring stays separate.

Tech stack: existing Swift 6 toolchain, Swift 5 language mode, macOS 14 floor, Foundation/PadCore; no new runtime packages or assets.

Spec: [catalog loading owner](../specs/2026-10-15-native-language-catalog-loading.md), including its exact API, plus the unchanged custom-language design and nine-step plan.

## Global constraints and exact inventory

- Design review is accepted; test authoring, source implementation, actual execution and public source adoption remain separate states. Root exclusively owns compiler and GUI execution. No GUI is needed here.
- Preserve all existing Core and old test bytes. Never fabricate a LoadedLanguageCatalog, weaken checks, count compile failure as behavioral red, or claim task cancellation stops pread.
- Use only synthetic private temporary directories/files. No real profile catalogs, user documents, home paths or raw public logs.
- New source candidate: `.local/native-language-catalog-loader-source-20261015/NativeLanguageCatalogOwner.swift`; ultimate proposed production destination: `Sources/TheOnlyPad/NativeLanguageCatalogOwner.swift`.
- New tests: `.local/native-language-catalog-loader-tests-20261015/NativeLanguageCatalogOwnerTests.swift`; eventual retained destination after review: `Tests/NativeIntegration/NativeLanguageCatalogOwnerTests.swift`.
- Frozen private package: `.local/native-language-catalog-loader-tests-20261015/Package/`, with target `PadCore` copied byte-exact from actual `Sources/PadCore/*.swift`, target `NativeLanguageCatalogComponent` containing only this owner, and test target `NativeLanguageCatalogOwnerTests` containing only reviewed tests. macOS14, Swift5. Do not import the executable or incomplete private manager owner.
- Execution evidence root: `.local/native-language-catalog-loader-execution-20261015/`; independent baseline/green packages and build roots are separate subdirectories. Source/test manifests include original and frozen hashes, manifest/toolchain recipe, copied runner/watchdog bytes, SwiftPM build inventory, built test bundle identity, argv and complete watchdog receipts.
- No public manifest change, manager command, AppDelegate edit, private-owner promotion, public runner command or requirement-complete declaration is part of this source slice. A retained runner can be separately proposed once the actual recipe succeeds.

## Task 1: reviewed deterministic tests and authentic baseline

Consumes the exact declarations in the linked spec’s API section and actual Core load/save/codec interfaces. Produces tests, a compile-legal inert baseline solely for reached red, frozen input inventory and reviewed execution recipe. Any inert baseline is a disposable test instrument, never proposed production source.

- [ ] Author test source and minimal fixture helpers only. Fixture store uses a fresh synthetic temporary path; load/save to prepare genuine receipts off main. A closure can return only a receipt obtained by actual store.load, never an initializer or unsafe cast.
- [ ] Use a locked Sendable test gate around a synchronous read closure. Signal entry through XCTest expectation, wait only inside detached worker, release from MainActor/test cleanup, count read entry/maximum overlap under the lock, and throw configured synthetic error or call actual store.load. Each held gate has guaranteed release on every test exit, followed by explicit invalidation join. Never sleep/poll or semaphore-wait on MainActor.
- [ ] Write the following fourteen unique behavioral methods with reached ordinary assertions before dependent unwraps. Test names are exact proposed names; assertions below are the required bodies' behavior, not a claim tests exist.

| Method | Discriminating assertions |
| --- | --- |
| testConstructionIsLazyAndInitiallyUnconfirmed | Zero read invocations/notifications, active lifetime, all IDs/current/error nil. Observer installation emits no replay. |
| testDefaultStoreMissingCatalogPublishesGenuineEmptyReadWithoutCreatingDirectory | Real default store initializer; started ID matches loading/terminal; generation0 empty snapshot, nonnil publication, no created directory; actual join. |
| testDefaultStoreReadsPopulatedCatalogAndReadClosureRunsOffMain | Actual store.prepare/save makes generation1 Unicode definition + built-in override; default initializer reads exact persisted catalog. A fresh owner wrapping the same actual load records Thread.isMainThread false and exact same snapshot. State callbacks record main-thread true. Generation/revision/bytes remain unchanged. |
| testInitialLoadFailurePublishesFailureWithoutCatalogOrDiskMutation | Actual corrupt synthetic Profiles.json causes typed decoding error; loading then failed request identities, no fake empty catalog/publication, bytes/directory entries unchanged. |
| testFailedReloadKeepsLastConfirmedPublicationAndRetryClearsOnlyOnSuccess | First actual success, next controlled error, then held retry. Prior publication/source request/snapshot persist through failure and retry loading; failure request changes on failure and persists during loading; later successful read clears failure and rotates publication even for identical generation/bytes. Audit private receipt preservation separately. |
| testBusyRequestsDoNotLaunchQueueOrNotify | Hold first real read; subsequent request returns original busy ID, unchanged state/count. Release first; no queued second read appears. |
| testLoadingObserverReentryIsBusy | In actual loading observer synchronously call requestLoad; busy original request ID, one producer, one loading/terminal pair. No spawned Task is used to simulate synchronous reentry. |
| testLoadingObserverInvalidationPreventsActualReadLaunch | Loading observer directly calls invalidate. Outer request returns invalidated rather than started; read counter0, canonical invalidated state, cleared observer, no terminal callback; repeated invalidateAndWait returns. |
| testTerminalObserverSuccessorRetainsItsWorkerAndState | First actual terminal success observer synchronously starts and holds B. After A settlement returns, state active IDB/current A, busy refusal names B and read count2/max overlap1; A cleanup cannot clear B. Release B, fresh publication and exactly A/B transition pairs. |
| testTerminalObserverInvalidationCannotPublishAgain | Actual successful terminal callback directly invalidates; callback count does not grow, state immediately canonical invalidated, next request refused, private worker join completes; no old-frame write restores current/observer. |
| testInvalidationSuppressesLateSuccessAndFailure | Two independent held-read fixtures return actual success / synthetic failure after invalidate. Snapshot/current/error stay nil, observer never redelivered, no new admission; join returns only after release/real completion. |
| testInvalidateAndWaitYieldsMainActorUntilActualWorkerCompletion | Worker held; start join in MainActor Task and observe its started marker. Test main-actor heartbeat runs and sees invalidated state while join-completed flag false. Release gate; await join completion and assert actual read-completed flag, zero post-invalidation callbacks. No timeout is used to infer producer completion. |
| testCancelledJoinStillWaitsForActualWorkerCompletion | Same held worker; cancel only joining task after its started marker. Assert not complete while held; main-actor release then await join and actual completion. Cancellation does not start replacement or publish. |
| testRepeatedInvalidationJoinsAndObserverReplacementCannotReviveOwner | Two concurrent async joiners capture same held worker; repeated sync invalidate/observer assignments/request calls neither retain/replay observer nor admit I/O. Release once; both joiners complete, read count1, canonical state. |

- [ ] Review tests independently for false green guards, async scheduling assumptions, main-thread blocking, teardown, receipt provenance and exact old-Core preservation. Freeze before execution. No producer code authoring before test review.
- [ ] Prepare a compile-legal private baseline matching API declarations but doing no I/O/state publication, plus actual Core, in baseline package. This is explicitly discarded after behavioral red; never copy it to production destination. Compilation failure gets repaired and preserved separately.
- [ ] Root runs baseline under the direct accepted watchdog using the recipe below. Require ordinary reached assertions for state publication, failure truthfulness, busy/reentry and joining; record which assertions cannot discriminate until a predecessor behavior exists. Lazy construction/refused invalidated checks that already pass earn no red credit. Tests must terminate through fixture release even when baseline never enters worker.

## Task 2: minimal complete source and matching green

Consumes reviewed fourteen tests and actual CustomLanguageStore. Produces one complete source file implementing the spec’s API; no changes to Core, old tests or application consumers.

- [ ] Implement native immutable state/admission types and owner with two initializers, observer, requestLoad, invalidate and invalidateAndWait only.
- [ ] Implement request reservation → loading delivery → active/request fence → actual detached load + weak-owner settlement installation. Store both handles before returning started. Invalidation before launch returns invalidated.
- [ ] Implement exact-record retirement after real producer result, success-only receipt/publication install, error-preserving previous current, and terminal delivery as the final mutation boundary. No defer after notification may clear state/worker.
- [ ] Implement synchronous terminal invalidation, nonretaining post-invalidation observer setter, and async join of captured settlement. Do not cancel producer, block main, invent a timeout or add test-only runtime controls.
- [ ] Inspect source against all API invariants, especially weak self binding only after producer await, no caller receipt access, missing-store semantics and unchanged raw generation/revisions. Refactor only within the new source.
- [ ] Root freezes matching green source/tests/Core and runs same reviewed recipe. Fourteen unique tests must pass with no skips. No increased test count or one filtered success replaces failed original methods.
- [ ] Independently review source and actual evidence. Bind original→frozen source/test hashes, exact compile/link/bundle identity and complete owned-process receipts. Resolve material findings before adoption.

## Task 3: scope-preserving integration check and adoption decision

- [ ] Root places the reviewed owner in its actual production target on an isolated candidate, preserving all other files. Freeze full candidate with baseline Core/old test hashes, then build actual app/helper and run focused unchanged language/store/readback/revision/inspection/repair/transfer/selection compatibility plus existing full suite under the accepted watchdog.
- [ ] Lint new native source and tests with the established swift-format command; rerun affected tests after any formatter change. Rebind exact hashes rather than attributing an earlier run to edited source.
- [ ] Record planned/implemented/tested/unverified states separately. The public source may be adopted only after legal actual-target build and independent matching-source/evidence review; a source file compiling in an isolated module alone does not prove app-target legality.
- [ ] A scoped local commit can contain owner, reviewed retained test/runner only if its actual reproduction command has been adopted/executed, and sanitized evidence. No automatic activation or publication is authorized by this plan. A future read-only manager must subscribe to this real owner; later CRUD/recovery/quit requires a new reviewed authority design.

## Planned execution recipe (not executed or proven by this design)

Only Root executes. Freeze actual accepted watchdog and swift wrapper, then run each stage directly under that watchdog; never wrap a coordinator that already owns a session watchdog. The direct watchdog source is `scripts/run-owned-search-tests.py`; its CLI is the existing `--timeout --output -- command` contract. Use distinct baseline/green/integrated evidence directories.

Prospective focused green command, after the reviewed private package exists:

```sh
python3 scripts/run-owned-search-tests.py --timeout 180 --output .local/native-language-catalog-loader-execution-20261015/green-receipts -- scripts/swift.sh test --package-path .local/native-language-catalog-loader-tests-20261015/Package --scratch-path .local/native-language-catalog-loader-execution-20261015/green-build -Xswiftc -warnings-as-errors --filter NativeLanguageCatalogOwnerTests
```

Run analogous baseline command against its separately frozen baseline package/build. Root must first review package/recipe literal argv and capture paths; design text is not executed evidence. Test wait timeouts fail tests and trigger safe fixture teardown; they do not establish worker cleanup. Watchdog termination is incomplete test evidence, never a successful join.

Prospective actual app checks after source placement, each as a separate direct-watchdog stage with matching frozen package/root and unshared scratch path:

```sh
scripts/swift.sh build --scratch-path .build/native-language-catalog-owner-integrated -Xswiftc -warnings-as-errors
scripts/swift.sh test --scratch-path .build/native-language-catalog-owner-integrated -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict Sources/TheOnlyPad/NativeLanguageCatalogOwner.swift Tests/NativeIntegration/NativeLanguageCatalogOwnerTests.swift
```

The broad suite contains pre-existing adversarial regex cases and must use the watchdog. No new contributor command is claimed to work until runner adoption/execution. No windows, packaged run, physical keyboard/IME, accessibility or performance evidence follows from these commands.
