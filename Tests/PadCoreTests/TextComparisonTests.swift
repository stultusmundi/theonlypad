import Foundation
import XCTest

@testable import PadCore

final class TextComparisonTests: XCTestCase {
  func testAlignedInsertionDeletionPreservesOriginals() throws {
    let left = "one\r\ntwo\nthree"
    let right = "one\r\nnew\ntwo\nthree"
    let result = try TextComparison.compare(left: left, right: right)
    XCTAssertEqual(result.leftText, left)
    XCTAssertEqual(result.rightText, right)
    XCTAssertEqual(result.rows.compactMap(\.left).joined(), left)
    XCTAssertEqual(result.rows.compactMap(\.right).joined(), right)
    XCTAssertEqual(result.differenceRows, [1])
    XCTAssertNil(result.rows[1].left)
    XCTAssertEqual(result.rows[1].right, "new\n")
    let reverse = try TextComparison.compare(left: right, right: left)
    XCTAssertEqual(reverse.rows[1].left, "new\n")
    XCTAssertNil(reverse.rows[1].right)
  }
  func testExactUnicodeEndingsAndFinalEmptyLine() throws {
    for pair in [("é", "e\u{301}"), ("a\r\n", "a\n"), ("a", "a\n")] {
      let result = try TextComparison.compare(left: pair.0, right: pair.1)
      XCTAssertFalse(result.differenceRows.isEmpty)
      XCTAssertEqual(Data(result.rows.compactMap(\.left).joined().utf8), Data(pair.0.utf8))
      XCTAssertEqual(Data(result.rows.compactMap(\.right).joined().utf8), Data(pair.1.utf8))
    }
    XCTAssertEqual(try TextComparison.compare(left: "", right: "").differenceRows, [])
    XCTAssertEqual(try TextComparison.compare(left: "😀\r\n", right: "😀\r\n").rows.count, 2)
  }
  func testChangedLinesAlignAndNavigationRowsExcludeEqualLines() throws {
    let result = try TextComparison.compare(left: "a\nb\nc", right: "x\ny\nc")
    XCTAssertEqual(result.rows.count, 3)
    XCTAssertEqual(result.differenceRows, [0, 1])
    XCTAssertEqual(result.rows[0].left, "a\n")
    XCTAssertEqual(result.rows[0].right, "x\n")
  }
  func testBudgetsAndCancellationRejectExplicitly() throws {
    XCTAssertThrowsError(
      try TextComparison.compare(left: String(repeating: "x", count: 2_000_001), right: ""))
    XCTAssertThrowsError(
      try TextComparison.compare(left: String(repeating: "\n", count: 2_000), right: ""))
    XCTAssertThrowsError(try TextComparison.compare(left: "a", right: "b", isCancelled: { true }))
    let large = (0..<1999).map { String($0) }.joined(separator: "\n")
    var calls = 0
    XCTAssertThrowsError(
      try TextComparison.compare(
        left: large, right: large,
        isCancelled: {
          calls += 1
          return calls > 10
        }))
  }
  func testFileLoadingStrictUnicodeAndUnsafeFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example")
    let original = DecodedDocument(text: "😀\r\n", encoding: .utf16LE, hasBOM: true)
    try DocumentCodec.encode(original).write(to: file)
    XCTAssertEqual(try TextComparison.readFile(file), original.text)
    try Data([0xFF]).write(to: file)
    XCTAssertThrowsError(try TextComparison.readFile(file))
    try Data(repeating: 65, count: 2_000_001).write(to: file)
    XCTAssertThrowsError(try TextComparison.readFile(file))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try TextComparison.readFile(link))
    XCTAssertThrowsError(try TextComparison.readFile(root))
  }
}
