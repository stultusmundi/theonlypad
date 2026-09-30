import Foundation
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerBootstrapTests: XCTestCase {
  private let canonical = "ABCDEF12-3456-7890-ABCD-EF1234567890"

  func testCanonicalUUIDAcceptsUpperLowerAndMixedCase() throws {
    for value in [canonical, canonical.lowercased(), "abcdef12-3456-7890-aBcD-EF1234567890"] {
      let bootstrap = try SearchWorkerBootstrap.parse(arguments: ["worker", "--generation", value])
      XCTAssertEqual(bootstrap.generation, UUID(uuidString: canonical))
    }
  }

  func testExecutablePathDoesNotChangeGeneration() throws {
    let bootstrap = try SearchWorkerBootstrap.parse(
      arguments: ["/synthetic/App.app/Contents/Helpers/PadSearchWorker", "--generation", canonical])
    XCTAssertEqual(bootstrap.generation, UUID(uuidString: canonical))
  }

  func testMissingDuplicateExtraAndReorderedArgumentsAreRejected() {
    let cases = [
      [], ["worker"], ["worker", "--generation"],
      ["worker", canonical], ["worker", "--generation", canonical, "extra"],
      ["worker", "--generation", canonical, "--generation", canonical],
      ["worker", canonical, "--generation"], ["worker", "--generation=" + canonical],
      ["worker", "--Generation", canonical], ["worker", "--generation ", canonical],
    ]
    for arguments in cases {
      XCTAssertThrowsError(try SearchWorkerBootstrap.parse(arguments: arguments)) {
        XCTAssertEqual($0 as? SearchWorkerBootstrapError, .invalidArguments)
      }
    }
  }

  func testMalformedNoncanonicalAndZeroUUIDAreRejected() {
    let values = [
      "", "not-a-uuid", "00000000-0000-0000-0000-000000000000",
      "ABCDEF1234567890ABCDEF1234567890", "{" + canonical + "}",
      " " + canonical, canonical + "\n", canonical + "\0", "urn:uuid:" + canonical,
      "GBCDEF12-3456-7890-ABCD-EF1234567890", "ＡBCDEF12-3456-7890-ABCD-EF1234567890",
      "ABCDEF12_3456-7890-ABCD-EF1234567890",
    ]
    for value in values {
      XCTAssertThrowsError(
        try SearchWorkerBootstrap.parse(arguments: ["worker", "--generation", value])
      ) {
        XCTAssertEqual($0 as? SearchWorkerBootstrapError, .invalidArguments)
      }
    }
  }
}
