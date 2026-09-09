import Foundation
import XCTest

@testable import PadCore

final class TextDifferenceTests: XCTestCase {
  func testMiddleInsertionDeletionAndExactNoop() throws {
    let edit = try XCTUnwrap(
      TextDifference.singleEdit(from: "prefix OLD suffix", to: "prefix NEW suffix"))
    XCTAssertEqual(edit.range, NSRange(location: 7, length: 3))
    XCTAssertEqual(edit.replacement, "NEW")
    let insertion = try XCTUnwrap(TextDifference.singleEdit(from: "ab", to: "aXXb"))
    XCTAssertEqual(insertion.range, NSRange(location: 1, length: 0))
    XCTAssertEqual(insertion.replacement, "XX")
    let deletion = try XCTUnwrap(TextDifference.singleEdit(from: "aXXb", to: "ab"))
    XCTAssertEqual(deletion.range, NSRange(location: 1, length: 2))
    XCTAssertEqual(deletion.replacement, "")
    XCTAssertNil(try TextDifference.singleEdit(from: "", to: ""))
    XCTAssertNil(try TextDifference.singleEdit(from: "e\u{301}👩🏽‍💻", to: "e\u{301}👩🏽‍💻"))
  }
  func testSurrogatePrefixSuffixAndCombiningBoundaries() throws {
    for (source, target) in [
      ("x😀tail", "x😁tail"), ("x😀tail", "x🨀tail"),
      ("e\u{301}", "é"), ("a", "a\u{301}"), ("a\u{301}", "a\u{308}"),
      ("👩🏽‍💻", "👩🏾‍💻"), ("a\r\nb", "a\nb"), ("אבa", "אב終"),
      ("", "😀"), ("😀", ""),
    ] {
      try assertRecreates(source, target)
    }
    let emoji = try XCTUnwrap(TextDifference.singleEdit(from: "x😀tail", to: "x😁tail"))
    XCTAssertEqual(emoji.range, NSRange(location: 1, length: 2))
    XCTAssertEqual(emoji.replacement, "😁")
    XCTAssertNotNil(try TextDifference.singleEdit(from: "e\u{301}", to: "é"))
  }
  func testSeededDifferentialFixturesAndMinimalScalarSpan() throws {
    var seed: UInt64 = 0x123ABCD
    func next(_ count: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Int(seed % UInt64(count))
    }
    let atoms = ["a", "b", "😀", "😁", "\u{301}", "e", "é", "\r", "\n", "👩🏽‍💻", "אב", ""]
    for _ in 0..<400 {
      let sharedPrefix = (0..<next(8)).map { _ in atoms[next(atoms.count)] }.joined()
      let sharedSuffix = (0..<next(8)).map { _ in atoms[next(atoms.count)] }.joined()
      let source =
        sharedPrefix + (0..<next(6)).map { _ in atoms[next(atoms.count)] }.joined() + sharedSuffix
      let target =
        sharedPrefix + (0..<next(6)).map { _ in atoms[next(atoms.count)] }.joined() + sharedSuffix
      try assertRecreates(source, target)
    }
  }
  func testLimitsAndCancellation() throws {
    XCTAssertThrowsError(try TextDifference.singleEdit(from: "a", to: "b", isCancelled: { true }))
    let oversized = String(repeating: "x", count: 100_000_001)
    XCTAssertThrowsError(try TextDifference.singleEdit(from: oversized, to: ""))
    XCTAssertThrowsError(try TextDifference.singleEdit(from: "", to: oversized))
  }
  private func assertRecreates(_ source: String, _ target: String) throws {
    guard let edit = try TextDifference.singleEdit(from: source, to: target) else {
      XCTAssertEqual(Data(source.utf8), Data(target.utf8))
      return
    }
    let actual = try TextEdits.apply([edit], to: source)
    XCTAssertEqual(Data(actual.utf8), Data(target.utf8))
    let old = Array(source.utf16)
    let new = Array(target.utf16)
    let start = edit.range.location
    let oldEnd = NSMaxRange(edit.range)
    let newEnd = start + edit.replacement.utf16.count
    XCTAssertTrue(start == old.count || !(0xDC00...0xDFFF).contains(old[start]))
    XCTAssertTrue(oldEnd == old.count || !(0xDC00...0xDFFF).contains(old[oldEnd]))
    // Independent scalar-array oracle: no equal whole scalar remains at either replacement edge.
    let removed = (source as NSString).substring(with: edit.range)
    if let firstOld = removed.unicodeScalars.first,
      let firstNew = edit.replacement.unicodeScalars.first
    {
      XCTAssertNotEqual(firstOld, firstNew)
    }
    if let lastOld = removed.unicodeScalars.last, let lastNew = edit.replacement.unicodeScalars.last
    {
      XCTAssertNotEqual(lastOld, lastNew)
    }
    XCTAssertEqual(Array(old[..<start]), Array(new[..<start]))
    XCTAssertEqual(Array(old[oldEnd...]), Array(new[newEnd...]))
  }
}
