import XCTest

@testable import PadCore

final class DocumentStatisticsTests: XCTestCase {
  func testMixedEndingsEmojiAndSelectionUnits() throws {
    let text = "👩🏽‍💻e\u{301}\r\nx\ny\r"
    let stats = try DocumentStatistics.measure(text, selection: NSRange(location: 0, length: 7))
    XCTAssertEqual(stats.characters, 7)
    XCTAssertEqual(stats.utf16Units, 15)
    XCTAssertEqual(stats.unicodeScalars, 12)
    XCTAssertEqual(stats.utf8Bytes, 24)
    XCTAssertEqual(stats.lines, 4)
    XCTAssertEqual(stats.crlfEndings, 1)
    XCTAssertEqual(stats.lfEndings, 1)
    XCTAssertEqual(stats.crEndings, 1)
    XCTAssertEqual(stats.selectedCharacters, 1)
    XCTAssertEqual(stats.selectedUTF16Units, 7)
  }
  func testEmptyFinalLinesAndInvalidSelections() throws {
    XCTAssertEqual(
      try DocumentStatistics.measure("", selection: NSRange(location: 0, length: 0)).lines, 1)
    XCTAssertEqual(
      try DocumentStatistics.measure("\r\n", selection: NSRange(location: 2, length: 0)).lines, 2)
    XCTAssertThrowsError(
      try DocumentStatistics.measure("😀", selection: NSRange(location: 1, length: 1)))
    XCTAssertThrowsError(
      try DocumentStatistics.measure("abc", selection: NSRange(location: Int.max, length: 1)))
  }
}
