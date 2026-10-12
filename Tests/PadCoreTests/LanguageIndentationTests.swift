import Foundation
import XCTest

@testable import PadCore

final class LanguageIndentationTests: XCTestCase {
  private func apply(
    _ command: LanguageIndentationCommand, _ text: String,
    _ selection: NSRange, _ policy: LanguageIndentation
  ) throws -> LineCommandResult {
    try LanguageIndentationEditing.apply(
      command: command, text: text, selection: selection, policy: policy)
  }

  func testSpacesWidthsOneTwoEightAndMixedEndingInverse() throws {
    let input = "a\r\n  😀b\n"
    for (width, expected) in [
      (1, " a\r\n   😀b\n"),
      (2, "  a\r\n    😀b\n"),
      (8, "        a\r\n          😀b\n"),
    ] {
      let result = try apply(.indent, input, NSRange(location: 0, length: 9), .spaces(width: width))
      XCTAssertEqual(Array(result.text.utf16), Array(expected.utf16))
      XCTAssertEqual(result.selection, NSRange(location: 0, length: 9 + 2 * width))
      let inverse = try apply(.outdent, result.text, result.selection, .spaces(width: width))
      XCTAssertEqual(Array(inverse.text.utf16), Array(input.utf16))
      XCTAssertEqual(inverse.selection, NSRange(location: 0, length: 9))
    }
  }

  func testInsertionSuppliesBoundedSpacesOneTabAndLegacyTab() throws {
    for (width, spaces) in [(1, " "), (2, "  "), (8, "        ")] {
      XCTAssertEqual(try LanguageIndentationEditing.insertion(for: .spaces(width: width)), spaces)
      XCTAssertEqual(try LanguageIndentationEditing.insertion(for: .tabs(width: width)), "\t")
    }
    XCTAssertEqual(try LanguageIndentationEditing.insertion(for: .tabs(width: 3)), "\t")
    XCTAssertEqual(try LanguageIndentationEditing.insertion(for: .legacy), "\t")
  }

  func testInvalidWidthsRefuseBothInsertionAndLineCommands() {
    for width in [0, 9, Int.max] {
      for policy in [LanguageIndentation.spaces(width: width), .tabs(width: width)] {
        XCTAssertThrowsError(try LanguageIndentationEditing.insertion(for: policy)) {
          XCTAssertEqual($0 as? LanguageIndentationError, .invalidWidth)
        }
        for command in [LanguageIndentationCommand.indent, .outdent] {
          XCTAssertThrowsError(try apply(command, "x", NSRange(location: 0, length: 1), policy)) {
            XCTAssertEqual($0 as? LanguageIndentationError, .invalidWidth)
          }
        }
      }
    }
  }

  func testCaretMapsThroughIndentAndRemovedLeadingWhitespace() throws {
    let indented = try apply(.indent, "a\n😀b", NSRange(location: 4, length: 0), .spaces(width: 2))
    XCTAssertEqual(Array(indented.text.utf16), Array("a\n  😀b".utf16))
    XCTAssertEqual(indented.selection, NSRange(location: 6, length: 0))
    let inside = try apply(.outdent, "  😀b", NSRange(location: 1, length: 0), .spaces(width: 2))
    XCTAssertEqual(Array(inside.text.utf16), Array("😀b".utf16))
    XCTAssertEqual(inside.selection, NSRange(location: 0, length: 0))
    let after = try apply(.outdent, "  😀b", NSRange(location: 4, length: 0), .spaces(width: 2))
    XCTAssertEqual(after.selection, NSRange(location: 2, length: 0))
  }

  func testSelectionEndpointAtNextLineLeavesThatLineUnchanged() throws {
    let changed = try apply(
      .indent, "a\r\nb\nc", NSRange(location: 1, length: 2), .spaces(width: 2))
    XCTAssertEqual(Array(changed.text.utf16), Array("  a\r\nb\nc".utf16))
    XCTAssertEqual(changed.selection, NSRange(location: 0, length: 5))
    let restored = try apply(.outdent, changed.text, changed.selection, .spaces(width: 2))
    XCTAssertEqual(Array(restored.text.utf16), Array("a\r\nb\nc".utf16))
    XCTAssertEqual(restored.selection, NSRange(location: 0, length: 3))
  }

  func testEmptyLastLineCaretAndEmptyDocumentAreEditable() throws {
    let whole = try apply(.indent, "x\n", NSRange(location: 0, length: 2), .spaces(width: 2))
    XCTAssertEqual(whole.text, "  x\n")
    XCTAssertEqual(whole.selection, NSRange(location: 0, length: 4))
    let eof = try apply(.indent, "x\n", NSRange(location: 2, length: 0), .spaces(width: 2))
    XCTAssertEqual(eof.text, "x\n  ")
    XCTAssertEqual(eof.selection, NSRange(location: 4, length: 0))
    let restored = try apply(.outdent, eof.text, eof.selection, .spaces(width: 2))
    XCTAssertEqual(restored.text, "x\n")
    XCTAssertEqual(restored.selection, NSRange(location: 2, length: 0))
    let empty = try apply(.indent, "", NSRange(location: 0, length: 0), .tabs(width: 3))
    XCTAssertEqual(empty.text, "\t")
    XCTAssertEqual(empty.selection, NSRange(location: 1, length: 0))
  }

  func testOutdentRemovesOneLeadingTabOrAtMostPolicySpaces() throws {
    for policy in [LanguageIndentation.spaces(width: 2), .tabs(width: 2)] {
      let result = try apply(
        .outdent, "\t x\r\n   y\rz\n", NSRange(location: 0, length: 12), policy)
      XCTAssertEqual(Array(result.text.utf16), Array(" x\r\n y\rz\n".utf16))
      XCTAssertEqual(result.selection, NSRange(location: 0, length: 9))
    }
    let legacy = try apply(.outdent, "     x\n\t y", NSRange(location: 0, length: 10), .legacy)
    XCTAssertEqual(legacy.text, " x\n y")
    XCTAssertEqual(legacy.selection, NSRange(location: 0, length: 5))
  }

  func testMixedCRLFCRLFAndNormalizationDistinctTextRemainExact() throws {
    let input = "😀\r\né\re\u{301}\nx"
    let result = try apply(.indent, input, NSRange(location: 0, length: 10), .tabs(width: 3))
    XCTAssertEqual(Array(result.text.utf16), Array("\t😀\r\n\té\r\te\u{301}\n\tx".utf16))
    XCTAssertEqual(result.selection, NSRange(location: 0, length: 14))
    let inverse = try apply(.outdent, result.text, result.selection, .tabs(width: 3))
    XCTAssertEqual(Array(inverse.text.utf16), Array(input.utf16))
    XCTAssertEqual(inverse.selection, NSRange(location: 0, length: 10))
    // A boundary between base and combining mark is scalar-safe.
    let scalar = try apply(.indent, "e\u{301}", NSRange(location: 1, length: 0), .spaces(width: 1))
    XCTAssertEqual(Array(scalar.text.utf16), Array(" e\u{301}".utf16))
    XCTAssertEqual(scalar.selection, NSRange(location: 2, length: 0))
  }

  func testInvalidAndDividedSupplementaryScalarSelectionsRefuse() {
    for selection in [
      NSRange(location: 1, length: 0), NSRange(location: 0, length: 1),
      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
      NSRange(location: 3, length: 0), NSRange(location: Int.max, length: Int.max),
    ] {
      for command in [LanguageIndentationCommand.indent, .outdent] {
        XCTAssertThrowsError(try apply(command, "😀", selection, .spaces(width: 2))) {
          XCTAssertEqual($0 as? LanguageIndentationError, .invalidSelection)
        }
      }
    }
  }

  func testTwoMillionInputLimitAcceptsExactAndRefusesPlusOneWithoutResult() throws {
    let exact = String(repeating: "x", count: 2_000_000)
    let accepted = try apply(.outdent, exact, NSRange(location: 0, length: 0), .spaces(width: 1))
    XCTAssertEqual(accepted.text.utf16.count, 2_000_000)
    XCTAssertTrue(accepted.text.utf16.elementsEqual(exact.utf16))
    XCTAssertEqual(accepted.selection, NSRange(location: 0, length: 0))
    for command in [LanguageIndentationCommand.indent, .outdent] {
      XCTAssertThrowsError(
        try apply(command, exact + "x", NSRange(location: 0, length: 0), .spaces(width: 1))
      ) {
        XCTAssertEqual($0 as? LanguageIndentationError, .textLimit)
      }
    }
  }

  func testProjectedOutputLimitAcceptsExactAndRefusesGrowthPastCap() throws {
    let below = String(repeating: "x", count: 1_999_999)
    let exact = try apply(.indent, below, NSRange(location: 0, length: 0), .spaces(width: 1))
    XCTAssertEqual(exact.text.utf16.count, 2_000_000)
    XCTAssertTrue(exact.text.utf16.elementsEqual((" " + below).utf16))
    XCTAssertEqual(exact.selection, NSRange(location: 1, length: 0))
    XCTAssertThrowsError(
      try apply(.indent, below + "x", NSRange(location: 0, length: 0), .spaces(width: 1))
    ) {
      XCTAssertEqual($0 as? LanguageIndentationError, .textLimit)
    }
  }

  func testTwentyThousandLogicalLinesIncludingTrailingEmptyLineBound() throws {
    let below = String(repeating: "x\n", count: 19_998) + "x"
    let belowResult = try apply(
      .indent, below, NSRange(location: 0, length: 39_997), .spaces(width: 1))
    XCTAssertTrue(
      belowResult.text.utf16.elementsEqual((String(repeating: " x\n", count: 19_998) + " x").utf16))
    XCTAssertEqual(belowResult.selection, NSRange(location: 0, length: 59_996))
    let exact = String(repeating: "x\n", count: 19_999) + "x"
    let accepted = try apply(
      .indent, exact, NSRange(location: 0, length: 39_999), .spaces(width: 1))
    let expected = String(repeating: " x\n", count: 19_999) + " x"
    XCTAssertTrue(accepted.text.utf16.elementsEqual(expected.utf16))
    XCTAssertEqual(accepted.selection, NSRange(location: 0, length: 59_999))
    let trailing = String(repeating: "\r\n", count: 19_999)
    let eof = try apply(.indent, trailing, NSRange(location: 39_998, length: 0), .spaces(width: 1))
    XCTAssertTrue(eof.text.utf16.elementsEqual((trailing + " ").utf16))
    XCTAssertEqual(eof.selection, NSRange(location: 39_999, length: 0))
    for text in [exact + "\nx", String(repeating: "\r\n", count: 20_000)] {
      for command in [LanguageIndentationCommand.indent, .outdent] {
        XCTAssertThrowsError(
          try apply(command, text, NSRange(location: 0, length: 0), .spaces(width: 1))
        ) {
          XCTAssertEqual($0 as? LanguageIndentationError, .lineLimit)
        }
      }
    }
  }

  func testImmediateCancellationCannotReturnPartialResult() {
    for command in [LanguageIndentationCommand.indent, .outdent] {
      var checks = 0
      XCTAssertThrowsError(
        try LanguageIndentationEditing.apply(
          command: command, text: "😀\r\n x", selection: NSRange(location: 0, length: 6),
          policy: .spaces(width: 2),
          isCancelled: {
            checks += 1
            return true
          })
      ) {
        XCTAssertTrue($0 is CancellationError)
      }
      XCTAssertGreaterThan(checks, 0)
      XCTAssertLessThanOrEqual(checks, 4)
    }
  }

  func testMidCallCancellationDuringLongScanReturnsNoResult() {
    for text in [String(repeating: "x", count: 40_000), String(repeating: " \r\n", count: 10_000)] {
      var checks = 0
      XCTAssertThrowsError(
        try LanguageIndentationEditing.apply(
          command: .indent, text: text, selection: NSRange(location: 0, length: text.utf16.count),
          policy: .spaces(width: 2),
          isCancelled: {
            checks += 1
            return checks >= 3
          })
      ) {
        XCTAssertTrue($0 is CancellationError)
      }
      XCTAssertEqual(checks, 3)
    }
  }
}
