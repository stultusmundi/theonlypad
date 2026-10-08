import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Test collaborators only. No process, descriptors, wall clock, or automatic response engine.
final class DriverHarness: @unchecked Sendable {
  let clock = DriverTestClock()
  let timers = DriverTestTimers()
  let system = DriverTestSystem()
  let connection = DriverTestConnection()
  let lifecycle: SearchChildLifecycle

  init(maximumRequests: UInt32 = 32, operationNanoseconds: UInt64 = 1_000_000_000) throws {
    let clock = self.clock
    let timers = self.timers
    lifecycle = try SearchChildLifecycle(
      executable: URL(fileURLWithPath: "/synthetic/parent-driver-child"),
      policy: .init(
        operationNanoseconds: operationNanoseconds, reapGraceNanoseconds: 100_000_000,
        idleNanoseconds: 2_000_000_000, maximumRequestsPerChild: maximumRequests),
      system: system, now: { clock.now }, schedule: { timers.schedule($0, event: $1) })
  }

  var accumulatorFactory: SearchParentWireResponseAccumulatorFactory {
    { _ in DriverTestAccumulator() }
  }

  /// Releases injected waits; caller still awaits driver shutdown/scope receipts.
  func releaseAllGates() {
    connection.releaseAllGates()
    for connection in system.connections { connection.releaseAllGates() }
    system.failPending()
  }

  /// Prepare sole-reaper success before asking the actual owner to stop.
  func prepareCleanup() {
    releaseAllGates()
    system.prepareReap()
    let now = clock.advance(by: 100_000_000)
    timers.fireDue(at: now)
  }
}

final class DriverTestLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}

/// One-shot async gate; resumes outside its lock, including open-before-wait.
final class DriverTestGate: @unchecked Sendable {
  private struct State {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = DriverTestLocked(State())
  var isOpen: Bool { state.withValue { $0.opened } }
  func wait() async {
    await withCheckedContinuation { continuation in
      let immediate = state.withValue { state in
        if state.opened { return true }
        precondition(state.waiters.count < 32, "Fixture gate waiter bound")
        state.waiters.append(continuation)
        return false
      }
      if immediate { continuation.resume() }
    }
  }
  func open() {
    let pending = state.withValue { state in
      state.opened = true
      let pending = state.waiters
      state.waiters.removeAll()
      return pending
    }
    for continuation in pending { continuation.resume() }
  }
}

/// Monotonic count notifications, not polling or absence-after-sleep assertions.
final class DriverTestCount: @unchecked Sendable {
  private struct State {
    var value = 0
    var waiters: [(Int, DriverTestGate)] = []
  }
  private let state = DriverTestLocked(State())
  var value: Int { state.withValue { $0.value } }
  func increment() {
    let ready = state.withValue { state in
      state.value += 1
      let ready = state.waiters.filter { $0.0 <= state.value }.map { $0.1 }
      state.waiters.removeAll { $0.0 <= state.value }
      return ready
    }
    for gate in ready { gate.open() }
  }
  func wait(for count: Int) async {
    let gate = DriverTestGate()
    let immediate = state.withValue { state in
      if state.value >= count { return true }
      precondition(state.waiters.count < 32, "Fixture count waiter bound")
      state.waiters.append((count, gate))
      return false
    }
    if immediate { gate.open() }
    await gate.wait()
  }
}

final class DriverTestClock: @unchecked Sendable {
  private let state = DriverTestLocked<UInt64>(0)
  var now: UInt64 { state.withValue { $0 } }
  @discardableResult
  func advance(by delta: UInt64) -> UInt64 {
    state.withValue { value in
      let (next, overflow) = value.addingReportingOverflow(delta)
      value = overflow ? UInt64.max : next
      return value
    }
  }
}

final class DriverTestTimer: SearchChildTimer, @unchecked Sendable {
  let deadline: UInt64
  private let active = DriverTestLocked(true)
  private let event: @Sendable () -> Void
  init(_ deadline: UInt64, event: @escaping @Sendable () -> Void) {
    self.deadline = deadline
    self.event = event
  }
  var isActive: Bool { active.withValue { $0 } }
  func cancel() { active.withValue { $0 = false } }
  func fire() {
    let fire = active.withValue { value in
      let old = value
      value = false
      return old
    }
    if fire { event() }
  }
}

final class DriverTestTimers: @unchecked Sendable {
  private let storage = DriverTestLocked<[DriverTestTimer]>([])
  let scheduled = DriverTestCount()
  var activeDeadlines: [UInt64] {
    storage.withValue { $0.filter(\.isActive).map(\.deadline) }
  }
  func schedule(_ deadline: UInt64, event: @escaping @Sendable () -> Void) -> any SearchChildTimer {
    let timer = DriverTestTimer(deadline, event: event)
    storage.withValue {
      precondition($0.count < 512, "Fixture timer bound")
      $0.append(timer)
    }
    scheduled.increment()
    return timer
  }
  func fireDue(at now: UInt64) {
    let due = storage.withValue { $0.filter { $0.deadline <= now } }
    for timer in due { timer.fire() }
  }
}

final class DriverTestSystem: SearchChildSystem, @unchecked Sendable {
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
    var polls: [Int32] = []
    var defaultPoll: SearchChildPoll = .running
    var perPID: [Int32: SearchChildPoll] = [:]
    var connections: [DriverTestConnection] = []
    var reapOnSignal = false
  }
  private let state = DriverTestLocked(State())
  let launchCount = DriverTestCount()
  let pollCount = DriverTestCount()
  let signalCount = DriverTestCount()
  var generations: [UUID] { state.withValue { $0.launches.map(\.generation) } }
  var signals: [Signal] { state.withValue { $0.signals } }
  var polledPIDs: [Int32] { state.withValue { $0.polls } }
  var connections: [DriverTestConnection] { state.withValue { $0.connections } }
  var reapOnSignal: Bool {
    get { state.withValue { $0.reapOnSignal } }
    set { state.withValue { $0.reapOnSignal = newValue } }
  }
  var defaultPoll: SearchChildPoll {
    get { state.withValue { $0.defaultPoll } }
    set { state.withValue { $0.defaultPoll = newValue } }
  }
  func setPoll(_ result: SearchChildPoll, for pid: Int32) {
    state.withValue { $0.perPID[pid] = result }
  }
  func prepareReap() {
    state.withValue {
      $0.perPID.removeAll()
      $0.defaultPoll = .reaped(.signaled(SIGKILL))
    }
  }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    state.withValue {
      precondition($0.launches.count < 16, "Fixture launch bound")
      $0.launches.append(.init(generation: generation, completion: completion))
    }
    launchCount.increment()
  }
  func deliver(generation: UUID, pid: Int32, connection: DriverTestConnection) {
    let callback = state.withValue { state in
      let index = state.launches.firstIndex { $0.generation == generation }
      precondition(index != nil, "Deliver only an admitted synthetic launch")
      let callback = state.launches[index!].completion
      precondition(callback != nil, "Launch completion is one-shot")
      state.launches[index!].completion = nil
      state.connections.append(connection)
      return callback
    }
    callback?(.success(.init(pid: pid, connection: connection)))
  }
  func failPending() {
    let callbacks = state.withValue { state in
      let callbacks = state.launches.compactMap(\.completion)
      for index in state.launches.indices { state.launches[index].completion = nil }
      return callbacks
    }
    for callback in callbacks { callback(.failure(.launchFailed(ENOENT))) }
  }
  func signal(pid: Int32, signal: Int32) -> Int32 {
    state.withValue {
      precondition($0.signals.count < 64, "Fixture signal bound")
      $0.signals.append(.init(pid: pid, signal: signal))
      if $0.reapOnSignal { $0.perPID[pid] = .reaped(.signaled(signal)) }
    }
    signalCount.increment()
    return 0
  }
  func pollExit(pid: Int32) -> SearchChildPoll {
    let result = state.withValue { state in
      precondition(state.polls.count < 512, "Fixture poll bound")
      state.polls.append(pid)
      return state.perPID[pid] ?? state.defaultPoll
    }
    pollCount.increment()
    return result
  }
}

enum DriverTestIOFailure: Error, Sendable { case unexpected }

/// Scripted transport. No source engine or outgoing-stream parser supplies responses.
final class DriverTestConnection: SearchChildConnection, @unchecked Sendable {
  private enum ReadFailure: Error, Sendable {
    case child(SearchChildFailure)
    case unknown
    var error: Error {
      switch self {
      case .child(let failure): return failure
      case .unknown: return DriverTestIOFailure.unexpected
      }
    }
  }
  struct WritePlan: Sendable {
    let release: DriverTestGate?
    let returnRelease: DriverTestGate?
    let failure: SearchChildFailure?
    let unknownFailure: Bool
    init(
      release: DriverTestGate? = nil, returnRelease: DriverTestGate? = nil,
      failure: SearchChildFailure? = nil, unknownFailure: Bool = false
    ) {
      self.release = release
      self.returnRelease = returnRelease
      precondition(failure == nil || !unknownFailure)
      self.failure = failure
      self.unknownFailure = unknownFailure
    }
  }
  struct Snapshot {
    let activeReads: Int
    let activeWrites: Int
    let maximumReads: Int
    let maximumWrites: Int
    let writeSizes: [Int]
    let readBytes: Int
    let writtenBytes: Int
    let closed: Bool
  }
  private struct State {
    var reads: [Result<Data, ReadFailure>] = []
    var pendingRead: (Int, CheckedContinuation<Data, Error>)?
    var writes: [WritePlan] = []
    var gates: [DriverTestGate] = []
    var writeSizes: [Int] = []
    var activeReads = 0
    var activeWrites = 0
    var maximumReads = 0
    var maximumWrites = 0
    var readBytes = 0
    var writtenBytes = 0
    var closed = false
  }
  private let state = DriverTestLocked(State())
  let readEntered = DriverTestCount()
  let writeEntered = DriverTestCount()
  let writeCompleted = DriverTestCount()
  /// Tail-of-body event with the Data parameter still live; never a scope-release receipt.
  let writeReturning = DriverTestCount()
  let closeEntered = DriverTestCount()
  let closeRelease = DriverTestGate()
  /// The cancelled read still owns its return scope here; close may finish independently.
  let cancelledReadReturning = DriverTestCount()
  private let cancelledReadReturn: DriverTestGate?

  init(holdClose: Bool = false, cancelledReadReturn: DriverTestGate? = nil) {
    self.cancelledReadReturn = cancelledReadReturn
    if !holdClose { closeRelease.open() }
  }

  var snapshot: Snapshot {
    state.withValue {
      Snapshot(
        activeReads: $0.activeReads, activeWrites: $0.activeWrites,
        maximumReads: $0.maximumReads, maximumWrites: $0.maximumWrites,
        writeSizes: $0.writeSizes, readBytes: $0.readBytes,
        writtenBytes: $0.writtenBytes, closed: $0.closed)
    }
  }
  func enqueueWrite(_ plan: WritePlan) {
    state.withValue {
      precondition($0.writes.count < 128, "Fixture write script bound")
      $0.writes.append(plan)
      if let gate = plan.release { $0.gates.append(gate) }
      if let gate = plan.returnRelease { $0.gates.append(gate) }
    }
  }
  func offer(_ bytes: Data) { offerResult(.success(bytes)) }
  func offerFailure(_ failure: SearchChildFailure) { offerResult(.failure(.child(failure))) }
  func offerUnknownFailure() { offerResult(.failure(.unknown)) }
  func waitForReadCalls(_ count: Int) async { await readEntered.wait(for: count) }
  func waitForWriteCalls(_ count: Int) async { await writeEntered.wait(for: count) }
  func offer(_ result: Result<Data, SearchChildFailure>) {
    offerResult(result.mapError { .child($0) })
  }
  private func offerResult(_ result: Result<Data, ReadFailure>) {
    if case .success(let bytes) = result {
      precondition(bytes.count <= 65_568, "Synthetic read offer bound")
    }
    let pending = state.withValue {
      state -> (CheckedContinuation<Data, Error>, Result<Data, ReadFailure>)? in
      guard !state.closed else { return nil }
      if let (maximum, continuation) = state.pendingRead {
        state.pendingRead = nil
        return (continuation, Self.prefix(result, maximum: maximum, remaining: &state.reads))
      }
      precondition(state.reads.isEmpty, "Fixture permits only one offered read result")
      state.reads.append(result)
      return nil
    }
    if let pending { pending.0.resume(with: pending.1.mapError { $0.error }) }
  }
  func read(maxBytes: Int) async throws -> Data {
    guard (1...65_568).contains(maxBytes) else { throw SearchChildFailure.protocolFailure }
    state.withValue {
      $0.activeReads += 1
      $0.maximumReads = max($0.maximumReads, $0.activeReads)
    }
    defer { state.withValue { $0.activeReads -= 1 } }
    let bytes: Data
    do {
      bytes = try await withCheckedThrowingContinuation { continuation in
        let immediate = state.withValue { state -> Result<Data, ReadFailure>? in
          guard state.activeReads == 1 else { return .failure(.child(.protocolFailure)) }
          if state.closed { return .failure(.child(.cancelled)) }
          if !state.reads.isEmpty {
            let result = state.reads.removeFirst()
            return Self.prefix(result, maximum: maxBytes, remaining: &state.reads)
          }
          precondition(state.pendingRead == nil)
          state.pendingRead = (maxBytes, continuation)
          return nil
        }
        readEntered.increment()
        if let immediate { continuation.resume(with: immediate.mapError { $0.error }) }
      }
    } catch {
      if error as? SearchChildFailure == .cancelled {
        cancelledReadReturning.increment()
        if let cancelledReadReturn { await cancelledReadReturn.wait() }
      }
      throw error
    }
    state.withValue { $0.readBytes += bytes.count }
    return bytes
  }
  func write(_ bytes: Data) async throws {
    let plan = try state.withValue { state -> WritePlan in
      guard !state.closed else { throw SearchChildFailure.cancelled }
      guard (1...65_536).contains(bytes.count) else { throw SearchChildFailure.protocolFailure }
      state.activeWrites += 1
      state.maximumWrites = max(state.maximumWrites, state.activeWrites)
      precondition(state.writeSizes.count < 256, "Fixture write metadata bound")
      state.writeSizes.append(bytes.count)
      return state.writes.isEmpty ? WritePlan() : state.writes.removeFirst()
    }
    defer {
      withExtendedLifetime(bytes) {}
      state.withValue { $0.activeWrites -= 1 }
      writeReturning.increment()
    }
    writeEntered.increment()
    if let release = plan.release { await release.wait() }
    writeCompleted.increment()
    if let release = plan.returnRelease { await release.wait() }
    if let failure = plan.failure { throw failure }
    if plan.unknownFailure { throw DriverTestIOFailure.unexpected }
    state.withValue { $0.writtenBytes += bytes.count }
  }
  func close() async {
    let pending = closeReadSide()
    closeEntered.increment()
    pending?.resume(throwing: SearchChildFailure.cancelled)
    // Writes intentionally retain their independent return-scope gates after close.
    await closeRelease.wait()
  }
  private func closeReadSide() -> CheckedContinuation<Data, Error>? {
    let removed = state.withValue {
      state -> (
        CheckedContinuation<Data, Error>?, [Result<Data, ReadFailure>]
      ) in
      state.closed = true
      let retired = state.reads
      state.reads.removeAll()
      let pending = state.pendingRead?.1
      state.pendingRead = nil
      return (pending, retired)
    }
    withExtendedLifetime(removed.1) {}
    return removed.0
  }
  func releaseAllGates() {
    let gates = state.withValue { $0.gates }
    for gate in gates { gate.open() }
    closeRelease.open()
    cancelledReadReturn?.open()
  }
  private static func prefix(
    _ result: Result<Data, ReadFailure>, maximum: Int,
    remaining: inout [Result<Data, ReadFailure>]
  ) -> Result<Data, ReadFailure> {
    guard case .success(let bytes) = result, bytes.count > maximum else { return result }
    precondition(remaining.isEmpty, "Split remainder is the sole offered read result")
    remaining.insert(.success(Data(bytes.dropFirst(maximum))), at: 0)
    return .success(Data(bytes.prefix(maximum)))
  }
}

/// Tiny trusted accumulator, confined by the production codec session to its lane.
final class DriverTestAccumulator: SearchParentWireResponseAccumulator, @unchecked Sendable {
  private var identity: SearchWireIdentity?
  private var ranges: [NSRange] = []
  private var replacement = Data()
  private var hasReplacement = false
  private var terminal: SearchWireTerminal?
  private let owner = Thread.current
  private let onCallback: (@Sendable (String) -> Void)?
  init(onCallback: (@Sendable (String) -> Void)? = nil) { self.onCallback = onCallback }
  private func checkLane(_ name: String) {
    precondition(Thread.current === owner && !Thread.isMainThread)
    onCallback?(name)
  }
  func helloAccepted(generation: UUID) throws { checkLane("hello") }
  func begin(_ response: SearchWireResponse) throws {
    checkLane("begin")
    identity = response.identity
    hasReplacement = response.replacementUTF16 != nil
  }
  func appendRanges(_ values: [NSRange]) throws {
    checkLane("ranges")
    precondition(ranges.count + values.count <= 16, "Synthetic accumulator range bound")
    ranges.append(contentsOf: values)
  }
  func appendReplacementUTF8(_ bytes: Data) throws {
    checkLane("replacement")
    precondition(replacement.count + bytes.count <= 1024, "Synthetic accumulator text bound")
    replacement.append(bytes)
  }
  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    checkLane("complete")
    self.identity = identity
    self.terminal = terminal
  }
  func takeTerminal(for identity: SearchWireIdentity) throws -> (
    terminal: SearchWireTerminal, output: SearchExecutionOutput?
  ) {
    checkLane("take")
    guard self.identity == identity, let terminal else { throw SearchWireError.invalidPhase }
    let output: SearchExecutionOutput?
    if terminal == .success {
      output = .init(
        matches: ranges,
        replacement: hasReplacement ? String(decoding: replacement, as: UTF8.self) : nil)
    } else {
      output = nil
    }
    ranges.removeAll()
    replacement.removeAll()
    self.identity = nil
    self.terminal = nil
    hasReplacement = false
    return (terminal, output)
  }
  func discard() {
    checkLane("discard")
    identity = nil
    terminal = nil
    ranges.removeAll()
    replacement.removeAll()
  }
}

/// A synchronous hold is legal only from the dedicated codec thread in these fixtures.
final class DriverTestBlockingGate: @unchecked Sendable {
  let entered = DriverTestGate()
  private let condition = NSCondition()
  private var released = false
  func waitOnCodecThread() {
    precondition(!Thread.isMainThread)
    entered.open()
    condition.lock()
    while !released { condition.wait() }
    condition.unlock()
  }
  func open() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

enum DriverTestWire {
  static func childHello(generation: UUID) throws -> Data {
    var result = Data()
    try SearchWireWriter.hello(generation: generation, fromChild: true) { result.append($0) }
    return result
  }
  static func success(
    identity: SearchWireIdentity, matches: [NSRange] = [NSRange(location: 0, length: 1)],
    replacement: String? = nil
  ) throws -> Data {
    precondition(matches.count <= 16 && (replacement?.utf8.count ?? 0) <= 1024)
    let output = SearchExecutionOutput(matches: matches, replacement: replacement)
    let response = try SearchWireResponse(
      identity: identity, matchCount: matches.count, replacementUTF16: replacement?.utf16.count)
    var result = Data()
    try SearchWireWriter.responseBody(response, output: output) { result.append($0) }
    try SearchWireWriter.terminal(identity, result: .success) { result.append($0) }
    return result
  }
  static func semanticFailure(identity: SearchWireIdentity, error: SearchError) throws -> Data {
    var result = Data()
    try SearchWireWriter.terminal(identity, result: .failure(error)) { result.append($0) }
    return result
  }
}
