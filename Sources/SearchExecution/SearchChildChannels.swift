import Darwin
import Dispatch
import Foundation

// These seams report one syscall, including the errno captured at that syscall.
enum ChannelIOResult: Equatable {
  case count(Int)
  case failed(Int32)
}
enum ChannelSourceKind: Hashable { case responseRead, requestWrite }
enum ChannelObservation {
  case turn(Int, Int)
  case readAdmitted
  case writeAdmitted(Int)
  case closing, closed
}
protocol ChannelDescriptorOperations: Sendable {
  func read(fd: Int32, into: UnsafeMutableRawBufferPointer) -> ChannelIOResult
  func write(fd: Int32, from: UnsafeRawBufferPointer) -> ChannelIOResult
  /// Zero confirms closure. Any errno leaves ownership uncertain; never retry the integer.
  func close(fd: Int32) -> Int32
}
protocol ChannelReadinessSource: AnyObject, Sendable {
  func activate()
  func suspend()
  func resume()
  func cancel()
}
protocol ChannelSourceFactory: Sendable {
  /// Both callbacks must run on queue; cancellation acknowledges all descriptor use by the source.
  func make(
    kind: ChannelSourceKind, fd: Int32, queue: DispatchQueue,
    event: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void
  ) -> any ChannelReadinessSource
}

/// Adopts three distinct, exclusively owned parent pipe endpoints above descriptor 3.
/// The caller must establish CLOEXEC on all three, O_NONBLOCK on the data endpoints,
/// and verified per-descriptor NOSIGPIPE on the request writer before adoption.
/// The injected queue must be serial. This implementation does not set flags,
/// create pipes, or launch children. Its default Darwin/Dispatch adapters are local
/// plumbing only; launcher routing remains outside this boundary.
final class SearchChildChannels: SearchChildConnection, @unchecked Sendable {
  private let core: ChannelCore

  /// Internal default construction after a future owner has established every
  /// descriptor precondition documented below. This slice does not adopt it from
  /// lifecycle code; direct-pipe tests exercise it with exclusive synthetic ends.
  convenience init(requestWriteFD: Int32, responseReadFD: Int32, lifetimeWriteFD: Int32) {
    self.init(
      requestWriteFD: requestWriteFD, responseReadFD: responseReadFD,
      lifetimeWriteFD: lifetimeWriteFD, operations: DarwinChannelDescriptorOperations(),
      sources: DispatchChannelSourceFactory(), queue: DispatchQueue(label: "SearchChildChannels.io"))
  }

  init(
    requestWriteFD: Int32, responseReadFD: Int32, lifetimeWriteFD: Int32,
    operations: any ChannelDescriptorOperations, sources: any ChannelSourceFactory,
    queue: DispatchQueue = DispatchQueue(label: "SearchChildChannels.io"),
    observe: (@Sendable (ChannelObservation) -> Void)? = nil
  ) {
    precondition(Set([requestWriteFD, responseReadFD, lifetimeWriteFD]).count == 3)
    precondition(min(requestWriteFD, responseReadFD, lifetimeWriteFD) > 3)
    core = ChannelCore(
      request: requestWriteFD, response: responseReadFD, lifetime: lifetimeWriteFD,
      operations: operations, sources: sources, queue: queue, observe: observe)
    core.start()
  }

  deinit { core.requestClose(.shutDown) }

  func write(_ bytes: Data) async throws {
    guard bytes.count <= 65_536 else { throw SearchChildFailure.channelFailure(EINVAL) }
    _ = try await core.perform(ChannelOperation(payload: bytes))
  }

  func read(maxBytes: Int) async throws -> Data {
    guard (1...65_568).contains(maxBytes) else {
      throw SearchChildFailure.channelFailure(EINVAL)
    }
    return try await core.perform(ChannelOperation(readLimit: maxBytes))
  }

  func close() async {
    core.requestClose(.shutDown)
    await core.closeCompletion.value
  }
}

private typealias ChannelResult = Result<Data, SearchChildFailure>
private typealias ChannelContinuation = CheckedContinuation<Data, Error>
private struct ChannelDelivery {
  let continuation: ChannelContinuation
  let result: ChannelResult
  func resume() { continuation.resume(with: result.mapError { $0 as Error }) }
}

private final class ChannelOperation: @unchecked Sendable {
  let readLimit: Int?
  // Payload and offset are only mutated on the I/O queue after admission.
  var payload: Data?
  var offset = 0
  // The core admission lock guards the remaining fields.
  var admitted = false
  var cancelled = false
  var terminal: ChannelResult?
  var continuation: ChannelContinuation?
  init(payload: Data) {
    self.payload = payload
    readLimit = nil
  }
  init(readLimit: Int) { self.readLimit = readLimit }
}

private final class ChannelCloseLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var complete = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { value in
      lock.lock()
      if complete {
        lock.unlock()
        value.resume()
      } else {
        precondition(continuation == nil)
        continuation = value
        lock.unlock()
      }
    }
  }
  func signal() {
    lock.lock()
    complete = true
    let value = continuation
    continuation = nil
    lock.unlock()
    value?.resume()
  }
}

private final class ChannelSourceSlot {
  var descriptor: Int32?
  var source: (any ChannelReadinessSource)?
  var suspended = false
  var cancelling = false
  var confirmed = false
  init(_ descriptor: Int32) { self.descriptor = descriptor }
}

/// Descriptor/source state is confined to queue. Only bounded admission and first-result
/// arbitration cross threads. No lock is held while calling a seam or resuming a caller.
private final class ChannelCore: @unchecked Sendable {
  private let lock = NSLock()
  private var read: ChannelOperation?
  private var writes: [ChannelOperation] = []
  private var closeReason: SearchChildFailure?
  private var eof = false
  private var pumpScheduled = false

  private let queue: DispatchQueue
  private let operations: any ChannelDescriptorOperations
  private let factory: any ChannelSourceFactory
  private let observe: (@Sendable (ChannelObservation) -> Void)?
  private let request: ChannelSourceSlot
  private let response: ChannelSourceSlot
  private var lifetime: Int32?
  private var lifetimeConfirmed = false
  private var readReady = true
  private var writeReady = true
  private var preferRead = true
  private var closing = false
  private var completed = false
  // An uncertain raw close deliberately retains exactly one core without polling/retry.
  private var quarantineOwner: ChannelCore?
  private let latch: ChannelCloseLatch
  let closeCompletion: Task<Void, Never>

  init(
    request: Int32, response: Int32, lifetime: Int32,
    operations: any ChannelDescriptorOperations, sources: any ChannelSourceFactory,
    queue: DispatchQueue, observe: (@Sendable (ChannelObservation) -> Void)?
  ) {
    self.request = ChannelSourceSlot(request)
    self.response = ChannelSourceSlot(response)
    self.lifetime = lifetime
    self.operations = operations
    factory = sources
    self.queue = queue
    self.observe = observe
    let latch = ChannelCloseLatch()
    self.latch = latch
    closeCompletion = Task { await latch.wait() }
  }

  func start() {
    queue.async {
      self.install(self.response, kind: .responseRead)
      self.install(self.request, kind: .requestWrite)
    }
  }

  func perform(_ operation: ChannelOperation) async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        submit(operation, continuation: continuation, alreadyCancelled: Task.isCancelled)
      }
    } onCancel: {
      self.cancel(operation)
    }
  }

  private func submit(
    _ operation: ChannelOperation, continuation: ChannelContinuation, alreadyCancelled: Bool
  ) {
    var rejection: ChannelResult?
    var observation: ChannelObservation?
    lock.lock()
    if alreadyCancelled || operation.cancelled {
      rejection = .failure(.cancelled)
    } else if closeReason != nil {
      rejection = .failure(.shutDown)
    } else if operation.readLimit != nil {
      if read != nil {
        rejection = .failure(.busy)
      } else if eof {
        rejection = .success(Data())
      } else {
        read = operation
        observation = .readAdmitted
      }
    } else if writes.count == 2 {
      rejection = .failure(.busy)
    } else {
      writes.append(operation)
      observation = .writeAdmitted(writes.count)
    }
    if let rejection {
      operation.terminal = rejection
    } else {
      operation.admitted = true
      operation.continuation = continuation
    }
    lock.unlock()
    if let rejection {
      operation.payload = nil
      continuation.resume(with: rejection.mapError { $0 as Error })
    } else {
      if let observation { observe?(observation) }
      schedulePump()
    }
  }

  private func cancel(_ operation: ChannelOperation) {
    lock.lock()
    guard operation.terminal == nil else {
      lock.unlock()
      return
    }
    operation.cancelled = true
    let admitted = operation.admitted
    if admitted {
      operation.terminal = .failure(closeReason ?? .cancelled)
      if closeReason == nil { closeReason = .cancelled }
    }
    lock.unlock()
    if admitted { schedulePump() }
  }

  func requestClose(_ reason: SearchChildFailure) {
    lock.lock()
    if closeReason == nil { closeReason = reason }
    lock.unlock()
    schedulePump()
  }

  private func schedulePump() {
    lock.lock()
    let enqueue = !pumpScheduled
    pumpScheduled = true
    lock.unlock()
    if enqueue { queue.async { self.pump() } }
  }

  private func snapshot() -> (SearchChildFailure?, ChannelOperation?, ChannelOperation?) {
    lock.lock()
    defer { lock.unlock() }
    return (closeReason, read, writes.first)
  }

  private func pump() {
    lock.lock()
    pumpScheduled = false
    lock.unlock()
    var calls = 0
    var steps = 0
    var bytes = 0
    var deliveries: [ChannelDelivery] = []
    while steps < 4 && bytes < 65_536 {
      steps += 1
      let (reason, reader, writer) = snapshot()
      if let reason {
        beginClose(reason)
        break
      }
      let canRead = reader != nil && readReady
      let canWrite = writer != nil && writeReady
      guard canRead || canWrite else { break }
      let isRead = canRead && (!canWrite || preferRead)
      preferRead = !isRead
      guard let operation = isRead ? reader : writer else { break }
      if !isRead, operation.payload?.isEmpty == true {
        finish(operation, result: .success(Data()), deliveries: &deliveries)
        continue
      }
      // Snapshot above is the last queue observation before starting this syscall.
      // Cancellation can win concurrently; its terminal result is checked by finish.
      calls += 1
      if isRead {
        var data = Data(count: min(operation.readLimit!, 65_536 - bytes))
        let result = data.withUnsafeMutableBytes {
          operations.read(fd: response.descriptor!, into: $0)
        }
        switch result {
        case .count(let count) where count >= 0 && count <= data.count:
          bytes += count
          data.count = count
          if count == 0 {
            lock.lock()
            eof = true
            lock.unlock()
            cancelSource(response)
          }
          finish(operation, result: .success(data), deliveries: &deliveries)
        case .failed(EINTR): break
        case .failed(EAGAIN): readReady = false
        case .failed(let error): requestClose(.channelFailure(error))
        default: requestClose(.channelFailure(EIO))
        }
      } else {
        let remaining = operation.payload!.count - operation.offset
        let length = min(remaining, 65_536 - bytes)
        let result = operation.payload!.withUnsafeBytes {
          operations.write(
            fd: request.descriptor!,
            from: UnsafeRawBufferPointer(
              rebasing: $0[operation.offset..<(operation.offset + length)]))
        }
        switch result {
        case .count(let count) where count > 0 && count <= length:
          bytes += count
          operation.offset += count
          if operation.offset == operation.payload!.count {
            finish(operation, result: .success(Data()), deliveries: &deliveries)
          }
        case .failed(EINTR): break
        case .failed(EAGAIN): writeReady = false
        case .failed(let error): requestClose(.channelFailure(error))
        default: requestClose(.channelFailure(EIO))
        }
      }
    }
    let (reason, reader, writer) = snapshot()
    if let reason {
      beginClose(reason)
    } else {
      setInterested(response, reader != nil)
      setInterested(request, writer != nil)
      if (reader != nil && readReady) || (writer != nil && writeReady) { schedulePump() }
    }
    observe?(.turn(calls, bytes))
    for delivery in deliveries { delivery.resume() }
  }

  private func finish(
    _ operation: ChannelOperation, result: ChannelResult, deliveries: inout [ChannelDelivery]
  ) {
    // Release the completed write before freeing its admission slot. Data can carry a
    // custom deallocator, so release it outside the lock as well.
    operation.payload = nil
    lock.lock()
    let chosen = operation.terminal ?? closeReason.map { .failure($0) } ?? result
    operation.terminal = chosen
    if operation.readLimit != nil {
      read = nil
    } else {
      precondition(writes.first === operation)
      writes.removeFirst()
    }
    let continuation = operation.continuation
    operation.continuation = nil
    operation.admitted = false
    lock.unlock()
    if operation.readLimit != nil { readReady = true } else { writeReady = true }
    if let continuation {
      deliveries.append(ChannelDelivery(continuation: continuation, result: chosen))
    }
  }

  private func beginClose(_ reason: SearchChildFailure) {
    guard !closing else { return }
    closing = true
    var deliveries: [ChannelDelivery] = []
    let (_, reader, _) = snapshot()
    if let reader { finish(reader, result: .failure(reason), deliveries: &deliveries) }
    while let writer = snapshot().2 {
      finish(writer, result: .failure(reason), deliveries: &deliveries)
    }
    observe?(.closing)
    if let descriptor = lifetime {
      lifetime = nil
      lifetimeConfirmed = operations.close(fd: descriptor) == 0
      if !lifetimeConfirmed { quarantineOwner = self }
    }
    cancelSource(response)
    cancelSource(request)
    for delivery in deliveries { delivery.resume() }
    confirmClose()
  }

  private func install(_ slot: ChannelSourceSlot, kind: ChannelSourceKind) {
    slot.source = factory.make(
      kind: kind, fd: slot.descriptor!, queue: queue,
      event: { self.ready(slot, kind: kind) },
      cancelled: { self.acknowledge(slot) })
    slot.source!.activate()
    slot.suspended = true
    slot.source!.suspend()
  }

  private func ready(_ slot: ChannelSourceSlot, kind: ChannelSourceKind) {
    guard !slot.cancelling, slot.descriptor != nil else { return }
    if kind == .responseRead { readReady = true } else { writeReady = true }
    schedulePump()
  }

  private func setInterested(_ slot: ChannelSourceSlot, _ interested: Bool) {
    guard !slot.cancelling, let source = slot.source else { return }
    if interested && slot.suspended {
      slot.suspended = false
      source.resume()
    } else if !interested && !slot.suspended {
      slot.suspended = true
      source.suspend()
    }
  }

  private func cancelSource(_ slot: ChannelSourceSlot) {
    guard !slot.cancelling, let source = slot.source else { return }
    slot.cancelling = true
    if slot.suspended {
      slot.suspended = false
      source.resume()
    }
    source.cancel()
  }

  private func acknowledge(_ slot: ChannelSourceSlot) {
    guard slot.cancelling, let descriptor = slot.descriptor else { return }
    // Consume ownership before the external call, including on EINTR or EBADF.
    slot.descriptor = nil
    slot.source = nil
    slot.confirmed = operations.close(fd: descriptor) == 0
    if !slot.confirmed { quarantineOwner = self }
    confirmClose()
  }

  private func confirmClose() {
    guard closing, !completed, request.confirmed, response.confirmed, lifetimeConfirmed else {
      return
    }
    completed = true
    observe?(.closed)
    latch.signal()
  }
}
