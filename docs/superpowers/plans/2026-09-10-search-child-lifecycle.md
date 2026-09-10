# Supervised search child lifecycle implementation plan

> Implementation worker: use `superpowers:executing-plans`, genuine red/green tests and independent source review. Root-reviewed planned work, awaiting completion and review of the wire protocol. All new commands below are proposed/unverified. No lifecycle source or tests are implemented by this plan.

**Goal:** Own at most one search helper process, enforce independent cancellation/deadline decisions, and retain its slot until exact reap and channel cleanup.

**Architecture:** One process-wide lifecycle owner on a private serial control queue, independent of transport codecs and the child engine. A bounded spawn lane and a single exact-child reaper feed generation-tagged events to that owner. Request/response wire parsing and large text allocation remain separate collaborators and implementation stages.

**Tech stack:** Swift 5 language mode/macOS14, Foundation/Dispatch/Darwin, existing SearchExecution module; Python3 outer test watchdog. No dependency, shell launch or AppKit.

**Inputs:** `docs/superpowers/specs/2026-09-10-supervised-search.md`, `docs/superpowers/plans/2026-09-10-search-wire-protocol.md`, reviewed one-enumeration API. Respect the active wire worker's ownership. Do not implement SearchExecuting/native/folder admission or production helper matching in this slice.

## Exact ownership and files

Create `Sources/SearchExecution/SearchChildLifecycleTypes.swift`, `SearchChildLifecycle.swift`, `SearchChildLauncher.swift`, `SearchChildChannels.swift`, `SearchParentLifetime.swift`. Create `Tests/SearchExecutionTests/SearchChildLifecycleTests.swift` for deterministic transitions. Create isolated real-process suite `Tests/SearchChildIntegration/SearchChildIntegrationTests.swift` and synthetic executable fixture `Tests/SearchChildIntegration/FixtureMain.swift`; these are projected into a temporary Swift package by the new `scripts/test-search-child-lifecycle.sh`. Create checked-in `scripts/run-owned-search-tests.py` for its outer watchdog. Do not add hanging fixtures to ordinary PadCoreTests or invoke adversarial ICU from XCTest.

The integration runner copies actual PadCore/SearchExecution sources and only the dedicated integration tests/fixture into an ignored temporary package, with SHA-256 manifests for original and copied sources. It adds a fixture executable target to that temporary package, builds it first, and gives its absolute path to the test suite via a test-only environment variable. No shipped fixture executable/product, no production helper lookup override. Package.swift changes, if needed for the already planned SearchExecution target, must be coordinated with the wire owner; this lifecycle task should need none after that target lands.

## Final public-to-module interfaces to freeze

The public initializer shown below becomes available only in Task 2, with the real launcher and channels. Task 1 defines the control owner and its methods but exposes construction only through the internal injected initializer specified below. No production initializer backed by a stub or unconditional failure is committed.

Values are public Sendable/Equatable unless noted. Implementation confinement is to the control queue, not MainActor; cross-queue entry methods are asynchronous wrappers. No mutable PID or file descriptor is exposed to native callers.

```swift
public struct SearchChildPolicy: Sendable, Equatable {
  public let operationNanoseconds: UInt64
  public let reapGraceNanoseconds: UInt64
  public let idleNanoseconds: UInt64
  public let maximumRequestsPerChild: UInt32
  public init(operationNanoseconds: UInt64, reapGraceNanoseconds: UInt64,
              idleNanoseconds: UInt64, maximumRequestsPerChild: UInt32) throws
}
public struct SearchChildTicket: Sendable, Equatable {
  public let identity: SearchWireIdentity // exact generation/request UUID/ordinal
  // No public initializer: only lifecycle-issued values are admitted.
}
public enum SearchChildFailure: Error, Sendable, Equatable {
  case busy, invalidPolicy, invalidExecutable, invalidRequestID, observerBusy, staleTicket
  case launchFailed(Int32), channelFailure(Int32), handshakeFailure
  case protocolFailure, cancelled, deadline, unexpectedExit, shutDown
}
public enum SearchChildExit: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
}
public enum SearchChildOutcome: Sendable, Equatable {
  case completed(SearchWireTerminal)
  case failed(SearchChildFailure)
}
public enum SearchChildCleanup: Sendable, Equatable {
  case noChild
  case pendingLaunch(generation: UUID)
  case stopping(generation: UUID)
  case reaped(generation: UUID, exit: SearchChildExit)
  case stopUnconfirmed(generation: UUID)
}
public struct SearchChildShutdown: Sendable, Equatable {
  public let cleanup: SearchChildCleanup
  public let channelsClosed: Bool
  public var stopped: Bool { get } // noChild/reaped AND channel cleanup complete
}
public final class SearchChildLifecycle: @unchecked Sendable {
  public init(executable: URL, policy: SearchChildPolicy) throws
  public func begin(requestID: UUID) async throws -> SearchChildTicket
  public func wait(for ticket: SearchChildTicket) async throws -> SearchChildOutcome
  public func cancel(_ ticket: SearchChildTicket) async throws
  public func cleanup(for ticket: SearchChildTicket) async throws -> SearchChildCleanup
  public func shutdown() async -> SearchChildShutdown
}
```

Policy initializer rejects zero/overflowing durations and maximumRequestsPerChild0; durations <=60 seconds operation/idle and <=5 seconds reap grace are representational safety bounds for this slice, not recommended production settings. Use checked monotonic additions. Caller supplies all values, no undocumented production default. Later policy tuning must include cold launch and100MB transport; no supported-input reduction to meet a stopwatch.

`begin` rejects the all-zero request UUID with invalidRequestID before creating an operation, allocating an ordinal, scheduling a deadline or spawning; existing child/operation state remains unchanged. It then serializes admission and creates/stores the operation before scheduling spawn or any callback. It returns a real ticket even while launch/handshake is pending; wait tracks that exact operation. At most one active ticket, no queue and no snapshots in this primitive. The later ApplicationSearches owner provides bounded global queue/byte reservations. One outstanding wait observer per ticket; a second throws observerBusy. Observer cancellation removes only that observer and returns CancellationError; it does not cancel the owned operation. Explicit cancel is required. Keep one last outcome/cleanup receipt for exact repeated inspection; older tickets return staleTicket. Clearing an operation happens before notifying its observer, with no old cleanup afterward.

Transport integration uses **internal** methods, not arbitrary native callbacks:

```swift
func connection(for ticket: SearchChildTicket) async throws -> any SearchChildConnection
func acceptedHandshake(generation: UUID) async throws
func acceptedTerminal(_ terminal: SearchWireTerminal, ticket: SearchChildTicket) async throws
func rejectedProtocol(generation: UUID) async
```

`connection` awaits only that child launch and returns the same object for the generation; it is available before handshake so the wire driver can send parentHello. At most one connection waiter, cancellation detaches observer only. `SearchChildConnection` is an internal `AnyObject, Sendable` protocol declared in `SearchChildLifecycleTypes.swift` during Task 1:

```swift
protocol SearchChildConnection: AnyObject, Sendable {
  func write(_ bytes: Data) async throws
  func read(maxBytes: Int) async throws -> Data
  func close() async
}
```

Its identity is bound to the generation by the retained SearchLaunchedChild/control-owner record. Task 1 uses a test-file scripted conformer with held completion gates; Task 2 adds the real `SearchChildChannels` conformer in `SearchChildChannels.swift`. The concrete owner enforces write chunks <=65,536, read bound1...65,568, at most one pending read and one pending write, one bounded queued write only. Empty read means actual EOF. No whole-stream collector. The Task 2 concrete owner serializes nonblocking syscalls/source cancellation/FD closure on a separate I/O queue and handles short writes/EINTR/EAGAIN. Cancelling a pending read/write fails it and requires connection shutdown; it never detaches a live FD for another operation. These transport primitives contain only bounded bytes, not wire or semantic parsing.

`acceptedHandshake` is called only after the separate wire reader validates protocol/semantic versions and expected generation, outside consume callbacks. `acceptedTerminal` is called only after a complete response and terminal have passed all wire/scope/range validation and the codec consume stack has unwound. That internal method checks exact issued ticket, operation state, handshake, deadline and child-liveness state. A semantic failure terminal can complete a request while preserving a healthy persistent child. A protocol failure cannot. This lifecycle task tests those calls as trusted collaborator events; it does not claim a fake event validates IPC or proves engine memory release. The later actual wire/engine integration must exercise real frames before production use.

## Control state machine and irreversible effects

Connection states: absent, launching(generation), awaitingHandshake(generation,pid), ready(generation,pid), executing(ticket,pid), stopping(generation,pid), quarantined(generation,optionalPID). A request admitted against absent child creates a fresh nonzero generation and ordinal1. Reuse of a healthy ready child increments ordinal exactly once; no UInt64 wrap. Recycle before beginning a request that exceeds maximumRequestsPerChild or ordinal capacity. Recycle is itself owned cleanup: reserve the new operation/deadline, stop/reap old child, then launch new generation only after cleanup. No two children overlap.

Every external event carries generation plus exact operation when relevant. A bounded control-event path must not enqueue unbounded progress/data; this slice has only launch/handshake/terminal/deadline/reap/channel-close events. Timer and termination observation never execute user/codec callbacks on control. Small state assignments precede observer delivery. Watchdog ownership survives caller task cancellation and loss of the UI/controller.

Start operation deadline on admission, **before** spawn/upload/handshake, using a monotonic source. If a timer delivery is delayed, acceptedTerminal also compares `now >= deadline` and cannot accept late success. First terminal decision wins. Completion at deadline is timeout by definition. Timer callbacks carry generation/ticket and stale ones do nothing. No task group waits for an uncooperative child or worker before making that decision.

Cancel/deadline/protocol failure atomically stores the failure, stops accepting response bytes, closes the upload direction and sends SIGKILL to the still-owned live child. There is no five-second graceful-TERM wait in production policy. A cancelled/timeout outcome can be delivered while reap is pending, but the physical slot and FD ownership remain unavailable. Reap grace expiry records stopUnconfirmed and keeps the exact child/launch slot quarantined; background bounded observation continues. New begin fails busy while cleanup is unconfirmed. Explicit repeated cancel/shutdown never changes another operation, sends to a reused PID, or reports stopped without evidence.

Normal terminal may release the operation to ready only after the validated event is accepted before deadline. If child exit has already been observed, refuse completion as unexpectedExit; ordering tests must cover terminal followed by immediate exit and vice versa. An idle child exit after an already accepted terminal does not revoke the result; it changes availability for the next operation. The future wire driver treats bytes after terminal as protocol failure, not as permission to accept another request. Request cleanup and transport terminal validation therefore need a coordinated handoff in that integration task.

## Spawn, signals, reaping and descriptor lifetime

Use `posix_spawn` with a fixed absolute executable path; no shell/PATH search. The lifecycle constructor performs only structural URL/path validation: require a file URL with an absolute, nonempty path and no embedded NUL; otherwise throw invalidExecutable. It does not resolve symlinks, query existence/permissions or perform filesystem executable checks. Perform those filesystem checks outside the control lane on the **one retained spawn lane**, while the admitted operation's deadline is already armed; actual spawn failure remains authoritative if the filesystem changes afterward. No second launch if that lane blocks. If deadline/cancel occurs before PID exists, mark pendingLaunch stop intent; any later successful spawn must immediately enter stop/reap without handshake or UI publication. Spawn error clears only its own exact launch ownership and closes all created descriptors. A blocked syscall is not claimed hard-interruptible.

Create request stdin, response stdout and parent-lifetime pipes with explicit close-on-exec discipline; stdin0/stdout1/control3 in child, stderr2 directed to /dev/null in production (no uncontrolled text diagnostics). Explicitly close unused ends in parent and child; reset inherited signal mask/dispositions in spawn attributes; verify the chosen Darwin close-on-exec spawn APIs against the actual SDK during implementation. The launcher always supplies the exact bootstrap arguments `--generation <UUID>` for its retained child generation, as frozen by the public wire plan. The helper validates this nonzero UUID before constructing RequestReader; parentHello must match that already supplied identity and is not an alternative bootstrap. No document/pattern/path payload appears in argv. Minimal environment excludes injected loader variables; no current-directory/PATH fallback.

Set FD_CLOEXEC immediately on all newly created ends, and use Darwin's POSIX_SPAWN_CLOEXEC_DEFAULT plus explicit dup/close file actions for this launcher. Handle source descriptors that collide with0...3 using safe temporary duplicates before installing final descriptors. The parent retains the **only** lifetime-pipe writer; helper and every launched fixture close that writer before exec. Pipe creation followed by fcntl is not an atomic guarantee against another uncoordinated concurrent app launcher. Production integration must audit every app spawn path for close-default behavior, or coordinate descriptor setup with a shared launch lock honored by those paths. This lifecycle-only slice tests its own controlled launches and records that prerequisite; it cannot claim absence of leaks from arbitrary unrelated launch code it has not integrated.

Root's read-only inventory identifies `Sources/PadCore/ExternalCommand.swift:91–111` (`Foundation.Process.run`) as the concrete existing app child-launch path requiring that integration audit. Do not assume Foundation closes unknown descriptors. This lifecycle slice does not modify that launcher or unrelated runners; production enablement must resolve its possible lifetime-writer inheritance before claiming parent-EOF coverage across app launches.

Use the Darwin per-descriptor F_SETNOSIGPIPE facility for parent request writes, with SDK availability and actual broken-pipe behavior verified in the bounded fixture test. Fail setup if it cannot be installed; do not silently ignore SIGPIPE process-wide. Apple's published Darwin header defines the per-FD controls, but that source is not a substitute for the supported-host test. [Apple Darwin fcntl definitions](https://github.com/apple/darwin-xnu/blob/main/bsd/sys/fcntl.h). This keeps parent-global signal policy untouched.

Keep the helper in the launching process's group. Production never group-signals: it signals its single exact unreaped PID only. Fixtures never daemonize, create a new session/group or spawn uncontrolled descendants. This lets the test runner's isolated process group contain the harness and all fixture descendants for outer cleanup. A malicious helper is outside this operational trust model; ordinary process separation is not a security sandbox.

Only one owner ever calls waitpid for this child. Use a Dispatch process-exit source as a wakeup plus serialized `waitpid(pid, ..., WNOHANG)` on the control lane; one low-rate timer also checks while stopping so a missed wakeup does not lose reap. Handle EINTR, and retain ownership while wait returns0. Do not perform blocking waitpid on control or a competing Foundation Process terminationHandler. Store terminal wait status and remove PID signal authority atomically on the same lane before external notification. ECHILD without a stored successful reap is cleanup inconsistency/stopUnconfirmed, not a fresh successful reap. A process-exit notification or kill(...)=ESRCH alone is not reap evidence.

Close channels on their owning I/O queue; stop signaling is independent of any codec callback or blocked lane. Generation checks fence late reads/writes. Physical slot release requires both actual reap and close completion (including cancellation/closure of dispatch sources and completion of their queued operations). Never close a raw descriptor twice or let a stale queued closure close its subsequently reused integer. Tests force descriptor reuse with fresh pipes and prove old callbacks cannot affect them. No waiting for a parser/large codec while holding control.

The implementation can fall back from DispatchSource process notification to periodic WNOHANG polling only if documented and reviewed; neither path provides a real-time scheduling guarantee. All polling is a single bounded source per owned child, not repeated detached tasks.

## Parent EOF helper component and shutdown

`SearchParentLifetime` is a separate helper-side utility in SearchExecution, with exact API `public static func run(controlFD: Int32) -> Never`. It performs a dedicated blocking read loop: EINTR retries; EOF invokes `_exit(0)`; unexpected data or other error invokes `_exit(70)`. It never waits for the engine or executes an AppKit callback. The future helper starts it on one dedicated thread before processing parentHello; main engine work runs elsewhere. No other process inherits the control pipe's write end. Normal recycle also closes the parent end, but parent still retains termination/reap ownership. Parent process exit automatically closes its descriptors, making this path useful if the parent cannot finish explicit cleanup.

This slice proves EOF behavior by closing the sole lifetime writer while the **directly owned** fixture child is busy, then actually reaping that child. It must also test unrelated descriptor inheritance does not keep that writer alive. Parent-death integration can be added to the later packaged helper test, but do not describe pipe closure as a measured parent crash or claim `_exit` runs on an arbitrarily unschedulable/malicious process.

`shutdown` closes admission permanently for this lifecycle instance, cancels active outcome, requests exact child stop, and waits at most supplied reapGraceNanoseconds for child+channel cleanup. It returns stopped only with actual evidence; otherwise pendingLaunch/stopping/stopUnconfirmed and channelsClosed status. Repeated shutdown inspects the same retained ownership. It is bounded even if spawn is stuck. Read-only helper cleanup is **not a durable-document quit veto**. The app's later coordinator may authorize normal exit after bounded search shutdown even if cleanup remains pending; do not mislabel exit permission as a stopped receipt. If durable quit is vetoed, retain this instance's quarantined resources; a new application lifecycle must not launch alongside it. A later explicit reopen API needs proof of quiescence and a separate reviewed interface; not included here.

## Deterministic seams without fake process evidence

Task 1 declares `SearchChildConnection`, `SearchChildSystem`, `SearchChildTimer`, `SearchLaunchedChild` and `SearchChildPoll` in `SearchChildLifecycleTypes.swift`; the control implementation is in `SearchChildLifecycle.swift`. No declaration in either file references a future concrete launcher/channel type. Exact internal construction is:

```swift
init(
  executable: URL,
  policy: SearchChildPolicy,
  system: any SearchChildSystem,
  now: @escaping @Sendable () -> UInt64,
  schedule: @escaping @Sendable (
    UInt64, @escaping @Sendable () -> Void
  ) -> any SearchChildTimer
) throws
```

The schedule arguments are the absolute monotonic deadline and event. `SearchChildTimer: AnyObject, Sendable` requires `func cancel()`. `SearchChildSystem: AnyObject, Sendable` requires `launch(executable: URL, generation: UUID, completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void)`, `signal(pid: Int32, signal: Int32) -> Int32`, and `pollExit(pid: Int32) -> SearchChildPoll`. `SearchLaunchedChild: Sendable` contains `pid: Int32` and `connection: any SearchChildConnection`; `SearchChildPoll: Sendable` is `.running`, `.reaped(SearchChildExit)`, `.interrupted`, `.failed(Int32)`. Launch supplies the connection, so no separate channel factory is necessary. Structural executable validation is shared by injected and eventual public construction.

Task 1's scripted system, clock, timer and connection conformers live only in `SearchChildLifecycleTests.swift`. They expose explicit gates for asynchronous connection closure, launch and timer events and simulate effects only; they never represent OS receipts. Thus deterministic async/race tests compile using the existing wire types plus the two new Task 1 source files, without Task 2 files or fake production defaults. Task 2 adds the real system/launcher, nonblocking channel conformer and Dispatch timer, then adds `public init(executable:policy:)` wired to those real collaborators. The final public API above is unchanged. Production launch uses the single retained spawn lane; actual process tests exercise it unchanged.

The signal seam returns0 or the captured errno value, never reads thread-local errno later. A simulation of reaped(-) is explicitly not an OS receipt. Integration tests must independently assert actual wait status using the implementation's recorded successful waitpid; they must not consume the status with a second reaper. A fresh benign child completing after a cancelled child is reaped demonstrates reuse behavior.

## Task 1 — Lifecycle state/ownership with deterministic red/green

- [x] Add the control owner and exact internal system/channel/timer interfaces in the two Task 1 files above, plus test-only scripted conformers. Do not add the public initializer or reference future concrete files. Compile the deterministic tests at this boundary; no fake/default production launcher, channel or throwing placeholder. Create explicit event gates.
- [x] First behavioral red: begin A; record launch not completed; cancel A; deliver late launch PID; assert SIGKILL exactly once for A, no handshake success, wait(A)=cancelled and begin(B) remains busy until exact reap+channel close. Then allow B and verify new generation/ordinal1. This addresses the hard ownership gap without executing ICU.
- [x] Reject zero request UUID while absent and while another operation exists; assert invalidRequestID, no new launch/deadline/ordinal and unchanged existing ticket/cleanup. Verify constructor structural refusal without invoking filesystem/launch collaborators, and delayed filesystem validation remains owned by the admitted launch deadline.
- [x] Add ordered races: deadline before/after launch, terminal one tick before/exactly at/after deadline, cancellation before/after terminal, repeated cancel, wrong ticket, old timer after next request, wait observer cancellation, second observer refusal and callback reentry beginning a new operation after old completion. No old cleanup may erase new state.
- [x] Simulate wait running/EINTR/ECHILD and delayed channel closure. Assert stopUnconfirmed retains slot, no repeated spawn, no stale PID signal after reap, and repeated shutdown returns actual latches. Reuse healthy child with increasing ordinals; max request count triggers reap-before-relaunch.
- [x] Proposed command `scripts/swift.sh test --scratch-path .build/search-child-lifecycle --filter SearchChildLifecycleTests`. Retain behavioral red before implementing minimal state transitions; rerun identical fixtures to green. This test suite contains no actual hanging child or regex.
- [x] Source review for control queue isolation, exactly one reap authority, bounded event/timer counts and no callback under locked ownership. Scope-format and independently review before launching real fault fixtures.

Task1 accepted at `eb3f1e177ccec82135c2251af7c6c7355f00dfd8` after independent specification and quality review,32 deterministic lifecycle tests and563 full-suite tests. See [verification](../../verification/search-child-lifecycle.md). Simulated effects do not establish real-process containment; Task2 remains unchecked.

## Task 2 — Real launch/channel/reap plus checked-in outer watchdog

- [ ] Implement the real launcher/system, `SearchChildChannels` protocol conformer, Dispatch timer and helper lifetime utility; only now add the public `init(executable:policy:)` using those implementations. Preserve the injected initializer for deterministic tests. Synthetic FixtureMain supports only fixed test modes: benign echo, never-read-input, partial-output-then-loop, continuous bounded-chunk-output, immediate-exit(code17), ignore-TERM-and-loop, and loop-with-parent-lifetime-watcher. No arbitrary shell command, path, regex or eval mode. An internal `SearchChildLauncher.init(arguments: [String])` receives additional fixed fixture-mode arguments in tests; these cannot replace or override the mandatory `--generation <UUID>` bootstrap. Public lifecycle construction uses no additional mode arguments but always supplies that exact bootstrap. Test the fixture receives the retained nonzero generation and refuses missing/duplicate/malformed bootstrap arguments. Fixed test readiness markers travel on response stdout only for these lifecycle fixtures (there is no production wire parser in this task); read them through the real bounded channel. Root's warm regex probe remains contextual evidence, not a substitute for these real lifecycle assertions.
- [ ] Implement `scripts/run-owned-search-tests.py` before any fault test runs. CLI: `--timeout SECONDS --output DIR -- COMMAND...`. Validate positive finite timeout, create private output directory, launch argv with `start_new_session=True`, no shell, and sanitized test environment. On timeout/interruption, SIGKILL only the owned process group, wait/reap direct runner child, record timeout=true/exit124 and fail. On normal harness exit, also clean the still-owned process group **before reaping the group leader**, so a crash cannot leave descendants and no recycled process-group number is targeted. Observe exit using Python's macOS `select.kqueue`/EVFILT_PROC NOTE_EXIT without calling Popen.poll/wait first; retain Popen strongly, make no second reaper, clean the owned group, then call wait. An ESRCH registration race for the just-created unreaped child is handled as possible already-exited child: clean that still-owned group before wait. Any other observation failure takes the same owned cleanup/failure path. Capability refusal must occur before launching fault tests if Python lacks kqueue; do not assume Linux waitid bindings exist on macOS. [Apple kqueue contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kqueue.2.html). The watchdog cannot personally reap nonchild descendants; report that limit rather than claiming all wait statuses. Fixtures' normal tests must use their real direct-child reaper. No ps/pgrep/broad kill scans.
- [ ] Bound stdout/stderr evidence: stream through the Python selector loop into capped files (e.g1MiB each candidate), continue draining/discarding after cap, record truncation and fail unexpectedly noisy tests. A flood must not fill the disk or block the watchdog. Keep timeout monitoring independent of read progress, cap bytes processed per selector iteration, and no printing raw fixture/document text in summaries.
- [ ] Add watchdog self-tests before lifecycle faults: benign command succeeds; owned infinite loop times out; child ignoring TERM is killed by KILL; leader exiting with lingering descendant is contained by the owned group cleanup. Use only fixture PIDs/groups. Record timeouts as expected only for watchdog self-controls, never for the product suite.
- [ ] `scripts/test-search-child-lifecycle.sh` snapshots source/tests/runner manifests, builds the temporary fixture and test package under the watchdog, then executes only SearchChildIntegrationTests under the watchdog. Avoid the repository's all-core/adversarial suite. Command paths use script-relative root, compatible with detached worktrees; no private root helper is a required dependency.
- [ ] Real red: ignore-TERM fixture announces loop readiness; cancellation must issue KILL, observe signaled(SIGKILL), reap and close channels; only then benign next request can launch and exit normally. Assert child-entered readiness separately from launch timing. First failures must be bounded by the outer watchdog, never an unprotected XCTest timeout expectation.
- [ ] Test exact absolute-path refusal, exec failure, immediate exit, closed stdin EPIPE with F_SETNOSIGPIPE installed (parent survives), short writes/nonreading-child cancel, flood/partial response cancellation and channel reuse. Per-FD setup failure must refuse before child launch; no fallback global signal-handler mutation.
- [ ] Proposed command `scripts/test-search-child-lifecycle.sh`; not verified or added to AGENTS.md yet. Run under one independent outer timeout around the complete build/test subprocess tree, plus the product's own deadlines. Raw process evidence stays ignored.

## Task 3 — Parent EOF, persistent reuse and bounded shutdown evidence

- [ ] EOF red: fixture busy loop continues until parent lifetime writer closes; then require actual child exit/reap and no replacement before close latch. Do not make EOF depend on receiving the next request. Start an unrelated executable while the writer exists and ensure descriptor inheritance cannot prolong it.
- [ ] Shutdown while launching/handshaking/executing/idle/quarantined returns bounded state with correct stopped flag, without turning an unconfirmed outcome into success. Simulated stuck spawn/channel cleanup covers states that should not be manufactured with unbounded real kernel stalls.
- [ ] Test healthy two-request reuse through lifecycle collaborator events, then recycling on maximumRequestsPerChild and idle deadline. Label this as lifecycle reuse, not real wire/ICU reuse. Actual wire handshake/terminal parsing and heavyweight release must be tested in the next helper integration plan.
- [ ] Run deterministic and real integration commands on one frozen source; inspect warnings and exact source hashes, scope-format, shell/Python syntax and public-pattern checks. Independent spec/quality review before scoped local commit. No production caller is wired in this plan.

## Integration gates and claim limits

Required next plans: complete wire reader/writer; concrete full-text sink/allocation ledger and measured100MB streaming; actual sequential PadSearchWorker invoking the semantic primitive once; handshake/terminal events linked to this lifecycle; byte reservations and bounded logical queue; packaged resolution/signing; native/folder/open-document consumers. Until those are reviewed and integrated, this lifecycle cannot claim bounded whole-search memory, malformed-IPC containment, no-second-engine invocation across panels, or production search cancellation.

Record separate facts: cancellation/deadline decision timestamp; signal syscall result; observed waitpid exit status; confirmed descriptor cleanup; next launch admission. Timer reaction50ms/reap250ms and all memory/time policy numbers remain **candidate, unmeasured targets**, not real-time guarantees. Existing root probe showed an engine-entered TERM exit and fresh benign child; it did not demonstrate KILL escalation, persistent IPC or RSS. Real100MB input may mean200MB UTF-16 wire data and up to300MB UTF-8 per String; this lifecycle carries no such allocations and cannot validate their budget.

In particular, the parent's source/replacement pair can occupy600MB UTF-8 payload at100M units each, while the helper's independent String-to-NSString/regex bridge may simultaneously add200MB UTF-16 plus its own Swift input/output. The earlier640MB active-ledger candidate has been rejected by the reviewed allocation preflight; no replacement active budget is adopted. Neither a logical parent reservation nor wire byte counts bound helper memory. The allocation stage must measure/account all simultaneous bridges, decoder growth, allocator/ICU state and ownership before routing is enabled; choose budgets from that evidence without silently reducing supported input. This lifecycle plan establishes only process/channel ownership counts, not total RSS containment. Helper signing/resolution is separately reviewed in `docs/superpowers/specs/2026-09-10-search-helper-packaging.md`; generation echoes and local ad-hoc signing are not authentication claims.

The architecture is operational isolation under the same user identity, not a sandbox. No native windows, GUI input, auth changes, remote actions, or physical desktop claims belong to these tests. Bounded shutdown does not supersede durable-document quit safety, and an OS/process scheduling stall may remain unconfirmed without allowing resource duplication.

Self-review: lifecycle work is independent of the active framing implementation; API uses its SearchWireIdentity/SearchWireTerminal only after those types freeze. Real fault fixtures have a checked-in outer watchdog prerequisite. The plan separates trusted collaborator simulations from actual OS effects and keeps all permanent application routing outside this slice. Root reviewed the fixed bootstrap, request admission, descriptor-inheritance dependency and compilable task split before adopting this plan. Dispatch follows complete wire approval; no lifecycle implementation is currently active.


## Root review rulings

- Use mandatory `--generation <UUID>` supplied before constructing the wire reader. Hello echoes correlation; it does not invent or authenticate identity.
- Validate structural executable URL shape synchronously, filesystem properties only on the retained launch lane under the operation deadline. Reject zero request IDs before side effects.
- Task1 has only injected interfaces and deterministic test conformers; add public production construction with actual launch/channel code in Task2. This prevents unimplemented production stubs.
- Actual Foundation external-command launch in `Sources/PadCore/ExternalCommand.swift` remains a required descriptor-inheritance integration check before production routing. No leak is claimed from source review alone.
- Buffer accounting does not imply RSS containment. Allocation and native integration remain separately planned/verified work.


## Task 2 implementation review, 2026-09-10

SDK preflight typechecked the Darwin interfaces at the macOS 14 deployment target. `pipe2` and function-like wait-status macros are unavailable to Swift; use `pipe` with immediate close-on-exec setup and a tested terminal-status decoder. Dispatch source cancellation must acknowledge completion before its descriptor is closed. These are SDK/compile findings, not runtime evidence.

Root accepted five bounded slices: A, checked-in watchdog and pure ordering tests; B, nonblocking channels; C, launcher and fixed synthetic fixture; D, timer/lifetime utility and temporary integration harness; E, real lifecycle integration and public construction. Move D's temporary-package infrastructure ahead of B's actual pipe tests. Keep production search routing disabled throughout this plan.

Slice A is authorized first. Before real self-controls, independently review its pure tests and source: observe the unreaped group leader through kqueue, clean only its owned group, then wait; bounded fair output capture; signal/exception cleanup; no numeric process scan or early Popen polling. The existing private build watchdog is not a substitute. Expected timeout statuses belong only to explicit watchdog self-controls.

Retain the reviewed 100 ms lifecycle polling cadence without adding another reaper. Channels admit one read, one active write and one queued bounded write; uncertain close remains unconfirmed. Launcher reads the parent SIGCHLD policy and refuses auto-reaping without changing it. The existing external-command Foundation.Process launch may overlap pipe-to-fcntl setup; descriptor inheritance remains a production-enablement audit requirement. No runtime inheritance result is claimed.

## Channel implementation boundary

The watchdog and frozen harness are accepted at `5587d43` and `0030b47`. The next independently reviewed slice owns only `SearchChildChannels.swift`, `Tests/SearchChildIntegration/SearchChildChannelTests.swift`, and fixed test inclusion in the existing harness/pure tests. First execute injected state tests; actual pipe controls require separate implementation review. No launcher, helper, public lifecycle constructor or application routing is included.

Adoption transfers three distinct, exclusively owned parent endpoints above descriptor 3, already configured with close-on-exec, required nonblocking flags and verified per-descriptor SIGPIPE suppression. The I/O queue owns all operations and closure. Admission reserves at most one read and two writes before queueing; each write is at most 65,536 bytes, each read bound is 1…65,568. Pumps perform at most four syscalls and 65,536 bytes per turn, with balanced idle source suspension and at most one continuation pump.

Cancellation decides the operation result once. It cannot retract an already-written prefix or interrupt an in-flight syscall; no new syscall begins after the I/O queue observes cancellation/closure. Source cancellation handlers own monitored-descriptor closure, and one shared close completion waits for all confirmed closes. An uncertain close is never retried against the integer and never reported as acknowledged. Injected schedules and actual OS observations remain separate evidence.

Acceptance includes queue bounds, partial I/O, EAGAIN/EINTR fairness, early/late cancellation, EOF, source teardown, facade loss, exact close ownership and quarantine. After code review, the separately filtered synthetic-pipe suite tests real bytes/backpressure/EOF/EPIPE and safe descriptor reuse under the accepted watchdog. It must not overwrite an unowned descriptor or alter parent-global signal policy. Passing this slice will not establish child reap, helper containment, whole-search memory or large-file performance.
