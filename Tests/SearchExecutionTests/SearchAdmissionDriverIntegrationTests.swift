import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Actual owner/driver/lifecycle composition with injected process and channel collaborators.
/// No process, descriptor, wall clock, helper, or native window is used by these tests.
@MainActor final class SearchAdmissionDriverIntegrationTests: XCTestCase {
  func testHealthyActualDriverPublishesExactBorrowedLease() async throws {
    let h = try DriverHarness()
    let observed = AdmissionDriverObservation()
    let driver = try makeDriver(h, observed: observed)
    let owner = try SearchAdmissionController<String>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    addTeardownBlock {
      h.prepareCleanup()
      _ = await owner.shutdown()
    }
    defer { h.releaseAllGates() }
    let delivered = DriverTestGate()
    var captures = 0
    var deliveries: [SearchAdmissionDelivery] = []
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        captures += 1
        return .init(text: "x", inputUTF16: 1, context: "synthetic-context")
      },
      completion: {
        deliveries.append($0)
        delivered.open()
      })
    let identity = try await connect(h, connection: h.connection, observed: observed, pid: 7210)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await delivered.wait()
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(deliveries.count, 1)
    guard case .completed(let lease) = try XCTUnwrap(deliveries.first) else {
      XCTFail("Actual driver success must publish a lease")
      h.prepareCleanup()
      _ = await owner.shutdown()
      return
    }
    XCTAssertTrue(
      owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, "synthetic-context")
        XCTAssertEqual(source, "x")
        XCTAssertEqual(output.matches, [NSRange(location: 0, length: 1)])
        XCTAssertNil(output.replacement)
      })
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 0)
    XCTAssertEqual(owner.accountingSnapshot.reservationCount, 0)
    XCTAssertEqual(owner.accountingSnapshot.leaseCount, 1)
    XCTAssertFalse(h.connection.snapshot.closed)
    XCTAssertEqual(h.system.signalCount.value, 0)
    owner.release(lease)
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    h.prepareCleanup()
    let first = await owner.shutdown()
    // Legacy shutdown joins child cleanup, but only observes parent settlement.
    // Closing the injected connection does not join the driver's idle read owner.
    await observed.sessionReleased.wait()
    XCTAssertEqual(observed.releasedGeneration, identity.generation)
    let stopped = await owner.shutdown()
    XCTAssertEqual(stopped.driver, first.driver)
    XCTAssertEqual(stopped.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(stopped.retainedActiveJobs, 0)
    XCTAssertEqual(stopped.retainedLeases, 0)
  }

  // Break: treating physical close/reap as proof that the parent idle read scope exited.
  func testHealthyShutdownStaysPendingUntilActualIdleReadScopeExits() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let readReturn = DriverTestGate()
    let connection = DriverTestConnection(cancelledReadReturn: readReturn)
    let observed = AdmissionDriverObservation()
    let driver = try makeDriver(h, observed: observed)
    let owner = try SearchAdmissionController<String>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    addTeardownBlock {
      connection.releaseAllGates()
      h.prepareCleanup()
      _ = await owner.shutdown()
    }
    defer {
      connection.releaseAllGates()
      h.releaseAllGates()
    }
    let delivered = DriverTestGate()
    var deliveries: [SearchAdmissionDelivery] = []
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: "held-idle-read") },
      completion: {
        deliveries.append($0)
        delivered.open()
      })
    let identity = try await connect(h, connection: connection, observed: observed, pid: 7213)
    connection.offer(try DriverTestWire.success(identity: identity))
    await delivered.wait()
    XCTAssertEqual(deliveries.count, 1)
    guard case .completed(let lease) = try XCTUnwrap(deliveries.first) else {
      return XCTFail("Actual driver success must publish a lease")
    }
    owner.release(lease)
    assertEmpty(owner)
    // Hello, terminal response, then the actual source-free idle read. Its return
    // gate is independent of close(), the sole consuming reap, and child shutdown.
    await connection.waitForReadCalls(3)
    XCTAssertEqual(connection.readEntered.value, 3)
    XCTAssertEqual(connection.snapshot.activeReads, 1)
    XCTAssertFalse(observed.sessionReleased.isOpen)
    let first = await owner.shutdown()
    await connection.cancelledReadReturning.wait(for: 1)
    XCTAssertTrue(first.driver.child.stopped)
    XCTAssertTrue(first.driver.child.channelsClosed)
    XCTAssertFalse(first.driver.parentLaneSettled)
    XCTAssertEqual(first.driver.retainedParentLanes, 1)
    XCTAssertEqual(first.driverSettlement, .pending)
    XCTAssertEqual(first.retainedActiveJobs, 0)
    XCTAssertEqual(first.retainedLeases, 0)
    XCTAssertEqual(connection.snapshot.activeReads, 1)
    XCTAssertFalse(readReturn.isOpen)
    XCTAssertFalse(observed.sessionReleased.isOpen)
    XCTAssertNil(observed.releasedGeneration)
    assertEmpty(owner)
    XCTAssertEqual(h.system.signals, [.init(pid: 7213, signal: SIGKILL)])
    let polls = h.system.pollCount.value
    let timers = h.timers.scheduled.value

    readReturn.open()
    // The driver emits this only after readLoop returns from read/discard scopes,
    // readOwnerExited clears the session and matching codec-lane ownership ends.
    await observed.sessionReleased.wait()
    XCTAssertEqual(observed.releasedGeneration, identity.generation)
    XCTAssertEqual(connection.snapshot.activeReads, 0)
    let stopped = await owner.shutdown()
    XCTAssertEqual(stopped.driver, first.driver)
    XCTAssertEqual(stopped.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(stopped.retainedActiveJobs, 0)
    XCTAssertEqual(stopped.retainedLeases, 0)
    assertEmpty(owner)
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(h.system.launchCount.value, 1)
    XCTAssertEqual(h.system.signals, [.init(pid: 7213, signal: SIGKILL)])
    XCTAssertEqual(h.system.pollCount.value, polls)
    XCTAssertEqual(h.timers.scheduled.value, timers)
  }

  func testCancellationKeepsReservationUntilActualReapAndCloseThenTerminalShutdown() async throws {
    let h = try DriverHarness()
    let connection = DriverTestConnection(holdClose: true)
    let observed = AdmissionDriverObservation()
    let driver = try makeDriver(h, observed: observed)
    let retry = AdmissionManualRetry()
    let retryScheduled = DriverTestCount()
    retry.onSchedule = { retryScheduled.increment() }
    let workerExited = DriverTestGate()
    let owner = try makeObservedOwner(driver, retry: retry, workerExited: workerExited)
    addTeardownBlock {
      connection.releaseAllGates()
      h.prepareCleanup()
      _ = await owner.shutdown()
    }
    defer {
      h.releaseAllGates()
      connection.releaseAllGates()
    }
    var completions = 0
    var firstCaptures = 0
    let first = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        firstCaptures += 1
        return .init(text: "x", inputUTF16: 1, context: "first")
      },
      completion: { _ in completions += 1 })
    _ = try await connect(h, connection: connection, observed: observed, pid: 7211)
    var queuedCaptures = 0
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        queuedCaptures += 1
        throw SearchAdmissionFailure.captureRefused
      }, completion: { _ in completions += 1 })
    owner.cancel(first)
    await workerExited.wait()
    await connection.closeEntered.wait(for: 1)
    await retryScheduled.wait(for: 1)
    XCTAssertTrue(observed.cancelled)
    XCTAssertEqual(firstCaptures, 1)
    XCTAssertEqual(retryScheduled.value, 1)
    XCTAssertEqual(h.system.signals, [.init(pid: 7211, signal: SIGKILL)])
    XCTAssertEqual(queuedCaptures, 0)
    XCTAssertEqual(completions, 0)
    assertReserved(owner)
    let pollsBeforeRetry = h.system.pollCount.value
    let nextRetry = retryScheduled.value + 1
    retry.fire()
    await retryScheduled.wait(for: nextRetry)
    XCTAssertEqual(retryScheduled.value, 2)
    XCTAssertEqual(h.system.pollCount.value, pollsBeforeRetry)
    assertReserved(owner)
    XCTAssertEqual(queuedCaptures, 0)

    // A real lifecycle maintenance callback consumes the injected reap while close stays held.
    h.system.setPoll(.reaped(.signaled(SIGKILL)), for: 7211)
    let deadline = try XCTUnwrap(h.timers.activeDeadlines.min())
    let nextPoll = h.system.pollCount.value + 1
    h.timers.fireDue(at: h.clock.advance(by: deadline - h.clock.now))
    await h.system.pollCount.wait(for: nextPoll)
    let physicallyHeld = await h.lifecycle.admissionInspection()
    XCTAssertEqual(physicallyHeld, .unsettled)
    XCTAssertFalse(connection.closeRelease.isOpen)
    let retryAfterReap = retryScheduled.value + 1
    retry.fire()
    await retryScheduled.wait(for: retryAfterReap)
    XCTAssertEqual(retryScheduled.value, 3)
    XCTAssertEqual(h.system.pollCount.value, nextPoll)
    assertReserved(owner)
    XCTAssertEqual(queuedCaptures, 0)
    XCTAssertEqual(completions, 0)

    // The first shutdown waiter acknowledges connectionClosed; opening its gate alone does not.
    // This is terminal completion, not evidence of nonterminal FIFO advancement.
    let shutdownTimer = h.timers.scheduled.value + 1
    let stopping = Task { await owner.shutdown() }
    await h.timers.scheduled.wait(for: shutdownTimer)
    assertReserved(owner)
    connection.closeRelease.open()
    let stopped = await stopping.value
    XCTAssertEqual(stopped.driverSettlement, .settled(admissionClosed: true))
    XCTAssertTrue(stopped.driver.child.channelsClosed)
    XCTAssertEqual(stopped.retainedActiveJobs, 0)
    XCTAssertEqual(stopped.retainedLeases, 0)
    assertEmpty(owner)
    XCTAssertEqual(queuedCaptures, 0)
    XCTAssertEqual(completions, 0)
    XCTAssertEqual(h.system.launchCount.value, 1)
    XCTAssertEqual(h.system.signals, [.init(pid: 7211, signal: SIGKILL)])
  }

  func testRepeatedShutdownKeepsHistoricalReceiptUntilActualWriteScopeExits() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let executeReturn = DriverTestGate()
    for _ in 0..<6 { h.connection.enqueueWrite(.init()) }
    h.connection.enqueueWrite(.init(returnRelease: executeReturn))
    let observed = AdmissionDriverObservation()
    let driver = try makeDriver(h, observed: observed)
    let workerExited = DriverTestGate()
    let owner = try makeObservedOwner(
      driver, retry: AdmissionManualRetry(), workerExited: workerExited)
    addTeardownBlock {
      executeReturn.open()
      h.prepareCleanup()
      _ = await owner.shutdown()
    }
    defer {
      executeReturn.open()
      h.releaseAllGates()
    }
    var completions = 0
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: "held-write") },
      completion: { _ in completions += 1 })
    _ = try await connect(h, connection: h.connection, observed: observed, pid: 7212)
    await h.connection.writeCompleted.wait(for: 7)
    XCTAssertFalse(executeReturn.isOpen)
    let first = await owner.shutdown()
    XCTAssertTrue(first.driver.child.channelsClosed)
    XCTAssertFalse(first.driver.parentLaneSettled)
    XCTAssertEqual(first.driver.retainedParentLanes, 1)
    XCTAssertEqual(first.driverSettlement, .pending)
    XCTAssertEqual(first.retainedActiveJobs, 1)
    XCTAssertEqual(first.retainedLeases, 0)
    assertReserved(owner)
    let scheduled = h.timers.scheduled.value
    let repeated = await owner.shutdown()
    XCTAssertEqual(repeated, first)
    XCTAssertEqual(h.timers.scheduled.value, scheduled)
    XCTAssertEqual(h.system.signals, [.init(pid: 7212, signal: SIGKILL)])
    XCTAssertFalse(workerExited.isOpen)
    XCTAssertEqual(completions, 0)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: {
          XCTFail("Terminal owner cannot capture")
          throw SearchAdmissionFailure.shutdown
        },
        completion: { _ in XCTFail("Terminal owner cannot publish") })
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .shutdown) }

    executeReturn.open()
    await observed.coordinatorExited.wait()
    await workerExited.wait()
    let settled = await owner.shutdown()
    XCTAssertEqual(settled.driver, first.driver)
    XCTAssertEqual(settled.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(settled.retainedActiveJobs, 0)
    XCTAssertEqual(settled.retainedLeases, 0)
    assertEmpty(owner)
    XCTAssertEqual(completions, 0)
    XCTAssertEqual(h.system.signals, [.init(pid: 7212, signal: SIGKILL)])
    XCTAssertEqual(h.system.launchCount.value, 1)
  }

  private func descriptor() throws -> SearchAdmissionDescriptor {
    try .init(
      query: .init(pattern: "x", mode: .literal), operation: .find, estimatedInputUTF16: 1,
      scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 8, cooperativeMilliseconds: 0))
  }

  private func makeDriver(_ h: DriverHarness, observed: AdmissionDriverObservation) throws
    -> SearchParentWireDriver
  {
    try .init(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000, observe: { observed.receive($0) })
  }

  private func makeObservedOwner(
    _ driver: SearchParentWireDriver, retry: AdmissionManualRetry, workerExited: DriverTestGate
  ) throws -> SearchAdmissionController<String> {
    try .init(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry,
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      }, observe: { if case .workerExited = $0 { workerExited.open() } })
  }

  private func connect(
    _ h: DriverHarness, connection: DriverTestConnection,
    observed: AdmissionDriverObservation, pid: Int32
  ) async throws -> SearchWireIdentity {
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: pid, connection: connection)
    await observed.connected.wait()
    await observed.ticketStored.wait()
    let admission = try XCTUnwrap(observed.admission)
    XCTAssertEqual(admission.identity.generation, generation)
    XCTAssertEqual(admission.connectionGeneration, generation)
    XCTAssertEqual(admission.ticketNonce, admission.connectionNonce)
    observed.expectSessionRelease(generation: admission.identity.generation)
    await connection.waitForWriteCalls(2)
    connection.offer(try DriverTestWire.childHello(generation: generation))
    await connection.waitForWriteCalls(7)
    // Expected identity comes from actual admission metadata before any response, never an outcome.
    return admission.identity
  }

  private func assertReserved(
    _ owner: SearchAdmissionController<String>, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(owner.accountingSnapshot.active, 6, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.retained, 0, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 3, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.reservationCount, 1, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.leaseCount, 0, file: file, line: line)
  }

  private func assertEmpty(
    _ owner: SearchAdmissionController<String>, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(owner.accountingSnapshot.active, 2, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.retained, 0, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 0, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.reservationCount, 0, file: file, line: line)
    XCTAssertEqual(owner.accountingSnapshot.leaseCount, 0, file: file, line: line)
  }
}

private final class AdmissionDriverObservation: @unchecked Sendable {
  struct Admission {
    let ticketNonce: UUID
    let identity: SearchWireIdentity
    let connectionNonce: UUID
    let connectionGeneration: UUID
  }
  private struct State {
    var ticket: (UUID, SearchWireIdentity)?
    var connection: (UUID, UUID)?
    var cancelled = false
    var expectedReleaseGeneration: UUID?
    var releasedGeneration: UUID?
  }
  private let state = DriverTestLocked(State())
  let ticketStored = DriverTestGate()
  let connected = DriverTestGate()
  let coordinatorExited = DriverTestGate()
  let sessionReleased = DriverTestGate()
  var cancelled: Bool { state.withValue { $0.cancelled } }
  var releasedGeneration: UUID? { state.withValue { $0.releasedGeneration } }
  func expectSessionRelease(generation: UUID) {
    let released = state.withValue {
      $0.expectedReleaseGeneration = generation
      return $0.releasedGeneration == generation
    }
    if released { sessionReleased.open() }
  }
  var admission: Admission? {
    state.withValue {
      guard let ticket = $0.ticket, let connection = $0.connection else { return nil }
      return .init(
        ticketNonce: ticket.0, identity: ticket.1,
        connectionNonce: connection.0, connectionGeneration: connection.1)
    }
  }
  func receive(_ event: SearchParentDriverEvent) {
    switch event {
    case .ticketStored(let nonce, let identity):
      state.withValue { $0.ticket = (nonce, identity) }
      ticketStored.open()
    case .connectionAvailable(let nonce, let generation):
      state.withValue { $0.connection = (nonce, generation) }
      connected.open()
    case .lifecycleDecided(_, .failed(.cancelled)):
      state.withValue { $0.cancelled = true }
    case .coordinatorScopeExited:
      coordinatorExited.open()
    case .sessionReleased(let generation):
      let matches = state.withValue {
        $0.releasedGeneration = generation
        return $0.expectedReleaseGeneration == generation
      }
      if matches { sessionReleased.open() }
    default: break
    }
  }
}
