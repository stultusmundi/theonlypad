import XCTest

@testable import PadCore

final class LaunchRequestTests: XCTestCase {
  private let directory = URL(fileURLWithPath: "/tmp/synthetic-work", isDirectory: true)

  func testRelativeFilesAndGlobalNavigationOptions() throws {
    let requests = try LaunchRequest.parse(
      arguments: ["first.txt", "--line", "2", "--column", "3", "other file.txt"],
      workingDirectory: directory)
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].url.path, "/tmp/synthetic-work/first.txt")
    XCTAssertEqual(requests[1].url.lastPathComponent, "other file.txt")
    XCTAssertTrue(requests.allSatisfy { $0.line == 2 && $0.column == 3 })
    XCTAssertEqual(try LaunchRequest.parse(arguments: [], workingDirectory: directory), [])
    XCTAssertEqual(
      try LaunchRequest.parse(arguments: ["--", "--line"], workingDirectory: directory).first?.url
        .lastPathComponent, "--line")
  }

  func testMalformedPositionsFlagsAndBudgetsFail() {
    for arguments in [
      ["--line"], ["--line", "0", "a"], ["--column", "-1", "a"],
      ["--line", "999999999999999999999999", "a"], ["--line", "+1", "a"], ["--line", "2"],
      ["--unknown", "a"], ["--line", "1", "--line", "2", "a"], Array(repeating: "a", count: 129),
    ] {
      XCTAssertThrowsError(
        try LaunchRequest.parse(arguments: arguments, workingDirectory: directory),
        "\(arguments.prefix(4))")
    }
    XCTAssertThrowsError(
      try LaunchRequest.parse(arguments: ["a\u{0}b"], workingDirectory: directory))
  }

  func testLocalProtocolRoundTripAndRejection() throws {
    let request = LaunchRequest(
      url: directory.appendingPathComponent("space + é # ?.txt"), line: 2, column: 9)
    XCTAssertEqual(try LaunchRequest.parse(url: request.protocolURL()), request)
    for value in [
      "theonlypad://run?file=file:///tmp/a", "theonlypad://open?file=https://example.test/a",
      "theonlypad://open?file=file://remote.test/a", "theonlypad://open?file=file:///tmp/a&line=0",
      "theonlypad://open?file=file:///tmp/a&line=1&line=2",
      "theonlypad://open?file=file:///tmp/a&command=run",
      "theonlypad://open?file=file:///tmp/a#fragment",
    ] {
      XCTAssertThrowsError(try LaunchRequest.parse(url: URL(string: value)!))
    }
  }

  func testGraphemeColumnsMixedEndingsAndClamping() throws {
    let text = "a👩🏽‍💻e\u{301}\r\nאב\r終\n"
    XCTAssertEqual(try TextNavigation.utf16Offset(in: text, line: 1, column: 1), 0)
    XCTAssertEqual(try TextNavigation.utf16Offset(in: text, line: 1, column: 2), 1)
    XCTAssertEqual(try TextNavigation.utf16Offset(in: text, line: 1, column: 3), 8)
    XCTAssertEqual(try TextNavigation.utf16Offset(in: text, line: 1, column: Int.max), 10)
    XCTAssertEqual(try TextNavigation.utf16Offset(in: text, line: 2, column: 2), 13)
    XCTAssertEqual(try TextNavigation.utf16Offset(in: text, line: 4, column: 1), text.utf16.count)
    XCTAssertEqual(try TextNavigation.utf16Offset(in: "", line: 1, column: 8), 0)
    XCTAssertThrowsError(try TextNavigation.utf16Offset(in: text, line: 5, column: 1))
    XCTAssertThrowsError(try TextNavigation.utf16Offset(in: text, line: 0, column: 1))
    XCTAssertThrowsError(try TextNavigation.utf16Offset(in: text, line: 1, column: 0))
  }
}
