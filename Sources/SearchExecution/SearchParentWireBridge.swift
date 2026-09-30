import Foundation

struct SearchParentWriterIdentity: Equatable, Sendable {
  let generation: UUID
  let requestID: UUID?
  let writerEpoch: UInt64
  init(generation: UUID, requestID: UUID?, writerEpoch: UInt64) throws {
    guard !isZeroParentUUID(generation), writerEpoch > 0,
      requestID.map({ !isZeroParentUUID($0) }) ?? true
    else { throw SearchParentWireFailure.invalidIdentity }
    self.generation = generation
    self.requestID = requestID
    self.writerEpoch = writerEpoch
  }
}
struct SearchParentEmissionToken: Equatable, Sendable {
  let writer: SearchParentWriterIdentity
  let sequence: UInt64
}
enum SearchParentWireFailure: Error, Equatable, Sendable {
  case child(SearchChildFailure)
  case wire(SearchWireError)
  case invalidIdentity, invalidChunk, sequenceExhausted
  case concurrentProducer, producerFinished, duplicateConsumer, consumerBusy
  case producerFailure, writeFailure

  fileprivate static func normalized(_ error: Error, fallback: Self) -> Self {
    if let value = error as? Self { return value }
    if let value = error as? SearchChildFailure { return .child(value) }
    if let value = error as? SearchWireError { return .wire(value) }
    return fallback
  }
}
enum SearchParentCodecLaneError: Error, Equatable, Sendable {
  case invalidIdentity, busy, stopped, observerBusy, staleWork
}
struct SearchParentUploadSnapshot {
  enum Slot: Equatable {
    case empty
    case offered(Int)
    case inFlight(Int)
  }
  let slot: Slot
  let currentToken: SearchParentEmissionToken?
  let producerExited: Bool
  let producerEmitActive: Bool
  let consumerStarted: Bool
  let consumerExited: Bool
  let consumerLeaseLive: Bool
  let firstError: SearchParentWireFailure?
  let lastAcknowledged: SearchParentEmissionToken?
  var settled: Bool {
    producerExited && !producerEmitActive && consumerExited && slot == .empty && !consumerLeaseLive
  }
}

/// One writer invocation, one blocking-capable producer, one retained async consumer.
/// Explicit close is cancellation authority; task cancellation is not settlement.
/// The writer closure may capture its connection and compact identity, not an
/// additional source/chunk. Consumer exit does not mean Swift Task deallocation.
final class SearchParentWireUploadBridge: @unchecked Sendable {
  private struct Slot {
    let token: SearchParentEmissionToken
    let bytes: Data
    var inFlight: Bool
  }
  private struct Retirement {
    let token: SearchParentEmissionToken
    let count: Int
  }
  private final class Lease {
    let token: SearchParentEmissionToken
    var bytes: Data?
    private let released: () -> Void
    init(token: SearchParentEmissionToken, bytes: Data, released: @escaping () -> Void) {
      self.token = token
      self.bytes = bytes
      self.released = released
    }
    deinit {
      bytes = nil
      released()
    }
  }
  private typealias Next = CheckedContinuation<SearchParentEmissionToken?, Error>
  private let identity: SearchParentWriterIdentity
  private let observeWriteScopeExit: (@Sendable (SearchParentEmissionToken) -> Void)?
  private let condition = NSCondition()
  private var slot: Slot?
  private var retiring: Retirement?
  private var sequence: UInt64 = 0
  private var acknowledged: SearchParentEmissionToken?
  private var firstError: SearchParentWireFailure?
  private var emitting = false
  private var producerDone = false
  private var consumerStarted = false
  private var consumerDone = false
  private var leaseToken: SearchParentEmissionToken?
  private var waiter: Next?

  init(
    identity: SearchParentWriterIdentity,
    observeWriteScopeExit: (@Sendable (SearchParentEmissionToken) -> Void)? = nil
  ) {
    self.identity = identity
    self.observeWriteScopeExit = observeWriteScopeExit
  }

  var snapshot: SearchParentUploadSnapshot {
    condition.lock()
    defer { condition.unlock() }
    let state: SearchParentUploadSnapshot.Slot =
      slot.map {
        $0.inFlight ? .inFlight($0.bytes.count) : .offered($0.bytes.count)
      } ?? retiring.map { .inFlight($0.count) } ?? .empty
    return SearchParentUploadSnapshot(
      slot: state, currentToken: slot?.token ?? retiring?.token,
      producerExited: producerDone, producerEmitActive: emitting,
      consumerStarted: consumerStarted, consumerExited: consumerDone,
      consumerLeaseLive: leaseToken != nil, firstError: firstError, lastAcknowledged: acknowledged)
  }

  func emit(_ bytes: Data) throws {
    guard (1...65_536).contains(bytes.count) else {
      close(.invalidChunk)
      throw snapshot.firstError ?? .invalidChunk
    }
    condition.lock()
    if let error = firstError {
      condition.unlock()
      throw error
    }
    guard !producerDone else {
      condition.unlock()
      throw SearchParentWireFailure.producerFinished
    }
    guard !emitting else {
      condition.unlock()
      close(.concurrentProducer)
      throw snapshot.firstError ?? .concurrentProducer
    }
    emitting = true
    condition.unlock()
    defer {
      condition.lock()
      emitting = false
      condition.broadcast()
      condition.unlock()
    }
    condition.lock()
    // Never admit another offered chunk while the prior slot is owned.
    while (slot != nil || retiring != nil) && firstError == nil { condition.wait() }
    if let error = firstError {
      condition.unlock()
      throw error
    }
    guard sequence < UInt64.max else {
      condition.unlock()
      close(.sequenceExhausted)
      throw snapshot.firstError ?? .sequenceExhausted
    }
    sequence += 1
    let token = SearchParentEmissionToken(writer: identity, sequence: sequence)
    slot = Slot(token: token, bytes: bytes, inFlight: false)
    let pending = waiter
    waiter = nil
    condition.unlock()
    if let pending { deliverNext(pending) }
    condition.lock()
    while firstError == nil && acknowledged != token { condition.wait() }
    let accepted = acknowledged == token
    let failure = firstError
    condition.unlock()
    if !accepted, let failure { throw failure }
  }

  func close(_ error: SearchParentWireFailure) {
    let completion = retireForClose(error)
    if let token = completion.0 {
      condition.lock()
      if retiring?.token == token { retiring = nil }
      condition.broadcast()
      condition.unlock()
    }
    completion.1?.resume(throwing: completion.2)
  }

  /// Returns metadata only, after any detached payload has left this helper.
  /// A concurrent close never clears another resolver's retirement sentinel.
  private func retireForClose(_ error: SearchParentWireFailure)
    -> (SearchParentEmissionToken?, Next?, SearchParentWireFailure)
  {
    condition.lock()
    if firstError == nil { firstError = error }
    let outcome = firstError!
    var retired = slot
    let token = retired?.token
    if let token {
      retiring = Retirement(token: token, count: retired!.bytes.count)
    }
    slot = nil
    let pending = waiter
    waiter = nil
    condition.broadcast()
    condition.unlock()
    // Deallocation may reenter close/snapshot; retain metadata until it returns.
    withExtendedLifetime(retired) {}
    retired = nil
    return (token, pending, outcome)
  }

  /// The owner calls this after Work.value confirms the source-bearing job/body
  /// has exited, never from the tail of a still-running codec body.
  func producerExited(_ result: Result<Void, Error>) {
    condition.lock()
    guard !producerDone else {
      condition.unlock()
      return
    }
    producerDone = true
    if firstError == nil {
      if case .failure(let error) = result {
        firstError = .normalized(error, fallback: .producerFailure)
      } else if slot != nil || retiring != nil || emitting {
        firstError = .producerFinished
      }
    }
    let failure = firstError
    let pending = failure == nil ? waiter : nil
    if pending != nil { waiter = nil }
    condition.broadcast()
    condition.unlock()
    if let failure { close(failure) }
    if let pending { deliverNext(pending) }
  }

  func consume(write: @escaping @Sendable (Data) async throws -> Void) async throws {
    try startConsumer()
    defer { finishConsumer() }
    while let completion = try await writeOne(write: write) {
      // Metadata only; callbacks must return promptly and never retain payload.
      observeWriteScopeExit?(completion.0)
      if !acknowledge(completion.0, result: completion.1) {
        if let error = snapshot.firstError { throw error }
        close(.consumerBusy)
        throw SearchParentWireFailure.consumerBusy
      }
      if case .failure(let error) = completion.1 { throw error }
    }
  }

  /// No payload-bearing value leaves this scope. In particular the caller never
  /// holds the lease while acknowledging and permitting the next producer chunk.
  private func writeOne(write: @Sendable (Data) async throws -> Void) async throws
    -> (SearchParentEmissionToken, Result<Void, SearchParentWireFailure>)?
  {
    guard let token = try await next() else { return nil }
    var lease: Lease? = try makeLease(token)
    let result = await performWrite(lease!, write: write)
    lease = nil  // deinit receipt runs without holding the condition.
    return (token, result)
  }

  /// The Data argument and any thrown arbitrary Error leave this inner scope
  /// before the outer helper releases its lease and publishes the receipt.
  private func performWrite(_ lease: Lease, write: @Sendable (Data) async throws -> Void) async
    -> Result<Void, SearchParentWireFailure>
  {
    if let error = snapshot.firstError {
      return .failure(error)
    }
    do {
      try await write(lease.bytes!)
      return .success(())
    } catch { return .failure(.normalized(error, fallback: .writeFailure)) }
  }

  @discardableResult
  func acknowledge(
    _ token: SearchParentEmissionToken,
    result: Result<Void, SearchParentWireFailure>
  ) -> Bool {
    guard retireForAcknowledgement(token) else { return false }
    condition.lock()
    guard retiring?.token == token else {
      condition.unlock()
      return false
    }
    retiring = nil
    let accepted = firstError == nil
    if accepted {
      switch result {
      case .success: acknowledged = token
      case .failure(let error): firstError = error
      }
    }
    condition.broadcast()
    condition.unlock()
    return accepted
  }

  /// Scope ends before acknowledgement can publish or wake the producer.
  private func retireForAcknowledgement(_ token: SearchParentEmissionToken) -> Bool {
    condition.lock()
    guard firstError == nil, slot?.inFlight == true, slot?.token == token,
      leaseToken == nil, retiring == nil
    else {
      condition.unlock()
      return false
    }
    var retired = slot
    retiring = Retirement(token: token, count: retired!.bytes.count)
    slot = nil
    condition.unlock()
    withExtendedLifetime(retired) {}
    retired = nil
    return true
  }

  private func startConsumer() throws {
    condition.lock()
    defer { condition.unlock() }
    guard !consumerStarted else { throw SearchParentWireFailure.duplicateConsumer }
    consumerStarted = true
  }
  private func finishConsumer() {
    condition.lock()
    consumerDone = true
    condition.broadcast()
    condition.unlock()
  }
  private func next() async throws -> SearchParentEmissionToken? {
    try await withCheckedThrowingContinuation { deliverNext($0) }
  }
  private func deliverNext(_ continuation: Next) {
    condition.lock()
    if let error = firstError {
      condition.unlock()
      continuation.resume(throwing: error)
      return
    }
    if slot?.inFlight == false {
      let token = slot!.token
      slot!.inFlight = true
      leaseToken = token
      condition.unlock()
      // The resumed continuation owns no payload/lease and cannot prolong one.
      continuation.resume(returning: token)
      return
    }
    if producerDone && slot == nil && retiring == nil {
      condition.unlock()
      continuation.resume(returning: nil)
      return
    }
    guard waiter == nil, slot == nil, retiring == nil else {
      condition.unlock()
      continuation.resume(throwing: SearchParentWireFailure.consumerBusy)
      return
    }
    waiter = continuation
    condition.unlock()
  }
  private func makeLease(_ token: SearchParentEmissionToken) throws -> Lease {
    condition.lock()
    if let error = firstError {
      if leaseToken == token { leaseToken = nil }
      condition.unlock()
      throw error
    }
    guard slot?.token == token, slot?.inFlight == true, leaseToken == token else {
      condition.unlock()
      throw SearchParentWireFailure.consumerBusy
    }
    let bytes = slot!.bytes
    condition.unlock()
    return Lease(token: token, bytes: bytes) { [weak self] in self?.released(token) }
  }
  private func released(_ token: SearchParentEmissionToken) {
    condition.lock()
    if leaseToken == token { leaseToken = nil }
    condition.unlock()
  }
}

struct SearchParentCodecToken: Equatable, Sendable {
  let generation: UUID
  let sessionEpoch: UInt64
  let operationID: UUID
  init(generation: UUID, sessionEpoch: UInt64, operationID: UUID) throws {
    guard !isZeroParentUUID(generation), !isZeroParentUUID(operationID), sessionEpoch > 0 else {
      throw SearchParentCodecLaneError.invalidIdentity
    }
    self.generation = generation
    self.sessionEpoch = sessionEpoch
    self.operationID = operationID
  }
}
struct SearchParentCodecLaneSnapshot: Equatable {
  let busy: Bool
  let stopping: Bool
  /// Final loop branch entered after admitted work released; not a pthread join.
  let loopStopped: Bool
}

/// Single-use internal coordinator receipt. Cancelling value's task leaves its
/// observer attached until completion; this is not the later UI waiter API.
final class SearchParentCodecWork<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<T, Error>?
  private var waiter: CheckedContinuation<T, Error>?
  private var consumed = false
  fileprivate init() {}
  var hasObserver: Bool {
    lock.lock()
    defer { lock.unlock() }
    return waiter != nil
  }
  func value() async throws -> T {
    try await withCheckedThrowingContinuation { install($0) }
  }
  private func install(_ continuation: CheckedContinuation<T, Error>) {
    lock.lock()
    guard !consumed else {
      lock.unlock()
      continuation.resume(throwing: SearchParentCodecLaneError.staleWork)
      return
    }
    guard waiter == nil else {
      lock.unlock()
      continuation.resume(throwing: SearchParentCodecLaneError.observerBusy)
      return
    }
    if let completed = result {
      result = nil
      consumed = true
      lock.unlock()
      continuation.resume(with: completed)
    } else {
      waiter = continuation
      lock.unlock()
    }
  }
  fileprivate func finish(_ completed: Result<T, Error>) {
    lock.lock()
    let continuation = waiter
    waiter = nil
    if continuation != nil { consumed = true } else { result = completed }
    lock.unlock()
    continuation?.resume(with: completed)
  }
}

/// One retained blocking-capable thread; never an active plus queued source job.
final class SearchParentCodecLane: @unchecked Sendable {
  private final class State: @unchecked Sendable {
    struct Job {
      let token: SearchParentCodecToken
      let run: () -> (() -> Void)
    }
    let condition = NSCondition()
    var job: Job?
    var active: SearchParentCodecToken?
    var stopping = false
    var exited = false
    var stopWaiter: CheckedContinuation<Void, Error>?
    func requestStop() {
      condition.lock()
      stopping = true
      condition.broadcast()
      condition.unlock()
    }
    func loop() {
      while true {
        condition.lock()
        while job == nil && !stopping { condition.wait() }
        if job == nil && stopping {
          exited = true
          let waiter = stopWaiter
          stopWaiter = nil
          condition.unlock()
          waiter?.resume()
          return
        }
        var work = job
        job = nil
        active = work!.token
        condition.unlock()
        var completion: (() -> Void)? = autoreleasepool {
          let result = work!.run()
          work = nil
          return result
        }
        condition.lock()
        active = nil
        condition.unlock()
        completion?()
        completion = nil
      }
    }
  }
  private let state: State
  private let thread: Thread
  init() {
    let state = State()
    self.state = state
    thread = Thread { state.loop() }
    thread.name = "TheOnlyPad.search-parent-codec"
    thread.start()
  }
  deinit { state.requestStop() }
  var snapshot: SearchParentCodecLaneSnapshot {
    state.condition.lock()
    defer { state.condition.unlock() }
    return SearchParentCodecLaneSnapshot(
      busy: state.job != nil || state.active != nil,
      stopping: state.stopping, loopStopped: state.exited)
  }
  func submit<T>(token: SearchParentCodecToken, _ body: @escaping @Sendable () throws -> T) throws
    -> SearchParentCodecWork<T>
  {
    let receipt = SearchParentCodecWork<T>()
    let job = State.Job(token: token) {
      let result = Result { try body() }
      return { receipt.finish(result) }
    }
    state.condition.lock()
    guard !state.stopping else {
      state.condition.unlock()
      throw SearchParentCodecLaneError.stopped
    }
    guard state.job == nil, state.active == nil else {
      state.condition.unlock()
      throw SearchParentCodecLaneError.busy
    }
    state.job = job
    state.condition.signal()
    state.condition.unlock()
    return receipt
  }
  func requestStop() { state.requestStop() }
  func waitForStop() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      state.condition.lock()
      if state.exited {
        state.condition.unlock()
        continuation.resume()
        return
      }
      guard state.stopWaiter == nil else {
        state.condition.unlock()
        continuation.resume(throwing: SearchParentCodecLaneError.observerBusy)
        return
      }
      state.stopWaiter = continuation
      state.condition.unlock()
    }
  }
}

private func isZeroParentUUID(_ uuid: UUID) -> Bool {
  uuid == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
