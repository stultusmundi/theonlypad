# Parent wire driver implementation plan

> Status: Task 1 bridge/lane is implemented and independently reviewed with 20 passing injected tests; Task2 codec session is implemented and independently reviewed with21 behavior tests plus114 wire tests passing; Task3 driver is under private implementation and review, with25 focused tests passing at the accepted ownership-fix checkpoint; broader cases and the checked-in instrumented runner remain outstanding. This plan defines the parent wire driver only. It does not select an allocator, set production byte/deadline policy, add native or folder routing, or establish process/RSS acceptance.

**Goal:** Connect the synchronous search wire codecs to the asynchronous owned-child connection with bounded backpressure, preserve lifecycle first-outcome rules, and make a persistent generation reusable only after the prior codec, result, and read handoff are settled.

**Architecture:** One package-internal `SearchParentWireDriver` is the exclusive higher owner of one `SearchChildLifecycle`. It admits no queue and runs at most one request. A retained dedicated codec thread owns every mutable wire codec. Each synchronous writer invocation uses a fresh single-slot rendezvous whose async consumer performs one complete `SearchChildConnection.write` before acknowledging the exact emission. One retained asynchronous read path stays armed across idle and next-request upload; it holds at most one completed read until `ResponseReader.expect` has installed the returned request boundary index. The driver owns the sole lifecycle observer for each ticket and exposes a separate detachable result observer.

**Inputs:** the supervised-search specification, final wire plan, child-lifecycle plan, worker-runtime plan and allocation preflight. The actual `SearchService` remains child-side; the driver never calls it.

## Review and inputs

Reviewed against the supervised-search, wire, lifecycle, worker-runtime and allocation plans. Wire response source869de1f is independently approved; semantic Task4 is active. Root review resolved handshake fragmentation, codec-inclusive staging, accepted-result preservation after idle-read failure and one-shot result ownership. Final independent review found an asynchronous upload-consumer lifetime gap; the explicit consumer-exit latch and combined release/publication/admission/shutdown predicates below resolve it. No implementation or runtime acceptance follows from plan review.

The typed channel-observation seam was independently extracted and implemented as a Task3 prerequisite at `5e562fc`: nine added tests,45 lifecycle cases and the final80-case peer/lifecycle selection pass. The full driver remains unimplemented; this early prerequisite does not imply Task3 completion.

Recheck dependency source and interface hashes at dispatch. The internal typed channel-observation addition below is approved for driver Task3 only if the implemented lifecycle lacks an equivalent; avoid duplicate events.

## Dependency order without a cycle

1. Wire Tasks 3A, 3B, and 4 must be independently approved before driver codec-session work. In particular, both readers must contain their phase-specific partial-trailing-frame checks, and `SearchWireWriter.request` must return the completed identity-bound `SearchWireBoundaryIndex` only after execute emission succeeds.
2. Driver Task 1 needs the final frame/writer limits and the lifecycle Task 1 `SearchChildConnection` declaration. It does not need a real process, worker runtime, or allocator.
3. Driver Task 2 needs the complete wire reader/writer surface. It remains no-process and uses an injected response accumulator.
4. Driver Task 3 additionally needs lifecycle Tasks 1–3. Runtime Tasks 1 and 2 can proceed independently after wire completion; runtime Task 3 can proceed once lifecycle is complete. Neither waits for allocator selection.
5. **Gate A occurs only after driver Tasks 1–3 and worker-runtime Task 3.** Its ignored two-process composition injects candidate helper input and parent response accumulators. The allocation specification's actual measurements then select eligible accumulators and reservation values. Driver implementation supplies the transport and ownership observations; it does not choose those values.
6. Runtime Task 4 may adopt the measured helper accumulator only after Gate A. The later ApplicationSearches owner may inject this driver only after its own admission, capture, retained-result, and delivery plan is reviewed. Actual worker integration and packaging remain their existing later stages.

## Scope and files

Proposed driver-owned production files:

- `Sources/SearchExecution/SearchParentWireDriverTypes.swift`
- `Sources/SearchExecution/SearchParentWireBridge.swift`
- `Sources/SearchExecution/SearchParentWireCodecSession.swift`
- `Sources/SearchExecution/SearchParentWireDriver.swift`
- one narrowly reviewed internal addition to `SearchChildLifecycleTypes.swift` and `SearchChildLifecycle.swift`, described below

Proposed tests:

- `Tests/SearchExecutionTests/SearchParentWireBridgeTests.swift`
- `Tests/SearchExecutionTests/SearchParentWireCodecSessionTests.swift`
- `Tests/SearchExecutionTests/SearchParentWireDriverTests.swift`

No Package.swift change should be needed because these files stay in `SearchExecution`. Add no executable, native dependency, public library product, helper resolver, folder lane, operation queue, default lifecycle policy, response accumulator implementation, or active/retained budget.

## Package-internal interface to freeze

Names may be adjusted once against compiled lifecycle source, but the ownership and phase boundaries may not be weakened.

```swift
package struct SearchParentWireJob: Sendable {
  package let requestID: UUID
  package let query: SearchQuery
  package let operation: SearchExecutionOperation
  package let text: String
  package let inputUTF16: Int
  package let scope: NSRange?
  package let limits: SearchWireLimits
  package init(
    requestID: UUID, query: SearchQuery,
    operation: SearchExecutionOperation, text: String,
    inputUTF16: Int, scope: NSRange?, limits: SearchWireLimits
  ) throws
}

package struct SearchParentWireHandle: Sendable, Equatable {
  // Driver-issued nonce plus requestID; no public/memberwise initializer.
}

package enum SearchParentWireOutcome: Sendable, Equatable {
  case completed(
    identity: SearchWireIdentity,
    source: String,
    output: SearchExecutionOutput
  )
  case semanticFailure(identity: SearchWireIdentity, error: SearchError)
  case failed(identity: SearchWireIdentity?, failure: SearchChildFailure)
}

package enum SearchParentWireDriverError: Error, Sendable, Equatable {
  case busy, observerBusy, staleHandle, notSettled, invalidJob, shutDown
}

package struct SearchParentWireShutdown: Sendable, Equatable {
  package let child: SearchChildShutdown
  package let parentLaneSettled: Bool
  package let retainedParentLanes: Int // exactly 0 or 1
}

package protocol SearchParentWireResponseAccumulator:
  SearchWireResponseSink, AnyObject, Sendable
{
  // Called only on the codec lane after the outer consume has returned.
  // Success returns exact complete output; semantic failure returns no output.
  func takeTerminal(
    for identity: SearchWireIdentity
  ) throws -> (terminal: SearchWireTerminal, output: SearchExecutionOutput?)
  func discard()
}

package typealias SearchParentWireResponseAccumulatorFactory =
  @Sendable (SearchWireRequest) throws -> any SearchParentWireResponseAccumulator

package protocol SearchParentWireDriving: AnyObject, Sendable {
  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle
  func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome
  func cancel(_ handle: SearchParentWireHandle) async throws
  func discard(_ handle: SearchParentWireHandle) async throws
  func shutdown() async -> SearchParentWireShutdown
}
```

`submit` performs only a single-owner state transition and starts a driver-retained coordinator; it does not await lifecycle launch on the caller's structured task. This lets a caller detach without orphaning an admitted lifecycle operation. There is no queue: a second submit returns `busy`. The driver-retained coordinator calls `lifecycle.begin`, obtains the exact issued identity, and then constructs `SearchWireRequest`; caller-supplied generation or ordinal is impossible.

`SearchParentWireJob.init` applies the already frozen cheap metadata checks: nonzero request UUID, global numeric limits, bounded pattern/template, subtraction-safe scope, and `inputUTF16 <= limits.maxTextUTF16`. It does not traverse the full source. The future capture owner supplies the UTF-16 count it computed while creating the immutable snapshot; `SearchWireWriter.request` remains the independent exact-length/scalar check during its one encoding pass. A mismatch discovered there is a fatal integration failure that retires the admitted connection, not a second prelaunch traversal or a user semantic terminal.

`wait` permits one caller observer. Cancellation before delivery wins removes that observer and returns `CancellationError`; it does not consume the receipt or cancel the lifecycle observer, bridge, read, write, or operation, so one later wait may attach. Delivery winning the same race atomically consumes the receipt and transfers the outcome before resuming the waiter. After either a successful transfer or `discard`, that handle is permanently stale and repeated wait/discard returns `staleHandle`. UI and folder consumers observe their future higher owner rather than the lifecycle directly.

`cancel` is the only per-operation cancellation entry: it records explicit cancellation, closes the current bridge immediately, and calls `lifecycle.cancel` without waiting for the codec thread. `discard` is legal only for a settled, unconsumed receipt with no attached waiter; before settlement it returns `notSettled`, and with a waiter it returns `observerBusy`. It releases an unobserved completed payload or compact failure receipt only after all codec callbacks have unwound; it is not operation cancellation.

`SearchParentWireShutdown` reports the actual `SearchChildShutdown` plus whether the codec job, upload consumer and its awaited connection write, and read completion have settled, and the count of retained parent operation lanes (zero or one; one while any of those owners remains). It closes admission and bridges immediately, then invokes lifecycle shutdown. It never labels app exit permission, timer outcome, or child reap alone as parent-lane settlement.

The response accumulator is an injected, lane-confined component. Unit tests use a small synthetic implementation; Gate A supplies measurement candidates. No production factory exists before selection. `complete` records a provisional terminal only. `takeTerminal` is legal only after its enclosing `ResponseReader.consume` returned successfully and validates these exact invariants: success has one complete output of the advertised shape; semantic failure has no output and has discarded any partial ranges/replacement. Any accumulator/factory failure is fatal infrastructure failure, never a `SearchError` terminal.

`SearchParentWireOutcome.completed` carries the immutable original source because later native stale-result checks require it. The source and output transfer together from active ownership to the caller's retained-result ownership. The driver does not define the byte amount or eviction policy. A failed reservation/capture happens before `submit`.

The driver keeps exactly one current handle and, after parent-lane settlement, at most one terminal/failure receipt. It keeps no array/history and no arbitrary error text, wire bytes, source, partial ranges, or partial replacement for an infrastructure/semantic failure. Cleanup, connection retirement, and parent-memory release continue even when no result waiter is attached.

An unconsumed **success** blocks later `submit` until `wait` transfers its source/output or `discard` releases them. An unobserved semantic/infrastructure failure retains only identity plus the typed error. With no attached waiter, the next `submit` atomically expires that compact failure receipt, makes its handle stale, and then admits the new job; it does not retain an indefinite metadata history or block a healthy handoff. The future process-wide owner normally maintains its one retained waiter and therefore observes either case. A consumed receipt is erased before observer resumption, so an immediate next submit cannot overwrite history or overlap the prior payload.

## Exclusive admission and retained observers

`SearchParentWireDriver` is an actor or equivalent small serialized owner. It never runs a codec callback, blocking condition wait, or I/O syscall on that executor. The application composition constructs one lifecycle and transfers its operational authority to one driver; no other component receives that lifecycle for `begin`, `wait`, `connection`, handshake, terminal, or rejection calls. Tests assert all such calls originate through the driver. This higher-owner exclusivity removes the need for a lifecycle admission hold/release API.

The driver state distinguishes `idle`, `admitting`, `handshaking`, `uploading`, `expecting`, `reading`, `terminalHandoff`, `failedCleaning`, `completedAwaitingTransfer`, `retiring`, and `shutDown`. Reentrant actor calls see the state and cannot create another producer/read/observer.

Immediately after lifecycle `begin` returns a ticket, the driver creates exactly one retained task that calls `lifecycle.wait(for:)`. That is the sole lifecycle observer. It is owned by the driver, not by the caller's `wait` task. When it reports cancellation, deadline, protocol/channel failure, or unexpected exit, the driver stores the first lifecycle decision and closes the bridge. It does not cancel a connection read/write task directly; lifecycle channel closure retires those operations as required by the connection contract.

The driver also owns one retained coordinator task for the operation and at most one read task for the connection. These are not created per chunk. Caller observer cancellation detaches only its continuation. Explicit cancellation reaches lifecycle and bridge independently. The lifecycle observer may receive a failure before the codec producer exits, but the driver's result observer is resumed only after the old producer, codec callbacks, upload consumer (including its awaited connection write and local Data), and read completion have settled. This keeps failure delivery distinct from the prompt cancellation decision while guaranteeing that a returned driver outcome cannot be followed by an overlapping retained producer. Physical child cleanup may still be pending and independently make the next lifecycle begin busy.

## Retained codec lane

`SearchParentCodecLane` owns one dedicated `Thread` (or another reviewed blocking-capable OS-thread primitive), one condition, and one nonqueueing job cell. It is outside MainActor, the lifecycle control queue, the connection I/O queue, and Swift cooperative tasks needed by async connection methods. It accepts a job only while both the cell and active-job flag are empty; there is never an active plus queued source-bearing job.

The implemented lane exposes synchronous nonblocking `submit(token, body)`, returning a one-shot `SearchParentCodecWork` whose async `value()` observes completion. The receipt retains only result/waiter state, never the source-bearing body; the thread-owned job retains the receipt one-way. The thread releases its job/body and drains that scope before clearing busy or publishing completion. Generic results are intentional ownership transfers; mutable codec/index instances must remain lane-confined through the later session API.

One internal value observer is allowed. An overlapping observer is rejected; result/error transfers once and later calls are stale. Cancellation of this internal coordinator observer leaves it attached until completion and does not cancel work. Dropping the caller's receipt cannot orphan admitted work. The driver's detachable public observer remains separate. `loopStopped` acknowledges the final loop branch after work release, not a physical pthread join.

All instances of `SearchWireResponseReader`, handshake/request writers while executing, boundary indexes, and response accumulators are created or used only on this lane. Every lane operation has a generation/session epoch and operation token. Calls into mutable codecs never overlap and never reenter from callbacks. The lane's completion is transferred through one continuation after the job and every callback return. No condition/driver lock spans `await connection.write`, `read`, lifecycle entry, or result observer delivery.

The retained thread can run short hello encode/parse jobs, one request writer job, `ResponseReader.expect`, and one response consume job at a time. During a writer's blocked emit the lane cannot parse responses; the read owner therefore keeps at most one completed read behind the expect gate. After cancellation, no later job is accepted until the current writer/consume closure actually returns. The thread is not force-cancelled.

## Single-slot synchronous emit to asynchronous write bridge

Each `SearchWireWriter.hello` or `.request` invocation gets a fresh `SearchParentWireUploadBridge`. A bridge is never reused between writer calls or operations. Its immutable identity is `(generation, optional requestID, writerEpoch)`; each emission adds a checked monotonically increasing sequence.

Under one condition/lock, the bridge tracks:

- producer: `running` or `exited(Result<..., Error>)`;
- slot: `empty`, `offered(token, Data)`, or `inFlight(token, Data)`;
- acknowledgement: none or the exact last acknowledged token;
- consumer waiter: absent or exactly one continuation;
- consumer: notStarted, running, or exited; its exit latch is set only after its last awaited connection write has returned and the consumer scope has released its local Data/token references;
- terminal: `open` or `closed(firstError)`.

The synchronous `emit` validates `1...65_536` bytes, deposits only into an empty slot, wakes the sole consumer once, and blocks the codec thread until that exact token is acknowledged or the bridge closes. It returns successfully only after the async consumer's entire `connection.write(data)` returned successfully. The connection remains responsible for short-write/EINTR handling. Deposit or internal enqueue is never an acknowledgement.

The async consumer takes one offered item, marks it in flight, releases the lock, awaits exactly one write, and then resolves that token under the lock. A matching success changes the slot to acknowledged/empty and wakes the producer exactly once. A write error stores the first bridge error, closes the bridge, wakes both sides exactly once, and is reported to lifecycle. No second write begins until resolution, so the connection's allowed queued-write position is never populated by this driver.

Token delivery carries metadata only; the consumer then claims a payload lease. The write helper releases its Data before publishing lease release. Resolution detaches the bridge slot into a payload-owning helper while retaining metadata-only retirement state, releases payload outside the condition, and returns before publishing the exact acknowledgement. A concurrent close preserves another active retirement until its helper returns. Bridge failures retain only bounded typed bridge/child/wire reasons; unknown producer/write errors normalize to compact failures.

Close is idempotent and preserves the first linearized bridge error. Close before deposit makes the next emit fail. Close while a write is in flight wakes the producer immediately; a later success/error for that token is ignored after dropping its references. Generation, bridge epoch, and sequence must all match, so a late acknowledgement cannot release a later emission in the same generation. Producer exit records its result, closes an otherwise clean stream after the final acknowledgement, wakes a waiting consumer, and is a separate settlement latch from merely waking the producer. Consumer exit is a second independent latch: closing/emptying the bridge or observing producer exit never establishes that the async write scope has returned. A late write result cannot acknowledge a new token, but it must still settle the old consumer and release its exact old Data ownership. Keep that consumer retained until it exits; no task cancellation, lifecycle decision, channel-close request or child reap substitutes for this receipt.

The owner records producer exit only after `Work.value()` confirms the source-bearing job/body and callbacks returned, never at the tail of a still-running lane body. Repeated producer-exit notifications cannot rewrite the first completion. An active emit independently prevents settlement.

If execute bytes partially escape and the complete write then throws, `SearchWireWriter.request` returns no boundary index, no later sink call is permitted, `expect` is never called, and the generation is retired. No rollback is claimed. A cancellation while the writer is constructing its next bounded UTF-16 chunk closes the bridge, but the source/index/producer credits remain until construction reaches emit/failure and the writer closure exits.

## Phase-by-phase transport and codec staging ledger

This plan adopts no active or retained operation budget. Source inspection shows that the allocation specification's earlier term of four 65,568-byte “transport/chunk slots” cannot represent the known driver **and codec** peak. The following is the minimum conservative ownership ledger for the current codecs. Every distinct allocation or retained capacity is charged as one uniform 65,568-byte credit even when its payload cap is 65,536. Multiple immutable Swift `Data` values that refer to one logical transfer are named together; they are not evidence that only one backing exists. Any copy across such an alias boundary adds another credit when source instrumentation or Gate A observes it.

| Phase | Simultaneously live bounded owners | Fixed peak |
| --- | --- | --- |
| Idle only | Connection read staging and, after completion, the returned driver gate `Data`; source inspection/measurement may prove these are one backing, but the ledger charges both. | 2 credits |
| Request input, header emit | The 65,536-byte `SearchWireUTF16Encoder` chunk remains live in `SearchWireWriter.request` while `FrameEncoder` constructs/emits its 32-byte header; bridge, async-consumer, and connection-write ownership of that small header; plus up to two idle-read owners. Header capacity is small but every distinct owner is explicit. | 3 full credits plus at most three bounded header copies |
| Request input, payload emit | Writer/frame payload chunk, bridge slot/in-flight reference, async consumer reference, connection pending-write reference or copy, and up to two idle-read owners. The driver never fills the connection's additional queued-write position. | 6 credits |
| Fragmented inbound frame before callback | Connection read staging, driver gate `Data`, and `FrameDecoder.payloadBytes` copied incrementally while the gate survives. `headerBytes` retains at most 32 bytes. | 3 credits plus header metadata |
| Range callback | The preceding read/gate owners, completed frame payload, `FrameDecoder.payloadBytes` capacity retained after `removeAll(keepingCapacity: true)`, and decoded `[NSRange]` temporary up to 4,096 pairs/65,536 bytes. The accumulator's retained/growth range storage is separately charged result work. | 5 credits plus result work |
| Replacement UTF-8 callback | The preceding read/gate owners, completed frame payload, retained FrameDecoder payload capacity, emitted UTF-8 `Data`, and the next 65,536-byte UTF16Decoder output capacity allocated **before** `appendReplacementUTF8` runs. Accumulator destination/growth storage is separately charged result work. | 6 credits plus result work |
| Terminal/hello callback | Read/gate owners, small frame payload, retained decoder capacities, and fixed callback record only. | Below the 6-credit peak |

The fixed parent transport-plus-codec floor is therefore **six uniform 65,568-byte credits = 393,408 bytes**, not four. This six-credit term counts the producer/frame reference, bridge/consumer transfer, connection pending write, connection read staging, held gate read, FrameDecoder copied/retained payload, range temporary, and both UTF-8 decoder buffers according to the phases in which they can coexist; it does not sum mutually exclusive request and response phases. Small 32-byte headers and fixed bridge state remain in bounded metadata.

The six-credit correction is included in the reviewed **provisional** allocation formula. This adopts no runtime budget or allocator. Gate A must verify at least this fixed floor against the implemented driver and candidate accumulators. Candidate response accumulators must additionally charge every append temporary, String/Array growth copy, retained result, and callback capture; the existing `6M` output and `16R` range terms may not silently absorb an observed extra live copy without source/measurement evidence and formula review. If bridge/connection/source inspection or Gate A finds another backing, retained capacity, or callback escape, revise the term upward and repeat affected evidence.

Only one logical upload emission and one logical completed read can coexist. The driver awaits one write, so it does not use the connection's additional queued-write allowance. It issues no second read until the first returned bytes have been consumed or retired. Original text, boundary bitset/index (up to its reviewed 12,500,001 bytes), retained ranges, and replacement output have separate caller/codec/result ownership and are not hidden in these six credits.

## Handshake, request, and response sequence

For a fresh generation:

1. The retained coordinator gets `connection(for:)`; generation comes from the ticket, never from peer bytes.
2. On the codec lane, `SearchWireWriter.hello` emits through a fresh bridge. Its producer and write consumer settle.
3. The driver loops one bounded `read(maxBytes: 65_568)` at a time. Each nonempty result is scheduled through `ResponseReader.consume` on the codec lane with one fixed handshake sink. If no complete childHello was delivered, the clean consume merely returns and the driver issues the next read; fragmented header/payload bytes remain only in FrameDecoder. On empty read before hello, run `ResponseReader.finish` on the codec lane to close/diagnose the incomplete stream, then report channel EOF; it is handshake failure and retires the generation. EOF never supplies handshake acceptance.
4. `helloAccepted` records one provisional event only. The read loop stops only when the consume call that produced that event returns successfully. Only then does the driver call `acceptedHandshake(generation:)`. An incomplete hello can never call lifecycle acceptance; the reader's ready/buffer check rejects any complete or partial suffix supplied with the completing childHello.

For every request:

1. Build `SearchWireRequest` from the lifecycle ticket and job. Create the injected accumulator before emitting request bytes; failure cancels/retires without a semantic terminal.
2. On the codec lane call `SearchWireWriter.request`. Append no independent index and do not parse outgoing bytes or traverse the full source again. Hold its returned exact boundary index only if every emission, including execute, was fully acknowledged.
3. Still serialized on the codec lane, call `ResponseReader.expect(request, boundaries:)` before any completed read is passed to consume. The boundary index remains owned until terminal validation finishes or the session fails.
4. Consume at most one 65,568-byte read at a time on the codec lane. Sink callbacks only append to the credited accumulator or record terminal. They do not publish, call lifecycle, start another read, or reenter a codec.
5. A terminal callback becomes actionable only after the outer consume succeeds. Then call `takeTerminal`; success requires exact output, semantic failure requires nil output. Any trailing complete/partial bytes in the same consume make the reader throw, discard the record/output, and call `rejectedProtocol` instead.
6. Call `acceptedTerminal(terminal, ticket:)` only after those steps and outside the codec lane callback/consume stack. If lifecycle already decided cancellation/deadline/exit, acceptance refuses and the provisional output is discarded. If acceptance succeeds, wait for the retained lifecycle observer to report the same `.completed(terminal)`.
7. Drop the request and boundary index after codec use. On semantic failure discard partial result. On success retain the exact original source plus complete output for one result transfer. Install the next tagged idle-read ownership before marking the driver handoff reusable. The accepted terminal no longer depends on that read remaining healthy: an immediate EOF/failure retires the session, settles the failed read, and then releases the unchanged accepted terminal receipt.

The response reader persists only for a healthy generation. Any wire/accumulator failure poisons it and retires that generation; there is no reset or in-process fallback.

## Idle read and reuse handoff

After a lifecycle-accepted terminal, the driver immediately installs exactly one tagged read owner and starts `connection.read(maxBytes: 65_568)` before it exposes the session as reusable. “Arm” means the driver has recorded that unique task/session ownership; it does not promise the peer will keep the read pending or healthy. The read normally remains pending while idle. Starting a later request never cancels it. The driver serializes `begin`, session generation changes, request upload completion, `expect`, and processing of this read.

If that newly armed read immediately returns EOF or throws, terminal acceptance still wins. The driver reports the channel observation for the same generation, marks the session retiring, drops the failed read/task references, and preserves the exact success or semantic-failure receipt. Once those parent references settle, `wait` returns the accepted terminal even if lifecycle child cleanup/recycle remains pending; it cannot wait indefinitely for a replacement idle read. The next `submit` may then reach lifecycle and receive busy until physical cleanup, or establish a fresh generation after cleanup. An idle read failure never rewrites an accepted terminal into infrastructure failure.

If a new ticket reuses the generation, the existing pending read is retagged from `idle(generation, sessionEpoch)` to `gate(newIdentity)`. If it completes during request upload, its one Data stays held. Regardless of callback order relative to the execute write, the driver waits for writer success and `expect` before parsing it. A valid fast response is therefore accepted; a stale old terminal is rejected by exact request UUID/ordinal. No next read starts while this Data is held.

If lifecycle recycles and returns a new generation, the old connection/read must first settle through lifecycle channel closure. Its completion remains tagged with the old session epoch and can only release old staging; it cannot touch the new reader, ticket, bridge, accumulator, or lifecycle event. The new reader/handshake starts only after this settlement. Lifecycle's no-overlapping-child guarantee remains independently required.

Late-byte outcomes are exact:

1. **Same consume as terminal:** reader invalidPhase/other precise wire error; provisional terminal/output discarded; no `acceptedTerminal`; `rejectedProtocol(old generation)` decides the still-active operation.
2. **Later byte while truly idle:** feed it to the ready reader, which fails invalidPhase. Call `rejectedProtocol(generation)` to retire the connection. The already accepted prior result is unchanged.
3. **Byte after next same-generation admission:** hold it behind the gate until `expect`. Any old identity then fails the current request, and `rejectedProtocol(generation)` makes the newly active ticket fail with protocol failure and retires the generation. It never mutates the prior result.
4. **Completion from a retired/replaced generation:** compare generation plus session epoch, release only that completion's Data/task, and ignore it for the current state. Do not call a generation-only lifecycle method for the replacement generation.
5. **Idle EOF/channel error:** retire the old generation through the channel-observation seam below. With no active ticket it changes availability only; with a newly active same-generation ticket it supplies that ticket's first infrastructure outcome unless cancellation/deadline already won.

There is no drain-until-empty, quiet timer, polling proof, or cancellation of a healthy read. A pending idle read is the handoff. Cancelling it during shutdown or failure means the whole connection is retired.

## Narrow lifecycle integration addition

The current lifecycle interface has `rejectedProtocol(generation:)` but no truthful entry for an empty response read or errno-bearing connection failure. Mapping every such event to protocol failure would make `channelFailure`/`unexpectedExit` inaccurate. Add only this internal generation-tagged collaborator event after lifecycle source lands:

```swift
enum SearchChildChannelObservation: Sendable, Equatable {
  case endOfFile
  case failure(Int32) // captured nonzero errno from the connection owner
}

func rejectedChannel(
  _ observation: SearchChildChannelObservation,
  generation: UUID
) async
```

`SearchChildChannels` throws `SearchChildFailure.channelFailure(capturedErrno)` from real read/write failures; scripted conformers do the same. The driver converts only that exact typed error to `.failure(errno)`. Empty Data becomes `.endOfFile`. An arbitrary injected error is an internal contract violation and uses fatal protocol retirement; it is never assigned a fabricated errno or translated to `SearchError`.

The lifecycle method applies existing generation and first-decision checks. During handshake, EOF remains handshake failure. During an active accepted request, EOF becomes unexpected exit and `.failure(errno)` becomes the existing channel failure. While ready/idle, either event stops/reaps that generation without changing the retained prior outcome. After cancel/deadline/protocol/terminal already won, it cannot replace that outcome. Stale generation events do nothing. Channel closure, signaling, reap, and physical-slot ownership remain entirely lifecycle-owned.

No lifecycle admission hold/release method is proposed. If implemented lifecycle already has an equivalent typed channel-close event, use it and omit this mechanical addition; do not add a duplicate path.

## First outcome, publication, and release predicates

The lifecycle decision and driver result transfer are separate:

- Cancellation/deadline stored before `acceptedTerminal` wins even if its observer delivery arrives later. A provisional terminal/output is discarded.
- Once `acceptedTerminal` succeeds and lifecycle stores `.completed(terminal)`, later deadline delivery, explicit cancel, or caller observer cancellation cannot rewrite it. Native applicability may later reject stale output without changing lifecycle history.
- A response is not returned until outer consume, accumulator settlement, terminal acceptance, matching lifecycle outcome, producer/lane and upload-consumer/write settlement, and installation plus settlement-or-retention of the tagged idle read. A read that fails immediately after accepted terminal retires the connection but does not block or rewrite that result.
- Explicit `cancel` returns after lifecycle has accepted the cancellation request and the bridge has closed; it does not wait for producer exit. The later `wait` outcome remains held until parent-lane cleanup latches settle. A future higher owner may show its own cancellation-requested state immediately without treating that as a result or cleanup receipt.

Release/admission predicates:

| Ownership | Release or transfer predicate |
| --- | --- |
| Physical child/PID/FDs | Lifecycle-only exact reap plus channel close; a driver decision or producer exit is insufficient. |
| Upload source, writer, current chunk, boundary index | Producer exited; exact bridge token has no slot/in-flight reference; writer and every callback returned; upload consumer exited after connection.write returned and its local Data/token references were released. Retain this operation reservation conservatively until all those receipts exist; boundary index additionally remains through response validation. |
| Completed/held read | Its consume callback returned or its retired session completion was dropped; no stale callback retains Data. |
| Partial response accumulator | Codec consume unwound and `discard` returned after poison/error, or complete success transferred to result ownership. |
| Successful source/output | Atomic active-to-retained transfer when `wait` returns, or explicit `discard`; no byte value is selected here. |
| Driver next admission | No producer/codec job or retained upload consumer/write from the prior request, no undelivered successful payload, and exactly one healthy pending/held idle read or a fully retired old session. A compact unobserved failure with no waiter is expired atomically by submit; lifecycle ready alone is insufficient. |

Bridge/source credit is released only after both producer exit and upload-consumer/write settlement, not bridge close, task cancellation, child reap, waiter wake, or an empty slot. Failure publication, discard eligibility, next admission, and parentLaneSettled use that same combined predicate. Bounded shutdown may return parentLaneSettled=false with one retained parent operation lane while the consumer still owns a chunk; cleanup continues afterward. Result callbacks cannot retain source/index/Data after their lane method returns except through the explicitly transferred output. The later allocation implementation must instrument these predicates; sampled RSS does not replace them.

## Task 1 — Blocking lane and acknowledged upload bridge

**Files:** create `SearchParentWireBridge.swift` and `SearchParentWireBridgeTests.swift`. Add only bridge/lane declarations used by this implementation and its tests.

**Implemented/tested:** the two component files are independently reviewed. A frozen minimal package containing actual production sources passed 20 tests; early-deposit acknowledgement and missing-consumer-exit mutants each failed one explicit assertion, and a missing-token-fence mutant failed its explicit assertion plus cleanup cancellation. The repeated-producer-exit regression failed before its fix. Held producer/consumer and deallocator-reentry tests establish logical ownership and settlement predicates only. Lifecycle/driver publication, discard, admission and shutdown enforcement remain Task 3; actual capacities remain Gate A. The public-manifest command below remains an integration check until separately run.

- [ ] First behavioral red: a fake producer emits A and then attempts B while the async writer holds A. Assert B is never deposited and producer remains blocked until the entire A write gate succeeds. Deposit acknowledgement must fail this test.
- [ ] Implement the retained one-job codec thread and fresh bridge state machine. No task per chunk, no second job cell, no lock across await, and no executor needed by the consumer may be blocked.
- [ ] Add exact races: close before deposit, close while write held, success acknowledgement racing close, late acknowledgement with matching generation but old bridge epoch/sequence, and first-error preservation. Assert continuations/condition waiters resume exactly once.
- [ ] Simulate a producer held between emissions while cancellation closes the bridge. Assert the lifecycle cancellation decision may be observed while the driver result remains held, and source credit and lane busy stay set until the producer gate opens and producer-exit fires; a new codec job is refused meanwhile.
- [ ] Hold connection.write after it captured Data, close the bridge and allow producer exit. Require consumer-exit=false and retained upload credits until the write gate returns and its consumer scope exits; late success/error must settle only that old token. No result transfer, discard, next admission or successful parent-lane shutdown receipt before settlement. Repeat with lifecycle child reap and close-request events already delivered; neither is a consumer-exit receipt.
- [ ] Test 1, 32, 65,536, and 65,537-byte emits, exact producer/bridge/consumer/connection ownership counters, and at most one connection write invocation. A fake connection copying input must consume its distinct connection credit; an uncharged extra copy fails the counter oracle.
- [ ] Run `scripts/swift.sh test --scratch-path .build/search-parent-wire-driver --filter SearchParentWireBridgeTests`; retain genuine red/green output. Then run scoped format, `python3 scripts/check-public.py`, and scoped `git diff --check` only.

## Task 2 — Lane-confined codec session and provisional results

**Files:** create `SearchParentWireDriverTypes.swift`, `SearchParentWireCodecSession.swift`, and `SearchParentWireCodecSessionTests.swift`. This task uses the bridge but no lifecycle/process implementation.

- [ ] Red-test a fixed hand-authored childHello delivered one byte per read. Assert no lifecycle-ready event through bytes 1...55 and exactly one provisional hello only after byte 56's consume returns cleanly. Also cover arbitrary header/payload splits, every 1...31 trailing suffix, and a complete header/partial payload. An incomplete hello or completing consume with a suffix never produces an accepted handshake.
- [ ] Implement lane-confined persistent ResponseReader/session epoch and the injected accumulator contract. Test callbacks cannot call expect/consume recursively.
- [ ] Principal request red: hold one gate read, emit a small Unicode request, require all execute bytes acknowledged, verify returned boundary-index identity/length/endpoints, call expect, then consume the held response. Fixed ranges/output are the oracle. Assert no parsing of outgoing bytes and instrument exactly one source UTF-16 traversal.
- [ ] Test execute write recording followed by failure: no returned index, no expect, no later emit. Test error before execute similarly never attempts execute; do not assert rollback of escaped bytes.
- [ ] Feed valid success/error terminal plus same-consume partial/complete junk. Assert provisional callback may occur but `takeTerminal`/publication does not, accumulator discards after unwind, and reader is poisoned. Test sink throwing `SearchError` maps to infrastructure/sink failure, not semantic failure.
- [ ] Test semantic error after partial response discards all partial data; success requires exact count/range/scalar/replacement validation. The codec session calls no engine and retains no complete wire stream.
- [ ] Instrument phase ownership for request header/payload, fragmented receive, range callback, and replacement callback. Require the six-credit fixed peak and explicit candidate-result storage outside it; no test may pass by assuming Data/String COW sharing.
- [ ] Run the focused codec-session filter plus existing final wire request/response/frame/UTF filters only. Scope-format/public/diff checks and independent review precede commit.

## Task 3 — Exclusive lifecycle driver, reuse, cancellation, and settlement

**Files:** create `SearchParentWireDriver.swift` and `SearchParentWireDriverTests.swift`; make only the reviewed channel-observation edits in lifecycle types/control and extend focused lifecycle tests for that event.

- [ ] First behavioral red: terminal acceptance resumes a driver waiter whose callback immediately submits request 2. Require request 2 admission only after request 1 producer/callbacks settled, output transferred, and one idle read is armed. Reuse exact generation with next lifecycle-issued ordinal.
- [ ] Implement driver-retained coordinator, sole lifecycle observer, detachable result observer, explicit cancel, discard, and bounded shutdown receipt. Assert second submit/observer refusal and stale handle fencing.
- [ ] Hold the idle read across request 2 upload and expect. Return a valid fast response before expect; assert only one Data is held, no second read begins, and it parses after expect. Return an old terminal instead; assert request 2 protocol failure and generation retirement while request 1 result stays accepted.
- [ ] After lifecycle accepts a success terminal, make the newly armed idle read return immediate EOF while child cleanup remains held. Assert the exact success/source/output is still delivered once the failed read references settle, the connection retires, and no replacement idle read or physical-cleanup wait can block the result. Repeat with an accepted semantic-error terminal followed by immediate errno failure.
- [ ] Test late old terminal while truly idle, same-consume terminal junk, and a late read/write/bridge completion from a retired generation after a fresh generation exists. Assert exact first outcomes and no old callback mutates the replacement session.
- [ ] Cancel the caller's `wait` during held upload: lifecycle/bridge/read remain live and a later wait can attach. Then explicit cancel: lifecycle cancellation records independently, bridge wakes without waiting for producer, connection retires, and no new producer is admitted until old producer exit.
- [ ] Race deadline/cancel against terminal acceptance. Decision before acceptance discards provisional output; accepted terminal followed by delayed driver publication and cancel returns the accepted completion. A stale native/application result is outside this test and must not be simulated as changed lifecycle outcome.
- [ ] Exercise `rejectedChannel` for handshake EOF, active EOF, errno failure, idle EOF, and stale generation. Verify existing lifecycle channel close/reap gates and first-decision behavior; run focused lifecycle tests because those two files changed.
- [ ] Reap/close the child while a producer construction gate remains held. Assert physical cleanup may complete but source/codec credit remains and submit is busy until producer exit. Conversely producer exit does not release the physical child slot.
- [ ] Cover one-shot receipt ownership: cancelled waiter then successful later wait; repeated wait after transfer; discard before settlement; discard with attached waiter; repeated discard; and unobserved infrastructure/semantic failures completing cleanup without retaining source/partial output. A later submit with no attached waiter must atomically expire that compact failure and stale its handle; an unobserved success must remain busy until transferred/discarded. Assert stale handles never retain an outcome history.
- [ ] Run focused `SearchParentWireDriverTests`, `SearchParentWireBridgeTests`, `SearchParentWireCodecSessionTests`, and `SearchChildLifecycleTests`. Use no process fixture in ordinary XCTest. Scope-format/public/diff checks, source hashes, and independent review precede scoped commits.

## Gate A handoff — not owned by these source tasks

After driver Task 3 and worker-runtime Task 3 are reviewed, the allocation harness may inject this driver, its actual lifecycle/connection, the Task 3 worker program composition, and measurement-only candidate accumulators. It must run under the existing owned-process watchdog and follow the full public allocation matrix. The driver provides exact events for source capture ownership, producer exit, boundary-index release, response sink discard/transfer, terminal acceptance, idle read arm, generation retirement, channel close, and reap.

Gate A must verify the provisional six-credit fixed floor against real capacities/copies and observe cold plus warm/recycle sequences. Gate A must separately select helper input and parent response accumulators. A candidate sink, active/retained budget, native snapshot policy, queue byte limit, deadline, recycle policy, or RSS claim is not part of driver Tasks 1–3. If a driver/codec/candidate copy or callback retention violates the revised staging shape, revise this plan/allocation formula and repeat affected evidence.

## Root review revision record

The initial draft was revised in four bounded areas before final independent review:

1. **Fragmented handshake:** the fresh-generation sequence now loops bounded reads and clean consumes until the exact childHello callback occurs; one-byte fragmentation and EOF-before-completion are explicit oracles.
2. **Codec-inclusive staging:** the former four-credit claim was removed. Current FrameDecoder copied/retained payload, request encoder/header overlap, range temporary, and both simultaneous UTF16Decoder output capacities produce a known six-credit floor. This corrects the provisional public allocation formula; it is not a budget adoption or RSS bound.
3. **Accepted terminal versus idle-read failure:** installing the tagged idle read completes the handoff obligation; immediate EOF/errno retires the session while preserving and delivering the already accepted success/error after failed-read references settle. Replacement-read or physical-cleanup success is not required to return that terminal.
4. **One-shot receipts:** successful delivery/discard stales the handle; observer cancellation before delivery permits one later attachment; unobserved success blocks to protect payload ownership; compact unobserved failures clean independently and may be atomically expired by a later submit. No outcome history is retained.

## Verification and claim limits

Proposed commands are not proven until implementation:

```sh
scripts/swift.sh test --scratch-path .build/search-parent-wire-driver --filter SearchParentWireBridgeTests
scripts/swift.sh test --scratch-path .build/search-parent-wire-driver --filter SearchParentWireCodecSessionTests
scripts/swift.sh test --scratch-path .build/search-parent-wire-driver --filter SearchParentWireDriverTests
scripts/swift.sh test --scratch-path .build/search-parent-wire-driver --filter SearchChildLifecycleTests
xcrun swift-format lint --strict Sources/SearchExecution/SearchParentWireDriverTypes.swift Sources/SearchExecution/SearchParentWireBridge.swift Sources/SearchExecution/SearchParentWireCodecSession.swift Sources/SearchExecution/SearchParentWireDriver.swift Tests/SearchExecutionTests/SearchParentWireBridgeTests.swift Tests/SearchExecutionTests/SearchParentWireCodecSessionTests.swift Tests/SearchExecutionTests/SearchParentWireDriverTests.swift
python3 scripts/check-public.py
```

Each task must preserve behavioral red then unchanged green, inspect warnings and exact scoped diff, and obtain independent review. Do not run the broad core adversarial regex suite, GUI, network, native document, folder traversal, or unsupervised process tests for this driver work.

Passing these tests establishes only deterministic bridge/backpressure, codec sequencing, lifecycle collaboration, late-byte policy, and ownership latches. It does not establish actual helper behavior, allocator eligibility, process containment, RSS bounds, UI responsiveness, native stale-result enforcement, folder fairness, packaging, signing, or release readiness.
