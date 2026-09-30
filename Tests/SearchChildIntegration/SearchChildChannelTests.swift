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
    weak var weakFacade: SearchChildChannels?
    weakFacade = c
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

final class SearchChildChannelPipeTests: XCTestCase {
  // This is compiled by the focused harness but is not executed until the separately
  // approved real-pipe stage. It requires the internal default Darwin construction.
  func testDefaultConstructorReadsOwnedResponseByte() async throws {
    let fixture = try PipeFixture()
    let channel = fixture.makeDefaultChannels()
    var operationError: Error?
    do {
      try fixture.writeResponse(Data([0xA5]))
      let value = try await channel.read(maxBytes: 8)
      XCTAssertEqual(value, Data([0xA5]))
    } catch { operationError = error }
    await channel.close()
    if operationError == nil {
      do { try await fixture.requireLifetimeEOF() } catch { operationError = error }
    }
    do { try await fixture.cleanup() } catch {
      if let operationError { XCTFail("Operation also failed: \(operationError)") }
      throw error
    }
    if let operationError { throw operationError }
  }
  func testRealShortResponseAndExactRequestBytes() async throws {
    try await withRecordedFixture { fixture, recorded, _ in
      try fixture.writeResponse(Data([1, 2, 3]))
      let read = FixtureTask { try await recorded.channel.read(maxBytes: 4096) }
      let response = try await read.value()
      XCTAssertEqual(response, Data([1, 2, 3]))
      let payload = Data([0x71, 0x72, 0x73, 0x74])
      let write = FixtureTask { try await recorded.channel.write(payload) }
      try await write.value()
      let drain = try fixture.makeRequestDrain(expected: payload.count)
      try await self.closeRecorded(recorded)
      let request = try await drain.value()
      XCTAssertEqual(request, payload)
    }
  }
  func testRealBackpressureTwoReservedWritesAndFIFO() async throws {
    try await withRecordedFixture(prefill: true) { fixture, recorded, fill in
      let fill = try XCTUnwrap(fill)
      XCTAssertGreaterThan(fill.bytes, 0)
      XCTAssertLessThanOrEqual(fill.bytes, 1_048_576)
      XCTAssertLessThanOrEqual(fill.calls, 256)
      let firstBytes = Data(repeating: 0xA1, count: 16_384)
      let secondBytes = Data(repeating: 0xB2, count: 16_384)
      let first = FixtureTask { try await recorded.channel.write(firstBytes) }
      try await self.waitFor(recorded.log, "admit.write.1")
      try await self.waitFor(recorded.log, "write.eagain")
      let second = FixtureTask { try await recorded.channel.write(secondBytes) }
      try await self.waitFor(recorded.log, "admit.write.2")
      let thirdTask = FixtureTask { try await recorded.channel.write(Data([0xC3])) }
      let third = await channelFailure { try await thirdTask.value() }
      XCTAssertEqual(third, .busy)
      let expected = Data(repeating: 0x31, count: fill.bytes) + firstBytes + secondBytes
      let drain = try fixture.makeRequestDrain(expected: expected.count)
      let draining = FixtureTask { try await drain.value() }
      try await first.value()
      try await second.value()
      try await self.closeRecorded(recorded)
      let actual = try await draining.value()
      XCTAssertEqual(actual, expected)
    }
  }
  func testRealReadCancellationAfterObservedEAGAIN() async throws {
    try await withRecordedFixture { _, recorded, _ in
      let read = FixtureTask { try await recorded.channel.read(maxBytes: 64) }
      try await self.waitFor(recorded.log, "admit.read")
      try await self.waitFor(recorded.log, "read.eagain")
      read.cancel()
      let failure = await channelFailure { _ = try await read.value() }
      XCTAssertEqual(failure, .cancelled)
    }
  }
  func testRealWriteCancellationAfterObservedBackpressure() async throws {
    try await withRecordedFixture(prefill: true) { _, recorded, _ in
      let write = FixtureTask { try await recorded.channel.write(Data(repeating: 9, count: 4096)) }
      try await self.waitFor(recorded.log, "admit.write.1")
      try await self.waitFor(recorded.log, "write.eagain")
      write.cancel()
      let failure = await channelFailure { try await write.value() }
      XCTAssertEqual(failure, .cancelled)
    }
  }
  func testRealResponseEOFIsStickyWithoutAnotherReadSyscall() async throws {
    try await withRecordedFixture { fixture, recorded, _ in
      try fixture.closeResponsePeer()
      let first = FixtureTask { try await recorded.channel.read(maxBytes: 64) }
      let firstValue = try await first.value()
      XCTAssertEqual(firstValue, Data())
      try await self.waitFor(recorded.log, "ack.responseRead")
      let reads = recorded.log.count("io.read")
      let second = FixtureTask { try await recorded.channel.read(maxBytes: 64) }
      let secondValue = try await second.value()
      XCTAssertEqual(secondValue, Data())
      XCTAssertEqual(recorded.log.count("io.read"), reads)
      XCTAssertEqual(recorded.log.count("read.count.0"), 1)
    }
  }
  func testRealEPIPEWithDefaultAndUnchangedSIGPIPE() async throws {
    // Fixture construction requires inherited SIG_DFL; cleanup compares native snapshots.
    try await withRecordedFixture { fixture, recorded, _ in
      try fixture.closeRequestPeer()
      let write = FixtureTask { try await recorded.channel.write(Data([0xA5])) }
      let failure = await channelFailure { try await write.value() }
      XCTAssertEqual(failure, .channelFailure(EPIPE))
      XCTAssertEqual(recorded.log.count("write.errno.\(EPIPE)"), 1)
    }
  }
  func testRealCloseAcknowledgmentsPrecedeTheirOwnedDescriptorCloses() async throws {
    try await withRecordedFixture { fixture, recorded, _ in
      let pending = FixtureTask { try await recorded.channel.read(maxBytes: 64) }
      try await self.waitFor(recorded.log, "admit.read")
      try await self.waitFor(recorded.log, "read.eagain")
      let lifetime = FixtureTask { try await fixture.requireLifetimeEOF() }
      try await self.closeRecorded(recorded)
      let failure = await channelFailure { _ = try await pending.value() }
      XCTAssertEqual(failure, .shutDown)
      try await lifetime.value()
      self.assertCloseOrder(recorded.log)
      // Lifetime peer completion is required, but its unrelated queue is not ordered
      // relative to channel.close's return. The writer close and observed EOF are real.
    }
  }
  func testRealExactDescriptorReuseAfterAcknowledgedCloseSurvivesRepeatedClose() async throws {
    try await withRecordedFixture { fixture, recorded, _ in
      // Create the independent sentinel while the old channel integer is still owned.
      let sentinel = try fixture.makeReuseSentinel()
      try await self.closeRecorded(recorded)
      self.assertCloseOrder(recorded.log)
      let alias = try fixture.reuseClosedRequestNumber(recorded, sentinel: sentinel)
      XCTAssertEqual(try alias.descriptor(), recorded.oldRequest)
      try fixture.verifySentinel(sentinel, alias: alias, byte: 0x71)
      try await self.closeRecorded(recorded)
      try fixture.verifySentinel(sentinel, alias: alias, byte: 0x72)
      XCTAssertEqual(recorded.log.count("close.request.confirmed"), 1)
      XCTAssertEqual(recorded.log.count("ack.requestWrite"), 1)
    }
  }
  private func waitFor(_ log: ChannelLog, _ event: String) async throws {
    guard await XCTWaiter.fulfillment(of: [log.expectation(event)], timeout: 30) == .completed
    else {
      throw PipeFixtureError.peerOperationTimedOut
    }
  }
  private func closeRecorded(_ recorded: RecordedPipeChannel) async throws {
    recorded.log.record("test.close.request")
    let close = FixtureTask { await recorded.channel.close() }
    try await close.value()
    recorded.log.record("test.close.returned")
  }
  private func assertCloseOrder(
    _ log: ChannelLog, file: StaticString = #filePath, line: UInt = #line
  ) {
    for (kind, role) in [("requestWrite", "request"), ("responseRead", "response")] {
      XCTAssertEqual(log.count("cancel.\(kind)"), 1, file: file, line: line)
      XCTAssertEqual(log.count("ack.\(kind)"), 1, file: file, line: line)
      XCTAssertEqual(log.count("close.\(role).confirmed"), 1, file: file, line: line)
      XCTAssertTrue(log.precedes("cancel.\(kind)", "ack.\(kind)"), file: file, line: line)
      XCTAssertTrue(log.precedes("ack.\(kind)", "close.\(role).confirmed"), file: file, line: line)
      XCTAssertTrue(log.precedes("close.\(role).confirmed", "closed"), file: file, line: line)
    }
    XCTAssertEqual(log.count("close.lifetime.confirmed"), 1, file: file, line: line)
    XCTAssertTrue(log.precedes("close.lifetime.confirmed", "closed"), file: file, line: line)
    XCTAssertTrue(log.precedes("closed", "test.close.returned"), file: file, line: line)
  }
  private func withRecordedFixture(
    prefill: Bool = false,
    _ body: (PipeFixture, RecordedPipeChannel, FixtureFillReceipt?) async throws -> Void
  ) async throws {
    let fixture = try PipeFixture()
    let fill: FixtureFillReceipt?
    do { fill = prefill ? try fixture.fillRequestBeforeAdoption() : nil } catch {
      let original = error
      do { try await fixture.cleanup() } catch { XCTFail("Setup cleanup also failed: \(error)") }
      throw original
    }
    let recorded = fixture.makeRecordedChannels()
    var operationError: Error?
    do { try await body(fixture, recorded, fill) } catch { operationError = error }
    do { try await closeRecorded(recorded) } catch { operationError = operationError ?? error }
    if operationError == nil {
      do { try await fixture.requireLifetimeEOF() } catch { operationError = error }
    }
    do { try await fixture.cleanup() } catch {
      if let operationError { XCTFail("Operation also failed: \(operationError)") }
      throw error
    }
    if let operationError { throw operationError }
    assertCloseOrder(recorded.log)
  }

}

final class PipeDescriptorCellTests: XCTestCase {
  func testReentrantCloseDoesNotRetryOrClaimConfirmedCleanup() {
    var cell: PipeDescriptorCell!
    var calls = 0
    var nested: PipeCloseResult?
    cell = PipeDescriptorCell(41) { _ in
      calls += 1
      nested = cell.closeOnce()
      return 0
    }
    XCTAssertEqual(cell.closeOnce(), .confirmed)
    XCTAssertEqual(nested, .uncertain(EBUSY))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(cell.closeOnce(), .alreadyConsumed)
  }
  func testConsumedTransferredAndUncertainCellsNeverRepeatClose() {
    var confirmedCalls = 0
    let confirmed = PipeDescriptorCell(
      41,
      closer: { _ in
        confirmedCalls += 1
        return 0
      })
    XCTAssertEqual(confirmed.closeOnce(), .confirmed)
    XCTAssertEqual(confirmed.closeOnce(), .alreadyConsumed)
    XCTAssertEqual(confirmedCalls, 1)

    var transferredCalls = 0
    let transferred = PipeDescriptorCell(
      42,
      closer: { _ in
        transferredCalls += 1
        return 0
      })
    XCTAssertEqual(try? transferred.transfer(), 42)
    XCTAssertEqual(transferred.closeOnce(), .alreadyConsumed)
    XCTAssertEqual(transferredCalls, 0)

    var uncertainCalls = 0
    let uncertain = PipeDescriptorCell(
      43,
      closer: { _ in
        uncertainCalls += 1
        return EBADF
      })
    XCTAssertEqual(uncertain.closeOnce(), .uncertain(EBADF))
    XCTAssertEqual(uncertain.closeOnce(), .uncertain(EBADF))
    XCTAssertEqual(uncertainCalls, 1)
  }
}

/// Injected fixture controls only: fake descriptor integers, no Darwin calls or signal reads.
final class PipeFixtureLifecycleTests: XCTestCase {
  func testActiveEOFHasDeadlineAndWaitsForCancelAcknowledgment() async {
    let h = FixturePeerHarness()
    h.peer!.observeEOF(h.results.record)
    await h.flush()
    XCTAssertTrue(h.timers.fire(.eof))
    await h.flush()
    XCTAssertEqual(h.sources.log.count("cancel.responseRead"), 1)
    h.timers.fire(.cancellation)
    await h.flush()
    XCTAssertEqual(h.results.count, 1)
    XCTAssertEqual(h.results.errors, [.eofTimedOut])
    XCTAssertEqual(h.closes.count("close"), 0)
    h.peer!.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.cleanup.errors, [.eofTimedOut])
    h.sources.acknowledge()
    await h.flush()
    XCTAssertEqual(h.closes.count("close"), 0)
  }
  func testAcknowledgmentCloseFailureIsRetainedWithoutCleanupWaiter() async {
    let h = FixturePeerHarness(closeError: EBADF)
    h.peer!.observeEOF(h.results.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.results.count, 0)
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
    h.peer!.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.cleanup.errors, [.uncertainFixtureCleanup])
    XCTAssertEqual(h.results.failures, 1)
    XCTAssertEqual(h.closes.count("close"), 1)
  }
  func testCleanupAfterQuarantineFailsImmediatelyWithoutDescriptorClose() async {
    let h = FixturePeerHarness()
    h.peer!.observeEOF(h.results.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertTrue(h.timers.fire(.cancellation))
    await h.flush()
    h.peer!.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.cleanup.errors, [.sourceAcknowledgmentTimedOut])
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
  }
  func testQuarantineRetainsOwnerAndLateAcknowledgmentDoesNotClose() async {
    let h = FixturePeerHarness()
    h.peer!.observeEOF(h.results.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    h.timers.fire(.cancellation)
    await h.flush()
    weak var retained = h.peer
    h.peer = nil
    await h.flush()
    XCTAssertEqual(h.quarantine.count, 1)
    XCTAssertNotNil(retained)
    h.sources.acknowledge()
    await h.flush()
    XCTAssertEqual(h.closes.count("close"), 0)
    retained?.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.cleanup.errors, [.sourceAcknowledgmentTimedOut])
    let observed = await retained?.hasLateAcknowledgment()
    XCTAssertEqual(observed, true)
    XCTAssertEqual(h.quarantine.count, 1)
    retained = nil
  }
  func testTerminalResultsSurviveRepeatedObservers() async {
    let h = FixturePeerHarness()
    h.peer!.observeEOF(h.results.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.results.count, 0)
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
    XCTAssertFalse(h.timers.fire(.eof))
    XCTAssertFalse(h.timers.fire(.cancellation))
    h.peer!.observeEOF(h.results.record)
    h.peer!.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.results.count, 2)
    XCTAssertEqual(h.results.failures, 0)
    XCTAssertEqual(h.cleanup.count, 1)
    XCTAssertEqual(h.closes.count("close"), 1)
  }
  func testThrownPeerCleanupStillClosesIndependentCellsAndChecksSignal() async throws {
    let closes = ChannelLog()
    let clean = PipeDescriptorCell(42) { _ in
      closes.record("clean")
      return 0
    }
    let uncertain = PipeDescriptorCell(43) { _ in
      closes.record("uncertain")
      return EBADF
    }
    var snapshots = 0
    let signal = try FixtureSignalGuard {
      snapshots += 1
      return FixtureSignalSnapshot(handler: 0, mask: 0, flags: 0)
    }
    do {
      try await FixtureCleanup.perform(
        peer: { throw PipeFixtureError.sourceAcknowledgmentTimedOut },
        cells: [clean, uncertain], signal: signal)
      XCTFail("Expected failed cleanup")
    } catch {}
    XCTAssertEqual(closes.count("clean"), 1)
    XCTAssertEqual(closes.count("uncertain"), 1)
    XCTAssertEqual(snapshots, 2)
    XCTAssertEqual(uncertain.closeOnce(), .uncertain(EBADF))
    XCTAssertEqual(closes.count("uncertain"), 1)
  }
  func testSignalGuardReadsPostSnapshotAndRejectsEveryChangedField() throws {
    let before = FixtureSignalSnapshot(handler: 0, mask: 0, flags: 0)
    for after in [
      FixtureSignalSnapshot(handler: 1, mask: 0, flags: 0),
      FixtureSignalSnapshot(handler: 0, mask: 1, flags: 0),
      FixtureSignalSnapshot(handler: 0, mask: 0, flags: 1),
    ] {
      var reads = 0
      let guardValue = try FixtureSignalGuard {
        reads += 1
        return reads == 1 ? before : after
      }
      XCTAssertThrowsError(try guardValue.verifyAfter())
      XCTAssertEqual(reads, 2)
    }
    XCTAssertThrowsError(
      try FixtureSignalGuard { FixtureSignalSnapshot(handler: 1, mask: 0, flags: 0) })
  }
}
private final class FixtureResults: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Result<Void, Error>] = []
  func record(_ result: Result<Void, Error>) {
    lock.lock()
    values.append(result)
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
  var errors: [PipeFixtureError] {
    lock.lock()
    defer { lock.unlock() }
    return values.compactMap {
      if case .failure(let error) = $0 { return error as? PipeFixtureError }
      return nil
    }
  }
  var failures: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.filter {
      if case .failure = $0 { return true }
      return false
    }.count
  }
}
private final class FixtureManualTimers: @unchecked Sendable {
  private let lock = NSLock()
  private var actions: [FixtureDeadline: (DispatchQueue, @Sendable () -> Void)] = [:]
  func schedule(
    _ kind: FixtureDeadline, queue: DispatchQueue, action: @escaping @Sendable () -> Void
  ) -> any FixtureTimer {
    lock.lock()
    actions[kind] = (queue, action)
    lock.unlock()
    return FixtureManualTimer { [weak self] in self?.remove(kind) }
  }
  private func remove(_ kind: FixtureDeadline) {
    lock.lock()
    actions[kind] = nil
    lock.unlock()
  }
  @discardableResult func fire(_ kind: FixtureDeadline) -> Bool {
    lock.lock()
    let value = actions.removeValue(forKey: kind)
    lock.unlock()
    if let value {
      value.0.async(execute: value.1)
      return true
    }
    return false
  }
}
private final class FixtureManualTimer: FixtureTimer {
  let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  func cancel() { action() }
}
private final class FixtureSources: ChannelSourceFactory, @unchecked Sendable {
  let log = ChannelLog()
  private let lock = NSLock()
  private var event: (@Sendable () -> Void)?
  private var ack: (@Sendable () -> Void)?
  private var queue: DispatchQueue?
  func make(
    kind: ChannelSourceKind, fd: Int32, queue: DispatchQueue,
    event: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void
  ) -> any ChannelReadinessSource {
    lock.lock()
    self.queue = queue
    self.event = event
    ack = cancelled
    lock.unlock()
    return FixtureSource(log: log)
  }
  func fire() {
    lock.lock()
    let q = queue
    let f = event
    lock.unlock()
    if let f { q?.async(execute: f) }
  }
  func acknowledge() {
    lock.lock()
    let q = queue
    let f = ack
    ack = nil
    event = nil
    lock.unlock()
    if let f { q?.async(execute: f) }
  }
}
private final class FixtureSource: ChannelReadinessSource, @unchecked Sendable {
  let log: ChannelLog
  init(log: ChannelLog) { self.log = log }
  func activate() { log.record("activate") }
  func suspend() {}
  func resume() {}
  func cancel() { log.record("cancel.responseRead") }
}
private final class FixturePeerHarness {
  let queue = DispatchQueue(label: "fixture.injected")
  let sources = FixtureSources()
  let timers = FixtureManualTimers()
  let quarantine = FixtureQuarantine()
  let closes = ChannelLog()
  let results = FixtureResults()
  let cleanup = FixtureResults()
  var peer: FixturePeerEOF?
  init(closeError: Int32 = 0) {
    let closes = closes
    let cell = PipeDescriptorCell(41) { _ in
      closes.record("close")
      return closeError
    }
    let timers = timers
    peer = FixturePeerEOF(
      cell: cell, queue: queue, sources: sources, read: { _ in .count(0) },
      schedule: { kind, queue, action in timers.schedule(kind, queue: queue, action: action) },
      quarantine: quarantine)
  }
  func flush() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
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

private enum PipeFixtureError: Error, Equatable {
  case syscall(Int32)
  case malformed
  case uncertainFixtureCleanup
  case defaultSIGPIPEUnavailable
  case sourceAcknowledgmentTimedOut
  case eofTimedOut
  case cancelled
  case signalDispositionChanged
  case ioBudgetExceeded
  case peerOperationTimedOut
}

private enum PipeCloseResult: Equatable {
  case confirmed
  case uncertain(Int32)
  case alreadyConsumed
}

private final class PipeDescriptorCell {
  private enum State {
    case owned(Int32)
    case transferred, closing, consumedConfirmed
    case consumedUncertain(Int32)
  }
  private let lock = NSLock()
  private var state: State
  private let closer: (Int32) -> Int32
  init(
    _ value: Int32,
    closer: @escaping (Int32) -> Int32 = { descriptor in
      if Darwin.close(descriptor) == 0 { return 0 }
      return errno
    }
  ) {
    state = .owned(value)
    self.closer = closer
  }
  func descriptor() throws -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    guard case .owned(let value) = state else { throw PipeFixtureError.malformed }
    return value
  }
  func transfer() throws -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    guard case .owned(let value) = state else { throw PipeFixtureError.malformed }
    state = .transferred
    return value
  }
  func closeOnce() -> PipeCloseResult {
    lock.lock()
    let descriptor: Int32
    switch state {
    case .owned(let value): descriptor = value
    case .consumedUncertain(let error):
      lock.unlock()
      return .uncertain(error)
    case .closing:
      lock.unlock()
      return .uncertain(EBUSY)
    case .transferred, .consumedConfirmed:
      lock.unlock()
      return .alreadyConsumed
    }
    state = .closing
    lock.unlock()
    let result = closer(descriptor)
    lock.lock()
    if result == 0 {
      state = .consumedConfirmed
      lock.unlock()
      return .confirmed
    }
    state = .consumedUncertain(result)
    lock.unlock()
    return .uncertain(result)
  }
}

private enum FixtureDeadline: Hashable { case eof, cancellation }
private protocol FixtureTimer: AnyObject { func cancel() }
private final class FixtureDispatchTimer: FixtureTimer {
  private let source: DispatchSourceTimer
  init(queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
    source = DispatchSource.makeTimerSource(queue: queue)
    source.setEventHandler(handler: action)
    source.schedule(deadline: .now() + 30)
    source.activate()
  }
  func cancel() { source.cancel() }
}
private final class FixtureQuarantine {
  static let process = FixtureQuarantine()
  private let lock = NSLock()
  private var owners: [ObjectIdentifier: FixturePeerEOF] = [:]
  func retain(_ peer: FixturePeerEOF) {
    lock.lock()
    defer { lock.unlock() }
    precondition(owners.count < 64, "fixture quarantine capacity exhausted")
    owners[ObjectIdentifier(peer)] = peer
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return owners.count
  }
}

/// All peer state is queue-confined. Result slots outlive individual observers.
/// A cancelled Dispatch source owns this object until its acknowledgment callback;
/// timeouts additionally retain it in the process quarantine until process teardown.
private final class FixturePeerEOF: @unchecked Sendable {
  private enum State: Equatable { case idle, active, cancelling, acknowledged, quarantined }
  private let queue: DispatchQueue
  private let cell: PipeDescriptorCell
  private let sources: any ChannelSourceFactory
  private let read: (Int32) -> ChannelIOResult
  private let schedule:
    (FixtureDeadline, DispatchQueue, @escaping @Sendable () -> Void) -> any FixtureTimer
  // The production registry is process-owned; injected tests own their registry.
  private weak var quarantine: FixtureQuarantine?
  private var state: State = .idle
  private var source: (any ChannelReadinessSource)?
  private var eofTimer: (any FixtureTimer)?
  private var cancelTimer: (any FixtureTimer)?
  private var eofWaiter: ((Result<Void, Error>) -> Void)?
  private var cleanupWaiter: ((Result<Void, Error>) -> Void)?
  private var pendingEOF: Result<Void, Error>?
  private var eofResult: Result<Void, Error>?
  private var cleanupResult: Result<Void, Error>?
  private var lateAcknowledgmentObserved = false

  init(
    cell: PipeDescriptorCell,
    queue: DispatchQueue = DispatchQueue(label: "channel.pipe.lifetime.peer"),
    sources: any ChannelSourceFactory = DispatchChannelSourceFactory(),
    read: @escaping (Int32) -> ChannelIOResult = { descriptor in
      var byte: UInt8 = 0
      let result = Darwin.read(descriptor, &byte, 1)
      return result < 0 ? .failed(errno) : .count(result)
    },
    schedule:
      @escaping (FixtureDeadline, DispatchQueue, @escaping @Sendable () -> Void) -> any FixtureTimer =
      {
        _, queue, action in FixtureDispatchTimer(queue: queue, action: action)
      }, quarantine: FixtureQuarantine = .process
  ) {
    self.cell = cell
    self.queue = queue
    self.sources = sources
    self.read = read
    self.schedule = schedule
    self.quarantine = quarantine
  }

  func hasLateAcknowledgment() async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.lateAcknowledgmentObserved) }
    }
  }
  func waitForEOF() async throws {
    try await withCheckedThrowingContinuation { continuation in
      observeEOF { continuation.resume(with: $0) }
    }
  }
  func cleanup() async throws {
    try await withCheckedThrowingContinuation { continuation in
      observeCleanup { continuation.resume(with: $0) }
    }
  }
  func observeEOF(_ completion: @escaping (Result<Void, Error>) -> Void) {
    queue.async {
      if let result = self.eofResult {
        completion(result)
        return
      }
      guard self.eofWaiter == nil else {
        completion(.failure(PipeFixtureError.malformed))
        return
      }
      self.eofWaiter = completion
      self.start()
    }
  }
  func observeCleanup(_ completion: @escaping (Result<Void, Error>) -> Void) {
    queue.async {
      if let result = self.cleanupResult {
        completion(result)
        return
      }
      guard self.cleanupWaiter == nil else {
        completion(.failure(PipeFixtureError.malformed))
        return
      }
      self.cleanupWaiter = completion
      switch self.state {
      case .idle:
        self.state = .acknowledged
        self.pendingEOF = .failure(PipeFixtureError.cancelled)
        self.closeAfterAcknowledgment()
      case .active:
        self.pendingEOF = .failure(PipeFixtureError.cancelled)
        self.beginCancellation()
      case .cancelling: break
      case .acknowledged, .quarantined:
        preconditionFailure("settled peer must retain its cleanup result")
      }
    }
  }
  private func start() {
    guard state == .idle else { return }
    do {
      let descriptor = try cell.descriptor()
      source = sources.make(
        kind: .responseRead, fd: descriptor, queue: queue,
        event: { [self] in ready() }, cancelled: { [self] in acknowledged() })
      state = .active
      eofTimer = schedule(.eof, queue) { [weak self] in self?.timedOut(.eofTimedOut) }
      source!.activate()
    } catch {
      state = .acknowledged
      pendingEOF = .failure(error)
      closeAfterAcknowledgment()
    }
  }
  private func ready() {
    guard state == .active, let descriptor = try? cell.descriptor() else { return }
    // One nonblocking syscall per readiness callback, never a retry/spin loop.
    switch read(descriptor) {
    case .count(0): pendingEOF = .success(())
    case .failed(let error) where error == EAGAIN || error == EWOULDBLOCK || error == EINTR: return
    case .failed(let error): pendingEOF = .failure(PipeFixtureError.syscall(error))
    case .count: pendingEOF = .failure(PipeFixtureError.malformed)
    }
    beginCancellation()
  }
  private func beginCancellation() {
    guard state == .active, let source else { return }
    state = .cancelling
    cancelTimer = schedule(.cancellation, queue) { [weak self] in
      self?.timedOut(.sourceAcknowledgmentTimedOut)
    }
    source.cancel()
  }
  private func timedOut(_ error: PipeFixtureError) {
    guard state == .active || state == .cancelling else { return }
    if state == .active { beginCancellation() }
    state = .quarantined
    guard let quarantine else { preconditionFailure("fixture quarantine owner unavailable") }
    quarantine.retain(self)
    cancelTimers()
    // Failure can be delivered without acknowledgment because ownership is retained.
    // It never licenses closing the source-owned descriptor.
    resolveEOF(.failure(error))
    resolveCleanup(.failure(error))
  }
  private func acknowledged() {
    if state == .quarantined {
      lateAcknowledgmentObserved = true
      source = nil
      return  // retain the cell and original failure; never retry/probe/reuse its integer
    }
    guard state == .cancelling else { return }
    source = nil
    state = .acknowledged
    cancelTimers()
    closeAfterAcknowledgment()
  }
  private func cancelTimers() {
    eofTimer?.cancel()
    eofTimer = nil
    cancelTimer?.cancel()
    cancelTimer = nil
  }
  private func closeAfterAcknowledgment() {
    precondition(state == .acknowledged)
    let cleanup: Result<Void, Error>
    switch cell.closeOnce() {
    case .confirmed, .alreadyConsumed: cleanup = .success(())
    case .uncertain: cleanup = .failure(PipeFixtureError.uncertainFixtureCleanup)
    }
    // Retain both results and clear observers before invoking any external callback.
    let eof: Result<Void, Error>
    if case .failure = cleanup {
      eof = cleanup
    } else {
      eof = pendingEOF ?? .failure(PipeFixtureError.cancelled)
    }
    pendingEOF = nil
    let eofObserver = eofWaiter
    eofWaiter = nil
    let cleanupObserver = cleanupWaiter
    cleanupWaiter = nil
    eofResult = eof
    cleanupResult = cleanup
    eofObserver?(eof)
    cleanupObserver?(cleanup)
  }
  private func resolveEOF(_ result: Result<Void, Error>) {
    guard eofResult == nil else { return }
    eofResult = result
    let waiter = eofWaiter
    eofWaiter = nil
    waiter?(result)
  }
  private func resolveCleanup(_ result: Result<Void, Error>) {
    guard cleanupResult == nil else { return }
    cleanupResult = result
    let waiter = cleanupWaiter
    cleanupWaiter = nil
    waiter?(result)
  }
}

private struct FixtureSignalSnapshot: Equatable {
  let handler: UInt
  let mask: sigset_t
  let flags: Int32
}
private struct FixtureSignalGuard {
  let before: FixtureSignalSnapshot
  private let snapshot: () throws -> FixtureSignalSnapshot
  init(snapshot: @escaping () throws -> FixtureSignalSnapshot) throws {
    self.snapshot = snapshot
    before = try snapshot()
    guard before.handler == 0 else { throw PipeFixtureError.defaultSIGPIPEUnavailable }
  }
  func verifyAfter() throws {
    guard try snapshot() == before else { throw PipeFixtureError.signalDispositionChanged }
  }
}

private struct FixtureCleanupFailure: Error {
  let peer: Error?
  let uncertainCloses: [Int32]
  let signal: Error?
}
private enum FixtureCleanup {
  static func perform(
    peer: (() async throws -> Void)?, cells: [PipeDescriptorCell],
    signal: FixtureSignalGuard
  ) async throws {
    var peerError: Error?
    if let peer {
      do { try await peer() } catch { peerError = error }
    }
    var uncertain: [Int32] = []
    for cell in cells {
      if case .uncertain(let error) = cell.closeOnce() { uncertain.append(error) }
    }
    var signalError: Error?
    do { try signal.verifyAfter() } catch { signalError = error }
    if peerError != nil || !uncertain.isEmpty || signalError != nil {
      throw FixtureCleanupFailure(peer: peerError, uncertainCloses: uncertain, signal: signalError)
    }
  }
}

/// Compile-only real-pipe fixture. The focused class is not executed until root review.
private final class PipeFixture {
  private var requestRead: PipeDescriptorCell?
  private var requestWrite: PipeDescriptorCell?
  private var responseRead: PipeDescriptorCell?
  private var responseWrite: PipeDescriptorCell?
  private var lifetimeRead: PipeDescriptorCell?
  private var lifetimeWrite: PipeDescriptorCell?
  private var lifetimeEOF: FixturePeerEOF?
  private var requestDrain: FixturePeerDrain?
  private var extraCells: [PipeDescriptorCell] = []

  private let signal: FixtureSignalGuard

  init() throws {
    // Capture default disposition before creating any synthetic descriptor.
    signal = try FixtureSignalGuard(snapshot: Self.signalSnapshot)
    do {
      let request = try Self.normalizedPipe()
      requestRead = request.0
      requestWrite = request.1
      let response = try Self.normalizedPipe()
      responseRead = response.0
      responseWrite = response.1
      let lifetime = try Self.normalizedPipe()
      lifetimeRead = lifetime.0
      lifetimeWrite = lifetime.1
      for cell in [
        requestRead!, requestWrite!, responseRead!, responseWrite!, lifetimeRead!, lifetimeWrite!,
      ] {
        try Self.verifyCloexec(try cell.descriptor())
      }
      for cell in [requestWrite!, responseRead!, requestRead!, responseWrite!, lifetimeRead!] {
        try Self.enableNonblocking(try cell.descriptor())
      }
      try Self.enableNoSigPipe(try requestWrite!.descriptor())
      lifetimeEOF = FixturePeerEOF(cell: lifetimeRead!)
      lifetimeRead = nil  // exclusive ownership passes to the peer, including quarantine
    } catch {
      let clean = Self.cleanupCells(
        [
          requestRead, requestWrite, responseRead, responseWrite,
          lifetimeRead, lifetimeWrite,
        ].compactMap { $0 })
      var signalError: Error?
      do { try signal.verifyAfter() } catch { signalError = error }
      if !clean { throw PipeFixtureError.uncertainFixtureCleanup }
      if let signalError { throw signalError }
      throw error
    }
  }

  func makeDefaultChannels() -> SearchChildChannels {
    let request = transfer(&requestWrite)
    let response = transfer(&responseRead)
    let lifetime = transfer(&lifetimeWrite)
    return SearchChildChannels(
      requestWriteFD: request, responseReadFD: response, lifetimeWriteFD: lifetime)
  }

  func writeResponse(_ bytes: Data) throws {
    let descriptor = try responseWrite!.descriptor()
    let result = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    guard result == bytes.count else {
      throw PipeFixtureError.syscall(result < 0 ? errno : EIO)
    }
  }

  func requireLifetimeEOF() async throws {
    guard let lifetimeEOF else { throw PipeFixtureError.malformed }
    try await lifetimeEOF.waitForEOF()
  }

  func cleanup() async throws {
    let peer = lifetimeEOF
    let drain = requestDrain
    // Retain cells and both peer owners: repeated cleanup preserves uncertain results.
    // Each peer owns its descriptor exclusively, including after a deadline/quarantine.
    try await FixtureCleanup.perform(
      peer: {
        var errors: [Error] = []
        if let peer { do { try await peer.cleanup() } catch { errors.append(error) } }
        if let drain { do { try await drain.cleanup() } catch { errors.append(error) } }
        if !errors.isEmpty { throw FixturePeerCleanupFailures(errors: errors) }
      },
      cells: [requestRead, requestWrite, responseRead, responseWrite, lifetimeRead, lifetimeWrite]
        .compactMap { $0 } + extraCells,
      signal: signal)
  }

  private func transfer(_ cell: inout PipeDescriptorCell?) -> Int32 {
    guard let owned = cell else { preconditionFailure("fixture descriptor already transferred") }
    let descriptor: Int32
    do { descriptor = try owned.transfer() } catch {
      preconditionFailure("fixture transfer failed")
    }
    cell = nil
    return descriptor
  }

  private static func normalizedPipe() throws -> (PipeDescriptorCell, PipeDescriptorCell) {
    var raw = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&raw) == 0 else { throw PipeFixtureError.syscall(errno) }
    let first = PipeDescriptorCell(raw[0])
    let second = PipeDescriptorCell(raw[1])
    var normalizedFirst: PipeDescriptorCell?
    do {
      let read = try normalize(first)
      normalizedFirst = read
      let write = try normalize(second)
      return (read, write)
    } catch {
      let clean = cleanupCells([first, second] + (normalizedFirst.map { [$0] } ?? []))
      if !clean { throw PipeFixtureError.uncertainFixtureCleanup }
      throw error
    }
  }

  private static func normalize(_ raw: PipeDescriptorCell) throws -> PipeDescriptorCell {
    let duplicate = Darwin.fcntl(try raw.descriptor(), F_DUPFD_CLOEXEC, 4)
    guard duplicate >= 0 else { throw PipeFixtureError.syscall(errno) }
    guard duplicate >= 4 else {
      let lowDescriptor = PipeDescriptorCell(duplicate)
      switch lowDescriptor.closeOnce() {
      case .confirmed:
        throw PipeFixtureError.syscall(EINVAL)
      case .alreadyConsumed, .uncertain:
        throw PipeFixtureError.uncertainFixtureCleanup
      }
    }
    let normalized = PipeDescriptorCell(duplicate)
    switch raw.closeOnce() {
    case .confirmed:
      return normalized
    case .alreadyConsumed, .uncertain:
      let clean = cleanupCells([normalized])
      if !clean { throw PipeFixtureError.uncertainFixtureCleanup }
      throw PipeFixtureError.uncertainFixtureCleanup
    }
  }

  private static func cleanupCells(_ cells: [PipeDescriptorCell]) -> Bool {
    var clean = true
    for cell in cells {
      switch cell.closeOnce() {
      case .confirmed, .alreadyConsumed: break
      case .uncertain: clean = false
      }
    }
    return clean
  }

  private static func verifyCloexec(_ descriptor: Int32) throws {
    let flags = Darwin.fcntl(descriptor, F_GETFD)
    guard flags >= 0, flags & FD_CLOEXEC != 0 else { throw PipeFixtureError.syscall(errno) }
  }

  private static func enableNonblocking(_ descriptor: Int32) throws {
    let original = Darwin.fcntl(descriptor, F_GETFL)
    guard original >= 0, Darwin.fcntl(descriptor, F_SETFL, original | O_NONBLOCK) == 0 else {
      throw PipeFixtureError.syscall(errno)
    }
    let verified = Darwin.fcntl(descriptor, F_GETFL)
    guard verified >= 0, verified & O_NONBLOCK != 0 else {
      throw PipeFixtureError.syscall(errno)
    }
  }

  private static func enableNoSigPipe(_ descriptor: Int32) throws {
    guard Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
      Darwin.fcntl(descriptor, F_GETNOSIGPIPE) == 1
    else {
      throw PipeFixtureError.syscall(errno)
    }
  }

  private static func signalSnapshot() throws -> FixtureSignalSnapshot {
    var action = Darwin.sigaction()
    let result = withUnsafeMutablePointer(to: &action) { sigaction(SIGPIPE, nil, $0) }
    guard result == 0 else { throw PipeFixtureError.syscall(errno) }
    return FixtureSignalSnapshot(
      handler: unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self),
      mask: action.sa_mask, flags: action.sa_flags)
  }
}

// Bounded bookkeeping controls below use injected calls only, never actual pipes.
final class PipeBoundedIOTests: XCTestCase {
  func testFillRequiresObservedEAGAINAndCountsShortWrites() throws {
    var results: [ChannelIOResult] = [.count(2), .count(3), .failed(EAGAIN)]
    var calls = 0
    let receipt = try FixtureFill.run { bytes in
      XCTAssertEqual(bytes.count, 4096)
      calls += 1
      return results.removeFirst()
    }
    XCTAssertEqual(receipt.bytes, 5)
    XCTAssertEqual(receipt.calls, 3)
    XCTAssertEqual(calls, 3)
    XCTAssertTrue(results.isEmpty)
  }
  func testFillStopsAtCallBudgetWithoutClaimingObservedBackpressure() {
    var calls = 0
    XCTAssertThrowsError(
      try FixtureFill.run { _ in
        calls += 1
        return .count(4096)
      })
    XCTAssertEqual(calls, 256)
    calls = 0
    XCTAssertThrowsError(
      try FixtureFill.run { _ in
        calls += 1
        return .failed(EINTR)
      })
    XCTAssertEqual(calls, 256)
  }
  func testDrainBudgetRejectsOverflowAndStopsAt512Calls() throws {
    XCTAssertThrowsError(try FixtureDrainBudget(expected: 2_097_153))
    XCTAssertThrowsError(try FixtureDrainBudget(expected: 0))
    var budget = try FixtureDrainBudget(expected: 1000)
    for _ in 0..<512 { try budget.noteCall() }
    XCTAssertThrowsError(try budget.noteCall())
    XCTAssertThrowsError(try budget.append(Data(repeating: 1, count: 1001), requested: 1000))
    XCTAssertEqual(budget.bytes.count, 0)
  }
  func testDrainBudgetAccumulatesExactBytesAndRejectsShortBufferMismatch() throws {
    var budget = try FixtureDrainBudget(expected: 3)
    try budget.append(Data([1]), requested: 3)
    XCTAssertFalse(budget.complete)
    try budget.append(Data([2, 3]), requested: 2)
    XCTAssertTrue(budget.complete)
    XCTAssertEqual(budget.bytes, Data([1, 2, 3]))
    XCTAssertThrowsError(try budget.append(Data([4]), requested: 1))
  }
}
private struct FixtureFillReceipt {
  let bytes: Int
  let calls: Int
}
private enum FixtureFill {
  static func run(write: (Data) -> ChannelIOResult) throws -> FixtureFillReceipt {
    let block = Data(repeating: 0x31, count: 4096)
    var filled = 0
    for index in 0..<256 {
      switch write(block) {
      case .count(let count):
        guard count > 0, count <= block.count else { throw PipeFixtureError.malformed }
        filled += count
      case .failed(let error) where error == EAGAIN || error == EWOULDBLOCK:
        guard filled > 0 else { throw PipeFixtureError.malformed }
        return .init(bytes: filled, calls: index + 1)
      case .failed(EINTR): continue
      case .failed(let error): throw PipeFixtureError.syscall(error)
      }
    }
    throw PipeFixtureError.ioBudgetExceeded
  }
}
private struct FixtureDrainBudget {
  let expected: Int
  private(set) var calls = 0
  private(set) var bytes = Data()
  init(expected: Int) throws {
    guard (1...2_097_152).contains(expected) else { throw PipeFixtureError.ioBudgetExceeded }
    self.expected = expected
  }
  var complete: Bool { bytes.count == expected }
  var nextReadSize: Int { min(4096, expected - bytes.count) }
  mutating func noteCall() throws {
    guard calls < 512 else { throw PipeFixtureError.ioBudgetExceeded }
    calls += 1
  }
  mutating func append(_ data: Data, requested: Int) throws {
    guard !data.isEmpty, requested > 0, requested <= nextReadSize,
      data.count <= requested, data.count <= expected - bytes.count
    else { throw PipeFixtureError.ioBudgetExceeded }
    bytes.append(data)
  }
}

/// One exact-stream peer drain. Its cell leaves the fixture's independent cleanup list.
/// No completion/cleanup success is published until the actual source acknowledges cancellation.
private final class FixturePeerDrain: @unchecked Sendable {
  private enum State { case idle, active, cancelling, settled, quarantined }
  private let cell: PipeDescriptorCell
  private let queue: DispatchQueue
  private let factory: any ChannelSourceFactory
  private let read: (Int32, Int) -> (ChannelIOResult, Data)
  private let schedule:
    (FixtureDeadline, DispatchQueue, @escaping @Sendable () -> Void) -> any FixtureTimer
  private weak var retention: FixtureDrainRetention?
  private var budget: FixtureDrainBudget
  private var state = State.idle
  private var source: (any ChannelReadinessSource)?
  private var deadline: (any FixtureTimer)?
  private var ackDeadline: (any FixtureTimer)?
  private var pending: Result<Data, Error>?
  private var terminal: Result<Data, Error>?
  private var cleanupResult: Result<Void, Error>?
  private var waiter: ((Result<Data, Error>) -> Void)?
  private var cleanupWaiter: ((Result<Void, Error>) -> Void)?

  init(
    cell: PipeDescriptorCell, expected: Int,
    queue: DispatchQueue = DispatchQueue(label: "pipe.fixture.drain"),
    factory: any ChannelSourceFactory = DispatchChannelSourceFactory(),
    read: @escaping (Int32, Int) -> (ChannelIOResult, Data) = { fd, limit in
      var data = Data(count: limit)
      let result = data.withUnsafeMutableBytes {
        DarwinChannelDescriptorOperations().read(fd: fd, into: $0)
      }
      if case .count(let count) = result, count >= 0, count <= limit {
        data.count = count
        return (result, data)
      }
      return (result, Data())
    },
    schedule:
      @escaping (FixtureDeadline, DispatchQueue, @escaping @Sendable () -> Void) -> any FixtureTimer =
      {
        _, queue, action in FixtureDispatchTimer(queue: queue, action: action)
      }, retention: FixtureDrainRetention = .process
  ) throws {
    budget = try FixtureDrainBudget(expected: expected)
    self.cell = cell
    self.queue = queue
    self.factory = factory
    self.read = read
    self.schedule = schedule
    self.retention = retention
  }
  func value() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      observe { continuation.resume(with: $0) }
    }
  }
  func cleanup() async throws {
    try await withCheckedThrowingContinuation { continuation in
      observeCleanup { continuation.resume(with: $0) }
    }
  }
  func observe(_ body: @escaping (Result<Data, Error>) -> Void) {
    queue.async {
      if let terminal = self.terminal {
        body(terminal)
        return
      }
      guard self.waiter == nil else {
        body(.failure(PipeFixtureError.malformed))
        return
      }
      self.waiter = body
      guard self.state == .idle else { return }
      do {
        let fd = try self.cell.descriptor()
        self.source = self.factory.make(
          kind: .responseRead, fd: fd, queue: self.queue,
          event: { [self] in turn() }, cancelled: { [self] in acknowledged() })
        self.state = .active
        self.deadline = self.schedule(.eof, self.queue) { [weak self] in self?.timeout() }
        self.source!.activate()
      } catch {
        self.state = .settled
        self.pending = .failure(error)
        self.finishClose()
      }
    }
  }
  func observeCleanup(_ body: @escaping (Result<Void, Error>) -> Void) {
    queue.async {
      if let result = self.cleanupResult {
        body(result)
        return
      }
      guard self.cleanupWaiter == nil else {
        body(.failure(PipeFixtureError.malformed))
        return
      }
      self.cleanupWaiter = body
      switch self.state {
      case .idle:
        self.state = .settled
        self.pending = .failure(PipeFixtureError.cancelled)
        self.finishClose()
      case .active: self.cancel(.failure(PipeFixtureError.cancelled))
      case .cancelling: break
      case .settled, .quarantined: preconditionFailure("Missing retained drain cleanup")
      }
    }
  }
  private func turn() {
    guard state == .active else { return }
    do {
      let fd = try cell.descriptor()
      // At most16 calls/64KiB per callback;512 calls/2MiB including EOF/probe calls.
      // At the exact payload boundary, request only one byte to reject any surplus.
      for _ in 0..<16 {
        let requested = budget.complete ? 1 : budget.nextReadSize
        try budget.noteCall()
        let (result, data) = read(fd, requested)
        switch result {
        case .count(let count):
          guard count >= 0, count == data.count, count <= requested else {
            throw PipeFixtureError.malformed
          }
          if count == 0 {
            guard budget.complete else { throw PipeFixtureError.malformed }
            cancel(.success(budget.bytes))
            return
          }
          guard !budget.complete else { throw PipeFixtureError.malformed }
          try budget.append(data, requested: requested)
        case .failed(let error) where error == EAGAIN || error == EWOULDBLOCK:
          guard budget.calls < 512 else { throw PipeFixtureError.ioBudgetExceeded }
          return  // retain actual readiness interest, never busy-poll
        case .failed(EINTR): break
        case .failed(let error): throw PipeFixtureError.syscall(error)
        }
      }
      if budget.calls == 512 { throw PipeFixtureError.ioBudgetExceeded }
      // The active level-triggered source supplies the next bounded turn if still readable.
    } catch { cancel(.failure(error)) }
  }
  private func cancel(_ result: Result<Data, Error>) {
    guard state == .active else { return }
    pending = result
    state = .cancelling
    ackDeadline = schedule(.cancellation, queue) { [weak self] in self?.timeout() }
    source?.cancel()
  }
  private func stopTimers() {
    deadline?.cancel()
    deadline = nil
    ackDeadline?.cancel()
    ackDeadline = nil
  }
  private func timeout() {
    guard state == .active || state == .cancelling else { return }
    if state == .active { cancel(.failure(PipeFixtureError.peerOperationTimedOut)) }
    state = .quarantined
    guard let retention else { preconditionFailure("drain quarantine unavailable") }
    retention.retain(self)
    stopTimers()
    terminal = .failure(PipeFixtureError.peerOperationTimedOut)
    cleanupResult = .failure(PipeFixtureError.peerOperationTimedOut)
    pending = nil
    deliver()
  }
  private func acknowledged() {
    if state == .quarantined {
      source = nil
      return
    }
    guard state == .cancelling else { return }
    source = nil
    state = .settled
    stopTimers()
    finishClose()
  }
  private func finishClose() {
    precondition(state == .settled)
    switch cell.closeOnce() {
    case .confirmed, .alreadyConsumed:
      cleanupResult = .success(())
      terminal = pending ?? .failure(PipeFixtureError.cancelled)
    case .uncertain:
      cleanupResult = .failure(PipeFixtureError.uncertainFixtureCleanup)
      terminal = .failure(PipeFixtureError.uncertainFixtureCleanup)
    }
    pending = nil
    deliver()
  }
  private func deliver() {
    let completed = waiter
    waiter = nil
    let cleaned = cleanupWaiter
    cleanupWaiter = nil
    if let terminal { completed?(terminal) }
    if let cleanupResult { cleaned?(cleanupResult) }
  }
}
private final class FixtureDrainRetention {
  static let process = FixtureDrainRetention()
  private let lock = NSLock()
  private var owners: [ObjectIdentifier: FixturePeerDrain] = [:]
  func retain(_ owner: FixturePeerDrain) {
    lock.lock()
    defer { lock.unlock() }
    precondition(owners.count < 64, "drain quarantine capacity exhausted")
    owners[ObjectIdentifier(owner)] = owner
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return owners.count
  }
}

final class PipeDrainLifecycleTests: XCTestCase {
  func testDrainRejectsSurplusByteAfterExpectedPayload() async throws {
    let h = try FixtureDrainHarness(reads: [
      (.count(3), Data([1, 2, 3])), (.count(1), Data([4])), (.count(0), Data()),
    ])
    h.owner!.observe(h.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.results.count, 0)
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
    XCTAssertTrue(h.values.isEmpty)
    XCTAssertEqual(h.results.errors, [.malformed])
    XCTAssertEqual(h.reads.count("limit.1"), 1)
    XCTAssertEqual(h.closes.count("close"), 1)
  }
  func testDrainWaitsThroughEAGAINForEOFBeforeAcknowledgment() async throws {
    let h = try FixtureDrainHarness(reads: [
      (.count(3), Data([1, 2, 3])), (.failed(EAGAIN), Data()), (.count(0), Data()),
    ])
    h.owner!.observe(h.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.sources.log.count("cancel.responseRead"), 0)
    XCTAssertEqual(h.results.count, 0)
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.sources.log.count("cancel.responseRead"), 1)
    XCTAssertEqual(h.results.count, 0)
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
    XCTAssertEqual(h.values, [Data([1, 2, 3])])
    XCTAssertEqual(h.reads.count("limit.1"), 2)
    XCTAssertEqual(h.closes.count("close"), 1)
  }
  func testDrainRejectsEOFBeforeExpectedPayload() async throws {
    let h = try FixtureDrainHarness(reads: [(.count(1), Data([1])), (.count(0), Data())])
    h.owner!.observe(h.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.results.count, 0)
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
    XCTAssertTrue(h.values.isEmpty)
    XCTAssertEqual(h.results.errors, [.malformed])
    XCTAssertEqual(h.closes.count("close"), 1)
  }

  func testExactDrainDefersDataAndCloseUntilAcknowledgment() async throws {
    let h = try FixtureDrainHarness(reads: [
      (.count(1), Data([1])), (.failed(EAGAIN), Data()), (.count(2), Data([2, 3])),
      (.count(0), Data()),
    ])
    h.owner!.observe(h.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.results.count, 0)
    h.sources.fire()
    await h.flush()
    XCTAssertEqual(h.sources.log.count("cancel.responseRead"), 1)
    XCTAssertEqual(h.results.count, 0)
    XCTAssertEqual(h.closes.count("close"), 0)
    h.sources.acknowledge()
    await h.flush()
    XCTAssertEqual(h.values, [Data([1, 2, 3])])
    XCTAssertEqual(h.reads.count("limit.1"), 1)
    XCTAssertEqual(h.closes.count("close"), 1)
    h.owner!.observe(h.record)
    await h.flush()
    XCTAssertEqual(h.values.count, 2)
    XCTAssertFalse(h.timers.fire(.eof))
    XCTAssertFalse(h.timers.fire(.cancellation))
  }
  func testDrainCloseUncertaintyIsStickyForLaterCleanup() async throws {
    let h = try FixtureDrainHarness(
      reads: [(.count(3), Data([1, 2, 3])), (.count(0), Data())], closeError: EBADF)
    h.owner!.observe(h.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    h.sources.acknowledge()
    await h.flush()
    h.owner!.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.results.errors, [.uncertainFixtureCleanup])
    XCTAssertEqual(h.cleanup.errors, [.uncertainFixtureCleanup])
    XCTAssertTrue(h.values.isEmpty)
    XCTAssertEqual(h.closes.count("close"), 1)
  }
  func testDrainActiveTimeoutQuarantinesAndLateAckNeverCloses() async throws {
    let h = try FixtureDrainHarness(reads: [])
    h.owner!.observe(h.record)
    await h.flush()
    XCTAssertTrue(h.timers.fire(.eof))
    await h.flush()
    XCTAssertEqual(h.sources.log.count("cancel.responseRead"), 1)
    XCTAssertEqual(h.retention.count, 1)
    weak var retained = h.owner
    h.owner = nil
    XCTAssertNotNil(retained)
    h.sources.acknowledge()
    await h.flush()
    retained?.observeCleanup(h.cleanup.record)
    await h.flush()
    XCTAssertEqual(h.results.errors, [.peerOperationTimedOut])
    XCTAssertEqual(h.cleanup.errors, [.peerOperationTimedOut])
    XCTAssertEqual(h.closes.count("close"), 0)
    retained = nil
  }
  func testDrainCancellationTimeoutDoesNotExposePendingBytes() async throws {
    let h = try FixtureDrainHarness(reads: [(.count(3), Data([1, 2, 3])), (.count(0), Data())])
    h.owner!.observe(h.record)
    await h.flush()
    h.sources.fire()
    await h.flush()
    XCTAssertTrue(h.timers.fire(.cancellation))
    await h.flush()
    XCTAssertTrue(h.values.isEmpty)
    XCTAssertEqual(h.results.errors, [.peerOperationTimedOut])
    h.sources.acknowledge()
    await h.flush()
    XCTAssertEqual(h.closes.count("close"), 0)
  }
}
private final class FixtureDrainHarness: @unchecked Sendable {
  let queue = DispatchQueue(label: "fixture.drain.injected")
  let sources = FixtureSources()
  let timers = FixtureManualTimers()
  let retention = FixtureDrainRetention()
  let closes = ChannelLog()
  let reads = ChannelLog()
  let results = FixtureResults()
  let cleanup = FixtureResults()
  private let lock = NSLock()
  private var storage: [Data] = []
  var owner: FixturePeerDrain?
  var values: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  init(reads: [(ChannelIOResult, Data)], closeError: Int32 = 0) throws {
    let closes = closes
    let cell = PipeDescriptorCell(41) { _ in
      closes.record("close")
      return closeError
    }
    let timers = timers
    var pending = reads
    let calls = self.reads
    owner = try FixturePeerDrain(
      cell: cell, expected: 3, queue: queue, factory: sources,
      read: { _, requested in
        calls.record("limit.\(requested)")
        return pending.isEmpty ? (.failed(EAGAIN), Data()) : pending.removeFirst()
      },
      schedule: { kind, queue, action in timers.schedule(kind, queue: queue, action: action) },
      retention: retention)
  }
  func record(_ result: Result<Data, Error>) {
    if case .success(let value) = result {
      lock.lock()
      storage.append(value)
      lock.unlock()
    }
    results.record(result.map { _ in () })
  }
  func flush() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }
}

/// Wrappers call the real Darwin/Dispatch adapters; records never manufacture OS callbacks.
private final class RecordingPipeIO: ChannelDescriptorOperations, @unchecked Sendable {
  let log: ChannelLog
  let names: [Int32: String]
  init(log: ChannelLog, names: [Int32: String]) {
    self.log = log
    self.names = names
  }
  func read(fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> ChannelIOResult {
    let value = DarwinChannelDescriptorOperations().read(fd: fd, into: buffer)
    log.record("io.read")
    record(value, operation: "read")
    return value
  }
  func write(fd: Int32, from buffer: UnsafeRawBufferPointer) -> ChannelIOResult {
    let value = DarwinChannelDescriptorOperations().write(fd: fd, from: buffer)
    log.record("io.write")
    record(value, operation: "write")
    return value
  }
  private func record(_ value: ChannelIOResult, operation: String) {
    switch value {
    case .failed(let error) where error == EAGAIN || error == EWOULDBLOCK:
      log.record(operation + ".eagain")
    case .failed(let error): log.record(operation + ".errno.\(error)")
    case .count(let count): log.record(operation + ".count.\(count)")
    }
  }
  func close(fd: Int32) -> Int32 {
    let value = DarwinChannelDescriptorOperations().close(fd: fd)
    log.record("close.\(names[fd] ?? "unknown").\(value == 0 ? "confirmed" : "uncertain")")
    return value
  }
}
private final class RecordingPipeSources: ChannelSourceFactory, @unchecked Sendable {
  let log: ChannelLog
  init(log: ChannelLog) { self.log = log }
  func make(
    kind: ChannelSourceKind, fd: Int32, queue: DispatchQueue,
    event: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void
  ) -> any ChannelReadinessSource {
    let log = log
    let source = DispatchChannelSourceFactory().make(
      kind: kind, fd: fd, queue: queue,
      event: {
        log.record("event.\(kind)")
        event()
      },
      cancelled: {
        log.record("ack.\(kind)")
        cancelled()
      })
    return RecordingPipeSource(source: source, kind: kind, log: log)
  }
}
private final class RecordingPipeSource: ChannelReadinessSource, @unchecked Sendable {
  let source: any ChannelReadinessSource
  let kind: ChannelSourceKind
  let log: ChannelLog
  init(source: any ChannelReadinessSource, kind: ChannelSourceKind, log: ChannelLog) {
    self.source = source
    self.kind = kind
    self.log = log
  }
  func activate() {
    log.record("activate.\(kind)")
    source.activate()
  }
  func suspend() { source.suspend() }
  func resume() { source.resume() }
  func cancel() {
    log.record("cancel.\(kind)")
    source.cancel()
  }
}
private struct RecordedPipeChannel {
  let channel: SearchChildChannels
  let log: ChannelLog
  let oldRequest: Int32
}
private final class FixtureTask<Value: Sendable> {
  private let task: Task<Value, Error>
  private let finished: XCTestExpectation
  init(_ operation: @escaping @Sendable () async throws -> Value) {
    let done = XCTestExpectation(description: "owned pipe operation completed")
    finished = done
    task = Task {
      defer { done.fulfill() }
      return try await operation()
    }
  }
  func value() async throws -> Value {
    guard await XCTWaiter.fulfillment(of: [finished], timeout: 30) == .completed else {
      task.cancel()
      throw PipeFixtureError.peerOperationTimedOut
    }
    return try await task.value
  }
  func cancel() { task.cancel() }
  deinit { task.cancel() }
}
private struct FixturePeerCleanupFailures: Error { let errors: [Error] }
private struct FixtureSentinel {
  let read: PipeDescriptorCell
  let write: PipeDescriptorCell
}

extension PipeFixture {
  fileprivate func fillRequestBeforeAdoption() throws -> FixtureFillReceipt {
    guard let requestWrite else { throw PipeFixtureError.malformed }
    let fd = try requestWrite.descriptor()
    return try FixtureFill.run { data in
      data.withUnsafeBytes { DarwinChannelDescriptorOperations().write(fd: fd, from: $0) }
    }
  }
  fileprivate func makeRecordedChannels() -> RecordedPipeChannel {
    let request = transfer(&requestWrite)
    let response = transfer(&responseRead)
    let lifetime = transfer(&lifetimeWrite)
    let log = ChannelLog()
    let operations = RecordingPipeIO(
      log: log, names: [request: "request", response: "response", lifetime: "lifetime"])
    let channel = SearchChildChannels(
      requestWriteFD: request, responseReadFD: response,
      lifetimeWriteFD: lifetime, operations: operations, sources: RecordingPipeSources(log: log),
      observe: { observation in
        switch observation {
        case .readAdmitted: log.record("admit.read")
        case .writeAdmitted(let position): log.record("admit.write.\(position)")
        case .closing: log.record("closing")
        case .closed: log.record("closed")
        case .turn: break
        }
      })
    return RecordedPipeChannel(channel: channel, log: log, oldRequest: request)
  }
  fileprivate func makeRequestDrain(expected: Int) throws -> FixturePeerDrain {
    guard requestDrain == nil, let requestRead else { throw PipeFixtureError.malformed }
    let drain = try FixturePeerDrain(cell: requestRead, expected: expected)
    requestDrain = drain
    self.requestRead = nil
    return drain
  }
  fileprivate func closeResponsePeer() throws {
    guard let responseWrite, responseWrite.closeOnce() == .confirmed else {
      throw PipeFixtureError.uncertainFixtureCleanup
    }
  }
  fileprivate func closeRequestPeer() throws {
    guard let requestRead, requestRead.closeOnce() == .confirmed else {
      throw PipeFixtureError.uncertainFixtureCleanup
    }
  }
  fileprivate func makeReuseSentinel() throws -> FixtureSentinel {
    let (read, write) = try Self.normalizedPipe()
    extraCells += [read, write]
    try Self.enableNonblocking(try read.descriptor())
    try Self.enableNonblocking(try write.descriptor())
    try Self.enableNoSigPipe(try write.descriptor())
    return FixtureSentinel(read: read, write: write)
  }
  fileprivate func reuseClosedRequestNumber(
    _ channel: RecordedPipeChannel, sentinel: FixtureSentinel
  ) throws -> PipeDescriptorCell {
    guard channel.oldRequest > 3, channel.log.count("closed") == 1,
      channel.log.count("ack.requestWrite") == 1,
      channel.log.count("close.request.confirmed") == 1,
      channel.log.count("test.close.returned") >= 1
    else { throw PipeFixtureError.malformed }
    let value = Darwin.fcntl(try sentinel.read.descriptor(), F_DUPFD_CLOEXEC, channel.oldRequest)
    guard value >= 0 else { throw PipeFixtureError.syscall(errno) }
    let alias = PipeDescriptorCell(value)
    extraCells.append(alias)
    // Never overwrite/correct a collision. The unexpected duplicate is fixture-owned
    // and its single close is still accounted by final cleanup.
    guard value == channel.oldRequest else { throw PipeFixtureError.malformed }
    try Self.verifyCloexec(value)
    return alias
  }
  fileprivate func verifySentinel(
    _ sentinel: FixtureSentinel, alias: PipeDescriptorCell, byte: UInt8
  ) throws {
    let payload = Data([byte, byte ^ 0xFF, byte])
    let writer = try sentinel.write.descriptor()
    let written = payload.withUnsafeBytes {
      DarwinChannelDescriptorOperations().write(fd: writer, from: $0)
    }
    guard written == .count(payload.count) else { throw PipeFixtureError.malformed }
    var result = Data(count: payload.count)
    let fd = try alias.descriptor()
    let read = result.withUnsafeMutableBytes {
      DarwinChannelDescriptorOperations().read(fd: fd, into: $0)
    }
    guard read == .count(payload.count), result == payload else { throw PipeFixtureError.malformed }
  }
}
