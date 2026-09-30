import Darwin
import Foundation

public final class SearchChildLifecycle: @unchecked Sendable {
  private let control: SearchChildLifecycleControl

  init(
    executable: URL, policy: SearchChildPolicy, system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> any SearchChildTimer
  ) throws {
    // URL.path can truncate at an encoded NUL on Foundation. Validate the full
    // decoded URL path before passing the URL to the launcher. No filesystem access.
    guard executable.isFileURL,
      let path = URLComponents(url: executable, resolvingAgainstBaseURL: true)?
        .percentEncodedPath.removingPercentEncoding,
      path.hasPrefix("/"), !path.isEmpty, !path.utf8.contains(0)
    else { throw SearchChildFailure.invalidExecutable }
    control = SearchChildLifecycleControl(
      executable: executable, policy: policy, system: system, now: now, schedule: schedule)
  }

  deinit {
    let owner = control
    owner.enqueue { owner.abandon() }
  }

  public func begin(requestID: UUID) async throws -> SearchChildTicket {
    try await control.perform { try $0.begin(requestID: requestID) }
  }

  public func wait(for ticket: SearchChildTicket) async throws -> SearchChildOutcome {
    let owner = control
    let observer = UUID()
    let registration = SearchChildObserverRegistration()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        owner.enqueue {
          owner.installWaiter(
            ticket, observer: observer, registration: registration,
            continuation: continuation)
        }
      }
    } onCancel: {
      registration.cancel()
      owner.enqueue { owner.cancelWaiter(ticket, observer: observer) }
    }
  }

  public func cancel(_ ticket: SearchChildTicket) async throws {
    try await control.perform { try $0.cancel(ticket) }
  }

  public func cleanup(for ticket: SearchChildTicket) async throws -> SearchChildCleanup {
    try await control.perform { try $0.cleanup(ticket) }
  }

  public func shutdown() async -> SearchChildShutdown {
    let owner = control
    return await withCheckedContinuation { continuation in
      owner.enqueue { owner.shutdown(continuation) }
    }
  }

  func connection(for ticket: SearchChildTicket) async throws -> any SearchChildConnection {
    let owner = control
    let observer = UUID()
    let registration = SearchChildObserverRegistration()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        owner.enqueue {
          owner.installConnectionWaiter(
            ticket, observer: observer, registration: registration,
            continuation: continuation)
        }
      }
    } onCancel: {
      registration.cancel()
      owner.enqueue { owner.cancelConnectionWaiter(ticket, observer: observer) }
    }
  }

  func acceptedHandshake(generation: UUID) async throws {
    try await control.perform { try $0.acceptedHandshake(generation) }
  }

  func acceptedTerminal(_ terminal: SearchWireTerminal, ticket: SearchChildTicket) async throws {
    try await control.perform { try $0.acceptedTerminal(terminal, ticket: ticket) }
  }

  func rejectedChannel(_ observation: SearchChildChannelObservation, generation: UUID) async {
    _ = try? await control.perform { $0.rejectedChannel(observation, generation: generation) }
  }

  func rejectedProtocol(generation: UUID) async {
    _ = try? await control.perform { $0.rejectedProtocol(generation) }
  }
}

/// All mutable state is confined to queue. Injected system methods submit work or perform
/// bounded nonblocking syscalls; they must never do filesystem validation or blocking I/O here.
/// Launch/timer callbacks enqueue directly, without an intermediate unstructured task.
private final class SearchChildLifecycleControl: @unchecked Sendable {
  private struct Operation {
    let ticket: SearchChildTicket
    let deadline: UInt64
    var timer: (any SearchChildTimer)?
    var waiter: (UUID, CheckedContinuation<SearchChildOutcome, Error>)?
    var connector: (UUID, CheckedContinuation<any SearchChildConnection, Error>)?
  }
  private struct Receipt {
    let ticket: SearchChildTicket
    let outcome: SearchChildOutcome
    // A reserved recycle request can be cleaning a different generation.
    let cleanupGeneration: UUID?
    var cleanup: SearchChildCleanup
  }
  private struct Child {
    let generation: UUID
    let pid: Int32
    let connection: any SearchChildConnection
    var completed: UInt32 = 0
    var handshake = false
    var stopping = false
    var signalSent = false
    var reaped: SearchChildExit?
    var closeStarted = false
    var closed = false
    var unconfirmed = false
    var idleDeadline: UInt64?
    var graceDeadline: UInt64?
    var timer: (any SearchChildTimer)?
    var timerToken: UUID?
  }
  private enum Slot {
    case absent
    case launching(UUID, stop: Bool)
    case owned(Child)
  }

  private let queue = DispatchQueue(label: "TheOnlyPad.search-child-control")
  private let executable: URL
  private let policy: SearchChildPolicy
  private let system: any SearchChildSystem
  private let now: @Sendable () -> UInt64
  private let schedule: @Sendable (UInt64, @escaping @Sendable () -> Void) -> any SearchChildTimer
  private var slot: Slot = .absent
  private var operation: Operation?
  private var receipt: Receipt?
  // Physical ownership outlives the facade and all observers, even if launch is stuck.
  // This lease ends only after successful reap AND actual channel close, or launch failure.
  private var ownership: SearchChildLifecycleControl?
  private var shutDown = false
  private var shutdownWaiter: CheckedContinuation<SearchChildShutdown, Never>?
  private var shutdownTimer: (any SearchChildTimer)?
  private var shutdownDeadline: UInt64?

  init(
    executable: URL, policy: SearchChildPolicy, system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> any SearchChildTimer
  ) {
    self.executable = executable
    self.policy = policy
    self.system = system
    self.now = now
    self.schedule = schedule
  }

  func enqueue(_ event: @escaping @Sendable () -> Void) { queue.async(execute: event) }

  func perform<T: Sendable>(
    _ body: @escaping @Sendable (SearchChildLifecycleControl) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      enqueue { continuation.resume(with: Result { try body(self) }) }
    }
  }

  func begin(requestID: UUID) throws -> SearchChildTicket {
    guard requestID != SearchWireBinary.zeroUUID else { throw SearchChildFailure.invalidRequestID }
    guard !shutDown else { throw SearchChildFailure.shutDown }
    guard operation == nil else { throw SearchChildFailure.busy }
    let generation: UUID
    let ordinal: UInt64
    var recycle: UUID?
    switch slot {
    case .absent:
      generation = UUID()
      ordinal = 1
    case .launching:
      throw SearchChildFailure.busy
    case .owned(let child):
      guard !child.stopping, child.reaped == nil, !child.unconfirmed else {
        throw SearchChildFailure.busy
      }
      if child.completed >= policy.maximumRequestsPerChild || child.completed == UInt32.max {
        generation = UUID()
        ordinal = 1
        recycle = child.generation
      } else {
        generation = child.generation
        ordinal = UInt64(child.completed) + 1
      }
    }
    let (deadline, overflow) = now().addingReportingOverflow(policy.operationNanoseconds)
    guard !overflow else { throw SearchChildFailure.invalidPolicy }
    let ticket = SearchChildTicket(
      identity: try SearchWireIdentity(
        generation: generation, requestID: requestID, ordinal: ordinal))
    // Publish identity before any collaborator can call back, including an inline timer.
    operation = Operation(ticket: ticket, deadline: deadline)
    operation?.timer = schedule(deadline) { [weak self] in
      guard let self else { return }
      self.enqueue { self.deadlineFired(ticket, deadline: deadline) }
    }
    if let recycle {
      stop(recycle)
    } else if case .absent = slot {
      launch(generation)
    } else if case .owned(var child) = slot {
      child.idleDeadline = nil
      slot = .owned(child)
    }
    return ticket
  }

  func installWaiter(
    _ ticket: SearchChildTicket, observer: UUID, registration: SearchChildObserverRegistration,
    continuation: CheckedContinuation<SearchChildOutcome, Error>
  ) {
    if registration.isCancelled {
      continuation.resume(throwing: CancellationError())
      return
    }
    if var current = operation, current.ticket == ticket {
      guard current.waiter == nil else {
        continuation.resume(throwing: SearchChildFailure.observerBusy)
        return
      }
      current.waiter = (observer, continuation)
      operation = current
    } else if let receipt, receipt.ticket == ticket {
      continuation.resume(returning: receipt.outcome)
    } else {
      continuation.resume(throwing: SearchChildFailure.staleTicket)
    }
  }

  func cancelWaiter(_ ticket: SearchChildTicket, observer: UUID) {
    guard var current = operation, current.ticket == ticket,
      let waiter = current.waiter, waiter.0 == observer
    else { return }
    current.waiter = nil
    operation = current
    waiter.1.resume(throwing: CancellationError())
  }

  func installConnectionWaiter(
    _ ticket: SearchChildTicket, observer: UUID, registration: SearchChildObserverRegistration,
    continuation: CheckedContinuation<any SearchChildConnection, Error>
  ) {
    if registration.isCancelled {
      continuation.resume(throwing: CancellationError())
      return
    }
    guard var current = operation, current.ticket == ticket else {
      continuation.resume(throwing: SearchChildFailure.staleTicket)
      return
    }
    if case .owned(let child) = slot, child.generation == ticket.identity.generation,
      !child.stopping, child.reaped == nil
    {
      continuation.resume(returning: child.connection)
      return
    }
    guard current.connector == nil else {
      continuation.resume(throwing: SearchChildFailure.observerBusy)
      return
    }
    current.connector = (observer, continuation)
    operation = current
  }

  func cancelConnectionWaiter(_ ticket: SearchChildTicket, observer: UUID) {
    guard var current = operation, current.ticket == ticket,
      let waiter = current.connector, waiter.0 == observer
    else { return }
    current.connector = nil
    operation = current
    waiter.1.resume(throwing: CancellationError())
  }

  func cancel(_ ticket: SearchChildTicket) throws {
    guard operation?.ticket == ticket else { throw SearchChildFailure.staleTicket }
    finish(.failed(.cancelled))
    stop(ticket.identity.generation)
  }

  func acceptedHandshake(_ generation: UUID) throws {
    guard operation?.ticket.identity.generation == generation,
      case .owned(var child) = slot, child.generation == generation,
      !child.stopping, child.reaped == nil
    else { throw SearchChildFailure.staleTicket }
    child.handshake = true
    slot = .owned(child)
  }

  func acceptedTerminal(_ terminal: SearchWireTerminal, ticket: SearchChildTicket) throws {
    guard let current = operation, current.ticket == ticket else {
      throw SearchChildFailure.staleTicket
    }
    guard now() < current.deadline else {
      finish(.failed(.deadline))
      stop(ticket.identity.generation)
      throw SearchChildFailure.deadline
    }
    guard case .owned(let child) = slot, child.generation == ticket.identity.generation,
      !child.stopping, child.reaped == nil
    else { throw SearchChildFailure.staleTicket }
    guard child.handshake else { throw SearchChildFailure.handshakeFailure }
    observe(child.generation)
    guard operation?.ticket == ticket else { throw SearchChildFailure.unexpectedExit }
    guard case .owned(var ready) = slot else { throw SearchChildFailure.unexpectedExit }
    ready.completed += 1
    let (idle, overflow) = now().addingReportingOverflow(policy.idleNanoseconds)
    ready.idleDeadline = overflow ? now() : idle
    slot = .owned(ready)
    finish(.completed(terminal))
    armMaintenance(ready.generation)
  }

  func rejectedChannel(_ observation: SearchChildChannelObservation, generation: UUID) {
    // No channel has been delivered for absent/launching/foreign generations.
    guard case .owned(let child) = slot, child.generation == generation else { return }
    if operation?.ticket.identity.generation == generation {
      let failure: SearchChildFailure
      switch observation {
      case .endOfFile:
        failure = child.handshake ? .unexpectedExit : .handshakeFailure
      case .failure(let errorNumber):
        failure = errorNumber > 0 ? .channelFailure(errorNumber) : .protocolFailure
      }
      finish(.failed(failure))
    }
    // Retire physical ownership even when a previous terminal already won.
    // During recycling the reserved operation can belong to a NEW generation.
    stop(generation)
  }

  func rejectedProtocol(_ generation: UUID) {
    if operation?.ticket.identity.generation == generation { finish(.failed(.protocolFailure)) }
    stop(generation)
  }

  func cleanup(_ ticket: SearchChildTicket) throws -> SearchChildCleanup {
    if operation?.ticket == ticket { return cleanupSnapshot() }
    if let receipt, receipt.ticket == ticket { return receipt.cleanup }
    throw SearchChildFailure.staleTicket
  }

  func abandon() {
    shutDown = true
    if operation != nil { finish(.failed(.shutDown)) }
    switch slot {
    case .launching(let generation, _): stop(generation)
    case .owned(let child): stop(child.generation)
    case .absent: break
    }
  }

  func shutdown(_ continuation: CheckedContinuation<SearchChildShutdown, Never>) {
    // Repeated calls inspect the same ownership; they never restart a grace period.
    if shutDown {
      continuation.resume(returning: shutdownSnapshot())
      return
    }
    abandon()
    guard !stoppedNow else {
      continuation.resume(returning: shutdownSnapshot())
      return
    }
    let (deadline, overflow) = now().addingReportingOverflow(policy.reapGraceNanoseconds)
    guard !overflow else {
      continuation.resume(returning: shutdownSnapshot())
      return
    }
    shutdownDeadline = deadline
    shutdownWaiter = continuation
    shutdownTimer = schedule(deadline) { [weak self] in
      guard let self else { return }
      self.enqueue { self.shutdownGraceFired(deadline) }
    }
  }

  private func launch(_ generation: UUID) {
    slot = .launching(generation, stop: false)
    ownership = self
    system.launch(executable: executable, generation: generation) { [weak self] result in
      guard let self else { return }
      self.enqueue { self.launchCompleted(generation, result: result) }
    }
  }

  private func launchCompleted(
    _ generation: UUID, result: Result<SearchLaunchedChild, SearchChildFailure>
  ) {
    guard case .launching(let expected, let stopRequested) = slot, expected == generation else {
      return
    }
    switch result {
    case .failure(let failure):
      slot = .absent
      ownership = nil
      if operation?.ticket.identity.generation == generation { finish(.failed(failure)) }
      updateReceipt(generation, cleanup: .noChild)
      completeShutdownIfStopped()
    case .success(let launched):
      slot = .owned(
        Child(generation: generation, pid: launched.pid, connection: launched.connection))
      if stopRequested || shutDown || operation?.ticket.identity.generation != generation {
        stop(generation)
      } else if let failure = launched.startupFailure {
        // Spawn succeeded: keep its PID and cleanup ownership even when startup failed.
        finish(.failed(failure))
        stop(generation)
      } else {
        if var current = operation, let waiter = current.connector {
          current.connector = nil
          operation = current
          waiter.1.resume(returning: launched.connection)
        }
        armMaintenance(generation)
      }
    }
  }

  private func deadlineFired(_ ticket: SearchChildTicket, deadline: UInt64) {
    guard operation?.ticket == ticket, operation?.deadline == deadline, now() >= deadline else {
      return
    }
    finish(.failed(.deadline))
    stop(ticket.identity.generation)
  }

  private func stop(_ generation: UUID) {
    switch slot {
    case .launching(let expected, _) where expected == generation:
      slot = .launching(generation, stop: true)
    case .owned(var child) where child.generation == generation:
      guard !child.stopping else { return }
      let maySignal = !child.unconfirmed
      child.stopping = true
      child.idleDeadline = nil
      let (deadline, overflow) = now().addingReportingOverflow(policy.reapGraceNanoseconds)
      child.graceDeadline = overflow ? nil : deadline
      child.unconfirmed = child.unconfirmed || overflow
      // Only a successful wait receipt removes signal authority. ECHILD is handled
      // separately by observe, which quarantines without ever signaling that PID again.
      if child.reaped == nil, !child.signalSent, maySignal {
        child.signalSent = true
        _ = system.signal(pid: child.pid, signal: SIGKILL)
      }
      slot = .owned(child)
      updateReceipt(generation, cleanup: cleanupSnapshot())
      startClose(generation)
      observe(generation)
      armMaintenance(generation)
    default: break
    }
  }

  private func observe(_ generation: UUID) {
    guard case .owned(var child) = slot, child.generation == generation, child.reaped == nil else {
      return
    }
    switch system.pollExit(pid: child.pid) {
    case .reaped(let exit):
      child.reaped = exit
      child.timer?.cancel()
      child.timer = nil
      child.timerToken = nil
      slot = .owned(child)
      if operation?.ticket.identity.generation == generation { finish(.failed(.unexpectedExit)) }
      updateReceipt(generation, cleanup: .reaped(generation: generation, exit: exit))
      startClose(generation)
      releaseIfComplete(generation)
    case .failed:
      child.unconfirmed = true
      child.stopping = true
      child.idleDeadline = nil
      slot = .owned(child)
      if operation?.ticket.identity.generation == generation { finish(.failed(.unexpectedExit)) }
      updateReceipt(generation, cleanup: .stopUnconfirmed(generation: generation))
      startClose(generation)
    case .running, .interrupted:
      if child.stopping, let deadline = child.graceDeadline, now() >= deadline {
        child.unconfirmed = true
        slot = .owned(child)
        updateReceipt(generation, cleanup: .stopUnconfirmed(generation: generation))
      }
    }
  }

  /// One retained low-rate observation timer per owned child, including quarantine.
  /// Polling substitutes for process notifications in this primitive; no codec/chunk events.
  /// The 100ms cadence is independent of policy grace; only a pending first grace
  /// or idle deadline can wake it sooner, so tiny grace values cannot spin quarantine.
  private func armMaintenance(_ generation: UUID) {
    guard case .owned(var child) = slot, child.generation == generation, child.reaped == nil else {
      return
    }
    child.timer?.cancel()
    let (next, overflow) = now().addingReportingOverflow(
      100_000_000)
    guard !overflow else {
      child.timer = nil
      child.timerToken = nil
      slot = .owned(child)
      return
    }
    var deadline = next
    if let idle = child.idleDeadline { deadline = min(deadline, idle) }
    if let grace = child.graceDeadline, grace > now() { deadline = min(deadline, grace) }
    let token = UUID()
    child.timer = nil
    child.timerToken = token
    slot = .owned(child)
    let timer = schedule(deadline) { [weak self, deadline] in
      guard let self else { return }
      self.enqueue { self.maintenanceFired(generation, token: token, deadline: deadline) }
    }
    if case .owned(var scheduled) = slot, scheduled.timerToken == token {
      scheduled.timer = timer
      slot = .owned(scheduled)
    } else {
      timer.cancel()
    }
  }

  private func maintenanceFired(_ generation: UUID, token: UUID, deadline: UInt64) {
    guard case .owned(let child) = slot, child.generation == generation,
      child.timerToken == token, now() >= deadline
    else { return }
    observe(generation)
    if case .owned(let current) = slot, current.generation == generation,
      !current.stopping, let idle = current.idleDeadline, now() >= idle
    {
      stop(generation)
    } else {
      armMaintenance(generation)
    }
    completeShutdownIfStopped()
  }

  private func startClose(_ generation: UUID) {
    guard case .owned(var child) = slot, child.generation == generation, !child.closeStarted else {
      return
    }
    child.closeStarted = true
    slot = .owned(child)
    // Exactly one asynchronous close per physical child, independent of the control lane.
    Task.detached { [connection = child.connection] in
      await connection.close()
      self.enqueue { self.connectionClosed(generation) }
    }
  }

  private func connectionClosed(_ generation: UUID) {
    guard case .owned(var child) = slot, child.generation == generation else { return }
    child.closed = true
    slot = .owned(child)
    releaseIfComplete(generation)
    completeShutdownIfStopped()
  }

  private func releaseIfComplete(_ generation: UUID) {
    guard case .owned(let child) = slot, child.generation == generation,
      child.reaped != nil, child.closed
    else { return }
    child.timer?.cancel()
    slot = .absent
    ownership = nil
    if let current = operation, current.ticket.identity.generation != generation {
      if now() >= current.deadline {
        finish(.failed(.deadline))
      } else {
        launch(current.ticket.identity.generation)
      }
    }
  }

  private func finish(_ outcome: SearchChildOutcome) {
    guard let current = operation else { return }
    current.timer?.cancel()
    operation = nil
    receipt = Receipt(
      ticket: current.ticket, outcome: outcome, cleanupGeneration: physicalGeneration,
      cleanup: cleanupSnapshot())
    current.connector?.1.resume(throwing: SearchChildFailure.staleTicket)
    current.waiter?.1.resume(returning: outcome)
  }

  private var physicalGeneration: UUID? {
    switch slot {
    case .absent: return nil
    case .launching(let generation, _): return generation
    case .owned(let child): return child.generation
    }
  }

  private func cleanupSnapshot() -> SearchChildCleanup {
    switch slot {
    case .absent: return .noChild
    case .launching(let generation, _): return .pendingLaunch(generation: generation)
    case .owned(let child):
      if let exit = child.reaped { return .reaped(generation: child.generation, exit: exit) }
      if child.unconfirmed { return .stopUnconfirmed(generation: child.generation) }
      return .stopping(generation: child.generation)
    }
  }

  private var stoppedNow: Bool {
    if case .absent = slot { return true }
    return false
  }

  private func shutdownSnapshot() -> SearchChildShutdown {
    let closed: Bool
    switch slot {
    case .absent: closed = true
    case .launching: closed = false
    case .owned(let child): closed = child.closed
    }
    return .init(cleanup: cleanupSnapshot(), channelsClosed: closed)
  }

  private func completeShutdownIfStopped() {
    guard stoppedNow else { return }
    shutdownTimer?.cancel()
    shutdownTimer = nil
    let waiter = shutdownWaiter
    shutdownWaiter = nil
    waiter?.resume(returning: shutdownSnapshot())
  }

  private func shutdownGraceFired(_ deadline: UInt64) {
    guard shutdownWaiter != nil, shutdownDeadline == deadline, now() >= deadline else { return }
    if case .owned(let child) = slot { observe(child.generation) }
    let waiter = shutdownWaiter
    shutdownWaiter = nil
    shutdownTimer?.cancel()
    shutdownTimer = nil
    waiter?.resume(returning: shutdownSnapshot())
  }

  private func updateReceipt(_ generation: UUID, cleanup: SearchChildCleanup) {
    guard receipt?.cleanupGeneration == generation else { return }
    receipt?.cleanup = cleanup
  }
}
