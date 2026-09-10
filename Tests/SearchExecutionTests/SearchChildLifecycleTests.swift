import Darwin
import Foundation
import XCTest

@testable import SearchExecution

final class SearchChildLifecycleTests: XCTestCase {
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
    var poll: SearchChildPoll = .running
    var watchers: [(Int, Gate)] = []
    var inlineFailure = false
  }
  private let state = Locked(State())
  var launches: [UUID] { state.withValue { $0.launches.map(\.generation) } }
  var signals: [Signal] { state.withValue { $0.signals } }
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
  func pollExit(pid: Int32) -> SearchChildPoll { poll }
  func deliver(_ ticket: SearchChildTicket, pid: Int32, connection: any SearchChildConnection) {
    let completion = state.withValue { state in
      guard
        let index = state.launches.firstIndex(where: { $0.generation == ticket.identity.generation }
        )
      else { return nil as (@Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void)? }
      let callback = state.launches[index].completion
      state.launches[index].completion = nil
      return callback
    }
    completion?(.success(.init(pid: pid, connection: connection)))
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
  func write(_ bytes: Data) async throws {}
  func read(maxBytes: Int) async throws -> Data { Data() }
  func close() async {
    started.open()
    await release.wait()
  }
}
