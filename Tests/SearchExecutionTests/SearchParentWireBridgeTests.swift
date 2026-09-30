import Foundation
import XCTest

@testable import SearchExecution

final class SearchParentWireBridgeTests: XCTestCase {
  private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private func identity(_ epoch: UInt64 = 1) throws -> SearchParentWriterIdentity {
    try SearchParentWriterIdentity(generation: generation, requestID: nil, writerEpoch: epoch)
  }
  private func token() throws -> SearchParentCodecToken {
    try SearchParentCodecToken(
      generation: generation, sessionEpoch: 1,
      operationID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
  }

  func testWholeWriteAcknowledgementPreventsSecondDeposit() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let writer = HeldWriter()
    writer.inspectEntry = { ordinal in
      if ordinal == 1 {
        // Positive early-ACK oracle runs inside the write before its release.
        XCTAssertNil(bridge.snapshot.lastAcknowledged)
        XCTAssertEqual(bridge.snapshot.slot, .inFlight(1))
        XCTAssertTrue(bridge.snapshot.consumerLeaseLive)
      }
    }
    let consumer = Task { try await bridge.consume { try await writer.write($0) } }
    let lane = SearchParentCodecLane()
    defer {
      writer.releaseAll()
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([65]))
      try bridge.emit(Data([66]))
    }
    await writer.entered(1)
    XCTAssertEqual(writer.snapshot.calls, 1)
    XCTAssertEqual(bridge.snapshot.currentToken?.sequence, 1)
    XCTAssertTrue(bridge.snapshot.producerEmitActive)
    XCTAssertFalse(bridge.snapshot.settled)
    writer.release(1)
    await writer.entered(2)
    XCTAssertEqual(bridge.snapshot.lastAcknowledged?.sequence, 1)
    XCTAssertEqual(writer.snapshot.maximumActive, 1)
    writer.release(2)
    try await finishProducer(producer, bridge: bridge)
    try await consumer.value
    XCTAssertEqual(writer.snapshot.firstBytes, [65, 66])
    XCTAssertEqual(bridge.snapshot.lastAcknowledged?.sequence, 2)
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testClosedProducerDoesNotSettleHeldConsumer() async throws {
    for lateError in [false, true] {
      let bridge = SearchParentWireUploadBridge(identity: try identity())
      let writer = HeldWriter(copyInput: true)
      let lane = SearchParentCodecLane()
      defer {
        writer.releaseAll()
        bridge.close(.child(.cancelled))
        lane.requestStop()
      }
      let consumer = Task { try await bridge.consume { try await writer.write($0) } }
      let producer = try lane.submit(token: token()) {
        try bridge.emit(Data([7]))
      }
      await writer.entered(1)
      XCTAssertEqual(writer.snapshot.connectionCopies, 1)
      XCTAssertTrue(bridge.snapshot.producerEmitActive)
      XCTAssertEqual(bridge.snapshot.slot, .inFlight(1))
      XCTAssertTrue(bridge.snapshot.consumerLeaseLive)
      // Four conservative logical ownership roles; no backing-sharing/RSS claim.
      let logicalOwners =
        (bridge.snapshot.producerEmitActive ? 1 : 0)
        + (bridge.snapshot.slot == .inFlight(1) ? 1 : 0)
        + (bridge.snapshot.consumerLeaseLive ? 1 : 0) + writer.snapshot.connectionCopies
      XCTAssertEqual(logicalOwners, 4)
      bridge.close(.child(.cancelled))
      do {
        try await finishProducer(producer, bridge: bridge)
        XCTFail("Closed producer succeeded")
      } catch { XCTAssertEqual(error as? SearchParentWireFailure, .child(.cancelled)) }
      // Child close/reap are intentionally not inputs to this parent-owner latch.
      XCTAssertTrue(bridge.snapshot.producerExited)
      XCTAssertFalse(bridge.snapshot.consumerExited)
      XCTAssertTrue(bridge.snapshot.consumerLeaseLive)
      XCTAssertFalse(bridge.snapshot.settled)
      XCTAssertEqual(writer.snapshot.connectionCopies, 1)
      writer.release(1, failure: lateError ? .channelFailure(32) : nil)
      do {
        try await consumer.value
        XCTFail("Cancelled consumer succeeded")
      } catch { XCTAssertEqual(error as? SearchParentWireFailure, .child(.cancelled)) }
      XCTAssertTrue(bridge.snapshot.settled)
      XCTAssertEqual(writer.snapshot.connectionCopies, 0)
      XCTAssertNil(bridge.snapshot.lastAcknowledged)
      lane.requestStop()
      try await lane.waitForStop()
    }
  }

  func testCloseBeforeDepositAndFirstFailureArePreserved() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    bridge.close(.child(.deadline))
    bridge.close(.child(.cancelled))
    XCTAssertThrowsError(try bridge.emit(Data([1]))) {
      XCTAssertEqual($0 as? SearchParentWireFailure, .child(.deadline))
    }
    bridge.producerExited(.failure(SearchWireError.invalidPhase))
    do { try await bridge.consume { _ in XCTFail("Closed bridge wrote bytes") } } catch {
      XCTAssertEqual(error as? SearchParentWireFailure, .child(.deadline))
    }
    XCTAssertEqual(bridge.snapshot.firstError, .child(.deadline))
    XCTAssertTrue(bridge.snapshot.settled)
  }

  func testExactTokenAndLeaseReleaseRequiredForAcknowledgement() async throws {
    let id = try identity()
    let bridge = SearchParentWireUploadBridge(identity: id)
    let writer = HeldWriter()
    let lane = SearchParentCodecLane()
    defer {
      writer.releaseAll()
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task { try await bridge.consume { try await writer.write($0) } }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
    }
    await writer.entered(1)
    for candidate in [
      SearchParentEmissionToken(writer: try identity(2), sequence: 1),
      SearchParentEmissionToken(writer: id, sequence: 2),
      SearchParentEmissionToken(writer: id, sequence: 1),
    ] {
      XCTAssertFalse(bridge.acknowledge(candidate, result: .success(())))
    }
    XCTAssertNil(bridge.snapshot.lastAcknowledged)
    XCTAssertTrue(bridge.snapshot.consumerLeaseLive)
    writer.release(1)
    try await finishProducer(producer, bridge: bridge)
    try await consumer.value
    XCTAssertFalse(
      bridge.acknowledge(SearchParentEmissionToken(writer: id, sequence: 1), result: .success(())))
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testForeignAcknowledgementsCannotResolveQuiescentCurrentToken() async throws {
    let id = try identity()
    let otherGeneration = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let foreign = [
      SearchParentEmissionToken(writer: try identity(2), sequence: 1),
      SearchParentEmissionToken(writer: id, sequence: 2),
      SearchParentEmissionToken(
        writer: try SearchParentWriterIdentity(
          generation: otherGeneration, requestID: nil, writerEpoch: 1), sequence: 1),
      SearchParentEmissionToken(
        writer: try SearchParentWriterIdentity(
          generation: generation, requestID: otherGeneration, writerEpoch: 1), sequence: 1),
    ]
    let weakBridge = WeakBridgeBox()
    let attempts = LockedValues<Bool>()
    let bridge = SearchParentWireUploadBridge(
      identity: id,
      observeWriteScopeExit: { token in
        guard let bridge = weakBridge.value else {
          XCTFail("Bridge lost")
          return
        }
        XCTAssertFalse(bridge.snapshot.consumerLeaseLive)
        XCTAssertEqual(bridge.snapshot.currentToken, token)
        for stale in foreign {
          let accepted = bridge.acknowledge(stale, result: .success(()))
          attempts.append(accepted)
          XCTAssertFalse(accepted)
          if accepted {
            bridge.close(.child(.cancelled))
            return
          }
          XCTAssertEqual(bridge.snapshot.currentToken, token)
          XCTAssertNil(bridge.snapshot.lastAcknowledged)
        }
      })
    weakBridge.value = bridge
    let lane = SearchParentCodecLane()
    defer {
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task { try await bridge.consume { _ in } }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
    }
    try await finishProducer(producer, bridge: bridge)
    try await consumer.value
    XCTAssertEqual(attempts.values, [false, false, false, false])
    XCTAssertEqual(
      bridge.snapshot.lastAcknowledged, SearchParentEmissionToken(writer: id, sequence: 1))
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testCloseAfterWriteScopeButBeforeAcknowledgementWins() async throws {
    let weakBridge = WeakBridgeBox()
    let bridge = SearchParentWireUploadBridge(
      identity: try identity(),
      observeWriteScopeExit: { _ in
        guard let bridge = weakBridge.value else {
          XCTFail("Bridge lost")
          return
        }
        XCTAssertFalse(bridge.snapshot.consumerLeaseLive)
        XCTAssertNil(bridge.snapshot.lastAcknowledged)
        bridge.close(.child(.deadline))
      })
    weakBridge.value = bridge
    let lane = SearchParentCodecLane()
    defer {
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task { try await bridge.consume { _ in } }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
    }
    do {
      try await finishProducer(producer, bridge: bridge)
      XCTFail("Late acknowledgement ignored close")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .child(.deadline)) }
    do {
      try await consumer.value
      XCTFail("Late acknowledgement ignored close")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .child(.deadline)) }
    XCTAssertNil(bridge.snapshot.lastAcknowledged)
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testBoundsAndOneWritePerEmission() async throws {
    for size in [1, 32, 65_536] {
      let bridge = SearchParentWireUploadBridge(identity: try identity())
      let lane = SearchParentCodecLane()
      let counts = LockedValues<Int>()
      defer {
        bridge.close(.child(.cancelled))
        lane.requestStop()
      }
      let consumer = Task { try await bridge.consume { bytes in counts.append(bytes.count) } }
      let producer = try lane.submit(token: token()) {
        try bridge.emit(Data(repeating: 1, count: size))
      }
      try await finishProducer(producer, bridge: bridge)
      try await consumer.value
      XCTAssertEqual(counts.values, [size])
      XCTAssertTrue(bridge.snapshot.settled)
      lane.requestStop()
      try await lane.waitForStop()
    }
    for size in [0, 65_537] {
      let bridge = SearchParentWireUploadBridge(identity: try identity())
      XCTAssertThrowsError(try bridge.emit(Data(repeating: 1, count: size))) {
        XCTAssertEqual($0 as? SearchParentWireFailure, .invalidChunk)
      }
      bridge.producerExited(.failure(SearchParentWireFailure.invalidChunk))
      do { try await bridge.consume { _ in XCTFail("Invalid chunk written") } } catch {
        XCTAssertEqual(error as? SearchParentWireFailure, .invalidChunk)
      }
      XCTAssertTrue(bridge.snapshot.settled)
    }
  }

  func testHeldProducerKeepsLaneAndSourceUntilActualExit() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let lane = SearchParentCodecLane()
    let entered = AsyncSignal()
    let gate = BlockingGate()
    defer {
      gate.open()
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let source = WeakBox()
    let producer = try submitSourceJob(lane, token: token(), source: source) {
      entered.signal()
      gate.wait()
      try bridge.emit(Data([1]))
    }
    let consumer = Task { try await bridge.consume { _ in XCTFail("Cancelled producer emitted") } }
    await entered.wait()
    bridge.close(.child(.cancelled))
    XCTAssertTrue(lane.snapshot.busy)
    XCTAssertNotNil(source.value)
    XCTAssertFalse(bridge.snapshot.producerExited)
    XCTAssertFalse(bridge.snapshot.settled)
    XCTAssertThrowsError(try lane.submit(token: token()) { 9 }) {
      XCTAssertEqual($0 as? SearchParentCodecLaneError, .busy)
    }
    gate.open()
    do {
      try await finishProducer(producer, bridge: bridge)
      XCTFail("Cancelled producer succeeded")
    } catch {}
    do {
      try await consumer.value
      XCTFail("Cancelled consumer succeeded")
    } catch {}
    XCTAssertNil(source.value)
    XCTAssertTrue(bridge.snapshot.settled)
    let next = try lane.submit(token: token()) {
      XCTAssertNil(source.value)
      return 9
    }
    let nextValue = try await next.value()
    XCTAssertEqual(nextValue, 9)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testLaneReceiptTransfersOnceAndCancelledObserverDoesNotCancelJob() async throws {
    let lane = SearchParentCodecLane()
    let gate = BlockingGate()
    let entered = AsyncSignal()
    defer {
      gate.open()
      lane.requestStop()
    }
    let work = try lane.submit(token: token()) {
      entered.signal()
      gate.wait()
      return 42
    }
    await entered.wait()
    let observerEntered = AsyncSignal()
    let observer = Task {
      observerEntered.signal()
      return try await work.value()
    }
    await observerEntered.wait()
    // Receipt registration must be observable without a timing assumption.
    for _ in 0..<10_000 {
      if work.hasObserver { break }
      await Task.yield()
    }
    XCTAssertTrue(work.hasObserver)
    observer.cancel()
    do {
      _ = try await work.value()
      XCTFail("Second observer accepted")
    } catch { XCTAssertEqual(error as? SearchParentCodecLaneError, .observerBusy) }
    gate.open()
    let observed = try await observer.value
    XCTAssertEqual(observed, 42)
    do {
      _ = try await work.value()
      XCTFail("Repeated transfer accepted")
    } catch { XCTAssertEqual(error as? SearchParentCodecLaneError, .staleWork) }
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testLaneStopWaitsForBodyAndAbandonedReceiptDoesNotOrphanIt() async throws {
    let lane = SearchParentCodecLane()
    let entered = AsyncSignal()
    let exited = AsyncSignal()
    let gate = BlockingGate()
    defer {
      gate.open()
      lane.requestStop()
    }
    _ = try lane.submit(token: token()) {
      entered.signal()
      gate.wait()
      exited.signal()
    }
    await entered.wait()
    lane.requestStop()
    XCTAssertTrue(lane.snapshot.busy)
    XCTAssertFalse(lane.snapshot.loopStopped)
    XCTAssertThrowsError(try lane.submit(token: token()) {}) {
      XCTAssertEqual($0 as? SearchParentCodecLaneError, .stopped)
    }
    gate.open()
    await exited.wait()
    try await lane.waitForStop()
    XCTAssertTrue(lane.snapshot.loopStopped)
  }

  func testConsumerPayloadDeallocatorReentersBeforeConsumerExit() async throws {
    let deallocations = LockedValues<Int>()
    let scopes = LockedValues<Int>()
    let weakBridge = WeakBridgeBox()
    let bridge = SearchParentWireUploadBridge(
      identity: try identity(),
      observeWriteScopeExit: { _ in
        guard let bridge = weakBridge.value else { return XCTFail("Bridge disappeared") }
        XCTAssertEqual(deallocations.values, [1])
        XCTAssertTrue(bridge.snapshot.producerExited)
        XCTAssertEqual(bridge.snapshot.slot, .empty)
        XCTAssertFalse(bridge.snapshot.consumerLeaseLive)
        XCTAssertFalse(bridge.snapshot.consumerExited)
        XCTAssertFalse(bridge.snapshot.settled)
        scopes.append(1)
      })
    weakBridge.value = bridge
    let lane = SearchParentCodecLane()
    let entered = AsyncSignal()
    let release = AsyncSignal()
    defer {
      release.signal()
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task {
      try await bridge.consume { bytes in
        entered.signal()
        await release.wait()
        withExtendedLifetime(bytes) {}
      }
    }
    let producer = try lane.submit(token: token()) {
      let pointer = UnsafeMutableRawPointer.allocate(byteCount: 32_768, alignment: 1)
      pointer.initializeMemory(as: UInt8.self, repeating: 1, count: 32_768)
      do {
        try bridge.emit(
          Data(
            bytesNoCopy: pointer, count: 32_768,
            deallocator: .custom { pointer, _ in
              // This payload-release callback deliberately reenters the condition.
              // Lease metadata remains live until its payload destructor returns.
              XCTAssertTrue(bridge.snapshot.producerExited)
              XCTAssertTrue(bridge.snapshot.consumerLeaseLive)
              XCTAssertFalse(bridge.snapshot.consumerExited)
              XCTAssertFalse(bridge.snapshot.settled)
              bridge.close(.child(.deadline))
              XCTAssertEqual(bridge.snapshot.firstError, .child(.cancelled))
              deallocations.append(1)
              pointer.deallocate()
            }))

      } catch { throw error }
    }
    await entered.wait()
    XCTAssertTrue(deallocations.values.isEmpty)
    bridge.close(.child(.cancelled))
    do {
      try await finishProducer(producer, bridge: bridge)
      XCTFail("Producer ignored close")
    } catch {}
    XCTAssertTrue(deallocations.values.isEmpty)
    release.signal()
    do {
      try await consumer.value
      XCTFail("Consumer ignored close")
    } catch {}
    XCTAssertEqual(deallocations.values, [1])
    XCTAssertEqual(scopes.values, [1])
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testWriteFailureNormalizesUnknownPayloadAndPreservesFirstReason() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let lane = SearchParentCodecLane()
    let weakOwner = WeakBox()
    defer {
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task {
      try await bridge.consume { _ in
        let owner = SourceOwner()
        weakOwner.value = owner
        throw PayloadError(owner: owner)
      }
    }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
    }
    do {
      try await finishProducer(producer, bridge: bridge)
      XCTFail("Write failure lost")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .writeFailure) }
    do {
      try await consumer.value
      XCTFail("Write failure lost")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .writeFailure) }
    bridge.close(.child(.deadline))
    XCTAssertEqual(bridge.snapshot.firstError, .writeFailure)
    XCTAssertNil(weakOwner.value)
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testProducerFailureNormalizesUnknownPayload() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let weakOwner = WeakBox()
    func fail() {
      let owner = SourceOwner()
      weakOwner.value = owner
      bridge.producerExited(.failure(PayloadError(owner: owner)))
    }
    fail()
    XCTAssertNil(weakOwner.value)
    do {
      try await bridge.consume { _ in XCTFail("Unexpected write") }
      XCTFail("Failure lost")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .producerFailure) }
    XCTAssertTrue(bridge.snapshot.settled)
  }

  func testDuplicateConsumerCannotSetOriginalConsumerExitLatch() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let writer = HeldWriter()
    let lane = SearchParentCodecLane()
    defer {
      writer.releaseAll()
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task { try await bridge.consume { try await writer.write($0) } }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
    }
    await writer.entered(1)
    do {
      try await bridge.consume { _ in XCTFail("Duplicate consumer wrote") }
      XCTFail("Accepted duplicate")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .duplicateConsumer) }
    XCTAssertFalse(bridge.snapshot.consumerExited)
    XCTAssertTrue(bridge.snapshot.consumerLeaseLive)
    writer.release(1)
    try await finishProducer(producer, bridge: bridge)
    try await consumer.value
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testConcurrentProducerRefusalClosesExactOriginalWrite() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let writer = HeldWriter()
    let lane = SearchParentCodecLane()
    let otherLane = SearchParentCodecLane()
    defer {
      writer.releaseAll()
      bridge.close(.child(.cancelled))
      lane.requestStop()
      otherLane.requestStop()
    }
    let consumer = Task { try await bridge.consume { try await writer.write($0) } }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
    }
    await writer.entered(1)
    let intruder = try otherLane.submit(token: token()) { try bridge.emit(Data([2])) }
    do {
      try await intruder.value()
      XCTFail("Second producer admitted")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .concurrentProducer) }
    do {
      try await finishProducer(producer, bridge: bridge)
      XCTFail("First producer not woken")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .concurrentProducer) }
    XCTAssertFalse(bridge.snapshot.settled)
    writer.release(1)
    do {
      try await consumer.value
      XCTFail("Closed consumer succeeded")
    } catch { XCTAssertEqual(error as? SearchParentWireFailure, .concurrentProducer) }
    XCTAssertEqual(writer.snapshot.calls, 1)
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    otherLane.requestStop()
    try await lane.waitForStop()
    try await otherLane.waitForStop()
  }

  func testAcknowledgementBeforeCloseRemainsRecordedAndNextEmitFails() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let lane = SearchParentCodecLane()
    let between = AsyncSignal()
    let gate = BlockingGate()
    defer {
      gate.open()
      bridge.close(.child(.cancelled))
      lane.requestStop()
    }
    let consumer = Task { try await bridge.consume { _ in } }
    let producer = try lane.submit(token: token()) {
      try bridge.emit(Data([1]))
      between.signal()
      gate.wait()
      try bridge.emit(Data([2]))
    }
    await between.wait()
    XCTAssertEqual(bridge.snapshot.lastAcknowledged?.sequence, 1)
    bridge.close(.child(.cancelled))
    gate.open()
    do {
      try await finishProducer(producer, bridge: bridge)
      XCTFail("Next emit ignored close")
    } catch {}
    do {
      try await consumer.value
      XCTFail("Consumer ignored close")
    } catch {}
    XCTAssertEqual(bridge.snapshot.lastAcknowledged?.sequence, 1)
    XCTAssertTrue(bridge.snapshot.settled)
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testCleanProducerExitWakesConsumerWithoutAnyChunk() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    let consumer = Task { try await bridge.consume { _ in XCTFail("Empty writer emitted") } }
    bridge.producerExited(.success(()))
    try await consumer.value
    XCTAssertTrue(bridge.snapshot.settled)
    XCTAssertNil(bridge.snapshot.lastAcknowledged)
  }

  func testLaneRetainsOneOSThreadAcrossJobsAndTransfersErrors() async throws {
    let lane = SearchParentCodecLane()
    defer { lane.requestStop() }
    let first = try lane.submit(token: token()) { () -> ObjectIdentifier in
      XCTAssertFalse(Thread.isMainThread)
      return ObjectIdentifier(Thread.current)
    }
    let firstThread = try await first.value()
    let second = try lane.submit(token: token()) { ObjectIdentifier(Thread.current) }
    let secondThread = try await second.value()
    XCTAssertEqual(firstThread, secondThread)
    let failed = try lane.submit(token: token()) { throw SearchWireError.invalidPhase }
    do {
      _ = try await failed.value()
      XCTFail("Job error lost")
    } catch { XCTAssertEqual(error as? SearchWireError, .invalidPhase) }
    lane.requestStop()
    try await lane.waitForStop()
  }

  func testRepeatedProducerExitCannotRewriteCleanFirstResult() async throws {
    let bridge = SearchParentWireUploadBridge(identity: try identity())
    bridge.producerExited(.success(()))
    bridge.producerExited(.failure(SearchWireError.invalidPhase))
    do { try await bridge.consume { _ in XCTFail("Unexpected write") } } catch {
      XCTFail("Duplicate producer exit rewrote clean completion: \(error)")
    }
    XCTAssertNil(bridge.snapshot.firstError)
    XCTAssertTrue(bridge.snapshot.settled)
  }

  func testInvalidIdentitiesAreRejectedBeforeLaneOrBridgeConstruction() throws {
    let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    XCTAssertThrowsError(
      try SearchParentWriterIdentity(generation: zero, requestID: nil, writerEpoch: 1))
    XCTAssertThrowsError(
      try SearchParentWriterIdentity(generation: generation, requestID: zero, writerEpoch: 1))
    XCTAssertThrowsError(
      try SearchParentWriterIdentity(generation: generation, requestID: nil, writerEpoch: 0))
    XCTAssertThrowsError(
      try SearchParentCodecToken(generation: zero, sessionEpoch: 1, operationID: generation))
    XCTAssertThrowsError(
      try SearchParentCodecToken(generation: generation, sessionEpoch: 0, operationID: generation))
    XCTAssertThrowsError(
      try SearchParentCodecToken(generation: generation, sessionEpoch: 1, operationID: zero))
  }

  private func finishProducer(
    _ work: SearchParentCodecWork<Void>, bridge: SearchParentWireUploadBridge
  ) async throws {
    // value returns only after the thread has released its job/body owners.
    // Producer exit is therefore an actual scope receipt, not a tail callback.
    do {
      try await work.value()
      bridge.producerExited(.success(()))
    } catch {
      bridge.producerExited(.failure(error))
      throw error
    }
  }

  private func submitSourceJob(
    _ lane: SearchParentCodecLane, token: SearchParentCodecToken, source: WeakBox,
    body: @escaping @Sendable () throws -> Void
  ) throws -> SearchParentCodecWork<Void> {
    let owner = SourceOwner()
    source.value = owner
    return try lane.submit(token: token) { [owner] in
      defer { withExtendedLifetime(owner) {} }
      try body()
    }
  }
}

private final class SourceOwner: Sendable {}
private struct PayloadError: Error { let owner: SourceOwner }
private final class WeakBridgeBox: @unchecked Sendable {
  weak var value: SearchParentWireUploadBridge?
}
private final class WeakBox: @unchecked Sendable { weak var value: SourceOwner? }
private final class BlockingGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var opened = false
  func wait() {
    condition.lock()
    while !opened { condition.wait() }
    condition.unlock()
  }
  func open() {
    condition.lock()
    opened = true
    condition.broadcast()
    condition.unlock()
  }
}
private final class AsyncSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiter: CheckedContinuation<Void, Never>?
  func signal() {
    lock.lock()
    fired = true
    let value = waiter
    waiter = nil
    lock.unlock()
    value?.resume()
  }
  func wait() async {
    await withCheckedContinuation { value in
      lock.lock()
      if fired {
        lock.unlock()
        value.resume()
      } else {
        precondition(waiter == nil)
        waiter = value
        lock.unlock()
      }
    }
  }
}
private final class LockedValues<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [T] = []
  func append(_ value: T) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
  var values: [T] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class HeldWriter: @unchecked Sendable {
  struct Snapshot {
    let calls: Int
    let maximumActive: Int
    let connectionCopies: Int
    let firstBytes: [UInt8]
  }
  private let lock = NSLock()
  private var calls = 0
  private var active = 0
  private var maximum = 0
  private var copies = 0
  private var values: [UInt8] = []
  private var enteredSignals: [Int: AsyncSignal] = [:]
  private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
  private var outcomes: [Int: SearchChildFailure?] = [:]
  private var releaseEverything = false
  private let copyInput: Bool
  var inspectEntry: (@Sendable (Int) -> Void)?
  init(copyInput: Bool = false) { self.copyInput = copyInput }
  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      calls: calls, maximumActive: maximum, connectionCopies: copies, firstBytes: values)
  }
  func entered(_ ordinal: Int) async { await signal(for: ordinal).wait() }
  private func signal(for ordinal: Int) -> AsyncSignal {
    lock.lock()
    defer { lock.unlock() }
    if let value = enteredSignals[ordinal] { return value }
    let value = AsyncSignal()
    enteredSignals[ordinal] = value
    return value
  }
  func write(_ bytes: Data) async throws {
    let ordinal = begin(bytes)
    var copied: Data? =
      copyInput
      ? bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) } : nil
    defer {
      copied = nil
      end()
    }
    inspectEntry?(ordinal)
    signal(for: ordinal).signal()
    try await withCheckedThrowingContinuation { continuation in
      install(continuation, ordinal: ordinal)
    }
    withExtendedLifetime(copied) {}
  }
  private func begin(_ bytes: Data) -> Int {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    active += 1
    maximum = max(maximum, active)
    if copyInput { copies += 1 }
    values.append(bytes.first ?? 0)
    return calls
  }
  private func end() {
    lock.lock()
    active -= 1
    if copyInput { copies -= 1 }
    lock.unlock()
  }
  private func install(_ waiter: CheckedContinuation<Void, Error>, ordinal: Int) {
    lock.lock()
    if releaseEverything {
      lock.unlock()
      waiter.resume()
      return
    }
    if let result = outcomes.removeValue(forKey: ordinal) {
      lock.unlock()
      if let result { waiter.resume(throwing: result) } else { waiter.resume() }
    } else {
      pending[ordinal] = waiter
      lock.unlock()
    }
  }
  func release(_ ordinal: Int, failure: SearchChildFailure? = nil) {
    lock.lock()
    let waiter = pending.removeValue(forKey: ordinal)
    if waiter == nil { outcomes.updateValue(failure, forKey: ordinal) }
    lock.unlock()
    if let failure { waiter?.resume(throwing: failure) } else { waiter?.resume() }
  }
  func releaseAll() {
    lock.lock()
    releaseEverything = true
    let waiters = Array(pending.values)
    pending.removeAll()
    lock.unlock()
    for waiter in waiters { waiter.resume() }
  }
}
