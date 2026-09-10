import Foundation
import XCTest

@testable import SearchExecution

final class SearchChildLifecycleTests: XCTestCase {
  func testCancelledWaiterDetachesWithoutCancellingOperationAndSecondWaiterIsRefused()
    async throws
  {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 70)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let ticket = try await lifecycle.begin(requestID: UUID())

    let firstWaiter = Task { () -> Error? in
      do {
        _ = try await lifecycle.wait(for: ticket)
        return nil
      } catch {
        return error
      }
    }
    await drainControlEvents()
    await assertThrowsFailure(.observerBusy) {
      _ = try await lifecycle.wait(for: ticket)
    }
    firstWaiter.cancel()
    let detachedError = await firstWaiter.value
    XCTAssertTrue(detachedError is CancellationError)

    let secondWaiter = Task { () -> SearchChildOutcome? in
      try? await lifecycle.wait(for: ticket)
    }
    await drainControlEvents()
    try await lifecycle.cancel(ticket)
    let outcome = await secondWaiter.value
    XCTAssertEqual(outcome, .failed(.cancelled))
    await assertThrowsFailure(.staleTicket) {
      try await lifecycle.cancel(ticket)
    }
  }

  func testReapGraceFailureQuarantinesThePhysicalSlot() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 80)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliverLaunch(
      generation: ticket.identity.generation,
      result: .success(.init(pid: 101, connection: HeldCloseConnection())))
    await drainControlEvents()
    try await lifecycle.cancel(ticket)

    system.poll = .failed(10)  // Simulated ECHILD is not a reap receipt.
    clock.now = 180
    timers.fire(deadline: 180)
    await drainControlEvents()
    let cleanup = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(cleanup, .stopUnconfirmed(generation: ticket.identity.generation))
    await assertThrowsFailure(.busy) {
      _ = try await lifecycle.begin(requestID: UUID())
    }
  }

  func testShutdownWaitsForReapAndCloseBeforeReturningStopped() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 50)
    let timers = ScriptedTimers()
    let connection = HeldCloseConnection()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliverLaunch(
      generation: ticket.identity.generation,
      result: .success(.init(pid: 91, connection: connection)))
    await drainControlEvents()
    system.poll = .reaped(.signaled(9))

    let returned = CompletionFlag()
    let shutdownTask = Task {
      let receipt = await lifecycle.shutdown()
      await returned.markReturned()
      return receipt
    }
    await drainControlEvents()
    let returnedBeforeReap = await returned.value
    XCTAssertFalse(returnedBeforeReap)

    connection.finishClose()
    let receipt = await shutdownTask.value
    XCTAssertTrue(receipt.stopped)
    XCTAssertEqual(receipt.cleanup, .noChild)
  }

  func testShutdownReturnsBoundedUnconfirmedReceiptAfterGraceForHeldLaunch() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 60)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    _ = try await lifecycle.begin(requestID: UUID())

    let returned = CompletionFlag()
    let shutdownTask = Task {
      let receipt = await lifecycle.shutdown()
      await returned.markReturned()
      return receipt
    }
    await drainControlEvents()
    let returnedBeforeGrace = await returned.value
    XCTAssertFalse(returnedBeforeGrace)

    clock.now = 160
    timers.fire(deadline: 160)
    let receipt = await shutdownTask.value
    XCTAssertFalse(receipt.stopped)
    XCTAssertEqual(receipt.cleanup, .pendingLaunch(generation: system.launches[0].generation))
    XCTAssertTrue(receipt.channelsClosed)
  }

  func testZeroRequestIDHasNoAdmissionSideEffects() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 1)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    await assertThrowsFailure(.invalidRequestID) {
      _ = try await lifecycle.begin(requestID: zero)
    }
    XCTAssertTrue(system.launches.isEmpty)
    XCTAssertTrue(timers.deadlines.isEmpty)

    let admitted = try await lifecycle.begin(requestID: UUID())
    await assertThrowsFailure(.invalidRequestID) {
      _ = try await lifecycle.begin(requestID: zero)
    }
    XCTAssertEqual(system.launches.count, 1)
    XCTAssertEqual(timers.deadlines, [1_001])
    let cleanup = try await lifecycle.cleanup(for: admitted)
    XCTAssertEqual(cleanup, .pendingLaunch(generation: admitted.identity.generation))
  }

  func testTerminalAtDeadlineIsCancelledBeforeSuccessCanBeAccepted() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 20)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliverLaunch(
      generation: ticket.identity.generation,
      result: .success(.init(pid: 61, connection: ImmediateCloseConnection())))
    await drainControlEvents()
    try await lifecycle.acceptedHandshake(generation: ticket.identity.generation)

    clock.now = 1_020
    await assertThrowsFailure(.deadline) {
      try await lifecycle.acceptedTerminal(.success, ticket: ticket)
    }
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.deadline))
    XCTAssertEqual(system.signals, [.init(pid: 61, signal: 9)])
  }

  func testMaximumRequestCountReapsBeforeLaunchingFreshGeneration() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 30)
    let timers = ScriptedTimers()
    let connection = HeldCloseConnection()
    let lifecycle = try makeLifecycle(
      system: system, clock: clock, timers: timers, maximumRequestsPerChild: 1)
    let first = try await lifecycle.begin(requestID: UUID())
    system.deliverLaunch(
      generation: first.identity.generation,
      result: .success(.init(pid: 71, connection: connection)))
    await drainControlEvents()
    try await lifecycle.acceptedHandshake(generation: first.identity.generation)
    try await lifecycle.acceptedTerminal(.success, ticket: first)

    system.poll = .reaped(.signaled(9))
    let second = try await lifecycle.begin(requestID: UUID())
    XCTAssertNotEqual(second.identity.generation, first.identity.generation)
    XCTAssertEqual(second.identity.ordinal, 1)
    XCTAssertEqual(system.launches.count, 1)
    XCTAssertEqual(system.signals, [.init(pid: 71, signal: 9)])

    connection.finishClose()
    await drainControlEvents()
    XCTAssertEqual(system.launches.count, 2)
    XCTAssertEqual(system.launches[1].generation, second.identity.generation)
  }

  func testObservedExitRefusesTerminalWithoutSignallingReapedPID() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 40)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliverLaunch(
      generation: ticket.identity.generation,
      result: .success(.init(pid: 81, connection: ImmediateCloseConnection())))
    await drainControlEvents()
    try await lifecycle.acceptedHandshake(generation: ticket.identity.generation)

    system.poll = .reaped(.exited(17))
    await assertThrowsFailure(.unexpectedExit) {
      try await lifecycle.acceptedTerminal(.success, ticket: ticket)
    }
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.unexpectedExit))
    XCTAssertTrue(system.signals.isEmpty)
  }

  func testTerminalRequiresAcceptedHandshakeBeforeCompleting() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 10)
    let timers = ScriptedTimers()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliverLaunch(
      generation: ticket.identity.generation,
      result: .success(.init(pid: 51, connection: ImmediateCloseConnection())))
    await drainControlEvents()

    await assertThrowsFailure(.handshakeFailure) {
      try await lifecycle.acceptedTerminal(.success, ticket: ticket)
    }
    try await lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    try await lifecycle.acceptedTerminal(.success, ticket: ticket)
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .completed(.success))

    let next = try await lifecycle.begin(requestID: UUID())
    XCTAssertEqual(next.identity.generation, ticket.identity.generation)
    XCTAssertEqual(next.identity.ordinal, 2)
  }

  func testCancelledHeldLaunchRetainsSlotUntilExactReapAndChannelClose() async throws {
    let system = ScriptedSystem()
    let clock = ScriptedClock(now: 100)
    let timers = ScriptedTimers()
    let connection = HeldCloseConnection()
    let lifecycle = try makeLifecycle(system: system, clock: clock, timers: timers)
    let requestA = UUID()

    let ticketA = try await lifecycle.begin(requestID: requestA)
    XCTAssertEqual(system.launches.count, 1)
    XCTAssertEqual(timers.deadlines, [1_100])

    try await lifecycle.cancel(ticketA)
    let generationA = ticketA.identity.generation
    system.deliverLaunch(
      generation: generationA,
      result: .success(.init(pid: 41, connection: connection)))
    await drainControlEvents()

    XCTAssertEqual(system.signals, [.init(pid: 41, signal: 9)])
    XCTAssertTrue(connection.closeStarted)
    let cancelledOutcome = try await lifecycle.wait(for: ticketA)
    XCTAssertEqual(cancelledOutcome, .failed(.cancelled))
    await assertThrowsFailure(.staleTicket) {
      try await lifecycle.acceptedHandshake(generation: generationA)
    }
    await assertThrowsFailure(.busy) {
      _ = try await lifecycle.begin(requestID: UUID())
    }

    system.poll = .reaped(.signaled(9))
    clock.now = 200
    timers.fire(deadline: 200)
    await drainControlEvents()
    await assertThrowsFailure(.busy) {
      _ = try await lifecycle.begin(requestID: UUID())
    }

    connection.finishClose()
    await drainControlEvents()
    let ticketB = try await lifecycle.begin(requestID: UUID())
    XCTAssertNotEqual(ticketB.identity.generation, generationA)
    XCTAssertEqual(ticketB.identity.ordinal, 1)
  }

  private func makeLifecycle(
    system: ScriptedSystem,
    clock: ScriptedClock,
    timers: ScriptedTimers,
    maximumRequestsPerChild: UInt32 = 2
  ) throws -> SearchChildLifecycle {
    try SearchChildLifecycle(
      executable: URL(fileURLWithPath: "/synthetic/search-child"),
      policy: .init(
        operationNanoseconds: 1_000,
        reapGraceNanoseconds: 100,
        idleNanoseconds: 1_000,
        maximumRequestsPerChild: maximumRequestsPerChild),
      system: system,
      now: { clock.now },
      schedule: { deadline, event in timers.schedule(deadline: deadline, event: event) })
  }

  private func assertThrowsFailure(
    _ expected: SearchChildFailure,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? SearchChildFailure, expected)
    }
  }

  private func drainControlEvents() async {
    for _ in 0..<256 {
      await Task.yield()
    }
  }
}

private final class ScriptedClock: @unchecked Sendable {
  var now: UInt64

  init(now: UInt64) {
    self.now = now
  }
}

private actor CompletionFlag {
  private var didReturn = false

  var value: Bool { didReturn }

  func markReturned() {
    didReturn = true
  }
}

private final class ScriptedTimer: SearchChildTimer, @unchecked Sendable {
  let deadline: UInt64
  let event: @Sendable () -> Void
  private(set) var cancelled = false

  init(deadline: UInt64, event: @escaping @Sendable () -> Void) {
    self.deadline = deadline
    self.event = event
  }

  func cancel() {
    cancelled = true
  }

  func fire() {
    guard !cancelled else { return }
    event()
  }
}

private final class ScriptedTimers: @unchecked Sendable {
  private(set) var timers = [ScriptedTimer]()

  var deadlines: [UInt64] {
    timers.map(\.deadline)
  }

  func schedule(deadline: UInt64, event: @escaping @Sendable () -> Void) -> any SearchChildTimer {
    let timer = ScriptedTimer(deadline: deadline, event: event)
    timers.append(timer)
    return timer
  }

  func fire(deadline: UInt64) {
    timers.last(where: { $0.deadline == deadline })?.fire()
  }
}

private final class ScriptedSystem: SearchChildSystem, @unchecked Sendable {
  struct Signal: Equatable {
    let pid: Int32
    let signal: Int32
  }

  struct Launch {
    let generation: UUID
    let completion: @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  }

  private(set) var launches = [Launch]()
  private(set) var signals = [Signal]()
  var poll: SearchChildPoll = .running

  func launch(
    executable: URL,
    generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    launches.append(.init(generation: generation, completion: completion))
  }

  func signal(pid: Int32, signal: Int32) -> Int32 {
    signals.append(.init(pid: pid, signal: signal))
    return 0
  }

  func pollExit(pid: Int32) -> SearchChildPoll {
    poll
  }

  func deliverLaunch(
    generation: UUID,
    result: Result<SearchLaunchedChild, SearchChildFailure>
  ) {
    launches.first(where: { $0.generation == generation })?.completion(result)
  }
}

private final class HeldCloseConnection: SearchChildConnection, @unchecked Sendable {
  private var continuation: CheckedContinuation<Void, Never>?
  private var finishRequested = false
  private(set) var closeStarted = false

  func write(_ bytes: Data) async throws {}

  func read(maxBytes: Int) async throws -> Data {
    Data()
  }

  func close() async {
    closeStarted = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      if finishRequested {
        self.continuation = nil
        continuation.resume()
      }
    }
  }

  func finishClose() {
    finishRequested = true
    continuation?.resume()
    continuation = nil
  }
}

private final class ImmediateCloseConnection: SearchChildConnection, @unchecked Sendable {
  func write(_ bytes: Data) async throws {}

  func read(maxBytes: Int) async throws -> Data {
    Data()
  }

  func close() async {}
}
