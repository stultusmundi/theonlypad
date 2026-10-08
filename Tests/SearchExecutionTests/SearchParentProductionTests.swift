import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchParentProductionTests: XCTestCase {
  func testSelectedPolicyAndCompletedByteThresholdHaveExactIndependentValues() throws {
    let policy = try SearchParentProductionPolicy.childPolicy()
    XCTAssertEqual(policy.operationNanoseconds, 10_000_000_000)
    XCTAssertEqual(policy.reapGraceNanoseconds, 2_000_000_000)
    XCTAssertEqual(policy.idleNanoseconds, 10_000_000_000)
    XCTAssertEqual(policy.maximumRequestsPerChild, 8)
    // Value selection only. Existing reduced-threshold driver/counter tests prove
    // completed-I/O retirement; this is neither a payload allocation nor an RSS test.
    XCTAssertEqual(SearchParentProductionPolicy.maximumWireBytesPerChild, 268_435_456)
  }

  func testMalformedBundleFormsRefuseBeforeLaunchOrTimer() async throws {
    for text in [
      "https://example.invalid/Pad.app", "file:relative.app",
      "file://remote.invalid/Pad.app", "file:///synthetic/Pad.app?helper=x",
      "file:///synthetic/Pad.app#fragment", "file:///synthetic/Pad%00.app",
    ] {
      let url = try XCTUnwrap(URL(string: text))
      let clock = DriverTestClock()
      let timers = DriverTestTimers()
      let system = ProductionLaunchRecorder(timers: timers)
      do {
        let driver = try SearchParentWireDriver(
          applicationBundle: url, system: system, now: { clock.now },
          schedule: { timers.schedule($0, event: $1) })
        // Even an incorrectly accepted constructor must close its real lane.
        assertJoined(await driver.shutdownJoined(after: nil))
        XCTFail("Malformed bundle was accepted: \(text)")
      } catch {
        XCTAssertEqual(error as? SearchWorkerBundleResolverError, .invalidURL)
      }
      XCTAssertEqual(system.backing.launchCount.value, 0)
      XCTAssertEqual(system.backing.signalCount.value, 0)
      XCTAssertEqual(system.backing.pollCount.value, 0)
      XCTAssertEqual(timers.scheduled.value, 0)
    }
  }

  func testAbsentBundleConstructionHasNoLaunchPollSignalOrTimer() async throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
      "missing-production-\(UUID().uuidString).app", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    let h = try fixture(bundle: bundle)
    XCTAssertEqual(h.system.backing.launchCount.value, 0)
    XCTAssertEqual(h.system.backing.pollCount.value, 0)
    XCTAssertEqual(h.system.backing.signalCount.value, 0)
    XCTAssertEqual(h.timers.scheduled.value, 0)
    let fresh = try await h.driver.settlement(after: nil)
    XCTAssertEqual(fresh, .settled(admissionClosed: false))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    let joined = await h.driver.shutdownJoined(after: nil)
    assertJoined(joined)
    let closed = try await h.driver.settlement(after: nil)
    XCTAssertEqual(closed, .settled(admissionClosed: true))
  }

  func testNormalizedFixedHelperIsSubmittedOnlyAfterAbsoluteDeadlineIsArmed() async throws {
    let bundle = try XCTUnwrap(URL(string: "file:///synthetic/one/../A%F0%9F%98%80%20b.app/./"))
    let h = try fixture(bundle: bundle)
    h.clock.advance(by: 23)
    let handle = try await h.submit(job())
    await h.system.backing.launchCount.wait(for: 1)
    let launch = try XCTUnwrap(h.system.launches.first)
    XCTAssertEqual(launch.executable.path, "/synthetic/A😀 b.app/Contents/Helpers/PadSearchWorker")
    XCTAssertEqual(launch.activeDeadlines, [10_000_000_023])
    XCTAssertEqual(h.system.backing.generations, [launch.generation])
    // Missing executable handling belongs to launch, not constructor admission.
    h.system.backing.failPending()
    let outcome = try await h.driver.wait(for: handle)
    XCTAssertEqual(
      outcome,
      .failed(
        identity: try SearchWireIdentity(
          generation: launch.generation, requestID: handle.requestID, ordinal: 1),
        failure: .launchFailed(ENOENT)))
    XCTAssertEqual(h.system.backing.signalCount.value, 0)
    XCTAssertEqual(h.system.backing.pollCount.value, 0)
  }

  func testProductionCollectorReturnsLiteralUnicodeThroughRealCodec() async throws {
    let h = try fixture()
    let source = "x😀e\u{301}猫"
    let request = try job(text: source, inputUTF16: 6, operation: .replace(template: "Q"))
    let (handle, identity, connection) = try await h.start(request)
    let replacement = "\u{FEFF}A😀e\u{301}\0\r\n\r\n\u{FEFF}"
    connection.offer(
      try DriverTestWire.success(
        identity: identity,
        matches: [NSRange(location: 1, length: 2), NSRange(location: 5, length: 1)],
        replacement: replacement))
    let outcome = try await h.driver.wait(for: handle)
    guard case .completed(let actualIdentity, let actualSource, let output) = outcome else {
      return XCTFail("Expected real codec success, got \(outcome)")
    }
    XCTAssertEqual(actualIdentity, identity)
    XCTAssertEqual(actualIdentity.requestID, request.requestID)
    XCTAssertEqual(actualIdentity.ordinal, 1)
    XCTAssertEqual(Array(actualSource.utf16), [0x78, 0xD83D, 0xDE00, 0x65, 0x301, 0x732B])
    XCTAssertEqual(
      output.matches, [NSRange(location: 1, length: 2), NSRange(location: 5, length: 1)])
    let text = try XCTUnwrap(output.replacement)
    XCTAssertEqual(
      Array(text.utf16),
      [0xFEFF, 0x41, 0xD83D, 0xDE00, 0x65, 0x301, 0, 0x0D, 0x0A, 0x0D, 0x0A, 0xFEFF])
    XCTAssertEqual(
      Array(text.utf8),
      [
        0xEF, 0xBB, 0xBF, 0x41, 0xF0, 0x9F, 0x98, 0x80, 0x65, 0xCC, 0x81, 0,
        0x0D, 0x0A, 0x0D, 0x0A, 0xEF, 0xBB, 0xBF,
      ])
    XCTAssertEqual(h.system.backing.signalCount.value, 0)
    XCTAssertEqual(h.system.backing.launchCount.value, 1)
  }

  func testSuccessTerminalWithoutResponseBeginRemainsProtocolFailure() async throws {
    let h = try fixture()
    let (handle, identity, connection) = try await h.start(job())
    var terminal = Data()
    // A valid frame in the wrong phase: the real writer permits framing it,
    // while the real parent response reader must refuse success without begin.
    try SearchWireWriter.terminal(identity, result: .success) { terminal.append($0) }
    connection.offer(terminal)
    let outcome = try await h.driver.wait(for: handle)
    XCTAssertEqual(outcome, .failed(identity: identity, failure: .protocolFailure))
  }

  func testTerminalOneNanosecondBeforeTenSecondsRemainsSuccessful() async throws {
    let h = try fixture()
    let (handle, identity, connection) = try await h.start(job())
    h.clock.advance(by: 9_999_999_999)
    h.timers.fireDue(at: h.clock.now)
    connection.offer(try DriverTestWire.success(identity: identity))
    let result = try await h.driver.wait(for: handle)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(h.system.backing.signalCount.value, 0)
  }

  func testTenSecondDeadlineWinsBeforeAnyTerminalResponse() async throws {
    let h = try fixture()
    let (handle, identity, _) = try await h.start(job())
    XCTAssertEqual(h.system.launches.first?.activeDeadlines, [10_000_000_000])
    h.clock.advance(by: 10_000_000_000)
    h.timers.fireDue(at: h.clock.now)
    let result = try await h.driver.wait(for: handle)
    XCTAssertEqual(result, .failed(identity: identity, failure: .deadline))
    await h.system.backing.signalCount.wait(for: 1)
    XCTAssertEqual(h.system.backing.signals, [.init(pid: 7301, signal: SIGKILL)])
  }

  func testSelectedTwoSecondGraceDistinguishesStoppingFromUnconfirmed() async throws {
    // Use the real policy and lifecycle cleanup query as a serial-lane barrier.
    // This test deliberately withholds reap; no driver/PID accessor is introduced.
    let clock = DriverTestClock()
    let timers = DriverTestTimers()
    let system = DriverTestSystem()
    let connection = DriverTestConnection()
    let lifecycle = try SearchChildLifecycle(
      executable: URL(fileURLWithPath: "/synthetic/Pad.app/Contents/Helpers/PadSearchWorker"),
      policy: SearchParentProductionPolicy.childPolicy(), system: system,
      now: { clock.now }, schedule: { timers.schedule($0, event: $1) })
    addTeardownBlock {
      connection.releaseAllGates()
      system.prepareReap()
      system.failPending()
      clock.advance(by: 100_000_000)
      timers.fireDue(at: clock.now)
      let shutdown = await lifecycle.shutdown()
      XCTAssertTrue(shutdown.stopped)
      XCTAssertTrue(shutdown.channelsClosed)
    }
    let ticket = try await lifecycle.begin(requestID: UUID())
    system.deliver(generation: ticket.identity.generation, pid: 7340, connection: connection)
    _ = try await lifecycle.connection(for: ticket)
    try await lifecycle.acceptedHandshake(generation: ticket.identity.generation)
    try await lifecycle.cancel(ticket)
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.cancelled))
    await connection.closeEntered.wait(for: 1)
    clock.advance(by: 1_999_999_999)
    timers.fireDue(at: clock.now)
    let before = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(before, .stopping(generation: ticket.identity.generation))
    clock.advance(by: 1)
    timers.fireDue(at: clock.now)
    let boundary = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(boundary, .stopUnconfirmed(generation: ticket.identity.generation))
    XCTAssertEqual(system.signals, [.init(pid: 7340, signal: SIGKILL)])
    // Reap and connection closure remain independent facts, not inferred from expiry.
    system.prepareReap()
    clock.advance(by: 100_000_000)
    timers.fireDue(at: clock.now)
    let reaped = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(
      reaped, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
  }

  func testHealthyChildRemainsUntilTenSecondIdleBoundary() async throws {
    let h = try fixture()
    let (handle, identity, connection) = try await h.start(job())
    connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await h.driver.wait(for: handle)
    await connection.waitForReadCalls(3)
    h.clock.advance(by: 9_999_999_999)
    h.timers.fireDue(at: h.clock.now)
    // settlement queries actual lifecycle state after the enqueued timer callback.
    let before = try await h.driver.settlement(after: handle)
    XCTAssertEqual(before, .settled(admissionClosed: false))
    XCTAssertEqual(h.system.backing.signalCount.value, 0)
    XCTAssertTrue(h.timers.activeDeadlines.contains(10_000_000_000))
    h.clock.advance(by: 1)
    h.timers.fireDue(at: h.clock.now)
    await h.system.backing.signalCount.wait(for: 1)
    XCTAssertEqual(h.system.backing.signals, [.init(pid: 7301, signal: SIGKILL)])
    XCTAssertEqual(h.system.backing.launchCount.value, 1)
    await connection.closeEntered.wait(for: 1)
    XCTAssertTrue(connection.snapshot.closed)
  }

  func testEightCompletedRequestsReuseThenNinthGetsNewGenerationAndOrdinalOne() async throws {
    let h = try fixture()
    let (first, firstIdentity, connection) = try await h.start(job())
    for ordinal in 1...8 {
      let handle: SearchParentWireHandle
      if ordinal == 1 {
        handle = first
      } else {
        handle = try await h.submit(job())
        await connection.waitForWriteCalls(2 + 5 * ordinal)
      }
      let identity = try SearchWireIdentity(
        generation: firstIdentity.generation, requestID: handle.requestID, ordinal: UInt64(ordinal))
      connection.offer(try DriverTestWire.success(identity: identity))
      let result = try await h.driver.wait(for: handle)
      XCTAssertEqual(
        result,
        .completed(
          identity: identity, source: "x",
          output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
      XCTAssertEqual(h.system.backing.launchCount.value, 1, "Completed request \(ordinal)")
      XCTAssertEqual(h.system.backing.signalCount.value, 0, "Completed request \(ordinal)")
    }
    let ninth = try await h.submit(job())
    await h.system.backing.launchCount.wait(for: 2)
    let generation = try XCTUnwrap(h.system.backing.generations.last)
    XCTAssertNotEqual(generation, firstIdentity.generation)
    XCTAssertEqual(h.system.backing.signals, [.init(pid: 7301, signal: SIGKILL)])
    XCTAssertTrue(connection.snapshot.closed)
    let replacement = DriverTestConnection()
    h.system.backing.deliver(generation: generation, pid: 7302, connection: replacement)
    await replacement.waitForWriteCalls(2)
    replacement.offer(try DriverTestWire.childHello(generation: generation))
    await replacement.waitForWriteCalls(7)
    let identity = try SearchWireIdentity(
      generation: generation, requestID: ninth.requestID, ordinal: 1)
    replacement.offer(try DriverTestWire.success(identity: identity))
    let result = try await h.driver.wait(for: ninth)
    XCTAssertEqual(
      result,
      .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil)))
    XCTAssertEqual(h.system.backing.launchCount.value, 2)
  }

  private func fixture(
    bundle: URL = URL(fileURLWithPath: "/synthetic/AbsentParent.app", isDirectory: true)
  ) throws -> ProductionDriverFixture {
    let h = try ProductionDriverFixture(bundle: bundle)
    addTeardownBlock {
      h.system.backing.prepareReap()
      h.system.backing.failPending()
      for connection in h.system.backing.connections { connection.releaseAllGates() }
      h.clock.advance(by: 100_000_000)
      h.timers.fireDue(at: h.clock.now)
      let result = await h.driver.shutdownJoined(after: h.latest)
      // The real retained join runs even if the test body threw before consuming a result.
      guard case .completed(let receipt) = result else {
        return XCTFail("Expected genuine joined cleanup, got \(result)")
      }
      XCTAssertEqual(receipt.ownership, .admitted)
      XCTAssertEqual(receipt.laneStop, .acknowledged)
      XCTAssertTrue(receipt.shutdown.child.stopped)
      XCTAssertTrue(receipt.shutdown.child.channelsClosed)
      XCTAssertTrue(receipt.shutdown.parentLaneSettled)
      XCTAssertEqual(receipt.shutdown.retainedParentLanes, 0)
    }
    return h
  }

  private func assertJoined(_ result: SearchParentJoinedShutdownResult) {
    guard case .completed(let receipt) = result else {
      return XCTFail("Expected joined shutdown, got \(result)")
    }
    XCTAssertEqual(receipt.ownership, .admitted)
    XCTAssertEqual(receipt.laneStop, .acknowledged)
    XCTAssertTrue(receipt.shutdown.child.stopped)
    XCTAssertTrue(receipt.shutdown.child.channelsClosed)
    XCTAssertEqual(receipt.shutdown.child.cleanup, .noChild)
    XCTAssertTrue(receipt.shutdown.parentLaneSettled)
    XCTAssertEqual(receipt.shutdown.retainedParentLanes, 0)
  }

  private func job(
    text: String = "x", inputUTF16: Int = 1, operation: SearchExecutionOperation = .find
  ) throws -> SearchParentWireJob {
    try SearchParentWireJob(
      requestID: UUID(), query: SearchQuery(pattern: "x", mode: .literal), operation: operation,
      text: text, inputUTF16: inputUTF16, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 32, maxOutputUTF16: 32, maxMatches: 8, cooperativeMilliseconds: 1000))
  }
}

/// Adds only observations missing from the existing scripted system. No helper executes.
private final class ProductionLaunchRecorder: SearchChildSystem, @unchecked Sendable {
  struct Launch {
    let executable: URL
    let generation: UUID
    let activeDeadlines: [UInt64]
  }
  let backing = DriverTestSystem()
  private let timers: DriverTestTimers
  private let recorded = DriverTestLocked<[Launch]>([])
  var launches: [Launch] { recorded.withValue { $0 } }
  init(timers: DriverTestTimers) { self.timers = timers }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    recorded.withValue {
      precondition($0.count < 16)
      $0.append(
        .init(
          executable: executable, generation: generation,
          activeDeadlines: timers.activeDeadlines))
    }
    backing.launch(executable: executable, generation: generation, completion: completion)
  }
  func signal(pid: Int32, signal: Int32) -> Int32 { backing.signal(pid: pid, signal: signal) }
  func pollExit(pid: Int32) -> SearchChildPoll { backing.pollExit(pid: pid) }
}

private final class ProductionDriverFixture: @unchecked Sendable {
  let clock = DriverTestClock()
  let timers = DriverTestTimers()
  let system: ProductionLaunchRecorder
  let driver: SearchParentWireDriver
  var latest: SearchParentWireHandle?
  init(bundle: URL) throws {
    let clock = self.clock
    let timers = self.timers
    system = ProductionLaunchRecorder(timers: timers)
    system.backing.reapOnSignal = true
    driver = try SearchParentWireDriver(
      applicationBundle: bundle, system: system, now: { clock.now },
      schedule: { timers.schedule($0, event: $1) })
  }
  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle {
    let handle = try await driver.submit(job)
    latest = handle
    return handle
  }
  func start(_ job: SearchParentWireJob) async throws
    -> (SearchParentWireHandle, SearchWireIdentity, DriverTestConnection)
  {
    let handle = try await submit(job)
    await system.backing.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(system.backing.generations.first)
    let connection = DriverTestConnection()
    system.backing.deliver(generation: generation, pid: 7301, connection: connection)
    await connection.waitForWriteCalls(2)
    connection.offer(try DriverTestWire.childHello(generation: generation))
    let identity = try SearchWireIdentity(
      generation: generation, requestID: handle.requestID, ordinal: 1)
    // Nonempty request: begin header/body (including pattern/template),
    // text header/body, execute. Together with hello, seven writes.
    await connection.waitForWriteCalls(7)
    return (handle, identity, connection)
  }
}
