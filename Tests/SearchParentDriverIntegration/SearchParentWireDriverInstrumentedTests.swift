import Foundation
import PadCore
import XCTest

@testable import SearchExecution

// Compiled only by the declared frozen integration runner, never ordinary SwiftPM.
final class SearchParentWireDriverInstrumentedTests: XCTestCase {
  func testTerminalPublicationWaitsForSourceScopeThenImmediateResubmit() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let events = DriverTestLocked<[SearchParentDriverEvent]>([])
    let entered = DriverTestGate()
    let release = DriverTestGate()
    let firstExit = DriverTestLocked(true)
    let observerInstalled = DriverTestGate()
    SearchParentDriverTestHooks.scopeExit = { _ in
      let first = firstExit.withValue { value in
        let old = value
        value = false
        return old
      }
      if first {
        entered.open()
        await release.wait()
      }
    }
    defer {
      release.open()
      SearchParentDriverTestHooks.scopeExit = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        events.withValue { $0.append(event) }
        if case .observerInstalled = event { observerInstalled.open() }
      })
    let first = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7101, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await h.connection.waitForWriteCalls(7)
    let identity = try SearchWireIdentity(
      generation: generation, requestID: first.requestID, ordinal: 1)
    let nextJob = try job()
    let resumed = Task {
      let result = try await driver.wait(for: first)
      XCTAssertTrue(release.isOpen, "Public result escaped the positively held source scope")
      XCTAssertTrue(events.withValue { $0.contains(.idleReadReserved(generation)) })
      XCTAssertTrue(
        events.withValue { $0.contains(.sourceOwnerReleased(first.nonce)) },
        "Source owner must release before the public waiter resumes")
      XCTAssertEqual(
        result,
        .completed(
          identity: identity, source: "x",
          output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
      return try await driver.submit(nextJob)
    }
    await observerInstalled.wait()
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await entered.wait()
    XCTAssertFalse(
      events.withValue { $0.contains(.resultDelivered(first.nonce)) },
      "Publication is forbidden inside the held source-bearing helper")
    release.open()
    let second = try await resumed.value
    await h.connection.waitForWriteCalls(12)
    let identity2 = try SearchWireIdentity(
      generation: generation, requestID: second.requestID, ordinal: 2)
    h.connection.offer(try DriverTestWire.success(identity: identity2))
    let secondResult = try await driver.wait(for: second)
    XCTAssertEqual(
      secondResult,
      .completed(
        identity: identity2, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(h.system.launchCount.value, 1)
    XCTAssertEqual(h.connection.snapshot.maximumReads, 1)
    XCTAssertEqual(h.connection.snapshot.maximumWrites, 1)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testRefusedAdmissionPreservesUnobservedCompactFailure() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let sourceEntered = DriverTestGate()
    let sourceRelease = DriverTestGate()
    let sessionEntered = DriverTestGate()
    let sessionRelease = DriverTestGate()
    let failedSettled = DriverTestGate()
    let exits = DriverTestLocked(0)
    let scopeEvents = DriverTestLocked(0)
    SearchParentDriverTestHooks.scopeExit = { _ in
      let count = exits.withValue {
        $0 += 1
        return $0
      }
      if count == 2 {
        sourceEntered.open()
        await sourceRelease.wait()
      }
    }
    SearchParentDriverTestHooks.sessionExit = { _ in
      sessionEntered.open()
      await sessionRelease.wait()
    }
    defer {
      sourceRelease.open()
      sessionRelease.open()
      h.releaseAllGates()
      SearchParentDriverTestHooks.scopeExit = nil
      SearchParentDriverTestHooks.sessionExit = nil
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: {
        if case .coordinatorScopeExited = $0 {
          let count = scopeEvents.withValue {
            $0 += 1
            return $0
          }
          if count == 2 { failedSettled.open() }
        }
      })
    let (first, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: first)
    await h.connection.waitForReadCalls(3)
    h.clock.advance(by: UInt64.max)
    let failed = try await driver.submit(job())
    await sourceEntered.wait()
    h.connection.offer(Data())
    await sessionEntered.wait()
    sourceRelease.open()
    await failedSettled.wait()
    do {
      _ = try await driver.submit(job())
      XCTFail("Retiring session must refuse admission")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .busy) }
    do {
      let result = try await driver.wait(for: failed)
      XCTAssertEqual(result, .failed(identity: nil, failure: .invalidPolicy))
    } catch { XCTFail("Refused attempt erased the unobserved failure: \(error)") }
    sessionRelease.open()
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testNoTicketRefusalCannotClearHeldIdleConsumeCredit() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let hold = DriverTestBlockingGate()
    let consumed = DriverTestLocked(0)
    let released = DriverTestGate()
    SearchParentDriverTestHooks.beforeConsume = {
      let count = consumed.withValue {
        $0 += 1
        return $0
      }
      if count == 3 { hold.waitOnCodecThread() }
    }
    defer {
      hold.open()
      SearchParentDriverTestHooks.beforeConsume = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .sessionReleased = $0 { released.open() } })
    let (first, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: first)
    await h.connection.waitForReadCalls(3)
    h.connection.offer(Data([0]))
    await hold.entered.wait()
    let before = await driver.testLaneOwnership()
    XCTAssertTrue(before.reserved)
    XCTAssertTrue(before.executing)
    h.clock.advance(by: UInt64.max)
    let refused = try await driver.submit(job())
    let result = try await driver.wait(for: refused)
    XCTAssertEqual(result, .failed(identity: nil, failure: .invalidPolicy))
    let held = await driver.testLaneOwnership()
    XCTAssertTrue(held.reserved, "A no-ticket refusal cannot release another owner's lane credit")
    XCTAssertTrue(held.executing, "The actual retained thread is positively held")
    hold.open()
    await released.wait()
    let ended = await driver.testLaneOwnership()
    XCTAssertFalse(ended.reserved)
    XCTAssertFalse(ended.executing)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testCancellationBeforeBeginUsesSharedReceiptAndSuppressesHello() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let entered = DriverTestGate()
    let release = DriverTestGate()
    let cancellationStarted = DriverTestGate()
    let commands = DriverTestLocked(0)
    SearchParentDriverTestHooks.beforeBegin = {
      entered.open()
      await release.wait()
    }
    defer {
      release.open()
      SearchParentDriverTestHooks.beforeBegin = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: {
        if case .cancellationStarted = $0 {
          commands.withValue { $0 += 1 }
          cancellationStarted.open()
        }
      })
    let handle = try await driver.submit(job())
    await entered.wait()
    let first = Task { try await driver.cancel(handle) }
    await cancellationStarted.wait()
    first.cancel()  // Cancelling a command caller cannot turn strict cancellation into detachment.
    let second = Task { try await driver.cancel(handle) }
    XCTAssertEqual(h.system.launchCount.value, 0)
    release.open()
    try await first.value
    try await second.value
    XCTAssertEqual(commands.withValue { $0 }, 1)
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .cancelled))
    XCTAssertEqual(h.connection.writeEntered.value, 0)
    h.system.deliver(generation: generation, pid: 7201, connection: h.connection)
    await h.connection.closeEntered.wait(for: 1)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testCancellationBeforeRefusedBeginSettlesWithoutTicket() async throws {
    let h = try DriverHarness()
    _ = await h.lifecycle.shutdown()
    let entered = DriverTestGate()
    let release = DriverTestGate()
    let cancellationStarted = DriverTestGate()
    SearchParentDriverTestHooks.beforeBegin = {
      entered.open()
      await release.wait()
    }
    defer {
      release.open()
      SearchParentDriverTestHooks.beforeBegin = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .cancellationStarted = $0 { cancellationStarted.open() } })
    let handle = try await driver.submit(job())
    await entered.wait()
    let command = Task { try await driver.cancel(handle) }
    await cancellationStarted.wait()
    release.open()
    try await command.value
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .failed(identity: nil, failure: .shutDown))
    XCTAssertEqual(h.system.launchCount.value, 0)
    _ = await driver.shutdown()
  }

  func testObserverCancellationBeforeInstallDoesNotConsumeReceipt() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let entered = DriverTestGate()
    let release = DriverTestGate()
    SearchParentDriverTestHooks.beforeObserverInstall = {
      entered.open()
      await release.wait()
    }
    defer {
      release.open()
      SearchParentDriverTestHooks.beforeObserverInstall = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    let observer = Task { try await driver.wait(for: handle) }
    await entered.wait()
    observer.cancel()
    release.open()
    do {
      _ = try await observer.value
      XCTFail("Pre-cancelled observer must detach")
    } catch { XCTAssertTrue(error is CancellationError) }
    SearchParentDriverTestHooks.beforeObserverInstall = nil
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

  func testCancellationAtDeliveryClaimPreservesOneShotReceipt() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let installed = DriverTestGate()
    defer {
      SearchParentDriverTestHooks.beforeClaim = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { if case .observerInstalled = $0 { installed.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    let observer = Task { try await driver.wait(for: handle) }
    await installed.wait()
    SearchParentDriverTestHooks.beforeClaim = { observer.cancel() }
    h.connection.offer(try DriverTestWire.success(identity: identity))
    do {
      _ = try await observer.value
      XCTFail("Cancellation won before atomic delivery claim")
    } catch { XCTAssertTrue(error is CancellationError) }
    SearchParentDriverTestHooks.beforeClaim = nil
    do {
      let result = try await driver.wait(for: handle)
      XCTAssertEqual(
        result,
        .completed(
          identity: identity, source: "x",
          output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    } catch { XCTFail("Detached observer must leave the receipt available: \(error)") }
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testNewGenerationWaitsForOldReadOwnerReceipt() async throws {
    let h = try DriverHarness(maximumRequests: 1)
    h.system.reapOnSignal = true
    let oldOwnerEntered = DriverTestGate()
    let oldOwnerRelease = DriverTestGate()
    let newConnectionAvailable = DriverTestGate()
    let connections = DriverTestLocked(0)
    SearchParentDriverTestHooks.sessionExit = { epoch in
      if epoch == 1 {
        oldOwnerEntered.open()
        await oldOwnerRelease.wait()
      }
    }
    defer {
      oldOwnerRelease.open()
      SearchParentDriverTestHooks.sessionExit = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: {
        if case .connectionAvailable = $0 {
          let count = connections.withValue {
            $0 += 1
            return $0
          }
          if count == 2 { newConnectionAvailable.open() }
        }
      })
    let (first, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: first)
    await h.connection.waitForReadCalls(3)
    let second = try await driver.submit(job())
    await oldOwnerEntered.wait()
    await h.system.launchCount.wait(for: 2)
    let generation = h.system.generations[1]
    XCTAssertNotEqual(generation, identity.generation)
    let connection = DriverTestConnection()
    h.system.deliver(generation: generation, pid: 7202, connection: connection)
    await newConnectionAvailable.wait()
    XCTAssertEqual(connection.writeEntered.value, 0)
    XCTAssertEqual(connection.readEntered.value, 0)
    let held = await driver.testLaneOwnership()
    XCTAssertTrue(held.reserved)
    oldOwnerRelease.open()
    await connection.waitForWriteCalls(2)
    connection.offer(try DriverTestWire.childHello(generation: generation))
    await connection.waitForWriteCalls(7)
    let secondIdentity = try SearchWireIdentity(
      generation: generation, requestID: second.requestID, ordinal: 1)
    connection.offer(try DriverTestWire.success(identity: secondIdentity))
    let result = try await driver.wait(for: second)
    XCTAssertEqual(
      result,
      .completed(
        identity: secondIdentity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(h.system.launchCount.value, 2)
    XCTAssertEqual(connection.snapshot.maximumReads, 1)
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testEOFDuringUploadCannotRaceIntoProtocolFailure() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let writeRelease = DriverTestGate()
    let observationEntered = DriverTestGate()
    let observationRelease = DriverTestGate()
    let uploaderAdvanced = DriverTestGate()
    let decisions = DriverTestLocked<[SearchChildOutcome]>([])
    h.connection.enqueueWrite(.init())
    h.connection.enqueueWrite(.init())
    h.connection.enqueueWrite(.init(returnRelease: writeRelease))
    SearchParentDriverTestHooks.beforeRequestUpload = {
      await h.connection.waitForReadCalls(2)
    }
    SearchParentDriverTestHooks.beforeChannelObservation = {
      observationEntered.open()
      await observationRelease.wait()
    }
    defer {
      writeRelease.open()
      observationRelease.open()
      h.releaseAllGates()
      SearchParentDriverTestHooks.beforeRequestUpload = nil
      SearchParentDriverTestHooks.beforeChannelObservation = nil
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        if case .lifecycleDecided(_, let result) = event {
          decisions.withValue { $0.append(result) }
          uploaderAdvanced.open()
        }
        if case .expectFinished = event { uploaderAdvanced.open() }
      })
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7203, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await h.connection.waitForWriteCalls(3)
    h.connection.offer(Data())
    await observationEntered.wait()
    writeRelease.open()
    await uploaderAdvanced.wait()
    XCTAssertFalse(
      decisions.withValue { $0.contains(.failed(.protocolFailure)) },
      "Bridge wakeup must not outrun truthful EOF observation")
    observationRelease.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: .unexpectedExit))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testCancelIntentCannotRaceIntoProtocolFailure() async throws {
    try await commandOriginRace(shutdown: false)
  }

  func testShutdownIntentCannotRaceIntoProtocolFailure() async throws {
    try await commandOriginRace(shutdown: true)
  }

  private func commandOriginRace(shutdown: Bool) async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let writeRelease = DriverTestGate()
    let commandEntered = DriverTestGate()
    let commandRelease = DriverTestGate()
    let uploaderAdvanced = DriverTestGate()
    h.connection.enqueueWrite(.init(returnRelease: writeRelease))
    if shutdown {
      SearchParentDriverTestHooks.beforeShutdownCommand = {
        commandEntered.open()
        await commandRelease.wait()
      }
    } else {
      SearchParentDriverTestHooks.beforeCancelCommand = {
        commandEntered.open()
        await commandRelease.wait()
      }
    }
    SearchParentDriverTestHooks.beforeAuthorityWait = { uploaderAdvanced.open() }
    defer {
      writeRelease.open()
      commandRelease.open()
      h.releaseAllGates()
      SearchParentDriverTestHooks.beforeCancelCommand = nil
      SearchParentDriverTestHooks.beforeShutdownCommand = nil
      SearchParentDriverTestHooks.beforeAuthorityWait = nil
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7204, connection: h.connection)
    await h.connection.waitForWriteCalls(1)
    let command = Task {
      if shutdown { _ = await driver.shutdown() } else { try await driver.cancel(handle) }
    }
    await commandEntered.wait()
    writeRelease.open()
    await uploaderAdvanced.wait()
    commandRelease.open()
    try await command.value
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .failed(
        identity: try SearchWireIdentity(
          generation: generation,
          requestID: handle.requestID, ordinal: 1), failure: shutdown ? .shutDown : .cancelled))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testReadPayloadIsIneligibleUntilReadHelperReturns() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let entered = DriverTestGate()
    let release = DriverTestGate()
    let callbacks = DriverTestLocked<[String]>([])
    SearchParentDriverTestHooks.readScope = { sequence in
      if sequence == 2 {
        entered.open()
        await release.wait()
      }
    }
    defer {
      release.open()
      SearchParentDriverTestHooks.readScope = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: { _ in
        DriverTestAccumulator(onCallback: { name in callbacks.withValue { $0.append(name) } })
      },
      maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await entered.wait()
    XCTAssertFalse(callbacks.withValue { $0.contains("begin") })
    XCTAssertEqual(h.connection.readEntered.value, 2)
    release.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testReadFailureWaitsForItsHelperBeforeAuthorityObservation() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let entered = DriverTestGate()
    let release = DriverTestGate()
    SearchParentDriverTestHooks.readScope = { sequence in
      if sequence == 2 {
        entered.open()
        await release.wait()
      }
    }
    defer {
      release.open()
      SearchParentDriverTestHooks.readScope = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offerFailure(.channelFailure(5))
    await entered.wait()
    XCTAssertEqual(h.system.signalCount.value, 0)
    XCTAssertEqual(h.connection.readEntered.value, 2)
    release.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(result, .failed(identity: identity, failure: .channelFailure(5)))
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testFalseIdleRetirementKeepsOldGenerationUnavailable() async throws {
    let h = try DriverHarness()
    let ownerEntered = DriverTestGate()
    let ownerRelease = DriverTestGate()
    let retirement = DriverTestLocked<Bool?>(nil)
    SearchParentDriverTestHooks.sessionExit = { _ in
      ownerEntered.open()
      await ownerRelease.wait()
    }
    defer {
      ownerRelease.open()
      SearchParentDriverTestHooks.sessionExit = nil
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1,
      observe: { event in
        if case .terminalAccepted = event {
          h.timers.fireDue(at: h.clock.advance(by: 2_000_000_000))
        }
        if case .idleRetirementRequested(_, let accepted) = event {
          retirement.withValue { $0 = accepted }
        }
      })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await ownerEntered.wait()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(retirement.withValue { $0 }, false)
    do {
      _ = try await driver.submit(job())
      XCTFail("Refused retirement cannot restore old admission")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .busy) }
    ownerRelease.open()
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  func testTerminalSequenceExhaustionKeepsAcceptedResult() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let exhausted = DriverTestGate()
    let released = DriverTestLocked(false)
    SearchParentDriverTestHooks.exhaustReadOnTerminal = true
    defer {
      SearchParentDriverTestHooks.exhaustReadOnTerminal = false
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        if case .readSequenceExhausted = event { exhausted.open() }
        if case .sessionReleased = event { released.withValue { $0 = true } }
      })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await exhausted.wait()
    let ownership = await driver.testLaneOwnership()
    XCTAssertTrue(
      ownership.reserved || released.withValue { $0 },
      "Exhausted read sequence must reserve cleanup or already release its owner")
    // Terminal coordination already supplies another pulse; this is a preservation control.
    h.prepareCleanup()
    _ = await driver.shutdown()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
  }

  func testPartialResponseSequenceExhaustionReservesCleanup() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let exhausted = DriverTestGate()
    let expected = DriverTestGate()
    let released = DriverTestLocked(false)
    SearchParentDriverTestHooks.exhaustReadOnNeedMore = true
    defer {
      SearchParentDriverTestHooks.exhaustReadOnNeedMore = false
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        if case .expectFinished = event { expected.open() }
        if case .readSequenceExhausted = event { exhausted.open() }
        if case .sessionReleased = event { released.withValue { $0 = true } }
      })
    let (handle, identity) = try await start(h, driver: driver)
    await expected.wait()
    h.connection.offer(try DriverTestWire.success(identity: identity).prefix(1))
    await exhausted.wait()
    let ownership = await driver.testLaneOwnership()
    let cleanupOwned = ownership.reserved || released.withValue { $0 }
    XCTAssertTrue(
      cleanupOwned,
      "Partial response exhaustion must reserve cleanup without waiting for another external event")
    if cleanupOwned {
      let result = try await driver.wait(for: handle)
      XCTAssertEqual(
        result, .failed(identity: identity, failure: .protocolFailure),
        "Checked exhaustion must reach lifecycle authority before test shutdown")
    }
    h.prepareCleanup()
    _ = await driver.shutdown()
    if !cleanupOwned { _ = try await driver.wait(for: handle) }
  }

  func testExpectGatePreventsPrematureConsumeAfterUploadReceipt() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let executeRelease = DriverTestGate()
    let responseHeld = DriverTestGate()
    let expectEntered = DriverTestGate()
    let expectRelease = DriverTestGate()
    let decisionObserved = DriverTestGate()
    let prematureConsume = DriverTestGate()
    let firstDecision = DriverTestLocked<Bool?>(nil)
    let expected = DriverTestLocked(false)
    let consumeCount = DriverTestLocked(0)
    let decisionArmed = DriverTestLocked(false)
    for _ in 0..<6 { h.connection.enqueueWrite(.init()) }
    h.connection.enqueueWrite(.init(returnRelease: executeRelease))
    SearchParentDriverTestHooks.beforeRequestUpload = {
      await h.connection.waitForReadCalls(2)
      decisionArmed.withValue { $0 = true }
    }
    SearchParentDriverTestHooks.beforeExpect = {
      expectEntered.open()
      await expectRelease.wait()
    }
    SearchParentDriverTestHooks.heldReadDecision = { enabled in
      guard decisionArmed.withValue({ $0 }) else { return }
      let first = firstDecision.withValue { value in
        if value != nil { return false }
        value = enabled
        return true
      }
      if first { decisionObserved.open() }
    }
    SearchParentDriverTestHooks.beforeConsume = {
      let count = consumeCount.withValue {
        $0 += 1
        return $0
      }
      if count == 2 && !expected.withValue({ $0 }) {
        XCTFail("Actual codec consume began before exact expect receipt")
        prematureConsume.open()
      }
    }
    defer {
      executeRelease.open()
      expectRelease.open()
      h.releaseAllGates()
      SearchParentDriverTestHooks.beforeRequestUpload = nil
      SearchParentDriverTestHooks.beforeExpect = nil
      SearchParentDriverTestHooks.heldReadDecision = nil
      SearchParentDriverTestHooks.beforeConsume = nil
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: h.accumulatorFactory, maximumWireBytesPerChild: 1_000_000,
      observe: { event in
        if case .readHeld(_, let count) = event, count > 56 { responseHeld.open() }
        if case .expectFinished = event { expected.withValue { $0 = true } }
      })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await responseHeld.wait()
    executeRelease.open()
    await expectEntered.wait()
    await decisionObserved.wait()
    let enabled = try XCTUnwrap(firstDecision.withValue { $0 })
    XCTAssertFalse(enabled, "Held response must remain ineligible before expect")
    if enabled { await prematureConsume.wait() }
    expectRelease.open()
    let result = try await driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    h.prepareCleanup()
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
