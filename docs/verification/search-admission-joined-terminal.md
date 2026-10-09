# Search admission joined terminal verification

Checkpoint: 2026-10-09. The joined terminal owner is implemented and Task 1 has independent SPEC/QUALITY/evidence approval. The current Task 2 driver/native/runner checks and fresh public-package regressions pass. Both required native mutation controls reached their intended assertion failures with genuine cleanup. Task 2 has independent SPEC/QUALITY/evidence approval. Final integrated specification, quality, evidence, documentation and privacy review approves the scoped checkpoint. The local commit remains pending. This record does not mark feature or application acceptance complete, and records no final source commit.

The [design](../superpowers/specs/2026-10-09-admission-joined-terminal-design.md) and [implementation plan](../superpowers/plans/2026-10-09-admission-joined-terminal.md) define this component boundary. Search service composition and editor search routing remain separate work.

## Implemented ownership and observations

`SearchParentWireJoining` extends the unchanged Driving protocol with the parent's existing `shutdownJoined(after:)` capability. The concrete parent declares that conformance without changing its lifecycle/codec mechanics. The admission controller adds `shutdownJoined()` and explicit `callerRefused` or `observed` results. An observation embeds the original parent result unchanged and separately reports current driver settlement, retained jobs/leases and actual ledger charges. It is not a success certificate: original caller/ownership refusal, failed lane acknowledgment or uncertain child cleanup cannot become admitted cleanup through a later current query.

Synchronous callback refusal precedes mode selection and mutation, including repeated callers. Legacy-first joined entry refuses; unsupported drivers refuse without closing admission or consuming state. Accepted joined selection installs one retained command before reentrant close callbacks. Matching callers share it; initiating or matching caller cancellation does not cancel that owner. Close immediately fences queued capture, completion, publication and retry progress.

The retained command awaits genuine preparation/request, exact cancellation and already-running inspection helper returns, including a late submit handle and callbacks that cleared a progress slot before their stack returned. It preserves the sole existing waiter and its real consumption. Only then does it pass the actual final handle to the parent join. There is no competing waiter, discarded receipt, invented handle or prewait for idle-session absence: the parent join owns closing and draining that idle read.

After the parent returns, a bounded current query refreshes admission facts. Concurrent callers coalesce an in-flight query; a later explicit call can observe later progress. Query errors report pending. Active reservation retirement requires actual helper returns, original admitted ownership/acknowledged lane/settled parent lane, and current settled admissionClosed=true. Captured/provisional payload clearing genuinely returns before ledger abandonment and Job removal. During genuine destruction, a synchronous public-ledger read retains active6/reserved3/reservation1 under the tiny test accounting; a queued caller later sees jobs0/active2/reserved0 after the outer clearing scope returns. Recursive async terminal execution during destruction remains an unproven reachability hypothesis; no private retirement guard is introduced or claimed necessary.

An actual result borrow has a different boundary. Close invalidates the lease but retains its payload and credit until the genuine outer `withResult` helper returns. Two joined observations can therefore return while the borrow is live with lease1/retained3; legacy-afterjoined also projects the exact original completed parent's shutdown receipt. After actual borrow return, weak Context death and retained0 are observed; earlier value snapshots stay lease1/retained3. Resident transport remains charged for the ledger lifetime.

Legacy-afterjoined reuses the same retained command and completed parent receipt. For deliberately shared-parent caller refusal, the refusal stays raw; the historical legacy API caches one genuine exceptional `driver.shutdown()` return through the parent's already selected authority. It does not fabricate a receipt, convert modes or create another signal/reap owner. The actual externally legacy-selected case compares this controller's cached alias, without assuming it must equal another caller's earlier bounded snapshot.

## Executed selections and overlapping counts

These counts describe separate selections of matching frozen inputs. They must not be added as independent coverage totals.

| Selection | Result | Scope and overlap |
| --- | --- | --- |
| Prior joined component selection | 27 passed, 0 failures | Scripted actual-controller mode/ownership/return/credit tests. |
| Prior neighboring component selection | 384 passed, 0 failures | Includes those same 27 joined tests; reused matching Task 1 evidence, not a fresh rerun. |
| Actual controller/parent/codec selection | 4 passed, 0 failures | Actual parent/lifecycle/codec with injected process/channel collaborators; also included in the fresh 496 and full 993 selections. |
| Fresh public-package neighboring selection | 496 passed, 0 failures | Includes joined 27 and actual-driver 4, plus parent/wire/worker/admission regressions. |
| Fresh corrected full public-package snapshot | 993 passed, 0 failures | Includes joined 27 and driver 4. Actual `TheOnlyPad` and `PadSearchWorker` products linked; this build does not establish a helper launch or routed search. |
| New hidden native runner | 10 passed, 0 failures | Eight admission cases plus the two previously accepted retirement ordering cases; the earlier separate native2 GREEN is not ten additional tests. |
| Unchanged old native runner | 3 passed, 0 failures | Original three native borrow tests and their original runner remain bytewise unchanged. |
| New runner pure checks | 52 passed, 0 failures | Synthetic source inventories/logs/receipts and host rejection; no Swift/AppKit/runtime execution in these Python tests. |

The accepted Swift/native selections reported zero compiler warnings and zero skipped tests. Exact source membership, bytes/modes/origins, unique named XCTest starts/passes and complete direct watchdog wait/capture/cleanup receipts were checked. Hidden native and Python selections run separately from the ordinary 993-test suite; they are not added to that public Swift count.

The four actual-driver cases cover a never-admitted owner, an independently held cancelled idle-read return after physical cleanup, active request cancellation with the sole waiter/final exact handle, and preserved externally selected legacy refusal. The held-read case requires genuine matching sessionReleased before joined observation; physical close and the synthetic consuming reap alone cannot substitute for read-loop return. Supplementary Unicode and tiny genuine wire frames are bound to actual request identity. Process/channel operations remain injected; no new actual helper process is exercised.

The native ten comprise a Timer-owned live borrow; capture, accounting, completed delivery, genuine worker observer, retry schedule, retry cancel and inline-failure cancel refusals; and two genuine provisional Context destruction ordering cases. Each uses real AppKit target/action and modalPanel run-loop entry. Seven refusal cases use public `Task.immediate` to enter the actual guard before the synchronous callback returns. Their isolated test package/host requires macOS 26 and Swift 5 mode, and rejects older hosts explicitly without skips. This test-host requirement does not raise the public app/package's macOS 14 floor. It does not establish Intel or macOS 14 runtime behavior.

## Reached controls, corrections and pending gates

The earlier frozen credit-before-clear control ran the two retirement methods and reached 18 intended failed assertions, nine per method, at actual live modal/destructor ledger reads and the retained immutable snapshot. It had zero emergency, phase, trace, unexpected-cleanup or compiler-warning failures. Unchanged production subsequently passed both ordering tests. This validates the supported payload-clear-before-credit ordering, without proving nested async destructor reentry.

The actual-parent held-read mutation omitted the parent's mechanical read-owner drain await in a frozen copy. One method reached two intended assertions: parent join returned prematurely while the real read-return gate remained held, and its immutable parent-lane receipt was unsettled. The actual gate was then opened; matching session release and complete fixture cleanup returned. There were zero unexpected, deadline, cleanup or compiler-warning failures. Accepted production remained unchanged.

The whole-capture guard-removal control selected all ten native methods. Capture and accounting each reached seven intended failed assertions, 14 total; the other eight methods passed. The required witnesses were failure to refuse during immediate construction and a real public shutdown refusal replacing consumerBusy. The loop stopped on that actual public mutation boundary; no fictitious worker was awaited when close occurred before worker installation.

The premature borrowed-credit-release control also selected all ten methods. Only the live-borrow method failed, with 15 intended lease/retained-charge assertions; the other nine passed. Actual joined and legacy observations returned during the genuine outer borrow, exposing early credit return. All retained tasks, preparation/worker/observer/forwarded scopes and native fixture cleanup returned. Both controls had zero warnings, emergency, deadline, unknown or cleanup failures and complete actual toolchain/test watchdog receipts. Only copied controller code was mutated; current production and every test remained unchanged.

Task 2 and final whole-branch review are independently approved. The local commit remains pending; no requirement acceptance row is promoted by these component results.

Earlier unsuccessful attempts remain historical:

- The original async-destructor native recipe ran two methods with 30 failed assertions and 17 explicit-self warnings, stopped once by an emergency in each case, and showed destructor return/outer return before the queued inner request began. It is preserved infrastructure failure, not behavioral RED. The asserted recursive reachability blocker was withdrawn; requirements were corrected to synchronous live ledger and genuine later queued results. Production was not changed to add a retirement guard.
- The first native admission draft failed independent source review because its delivery metadata probe cancelled a new Job on the original consumer, releasing that consumer's original published lease. The corrected probe uses a fresh isolated consumer and deferred cleanup; original live lease/credit/weak and actual result-borrow checks remain intact. The rejected draft was never executed.
- The first private actual-driver draft also failed source review and was corrected before runtime. Its rejected expectations and review remain preserved; they are not passing evidence or witnessed production defects.
- The first full snapshot started 993 tests and had one failure because Root's fixture omitted the actual bundled example manifest. The production and original test were unchanged. A fresh corrected snapshot included that exact example in its package layout and passed 993/0. The earlier 993/1 run remains infrastructure history rather than being relabeled a test pass.

## Commands and evidence handling

Executed public native/Python entry points:

```sh
env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/SearchAdmissionJoinedNativeIntegration -p 'test_*.py' -v
scripts/test-search-admission-joined-native.sh
scripts/test-search-admission-native-borrow.sh
```

Each native coordinator freezes its declared inputs and owns direct supervision. Invoke it directly; never put another session/process-group watchdog around it. It refuses arbitrary filters and requires every declared native method.

The component/public Swift counts above were executed through Root-owned exact frozen packages. For a fresh public-worktree reproduction, use the established public interface under the accepted direct watchdog, with fresh output directories and exclusive input ownership:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-joined-driver-green-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-driver --filter SearchAdmissionJoinedDriverIntegrationTests
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/admission-joined-neighbors-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-integrated --filter 'SearchAdmission|SearchParent|SearchWire|SearchWorker'
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/admission-joined-full-owned -- scripts/swift.sh test --scratch-path .build/admission-joined-integrated
```

These are public reproduction interfaces; they do not pretend the frozen recorded commands used an unfrozen moving worktree. The broad suite includes adversarial regex cases and requires this accepted direct watchdog, without nested supervision. Freeze/verify actual source and resource membership separately; a passing build alone is not feature completeness.

Raw snapshots, rejected drafts and process receipts remain ignored under `.local/admission-joined-component/`, `.local/search-admission-joined-native/`, `.local/search-admission-native-integration/`, `.local/admission-joined-native-pure-green/`, `.local/admission-joined-integrated/` and `.local/admission-joined-integrated-v2/` and `.local/admission-joined-native-controls/`. Private reports and raw diagnostics are not published as public artifacts.

Current reviewed production identities before a final checkpoint commit:

| File | SHA-256 |
| --- | --- |
| `SearchAdmissionController.swift` | `e6cdd3dd5e724b267437415dbe672bc01d98c2ff7936ae8bcb813ffab48afedc` |
| `SearchAdmissionJoinedShutdownTypes.swift` | `5b9a2caa37d2439fe1d98348ca9dacdf530119321993dfa240307e07cf017dc2` |
| `SearchParentWireDriverTypes.swift` | `47516f459e28fa8d30671fdb99c3729260ba067bad1257a013cd7c6345a18676` |
| `SearchParentWireDriver.swift` | `7b21dfb362dcf422b29b3bbafcf1b95f861b9420691f99e958d38d2911fa21db` |

## Remaining scope

No new runtime dependency or asset was adopted; existing repository MIT licensing and system Swift/Foundation/AppKit frameworks remain the attribution boundary. Numeric ledger allowances do not establish measured heap/RSS, allocator release, a calibrated production memory policy, helper containment or global memory bounds. Arbitrary collaborator nonreturn, suppressed genuine events, external aliases and launcher quarantine remain outside the finite tested cleanup contract.

This checkpoint shows no windows or shown modal session, posts no keyboard/mouse input, changes no privacy setting, and launches no helper through the new native/driver cases. It establishes no new packaged helper/service, editor/folder search routing, application quit routing, desktop/IME/VoiceOver, physical input, Accessibility grant, Intel/macOS 14 runtime or performance acceptance. The local distribution remains the earlier `4841d89` checkpoint. Current UI Automation authentication remains user-owned and pending; this source/test checkpoint produces no new packaged desktop result. The next separately reviewed service owner must compose real parent/accounting/retry and native cancellation/quit ownership without treating a residual borrower, refused ownership or uncertain child as whole-service success.
