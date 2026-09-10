import Darwin
import Foundation

public final class SearchChildLifecycle: @unchecked Sendable {
  private let control: SearchChildLifecycleControl

  init(
    executable: URL,
    policy: SearchChildPolicy,
    system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule:
      @escaping @Sendable (
        UInt64, @escaping @Sendable () -> Void
      ) -> any SearchChildTimer
  ) throws {
    guard executable.isFileURL, executable.path.hasPrefix("/"), !executable.path.isEmpty,
      !executable.path.utf8.contains(0)
    else {
      throw SearchChildFailure.invalidExecutable
    }
    control = SearchChildLifecycleControl(
      executable: executable, policy: policy, system: system, now: now, schedule: schedule)
  }

  public func begin(requestID: UUID) async throws -> SearchChildTicket {
    try await control.begin(requestID: requestID)
  }

  public func wait(for ticket: SearchChildTicket) async throws -> SearchChildOutcome {
    let observer = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Task {
          await self.control.installWaiter(
            ticket: ticket, observer: observer, continuation: continuation)
        }
      }
    } onCancel: {
      Task { await self.control.cancelWaiter(ticket: ticket, observer: observer) }
    }
  }

  public func cancel(_ ticket: SearchChildTicket) async throws {
    try await control.cancel(ticket: ticket, failure: .cancelled)
  }

  public func cleanup(for ticket: SearchChildTicket) async throws -> SearchChildCleanup {
    try await control.cleanup(for: ticket)
  }

  public func shutdown() async -> SearchChildShutdown {
    await control.shutdown()
  }

  func connection(for ticket: SearchChildTicket) async throws -> any SearchChildConnection {
    let observer = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Task {
          await self.control.installConnectionWaiter(
            ticket: ticket, observer: observer, continuation: continuation)
        }
      }
    } onCancel: {
      Task { await self.control.cancelConnectionWaiter(ticket: ticket, observer: observer) }
    }
  }

  func acceptedHandshake(generation: UUID) async throws {
    try await control.acceptedHandshake(generation: generation)
  }

  func acceptedTerminal(_ terminal: SearchWireTerminal, ticket: SearchChildTicket) async throws {
    try await control.acceptedTerminal(terminal, ticket: ticket)
  }

  func rejectedProtocol(generation: UUID) async {
    await control.rejectedProtocol(generation: generation)
  }
}

private actor SearchChildLifecycleControl {
  private struct Operation {
    let ticket: SearchChildTicket
    let deadline: UInt64
    let timer: any SearchChildTimer
    let beginsFreshGeneration: Bool
    var waiter: Waiter?
    var connectionWaiter: ConnectionWaiter?
  }

  private struct Waiter {
    let observer: UUID
    let continuation: CheckedContinuation<SearchChildOutcome, Error>
  }

  private struct ConnectionWaiter {
    let observer: UUID
    let continuation: CheckedContinuation<any SearchChildConnection, Error>
  }

  private struct Receipt {
    let ticket: SearchChildTicket
    let outcome: SearchChildOutcome
    var cleanup: SearchChildCleanup
  }

  private struct OwnedChild {
    let generation: UUID
    let pid: Int32
    let connection: any SearchChildConnection
    var requestsCompleted: UInt32
    var handshakeAccepted: Bool
    var stopRequested: Bool
    var signalSent: Bool
    var reaped: SearchChildExit?
    var closeCompleted: Bool
    var stopUnconfirmed: Bool
    var reapTimer: (any SearchChildTimer)?
  }

  private enum Slot {
    case absent
    case launching(generation: UUID, stopRequested: Bool)
    case owned(OwnedChild)
  }

  private let executable: URL
  private let policy: SearchChildPolicy
  private let system: any SearchChildSystem
  private let now: @Sendable () -> UInt64
  private let schedule: @Sendable (UInt64, @escaping @Sendable () -> Void) -> any SearchChildTimer
  private var slot: Slot = .absent
  private var operation: Operation?
  private var receipt: Receipt?
  private var shutDown = false
  private var shutdownWaiter: CheckedContinuation<SearchChildShutdown, Never>?
  private var shutdownTimer: (any SearchChildTimer)?

  init(
    executable: URL,
    policy: SearchChildPolicy,
    system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule:
      @escaping @Sendable (
        UInt64, @escaping @Sendable () -> Void
      ) -> any SearchChildTimer
  ) {
    self.executable = executable
    self.policy = policy
    self.system = system
    self.now = now
    self.schedule = schedule
  }

  func begin(requestID: UUID) throws -> SearchChildTicket {
    guard requestID != SearchWireBinary.zeroUUID else { throw SearchChildFailure.invalidRequestID }
    guard !shutDown else { throw SearchChildFailure.shutDown }
    guard operation == nil else { throw SearchChildFailure.busy }

    switch slot {
    case .absent:
      return try admit(
        requestID: requestID, generation: UUID(), ordinal: 1, beginsFreshGeneration: true)
    case .launching:
      throw SearchChildFailure.busy
    case .owned(let child)
    where child.stopRequested || child.reaped != nil || child.stopUnconfirmed:
      throw SearchChildFailure.busy
    case .owned(let child):
      guard child.requestsCompleted < policy.maximumRequestsPerChild,
        child.requestsCompleted < UInt32.max
      else {
        let ticket = try admit(
          requestID: requestID, generation: UUID(), ordinal: 1, beginsFreshGeneration: true)
        requestStop(for: child.generation)
        return ticket
      }
      let ordinal = UInt64(child.requestsCompleted) + 1
      return try admit(
        requestID: requestID, generation: child.generation, ordinal: ordinal,
        beginsFreshGeneration: false)
    }
  }

  func installWaiter(
    ticket: SearchChildTicket,
    observer: UUID,
    continuation: CheckedContinuation<SearchChildOutcome, Error>
  ) {
    if let operation, operation.ticket == ticket {
      guard operation.waiter == nil else {
        continuation.resume(throwing: SearchChildFailure.observerBusy)
        return
      }
      var replacement = operation
      replacement.waiter = .init(observer: observer, continuation: continuation)
      self.operation = replacement
      return
    }
    if let receipt, receipt.ticket == ticket {
      continuation.resume(returning: receipt.outcome)
    } else {
      continuation.resume(throwing: SearchChildFailure.staleTicket)
    }
  }

  func cancelWaiter(ticket: SearchChildTicket, observer: UUID) {
    guard var operation, operation.ticket == ticket, operation.waiter?.observer == observer,
      let waiter = operation.waiter
    else { return }
    operation.waiter = nil
    self.operation = operation
    waiter.continuation.resume(throwing: CancellationError())
  }

  func installConnectionWaiter(
    ticket: SearchChildTicket,
    observer: UUID,
    continuation: CheckedContinuation<any SearchChildConnection, Error>
  ) {
    guard let operation, operation.ticket == ticket else {
      continuation.resume(throwing: SearchChildFailure.staleTicket)
      return
    }
    if case .owned(let child) = slot, child.generation == ticket.identity.generation,
      !child.stopRequested, child.reaped == nil
    {
      continuation.resume(returning: child.connection)
      return
    }
    guard operation.connectionWaiter == nil else {
      continuation.resume(throwing: SearchChildFailure.observerBusy)
      return
    }
    var replacement = operation
    replacement.connectionWaiter = .init(observer: observer, continuation: continuation)
    self.operation = replacement
  }

  func cancelConnectionWaiter(ticket: SearchChildTicket, observer: UUID) {
    guard var operation, operation.ticket == ticket,
      operation.connectionWaiter?.observer == observer,
      let waiter = operation.connectionWaiter
    else { return }
    operation.connectionWaiter = nil
    self.operation = operation
    waiter.continuation.resume(throwing: CancellationError())
  }

  func cancel(ticket: SearchChildTicket, failure: SearchChildFailure) throws {
    guard let operation, operation.ticket == ticket else { throw SearchChildFailure.staleTicket }
    finish(operation: operation, outcome: .failed(failure))
    requestStop(for: ticket.identity.generation)
  }

  func acceptedHandshake(generation: UUID) throws {
    guard let operation, operation.ticket.identity.generation == generation else {
      throw SearchChildFailure.staleTicket
    }
    guard case .owned(var child) = slot, child.generation == generation,
      !child.stopRequested, child.reaped == nil
    else { throw SearchChildFailure.staleTicket }
    child.handshakeAccepted = true
    slot = .owned(child)
  }

  func acceptedTerminal(_ terminal: SearchWireTerminal, ticket: SearchChildTicket) throws {
    guard let operation, operation.ticket == ticket else { throw SearchChildFailure.staleTicket }
    guard now() < operation.deadline else {
      finish(operation: operation, outcome: .failed(.deadline))
      requestStop(for: ticket.identity.generation)
      throw SearchChildFailure.deadline
    }
    guard case .owned(let child) = slot, child.generation == ticket.identity.generation,
      !child.stopRequested, child.reaped == nil
    else {
      finish(operation: operation, outcome: .failed(.unexpectedExit))
      throw SearchChildFailure.unexpectedExit
    }
    guard child.handshakeAccepted else { throw SearchChildFailure.handshakeFailure }
    switch system.pollExit(pid: child.pid) {
    case .reaped(let exit):
      var exited = child
      exited.reaped = exit
      slot = .owned(exited)
      finish(operation: operation, outcome: .failed(.unexpectedExit))
      close(child: exited)
      throw SearchChildFailure.unexpectedExit
    case .failed:
      var unconfirmed = child
      unconfirmed.stopUnconfirmed = true
      slot = .owned(unconfirmed)
      finish(operation: operation, outcome: .failed(.unexpectedExit))
      close(child: unconfirmed)
      throw SearchChildFailure.unexpectedExit
    case .running, .interrupted:
      break
    }
    finish(operation: operation, outcome: .completed(terminal))
    var ready = child
    ready.requestsCompleted += 1
    slot = .owned(ready)
  }

  func rejectedProtocol(generation: UUID) {
    if let operation, operation.ticket.identity.generation == generation {
      finish(operation: operation, outcome: .failed(.protocolFailure))
    }
    requestStop(for: generation)
  }

  func cleanup(for ticket: SearchChildTicket) throws -> SearchChildCleanup {
    if let operation, operation.ticket == ticket { return cleanupSnapshot() }
    if let receipt, receipt.ticket == ticket { return receipt.cleanup }
    throw SearchChildFailure.staleTicket
  }

  func shutdown() async -> SearchChildShutdown {
    shutDown = true
    if let operation {
      finish(operation: operation, outcome: .failed(.shutDown))
      requestStop(for: operation.ticket.identity.generation)
    } else if case .owned(let child) = slot, !child.stopRequested {
      requestStop(for: child.generation)
    }
    if stoppedNow { return shutdownSnapshot() }
    if shutdownWaiter != nil { return shutdownSnapshot() }
    let (deadline, overflow) = now().addingReportingOverflow(policy.reapGraceNanoseconds)
    guard !overflow else { return shutdownSnapshot() }
    return await withCheckedContinuation { continuation in
      shutdownWaiter = continuation
      shutdownTimer = schedule(deadline) { [weak self] in
        Task { await self?.shutdownGraceFired(deadline: deadline) }
      }
    }
  }

  private func admit(
    requestID: UUID,
    generation: UUID,
    ordinal: UInt64,
    beginsFreshGeneration: Bool
  ) throws -> SearchChildTicket {
    let (deadline, overflow) = now().addingReportingOverflow(policy.operationNanoseconds)
    guard !overflow else { throw SearchChildFailure.invalidPolicy }
    let identity = try SearchWireIdentity(
      generation: generation, requestID: requestID, ordinal: ordinal)
    let ticket = SearchChildTicket(identity: identity)
    let timer = schedule(deadline) { [weak self] in
      Task { await self?.deadlineFired(ticket: ticket, deadline: deadline) }
    }
    operation = .init(
      ticket: ticket, deadline: deadline, timer: timer,
      beginsFreshGeneration: beginsFreshGeneration,
      waiter: nil, connectionWaiter: nil)
    if beginsFreshGeneration {
      switch slot {
      case .absent:
        slot = .launching(generation: generation, stopRequested: false)
        launch(generation: generation)
      case .owned:
        break
      case .launching:
        break
      }
    }
    return ticket
  }

  private func launch(generation: UUID) {
    system.launch(executable: executable, generation: generation) { [weak self] result in
      Task { await self?.launchCompleted(generation: generation, result: result) }
    }
  }

  private func launchCompleted(
    generation: UUID,
    result: Result<SearchLaunchedChild, SearchChildFailure>
  ) {
    guard case .launching(let expectedGeneration, let shouldStop) = slot,
      expectedGeneration == generation
    else { return }
    switch result {
    case .failure(let failure):
      slot = .absent
      if let operation, operation.ticket.identity.generation == generation {
        finish(operation: operation, outcome: .failed(failure))
      }
    case .success(let launched):
      let stopAfterLaunch = shouldStop
      let child = OwnedChild(
        generation: generation, pid: launched.pid, connection: launched.connection,
        requestsCompleted: 0,
        handshakeAccepted: false, stopRequested: false, signalSent: false, reaped: nil,
        closeCompleted: false,
        stopUnconfirmed: false, reapTimer: nil)
      slot = .owned(child)
      deliverConnectionIfWaiting(child: child)
      if stopAfterLaunch || operation?.ticket.identity.generation != generation {
        requestStop(for: generation)
      }
    }
  }

  private func deadlineFired(ticket: SearchChildTicket, deadline: UInt64) {
    guard let operation, operation.ticket == ticket, operation.deadline == deadline else { return }
    guard now() >= deadline else { return }
    finish(operation: operation, outcome: .failed(.deadline))
    requestStop(for: ticket.identity.generation)
  }

  private func requestStop(for generation: UUID) {
    switch slot {
    case .launching(let currentGeneration, _) where currentGeneration == generation:
      slot = .launching(generation: generation, stopRequested: true)
    case .owned(var child) where child.generation == generation:
      guard !child.stopRequested else { return }
      child.stopRequested = true
      if child.reaped == nil, !child.signalSent {
        child.signalSent = true
        _ = system.signal(pid: child.pid, signal: SIGKILL)
      }
      let (graceDeadline, overflow) = now().addingReportingOverflow(policy.reapGraceNanoseconds)
      if overflow {
        child.stopUnconfirmed = true
      } else {
        child.reapTimer = schedule(graceDeadline) { [weak self] in
          Task { await self?.reapGraceFired(generation: generation, deadline: graceDeadline) }
        }
      }
      slot = .owned(child)
      close(child: child)
      pollExit(for: generation)
    default:
      return
    }
  }

  private func close(child: OwnedChild) {
    Task.detached { [connection = child.connection, generation = child.generation] in
      await connection.close()
      await self.connectionClosed(generation: generation)
    }
  }

  private func connectionClosed(generation: UUID) {
    guard case .owned(var child) = slot, child.generation == generation else { return }
    child.closeCompleted = true
    slot = .owned(child)
    releaseIfComplete(generation: generation)
    completeShutdownIfStopped()
  }

  private func reapGraceFired(generation: UUID, deadline: UInt64) {
    guard case .owned(var child) = slot, child.generation == generation,
      child.stopRequested, child.reaped == nil
    else { return }
    guard now() >= deadline else { return }
    switch system.pollExit(pid: child.pid) {
    case .reaped(let exit):
      child.reaped = exit
      child.reapTimer?.cancel()
      child.reapTimer = nil
      slot = .owned(child)
      updateReceiptCleanup(
        generation: generation, cleanup: .reaped(generation: generation, exit: exit))
      releaseIfComplete(generation: generation)
    case .running, .interrupted:
      child.stopUnconfirmed = true
      slot = .owned(child)
      updateReceiptCleanup(
        generation: generation, cleanup: .stopUnconfirmed(generation: generation))
    case .failed:
      child.stopUnconfirmed = true
      slot = .owned(child)
      updateReceiptCleanup(
        generation: generation, cleanup: .stopUnconfirmed(generation: generation))
    }
    completeShutdownIfStopped()
  }

  private func pollExit(for generation: UUID) {
    guard case .owned(let child) = slot, child.generation == generation,
      child.stopRequested, child.reaped == nil
    else { return }
    if case .reaped(let exit) = system.pollExit(pid: child.pid) {
      var reaped = child
      reaped.reaped = exit
      reaped.reapTimer?.cancel()
      reaped.reapTimer = nil
      slot = .owned(reaped)
      updateReceiptCleanup(
        generation: generation, cleanup: .reaped(generation: generation, exit: exit))
      releaseIfComplete(generation: generation)
      completeShutdownIfStopped()
    }
  }

  private func releaseIfComplete(generation: UUID) {
    guard case .owned(let child) = slot, child.generation == generation,
      child.reaped != nil, child.closeCompleted
    else { return }
    slot = .absent
    if let operation, operation.beginsFreshGeneration,
      operation.ticket.identity.generation != generation
    {
      launchFreshOperationIfStillLive(operation)
    }
  }

  private func launchFreshOperationIfStillLive(_ operation: Operation) {
    guard self.operation?.ticket == operation.ticket else { return }
    slot = .launching(generation: operation.ticket.identity.generation, stopRequested: false)
    launch(generation: operation.ticket.identity.generation)
  }

  private func finish(operation: Operation, outcome: SearchChildOutcome) {
    operation.timer.cancel()
    self.operation = nil
    let cleanup = cleanupSnapshot()
    receipt = .init(ticket: operation.ticket, outcome: outcome, cleanup: cleanup)
    operation.connectionWaiter?.continuation.resume(throwing: SearchChildFailure.staleTicket)
    operation.waiter?.continuation.resume(returning: outcome)
  }

  private func deliverConnectionIfWaiting(child: OwnedChild) {
    guard let operation, operation.ticket.identity.generation == child.generation,
      let waiter = operation.connectionWaiter
    else { return }
    var replacement = operation
    replacement.connectionWaiter = nil
    self.operation = replacement
    waiter.continuation.resume(returning: child.connection)
  }

  private func cleanupSnapshot() -> SearchChildCleanup {
    switch slot {
    case .absent:
      return .noChild
    case .launching(let generation, _):
      return .pendingLaunch(generation: generation)
    case .owned(let child):
      if let exit = child.reaped { return .reaped(generation: child.generation, exit: exit) }
      if child.stopUnconfirmed { return .stopUnconfirmed(generation: child.generation) }
      return .stopping(generation: child.generation)
    }
  }

  private var channelsClosed: Bool {
    switch slot {
    case .absent, .launching:
      return true
    case .owned(let child):
      return child.closeCompleted
    }
  }

  private var stoppedNow: Bool {
    switch slot {
    case .absent:
      return true
    case .launching:
      return false
    case .owned(let child):
      return child.reaped != nil && child.closeCompleted
    }
  }

  private func shutdownSnapshot() -> SearchChildShutdown {
    .init(cleanup: cleanupSnapshot(), channelsClosed: channelsClosed)
  }

  private func completeShutdownIfStopped() {
    guard stoppedNow, let waiter = shutdownWaiter else { return }
    shutdownTimer?.cancel()
    shutdownTimer = nil
    shutdownWaiter = nil
    waiter.resume(returning: shutdownSnapshot())
  }

  private func shutdownGraceFired(deadline: UInt64) {
    guard shutdownWaiter != nil, now() >= deadline else { return }
    switch slot {
    case .owned(let child) where child.stopRequested && child.reaped == nil:
      pollExit(for: child.generation)
      if case .owned(var stillOwned) = slot, stillOwned.generation == child.generation,
        stillOwned.reaped == nil
      {
        stillOwned.stopUnconfirmed = true
        slot = .owned(stillOwned)
        updateReceiptCleanup(
          generation: stillOwned.generation,
          cleanup: .stopUnconfirmed(generation: stillOwned.generation))
      }
    case .absent, .launching, .owned:
      break
    }
    guard let waiter = shutdownWaiter else { return }
    shutdownTimer = nil
    shutdownWaiter = nil
    waiter.resume(returning: shutdownSnapshot())
  }

  private func updateReceiptCleanup(generation: UUID, cleanup: SearchChildCleanup) {
    guard var receipt, receipt.ticket.identity.generation == generation else { return }
    receipt.cleanup = cleanup
    self.receipt = receipt
  }
}
