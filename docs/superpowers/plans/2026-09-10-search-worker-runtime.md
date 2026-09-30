# PadSearchWorker Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task, with genuine red/green evidence and an independent review after each task. Do not dispatch overlapping workers against the wire, lifecycle, allocation, or packaging owners.

**Goal:** Build the sequential `PadSearchWorker` runtime that accepts the approved binary protocol on stdin, invokes the existing `SearchService.execute` primitive exactly once per accepted request, writes a complete response, releases request-heavy state before its terminal, and acknowledges the request only after the terminal write succeeds.

**Architecture:** A package-internal `PadSearchWorkerRuntime` target owns a synchronous, single-lane request loop and an injected caller-owned text accumulator. The shipped executable is a minimal bootstrap over bounded blocking stdin/stdout and a separate parent-lifetime watcher; the parent lifecycle and its asynchronous transport remain separate owners. The concrete accumulator and production target are adopted only after the reviewed allocation experiment selects a qualifying implementation.

**Tech Stack:** Swift Package Manager, Swift 6 toolchain in Swift 5 language mode, macOS 14, Foundation, Darwin, `PadCore`, and `SearchExecution`; no new dependency, AppKit, shell protocol, network access, document paths, or file writes.

**Spec:** `docs/superpowers/specs/2026-09-10-supervised-search.md`; wire contract `docs/superpowers/plans/2026-09-10-search-wire-protocol.md`; lifecycle contract `docs/superpowers/plans/2026-09-10-search-child-lifecycle.md`; allocation gate `docs/superpowers/specs/2026-09-10-search-text-allocation.md`; packaging handoff `docs/superpowers/specs/2026-09-10-search-helper-packaging.md`.

**Status:** Task1 injected loop/collector implemented and independently approved2026-09-30, with21/0 final tests and actual public-target build; see `docs/verification/search-worker-runtime.md`. Task2 exact engine adapter independently approved2026-09-30 with42/0 combined tests and compiling RED21/19. Tasks3–6 and GateA remain outstanding. Historical reviewed-plan baseline follows: Independent drafting and root review resolved dependency ordering, error classification, test seams and bootstrap decisions. No runtime, executable, process evidence, allocator choice, RSS ceiling, deadline policy, packaging or production routing is implemented by this plan. Wire and lifecycle prerequisites remain outstanding.

## Global constraints

- The helper processes exactly one request at a time and has no queue. A healthy process may serve later sequential requests only after terminal write and exact `RequestReader.acknowledgeTerminal` succeed.
- The helper calls only `SearchService.execute(_:in:scope:operation:)`. It does not call `matches`, `replacing`, or perform a second matching pass.
- `SearchWireRequestReader.consume` and all sink callbacks must unwind before text finalization or engine execution begins. A pending execute event is discarded if any later coalesced frame makes that same `consume` call fail.
- The helper writes `responseBody` while input, regex/checking results, and output are in the request-heavy scope. Only the identity and typed terminal leave that scope. It releases the request/accumulator owner and drains the autorelease pool before writing terminal.
- Only a successful complete terminal write permits acknowledgement. A body/terminal write failure, protocol error, local codec error, bootstrap error, or internal sink failure causes process exit without acknowledgement or a fabricated semantic terminal.
- Only a `SearchError` caught directly around the single `engine.execute` call becomes `SearchWireTerminal.failure`. An accumulator, response writer, channel, or other sink that happens to throw the same Swift error type is still a fatal local/transport failure. Do not translate `SearchWireError`, I/O failure, allocation/sink failure, or arbitrary errors into a semantic engine error.
- Construct `SearchService` from every request's explicit `maxTextUTF16`, `maxMatches`, `maxOutputUTF16`, and `cooperativeMilliseconds`. Convert milliseconds to seconds exactly; zero remains zero. Hard cancellation/deadline remains parent-owned forced termination, not a helper cancel frame.
- Use stdin fd 0 for requests, stdout fd 1 for responses, and control fd 3 for the parent-lifetime reader. No text, pattern, template, document path, arbitrary mode, or diagnostics appear in argv, stderr, temporary files, or logs.
- The helper's main runtime lane may block on its own bounded pipe reads/writes. The parent-lifetime watcher runs independently and calls `_exit` on control EOF. No codec, engine, or callback runs on the lifecycle control queue.
- No source task adopts an active/retained byte ledger or claims an RSS ceiling. The selected text accumulator and supported production reservation remain blocked on the full reviewed allocation matrix.
- Real child/fault tests run only under the lifecycle plan's checked-in owned-process watchdog. Unit tasks below launch no processes. No visible GUI, network, physical-input, or native-document claim follows from this plan.

## Reviewed inputs and current dependency state

Drafted from repository HEAD `c9df35862fd9fe78ad6cd4a4934255af8ae787a2` with these inspected Git object IDs:

| Input | Git object |
| --- | --- |
| Supervised-search spec | `a2cc761d6e943ad9bbc00f18952d72ff5e3cafe7` |
| Wire plan | `af00e8d01ca4949fa1f7e5b21bcbe3b184eb5cc8` |
| Public lifecycle plan | `ee0c18b3f90ed55676a4185ae0027d6a477aafdb` |
| Public allocation specification | `a884b6d0333bb375eeca1767d0e7f1acfb81c89a` |
| Public helper-packaging specification | `39c36e9fb74a710d1ebb410c88bfc66d56d7876d` |
| `SearchService.swift` | `da1add7fece12f26fa48ff51c5a6a4983a2ef107` |
| `Package.swift` | `5ea5316237293cc409c28c478f73b538dc5e3492` |

Dependencies are staged rather than global:

1. Runtime Tasks 1 and 2 may begin after wire Tasks 3A, 3B, and 4 are independently approved: they need the final request/response values, readers, writers, returned parent boundary index, and benign semantic handoff. They use only injected in-process collaborators and launch no helper.
2. Runtime Task 3 additionally waits for lifecycle Tasks 1-3, especially `SearchParentLifetime.run(controlFD:)`, the real launcher fd contract, parent EOF behavior, and the owned-process watchdog.
3. Gate A then waits for Tasks 1-3 plus a separately reviewed parent wire driver. `SearchChildConnection.write/read` are async, while wire writer emit callbacks are synchronous. The parent driver must use one explicitly bounded codec lane and bounded rendezvous/backpressure; it may not `await` inside the callback, create one task per chunk, block the lifecycle control queue, parse its outgoing request, or traverse the full source again. Response parsing remains gated until `Writer.request` returns its completed index and `ResponseReader.expect` accepts it.
4. With that real driver and Task 3 runtime composition available, Gate A runs the actual parent/helper candidate matrix required by the public allocation specification. Only its reviewed result permits Task 4 to add a production accumulator and shipped executable. A microprobe or helper-only measurement cannot select the sink.

The active request-codec working tree is not a frozen dependency. Executors must record the approved commit and source hashes when each prerequisite lands.

Before freezing Task 3A, require the request-side counterpart of the terminal/trailing-header rule: after `FrameDecoder.consume` returns in the executing phase, any nonzero decoder `bufferedByteCount` is an invalid premature next request and poisons `RequestReader`. A complete execute followed by a partial next header must therefore make the outer consume fail, allowing this runtime to discard its recorded execute and invoke the engine zero times. Buffered partial headers remain valid while awaiting or receiving a request; this check is phase-specific.

## File and module ownership

The proposed module split prevents the app from importing helper implementation and lets the runtime be tested without an `@main` process:

| File | Responsibility |
| --- | --- |
| `Sources/PadSearchWorkerRuntime/SearchWorkerInterfaces.swift` | Package-only synchronous channel, accumulator, engine, pending-work, and exit types. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerRequestSink.swift` | Caller-owned request collector; accumulates decoded UTF-8 and records hello/execute events without running the engine. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerRuntime.swift` | Sequential reader loop, event drain, heavy scope, response/terminal ordering, and acknowledgement. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerSearchService.swift` | Exact per-request `SearchService` adapter. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerBootstrap.swift` | Exact argv validation and numeric process-exit mapping. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerBlockingChannel.swift` | Bounded EINTR/short-I/O loops over fd 0/1 and per-descriptor broken-pipe handling. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerProgram.swift` | Bootstrap composition and independent fd 3 lifetime-thread start. |
| `Sources/PadSearchWorkerRuntime/SearchWorkerTextAccumulator.swift` | The single measured and reviewed production accumulator; this file is created only after selection. |
| `Sources/PadSearchWorker/main.swift` | Minimal shipped entry calling `SearchWorkerProgram`. |
| `Tests/PadSearchWorkerRuntimeTests/*.swift` | No-process deterministic runtime, semantic-adapter, bootstrap, and I/O seam tests. |
| `Tests/SearchWorkerAllocation/*` | Synthetic candidate and measurement driver sources used only by the ignored measurement package. |
| `Tests/SearchWorkerIntegration/*` | Real helper/lifecycle/wire fixtures, never an ordinary core-test dependency. |
| `scripts/measure-search-worker-allocations.sh` | Frozen-source allocation matrix driver under the owned watchdog. |
| `scripts/test-search-worker-runtime.sh` | Frozen-source real helper test driver under the owned watchdog. |

Task 1 adds `.target(name: "PadSearchWorkerRuntime", dependencies: ["PadCore", "SearchExecution"])` and `.testTarget(name: "PadSearchWorkerRuntimeTests", dependencies: ["PadSearchWorkerRuntime", "PadCore", "SearchExecution"])`. It adds no executable product or placeholder implementation. The executable product/target is added only after a concrete accumulator qualifies. Packaging files remain owned by the separate helper-packaging plan.

## Interfaces to freeze

These are the final interfaces across tasks, not a request to commit unused seams. Task1 adds only its channel/accumulator/engine/collector/runtime types. Task2 adds the Foundation adapter. Task3 adds IOSystem/IOFailure/FDChannel/ChannelFactory/bootstrap/program with their working implementations.

Use package access for runtime seams so the executable and test/measurement targets in this package can compose them without making them public API:

```swift
package protocol SearchWorkerBlockingChannel: AnyObject {
  // maxBytes is required to be 1...65_568; empty Data means actual EOF.
  func read(maxBytes: Int) throws -> Data
  // bytes is required to be nonempty and <=65_536.
  func write(_ bytes: Data) throws
}

package struct SearchWorkerIOFailure: Error, Equatable {
  package let code: Int32
}

package struct SearchWorkerIOSystem {
  package let setNoSigPipe: (Int32) -> Result<Void, SearchWorkerIOFailure>
  package let read: (
    Int32, UnsafeMutableRawBufferPointer
  ) -> Result<Int, SearchWorkerIOFailure>
  package let write: (
    Int32, UnsafeRawBufferPointer
  ) -> Result<Int, SearchWorkerIOFailure>
  package static let darwin: SearchWorkerIOSystem
}

package final class SearchWorkerFDChannel: SearchWorkerBlockingChannel {
  package init(inputFD: Int32, outputFD: Int32, system: SearchWorkerIOSystem) throws
  package func read(maxBytes: Int) throws -> Data
  package func write(_ bytes: Data) throws
}

package typealias SearchWorkerChannelFactory =
  (_ inputFD: Int32, _ outputFD: Int32) throws -> any SearchWorkerBlockingChannel

package protocol SearchWorkerTextAccumulator: AnyObject {
  func appendUTF8(_ bytes: Data) throws
  // Called once, only after the successful RequestReader.consume has unwound.
  func finish() throws -> String
}

package typealias SearchWorkerAccumulatorFactory =
  (_ expectedUTF16: Int) throws -> any SearchWorkerTextAccumulator

package protocol SearchWorkerEngine {
  func execute(_ request: SearchWireRequest, text: String) throws -> SearchExecutionOutput
}

package struct SearchWorkerPendingRequest {
  package let request: SearchWireRequest
  package let accumulator: any SearchWorkerTextAccumulator
}

package final class SearchWorkerRequestCollector: SearchWireRequestSink {
  package init(makeAccumulator: @escaping SearchWorkerAccumulatorFactory)
  package func takeHelloGeneration() -> UUID?
  package func takeSealedRequest() -> SearchWorkerPendingRequest?
  package func discard()
  // The four SearchWireRequestSink requirements are implemented with the
  // phase behavior below; none invokes the engine or a wire writer.
}

package enum SearchWorkerRunExit: Equatable {
  case cleanEOF
  case protocolFailure
  case inputSinkFailure
  case inputFailure
  case outputFailure
  case internalFailure
}

package final class SearchWorkerRuntime {
  package init(
    generation: UUID,
    channel: any SearchWorkerBlockingChannel,
    makeAccumulator: @escaping SearchWorkerAccumulatorFactory,
    engine: any SearchWorkerEngine
  ) throws
  package func run() -> SearchWorkerRunExit
}

package struct SearchWorkerBootstrap: Equatable {
  package let generation: UUID
  package static func parse(arguments: [String]) throws -> SearchWorkerBootstrap
}

package enum SearchWorkerBootstrapError: Error, Equatable {
  case invalidArguments
}

package struct FoundationSearchWorkerEngine: SearchWorkerEngine {
  package init()
  package func execute(
    _ request: SearchWireRequest, text: String
  ) throws -> SearchExecutionOutput
}

package enum SearchWorkerProgram {
  package static func run(
    arguments: [String],
    inputFD: Int32,
    outputFD: Int32,
    controlFD: Int32,
    makeChannel: @escaping SearchWorkerChannelFactory,
    makeAccumulator: @escaping SearchWorkerAccumulatorFactory,
    startParentLifetime: @escaping (Int32) -> Void
  ) -> Int32
}
```

`SearchWorkerProgram` maps cleanEOF to0, bootstrap refusal to64, protocolFailure to65, inputSinkFailure/internalFailure to70, and inputFailure/outputFailure to74. A thrown channel read is inputFailure; successful empty read is EOF and still requires reader.finish. Accumulator failure is not an input I/O failure. These codes are process diagnostics for the parent lifecycle; they never become `SearchError` or wire strings. After bootstrap succeeds, Program asks `makeChannel` for exactly one channel, starts the lifetime watcher, and constructs the runtime with a fixed `FoundationSearchWorkerEngine()` internally. There is no engine parameter or production engine-selection seam. No-process Program tests inject a scripted channel factory whose object ignores the placeholder fd values; they never pass fake fd 0/1 into real Darwin reads. Runtime tests continue to inject their engine directly.

The shipped `main.swift` supplies fd 0/1/3, a channel factory constructing `SearchWorkerFDChannel(inputFD:outputFD:system: .darwin)`, the selected accumulator factory, and a starter that launches one dedicated thread executing `SearchParentLifetime.run(controlFD: 3)`.

`SearchWorkerBootstrap.parse` accepts exactly three arguments: executable name, the literal `--generation`, and one 36-character hyphenated canonical UUID. Hex letter case is accepted case-insensitively; braces, missing hyphens, whitespace, extra fields, malformed text, and the all-zero UUID are rejected. The lifecycle launcher emits `UUID.uuidString` in canonical uppercase form. The generation is correlation, not authentication.

## Runtime phase and ownership contract

The runtime holds one `SearchWireRequestReader` and one `SearchWorkerRequestCollector`. The collector owns these phases:

```text
awaitingHello
ready
receiving(request, accumulator)
sealed(request, accumulator)
```

- `helloAccepted` records a bounded hello event only.
- `begin` creates exactly one accumulator using `request.inputUTF16` and stores the small request metadata.
- `appendInputUTF8` forwards each nonempty decoder chunk synchronously; it does not retain a callback array or encoded document.
- `execute` verifies the exact current identity, changes `receiving` to `sealed`, and records one execute event. It does not call `finish`, `SearchService`, a writer, acknowledgement, or arbitrary external code.
- After `RequestReader.consume` returns successfully, the runtime drains hello before execute if both arrived in one transport read. It writes childHello outside the reader callback, then takes the sealed accumulator, calls `finish`, and executes.
- If `consume` throws after recording execute because a later coalesced frame is illegal, the runtime destroys the sealed accumulator, invokes the engine zero times, writes no response/terminal, and exits with protocol failure.
- While an execute event is pending or running, the runtime performs no next stdin read. After a successful terminal write it calls `acknowledgeTerminal` outside every callback; only then may it read the next request.

The heavy operation must have this lexical ownership shape:

```swift
// Enter only after a sealed request was validated; absence is internal failure.
var work: SearchWorkerPendingRequest? = sink.takeSealedRequest()
let identity = work!.request.identity
let terminal = try autoreleasepool {
  defer { work = nil }  // release the final request owner before the pool drains
  return try executeAndWriteBody(work!)
}
try SearchWireWriter.terminal(identity, result: terminal) { try channel.write($0) }
try reader.acknowledgeTerminal(identity)
```

`executeAndWriteBody` calls `accumulator.finish`, invokes `engine.execute` once, checks result shape/count/length against that request, constructs `SearchWireResponse`, and finishes `responseBody`, all inside the caller's one `autoreleasepool`. The concrete engine adapter constructs the exact per-request `SearchService` inside that one call. The runtime's `do/catch let error as SearchError` surrounds only `engine.execute(request, text:)`; it returns `.failure(error)` from that direct call. Accumulator finalization occurs before that catch, and result validation/response writing occurs after it, so an accumulator, writer, or channel throwing a value that happens to be `SearchError` remains fatal. The function otherwise returns `.success` and must not return the input, response, replacement, match array, checking results, service, or an escaping closure. The caller clears its final `work` owner in the pool closure before the pool drains, including on errors, and only then writes terminal. Source review and allocation observations must verify this shape; the terminal itself is not proof that allocator pages returned.

For replacement, compute `replacementUTF16` inside the heavy scope and pass it to `SearchWireResponse`; nil means find and zero means an empty replacement. The helper additionally checks `output.matches.count <= request.limits.maxMatches`, replacement length `<= request.limits.maxOutputUTF16`, and find/replace result shape before responseStart. The response writer still validates signed/global ranges, and the parent response reader remains authoritative for original input, scope, scalar endpoints, ordering, and per-request limits.

## Error and exit table

| Event | Wire action | Ack | Process action |
| --- | --- | --- | --- |
| Valid `SearchError` from the one engine call | After heavy-scope exit, write matching failure terminal | Only after full terminal write | Continue healthy sequential loop |
| Successful engine output and body | After body completes and heavy-scope exit, write success terminal | Only after full terminal write | Continue healthy sequential loop |
| Malformed request/phase/identity/UTF-16/EOF | No semantic terminal | Never | Close/exit protocol failure; parent stops/reaps |
| Accumulator or local result-shape failure | No semantic terminal | Never | Exit internal/input-sink failure; parent stops/reaps |
| Response-body codec failure | No later terminal | Never | Exit internal/protocol failure; parent stops/reaps |
| Channel read failure | No semantic terminal | Never | Exit input I/O failure74; parent owns cleanup |
| Body or terminal fd write failure | No retry or later frame | Never | Exit output I/O failure74; parent owns cleanup |
| Exact EOF while reader is ready after hello | None | Not applicable | `finish` succeeds; exit 0 |
| EOF before hello or during request/execution | No semantic terminal | Never | `finish` rejects; exit protocol failure |
| Parent-lifetime fd 3 EOF | None | Not applicable | Independent watcher calls `_exit(0)` even if main/engine is blocked |

The current complete-result `SearchService` cannot produce a semantic error after `responseBody` begins: engine errors occur before a body exists. Do not manufacture the protocol's allowed partial-body/failure form. A writer/I/O failure after a partial body is fatal instead.

## Task 1 — Sequential runtime and caller-owned request sink

**Files:** modify `Package.swift`; create `SearchWorkerInterfaces.swift`, `SearchWorkerRequestSink.swift`, `SearchWorkerRuntime.swift`, and `Tests/PadSearchWorkerRuntimeTests/SearchWorkerRuntimeTests.swift`.

**Consumes:** independently approved complete wire API. **Produces:** a fully functioning injected runtime with no default channel, engine, accumulator, executable, or throwing placeholder.

- [ ] Add the runtime/test targets and compile-only interfaces. Record setup compilation separately; do not call a missing target a behavioral red.
- [ ] Write the principal behavioral red with one scripted read containing a valid execute followed first by a complete illegal next-request frame and then, in a separate case, by only a partial next header. Assert the sink recorded execute, engine invocation count is zero, response writes are empty, the accumulator is released, and `run` reports protocol failure in both cases.
- [ ] Implement the sink phases and runtime event drain minimally. Set sink/reader phases before callbacks, preserve reviewed poison behavior, and discard all recorded events on an unsuccessful consume.
- [ ] Add a valid two-read/two-request fixture. The first terminal must be completely accepted by the scripted writer before the second `read` occurs; assert exact identities/ordinals, one engine call per request, one response body and terminal per request, and clean EOF only after both acknowledgements. Decode output with fixed expected values, not only a writer round trip.
- [ ] Add sink refusal, external write refusal at body and terminal, EOF before hello/mid-request/ready, hello+execute coalescing, and reentrant callback controls. Add a same-type regression in which `accumulator.finish` throws `SearchError.invalidPattern`, and another in which the response emit sink throws a `SearchError`; both must be fatal runtime/output failures with no semantic terminal or acknowledgement. Assert no next read after an unacknowledged terminal and no semantic error for codec/I/O failures.
- [ ] Run proposed focused command `scripts/swift.sh test --scratch-path .build/search-worker-runtime --filter SearchWorkerRuntimeTests`. Retain genuine behavioral RED, implement, then rerun unchanged to GREEN. Run scoped format/public/diff checks and independent review before a scoped commit.

## Task 2 — Exact `SearchService` adapter and heavy-scope ordering

**Files:** create `SearchWorkerSearchService.swift` and `Tests/PadSearchWorkerRuntimeTests/SearchWorkerSearchServiceTests.swift`; extend runtime tests only for release-order assertions.

**Consumes:** Task 1 `SearchWorkerEngine` and runtime. **Produces:** `package struct FoundationSearchWorkerEngine: SearchWorkerEngine` with no implicit limits.

- [ ] Red-test that the adapter constructs a service from the request limits and produces fixed literal/regex/escaped, scope, NUL, optional-capture, zero-length EOF, and emoji outputs. Include `(a)` replacing `$1!` in `a a` with ranges `(0,1),(2,1)` and exact output `a! a!`.
- [ ] Test exact-boundary `maxTextUTF16`, explicit small `maxMatches` and `maxOutputUTF16` failures, invalid escape/pattern/replacement, scalar-safe scope, and zero cooperative milliseconds. Assert the exact helper-reachable `SearchError` terminal code and that malformed wire remains a runtime protocol failure. `textLimit` and `invalidScope` are parent admission outcomes for local requests; input-over-limit or invalid-scope wire is rejected by request validation before the engine and must not be relabeled as a helper semantic terminal.
- [ ] Use the Task 1 injected engine counter to retain the one-call oracle and to verify `.engineFailure` maps to its terminal only when thrown directly by `engine.execute`. The existing deterministic engine-failure seam is internal to `PadCore` tests and cannot be called through the actual adapter target; do not claim an actual Foundation engineFailure fixture. Review `FoundationSearchWorkerEngine` source for exactly one call to `SearchService.execute` and no calls to the wrappers. Do not infer invocation count from equal output alone.
- [ ] Add a release-order fixture whose accumulator owner is weakly observable. The terminal-header write must observe that owner released and the body completed; a terminal-payload failure must leave acknowledgement absent. Label this as logical owner/autorelease-scope ordering, not RSS or Foundation heap release.
- [ ] Run proposed focused commands `scripts/swift.sh test --scratch-path .build/search-worker-runtime --filter SearchWorkerSearchServiceTests` and `--filter SearchWorkerRuntimeTests`; scope-format and independently review before commit. Do not run adversarial core regex suites.

## Task 3 — Bootstrap, bounded helper-side fd I/O, and lifetime composition

**Files:** create `SearchWorkerBootstrap.swift`, `SearchWorkerBlockingChannel.swift`, `SearchWorkerProgram.swift`, and `Tests/PadSearchWorkerRuntimeTests/SearchWorkerProgramTests.swift`.

**Consumes:** Task 1 runtime, Task 2 engine, and reviewed `SearchParentLifetime`. **Produces:** testable concrete worker program composition while still requiring an injected accumulator; no shipped executable yet.

- [ ] Red-test exact argv refusal before channel construction/lifetime start: missing/duplicate/extra/malformed/zero generation returns 64 and performs zero reads/writes. Valid bootstrap starts the fd 3 watcher exactly once before the first stdin read and binds RequestReader to that generation.
- [ ] Implement a bounded Darwin channel: read requests only in `1...65_568`, allocate at most that chunk, return empty only on actual EOF, and retry EINTR. Write accepts only `1...65_536`, loops over short writes, retries EINTR, and fails closed on zero/other errors. Install and verify per-fd `F_SETNOSIGPIPE` for stdout rather than changing process-global SIGPIPE policy.
- [ ] Use the exact `SearchWorkerIOSystem` closures for deterministic zero/short/EINTR/EPIPE and oversize channel tests; separately source-review `.darwin` for immediate errno capture. Keep concrete Darwin calls in the same implementation. No test blocks on a deliberately full real pipe without the owned-process watchdog.
- [ ] Verify `SearchWorkerProgram` with an injected scripted `SearchWorkerChannelFactory`: it emits no stderr/stdout diagnostics beyond protocol bytes, never constructs a real fd channel from fake fd values, starts no channel/engine/lifetime work after bootstrap refusal, constructs the fixed Foundation engine only after valid bootstrap/channel setup, and maps runtime exits to 0/65/70/74 exactly. The lifetime starter must run a dedicated thread; it never shares the request loop or waits for it.
- [ ] Confirm with the lifecycle launcher owner that child fd 0/1 are blocking and fd 3 is the sole lifetime read end after spawn. Parent-side nonblocking configuration must not leak onto the child endpoints.
- [ ] Run proposed command `scripts/swift.sh test --scratch-path .build/search-worker-runtime --filter SearchWorkerProgramTests`; rerun all three runtime filters, scope-format, and independently review before commit.

## Gate A — Parent driver and allocation evidence

Do not create `SearchWorkerTextAccumulator.swift`, `Sources/PadSearchWorker`, or the executable product before this gate passes.

The separate parent-driver deliverable must expose one operation that owns the returned boundary index through complete response validation and integrates exact lifecycle events. Its implementation must prove bounded backpressure between synchronous wire callbacks and async `SearchChildConnection`; this worker plan does not prescribe an unsafe adapter. The driver must stop feeding response bytes until `ResponseReader.expect` succeeds, and it must keep codec/read reservations until callbacks and lanes quiesce after cancellation.

Then implement the public allocation specification's real two-process matrix using Task 3 program composition with measurement-only candidate factories. The ignored measurement package may choose a candidate by fixed synthetic fixture ID; the shipped executable may not expose such an option. Required fixtures and ownership gates are exactly those in `docs/superpowers/specs/2026-09-10-search-text-allocation.md`: cold and warm/recycle sequences, 1/10/100 MB and applicable 100M-unit cases, Unicode encodings, 100,000 matches, near-one-million retained capture ranges, successful replacement, zero-match replacement, output-limit and healthy semantic failures, bounded digests, time-aligned parent/helper RSS, heavy-scope/terminal/reap observations, and no harness-owned full payload copies.

Proposed command after the watchdog and parent driver exist:

```sh
scripts/measure-search-worker-allocations.sh
```

The script must record its finite diagnostic watchdog configuration and explicit per-fixture semantic limits in private output. It must not turn that timeout into production policy. Root review selects a helper input accumulator only if it completes every supported fixture, exact output/digests match, no full-size intermediate is uncharged, and the ownership/recycle evidence passes. RSS informs suitability and never supplies ledger credits. If no candidate qualifies, revise the sink/budget under review and repeat; do not reduce the 100M-unit contract.

The parent response accumulator may require a different selection. Its owner must record that choice separately; helper-input evidence cannot silently authorize the parent sink.

## Task 4 — Adopt the measured accumulator and add `PadSearchWorker`

**Files:** create `SearchWorkerTextAccumulator.swift` and `Sources/PadSearchWorker/main.swift`; modify `Package.swift` to add `.executable(name: "PadSearchWorker", targets: ["PadSearchWorker"])` and `.executableTarget(name: "PadSearchWorker", dependencies: ["PadSearchWorkerRuntime"])`; add `Tests/PadSearchWorkerRuntimeTests/SearchWorkerTextAccumulatorTests.swift`.

**Consumes:** approved Gate A selection record and Tasks 1-3. **Produces:** the actual local helper executable product. It does not package or route the app.

- [ ] Copy the selected candidate algorithm into the production accumulator file without measurement switches. Name the concrete factory `measuredSearchWorkerAccumulator(expectedUTF16:)`. Record the selection evidence/hash and every charged buffer/lifetime; do not copy an unselected comparator.
- [ ] Red-test incremental ASCII/BMP/supplementary/decomposed input, split source frames, exact 0 and 100M constructor bounds without allocating fake maximum text, finish-once behavior, declared UTF-16 mismatch, callback/input failure, and release after finish. Exact UTF-8/UTF-16 values are the oracle.
- [ ] Implement the production accumulator exactly as measured. It retains one final `String` representation plus only the measured bounded temporary state; it never retains all callback `Data`, a full wire `Data`, or a second final text.
- [ ] Add minimal `main.swift`: pass `CommandLine.arguments`, fd 0/1/3, the concrete Darwin channel factory, the measured accumulator factory, and the dedicated `SearchParentLifetime` starter to `SearchWorkerProgram.run`, then exit with that status. Program constructs its fixed `FoundationSearchWorkerEngine` internally. No environment/config defaults, paths, diagnostics, AppKit, or alternate engine.
- [ ] Build only the helper with proposed command `scripts/swift.sh build --scratch-path .build/search-worker-runtime --product PadSearchWorker`; run the focused accumulator/runtime tests, scope-format, public-pattern/diff checks, and independent review before commit. A build is not process, package, cancellation, or RSS evidence.

## Task 5 — Actual sequential helper through lifecycle and wire

**Files:** create `Tests/SearchWorkerIntegration/PadSearchWorkerIntegrationTests.swift` and `scripts/test-search-worker-runtime.sh`; adjust only the dedicated integration-package manifest owned by the lifecycle runner if required.

**Consumes:** actual parent driver, lifecycle launcher/channels/reaper/watchdog, complete wire, and Task 4 executable. **Produces:** bounded real-process evidence for the local helper, not packaged/native routing.

- [ ] Make the script freeze actual PadCore/SearchExecution/runtime/helper/driver/lifecycle sources and hashes into an ignored package, build the real helper, and run only `PadSearchWorkerIntegrationTests` under `scripts/run-owned-search-tests.py`. Cap stdout/stderr evidence as in the lifecycle plan; protocol stdout is consumed by the driver, not copied to logs.
- [ ] Principal real red: launch with the exact generation and fd layout, complete hello, execute two benign requests sequentially in the same PID/generation with ordinals 1 and 2, and assert fixed Unicode find/replace ranges/output. Require one complete terminal per request, lifecycle acceptance after response-reader validation, no second engine result, and clean reuse only after the first terminal/ack sequence.
- [ ] Exercise each helper-reachable `SearchError` with bounded deterministic fixtures: invalidEscape, invalidPattern, invalidReplacement, matchLimit, outputLimit, and timedOut from zero cooperative milliseconds. Verify semantic failure keeps the healthy child reusable. Verify separately that invalid scope/input-over-limit is protocol refusal at this boundary, while parent admission owns user-facing invalidScope/textLimit before launch. Cancellation is parent kill with no terminal. Test engineFailure mapping with the injected runtime engine in a separately labeled isolated composition; do not claim that fixture is the fixed production executable or force a pathological Foundation failure. Never run an unbounded regex outside the owned watchdog.
- [ ] Send malformed/truncated UTF-16, wrong identity/ordinal, an execute followed by an illegal coalesced next request, and close response output during body/terminal. Assert no engine for the coalesced-invalid consume, no fabricated terminal/ack after transport failure, exact child exit/reap/channel close, and no replacement child before those receipts.
- [ ] Close the sole parent-lifetime writer while the fixed production helper is idle and require actual exit plus the lifecycle owner's exact reap. Exercise the busy-main-lane case with a separately labeled runtime composition whose injected engine holds an explicit gate; require the same watcher exit/reap, but do not call that alternate fixture the fixed production executable or Foundation engine-entry evidence. A later actual-Foundation busy case needs its own reliable engine-entry observation under the watchdog. Do not claim a malicious or unschedulable helper bound.
- [ ] Run proposed command `scripts/test-search-worker-runtime.sh`. A watchdog timeout is a failed product test even if cleanup succeeds. Rerun focused no-process runtime tests on the identical frozen source, inspect hashes and warnings, scope-format, and obtain independent review before commit.

## Task 6 — Handoff to packaging and production routing plans

This task changes no worker runtime source. Give the packaging owner the reviewed `PadSearchWorker` product name, fixed bundle destination `Contents/Helpers/PadSearchWorker`, mandatory `--generation <UUID>` bootstrap, fd 0/1/3 contract, exit map, source hash, architecture, and deployment target. Packaging must build explicitly, strip, sign nested-first, inventory/hash in SBOM, validate Mach-O architecture/minimum OS, relocate the archive, resolve only the fixed bundle helper, and run the packaged smoke described in `docs/superpowers/specs/2026-09-10-search-helper-packaging.md`.

Production routing remains blocked on reviewed parent admission/reservations, native/folder/open-document ownership, fixed bundle resolution, packaged helper smoke, and measured policies. Do not add in-process fallback, PATH lookup, a developer override in packaged builds, or claim that local helper integration proves UI responsiveness, process sandboxing, release signing/notarization, allocator bounds, or complete C-07/C-08 acceptance.

## Verification and evidence discipline

Every task records planned, implemented, tested, and blocked state separately with exact source hashes and command output. Unit red must be behavioral after setup compiles. Real-process reds are run only after the watchdog self-controls pass. Tests use synthetic documents and fixed expected values; raw measurement/process logs remain ignored and private. Scoped commits include only each task's owned files and must not consume another worker's staged edits.

Self-review against the spec found no runtime task for parent async bridging, allocation-budget adoption, packaging, native delivery, folder orchestration, open-document search, or UI cancellation; each is deliberately an explicit dependency or later owner above. The runtime plan covers helper bootstrap, bounded helper-side I/O, parent lifetime, caller-owned input construction, one-at-a-time execution, exact per-request semantics, heavy-scope release ordering, terminal/ack sequencing, persistent healthy reuse, and fatal malformed-I/O paths without expanding those claims.

## Frozen root rulings and remaining gates

- Bootstrap accepts canonical hyphenated UUID text case-insensitively and rejects every other form plus zero; the launcher emits `UUID.uuidString` uppercase.
- The helper uses the separate package-only `PadSearchWorkerRuntime` target.
- Helper stdout installs per-fd `F_SETNOSIGPIPE`; real bounded broken-pipe verification under the owned watchdog is required before production acceptance.
- The parent synchronous-writer/async-connection bridge remains a separate unresolved plan and must freeze before Gate A; the current lifecycle interface alone is insufficient.
- The helper accumulator and production reservation remain unselected until Gate A evidence passes. No candidate or byte/RSS policy is chosen in this draft.

## Root review record

The initial private draft had a circular allocation prerequisite, a mismatched Program engine parameter, an overly broad semantic-error catch, an inaccessible cross-module test seam and private document references. All five were corrected before adoption. Root additionally made input I/O failure distinct from accumulator failure, staged interface declarations with their working tasks, and placed final request-owner release inside the autorelease pool before it drains. The partial-frame rules are frozen in the public wire plan (response5ecd6d8, requesta45d6b1); same-consume provisional callbacks must be discarded on failure. Later-arriving bytes cannot undo an execution already scheduled after an earlier successful consume. This review is plan acceptance only, not runtime verification.
