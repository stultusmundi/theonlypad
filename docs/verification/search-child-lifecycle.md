# Search child lifecycle state verification

Task 1 is implemented and independently approved at `eb3f1e177ccec82135c2251af7c6c7355f00dfd8`. This is the injected lifecycle state machine. The later sections record accepted direct-pipe channel tests. Real child launch, waitpid, helper integration and native search routing remain outstanding.

## Implemented boundary

`Sources/SearchExecution/SearchChildLifecycle.swift` confines control state to one serial queue. Admission stores the operation and monotonic deadline before invoking launch/timer seams. One request owns the slot; cancellation/deadline decisions can return while exact child ownership remains retained through both reap and channel-close acknowledgment. Facade loss requests cleanup without abandoning a pending launch or idle child. Unconfirmed cleanup stays quarantined and receives bounded background observation.

Typed policy, ticket, outcome, cleanup and internal collaborator contracts live in `SearchChildLifecycleTypes.swift`. Construction remains internal and injected until the real collaborators exist. No public fake launcher or claimed OS receipt is included. Waiter cancellation detaches only that observer; continuation state is removed before delivery. Generations, tickets, ordinals and timer tokens fence stale callbacks. Completed results survive later idle exit. Repeated shutdown inspects the original bounded cleanup attempt.

Background observation uses a fixed 100 ms cadence, with earlier one-time grace/idle deadlines when necessary. This is a scheduling policy, not a measured real-time guarantee. Pending launch conservatively reports channel closure unconfirmed. A recycling request tracks its physical cleanup generation separately from its new request identity.

## Evidence

`Tests/SearchExecutionTests/SearchChildLifecycleTests.swift` contains 32 deterministic cases. Synchronized gates and fixtures cover late launch after cancellation, signal/reap/close ordering, pre/exact/post deadline terminal handling, observer cancellation and refusal, installed-continuation reentry, healthy reuse/recycling, stale callbacks after simulated PID reuse, EINTR/ECHILD quarantine, idle/active exit, facade loss, shutdown, overflow and malformed URL admission. These are scripted effects, not real OS process tests.

- Final full core plus search suite: 563 tests, zero failures; 15.609 seconds suite elapsed, 17.94 seconds owned-watchdog command; no timeout.
- Final exact lifecycle source: 32 tests, zero failures; 3.723 seconds owned-watchdog command; no timeout.
- Strict scoped Swift formatting, public-source checks and diff checks passed.
- Independent specification and code-quality review approved the final source after all three material findings were resolved.

The review findings were reproduced before fixes: stale cleanup receipt during cancelled/deadlined recycling, excessive polling under a 1 ns grace policy, and premature channel-closure reporting during held launch. The regression run failed six assertions, then all 32 cases passed. Earlier idle-expiry, overflow-signalling and encoded-NUL issues also have retained behavioral red/green evidence. The original repeated-shutdown hang and unsynchronized test fixtures remain recorded as failures; they were replaced with one retained shutdown deadline and explicit synchronized gates.

The full 563 run preceded only relocation of one test comment. Production bytes are identical; the exact final test file was additionally checked by the 32-case run. Final SHA-256 values:

```text
b45f03bf7b681da2b93d793cbeed4010e48c7ff6f416ace0c0e9e0ce92df7c15  SearchChildLifecycle.swift
10493af1a5d9951141dce2767a675904044d67a8ca7946108f376e0cf01113d8  SearchChildLifecycleTypes.swift
7318712f4a61218f541f9d489d06782625cf37222ea4d0dd4c9848f9844b737c  SearchChildLifecycleTests.swift
```

Reproduce the focused deterministic suite with:

```sh
env NSUnbufferedIO=YES scripts/swift.sh test --scratch-path .build/search-child-lifecycle-repair --filter SearchChildLifecycleTests
```

Development verification wrapped every invocation in the private owned-process watchdog. Raw logs, manifests and reports remain ignored under `.local/search-child-lifecycle-task-1/` and `.local/search-child-lifecycle-repair-review/`. Full/adversarial suites continue to require an outer watchdog. Task 2 must add the checked-in real-process watchdog before running hostile child fixtures.

No dependency, public helper executable, package, GUI routing or release changed in this slice. It does not demonstrate hard regex termination, real descriptor closure, 100 MB memory bounds, performance targets or complete C-07/C-08 acceptance.


## Real-process watchdog bootstrap — incomplete

Commit `17f57cd` adds the checked-in outer watchdog and 21 passing pure tests. Independent source review approved four fixed self-controls, with group cleanup before the direct leader is reaped, bounded capture and conservative SIGCHLD policy refusal.

The first actual benign control failed safely: kqueue reported leader exit, the owned process-group SIGKILL returned `EPERM`, direct wait returned exit 0, and capture reached EOF. The watchdog returned 125 with cleanup unconfirmed. No hanging, ignored-TERM or lingering-descendant controls ran after that failure. Darwin zombie-group behavior is under investigation; `EPERM` is not being treated as success or as a request to change permissions. Real watchdog acceptance and the later launcher/channel tests remain outstanding.

## Reviewed watchdog controls

The conservative singleton refinement is committed at `5587d43`, with27 pure tests passing and independent review approved. The original benign failure remains preserved. A fresh serial run of all four fixed controls completed successfully:

| Control | Watchdog exit | Cleanup receipt | Direct wait | Seconds |
| --- | --- | --- | --- | --- |
| Benign | 0 | Exited leader alone, EPERM retained | 0 | 0.021312 |
| Loop | 124, expected timeout | Owned group signaled | -9 | 1.002668 |
| Ignore TERM | 124, expected timeout | Owned group signaled | -9 | 1.007106 |
| Leader exits with one same-group child | 0 | Owned group signaled | 0 | 0.019947 |

Every control completed output capture without truncation, recorded successful direct-child wait, and allowed the next serial command to run. The benign singleton result does not claim signal delivery. The descendant control establishes group signaling plus pipe EOF, not a direct wait receipt for a nonchild descendant. Raw receipts remain in `.local/search-child-lifecycle-task-2/watchdog-controls-_dok7tss/`; independent review is in the same private task directory. These are watchdog self-controls, not real search-launcher/channel/helper acceptance. Production search routing remains unchanged.

## Frozen integration harness

The reviewed infrastructure runner now snapshots the actual core/search sources and existing lifecycle tests into a private package, records and rechecks their hashes, and runs each stage through the same-process imported watchdog. It refuses source symlinks, inconsistent snapshots, incomplete cleanup/capture receipts and zero-test output. It adds no helper, launcher, channel, public constructor or adversarial fixture.

Twelve pure harness tests passed. Actual `scripts/test-search-child-lifecycle.sh --build-only` completed its build stage in 11.375807 seconds. The default command then passed all 32 deterministic lifecycle tests, with a 10.773264-second build and 0.892868-second test command. All stages returned zero with complete watchdog receipts. Private evidence is retained in `.local/search-child-integration/run.vk1hg9p8/` and `run.zq6yh9i8/`; both source manifests have SHA256 `ba8843610831d828e30949871ccb314b3681a23bec2ea61cbad6fe4b25e66e31`. Independent review approved this infrastructure boundary only. Actual channel/launcher fault testing remains outstanding.

## Injected nonblocking channel state, 2026-09-10

`SearchChildChannels` now implements the internal connection protocol with explicit descriptor/source injection. Admission reserves one read and two FIFO writes before dispatch, each write at most65,536 bytes; the read request limit is65,568 bytes. A serial pump performs at most four syscalls/65,536 transferred bytes per turn. First-result arbitration preserves cancellation, short writes retain their offsets, EOF is sticky, and source cancellation acknowledgment precedes each monitored descriptor's single close attempt. An uncertain close retains quarantine and never reports confirmed cleanup.

Independent source review found a test gap: the original late-cancellation test cancelled after its handler exited. A new gate cancels after success selection but before continuation delivery; a second gate cancels an entered read. The private negative control produced two tests/four behavioral failures, with no timeout or compilation failure. Reviewed production was not weakened. Root reviewed the correction and verified final source hashes against retained actual receipts.

Final frozen channel tests:20/0; unchanged lifecycle regression:32/0. Both use manifest `6f868e669593809d8733c1245e19e549dbb5eaa1d6df31c4dca9658c623c469a`. Every toolchain/build/test stage completed with actual wait0, complete capture and no timeout, truncation, interruption or receipt failure. The unchanged pure harness has13/0 evidence. Strict source formatting and public-source checks pass.

Proven commands:

```sh
scripts/test-search-child-lifecycle.sh --filter SearchChildChannelStateTests
scripts/test-search-child-lifecycle.sh
```

Raw synthetic results remain ignored in `.local/search-child-integration/run.mxcjoh6i/` and `run.kbnxa014/`; reviews/negative control are under `.local/search-child-lifecycle-task-2/channels-cancellation-review/`. Production source SHA256 is `5a2770fa001e914c3c7b10b634bfe9d4c9d10ee429d7e13862c9cf54f63fd754`; test source is `534351a0e4db585952d571056f83f0c57ff2cd34ad502d2a93f854a31452e63e`.

These are injected syscall/source tests. Concrete Darwin/Dispatch adapters, actual pipe backpressure/EOF/NOSIGPIPE/descriptor reuse, launcher/helper/reap containment and application routing remain outstanding. There is no fake-backed default or public production constructor. Adoption preconditions remain caller obligations; this slice does not establish flags, kernel ownership, physical cancellation or whole-search memory bounds.

## Frozen-input and receipt correction

The harness now compares the entire SwiftPM input-tree membership against its manifest before and after each stage, rejecting unexpected files, directories, alternate package manifests and symlinks. It also requires complete, strictly typed process receipts; missing nullable fields and boolean/float aliases cannot authorize success. Same-process watchdog ownership and the lifecycle filter remain unchanged.

Pure regression evidence: the initial16-test run reproduced13 behavioral failures; final18 harness tests plus27 existing watchdog tests passed. A fresh actual lifecycle run passed32/0 with all three complete process receipts and exact source membership independently verified. Private run `.local/search-child-integration/run.iqiqcfbd` uses manifest `e296078d20369b0d636185de02bf248c8aa152c3634ef24b1d1a4148350248a1`. Independent specification and code-quality review approved the two-file correction. This protects locally owned test-evidence capture against accidental changes; it is not an atomic filesystem sandbox against a hostile writer.

Real pipe fixture, helper launch and application routing remain unverified. The separate legacy shortcut runner's provenance validation gap is recorded and outstanding; this correction does not repair that runner.

## Concrete adapters and first actual pipe control

The internal default connection constructor now uses one-syscall Darwin read/write/close operations and real Dispatch readiness sources. The caller still owns descriptor normalization, flags and exclusive adoption; no lifecycle launcher or public application routing was added. Dispatch cancellation acknowledgment precedes each monitored descriptor's raw close.

The test fixture was repaired after review found lost close errors, missing EOF deadlines, cleanup waiters that could hang, weak quarantine ownership and absent signal-state comparison. Deterministic failures first reproduced7 tests/17 assertions plus a separate1-test/3-assertion cleanup failure. Final29/0 combined the unchanged20 channel-state tests with9 injected fixture controls. The fixture retains terminal results independently of observers, keeps uncertain close results sticky without retry, bounds EOF/cancel acknowledgment, and retains timed-out source ownership until process teardown. These are test-fixture controls, not a production launcher implementation.

Root reviewed the final source and ran exactly one actual smoke:

```sh
scripts/test-search-child-lifecycle.sh --filter SearchChildChannelPipeTests/testDefaultConstructorReadsOwnedResponseByte
```

It passed1/0 in0.002s reported XCTest case time. The default constructor delivered one exact response byte over a real synthetic pipe, then closed; the independent lifetime peer required EOF, actual source cancellation acknowledgment and confirmed peer close. Cleanup checked unchanged inherited default SIGPIPE disposition. No signal disposition was modified, and no real document or GUI was involved. All toolchain/build/test receipts had confirmed wait, complete capture and no timeout/interruption/truncation; frozen input membership was checked independently.

Private evidence: `.local/search-child-integration/run.9qp6ec9y`, manifest `3469c7eb7a77ddf8f8d9298f7edefb7aec9ce625a25fca034641ddce4bc19c34`. Final fixture SHA256 `d3a434b1b5cdd3cd28b38773c4c197bd7e8d0c61e605b7cf77094b3405417117`; source/negative-control review is under `.local/search-child-lifecycle-task-2/stage-a-repair/`.

This single byte/EOF control is not backpressure, EPIPE, cancellation, descriptor-reuse, child inheritance/reap, performance or application-search acceptance. Those controls remain outstanding and are the next implementation work. The main distributed app has not been repackaged from this slice.

## Actual bounded channel suite, 2026-09-10

The reviewed Darwin/Dispatch channel component now passes all nine actual synthetic-pipe tests. These tests create owned pipes inside the test process; they do not create a search child or exercise waitpid.

| Actual control | Required observation |
|---|---|
| Default constructor | Exact response byte, channel close and lifetime EOF |
| Short response and request stream | Three-byte native read with a larger requested maximum; exact request bytes followed by actual EOF |
| Backpressure and FIFO | Bounded prefill reaches actual EAGAIN; first/second write reservations, third busy refusal, exact filler/first/second payload stream through EOF |
| Read cancellation | Actual admission and EAGAIN before cancelled result |
| Write cancellation | Actual backpressure/admission/EAGAIN before cancelled result |
| Sticky response EOF | Second empty result without another native read syscall |
| EPIPE | Default inherited SIGPIPE, real EPIPE, survival with per-FD suppression and unchanged native signal snapshot |
| Close ordering | Each actual source cancellation acknowledgment precedes its descriptor's confirmed close; channel completion follows confirmed closes |
| Descriptor reuse | Exact old request integer reused only after acknowledged/confirmed close, then independent sentinel bytes survive repeated channel close |

The fixture's request drain verifies the entire expected stream: reaching the expected count alone is insufficient. It probes at most one byte for surplus data, rejects early EOF, and succeeds only on actual EOF at the expected count. The data cases close the channel after admitted writes complete before awaiting drain EOF; FIFO begins draining earlier to release backpressure. Lifetime EOF is independently required, without inventing an ordering between its unrelated queue and channel-close return. No actual stale Dispatch callback is claimed.

Fill remains bounded to 256 writes of at most 4,096 bytes. Drain remains bounded to 512 reads and 2 MiB, including EOF/probe attempts, with at most 16 calls/64 KiB per callback. Overall EOF and cancellation-acknowledgment deadlines remain 30 seconds. Results wait for source acknowledgment and confirmed owned close; uncertain close is sticky, and timed-out ownership remains quarantined. These fixture bounds and passing tests are not whole-search memory or latency guarantees.

### Preserved failures and oracle correction

The first broader run stopped during its sandboxed SwiftPM build because an output-file-map could not be read; no pipe test executed. The same command under the already accepted outside-sandbox toolchain environment built and passed its first data case. That earlier pass proved the expected prefix and cleanup, but could not reject surplus trailing bytes.

Root review identified this oracle gap before the full suite ran. Injected tests then produced seven tests with six failed assertions: the old drain returned prefix success without checking a surplus byte or waiting for EOF. The repair added exact-payload-plus-EOF, payload/EAGAIN/EOF, surplus-byte rejection and premature-EOF controls while preserving the cancellation/close gates. The final frozen injected suite passed 40/0: original 20 channel tests, nine accepted StageA fixture tests, four bounded-I/O controls and seven drain-lifecycle tests.

Root reviewed the repair, then executed the repaired first data case (1/0) followed by the full actual class (9/0). Each run had all three strict exact-command toolchain/build/test receipts, complete wait/group-cleanup/capture observations, verified captured byte lengths and full frozen source inventory. Actual test names and positive XCTest counts matched the summaries. The earlier prefix-only pass and build refusal remain preserved separately; neither was relabeled as full-stream evidence.

Proven commands:

```sh
scripts/test-search-child-lifecycle.sh --filter SearchChildChannelPipeTests/testRealShortResponseAndExactRequestBytes
scripts/test-search-child-lifecycle.sh --filter SearchChildChannelPipeTests
scripts/test-search-child-lifecycle.sh --filter 'PipeBoundedIOTests|PipeDrainLifecycleTests|PipeDescriptorCellTests|PipeFixtureLifecycleTests|SearchChildChannelStateTests'
```

The existing coordinator calls the accepted watchdog directly for each stage. Do not nest another session-owning watchdog. In the restricted development environment, these builds used the approved outside-sandbox SwiftPM invocation; this does not change the test commands or product signal policy.

Final reviewed hashes:

```text
e0b5a4707799afad754bfbd5a1d6f1e388d0cc28d1454489df73c8190e92cf38  SearchChildChannelTests.swift
2b3a70efb97981b3338af79ea2c539deea6649969dd1eed694c3c0de809ddf52  SearchChildChannels.swift
9a201f6870e46daeca4baa2a2bd1f131a7c96dc40f1fa9993fe479d92485f57b  SearchChildChannelDarwin.swift
```

The repaired injected, first actual and full actual runs share source manifest SHA256 `9ffe0f0c45652a42500539085aac17371e042333fecc836d553f03fc2deac93a`. Raw synthetic evidence remains ignored: injected `run.dxc892a9`, first actual `run.a42pl2qz`, full actual `run.4kxr8u32`; the prior prefix run is `run.ta6hk71d`, build refusal `run.89aw_j8q`, and EOF-oracle red `run.ylb5rvbq`. Root source/runtime review accepted this component boundary.

Real child process creation, descriptor inheritance across other app launchers, exact child reap, helper lifetime, wire/runtime integration, public lifecycle construction and production search routing remain outstanding. The existing Foundation external-command path still needs the planned inheritance audit. Direct pipe success establishes neither an OS sandbox nor packaged, desktop, large-input or performance acceptance.

## Startup-failure ownership contract

The internal launched-child value now carries optional `startupFailure`, defaulting to nil. The lifecycle stores the real child PID and connection before processing that failure. If no earlier cancellation/deadline/shutdown decision won, it fails the active operation immediately and uses the existing exact-child stop/reap/close path. It does not publish a usable connection or accept a handshake on that branch. Earlier outcomes remain unchanged, and physical ownership still requires both reap and connection cleanup before release.

API comments distinguish child/adopted-connection settlement from complete process resource cleanup. `.noChild` does not certify closure of descriptors quarantined before child/connection adoption. A future launcher may retain such quarantine and permanently refuse new launches. Post-spawn ancillary cleanup must remain part of the connection's close acknowledgment; the optional failure field does not implement that ownership gate.

The compiling behavioral red run added the field and tests while leaving lifecycle control unchanged. Four tests produced five failed assertions: no immediate stop, an active deadline timer, a published connection and a later deadline outcome instead of startup failure. The captured timer was forced only after immediate-state assertions, so the red completed without a watchdog timeout. Prior-outcome, pending-shutdown and facade-loss controls already passed.

The four-line control addition then passed all 36 deterministic tests through the default harness. The original 32 test bodies remain byte-identical. New coverage verifies connector suppression, first-outcome order, exact simulated signal/poll PID, reaped child with held close, unchanged shutdown grace and ownership after facade loss. Effects are injected; no child was spawned.

```sh
scripts/test-search-child-lifecycle.sh --filter SearchChildLifecycleTests/testStartupFailure
scripts/test-search-child-lifecycle.sh
```

Both runs had complete frozen inventories and all three strictly validated exact-command watchdog receipts, including expected red exit, actual captured lengths and positive XCTest counts. Root independently verified the same inputs/results. Scoped strict Swift formatting, public-source and whitespace checks passed. Independent specification and code-quality review passed with no material findings; it also matched all three source hashes, both manifests, all six typed receipts and the unchanged original test bodies.

Final hashes:

```text
ae9dd3dcd0de0c57a8bfc724f790777da8f489f68c923bc70d06779b6bc97130  SearchChildLifecycleTypes.swift
8978bd2966ab34b3d17dc41962326809c3e99e68ba7f7088c6d56a202d342442  SearchChildLifecycle.swift
1ea6e680c6a4b9bf6ff78047a8290eb8b713f85bb7d1bfc1c8594bac2fd676ea  SearchChildLifecycleTests.swift
```

Green manifest SHA256: `f1b3bf51839d5df51cc339bc7d5cabc3a33770a944a9e0de1f759082a4809e9d`. Raw red/green evidence is retained privately in `run.jv7ye2cz` and `run.tz0d347j`, with the three-file handoff under `.local/search-child-lifecycle-task-2/startup-failure/`. Accepted channel sources/tests are unchanged.

The real launcher, process-wide setup quarantine, ancillary cleanup wrapper, SIGCHLD policy checks, no-external-reaper integration precondition and Foundation inheritance audit remain outstanding. No public lifecycle construction, helper, application routing, GUI or performance acceptance is added by this contract.
