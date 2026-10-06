import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchParentJoinedShutdownTests: XCTestCase {
  // Break: unconditional stub refusal rejects the valid never-admitted owner.
  func testNeverAdmittedNilJoinsAndClosesAdmission() async throws {
    let h = try DriverHarness()
    let driver = try makeDriver(h)
    let result = await driver.shutdownJoined(after: nil)
    if case .completed(let completion) = result {
      XCTAssertEqual(completion.ownership, .admitted)
      XCTAssertEqual(completion.laneStop, .acknowledged)
      XCTAssertTrue(completion.shutdown.child.stopped)
      XCTAssertTrue(completion.shutdown.parentLaneSettled)
      XCTAssertEqual(completion.shutdown.retainedParentLanes, 0)
      let repeated = await driver.shutdownJoined(after: nil)
      XCTAssertEqual(repeated, result)
      do {
        _ = try await driver.submit(job())
        XCTFail("Joined terminal intent must close actual admission")
      } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .shutDown) }
    } else {
      XCTFail("A never-admitted nil owner must complete")
    }
    _ = await driver.shutdown()
  }

  // Break: using nil as wildcard admits a caller after a real request was consumed.
  func testNilAfterConsumedAdmissionLatchesStaleOwnership() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    let driver = try makeDriver(h)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let result = await driver.shutdownJoined(after: nil)
    if case .completed(let completion) = result {
      XCTAssertEqual(completion.ownership, .refused(.staleHandle))
      XCTAssertEqual(completion.laneStop, .acknowledged)
      XCTAssertTrue(completion.shutdown.parentLaneSettled)
      let repeated = await driver.shutdownJoined(after: nil)
      XCTAssertEqual(repeated, result)
      let corrected = await driver.shutdownJoined(after: handle)
      XCTAssertEqual(corrected, .callerRefused(.differentJoinOwner))
    } else {
      XCTFail("First wrong ownership must still finish diagnostic cleanup")
    }
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  // Break: a consumed latest handle is confused with retained payload state.
  func testConsumedLatestHandleIsAdmittedAndCompletionIsStable() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    defer { h.releaseAllGates() }
    let driver = try makeDriver(h)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let result = await driver.shutdownJoined(after: handle)
    if case .completed(let completion) = result {
      XCTAssertEqual(completion.ownership, .admitted)
      XCTAssertEqual(completion.laneStop, .acknowledged)
      XCTAssertTrue(completion.shutdown.child.stopped)
      XCTAssertTrue(completion.shutdown.parentLaneSettled)
      let repeated = await driver.shutdownJoined(after: handle)
      XCTAssertEqual(repeated, result)
      let legacyAlias = await driver.shutdown()
      XCTAssertEqual(legacyAlias, completion.shutdown)
    } else {
      XCTFail("Consumed exact owner must complete joined cleanup")
    }
    h.prepareCleanup()
    _ = await driver.shutdown()
  }

  // Break: later mismatched key borrows a different owner's committed completion.
  func testWrongLaterKeyCannotBorrowNeverAdmittedCompletion() async throws {
    let h = try DriverHarness()
    let driver = try makeDriver(h)
    let first = await driver.shutdownJoined(after: nil)
    let foreign = SearchParentWireHandle(nonce: UUID(), requestID: UUID())
    let later = await driver.shutdownJoined(after: foreign)
    XCTAssertEqual(later, .callerRefused(.differentJoinOwner))
    let original = await driver.shutdownJoined(after: nil)
    XCTAssertEqual(original, first)
    _ = await driver.shutdown()
  }

  // Break: joined call can reselect mode after old-only shutdown has started.
  func testLegacyFirstPermanentlyRefusesJoinedMode() async throws {
    let h = try DriverHarness()
    let driver = try makeDriver(h)
    let old = await driver.shutdown()
    XCTAssertTrue(old.child.stopped)
    let first = await driver.shutdownJoined(after: nil)
    let second = await driver.shutdownJoined(after: nil)
    XCTAssertEqual(first, .callerRefused(.legacyModeSelected))
    XCTAssertEqual(second, first)
    XCTAssertEqual(h.system.launchCount.value, 0)
    XCTAssertEqual(h.system.signalCount.value, 0)
    XCTAssertEqual(h.timers.scheduled.value, 0)
  }

  func makeDriver(_ h: DriverHarness) throws -> SearchParentWireDriver {
    try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000)
  }
  func start(_ h: DriverHarness, driver: SearchParentWireDriver) async throws
    -> (SearchParentWireHandle, SearchWireIdentity)
  {
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7290, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await h.connection.waitForWriteCalls(7)
    return (
      handle,
      try SearchWireIdentity(
        generation: generation, requestID: handle.requestID, ordinal: 1)
    )
  }
  func job() throws -> SearchParentWireJob {
    try SearchParentWireJob(
      requestID: UUID(), query: SearchQuery(pattern: "x", mode: .literal), operation: .find,
      text: "x", inputUTF16: 1, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 8, cooperativeMilliseconds: 0))
  }
}
