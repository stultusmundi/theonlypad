import Foundation
import SearchExecution
import XCTest

/// Compile this file with an ordinary import: no test-only extension supplies access.
final class SearchParentProductionPackageAccessTests: XCTestCase {
  func testOrdinaryBundleConstructorJoinsActualLaneWithoutStartingHelper() async throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPadMissing-\(UUID().uuidString).app", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    let driver = try SearchParentWireDriver(applicationBundle: bundle)
    // Registered immediately so a future throwing assertion/setup edit still joins.
    addTeardownBlock { _ = await driver.shutdownJoined(after: nil) }
    let result = await driver.shutdownJoined(after: nil)
    guard case .completed(let receipt) = result else {
      return XCTFail("Expected ordinary constructor's genuine joined completion")
    }
    XCTAssertEqual(receipt.ownership, .admitted)
    XCTAssertEqual(receipt.laneStop, .acknowledged)
    XCTAssertTrue(receipt.shutdown.child.stopped)
    XCTAssertTrue(receipt.shutdown.child.channelsClosed)
    XCTAssertEqual(receipt.shutdown.child.cleanup, .noChild)
    XCTAssertTrue(receipt.shutdown.parentLaneSettled)
    XCTAssertEqual(receipt.shutdown.retainedParentLanes, 0)
    let closed = try await driver.settlement(after: nil)
    XCTAssertEqual(closed, .settled(admissionClosed: true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
  }
}
