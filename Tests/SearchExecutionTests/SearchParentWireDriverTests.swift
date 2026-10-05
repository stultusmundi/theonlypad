import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchParentWireDriverTests: XCTestCase {
  func testJobRejectsZeroIdentityAndInvalidScopeBeforeAdmission() throws {
    let limits = try SearchWireLimits(
      maxTextUTF16: 8, maxOutputUTF16: 8,
      maxMatches: 8, cooperativeMilliseconds: 0)
    XCTAssertThrowsError(
      try SearchParentWireJob(
        requestID: SearchWireBinary.zeroUUID,
        query: SearchQuery(pattern: "x", mode: .literal), operation: .find, text: "x",
        inputUTF16: 1,
        scope: nil, limits: limits)
    ) { XCTAssertEqual($0 as? SearchParentWireDriverError, .invalidJob) }
    XCTAssertThrowsError(
      try SearchParentWireJob(
        requestID: UUID(),
        query: SearchQuery(pattern: "x", mode: .literal), operation: .find, text: "x",
        inputUTF16: 1,
        scope: NSRange(location: 1, length: Int.max), limits: limits)
    ) {
      XCTAssertEqual($0 as? SearchParentWireDriverError, .invalidJob)
    }
  }

  func testFragmentedHandshakeEOFProducesHandshakeFailureWithoutRequest() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7102, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(Data(try DriverTestWire.childHello(generation: generation).prefix(10)))
    await h.connection.waitForReadCalls(2)
    h.connection.offer(Data())
    let outcome = try await driver.wait(for: handle)
    XCTAssertEqual(
      outcome,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .handshakeFailure))
    XCTAssertEqual(h.connection.snapshot.writeSizes.count, 2)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testTerminalWithHeaderOnlySuffixIsProtocolFailure() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7103, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await h.connection.waitForWriteCalls(7)
    let identity = try SearchWireIdentity(
      generation: generation, requestID: handle.requestID, ordinal: 1)
    let response = try DriverTestWire.success(identity: identity)
    h.connection.offer(response + response.suffix(48).prefix(32))
    let outcome = try await driver.wait(for: handle)
    XCTAssertEqual(outcome, .failed(identity: identity, failure: .protocolFailure))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testWriteErrnoSurvivesSinkRejection() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    // Parent hello is two emits. Fail the first request emit after successful handshake.
    h.connection.enqueueWrite(.init())
    h.connection.enqueueWrite(.init())
    h.connection.enqueueWrite(.init(failure: .channelFailure(5)))
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7104, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    let outcome = try await driver.wait(for: handle)
    XCTAssertEqual(
      outcome,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .channelFailure(5)))
    XCTAssertEqual(h.connection.snapshot.writeSizes.count, 3)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testFastResponseIsHeldUntilExecuteWriteAndExpectFinish() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let executeReturn = DriverTestGate()
    let responseHeld = DriverTestGate()
    let callbacks = DriverTestLocked<[String]>([])
    let events = DriverTestLocked<[SearchParentDriverEvent]>([])
    defer {
      executeReturn.open()
      h.releaseAllGates()
    }
    for _ in 0..<6 { h.connection.enqueueWrite(.init()) }
    h.connection.enqueueWrite(.init(returnRelease: executeReturn))
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: { _ in
        DriverTestAccumulator(onCallback: { name in callbacks.withValue { $0.append(name) } })
      },
      maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        events.withValue { $0.append(event) }
        if case .readHeld(_, let count) = event, count > 56 { responseHeld.open() }
      })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await responseHeld.wait()
    XCTAssertFalse(events.withValue { $0.contains(.expectFinished(handle.nonce)) })
    XCTAssertFalse(callbacks.withValue { $0.contains("begin") })
    XCTAssertEqual(h.connection.readEntered.value, 2)
    executeReturn.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertTrue(events.withValue { $0.contains(.expectFinished(handle.nonce)) })
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testSemanticFailurePreservesExactIdentityAndHasNoSourceOutcome() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(
      try DriverTestWire.semanticFailure(identity: identity, error: .invalidPattern))
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .semanticFailure(identity: identity, error: .invalidPattern))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testCancellationWithHeldWriteReturnsBeforeConsumerButKeepsAdmissionBusy() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let hold = DriverTestGate()
    defer {
      hold.open()
      h.releaseAllGates()
    }
    h.connection.enqueueWrite(.init(returnRelease: hold))
    let delivered = DriverTestLocked(false)
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .resultDelivered = $0 { delivered.withValue { $0 = true } } })
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7110, connection: h.connection)
    await h.connection.waitForWriteCalls(1)
    try await driver.cancel(handle)
    XCTAssertFalse(hold.isOpen)
    do {
      _ = try await driver.submit(job())
      XCTFail("Held consumer still owns admission")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .busy) }
    XCTAssertFalse(delivered.withValue { $0 })
    hold.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .cancelled))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testObserverCancellationDetachesWithoutCancellingOperation() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let installed = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .observerInstalled = $0 { installed.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    let observer = Task { try await driver.wait(for: handle) }
    await installed.wait()
    observer.cancel()
    do {
      _ = try await observer.value
      XCTFail("Cancelled observer must detach")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(h.system.signalCount.value, 0)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testDuplicateObserverAndConsumedHandleAreRejected() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let installed = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .observerInstalled = $0 { installed.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    let observer = Task { try await driver.wait(for: handle) }
    await installed.wait()
    do {
      _ = try await driver.wait(for: handle)
      XCTFail("Only one observer is allowed")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .observerBusy) }
    do {
      try await driver.discard(handle)
      XCTFail("Attached observer owns result delivery")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .observerBusy) }
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await observer.value
    do {
      _ = try await driver.wait(for: handle)
      XCTFail("Result transfers only once")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testUnobservedSuccessRequiresExplicitDiscardBeforeAdmission() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let settled = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { settled.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    do {
      try await driver.discard(handle)
      XCTFail("Active source cannot be discarded")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .notSettled) }
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await settled.wait()
    do {
      _ = try await driver.submit(job())
      XCTFail("Unconsumed success owns admission")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .busy) }
    try await driver.discard(handle)
    do {
      try await driver.discard(handle)
      XCTFail("Discard is one-shot")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testBeginRefusalWithoutTicketSettlesCancellationReceipt() async throws {
    let h = try DriverHarness()
    _ = await h.lifecycle.shutdown()
    let sourceReleased = DriverTestLocked(false)
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .sourceOwnerReleased = $0 { sourceReleased.withValue { $0 = true } } })
    let handle = try await driver.submit(job())
    try await driver.cancel(handle)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .failed(identity: nil, failure: .shutDown))
    XCTAssertTrue(sourceReleased.withValue { $0 })
    XCTAssertEqual(h.system.launchCount.value, 0)
    _ = await driver.shutdown()
  }

  func testDeadlineWinsWhileTerminalCallbackIsHeldOnCodecThread() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let hold = DriverTestBlockingGate()
    let decided = DriverTestGate()
    defer {
      hold.open()
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: { _ in
        DriverTestAccumulator(onCallback: { name in
          if name == "complete" { hold.waitOnCodecThread() }
        })
      }, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .lifecycleDecided(_, .failed(.deadline)) = $0 { decided.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await hold.entered.wait()
    h.timers.fireDue(at: h.clock.advance(by: 1_000_000_000))
    await decided.wait()
    hold.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .failed(identity: identity, failure: .deadline))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testAcceptedTerminalWinsLaterCancel() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let accepted = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .terminalAccepted = $0 { accepted.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await accepted.wait()
    try await driver.cancel(handle)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testByteThresholdRetiresAfterResultAndReadReservation() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let reservedBeforeSignal = DriverTestLocked<Bool?>(nil)
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1,
      observe: {
        if case .idleReadReserved = $0 {
          reservedBeforeSignal.withValue { $0 = h.system.signalCount.value == 0 }
        }
      })
    let (handle, identity) = try await start(h, driver: driver)
    XCTAssertEqual(h.system.signalCount.value, 0, "Threshold must not interrupt the active request")
    h.connection.offer(try DriverTestWire.success(identity: identity))
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(reservedBeforeSignal.withValue { $0 }, true)
    XCTAssertEqual(h.system.signalCount.value, 1)
    // Independent collaborator entry; the metadata receipt only claims action reservation.
    await h.connection.waitForReadCalls(3)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testReusedBeginOverflowRestoresIdleReadWithoutStrandingFailure() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let released = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .sessionReleased = $0 { released.open() } })
    let (first, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: first)
    await h.connection.waitForReadCalls(3)
    h.clock.advance(by: UInt64.max)
    let refused = try await driver.submit(job())
    let result = try await driver.wait(for: refused)
    XCTAssertEqual(result, .failed(identity: nil, failure: .invalidPolicy))
    XCTAssertEqual(
      h.connection.snapshot.activeReads, 1,
      "Healthy old idle read must not block compact no-ticket failure")
    h.connection.offer(Data())
    await released.wait()
    XCTAssertEqual(h.system.launchCount.value, 1)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testUnknownReadErrorIsProtocolFailureWithoutInventedErrno() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offerUnknownFailure()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .failed(identity: identity, failure: .protocolFailure))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testUnknownWriteErrorIsProtocolFailureWithoutInventedErrno() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    h.connection.enqueueWrite(.init(unknownFailure: true))
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7130, connection: h.connection)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .protocolFailure))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testAcceptedResultSurvivesIdleEOFBeforeReap() async throws {
    let h = try DriverHarness()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await h.connection.waitForReadCalls(3)
    h.connection.offer(Data())
    await h.system.signalCount.wait(for: 1)
    // Fake reaper remains running. Result delivery must not await physical cleanup.
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testAcceptedSemanticResultSurvivesIdleErrnoBeforeReap() async throws {
    let h = try DriverHarness()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(
      try DriverTestWire.semanticFailure(identity: identity, error: .invalidPattern))
    await h.connection.waitForReadCalls(3)
    h.connection.offerFailure(.channelFailure(5))
    await h.system.signalCount.wait(for: 1)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .semanticFailure(identity: identity, error: .invalidPattern))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testShutdownReportsHeldCodecProducerUntilItsScopeExits() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let hold = DriverTestBlockingGate()
    defer {
      hold.open()
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: { _ in
        hold.waitOnCodecThread()
        return DriverTestAccumulator()
      },
      maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7140, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await hold.entered.wait()
    let held = await driver.shutdown()
    XCTAssertTrue(held.child.stopped)
    XCTAssertFalse(held.parentLaneSettled)
    XCTAssertEqual(held.retainedParentLanes, 1)
    hold.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .shutDown))
    let settled = await driver.shutdown()
    XCTAssertTrue(settled.parentLaneSettled)
    XCTAssertEqual(settled.retainedParentLanes, 0)
  }

  func testShutdownPreservesRetainedSuccessReceipt() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let settled = DriverTestGate()
    let released = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        if case .coordinatorScopeExited = event { settled.open() }
        if case .sessionReleased = event { released.open() }
      })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await settled.wait()
    _ = await driver.shutdown()
    await released.wait()
    let shutdown = await driver.shutdown()
    XCTAssertTrue(shutdown.parentLaneSettled)
    XCTAssertEqual(shutdown.retainedParentLanes, 0)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
  }

  func testDroppingFacadeWhileIdleStartsRetainedCleanup() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let released = DriverTestGate()
    defer { h.releaseAllGates() }
    var driver: SearchParentWireDriver? = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .sessionReleased = $0 { released.open() } })
    let weakDriver = DriverTestWeak(driver)
    let (handle, identity) = try await start(h, driver: try XCTUnwrap(driver))
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver?.wait(for: handle)
    await h.connection.waitForReadCalls(3)
    driver = nil
    XCTAssertNil(weakDriver.value)
    await h.connection.closeEntered.wait(for: 1)
    await released.wait()
    XCTAssertEqual(h.system.signalCount.value, 1)
  }

  func testSuccessfulAdmissionExpiresOnlyThePreviousCompactFailure() async throws {
    let h = try DriverHarness()
    _ = await h.lifecycle.shutdown()
    let settled = DriverTestGate()
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { settled.open() } })
    let first = try await driver.submit(job())
    await settled.wait()
    let second = try await driver.submit(job())
    do {
      _ = try await driver.wait(for: first)
      XCTFail("New admission expires old compact failure")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    let result = try await driver.wait(for: second)
    XCTAssertEqual(result, .failed(identity: nil, failure: .shutDown))
    _ = await driver.shutdown()
  }

  func testForeignHandleIsRefusedWithoutLifecycleSideEffects() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let other = try DriverHarness()
    defer {
      h.releaseAllGates()
      other.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let foreign = try SearchParentWireDriver(
      lifecycle: other.lifecycle,
      accumulatorFactory: other.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    do {
      _ = try await foreign.wait(for: handle)
      XCTFail("Foreign handle")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    do {
      try await foreign.cancel(handle)
      XCTFail("Foreign cancellation")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    do {
      try await foreign.discard(handle)
      XCTFail("Foreign discard")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    XCTAssertEqual(other.system.launchCount.value, 0)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    h.prepareCleanup()
    _ = await driver.shutdown()
    _ = await foreign.shutdown()
  }

  func testIdleUnsolicitedByteRetiresWithoutRewritingAcceptedResult() async throws {
    let h = try DriverHarness()
    let settled = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { settled.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await settled.wait()
    await h.connection.waitForReadCalls(3)
    h.connection.offer(Data([0]))
    await h.system.signalCount.wait(for: 1)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testOldTerminalHeldBehindNextExpectFailsOnlyNewIdentity() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let executeReturn = DriverTestGate()
    let responseHeld = DriverTestGate()
    let events = DriverTestLocked<[SearchParentDriverEvent]>([])
    defer {
      executeReturn.open()
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        events.withValue { $0.append(event) }
        if case .readHeld(_, 48) = event { responseHeld.open() }
      })
    let (first, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: first)
    for _ in 0..<4 { h.connection.enqueueWrite(.init()) }
    h.connection.enqueueWrite(.init(returnRelease: executeReturn))
    let second = try await driver.submit(job())
    await h.connection.waitForWriteCalls(12)
    h.connection.offer(
      try DriverTestWire.semanticFailure(identity: identity, error: .invalidPattern))
    await responseHeld.wait()
    XCTAssertFalse(events.withValue { $0.contains(.expectFinished(second.nonce)) })
    executeReturn.open()
    let result = try await driver.wait(for: second)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: identity.generation,
          requestID: second.requestID, ordinal: 2), failure: .protocolFailure))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testUnobservedSemanticFailureExpiresOnNextHealthyAdmission() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let settled = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { settled.open() } })
    let (first, identity) = try await start(h, driver: driver)
    h.connection.offer(
      try DriverTestWire.semanticFailure(identity: identity, error: .invalidPattern))
    await settled.wait()
    let second: SearchParentWireHandle
    do { second = try await driver.submit(job()) } catch {
      XCTFail("Compact semantic failure must permit healthy handoff: \(error)")
      h.prepareCleanup()
      _ = await driver.shutdown()
      return
    }
    do {
      _ = try await driver.wait(for: first)
      XCTFail("New admission expires semantic receipt")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    await h.connection.waitForWriteCalls(12)
    let secondIdentity = try SearchWireIdentity(
      generation: identity.generation, requestID: second.requestID, ordinal: 2)
    h.connection.offer(try DriverTestWire.success(identity: secondIdentity))
    let result = try await driver.wait(for: second)
    XCTAssertEqual(
      result,
      .completed(
        identity: secondIdentity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(h.system.launchCount.value, 1)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testSettlementBeforeAdmissionIsReadOnlyAndShutdownIsTerminal() async throws {
    let h = try DriverHarness()
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000)
    let fresh = try await driver.settlement(after: nil)
    XCTAssertEqual(fresh, .settled(admissionClosed: false))
    XCTAssertEqual(h.system.launchCount.value, 0)
    XCTAssertEqual(h.system.pollCount.value, 0)
    XCTAssertEqual(h.system.signalCount.value, 0)
    XCTAssertEqual(h.timers.scheduled.value, 0)
    _ = await driver.shutdown()
    let closed = try await driver.settlement(after: nil)
    XCTAssertEqual(closed, .settled(admissionClosed: true))
    XCTAssertEqual(h.system.launchCount.value, 0)
  }

  func testSettlementRequiresReceiptConsumptionAndAllowsHealthyReuse() async throws {
    let h = try DriverHarness()
    let staged = DriverTestCount()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { staged.increment() } })
    let (first, identity) = try await start(h, driver: driver)
    let active = try await driver.settlement(after: first)
    XCTAssertEqual(active, .pending)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await staged.wait(for: 1)
    let unconsumed = try await driver.settlement(after: first)
    XCTAssertEqual(unconsumed, .pending)
    _ = try await driver.wait(for: first)
    await h.connection.waitForReadCalls(3)
    let before = (h.system.polledPIDs, h.system.signals, h.timers.scheduled.value)
    let settled = try await driver.settlement(after: first)
    XCTAssertEqual(settled, .settled(admissionClosed: false))
    XCTAssertEqual(h.system.polledPIDs, before.0)
    XCTAssertEqual(h.system.signals, before.1)
    XCTAssertEqual(h.timers.scheduled.value, before.2)
    XCTAssertFalse(h.connection.snapshot.closed)
    XCTAssertEqual(h.connection.snapshot.activeReads, 1)
    let second = try await driver.submit(job())
    await h.connection.waitForWriteCalls(12)
    for old in [Optional(first), nil] {
      do {
        _ = try await driver.settlement(after: old)
        XCTFail("An older or initial handle cannot inspect the new admission")
      } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    }
    let secondIdentity = try SearchWireIdentity(
      generation: identity.generation, requestID: second.requestID, ordinal: 2)
    h.connection.offer(try DriverTestWire.success(identity: secondIdentity))
    _ = try await driver.wait(for: second)
    let again = try await driver.settlement(after: second)
    XCTAssertEqual(again, .settled(admissionClosed: false))
    XCTAssertEqual(h.system.launchCount.value, 1)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testSettlementRejectsForeignHandleAndRetainsSemanticReceipt() async throws {
    let h = try DriverHarness()
    let other = try DriverHarness()
    let staged = DriverTestGate()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { staged.open() } })
    let foreign = try SearchParentWireDriver(
      lifecycle: other.lifecycle, accumulatorFactory: other.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    do {
      _ = try await foreign.settlement(after: handle)
      XCTFail("Foreign handle")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .staleHandle) }
    h.connection.offer(
      try DriverTestWire.semanticFailure(identity: identity, error: .invalidPattern))
    await staged.wait()
    let unconsumed = try await driver.settlement(after: handle)
    XCTAssertEqual(unconsumed, .pending)
    try await driver.discard(handle)
    let consumed = try await driver.settlement(after: handle)
    XCTAssertEqual(consumed, .settled(admissionClosed: false))
    XCTAssertEqual(other.system.launchCount.value, 0)
    h.prepareCleanup()
    _ = await driver.shutdown()
    _ = await foreign.shutdown()
  }

  func testSettlementCancellationOutcomeDoesNotCertifyReap() async throws {
    let h = try DriverHarness()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    try await driver.cancel(handle)
    let outcome = try await driver.wait(for: handle)
    XCTAssertEqual(outcome, .failed(identity: identity, failure: .cancelled))
    let before = (h.system.polledPIDs, h.system.signals, h.timers.scheduled.value)
    let pending = try await driver.settlement(after: handle)
    XCTAssertEqual(pending, .pending)
    XCTAssertEqual(h.system.polledPIDs, before.0)
    XCTAssertEqual(h.system.signals, before.1)
    XCTAssertEqual(h.timers.scheduled.value, before.2)
    h.prepareCleanup()
    _ = await driver.shutdown()
    let settled = try await driver.settlement(after: handle)
    XCTAssertEqual(settled, .settled(admissionClosed: true))
  }

  func testSettlementReapDoesNotCertifyHeldChannelClose() async throws {
    let h = try DriverHarness()
    let connection = DriverTestConnection(holdClose: true)
    h.system.reapOnSignal = true
    defer {
      h.releaseAllGates()
      connection.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7181, connection: connection)
    await connection.waitForWriteCalls(2)
    connection.offer(try DriverTestWire.childHello(generation: generation))
    await connection.waitForWriteCalls(7)
    try await driver.cancel(handle)
    _ = try await driver.wait(for: handle)
    await connection.closeEntered.wait(for: 1)
    let pending = try await driver.settlement(after: handle)
    XCTAssertEqual(pending, .pending)
    let nextTimer = h.timers.scheduled.value + 1
    let stopping = Task { await driver.shutdown() }
    await h.timers.scheduled.wait(for: nextTimer)
    let bounded = await driver.shutdown()
    XCTAssertFalse(bounded.child.stopped)
    let stillPending = try await driver.settlement(after: handle)
    XCTAssertEqual(stillPending, .pending)
    connection.closeRelease.open()
    _ = await stopping.value
    let settled = try await driver.settlement(after: handle)
    XCTAssertEqual(settled, .settled(admissionClosed: true))
    XCTAssertEqual(h.system.signals, [.init(pid: 7181, signal: SIGKILL)])
  }

  func testSettlementHeldLaunchThenNoPIDFailure() async throws {
    let h = try DriverHarness()
    defer { h.releaseAllGates() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let pending = try await driver.settlement(after: handle)
    XCTAssertEqual(pending, .pending)
    h.system.failPending()
    let result = try await driver.wait(for: handle)
    guard case .failed(_, .launchFailed) = result else { return XCTFail("Expected launch refusal") }
    let settled = try await driver.settlement(after: handle)
    XCTAssertEqual(settled, .settled(admissionClosed: false))
    XCTAssertEqual(h.system.signalCount.value, 0)
    XCTAssertEqual(h.system.pollCount.value, 0)
    _ = await driver.shutdown()
  }

  private func start(_ h: DriverHarness, driver: SearchParentWireDriver) async throws
    -> (SearchParentWireHandle, SearchWireIdentity)
  {
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7120, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await h.connection.waitForWriteCalls(7)
    return (
      handle,
      try SearchWireIdentity(generation: generation, requestID: handle.requestID, ordinal: 1)
    )
  }

  private func job() throws -> SearchParentWireJob {
    try SearchParentWireJob(
      requestID: UUID(), query: SearchQuery(pattern: "x", mode: .literal), operation: .find,
      text: "x", inputUTF16: 1, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 8, maxOutputUTF16: 8,
        maxMatches: 8, cooperativeMilliseconds: 0))
  }

}

private final class DriverTestWeak<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}
