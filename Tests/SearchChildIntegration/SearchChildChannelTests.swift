import Darwin
import Dispatch
import Foundation
import XCTest

@testable import SearchExecution

// Injected descriptor/source receipts only: this class never creates or operates OS pipes.
final class SearchChildChannelStateTests: XCTestCase {
  func testShortWriteRequiresRemainingBytesBeforeSuccess() async {
    let h = ChannelHarness()
    h.io.writes = [.count(2), .count(3)]
    let c = h.make()
    let failure = await channelFailure { try await c.write(Data("hello".utf8)) }
    XCTAssertNil(failure)
    XCTAssertEqual(h.io.written, Data("hello".utf8))
    XCTAssertEqual(h.io.writeLengths, [5, 3])
    await c.close()
  }

  func testIdleCloseCancelsSourcesBeforeDescriptorClose() async {
    let h = ChannelHarness()
    let c = h.make()
    await c.close()
    XCTAssertEqual(h.sources.createdCount, 2)
    XCTAssertEqual(h.log.count("cancel.responseRead"), 1)
    XCTAssertEqual(h.log.count("cancel.requestWrite"), 1)
    XCTAssertTrue(h.log.precedes("ack.responseRead", "close.42"))
    XCTAssertTrue(h.log.precedes("ack.requestWrite", "close.41"))
    XCTAssertEqual(h.io.closed.sorted(), [41, 42, 43])
    XCTAssertEqual(h.sources.balances, [0, 0])
  }

  func testLengthsAreValidatedBeforeIOAndEmptyWriteUsesNoSyscall() async {
    let h = ChannelHarness()
    let c = h.make()
    for length in [-1, 0, 65_569] {
      let error = await channelFailure { _ = try await c.read(maxBytes: length) }
      XCTAssertEqual(error, .channelFailure(EINVAL))
    }
    let error = await channelFailure { try await c.write(Data(count: 65_537)) }
    XCTAssertEqual(error, .channelFailure(EINVAL))
    let empty = await channelFailure { try await c.write(Data()) }
    XCTAssertNil(empty)
    XCTAssertEqual(h.io.writeLengths, [])
    XCTAssertEqual(h.io.readLengths, [])
    await c.close()
  }

  func testShortReadCompletesOnceAndEOFIsSticky() async throws {
    let h = ChannelHarness()
    let c = h.make()
    h.io.reads = [.bytes(Data([1, 2])), .bytes(Data())]
    let value = try await c.read(maxBytes: 65_568)
    XCTAssertEqual(value, Data([1, 2]))
    XCTAssertEqual(h.io.readLengths.count, 1)
    let eof = try await c.read(maxBytes: 1)
    XCTAssertTrue(eof.isEmpty)
    await h.barrier()
    let again = try await c.read(maxBytes: 8)
    XCTAssertTrue(again.isEmpty)
    XCTAssertEqual(h.io.readLengths.count, 2)
    await c.close()
    XCTAssertEqual(h.io.closed.filter { $0 == 42 }.count, 1)
  }

  func testEAGAINWaitsForExplicitReadinessThenResumesAtWriteOffset() async {
    let h = ChannelHarness()
    let c = h.make()
    h.io.writes = [.count(2), .failed(EAGAIN), .count(3)]
    let task = Task { await channelFailure { try await c.write(Data("hello".utf8)) } }
    guard await wait(h.log, "write", count: 2) else {
      task.cancel()
      return
    }
    await h.barrier()
    XCTAssertEqual(h.io.written, Data("he".utf8))
    XCTAssertEqual(h.io.writeLengths.count, 2)
    h.sources.fire(.requestWrite)
    let failure = await task.value
    XCTAssertNil(failure)
    XCTAssertEqual(h.io.writeLengths, [5, 3, 3])
    XCTAssertEqual(h.io.written, Data("hello".utf8))
    await c.close()
  }

  func testPendingReadEAGAINWaitsForReadSource() async throws {
    let h = ChannelHarness()
    let c = h.make()
    let task = Task { try await c.read(maxBytes: 8) }
    guard await wait(h.log, "read") else {
      task.cancel()
      return
    }
    await h.barrier()
    XCTAssertEqual(h.io.readLengths, [8])
    h.io.reads = [.bytes(Data([9]))]
    h.sources.fire(.responseRead)
    let value = try await task.value
    XCTAssertEqual(value, Data([9]))
    await c.close()
  }

  func testAdmissionReservesOneReadAndTwoWritesBeforeQueueInstallation() async {
    let h = ChannelHarness()
    h.queue.suspend()
    let c = h.make()
    let first = Task { await channelFailure { try await c.write(Data([1])) } }
    guard await wait(h.log, "writeAdmitted(1)") else {
      h.queue.resume()
      first.cancel()
      return
    }
    let second = Task { await channelFailure { try await c.write(Data([2])) } }
    guard await wait(h.log, "writeAdmitted(2)") else {
      h.queue.resume()
      first.cancel()
      second.cancel()
      return
    }
    let third = await channelFailure { try await c.write(Data([3])) }
    XCTAssertEqual(third, .busy)
    let read = Task { await channelFailure { _ = try await c.read(maxBytes: 1) } }
    guard await wait(h.log, "readAdmitted") else {
      h.queue.resume()
      first.cancel()
      second.cancel()
      read.cancel()
      return
    }
    let anotherRead = await channelFailure { _ = try await c.read(maxBytes: 1) }
    XCTAssertEqual(anotherRead, .busy)
    read.cancel()
    h.queue.resume()
    let errors = await [first.value, second.value, read.value]
    XCTAssertEqual(errors, [.cancelled, .cancelled, .cancelled])
    XCTAssertTrue(h.io.writeLengths.isEmpty && h.io.readLengths.isEmpty)
    await c.close()
  }

  func testQueuedWriteStaysBehindBlockedActiveWrite() async {
    let h = ChannelHarness()
    let c = h.make()
    h.io.writes = [.count(1), .failed(EAGAIN)]
    let first = Task { await channelFailure { try await c.write(Data([1, 2])) } }
    guard await wait(h.log, "write", count: 2) else {
      first.cancel()
      return
    }
    let second = Task { await channelFailure { try await c.write(Data([3])) } }
    guard await wait(h.log, "writeAdmitted(2)") else {
      first.cancel()
      second.cancel()
      return
    }
    let excess = await channelFailure { try await c.write(Data([4])) }
    XCTAssertEqual(excess, .busy)
    await h.barrier()
    XCTAssertEqual(h.io.written, Data([1]))
    h.io.writes = [.count(1), .count(1)]
    h.sources.fire(.requestWrite)
    let errors = await [first.value, second.value]
    XCTAssertEqual(errors, [nil, nil])
    XCTAssertEqual(h.io.written, Data([1, 2, 3]))
    await c.close()
  }

  func testReadEINTRRetriesAndFatalReadSettlesBlockedWrite() async {
    let h = ChannelHarness()
    let c = h.make()
    let writer = Task { await channelFailure { try await c.write(Data([1])) } }
    guard await wait(h.log, "write") else {
      writer.cancel()
      return
    }
    h.io.reads = [.failed(EINTR), .failed(EIO)]
    let failed = await channelFailure { _ = try await c.read(maxBytes: 1) }
    XCTAssertEqual(failed, .channelFailure(EIO))
    let writeFailure = await writer.value
    XCTAssertEqual(writeFailure, .channelFailure(EIO))
    XCTAssertEqual(h.io.readLengths, [1, 1])
    await c.close()
  }

  func testInFlightPartialWriteCannotReportSuccessAfterCancellationWins() async {
    let h = ChannelHarness()
    let c = h.make()
    let release = DispatchSemaphore(value: 0)
    h.io.writeHook = {
      h.log.record("inflight")
      if release.wait(timeout: .now() + 2) == .timedOut { h.log.record("gate-timeout") }
    }
    h.io.writes = [.count(2), .count(3)]
    let task = Task { await channelFailure { try await c.write(Data("hello".utf8)) } }
    guard await wait(h.log, "inflight") else {
      release.signal()
      task.cancel()
      return
    }
    task.cancel()
    release.signal()
    let failure = await task.value
    XCTAssertEqual(failure, .cancelled)
    XCTAssertEqual(h.io.written, Data("he".utf8))
    XCTAssertEqual(h.io.writeLengths, [5])
    XCTAssertEqual(h.log.count("gate-timeout"), 0)
    await c.close()
  }

  func testAlreadyCancelledTaskDoesNotCloseHealthyConnection() async {
    let h = ChannelHarness()
    let c = h.make()
    let begin = ChannelGate()
    let task = Task {
      await begin.wait()
      return await channelFailure { try await c.write(Data([1])) }
    }
    task.cancel()
    begin.open()
    let failure = await task.value
    XCTAssertEqual(failure, .cancelled)
    XCTAssertEqual(h.log.count("closing"), 0)
    h.io.writes = [.count(1)]
    let next = await channelFailure { try await c.write(Data([2])) }
    XCTAssertNil(next)
    await c.close()
  }

  func testLateCancellationBeforeSelectedSuccessIsDeliveredDoesNotCloseConnection() async {
    let h = ChannelHarness()
    let c = h.make()
    let release = DispatchSemaphore(value: 0)
    h.turns.hook = { _, bytes in
      guard bytes == 1 else { return }
      h.log.record("success-selected-before-delivery")
      if release.wait(timeout: .now() + 2) == .timedOut { h.log.record("gate-timeout") }
    }
    h.io.writes = [.count(1), .count(1)]
    let task = Task { await channelFailure { try await c.write(Data([1])) } }
    guard await wait(h.log, "success-selected-before-delivery") else {
      h.turns.hook = nil
      release.signal()
      task.cancel()
      return
    }
    // The turn observation runs after finish detached the slot, but before its
    // continuation is delivered. The caller's cancellation handler is still installed.
    task.cancel()
    h.turns.hook = nil
    release.signal()
    let first = await task.value
    XCTAssertNil(first)
    let next = await channelFailure { try await c.write(Data([2])) }
    XCTAssertNil(next)
    XCTAssertEqual(h.io.written, Data([1, 2]))
    XCTAssertEqual(h.log.count("closing"), 0)
    XCTAssertEqual(h.log.count("gate-timeout"), 0)
    await c.close()
  }

  func testInFlightReadCannotReportDataAfterCancellationWins() async {
    let h = ChannelHarness()
    let c = h.make()
    let writer = Task { await channelFailure { try await c.write(Data([1])) } }
    guard await wait(h.log, "write") else {
      writer.cancel()
      return
    }
    let release = DispatchSemaphore(value: 0)
    h.io.readHook = {
      h.log.record("read-inflight")
      if release.wait(timeout: .now() + 2) == .timedOut { h.log.record("gate-timeout") }
    }
    h.io.reads = [.bytes(Data([7, 8]))]
    let reader = Task { await channelFailure { _ = try await c.read(maxBytes: 8) } }
    guard await wait(h.log, "read-inflight") else {
      h.io.readHook = nil
      release.signal()
      reader.cancel()
      writer.cancel()
      return
    }
    reader.cancel()
    h.io.readHook = nil
    release.signal()
    let readFailure = await reader.value
    let writeFailure = await writer.value
    XCTAssertEqual(readFailure, .cancelled)
    XCTAssertEqual(writeFailure, .cancelled)
    XCTAssertEqual(h.io.readLengths, [8])
    XCTAssertEqual(h.io.writeLengths, [1])
    XCTAssertEqual(h.log.count("gate-timeout"), 0)
    await c.close()
    XCTAssertEqual(h.io.closed.sorted(), [41, 42, 43])
  }

  func testLateCancellationAfterCompletedWriteDoesNotCloseConnection() async {
    let h = ChannelHarness()
    let c = h.make()
    h.io.writes = [.count(1), .count(1)]
    let task = Task { await channelFailure { try await c.write(Data([1])) } }
    let first = await task.value
    XCTAssertNil(first)
    task.cancel()
    let second = await channelFailure { try await c.write(Data([2])) }
    XCTAssertNil(second)
    XCTAssertEqual(h.log.count("closing"), 0)
    await c.close()
  }

  func testFatalWriteAndZeroWriteCloseAllAdmittedWork() async {
    for result in [ChannelIOResult.failed(EPIPE), .count(0)] {
      let h = ChannelHarness()
      let c = h.make()
      let pending = Task { await channelFailure { _ = try await c.read(maxBytes: 1) } }
      guard await wait(h.log, "read") else {
        pending.cancel()
        return
      }
      h.io.writes = [result]
      let failed = await channelFailure { try await c.write(Data([1])) }
      let expected: SearchChildFailure =
        result == .count(0) ? .channelFailure(EIO) : .channelFailure(EPIPE)
      XCTAssertEqual(failed, expected)
      let readFailure = await pending.value
      XCTAssertEqual(readFailure, expected)
      await c.close()
      XCTAssertEqual(h.io.closed.sorted(), [41, 42, 43])
    }
  }

  func testEINTRAndByteBudgetsYieldWithBoundedWork() async {
    let h = ChannelHarness()
    let c = h.make()
    h.io.writes = Array(repeating: .failed(EINTR), count: 9) + [.count(65_536)]
    let failure = await channelFailure { try await c.write(Data(count: 65_536)) }
    XCTAssertNil(failure)
    let turns = h.turns.values
    XCTAssertGreaterThanOrEqual(turns.count, 3)
    XCTAssertTrue(turns.allSatisfy { $0.0 <= 4 && $0.1 <= 65_536 })
    XCTAssertEqual(h.io.writeLengths.count, 10)
    await c.close()
  }

  func testCloseWaitsForBothCancelAcknowledgmentsAndJoinsOneCompletion() async {
    let h = ChannelHarness()
    h.sources.holdCancellation = true
    let c = h.make()
    let first = Task {
      await c.close()
      h.log.record("first-returned")
    }
    let second = Task {
      await c.close()
      h.log.record("second-returned")
    }
    guard await wait(h.log, "cancel.requestWrite") else { return }
    await h.barrier()
    XCTAssertEqual(h.io.closed, [43])
    XCTAssertEqual(h.log.count("closed"), 0)
    h.sources.acknowledge(.responseRead)
    await h.barrier()
    XCTAssertEqual(h.io.closed.sorted(), [42, 43])
    XCTAssertEqual(h.log.count("closed"), 0)
    h.sources.acknowledge(.requestWrite)
    await first.value
    await second.value
    XCTAssertEqual(h.log.count("closing"), 1)
    XCTAssertEqual(h.log.count("closed"), 1)
    XCTAssertTrue(h.log.precedes("ack.requestWrite", "first-returned"))
    XCTAssertEqual(h.sources.balances, [0, 0])
    await c.close()
    XCTAssertEqual(h.io.closed.sorted(), [41, 42, 43])
  }

  func testUncertainCloseIsQuarantinedWithoutRetryOrSuccess() async {
    for error in [EINTR, EBADF] {
      let h = ChannelHarness()
      h.io.closeErrors = [41: error]
      let c = h.make()
      let close = Task {
        await c.close()
        h.log.record("unexpected-return")
      }
      guard await wait(h.log, "close.41") else { return }
      await h.barrier()
      h.sources.fire(.requestWrite)
      h.sources.fire(.responseRead)
      let repeated = Task {
        await c.close()
        h.log.record("unexpected-return")
      }
      await h.barrier()
      XCTAssertEqual(h.io.closed.sorted(), [41, 42, 43])
      XCTAssertEqual(h.log.count("closed"), 0)
      let returned = h.log.expectation("unexpected-return")
      returned.isInverted = true
      await fulfillment(of: [returned], timeout: 0.05)
      close.cancel()
      repeated.cancel()
      // Deliberately unacknowledged fake quarantine: no kernel descriptors or retries exist.
    }
  }

  func testFacadeLossRetainsCloseAndStaleHandlersCannotUseConsumedFD() async {
    let h = ChannelHarness()
    var c: SearchChildChannels? = h.make()
    weak var weakFacade = c
    await h.barrier()
    c = nil
    XCTAssertNil(weakFacade)
    guard await wait(h.log, "closed") else { return }
    let old = h.io.closed
    h.sources.fire(.requestWrite)
    h.sources.fire(.responseRead)
    await h.barrier()
    XCTAssertEqual(h.io.closed, old)
    XCTAssertEqual(old.sorted(), [41, 42, 43])
    XCTAssertTrue(h.io.readLengths.isEmpty && h.io.writeLengths.isEmpty)
  }

  func testContinuationCanImmediatelyReenterAndClosedCallsRefuse() async {
    let h = ChannelHarness()
    let c = h.make()
    h.io.writes = [.count(1), .count(1)]
    let failure = await channelFailure {
      try await c.write(Data([1]))
      try await c.write(Data([2]))
    }
    XCTAssertNil(failure)
    XCTAssertEqual(h.io.written, Data([1, 2]))
    await c.close()
    let write = await channelFailure { try await c.write(Data([3])) }
    let read = await channelFailure { _ = try await c.read(maxBytes: 1) }
    XCTAssertEqual(write, .shutDown)
    XCTAssertEqual(read, .shutDown)
  }

  private func wait(_ log: ChannelLog, _ event: String, count: Int = 1) async -> Bool {
    let result = await XCTWaiter.fulfillment(of: [log.expectation(event, count: count)], timeout: 2)
    XCTAssertEqual(result, .completed, "Missing injected boundary: \(event)")
    return result == .completed
  }
}

private func channelFailure(_ operation: () async throws -> Void) async -> SearchChildFailure? {
  do {
    try await operation()
    return nil
  } catch let failure as SearchChildFailure { return failure } catch {
    XCTFail("Unexpected error type: \(type(of: error))")
    return .channelFailure(EIO)
  }
}

private final class ChannelLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  private var waiters: [(String, Int, XCTestExpectation)] = []
  func record(_ event: String) {
    lock.lock()
    precondition(events.count < 1024, "Injected event log overflow")
    events.append(event)
    let ready = waiters.filter { name, count, _ in events.filter { $0 == name }.count >= count }
    waiters.removeAll { item in ready.contains { $0.2 === item.2 } }
    lock.unlock()
    for item in ready { item.2.fulfill() }
  }
  func count(_ event: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return events.filter { $0 == event }.count
  }
  func precedes(_ first: String, _ last: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let a = events.firstIndex(of: first), let b = events.firstIndex(of: last) else {
      return false
    }
    return a < b
  }
  func expectation(_ event: String, count: Int = 1) -> XCTestExpectation {
    let result = XCTestExpectation(description: event)
    lock.lock()
    let ready = events.filter { $0 == event }.count >= count
    if !ready { waiters.append((event, count, result)) }
    lock.unlock()
    if ready { result.fulfill() }
    return result
  }
}
private final class ChannelTurns: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [(Int, Int)] = []
  private var callback: (@Sendable (Int, Int) -> Void)?
  var hook: (@Sendable (Int, Int) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return callback
    }
    set {
      lock.lock()
      callback = newValue
      lock.unlock()
    }
  }
  var values: [(Int, Int)] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func add(_ syscalls: Int, _ bytes: Int) {
    lock.lock()
    precondition(storage.count < 512)
    storage.append((syscalls, bytes))
    let action = callback
    lock.unlock()
    action?(syscalls, bytes)
  }
}
private final class ChannelGate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { value in
      lock.lock()
      if opened {
        lock.unlock()
        value.resume()
      } else {
        continuation = value
        lock.unlock()
      }
    }
  }
  func open() {
    lock.lock()
    opened = true
    let value = continuation
    continuation = nil
    lock.unlock()
    value?.resume()
  }
}
private final class ChannelHarness: @unchecked Sendable {
  let queue = DispatchQueue(label: "channel.injected.tests")
  let log: ChannelLog
  let turns = ChannelTurns()
  let io: ChannelFakeIO
  let sources: ChannelFakeSources
  init() {
    let log = ChannelLog()
    self.log = log
    io = ChannelFakeIO(log: log)
    sources = ChannelFakeSources(log: log)
  }
  func make() -> SearchChildChannels {
    let log = log
    let turns = turns
    return SearchChildChannels(
      requestWriteFD: 41, responseReadFD: 42, lifetimeWriteFD: 43,
      operations: io, sources: sources, queue: queue,
      observe: {
        if case .turn(let calls, let bytes) = $0 {
          turns.add(calls, bytes)
        } else {
          log.record(String(describing: $0))
        }
      })
  }
  func barrier() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }
}

private final class ChannelFakeIO: ChannelDescriptorOperations, @unchecked Sendable {
  enum Read {
    case bytes(Data)
    case failed(Int32)
  }
  private let lock = NSLock()
  private let log: ChannelLog
  private var writeStorage: [ChannelIOResult] = []
  private var readStorage: [Read] = []
  private var output = Data()
  private var writeSizes: [Int] = []
  private var readSizes: [Int] = []
  private var closedFDs: [Int32] = []
  private var closeStorage: [Int32: Int32] = [:]
  private var hook: (@Sendable () -> Void)?
  private var readCallback: (@Sendable () -> Void)?
  init(log: ChannelLog) { self.log = log }
  var writes: [ChannelIOResult] {
    get {
      lock.lock()
      defer { lock.unlock() }
      return writeStorage
    }
    set {
      lock.lock()
      writeStorage = newValue
      lock.unlock()
    }
  }
  var reads: [Read] {
    get {
      lock.lock()
      defer { lock.unlock() }
      return readStorage
    }
    set {
      lock.lock()
      readStorage = newValue
      lock.unlock()
    }
  }
  var closeErrors: [Int32: Int32] {
    get {
      lock.lock()
      defer { lock.unlock() }
      return closeStorage
    }
    set {
      lock.lock()
      closeStorage = newValue
      lock.unlock()
    }
  }
  var writeHook: (@Sendable () -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return hook
    }
    set {
      lock.lock()
      hook = newValue
      lock.unlock()
    }
  }
  var readHook: (@Sendable () -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return readCallback
    }
    set {
      lock.lock()
      readCallback = newValue
      lock.unlock()
    }
  }
  var written: Data {
    lock.lock()
    defer { lock.unlock() }
    return output
  }
  var writeLengths: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return writeSizes
  }
  var readLengths: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return readSizes
  }
  var closed: [Int32] {
    lock.lock()
    defer { lock.unlock() }
    return closedFDs
  }
  func read(fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> ChannelIOResult {
    lock.lock()
    precondition(readSizes.count < 512)
    readSizes.append(buffer.count)
    let next = readStorage.isEmpty ? Read.failed(EAGAIN) : readStorage.removeFirst()
    let callback = readCallback
    lock.unlock()
    callback?()
    log.record("read")
    switch next {
    case .failed(let error): return .failed(error)
    case .bytes(let value):
      precondition(value.count <= buffer.count)
      value.copyBytes(to: buffer)
      return .count(value.count)
    }
  }
  func write(fd: Int32, from buffer: UnsafeRawBufferPointer) -> ChannelIOResult {
    lock.lock()
    precondition(writeSizes.count < 512)
    writeSizes.append(buffer.count)
    let result = writeStorage.isEmpty ? ChannelIOResult.failed(EAGAIN) : writeStorage.removeFirst()
    let callback = hook
    lock.unlock()
    callback?()
    lock.lock()
    if case .count(let count) = result, count > 0, count <= buffer.count {
      output.append(contentsOf: buffer.prefix(count))
    }
    lock.unlock()
    log.record("write")
    return result
  }
  func close(fd: Int32) -> Int32 {
    lock.lock()
    precondition(closedFDs.count < 512)
    closedFDs.append(fd)
    let error = closeStorage[fd] ?? 0
    lock.unlock()
    log.record("close.\(fd)")
    return error
  }
}
private final class ChannelFakeSources: ChannelSourceFactory, @unchecked Sendable {
  private let lock = NSLock()
  private let log: ChannelLog
  private var values: [ChannelSourceKind: ChannelFakeSource] = [:]
  private var hold = false
  var holdCancellation: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return hold
    }
    set {
      lock.lock()
      precondition(values.isEmpty)
      hold = newValue
      lock.unlock()
    }
  }
  init(log: ChannelLog) { self.log = log }
  var createdCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
  var balances: [Int] {
    lock.lock()
    let sources = Array(values.values)
    lock.unlock()
    return sources.map(\.balance)
  }
  func make(
    kind: ChannelSourceKind, fd: Int32, queue: DispatchQueue,
    event: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void
  ) -> any ChannelReadinessSource {
    let value = ChannelFakeSource(
      kind: kind, queue: queue, log: log, hold: holdCancellation, event: event, cancelled: cancelled
    )
    lock.lock()
    precondition(values[kind] == nil)
    values[kind] = value
    lock.unlock()
    return value
  }
  func fire(_ kind: ChannelSourceKind) {
    lock.lock()
    let value = values[kind]
    lock.unlock()
    value?.fire()
  }
  func acknowledge(_ kind: ChannelSourceKind) {
    lock.lock()
    let value = values[kind]
    lock.unlock()
    value?.acknowledge()
  }
}
private final class ChannelFakeSource: ChannelReadinessSource, @unchecked Sendable {
  private let lock = NSLock()
  private var depth = 0
  private let kind: ChannelSourceKind
  private let queue: DispatchQueue
  private let log: ChannelLog
  private let hold: Bool
  private let event: @Sendable () -> Void
  private let cancelled: @Sendable () -> Void
  init(
    kind: ChannelSourceKind, queue: DispatchQueue, log: ChannelLog, hold: Bool,
    event: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void
  ) {
    self.kind = kind
    self.queue = queue
    self.log = log
    self.hold = hold
    self.event = event
    self.cancelled = cancelled
  }
  var balance: Int {
    lock.lock()
    defer { lock.unlock() }
    return depth
  }
  func activate() { log.record("activate.\(kind)") }
  func suspend() {
    lock.lock()
    depth += 1
    lock.unlock()
    log.record("suspend.\(kind)")
  }
  func resume() {
    lock.lock()
    depth -= 1
    lock.unlock()
    log.record("resume.\(kind)")
  }
  func cancel() {
    log.record("cancel.\(kind)")
    if !hold { acknowledge() }
  }
  func acknowledge() {
    queue.async {
      self.log.record("ack.\(self.kind)")
      self.cancelled()
    }
  }
  func fire() { queue.async(execute: event) }
}
