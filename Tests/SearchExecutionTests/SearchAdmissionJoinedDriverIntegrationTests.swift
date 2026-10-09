import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Private Task2 draft. Actual controller/parent/codec with unchanged injected
/// lifecycle/channel collaborators; no OS process, descriptor, wall clock or AppKit.
@MainActor final class SearchAdmissionJoinedDriverIntegrationTests: XCTestCase {
  func testActualNeverAdmittedJoinedOwnerClosesAndAcknowledgesLane() async throws {
    let fixture = try makeFixture()
    let result = try observed(await fixture.owner.shutdownJoined())
    let completion = try completed(result.parent)
    XCTAssertEqual(completion.ownership, .admitted)
    XCTAssertEqual(completion.laneStop, .acknowledged)
    XCTAssertEqual(completion.shutdown.child.cleanup, .noChild)
    XCTAssertTrue(completion.shutdown.child.channelsClosed)
    XCTAssertTrue(completion.shutdown.parentLaneSettled)
    XCTAssertEqual(completion.shutdown.retainedParentLanes, 0)
    assertEmpty(result)
    let repeated = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(repeated.parent, result.parent)
    let boundary = await fixture.boundary.snapshot()
    XCTAssertEqual(boundary.joinHandles.count, 1)
    let joinHandle: SearchParentWireHandle? = try XCTUnwrap(boundary.joinHandles.first)
    XCTAssertNil(joinHandle)
    XCTAssertEqual(boundary.joinReturns, [result.parent])
    XCTAssertEqual(boundary.legacyReturns.count, 0)
    XCTAssertEqual(boundary.submittedHandles.count, 0)
    XCTAssertEqual(fixture.h.system.launchCount.value, 0)
    XCTAssertEqual(fixture.h.system.signalCount.value, 0)
  }

  // Break: physical close/reap or a cleared session slot stands in for the
  // genuine idle read's return, or admission waits for idle absence before join.
  func testActualIdleReadMustReturnBeforeJoinedObservation() async throws {
    let readReturn = DriverTestGate()
    let connection = DriverTestConnection(cancelledReadReturn: readReturn)
    let fixture = try makeFixture(connection: connection)
    fixture.h.system.reapOnSignal = true
    let delivered = DriverTestGate()
    var deliveries: [SearchAdmissionDelivery] = []
    _ = try fixture.submit(text: "😀x", pattern: "😀") {
      deliveries.append($0)
      delivered.open()
    }
    let identity = try await connect(fixture, pid: 7310)
    connection.offer(
      try DriverTestWire.success(
        identity: identity, matches: [NSRange(location: 0, length: 2)]))
    await delivered.wait()
    guard case .completed(let lease) = try XCTUnwrap(deliveries.first) else {
      throw DraftFailure.unexpectedDelivery
    }
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertTrue(
      fixture.owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, "synthetic-joined-context")
        XCTAssertEqual(source, "😀x")
        XCTAssertEqual(output.matches, [NSRange(location: 0, length: 2)])
        XCTAssertNil(output.replacement)
      })
    fixture.owner.release(lease)
    XCTAssertEqual(fixture.owner.accountingSnapshot.active, 2)
    XCTAssertEqual(fixture.owner.accountingSnapshot.retained, 0)
    await connection.waitForReadCalls(3)
    XCTAssertEqual(connection.snapshot.activeReads, 1)
    XCTAssertFalse(fixture.events.sessionReleased.isOpen)
    // acceptedTerminal performs one real running-state poll before publishing.
    XCTAssertEqual(fixture.h.system.polledPIDs, [7310])
    XCTAssertEqual(fixture.h.system.signalCount.value, 0)

    let closing = fixture.closeJoined()
    await fixture.boundary.joinEntered.wait()
    await connection.cancelledReadReturning.wait(for: 1)
    // This bounded current child snapshot shares the existing sole reaper.
    // Its cleanup reports the actual injected consuming reap; adopted close
    // acknowledgment can still be pending and is not inferred from read cancel.
    let child = await fixture.h.lifecycle.shutdown()
    // A repeated lifecycle call is a bounded current observation, distinct
    // from the first shutdown receipt that the actual parent retains.
    switch child.cleanup {
    case .noChild:
      XCTAssertTrue(child.channelsClosed)
    case .reaped(let generation, let exit):
      XCTAssertEqual(generation, identity.generation)
      XCTAssertEqual(exit, .signaled(SIGKILL))
    default:
      XCTFail("Physical cleanup has not consumed the synthetic child's exit: \(child.cleanup)")
    }
    XCTAssertTrue(connection.snapshot.closed)
    XCTAssertEqual(connection.snapshot.activeReads, 1)
    XCTAssertFalse(readReturn.isOpen)
    XCTAssertFalse(fixture.events.sessionReleased.isOpen)
    XCTAssertNil(fixture.events.snapshot.releasedGeneration)
    let held = await fixture.boundary.snapshot()
    XCTAssertEqual(held.joinHandles.count, 1)
    let heldJoinHandle: SearchParentWireHandle? = try XCTUnwrap(held.joinHandles.first)
    XCTAssertEqual(heldJoinHandle, held.submittedHandles.first)
    XCTAssertTrue(held.joinReturns.isEmpty)
    XCTAssertFalse(fixture.events.snapshot.trace.contains("controller.join.return"))
    XCTAssertEqual(fixture.h.system.signals, [.init(pid: 7310, signal: SIGKILL)])
    XCTAssertEqual(fixture.h.system.polledPIDs, [7310, 7310])

    readReturn.open()
    await fixture.events.sessionReleased.wait()
    XCTAssertEqual(fixture.events.snapshot.releasedGeneration, identity.generation)
    let result = try observed(await closing.value)
    let completion = try completed(result.parent)
    XCTAssertEqual(completion.ownership, .admitted)
    XCTAssertEqual(completion.laneStop, .acknowledged)
    XCTAssertTrue(completion.shutdown.parentLaneSettled)
    XCTAssertTrue(completion.shutdown.child.channelsClosed)
    // Normal first shutdown waits for actual slot absence. Its unmodified
    // receipt is noChild, not an earlier external reaped snapshot.
    XCTAssertEqual(completion.shutdown.child.cleanup, .noChild)
    let raw = await fixture.boundary.snapshot()
    XCTAssertEqual(raw.joinReturns, [result.parent])
    let refreshed = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(refreshed.parent, result.parent)
    assertEmpty(refreshed)
    let afterRefresh = await fixture.boundary.snapshot()
    XCTAssertEqual(afterRefresh.joinHandles.count, 1)
    assertEmpty(result)
    XCTAssertEqual(connection.snapshot.activeReads, 0)
    let trace = fixture.events.snapshot.trace
    let released = try XCTUnwrap(trace.firstIndex(of: "parent.session.released"))
    let returned = try XCTUnwrap(trace.firstIndex(of: "controller.join.return"))
    XCTAssertLessThan(released, returned)
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(fixture.h.system.launchCount.value, 1)
    XCTAssertEqual(fixture.h.system.signals, [.init(pid: 7310, signal: SIGKILL)])
    XCTAssertEqual(fixture.h.system.polledPIDs, [7310, 7310])
  }

  // Break: early nil join, receipt discard, competing wait or duplicate exact
  // cancellation. Entry/return probes never supply the parent's receipt.
  func testActualCancelledActiveRequestPreservesSoleWaitAndExactJoinHandle() async throws {
    let connection = DriverTestConnection(holdClose: true)
    let fixture = try makeFixture(connection: connection)
    fixture.h.system.reapOnSignal = true
    var deliveries = 0
    _ = try fixture.submit(text: "x", pattern: "x") { _ in deliveries += 1 }
    let identity = try await connect(fixture, pid: 7311)
    await fixture.events.observerInstalled.wait()
    let closing = fixture.closeJoined()
    await fixture.events.cancellationStarted.wait()
    await connection.closeEntered.wait(for: 1)
    await fixture.boundary.joinEntered.wait()
    let atJoin = await fixture.boundary.snapshot()
    let handle = try XCTUnwrap(atJoin.submittedHandles.first)
    XCTAssertEqual(atJoin.submittedHandles.count, 1)
    XCTAssertEqual(atJoin.waitedHandles, [handle])
    XCTAssertEqual(atJoin.waitReturns.count, 1)
    XCTAssertEqual(atJoin.cancelledHandles, [handle])
    XCTAssertEqual(atJoin.cancelReturns, [handle])
    XCTAssertEqual(atJoin.joinHandles, [handle])
    XCTAssertEqual(atJoin.discardHandles.count, 0)
    XCTAssertEqual(atJoin.waitThrows, 0)
    XCTAssertEqual(atJoin.cancelThrows, 0)
    let actualWait = try XCTUnwrap(atJoin.waitReturns.first)
    guard case .failed(let failedIdentity, .cancelled) = actualWait.outcome else {
      throw DraftFailure.unexpectedOutcome
    }
    XCTAssertEqual(failedIdentity, identity)
    XCTAssertEqual(actualWait.handle, handle)
    let parentEvents = fixture.events.snapshot
    XCTAssertEqual(parentEvents.admitted, [handle.nonce])
    XCTAssertEqual(parentEvents.observers, [handle.nonce])
    XCTAssertEqual(parentEvents.cancellations, [handle.nonce])
    XCTAssertEqual(parentEvents.delivered, [handle.nonce])
    XCTAssertEqual(parentEvents.cancelledDecisions, [handle.nonce])
    XCTAssertEqual(parentEvents.workerReturns, 1)
    XCTAssertEqual(parentEvents.releasedGeneration, identity.generation)
    let joinIndex = try XCTUnwrap(atJoin.trace.firstIndex(of: "join.enter"))
    let waitIndex = try XCTUnwrap(atJoin.trace.firstIndex(of: "wait.return"))
    let cancelIndex = try XCTUnwrap(atJoin.trace.firstIndex(of: "cancel.return"))
    XCTAssertLessThan(waitIndex, joinIndex)
    XCTAssertLessThan(cancelIndex, joinIndex)
    XCTAssertFalse(connection.closeRelease.isOpen)
    XCTAssertEqual(fixture.owner.accountingSnapshot.active, 6)
    XCTAssertEqual(fixture.owner.accountingSnapshot.reservedRetained, 3)
    XCTAssertEqual(deliveries, 0)

    connection.closeRelease.open()
    let result = try observed(await closing.value)
    let completion = try completed(result.parent)
    XCTAssertEqual(completion.ownership, .admitted)
    XCTAssertEqual(completion.laneStop, .acknowledged)
    XCTAssertTrue(completion.shutdown.parentLaneSettled)
    XCTAssertTrue(completion.shutdown.child.channelsClosed)
    XCTAssertEqual(completion.shutdown.child.cleanup, .noChild)
    assertEmpty(result)
    let refreshed = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(refreshed.parent, result.parent)
    assertEmpty(refreshed)
    let final = await fixture.boundary.snapshot()
    XCTAssertEqual(final.joinHandles, [handle])
    XCTAssertEqual(final.joinReturns, [result.parent])
    XCTAssertEqual(final.waitedHandles, [handle])
    XCTAssertEqual(final.cancelledHandles, [handle])
    XCTAssertEqual(final.discardHandles.count, 0)
    XCTAssertEqual(fixture.h.system.signals, [.init(pid: 7311, signal: SIGKILL)])
    XCTAssertEqual(fixture.h.system.polledPIDs, [7311])
    XCTAssertEqual(deliveries, 0)
  }

  func testExternallySelectedParentLegacyIsPreservedAsRawRefusal() async throws {
    let fixture = try makeFixture()
    // Deliberate ownership misuse. This external bounded snapshot need not be
    // equal to the controller's later genuine compatibility alias receipt.
    let external = Task { await fixture.actual.shutdown() }
    fixture.track(external)
    _ = await external.value
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, .callerRefused(.legacyModeSelected))
    assertEmpty(first)
    let repeated = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(repeated.parent, first.parent)
    let beforeAlias = await fixture.boundary.snapshot()
    XCTAssertEqual(beforeAlias.joinHandles.count, 1)
    let refusedJoinHandle: SearchParentWireHandle? = try XCTUnwrap(beforeAlias.joinHandles.first)
    XCTAssertNil(refusedJoinHandle)
    XCTAssertEqual(beforeAlias.joinReturns, [first.parent])
    XCTAssertEqual(beforeAlias.legacyReturns.count, 0)

    let alias = await fixture.owner.shutdown()
    let matching = await fixture.owner.shutdown()
    let boundary = await fixture.boundary.snapshot()
    XCTAssertEqual(boundary.legacyEntries, 1)
    XCTAssertEqual(boundary.legacyReturns.count, 1)
    let actualAlias = try XCTUnwrap(boundary.legacyReturns.first)
    XCTAssertEqual(alias.driver, actualAlias)
    XCTAssertEqual(matching.driver, actualAlias)
    XCTAssertEqual(matching.driverSettlement, .settled(admissionClosed: true))
    let final = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(final.parent, .callerRefused(.legacyModeSelected))
    assertEmpty(final)
    XCTAssertEqual(fixture.h.system.launchCount.value, 0)
    XCTAssertEqual(fixture.h.system.signalCount.value, 0)
  }

  private enum DraftFailure: Error {
    case unexpectedDelivery, unexpectedOutcome, notObserved, notCompleted
  }

  private func makeFixture(connection: DriverTestConnection = DriverTestConnection()) throws
    -> JoinedActualAdmissionFixture
  {
    let fixture = try JoinedActualAdmissionFixture(connection: connection)
    // Registered before the first setup mutation, submission or suspension.
    addTeardownBlock { await fixture.cleanup() }
    return fixture
  }

  private func connect(_ fixture: JoinedActualAdmissionFixture, pid: Int32) async throws
    -> SearchWireIdentity
  {
    await fixture.h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(fixture.h.system.generations.first)
    fixture.h.system.deliver(generation: generation, pid: pid, connection: fixture.connection)
    await fixture.events.connected.wait()
    await fixture.events.ticketStored.wait()
    let metadata = fixture.events.snapshot
    let ticket = try XCTUnwrap(metadata.ticket)
    let connection = try XCTUnwrap(metadata.connection)
    XCTAssertEqual(ticket.identity.generation, generation)
    XCTAssertEqual(connection.generation, generation)
    XCTAssertEqual(ticket.nonce, connection.nonce)
    fixture.events.expectSessionRelease(generation)
    await fixture.connection.waitForWriteCalls(2)
    fixture.connection.offer(try DriverTestWire.childHello(generation: generation))
    await fixture.connection.waitForWriteCalls(7)
    return ticket.identity
  }

  private func observed(_ result: SearchAdmissionJoinedShutdownResult) throws
    -> SearchAdmissionJoinedShutdownObservation
  {
    guard case .observed(let observation) = result else {
      XCTFail("Actual controller refused factual observation: \(result)")
      throw DraftFailure.notObserved
    }
    return observation
  }

  private func completed(_ result: SearchParentJoinedShutdownResult) throws
    -> SearchParentJoinedShutdownCompletion
  {
    guard case .completed(let completion) = result else {
      XCTFail("Actual parent refused joined ownership: \(result)")
      throw DraftFailure.notCompleted
    }
    return completion
  }

  private func assertEmpty(
    _ observation: SearchAdmissionJoinedShutdownObservation,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      observation.driverSettlement, .settled(admissionClosed: true), file: file, line: line)
    XCTAssertEqual(observation.retainedActiveJobs, 0, file: file, line: line)
    XCTAssertEqual(observation.retainedLeases, 0, file: file, line: line)
    XCTAssertEqual(observation.activeCharge, 2, file: file, line: line)
    XCTAssertEqual(observation.retainedCharge, 0, file: file, line: line)
    XCTAssertEqual(observation.reservedRetainedCharge, 0, file: file, line: line)
  }
}

@MainActor private final class JoinedActualAdmissionFixture {
  let h: DriverHarness
  let connection: DriverTestConnection
  let events: JoinedActualAdmissionEvents
  let actual: SearchParentWireDriver
  let boundary: JoinedActualAdmissionBoundary
  let owner: SearchAdmissionController<String>
  private var callers: [Task<Void, Never>] = []
  private var captures = 0

  init(connection: DriverTestConnection) throws {
    h = try DriverHarness()
    self.connection = connection
    let events = JoinedActualAdmissionEvents()
    self.events = events
    let actual = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 16_384, observe: { events.receive($0) })
    self.actual = actual
    let boundary = JoinedActualAdmissionBoundary(actual: actual)
    self.boundary = boundary
    owner = try SearchAdmissionController(
      driver: boundary, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry(),
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      }, observe: { if case .workerExited = $0 { events.workerReturned() } })
  }

  func submit(
    text: String, pattern: String,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  )
    throws -> SearchJobID
  {
    let descriptor = try SearchAdmissionDescriptor(
      query: .init(pattern: pattern, mode: .literal), operation: .find,
      estimatedInputUTF16: text.utf16.count, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 8, cooperativeMilliseconds: 0))
    return try owner.submit(
      consumer: owner.register(), descriptor: descriptor,
      capture: { [self] in
        captures += 1
        return .init(text: text, inputUTF16: text.utf16.count, context: "synthetic-joined-context")
      }, completion: completion)
  }

  func closeJoined() -> Task<SearchAdmissionJoinedShutdownResult, Never> {
    let task = Task { [owner, events] in
      let result = await owner.shutdownJoined()
      events.record("controller.join.return")
      return result
    }
    track(task)
    return task
  }

  func track<Value>(_ task: Task<Value, Never>) {
    precondition(callers.count < 16, "Finite actual-driver caller inventory")
    callers.append(Task { _ = await task.value })
  }

  func cleanup() async {
    connection.releaseAllGates()
    h.prepareCleanup()
    // Prepare all real gates/reap before either authority runs. The underlying
    // actual driver stop is independent of the candidate controller receipt.
    let ownerStop = Task { await owner.shutdown() }
    let actualStop = Task { await actual.shutdown() }
    _ = await actualStop.value
    // This callback follows actual prepare/request return and has no further
    // suspension before its MainActor worker returns. It cannot be replaced by
    // an early candidate joined receipt. There is at most one captured job.
    if captures > 0 { await events.workerReturnCount.wait(for: captures) }
    if let connection = events.snapshot.connection {
      events.expectSessionRelease(connection.generation)
      await events.sessionReleased.wait()
      XCTAssertEqual(events.snapshot.releasedGeneration, connection.generation)
    }
    for caller in callers { await caller.value }
    _ = await ownerStop.value
    let scopes = self.connection.snapshot
    XCTAssertEqual(scopes.activeReads, 0)
    XCTAssertEqual(scopes.activeWrites, 0)
    XCTAssertEqual(events.snapshot.workerReturns, captures)
  }
}

/// Observes unchanged production events. Identity comes from admission metadata,
/// never from a scripted response or a conveniently manufactured receipt.
private final class JoinedActualAdmissionEvents: @unchecked Sendable {
  struct Snapshot {
    var ticket: (nonce: UUID, identity: SearchWireIdentity)?
    var connection: (nonce: UUID, generation: UUID)?
    var admitted: [UUID] = []
    var observers: [UUID] = []
    var cancellations: [UUID] = []
    var delivered: [UUID] = []
    var cancelledDecisions: [UUID] = []
    var expectedReleaseGeneration: UUID?
    var releasedGeneration: UUID?
    var workerReturns = 0
    var trace: [String] = []
  }
  private let state = DriverTestLocked(Snapshot())
  let connected = DriverTestGate()
  let ticketStored = DriverTestGate()
  let observerInstalled = DriverTestGate()
  let cancellationStarted = DriverTestGate()
  let sessionReleased = DriverTestGate()
  let workerReturnCount = DriverTestCount()
  var snapshot: Snapshot { state.withValue { $0 } }

  func record(_ event: String) {
    state.withValue { if $0.trace.count < 64 { $0.trace.append(event) } }
  }

  func workerReturned() {
    state.withValue { $0.workerReturns += 1 }
    record("controller.worker.return")
    workerReturnCount.increment()
  }

  func expectSessionRelease(_ generation: UUID) {
    let released = state.withValue {
      $0.expectedReleaseGeneration = generation
      return $0.releasedGeneration == generation
    }
    if released { sessionReleased.open() }
  }

  func receive(_ event: SearchParentDriverEvent) {
    switch event {
    case .admitted(let nonce):
      state.withValue {
        precondition($0.admitted.count < 4)
        $0.admitted.append(nonce)
      }
    case .ticketStored(let nonce, let identity):
      state.withValue { $0.ticket = (nonce, identity) }
      ticketStored.open()
    case .connectionAvailable(let nonce, let generation):
      state.withValue { $0.connection = (nonce, generation) }
      connected.open()
    case .observerInstalled(let nonce):
      state.withValue {
        precondition($0.observers.count < 4)
        $0.observers.append(nonce)
      }
      observerInstalled.open()
    case .cancellationStarted(let nonce):
      state.withValue {
        precondition($0.cancellations.count < 4)
        $0.cancellations.append(nonce)
      }
      cancellationStarted.open()
    case .resultDelivered(let nonce):
      state.withValue {
        precondition($0.delivered.count < 4)
        $0.delivered.append(nonce)
      }
    case .lifecycleDecided(let nonce, .failed(.cancelled)):
      state.withValue {
        precondition($0.cancelledDecisions.count < 4)
        $0.cancelledDecisions.append(nonce)
      }
    case .sessionReleased(let generation):
      let matches = state.withValue {
        $0.releasedGeneration = generation
        if $0.trace.count < 64 { $0.trace.append("parent.session.released") }
        return $0.expectedReleaseGeneration == generation
      }
      if matches { sessionReleased.open() }
    default:
      break
    }
  }
}

/// Transparent boundary recorder over the actual driver. Every forwarded value
/// and thrown error is unchanged; no cache, synthetic result or second observer.
private actor JoinedActualAdmissionBoundary: SearchParentWireJoining {
  struct WaitReturn: Sendable {
    let handle: SearchParentWireHandle
    let outcome: SearchParentWireOutcome
  }
  struct Snapshot: Sendable {
    var submittedHandles: [SearchParentWireHandle] = []
    var waitedHandles: [SearchParentWireHandle] = []
    var waitReturns: [WaitReturn] = []
    var waitThrows = 0
    var cancelledHandles: [SearchParentWireHandle] = []
    var cancelReturns: [SearchParentWireHandle] = []
    var cancelThrows = 0
    var discardHandles: [SearchParentWireHandle] = []
    var joinHandles: [SearchParentWireHandle?] = []
    var joinReturns: [SearchParentJoinedShutdownResult] = []
    var legacyEntries = 0
    var legacyReturns: [SearchParentWireShutdown] = []
    var trace: [String] = []
  }
  private let actual: SearchParentWireDriver
  private var state = Snapshot()
  nonisolated let joinEntered = DriverTestGate()

  init(actual: SearchParentWireDriver) { self.actual = actual }
  func snapshot() -> Snapshot { state }

  func settlement(after handle: SearchParentWireHandle?) async throws -> SearchParentWireSettlement
  {
    try await actual.settlement(after: handle)
  }

  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle {
    record("submit.enter")
    let handle = try await actual.submit(job)
    precondition(state.submittedHandles.count < 4)
    state.submittedHandles.append(handle)
    record("submit.return")
    return handle
  }

  func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome {
    precondition(state.waitedHandles.count < 4)
    state.waitedHandles.append(handle)
    record("wait.enter")
    do {
      let outcome = try await actual.wait(for: handle)
      state.waitReturns.append(.init(handle: handle, outcome: outcome))
      record("wait.return")
      return outcome
    } catch {
      state.waitThrows += 1
      record("wait.throw")
      throw error
    }
  }

  func cancel(_ handle: SearchParentWireHandle) async throws {
    precondition(state.cancelledHandles.count < 4)
    state.cancelledHandles.append(handle)
    record("cancel.enter")
    do {
      try await actual.cancel(handle)
      state.cancelReturns.append(handle)
      record("cancel.return")
    } catch {
      state.cancelThrows += 1
      record("cancel.throw")
      throw error
    }
  }

  func discard(_ handle: SearchParentWireHandle) async throws {
    precondition(state.discardHandles.count < 4)
    state.discardHandles.append(handle)
    record("discard.enter")
    try await actual.discard(handle)
    record("discard.return")
  }

  func shutdownJoined(after handle: SearchParentWireHandle?) async
    -> SearchParentJoinedShutdownResult
  {
    precondition(state.joinHandles.count < 4)
    state.joinHandles.append(handle)
    record("join.enter")
    joinEntered.open()
    let result = await actual.shutdownJoined(after: handle)
    state.joinReturns.append(result)
    record("join.return")
    return result
  }

  func shutdown() async -> SearchParentWireShutdown {
    precondition(state.legacyEntries < 4)
    state.legacyEntries += 1
    record("legacy.enter")
    let receipt = await actual.shutdown()
    state.legacyReturns.append(receipt)
    record("legacy.return")
    return receipt
  }

  private func record(_ event: String) {
    if state.trace.count < 64 { state.trace.append(event) }
  }
}
