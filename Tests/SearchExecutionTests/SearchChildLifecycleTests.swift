import Darwin
import Foundation
import XCTest

@testable import SearchExecution

final class SearchChildLifecycleTests: XCTestCase {
  func testAdmissionInspectionAbsentAndClosedDoesNotScheduleOrPoll() async throws {
    let h = try Harness()
    let before = await h.lifecycle.admissionInspection()
    XCTAssertEqual(before, .absent(admissionClosed: false))
    XCTAssertTrue(h.system.launches.isEmpty)
    XCTAssertTrue(h.system.signals.isEmpty)
    XCTAssertTrue(h.system.polledPIDs.isEmpty)
    XCTAssertEqual(h.timers.count, 0)
    _ = await h.lifecycle.shutdown()
    let after = await h.lifecycle.admissionInspection()
    XCTAssertEqual(after, .absent(admissionClosed: true))
    XCTAssertEqual(h.timers.count, 0)
  }

  func testAdmissionInspectionDistinguishesActiveFromHealthyIdleWithoutMutation() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    let active = await h.lifecycle.admissionInspection()
    XCTAssertEqual(active, .unsettled)
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    let before = (h.system.polledPIDs, h.system.signals, h.timers.activeDeadlines, h.timers.count)
    let idle = await h.lifecycle.admissionInspection()
    XCTAssertEqual(idle, .healthy(generation: ticket.identity.generation))
    XCTAssertEqual(h.system.polledPIDs, before.0)
    XCTAssertEqual(h.system.signals, before.1)
    XCTAssertEqual(h.timers.activeDeadlines, before.2)
    XCTAssertEqual(h.timers.count, before.3)
    let next = try await h.lifecycle.begin(requestID: UUID())
    XCTAssertEqual(next.identity.generation, ticket.identity.generation)
    let activeAgain = await h.lifecycle.admissionInspection()
    XCTAssertEqual(activeAgain, .unsettled)
    await h.dispose()
  }

  func testAdmissionInspectionRetainsReapedChildUntilCloseAcknowledgment() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    h.system.poll = .reaped(.exited(0))
    try await h.lifecycle.cancel(ticket)
    await h.connection.started.wait()
    let before = (h.system.polledPIDs, h.system.signals, h.timers.count)
    let held = await h.lifecycle.admissionInspection()
    XCTAssertEqual(held, .unsettled)
    XCTAssertEqual(h.system.polledPIDs, before.0)
    XCTAssertEqual(h.system.signals, before.1)
    XCTAssertEqual(h.timers.count, before.2)
    let stopping = Task { await h.lifecycle.shutdown() }
    await h.timers.waitForDeadline(100_000_000)
    let closedButHeld = await h.lifecycle.admissionInspection()
    XCTAssertEqual(closedButHeld, .unsettled)
    h.connection.release.open()
    _ = await stopping.value
    let settled = await h.lifecycle.admissionInspection()
    XCTAssertEqual(settled, .absent(admissionClosed: true))
    let receipt = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(receipt, .reaped(generation: ticket.identity.generation, exit: .exited(0)))
  }

  func testAdmissionInspectionHeldLaunchAndUnconfirmedStopRemainUnsettled() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let launch = await h.lifecycle.admissionInspection()
    XCTAssertEqual(launch, .unsettled)
    h.system.deliver(ticket, pid: 49, connection: h.connection)
    _ = try await h.lifecycle.connection(for: ticket)
    h.system.poll = .failed(ECHILD)
    try await h.lifecycle.cancel(ticket)
    await h.connection.started.wait()
    let before = (h.system.polledPIDs, h.system.signals, h.timers.count)
    let unconfirmed = await h.lifecycle.admissionInspection()
    XCTAssertEqual(unconfirmed, .unsettled)
    XCTAssertEqual(h.system.polledPIDs, before.0)
    XCTAssertEqual(h.system.signals, before.1)
    XCTAssertEqual(h.timers.count, before.2)
    await h.dispose()
  }

  func testStartupFailureStopsOwnedChildWithoutPublishingConnection() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let operationTimer = try XCTUnwrap(h.timers.last(at: 1_000_000_000))
    let refused = Gate()
    func connect() async -> Error? {
      let error = await caught { _ = try await h.lifecycle.connection(for: ticket) }
      if error as? SearchChildFailure == .observerBusy { refused.open() }
      return error
    }
    let first = Task { await connect() }
    let second = Task { await connect() }
    await refused.wait()  // One connector is now installed; the other was refused.
    h.system.deliver(ticket, pid: 73, connection: h.connection, startupFailure: .launchFailed(EIO))
    try await h.barrier(ticket)
    XCTAssertEqual(h.system.signals, [.init(pid: 73, signal: SIGKILL)])
    XCTAssertFalse(operationTimer.isActive, "Startup failure decides before the deadline callback")
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }

    // Deterministic RED backstop: an ignored startupFailure must finish by this old
    // timer, yielding the wrong outcome instead of hanging the expected-failure run.
    h.clock.now = 1_000_000_000
    operationTimer.forceFire()
    try await h.barrier(ticket)
    let errors = await [first.value, second.value]
    XCTAssertEqual(errors.filter { $0 as? SearchChildFailure == .observerBusy }.count, 1)
    XCTAssertEqual(errors.filter { $0 as? SearchChildFailure == .staleTicket }.count, 1)
    XCTAssertEqual(errors.filter { $0 == nil }.count, 0, "No usable connection may escape")
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.launchFailed(EIO)))
    await failure(.staleTicket) { try await h.lifecycle.cancel(ticket) }
    await failure(.staleTicket) {
      try await h.lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    }
    await failure(.staleTicket) { try await h.lifecycle.acceptedTerminal(.success, ticket: ticket) }
    let retained = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(retained, outcome)

    await h.connection.started.wait()
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.clock.now = 1_100_000_000
    h.timers.fireDue(at: h.clock.now)
    try await h.barrier(ticket)
    let cleanup = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(
      cleanup, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    XCTAssertFalse(h.system.polledPIDs.isEmpty)
    XCTAssertTrue(h.system.polledPIDs.allSatisfy { $0 == 73 })
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    let shutdown = Task { await h.lifecycle.shutdown() }
    await h.timers.waitForDeadline(1_200_000_000)
    let held = await h.lifecycle.shutdown()
    XCTAssertEqual(held.cleanup, cleanup)
    XCTAssertFalse(held.channelsClosed)
    XCTAssertFalse(held.stopped)
    let pollCount = h.system.polledPIDs.count
    operationTimer.forceFire()
    try await h.barrier(ticket)
    XCTAssertEqual(h.system.polledPIDs.count, pollCount)
    h.connection.release.open()
    let settled = await shutdown.value
    XCTAssertTrue(settled.stopped)
    XCTAssertEqual(h.system.signals, [.init(pid: 73, signal: SIGKILL)])
    XCTAssertEqual(h.connection.closeCalls, 1)
  }

  func testStartupFailurePreservesPriorCancelAndDeadline() async throws {
    for deadline in [false, true] {
      let h = try Harness()
      let ticket = try await h.lifecycle.begin(requestID: UUID())
      if deadline {
        h.clock.now = 1_000_000_000
        h.timers.fireDue(at: h.clock.now)
        try await h.barrier(ticket)
      } else {
        try await h.lifecycle.cancel(ticket)
      }
      let before = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(before, .failed(deadline ? .deadline : .cancelled))
      h.system.deliver(
        ticket, pid: 79, connection: h.connection, startupFailure: .launchFailed(EIO))
      try await h.barrier(ticket)
      await h.connection.started.wait()
      let after = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(after, before)
      XCTAssertEqual(h.system.signals, [.init(pid: 79, signal: SIGKILL)])
      XCTAssertEqual(h.system.polledPIDs, [79])
      await failure(.staleTicket) {
        try await h.lifecycle.acceptedHandshake(generation: ticket.identity.generation)
      }
      await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
      await h.dispose()
      XCTAssertEqual(h.connection.closeCalls, 1)
      XCTAssertEqual(h.system.signals.count, 1)
    }
  }

  func testStartupFailureDuringShutdownPreservesGraceAndHeldCleanup() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let shutdown = Task { await h.lifecycle.shutdown() }
    await h.timers.waitForDeadline(100_000_000)
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.system.deliver(ticket, pid: 83, connection: h.connection, startupFailure: .launchFailed(EIO))
    try await h.barrier(ticket)
    await h.connection.started.wait()
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.shutDown))
    h.clock.now = 100_000_000
    h.timers.fireDue(at: h.clock.now)
    let held = await shutdown.value
    XCTAssertEqual(
      held.cleanup, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    XCTAssertFalse(held.channelsClosed)
    XCTAssertFalse(held.stopped)
    let count = h.timers.count
    let repeated = await h.lifecycle.shutdown()
    XCTAssertEqual(repeated, held)
    XCTAssertEqual(h.timers.count, count)
    XCTAssertEqual(h.system.signals, [.init(pid: 83, signal: SIGKILL)])
    XCTAssertEqual(h.system.polledPIDs, [83])
    XCTAssertEqual(h.connection.closeCalls, 1)
    h.connection.release.open()
    await h.dispose()
  }

  func testStartupFailureAfterFacadeLossRetainsExactChildCleanup() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock()
    let timers = ScriptedTimers()
    let connection = HeldCloseConnection()
    var lifecycle: SearchChildLifecycle? = try makeLifecycle(system, clock, timers)
    weak let facade = lifecycle
    let ticket = try await lifecycle!.begin(requestID: UUID())
    lifecycle = nil
    XCTAssertNil(facade)
    system.poll = .reaped(.signaled(SIGKILL))
    system.deliver(ticket, pid: 89, connection: connection, startupFailure: .launchFailed(EIO))
    await connection.started.wait()
    await system.waitForPollCount(1)
    XCTAssertEqual(system.signals, [.init(pid: 89, signal: SIGKILL)])
    XCTAssertEqual(system.polledPIDs, [89])
    XCTAssertEqual(connection.closeCalls, 1)
    connection.release.open()
  }

  func testCancelledHeldLaunchRetainsSlotUntilExactReapAndChannelClose() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    try await h.lifecycle.cancel(ticket)
    h.system.deliver(ticket, pid: 41, connection: h.connection)
    try await h.barrier(ticket)
    await h.connection.started.wait()
    XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.cancelled))
    await failure(.staleTicket) {
      try await h.lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    }
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.clock.now = 100_000_000
    h.timers.fireDue(at: 100_000_000)
    try await h.barrier(ticket)
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    h.connection.release.open()
    // Shutdown is also an explicit close-acknowledgment gate; it must not return before closure.
    let shutdown = await h.lifecycle.shutdown()
    XCTAssertTrue(shutdown.stopped)
    XCTAssertEqual(h.system.signals.count, 1)
  }

  func testReapAndCloseEnableNewGenerationWithoutShutdown() async throws {
    let h = try Harness(maximum: 1)
    let first = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    h.system.poll = .reaped(.signaled(SIGKILL))
    let second = try await h.lifecycle.begin(requestID: UUID())
    XCTAssertNotEqual(first.identity.generation, second.identity.generation)
    XCTAssertEqual(second.identity.ordinal, 1)
    XCTAssertEqual(h.system.launches.count, 1)
    await h.connection.started.wait()
    h.connection.release.open()
    await h.system.waitForLaunchCount(2)
    XCTAssertEqual(h.system.launches[1], second.identity.generation)
    await failure(.staleTicket) { try await h.lifecycle.cancel(first) }
    XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
    await h.dispose()
  }

  func testHealthyReuseIncrementsOrdinalAndCompletionCanReenter() async throws {
    let h = try Harness()
    let first = try await h.ready()
    let refused = Gate()
    func observeAndReenter() async throws -> SearchChildTicket? {
      do {
        let result = try await h.lifecycle.wait(for: first)
        XCTAssertEqual(result, .completed(.success))
        return try await h.lifecycle.begin(requestID: UUID())
      } catch SearchChildFailure.observerBusy {
        refused.open()
        return nil
      }
    }
    let observerA = Task { try await observeAndReenter() }
    let observerB = Task { try await observeAndReenter() }
    await refused.wait()  // The other continuation is now installed before completion.
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    let tickets = try await [observerA.value, observerB.value].compactMap { $0 }
    XCTAssertEqual(tickets.count, 1)
    let second = try XCTUnwrap(tickets.first)
    XCTAssertEqual(second.identity.generation, first.identity.generation)
    XCTAssertEqual(second.identity.ordinal, 2)
    XCTAssertEqual(h.system.launches.count, 1)
    await h.dispose()
  }

  func testDeadlineBeforeLateLaunchStopsOnlyTheLateOwnedPID() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    h.clock.now = 1_000_000_000
    h.timers.fireDue(at: 1_000_000_000)
    try await h.barrier(ticket)
    let result = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(result, .failed(.deadline))
    h.system.deliver(ticket, pid: 73, connection: h.connection)
    try await h.barrier(ticket)
    XCTAssertEqual(h.system.signals, [.init(pid: 73, signal: SIGKILL)])
    await failure(.staleTicket) {
      try await h.lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    }
    await h.dispose()
  }

  func testTerminalBeforeExactlyAtAndAfterDeadline() async throws {
    for time: UInt64 in [999_999_999, 1_000_000_000, 1_000_000_001] {
      let h = try Harness()
      let ticket = try await h.ready()
      h.clock.now = time
      if time < 1_000_000_000 {
        try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
      } else {
        await failure(.deadline) {
          try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
        }
      }
      let result = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(result, time < 1_000_000_000 ? .completed(.success) : .failed(.deadline))
      XCTAssertEqual(h.system.signals.count, time < 1_000_000_000 ? 0 : 1)
      await h.dispose()
    }
  }

  func testDeadlineAfterLaunchAndEarlyTimerDelivery() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    let deadline = try XCTUnwrap(h.timers.last(at: 1_000_000_000))
    deadline.forceFire()
    try await h.barrier(ticket)
    XCTAssertTrue(h.system.signals.isEmpty)
    h.clock.now = 1_000_000_000
    deadline.forceFire()
    try await h.barrier(ticket)
    XCTAssertEqual(h.system.signals.count, 1)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.deadline))
    await h.dispose()
  }

  func testCancelBeforeTerminalAndRepeatedCancelCannotChangeOutcome() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    try await h.lifecycle.cancel(ticket)
    await failure(.staleTicket) { try await h.lifecycle.cancel(ticket) }
    await failure(.staleTicket) { try await h.lifecycle.acceptedTerminal(.success, ticket: ticket) }
    let result = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(result, .failed(.cancelled))
    XCTAssertEqual(h.system.signals.count, 1)
    await h.dispose()
  }

  func testOldOperationAndMaintenanceTimersCannotAffectNextOperation() async throws {
    let h = try Harness()
    let first = try await h.ready()
    let oldDeadline = try XCTUnwrap(h.timers.last(at: 1_000_000_000))
    let oldPoll = try XCTUnwrap(h.timers.last(at: 100_000_000))
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    await failure(.staleTicket) { try await h.lifecycle.cancel(first) }
    h.clock.now = 1
    let second = try await h.lifecycle.begin(requestID: UUID())
    h.clock.now = 1_000_000_000
    oldDeadline.forceFire()
    oldPoll.forceFire()
    try await h.barrier(second)
    try await h.lifecycle.acceptedTerminal(.success, ticket: second)
    let result = try await h.lifecycle.wait(for: second)
    XCTAssertEqual(result, .completed(.success))
    XCTAssertTrue(h.system.signals.isEmpty)
    await h.dispose()
  }

  func testStaleGenerationCallbacksCannotSignalAReusedPID() async throws {
    let h = try Harness(maximum: 1)
    let first = try await h.ready()
    let oldDeadline = try XCTUnwrap(h.timers.last(at: 1_000_000_000))
    let oldPoll = try XCTUnwrap(h.timers.last(at: 100_000_000))
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    h.clock.now = 1
    h.system.poll = .reaped(.signaled(SIGKILL))
    let second = try await h.lifecycle.begin(requestID: UUID())
    h.connection.release.open()
    await h.system.waitForLaunchCount(2)
    h.system.poll = .running
    let freshConnection = HeldCloseConnection()
    freshConnection.release.open()
    h.system.deliver(second, pid: 41, connection: freshConnection)
    _ = try await h.lifecycle.connection(for: second)
    try await h.lifecycle.acceptedHandshake(generation: second.identity.generation)
    h.clock.now = 1_000_000_000
    oldDeadline.forceFire()
    oldPoll.forceFire()
    await h.lifecycle.rejectedProtocol(generation: first.identity.generation)
    try await h.lifecycle.acceptedTerminal(.success, ticket: second)
    XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
    let result = try await h.lifecycle.wait(for: second)
    XCTAssertEqual(result, .completed(.success))
    await h.dispose()
  }

  func testWrongTicketCannotCancelConnectInspectOrCompleteCurrentOperation() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    for identity in [
      try SearchWireIdentity(generation: UUID(), requestID: ticket.identity.requestID, ordinal: 1),
      try SearchWireIdentity(generation: ticket.identity.generation, requestID: UUID(), ordinal: 1),
      try SearchWireIdentity(
        generation: ticket.identity.generation, requestID: ticket.identity.requestID, ordinal: 2),
    ] {
      let wrong = SearchChildTicket(identity: identity)
      await failure(.staleTicket) { try await h.lifecycle.cancel(wrong) }
      await failure(.staleTicket) { _ = try await h.lifecycle.connection(for: wrong) }
      await failure(.staleTicket) { _ = try await h.lifecycle.cleanup(for: wrong) }
      await failure(.staleTicket) { _ = try await h.lifecycle.wait(for: wrong) }
      await failure(.staleTicket) {
        try await h.lifecycle.acceptedTerminal(.success, ticket: wrong)
      }
    }
    XCTAssertTrue(h.system.signals.isEmpty)
    await h.dispose()
  }

  func testAlreadyCancelledObserversDoNotInstallOrCancelOperation() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let gate = Gate()
    let waiter = Task {
      await gate.wait()
      return await caught { _ = try await h.lifecycle.wait(for: ticket) }
    }
    let connector = Task {
      await gate.wait()
      return await caught { _ = try await h.lifecycle.connection(for: ticket) }
    }
    waiter.cancel()
    connector.cancel()
    gate.open()
    let waitError = await waiter.value
    let connectError = await connector.value
    XCTAssertTrue(waitError is CancellationError)
    XCTAssertTrue(connectError is CancellationError)
    XCTAssertTrue(h.system.signals.isEmpty)
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    await h.dispose()
  }

  func testSecondWaitObserverRefusedAndInstalledObserverCancellationDetaches() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let refused = Gate()
    func observe() async -> Error? {
      let error = await caught { _ = try await h.lifecycle.wait(for: ticket) }
      if error as? SearchChildFailure == .observerBusy { refused.open() }
      return error
    }
    let first = Task { await observe() }
    let second = Task { await observe() }
    await refused.wait()  // Proves one observer is installed and the other was refused.
    first.cancel()
    second.cancel()
    let errors = await [first.value, second.value]
    XCTAssertEqual(errors.filter { $0 as? SearchChildFailure == .observerBusy }.count, 1)
    XCTAssertEqual(errors.filter { $0 is CancellationError }.count, 1)
    try await h.lifecycle.cancel(ticket)
    let result = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(result, .failed(.cancelled))
    await h.dispose()
  }

  func testSecondConnectionObserverRefusedAndCancellationDetaches() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let refused = Gate()
    func observe() async -> Error? {
      let error = await caught { _ = try await h.lifecycle.connection(for: ticket) }
      if error as? SearchChildFailure == .observerBusy { refused.open() }
      return error
    }
    let first = Task { await observe() }
    let second = Task { await observe() }
    await refused.wait()
    first.cancel()
    second.cancel()
    let errors = await [first.value, second.value]
    XCTAssertEqual(errors.filter { $0 as? SearchChildFailure == .observerBusy }.count, 1)
    XCTAssertEqual(errors.filter { $0 is CancellationError }.count, 1)
    h.system.deliver(ticket, pid: 41, connection: h.connection)
    let connected = try await h.lifecycle.connection(for: ticket)
    XCTAssertTrue(connected === h.connection)
    XCTAssertTrue(h.system.signals.isEmpty)
    await h.dispose()
  }

  func testRunningInterruptedAndECHILDQuarantineThenContinueBoundedPolling() async throws {
    for status in [SearchChildPoll.running, .interrupted, .failed(ECHILD)] {
      let h = try Harness(maximum: 1)
      let first = try await h.ready()
      try await h.lifecycle.acceptedTerminal(.success, ticket: first)
      let second = try await h.lifecycle.begin(requestID: UUID())
      await h.connection.started.wait()
      h.connection.release.open()
      h.system.poll = status
      h.clock.now = 100_000_000
      h.timers.fireDue(at: 100_000_000)
      try await h.barrier(second)
      let cleanup = try await h.lifecycle.cleanup(for: first)
      XCTAssertEqual(cleanup, .stopUnconfirmed(generation: first.identity.generation))
      XCTAssertEqual(h.system.launches.count, 1)
      XCTAssertEqual(h.timers.activeCount, 2)  // One operation deadline plus one child poll.
      await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
      h.system.poll = .reaped(.signaled(SIGKILL))
      h.clock.now = 200_000_000
      h.timers.fireDue(at: 200_000_000)
      await h.system.waitForLaunchCount(2)
      XCTAssertEqual(h.system.signals.count, 1)
      await h.dispose()
    }
  }

  func testCancelledRecycleReceiptTracksOldChildThroughReapAndClose() async throws {
    try await verifyRetiredChildReceipt(deadline: false)
  }

  func testExpiredRecycleReceiptTracksOldChildThroughReapAndClose() async throws {
    try await verifyRetiredChildReceipt(deadline: true)
  }

  private func verifyRetiredChildReceipt(deadline: Bool) async throws {
    let h = try Harness(maximum: 1)
    let first = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    let second = try await h.lifecycle.begin(requestID: UUID())
    if deadline {
      h.clock.now = 1_000_000_000
      h.timers.fireDue(at: 1_000_000_000)
      try await h.barrier(second)
    } else {
      try await h.lifecycle.cancel(second)
    }
    let outcome = try await h.lifecycle.wait(for: second)
    XCTAssertEqual(outcome, .failed(deadline ? .deadline : .cancelled))
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.clock.now += 100_000_000
    h.timers.fireDue(at: h.clock.now)
    try await h.barrier(second)
    let reaped = SearchChildCleanup.reaped(
      generation: first.identity.generation, exit: .signaled(SIGKILL))
    let beforeClose = try await h.lifecycle.cleanup(for: second)
    XCTAssertEqual(beforeClose, reaped)
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    h.connection.release.open()
    let shutdown = await h.lifecycle.shutdown()
    XCTAssertTrue(shutdown.stopped)
    let afterClose = try await h.lifecycle.cleanup(for: second)
    XCTAssertEqual(afterClose, reaped)
    XCTAssertEqual(h.system.launches.count, 1)
  }

  func testTinyGraceQuarantinesPromptlyThenUsesLowRateBackgroundPolling() async throws {
    let h = try Harness(grace: 1)
    let ticket = try await h.ready()
    try await h.lifecycle.cancel(ticket)
    h.clock.now = 1
    h.timers.fireDue(at: 1)
    try await h.barrier(ticket)
    let cleanup = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(cleanup, .stopUnconfirmed(generation: ticket.identity.generation))
    XCTAssertEqual(h.timers.activeCount, 1)
    XCTAssertEqual(h.timers.activeDeadlines, [100_000_001])
    h.clock.now = 100_000_001
    h.timers.fireDue(at: 100_000_001)
    try await h.barrier(ticket)
    XCTAssertEqual(h.timers.activeCount, 1)
    XCTAssertEqual(h.timers.activeDeadlines, [200_000_001])
    XCTAssertEqual(h.system.signals.count, 1)
    await h.dispose()
  }

  func testIdleExpiryRequestsStopWithoutAnotherBegin() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    h.clock.now = 2_000_000_000
    h.timers.fireDue(at: 2_000_000_000)
    try await h.barrier(ticket)
    XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .completed(.success))
    await h.dispose()
  }

  func testIdleExitPreservesAcceptedTerminalAndNeverSignalsReapedPID() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    h.system.poll = .reaped(.exited(17))
    h.clock.now = 100_000_000
    h.timers.fireDue(at: 100_000_000)
    try await h.barrier(ticket)
    await h.connection.started.wait()
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .completed(.success))
    XCTAssertTrue(h.system.signals.isEmpty)
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    h.connection.release.open()
    let shutdown = await h.lifecycle.shutdown()
    XCTAssertTrue(shutdown.stopped)
    XCTAssertTrue(h.system.signals.isEmpty)
  }

  func testExitBeforeTerminalRejectsSuccessAndDoesNotSignal() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    h.system.poll = .reaped(.exited(17))
    await failure(.unexpectedExit) {
      try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    }
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.unexpectedExit))
    XCTAssertTrue(h.system.signals.isEmpty)
    await h.dispose()
  }

  func testActiveExitPollFailsOperationWithoutWaitingForDeadline() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    h.system.poll = .reaped(.exited(17))
    h.clock.now = 100_000_000
    h.timers.fireDue(at: 100_000_000)
    try await h.barrier(ticket)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.unexpectedExit))
    XCTAssertTrue(h.system.signals.isEmpty)
    await h.dispose()
  }

  func testHandshakeRequiredAndProtocolRejectionWinsOnce() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    h.system.deliver(ticket, pid: 41, connection: h.connection)
    _ = try await h.lifecycle.connection(for: ticket)
    await failure(.handshakeFailure) {
      try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    }
    await h.lifecycle.rejectedProtocol(generation: UUID())
    XCTAssertTrue(h.system.signals.isEmpty)
    await h.lifecycle.rejectedProtocol(generation: ticket.identity.generation)
    await h.lifecycle.rejectedProtocol(generation: ticket.identity.generation)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.protocolFailure))
    XCTAssertEqual(h.system.signals.count, 1)
    await h.dispose()
  }

  func testShutdownWaitsForBothLatchesAndRepeatedCallInspectsSameState() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    h.system.poll = .reaped(.signaled(SIGKILL))
    let task = Task { await h.lifecycle.shutdown() }
    await h.connection.started.wait()
    let interim = await h.lifecycle.shutdown()
    XCTAssertFalse(interim.stopped)
    XCTAssertFalse(interim.channelsClosed)
    XCTAssertEqual(
      interim.cleanup, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    h.connection.release.open()
    let result = await task.value
    XCTAssertTrue(result.stopped)
    XCTAssertEqual(result.cleanup, .noChild)
    let count = h.timers.count
    let repeated = await h.lifecycle.shutdown()
    XCTAssertEqual(repeated, result)
    XCTAssertEqual(h.timers.count, count)
    await failure(.shutDown) { _ = try await h.lifecycle.begin(requestID: UUID()) }
  }

  func testSuccessfulSignalThenExitZeroRetainsOwnershipUntilCloseAcknowledgment() async throws {
    try await assertSuccessfulSignalShutdown(exit: .exited(0))
  }

  func testSuccessfulSignalThenSignalNineRetainsOwnershipUntilCloseAcknowledgment() async throws {
    try await assertSuccessfulSignalShutdown(exit: .signaled(SIGKILL))
  }

  private func assertSuccessfulSignalShutdown(exit: SearchChildExit) async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock()
    let timers = ScriptedTimers()
    let signalsAtClose = Locked<[ScriptedSystem.Signal]?>(nil)
    let connection = HeldCloseConnection {
      signalsAtClose.withValue { $0 = system.signals }
    }
    let lifecycle = try makeLifecycle(system, clock, timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliver(ticket, pid: 41, connection: connection)
    _ = try await lifecycle.connection(for: ticket)
    try await lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    let pollsBeforeShutdown = system.polledPIDs.count
    system.poll = .reaped(exit)

    let task = Task { await lifecycle.shutdown() }
    await connection.started.wait()
    let held = await lifecycle.shutdown()
    let expectedSignal = [ScriptedSystem.Signal(pid: 41, signal: SIGKILL)]
    XCTAssertEqual(signalsAtClose.withValue { $0 }, expectedSignal)
    XCTAssertEqual(system.signals, expectedSignal)
    XCTAssertEqual(Array(system.polledPIDs.dropFirst(pollsBeforeShutdown)), [41])
    XCTAssertEqual(connection.closeCalls, 1)
    XCTAssertFalse(held.stopped)
    XCTAssertFalse(held.channelsClosed)
    XCTAssertEqual(held.cleanup, .reaped(generation: ticket.identity.generation, exit: exit))

    // Repeated inspection cannot retire an owned child with its close acknowledgment held.
    let heldAgain = await lifecycle.shutdown()
    XCTAssertEqual(heldAgain, held)
    connection.release.open()
    let settled = await task.value
    XCTAssertTrue(settled.stopped)
    XCTAssertTrue(settled.channelsClosed)
    XCTAssertEqual(settled.cleanup, .noChild)
    let repeated = await lifecycle.shutdown()
    XCTAssertEqual(repeated, settled)
    XCTAssertEqual(system.signals, expectedSignal)
    XCTAssertEqual(Array(system.polledPIDs.dropFirst(pollsBeforeShutdown)), [41])
    XCTAssertEqual(connection.closeCalls, 1)
    let receipt = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(receipt, .reaped(generation: ticket.identity.generation, exit: exit))
  }

  func testShutdownGraceIsNotRestartedForHeldLaunch() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let task = Task { await h.lifecycle.shutdown() }
    await h.timers.waitForDeadline(100_000_000)
    h.clock.now = 100_000_000
    h.timers.fireDue(at: 100_000_000)
    let result = await task.value
    XCTAssertEqual(result.cleanup, .pendingLaunch(generation: ticket.identity.generation))
    XCTAssertFalse(result.stopped)
    XCTAssertFalse(result.channelsClosed)
    let count = h.timers.count
    let repeated = await h.lifecycle.shutdown()
    XCTAssertEqual(repeated, result)
    XCTAssertEqual(h.timers.count, count)
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.system.deliver(ticket, pid: 41, connection: h.connection)
    await h.connection.started.wait()
    let lateChild = await h.lifecycle.shutdown()
    XCTAssertFalse(lateChild.channelsClosed)
    h.connection.release.open()
    await h.dispose()
  }

  func testLaunchFailureCompletesPendingShutdownWithoutGraceTimer() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let task = Task { await h.lifecycle.shutdown() }
    await h.timers.waitForDeadline(100_000_000)
    h.system.failPending()
    let result = await task.value
    XCTAssertTrue(result.stopped)
    let cleanup = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(cleanup, .noChild)
    XCTAssertEqual(h.timers.activeCount, 0)
  }

  func testShutdownUnconfirmedReceiptAndLaterExactReap() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    let task = Task { await h.lifecycle.shutdown() }
    await h.connection.started.wait()
    // Launch poll, stop poll, shutdown grace.
    await h.timers.waitForCount(at: 100_000_000, count: 3)
    h.system.poll = .failed(ECHILD)
    h.clock.now = 100_000_000
    h.timers.fireDue(at: 100_000_000)
    let result = await task.value
    XCTAssertFalse(result.stopped)
    XCTAssertEqual(result.cleanup, .stopUnconfirmed(generation: ticket.identity.generation))
    XCTAssertFalse(result.channelsClosed)
    XCTAssertEqual(h.timers.activeCount, 1)
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.clock.now = 200_000_000
    h.timers.fireDue(at: 200_000_000)
    try await h.barrier(ticket)
    let reaped = await h.lifecycle.shutdown()
    XCTAssertFalse(reaped.stopped)
    XCTAssertEqual(
      reaped.cleanup, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    h.connection.release.open()
    XCTAssertEqual(h.system.signals.count, 1)
  }

  func testFacadeLossDuringPendingLaunchRetainsStopAndReapOwnership() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock()
    let timers = ScriptedTimers()
    let connection = HeldCloseConnection()
    var lifecycle: SearchChildLifecycle? = try makeLifecycle(system, clock, timers)
    weak let facade = lifecycle
    let ticket = try await lifecycle!.begin(requestID: UUID())
    lifecycle = nil
    XCTAssertNil(facade)
    system.poll = .reaped(.signaled(SIGKILL))
    system.deliver(ticket, pid: 51, connection: connection)
    await connection.started.wait()
    XCTAssertEqual(system.signals, [.init(pid: 51, signal: SIGKILL)])
    connection.release.open()
  }

  func testFacadeLossWhileIdleStopsTheOwnedChild() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock()
    let timers = ScriptedTimers()
    let connection = HeldCloseConnection()
    var lifecycle: SearchChildLifecycle? = try makeLifecycle(system, clock, timers)
    let ticket = try await lifecycle!.begin(requestID: UUID())
    system.deliver(ticket, pid: 51, connection: connection)
    _ = try await lifecycle!.connection(for: ticket)
    try await lifecycle!.acceptedHandshake(generation: ticket.identity.generation)
    try await lifecycle!.acceptedTerminal(.success, ticket: ticket)
    system.poll = .reaped(.signaled(SIGKILL))
    lifecycle = nil
    await connection.started.wait()
    XCTAssertEqual(system.signals, [.init(pid: 51, signal: SIGKILL)])
    connection.release.open()
  }

  func testInvalidRequestAndConstructorHaveNoAdmissionSideEffects() async throws {
    let h = try Harness()
    for url in [
      URL(string: "https://example.invalid/helper")!, URL(string: "file:///synthetic/%00helper")!,
      URL(string: "file:relative")!,
    ] {
      XCTAssertThrowsError(try makeLifecycle(h.system, h.clock, h.timers, executable: url)) {
        XCTAssertEqual($0 as? SearchChildFailure, .invalidExecutable)
      }
    }
    await failure(.invalidRequestID) {
      _ = try await h.lifecycle.begin(requestID: SearchWireBinary.zeroUUID)
    }
    XCTAssertEqual(h.timers.count, 0)
    XCTAssertTrue(h.system.launches.isEmpty)
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let deadlines = h.timers.count
    await failure(.invalidRequestID) {
      _ = try await h.lifecycle.begin(requestID: SearchWireBinary.zeroUUID)
    }
    XCTAssertEqual(h.timers.count, deadlines)
    XCTAssertEqual(h.system.launches.count, 1)
    let cleanup = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(cleanup, .pendingLaunch(generation: ticket.identity.generation))
    await h.dispose()
  }

  func testInvalidPolicyAndAdmissionOverflowAreRefused() async throws {
    for values: (UInt64, UInt64, UInt64, UInt32) in [
      (0, 1, 1, 1), (1, 0, 1, 1), (1, 1, 0, 1), (1, 1, 1, 0),
      (60_000_000_001, 1, 1, 1), (1, 5_000_000_001, 1, 1), (1, 1, 60_000_000_001, 1),
    ] {
      XCTAssertThrowsError(
        try SearchChildPolicy(
          operationNanoseconds: values.0,
          reapGraceNanoseconds: values.1, idleNanoseconds: values.2,
          maximumRequestsPerChild: values.3))
    }
    let h = try Harness()
    h.clock.now = UInt64.max - 999_999_999
    await failure(.invalidPolicy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    XCTAssertEqual(h.timers.count, 0)
    XCTAssertTrue(h.system.launches.isEmpty)
    await h.dispose()
  }

  func testOverflowDuringStopStillSignalsOwnedPID() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    h.clock.now = UInt64.max
    h.system.poll = .reaped(.signaled(SIGKILL))
    try await h.lifecycle.cancel(ticket)
    XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
    await h.dispose()
  }

  func testInlineTimerAndLaunchCallbacksCannotOvertakeAdmission() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock()
    let timers = ScriptedTimers()
    timers.inline = true
    system.inlineFailure = true
    let lifecycle = try makeLifecycle(system, clock, timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.launchFailed(ENOENT)))
    let cleanup = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(cleanup, .noChild)
    XCTAssertEqual(timers.activeCount, 0)
    let shutdown = await lifecycle.shutdown()
    XCTAssertTrue(shutdown.stopped)
  }

  private func failure(_ expected: SearchChildFailure, operation: () async throws -> Void) async {
    let error = await caught(operation)
    XCTAssertEqual(error as? SearchChildFailure, expected)
  }
}

private func caught(_ operation: () async throws -> Void) async -> Error? {
  do {
    try await operation()
    return nil
  } catch { return error }
}

private func makeLifecycle(
  _ system: ScriptedSystem, _ clock: ScriptedClock, _ timers: ScriptedTimers,
  maximum: UInt32 = 2, grace: UInt64 = 100_000_000,
  executable: URL = URL(fileURLWithPath: "/synthetic/search-child")
) throws -> SearchChildLifecycle {
  try SearchChildLifecycle(
    executable: executable,
    policy: .init(
      operationNanoseconds: 1_000_000_000, reapGraceNanoseconds: grace,
      idleNanoseconds: 2_000_000_000, maximumRequestsPerChild: maximum),
    system: system, now: { clock.now }, schedule: { timers.schedule($0, event: $1) })
}

private struct Harness {
  let system = ScriptedSystem()
  let clock = ScriptedClock()
  let timers = ScriptedTimers()
  let connection = HeldCloseConnection()
  let lifecycle: SearchChildLifecycle

  init(maximum: UInt32 = 2, grace: UInt64 = 100_000_000) throws {
    lifecycle = try makeLifecycle(system, clock, timers, maximum: maximum, grace: grace)
  }

  func ready() async throws -> SearchChildTicket {
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliver(ticket, pid: 41, connection: connection)
    _ = try await lifecycle.connection(for: ticket)
    try await lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    return ticket
  }

  // Seam callbacks enqueue synchronously on control. A subsequent public inspection is
  // an actual FIFO barrier for those callbacks, unlike Task.yield or elapsed wall time.
  func barrier(_ ticket: SearchChildTicket) async throws {
    _ = try await lifecycle.cleanup(for: ticket)
  }

  func dispose() async {
    system.poll = .reaped(.signaled(SIGKILL))
    connection.release.open()
    system.failPending()
    clock.now = clock.now > UInt64.max - 100_000_000 ? UInt64.max : clock.now + 100_000_000
    timers.fireDue(at: clock.now)
    _ = await lifecycle.shutdown()
  }
}

private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withValue<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

/// Explicit one-shot gate. Opening before installation is supported and every continuation
/// is removed under the lock, then resumed outside it. No polling, sleeps, or yield barriers.
private final class Gate: @unchecked Sendable {
  private struct State {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Locked(State())
  func wait() async {
    await withCheckedContinuation { continuation in
      let immediate = state.withValue { state in
        if state.opened { return true }
        state.waiters.append(continuation)
        return false
      }
      if immediate { continuation.resume() }
    }
  }
  func open() {
    let waiters = state.withValue { state in
      state.opened = true
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}

private final class ScriptedClock: @unchecked Sendable {
  private let storage = Locked<UInt64>(0)
  var now: UInt64 {
    get { storage.withValue { $0 } }
    set { storage.withValue { $0 = newValue } }
  }
}

private final class ScriptedTimer: SearchChildTimer, @unchecked Sendable {
  let deadline: UInt64
  private let event: @Sendable () -> Void
  private let active = Locked(true)
  var isActive: Bool { active.withValue { $0 } }
  init(_ deadline: UInt64, event: @escaping @Sendable () -> Void) {
    self.deadline = deadline
    self.event = event
  }
  func cancel() { active.withValue { $0 = false } }
  func fire() {
    let shouldFire = active.withValue { value in
      let previous = value
      value = false
      return previous
    }
    if shouldFire { event() }
  }
  func forceFire() { event() }
}

private final class ScriptedTimers: @unchecked Sendable {
  private struct State {
    var timers: [ScriptedTimer] = []
    var watchers: [(UInt64, Int, Gate)] = []
    var inline = false
  }
  private let state = Locked(State())
  var inline: Bool {
    get { state.withValue { $0.inline } }
    set { state.withValue { $0.inline = newValue } }
  }
  var count: Int { state.withValue { $0.timers.count } }
  var activeDeadlines: [UInt64] { state.withValue { $0.timers.filter(\.isActive).map(\.deadline) } }
  var activeCount: Int { state.withValue { $0.timers.filter(\.isActive).count } }
  func last(at deadline: UInt64) -> ScriptedTimer? {
    state.withValue { $0.timers.last { $0.deadline == deadline } }
  }
  func schedule(_ deadline: UInt64, event: @escaping @Sendable () -> Void) -> any SearchChildTimer {
    let timer = ScriptedTimer(deadline, event: event)
    let result = state.withValue { state in
      state.timers.append(timer)
      let ready = state.watchers.filter { watch in
        state.timers.filter { $0.deadline == watch.0 }.count >= watch.1
      }
      state.watchers.removeAll { watch in ready.contains { $0.2 === watch.2 } }
      return (ready.map { $0.2 }, state.inline)
    }
    for gate in result.0 { gate.open() }
    if result.1 { timer.forceFire() }
    return timer
  }
  func fireDue(at now: UInt64) {
    let timers = state.withValue { $0.timers.filter { $0.deadline <= now } }
    for timer in timers { timer.fire() }
  }
  func waitForDeadline(_ deadline: UInt64) async { await waitForCount(at: deadline, count: 1) }
  func waitForCount(at deadline: UInt64, count: Int) async {
    let gate = Gate()
    let ready = state.withValue { state in
      if state.timers.filter({ $0.deadline == deadline }).count >= count { return true }
      state.watchers.append((deadline, count, gate))
      return false
    }
    if ready { gate.open() }
    await gate.wait()
  }
}

private final class ScriptedSystem: SearchChildSystem, @unchecked Sendable {
  struct Signal: Equatable {
    let pid: Int32
    let signal: Int32
  }
  private struct Launch {
    let generation: UUID
    var completion: (@Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void)?
  }
  private struct State {
    var launches: [Launch] = []
    var signals: [Signal] = []
    var polledPIDs: [Int32] = []
    var pollWatchers: [(Int, Gate)] = []
    var poll: SearchChildPoll = .running
    var watchers: [(Int, Gate)] = []
    var inlineFailure = false
  }
  private let state = Locked(State())
  var launches: [UUID] { state.withValue { $0.launches.map(\.generation) } }
  var signals: [Signal] { state.withValue { $0.signals } }
  var polledPIDs: [Int32] { state.withValue { $0.polledPIDs } }
  var poll: SearchChildPoll {
    get { state.withValue { $0.poll } }
    set { state.withValue { $0.poll = newValue } }
  }
  var inlineFailure: Bool {
    get { state.withValue { $0.inlineFailure } }
    set { state.withValue { $0.inlineFailure = newValue } }
  }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    let result = state.withValue { state in
      state.launches.append(
        Launch(generation: generation, completion: state.inlineFailure ? nil : completion))
      let ready = state.watchers.filter { $0.0 <= state.launches.count }
      state.watchers.removeAll { $0.0 <= state.launches.count }
      return (ready.map { $0.1 }, state.inlineFailure)
    }
    for gate in result.0 { gate.open() }
    if result.1 { completion(.failure(.launchFailed(ENOENT))) }
  }
  func signal(pid: Int32, signal: Int32) -> Int32 {
    state.withValue { $0.signals.append(Signal(pid: pid, signal: signal)) }
    return 0
  }
  func pollExit(pid: Int32) -> SearchChildPoll {
    let result = state.withValue { state in
      precondition(state.polledPIDs.count < 256, "Injected poll log overflow")
      state.polledPIDs.append(pid)
      let ready = state.pollWatchers.filter { $0.0 <= state.polledPIDs.count }
      state.pollWatchers.removeAll { item in ready.contains { $0.1 === item.1 } }
      return (state.poll, ready.map { $0.1 })
    }
    for gate in result.1 { gate.open() }
    return result.0
  }
  func waitForPollCount(_ count: Int) async {
    let gate = Gate()
    let ready = state.withValue { state in
      if state.polledPIDs.count >= count { return true }
      state.pollWatchers.append((count, gate))
      return false
    }
    if ready { gate.open() }
    await gate.wait()
  }
  func deliver(
    _ ticket: SearchChildTicket, pid: Int32, connection: any SearchChildConnection,
    startupFailure: SearchChildFailure? = nil
  ) {
    let completion = state.withValue { state in
      guard
        let index = state.launches.firstIndex(where: { $0.generation == ticket.identity.generation }
        )
      else { return nil as (@Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void)? }
      let callback = state.launches[index].completion
      state.launches[index].completion = nil
      return callback
    }
    completion?(.success(.init(pid: pid, connection: connection, startupFailure: startupFailure)))
  }
  func failPending() {
    let callbacks = state.withValue { state in
      let callbacks = state.launches.compactMap(\.completion)
      for index in state.launches.indices { state.launches[index].completion = nil }
      return callbacks
    }
    for callback in callbacks { callback(.failure(.launchFailed(ENOENT))) }
  }
  func waitForLaunchCount(_ count: Int) async {
    let gate = Gate()
    let ready = state.withValue { state in
      if state.launches.count >= count { return true }
      state.watchers.append((count, gate))
      return false
    }
    if ready { gate.open() }
    await gate.wait()
  }
}

private final class HeldCloseConnection: SearchChildConnection, Sendable {
  let started = Gate()
  let release = Gate()
  private let calls = Locked(0)
  private let onClose: @Sendable () -> Void
  init(onClose: @escaping @Sendable () -> Void = {}) { self.onClose = onClose }
  var closeCalls: Int { calls.withValue { $0 } }
  func write(_ bytes: Data) async throws {}
  func read(maxBytes: Int) async throws -> Data { Data() }
  func close() async {
    calls.withValue { $0 += 1 }
    onClose()
    started.open()
    await release.wait()
  }
}

extension SearchChildLifecycleTests {
  func testChannelEOFBeforeHandshakeReportsHandshakeFailure() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    h.system.deliver(ticket, pid: 41, connection: h.connection)
    _ = try await h.lifecycle.connection(for: ticket)
    await h.lifecycle.rejectedChannel(.endOfFile, generation: ticket.identity.generation)
    // RED backstop: a missing decision produces cancellation instead of hanging.
    try? await h.lifecycle.cancel(ticket)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.handshakeFailure))
    await h.dispose()
  }

  func testChannelErrorPreservesCapturedErrnoInBothHandshakePhases() async throws {
    for accepted in [false, true] {
      let h = try Harness()
      let ticket = try await h.lifecycle.begin(requestID: UUID())
      h.system.deliver(ticket, pid: 41, connection: h.connection)
      _ = try await h.lifecycle.connection(for: ticket)
      if accepted {
        try await h.lifecycle.acceptedHandshake(generation: ticket.identity.generation)
      }
      await h.lifecycle.rejectedChannel(.failure(EPIPE), generation: ticket.identity.generation)
      try? await h.lifecycle.cancel(ticket)
      let outcome = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .failed(.channelFailure(EPIPE)))
      await h.dispose()
    }
  }

  func testChannelEOFReadyRequestStopsButKeepsPhysicalSlotUntilCloseAndReap() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    await h.lifecycle.rejectedChannel(.endOfFile, generation: ticket.identity.generation)
    try? await h.lifecycle.cancel(ticket)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.unexpectedExit))
    XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    await h.connection.started.wait()
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.clock.now += 100_000_000
    h.timers.fireDue(at: h.clock.now)
    try await h.barrier(ticket)
    let reaped = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(
      reaped, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    h.connection.release.open()
    await h.dispose()
  }

  func testIdleChannelFailurePreservesAcceptedTerminalAndRetiresGeneration() async throws {
    for terminal: SearchWireTerminal in [.success, .failure(.invalidPattern)] {
      for observation: SearchChildChannelObservation in [.endOfFile, .failure(EIO)] {
        let h = try Harness()
        let ticket = try await h.ready()
        try await h.lifecycle.acceptedTerminal(terminal, ticket: ticket)
        await h.lifecycle.rejectedChannel(observation, generation: ticket.identity.generation)
        let outcome = try await h.lifecycle.wait(for: ticket)
        XCTAssertEqual(outcome, .completed(terminal))
        XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
        let admission = await caught { _ = try await h.lifecycle.begin(requestID: UUID()) }
        XCTAssertEqual(admission as? SearchChildFailure, .busy)
        await h.dispose()
      }
    }
  }

  func testChannelObservationsDoNotOverwritePriorCancellationOrDeadline() async throws {
    for deadline in [false, true] {
      let h = try Harness()
      let ticket = try await h.ready()
      if deadline {
        h.clock.now = 1_000_000_000
        h.timers.fireDue(at: h.clock.now)
        try await h.barrier(ticket)
      } else {
        try await h.lifecycle.cancel(ticket)
      }
      await h.lifecycle.rejectedChannel(.endOfFile, generation: ticket.identity.generation)
      await h.lifecycle.rejectedChannel(.failure(EIO), generation: ticket.identity.generation)
      let outcome = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .failed(deadline ? .deadline : .cancelled))
      XCTAssertEqual(h.system.signals.count, 1)
      await h.dispose()
    }
  }

  func testForeignChannelObservationCannotAffectCurrentRequest() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    let foreign = UUID()
    await h.lifecycle.rejectedChannel(.endOfFile, generation: foreign)
    await h.lifecycle.rejectedChannel(.failure(EIO), generation: foreign)
    await h.lifecycle.rejectedChannel(.failure(0), generation: foreign)
    await h.lifecycle.rejectedChannel(.failure(-1), generation: foreign)
    XCTAssertTrue(h.system.signals.isEmpty)
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .completed(.success))
    await h.dispose()
  }
}

extension SearchChildLifecycleTests {
  func testInvalidChannelErrnoIsProtocolFailureInsteadOfInventedSystemError() async throws {
    for errno: Int32 in [0, -1] {
      let h = try Harness()
      let ticket = try await h.ready()
      await h.lifecycle.rejectedChannel(.failure(errno), generation: ticket.identity.generation)
      try? await h.lifecycle.cancel(ticket)
      let outcome = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .failed(.protocolFailure))
      await h.dispose()
    }
  }

  func testIdleReadFailureAfterNextAdmissionAppliesToNewTicketOnly() async throws {
    let h = try Harness()
    let first = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    let accepted = try await h.lifecycle.wait(for: first)
    let next = try await h.lifecycle.begin(requestID: UUID())
    XCTAssertEqual(first.identity.generation, next.identity.generation)
    XCTAssertNotEqual(first.identity.requestID, next.identity.requestID)
    await h.lifecycle.rejectedChannel(.endOfFile, generation: next.identity.generation)
    try? await h.lifecycle.cancel(next)
    let failed = try await h.lifecycle.wait(for: next)
    XCTAssertEqual(accepted, .completed(.success))
    XCTAssertEqual(failed, .failed(.unexpectedExit))
    await h.dispose()
  }
}

extension SearchChildLifecycleTests {
  func testOldGenerationChannelObservationCannotFinishReservedOrReplacementRequest() async throws {
    let h = try Harness(maximum: 1)
    let first = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    h.system.poll = .reaped(.signaled(SIGKILL))
    let second = try await h.lifecycle.begin(requestID: UUID())
    XCTAssertNotEqual(first.identity.generation, second.identity.generation)
    await h.connection.started.wait()
    // The old physical child still holds its close receipt while the NEW ticket is reserved.
    await h.lifecycle.rejectedChannel(.failure(EIO), generation: first.identity.generation)
    await h.lifecycle.rejectedChannel(.endOfFile, generation: first.identity.generation)
    h.connection.release.open()
    await h.system.waitForLaunchCount(2)
    let replacement = HeldCloseConnection()
    h.system.poll = .running
    h.system.deliver(second, pid: 73, connection: replacement)
    _ = try await h.lifecycle.connection(for: second)
    try await h.lifecycle.acceptedHandshake(generation: second.identity.generation)
    let signals = h.system.signals
    await h.lifecycle.rejectedChannel(.endOfFile, generation: first.identity.generation)
    await h.lifecycle.rejectedChannel(.failure(-1), generation: first.identity.generation)
    XCTAssertEqual(h.system.signals, signals)
    try await h.lifecycle.acceptedTerminal(.success, ticket: second)
    let outcome = try await h.lifecycle.wait(for: second)
    XCTAssertEqual(outcome, .completed(.success))
    replacement.release.open()
    await h.dispose()
  }
}

extension SearchChildLifecycleTests {
  func testIdleRetirementPreservesSuccessfulAndSemanticReceipts() async throws {
    for terminal: SearchWireTerminal in [.success, .failure(.invalidPattern)] {
      let h = try Harness()
      let ticket = try await h.ready()
      try await h.lifecycle.acceptedTerminal(terminal, ticket: ticket)
      let accepted = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
      XCTAssertTrue(accepted)
      let outcome = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .completed(terminal))
      XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
      let repeated = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
      XCTAssertFalse(repeated)
      XCTAssertEqual(h.system.signals.count, 1)
      await h.dispose()
    }
  }

  func testIdleRetirementRefusesActiveAndPreHandshakeRequests() async throws {
    let h = try Harness()
    let ticket = try await h.lifecycle.begin(requestID: UUID())
    let launching = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
    XCTAssertFalse(launching)
    h.system.deliver(ticket, pid: 41, connection: h.connection)
    _ = try await h.lifecycle.connection(for: ticket)
    let unaccepted = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
    XCTAssertFalse(unaccepted)
    try await h.lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    let active = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
    XCTAssertFalse(active)
    XCTAssertTrue(h.system.signals.isEmpty)
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    let outcome = try await h.lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .completed(.success))
    await h.dispose()
  }

  func testIdleRetirementCannotReplaceChildBeforeReapAndHeldChannelClose() async throws {
    let h = try Harness()
    let ticket = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    let accepted = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
    XCTAssertTrue(accepted)
    // RED cleanup backstop: ensure close starts without requiring missing behavior.
    if !accepted { await h.lifecycle.rejectedProtocol(generation: ticket.identity.generation) }
    await h.connection.started.wait()
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    h.system.poll = .reaped(.signaled(SIGKILL))
    h.clock.now = 100_000_000
    h.timers.fireDue(at: h.clock.now)
    try await h.barrier(ticket)
    let cleanup = try await h.lifecycle.cleanup(for: ticket)
    XCTAssertEqual(
      cleanup, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    await failure(.busy) { _ = try await h.lifecycle.begin(requestID: UUID()) }
    XCTAssertEqual(h.system.launches.count, 1)
    h.connection.release.open()
    let stopped = await h.lifecycle.shutdown()
    XCTAssertTrue(stopped.stopped)
    XCTAssertTrue(stopped.channelsClosed)
  }

  func testIdleRetirementForeignGenerationIsIgnored() async throws {
    let h = try Harness()
    let absent = await h.lifecycle.requestIdleRetirement(generation: UUID())
    XCTAssertFalse(absent)
    let ticket = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
    let foreign = await h.lifecycle.requestIdleRetirement(generation: UUID())
    XCTAssertFalse(foreign)
    XCTAssertTrue(h.system.signals.isEmpty)
    let next = try await h.lifecycle.begin(requestID: UUID())
    XCTAssertEqual(next.identity.generation, ticket.identity.generation)
    await h.dispose()
  }

  func testIdleRetirementCannotAffectCountReservedReplacement() async throws {
    let h = try Harness(maximum: 1)
    let first = try await h.ready()
    try await h.lifecycle.acceptedTerminal(.success, ticket: first)
    h.system.poll = .reaped(.signaled(SIGKILL))
    let next = try await h.lifecycle.begin(requestID: UUID())
    let before = h.system.signals
    let old = await h.lifecycle.requestIdleRetirement(generation: first.identity.generation)
    let reserved = await h.lifecycle.requestIdleRetirement(generation: next.identity.generation)
    XCTAssertFalse(old)
    XCTAssertFalse(reserved)
    XCTAssertEqual(h.system.signals, before)
    h.connection.release.open()
    await h.system.waitForLaunchCount(2)
    XCTAssertEqual(h.system.launches[1], next.identity.generation)
    await h.dispose()
  }

  func testIdleDeadlineAndExplicitRetirementHaveOneStop() async throws {
    for deadlineFirst in [true, false] {
      let h = try Harness()
      let ticket = try await h.ready()
      try await h.lifecycle.acceptedTerminal(.success, ticket: ticket)
      if deadlineFirst {
        h.clock.now = 2_000_000_000
        h.timers.fireDue(at: h.clock.now)
        try await h.barrier(ticket)
      }
      let accepted = await h.lifecycle.requestIdleRetirement(generation: ticket.identity.generation)
      XCTAssertEqual(accepted, !deadlineFirst)
      h.clock.now = 2_000_000_000
      h.timers.fireDue(at: h.clock.now)
      try await h.barrier(ticket)
      XCTAssertEqual(h.system.signals, [.init(pid: 41, signal: SIGKILL)])
      let outcome = try await h.lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .completed(.success))
      await h.dispose()
    }
  }
}
