import Foundation
import XCTest

@testable import PadCore

final class LineCommandsTests: XCTestCase {
  func testEndpointAtFollowingLineStartExcludesThatLine() throws {
    let result = try LineCommand.duplicate.apply(
      to: "one\r\ntwo\nthree", selection: NSRange(location: 1, length: 4))
    XCTAssertEqual(result.text, "one\r\none\r\ntwo\nthree")
    XCTAssertEqual(result.selection, NSRange(location: 5, length: 5))
  }
  func testDuplicateAndDeleteTrailingEmptyAndEntirelyEmptyLines() throws {
    XCTAssertEqual(
      try LineCommand.duplicate.apply(to: "", selection: NSRange(location: 0, length: 0)).text, "\n"
    )
    XCTAssertEqual(
      try LineCommand.duplicate.apply(to: "a\r\n", selection: NSRange(location: 3, length: 0)).text,
      "a\r\n\r\n")
    XCTAssertEqual(
      try LineCommand.delete.apply(to: "a\r\n", selection: NSRange(location: 3, length: 0)).text,
      "a")
    XCTAssertEqual(
      try LineCommand.delete.apply(to: "", selection: NSRange(location: 0, length: 0)).text, "")
    XCTAssertEqual(
      try LineCommand.delete.apply(to: "a\nb", selection: NSRange(location: 2, length: 0)).text, "a"
    )
    XCTAssertEqual(
      try LineCommand.duplicate.apply(to: "a\rb", selection: NSRange(location: 2, length: 0)).text,
      "a\rb\rb")
  }
  func testDeleteOnlyTouchedLinesPreservesUntouchedBytes() throws {
    let text = "é\r\ne\u{301}\n👩🏽‍💻\rfinal"
    let result = try LineCommand.delete.apply(to: text, selection: NSRange(location: 3, length: 3))
    XCTAssertEqual(Data(result.text.utf8), Data("é\r\n👩🏽‍💻\rfinal".utf8))
    XCTAssertEqual(result.selection, NSRange(location: 3, length: 0))
  }
  func testJoinPreservesWhitespaceAndLastLineEnding() throws {
    let result = try LineCommand.join.apply(
      to: "a\r\n b\rc\nend", selection: NSRange(location: 0, length: 6))
    XCTAssertEqual(result.text, "a  b\rc\nend")
    XCTAssertEqual(
      try LineCommand.join.apply(to: "a\r\nb", selection: NSRange(location: 0, length: 0)).text,
      "a b")
  }
  func testMovementSlotsAndSelection() throws {
    let result = try LineCommand.moveDown.apply(
      to: "é\r\ne\u{301}\n👩🏽‍💻", selection: NSRange(location: 0, length: 0))
    XCTAssertEqual(Data(result.text.utf8), Data("e\u{301}\r\né\n👩🏽‍💻".utf8))
    XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
    let edge = try LineCommand.moveUp.apply(to: "a\nb", selection: NSRange(location: 1, length: 0))
    XCTAssertEqual(
      edge, LineCommandResult(text: "a\nb", selection: NSRange(location: 1, length: 0)))
  }
  func testMovementInversePreservesExactUnicodeAndMixedMarkers() throws {
    for ending in ["", "\n", "\r", "\r\n"] {
      for first in ["", "é", "e\u{301}", "👩🏽‍💻"] {
        let text = first + "\r\nb\nc" + ending
        let original = NSRange(location: first.utf16.count + 2, length: 1)
        let up = try LineCommand.moveUp.apply(to: text, selection: original)
        XCTAssertFalse(up.text.utf16.elementsEqual(text.utf16))
        let down = try LineCommand.moveDown.apply(to: up.text, selection: up.selection)
        XCTAssertEqual(Data(down.text.utf8), Data(text.utf8))
      }
    }
  }
  func testTabStopsUseCurrentColumnAndKeepMixedMarkers() throws {
    XCTAssertEqual(
      try LineCommand.tabsToSpaces.apply(
        to: "a\tb\r\n\tq\rc", selection: NSRange(location: 0, length: 9)
      ).text, "a   b\r\n    q\rc")
    XCTAssertEqual(
      try LineCommand.spacesToTabs.apply(
        to: "a   b    c\nend", selection: NSRange(location: 0, length: 0)
      ).text, "a\tb\t c\nend")
    XCTAssertEqual(
      try LineCommand.tabsToSpaces.apply(
        to: "é\tend", selection: NSRange(location: 0, length: 0), tabWidth: 4
      ).text, "é   end")
  }
  func testTabConversionRoundTripsVisualColumnsAndGraphemes() throws {
    for source in ["a   b    c", "    ", "e\u{301}   q", "👩🏽‍💻   q", "  x  "] {
      for width in 1...8 {
        let compressed = try LineCommand.spacesToTabs.apply(
          to: source, selection: NSRange(location: 0, length: 0), tabWidth: width)
        let expanded = try LineCommand.tabsToSpaces.apply(
          to: compressed.text, selection: NSRange(location: 0, length: 0), tabWidth: width)
        XCTAssertEqual(Data(expanded.text.utf8), Data(source.utf8))
      }
    }
  }
  func testCaretInsideCompressedIndentMapsAfterTabBeforeEmoji() throws {
    for caret in 1...4 {
      let result = try LineCommand.spacesToTabs.apply(
        to: "    😀", selection: NSRange(location: caret, length: 0), tabWidth: 4)
      XCTAssertEqual(result.text, "\t😀")
      XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
    }
    let expanded = try LineCommand.tabsToSpaces.apply(
      to: "\t😀", selection: NSRange(location: 1, length: 0), tabWidth: 4)
    XCTAssertEqual(expanded.selection, NSRange(location: 4, length: 0))
  }
  func testSeededConversionCaretsStayAtScalarBoundariesAndMoveMonotonically() throws {
    var seed: UInt64 = 0xA718_C0DE
    func next(_ count: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(seed % UInt64(count))
    }
    let atoms = [" ", "    ", "\t", "😀", "e\u{301}", "👩🏽‍💻", "q"]
    for _ in 0..<64 {
      let source = (0..<8).map { _ in atoms[next(atoms.count)] }.joined()
      let input = Array(source.utf16)
      let width = next(8) + 1
      for command in [LineCommand.spacesToTabs, .tabsToSpaces] {
        var previous = 0
        for caret in 0...input.count
        where caret == input.count || !(0xDC00...0xDFFF).contains(input[caret]) {
          let result = try command.apply(
            to: source, selection: NSRange(location: caret, length: 0), tabWidth: width)
          let output = Array(result.text.utf16)
          let mapped = result.selection.location
          XCTAssertEqual(result.selection.length, 0)
          XCTAssertTrue((0...output.count).contains(mapped))
          if mapped < output.count {
            XCTAssertFalse(
              (0xDC00...0xDFFF).contains(output[mapped]),
              "\(command) width \(width), input caret \(caret)")
          }
          XCTAssertGreaterThanOrEqual(mapped, previous)
          previous = mapped
          if caret == 0 { XCTAssertEqual(mapped, 0) }
          if caret == input.count { XCTAssertEqual(mapped, output.count) }
        }
      }
    }
  }
  func testLineCountLimitIsExplicit() {
    XCTAssertThrowsError(
      try LineCommand.delete.apply(
        to: String(repeating: "\n", count: 200_000), selection: NSRange(location: 0, length: 0)))
  }
  func testInvalidRangesTabWidthsAndOversizedInputThrow() {
    for range in [
      NSRange(location: -1, length: 0), NSRange(location: 0, length: Int.max),
      NSRange(location: 1, length: 0),
    ] {
      XCTAssertThrowsError(try LineCommand.duplicate.apply(to: "😀", selection: range))
    }
    XCTAssertThrowsError(
      try LineCommand.tabsToSpaces.apply(
        to: "a", selection: NSRange(location: 0, length: 0), tabWidth: 0))
    XCTAssertThrowsError(
      try LineCommand.delete.apply(
        to: String(repeating: "x", count: 20_000_001), selection: NSRange(location: 0, length: 0)))
  }
}
