import Foundation
import XCTest

@testable import PadCore

final class SearchExecutionTests: XCTestCase {
  func testRegexReplacementReturnsRangesAndOutputFromOneEnumeration() throws {
    var enumerations = 0
    let service = SearchService { expression, text, options, range, callback in
      enumerations += 1
      expression.enumerateMatches(in: text, options: options, range: range, using: callback)
    }
    let query = SearchQuery(pattern: "(a)", mode: .regex)

    let result = try service.execute(
      query, in: "a a", operation: .replace(template: "$1!"))

    XCTAssertEqual(
      result.matches,
      [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    XCTAssertEqual(result.replacement, "a! a!")
    XCTAssertEqual(enumerations, 1)
  }

  func testScopedReplacementUsesOriginalCoordinatesAndPreservesOutsideText() throws {
    let result = try SearchService().execute(
      SearchQuery(pattern: "a", mode: .literal), in: "a a a",
      scope: NSRange(location: 2, length: 1), operation: .replace(template: "b"))

    XCTAssertEqual(result.matches, [NSRange(location: 2, length: 1)])
    XCTAssertEqual(result.replacement, "a b a")
  }

  func testScopedWholeWordSearchDoesNotInventBoundaries() throws {
    let result = try SearchService().execute(
      SearchQuery(pattern: "a", mode: .literal, wholeWord: true), in: "cat",
      scope: NSRange(location: 1, length: 1), operation: .find)

    XCTAssertEqual(result, SearchExecutionOutput(matches: [], replacement: nil))
  }

  func testZeroLengthEOFReplacementAndLookaheadCaptures() throws {
    let service = SearchService()

    let eof = try service.execute(
      SearchQuery(pattern: "\\z", mode: .regex), in: "ab", operation: .replace(template: "!"))
    XCTAssertEqual(eof.matches, [NSRange(location: 2, length: 0)])
    XCTAssertEqual(eof.replacement, "ab!")

    let lookahead = try service.execute(
      SearchQuery(pattern: "(?=(a))", mode: .regex), in: "aa",
      operation: .replace(template: "$1"))
    XCTAssertEqual(
      lookahead.matches,
      [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)])
    XCTAssertEqual(lookahead.replacement, "aaaa")
  }

  func testRegexReplacementHandlesOptionalAndNumericCaptures() throws {
    let service = SearchService()

    let optional = try service.execute(
      SearchQuery(pattern: "(a)?b", mode: .regex), in: "b ab",
      operation: .replace(template: "<$1>"))
    XCTAssertEqual(
      optional.matches,
      [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)])
    XCTAssertEqual(optional.replacement, "<> <a>")

    let wholeMatch = try service.execute(
      SearchQuery(pattern: "(ab)", mode: .regex), in: "ab",
      operation: .replace(template: "[$0]"))
    XCTAssertEqual(wholeMatch.matches, [NSRange(location: 0, length: 2)])
    XCTAssertEqual(wholeMatch.replacement, "[ab]")

    let multiDigit = try service.execute(
      SearchQuery(pattern: "(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)", mode: .regex),
      in: "abcdefghijkl", operation: .replace(template: "$12-$1"))
    XCTAssertEqual(multiDigit.matches, [NSRange(location: 0, length: 12)])
    XCTAssertEqual(multiDigit.replacement, "l-a")

    let quoted = try service.execute(
      SearchQuery(pattern: "(a)", mode: .regex), in: "a",
      operation: .replace(template: "\\$1\\\\"))
    XCTAssertEqual(quoted.matches, [NSRange(location: 0, length: 1)])
    XCTAssertEqual(quoted.replacement, "$1\\")
  }

  func testLiteralAndEscapedModesKeepReplacementTemplatesLiteral() throws {
    let service = SearchService()

    let literal = try service.execute(
      SearchQuery(pattern: ".", mode: .literal), in: "a.b",
      operation: .replace(template: "$1\\"))
    XCTAssertEqual(literal.matches, [NSRange(location: 1, length: 1)])
    XCTAssertEqual(literal.replacement, "a$1\\b")

    let escaped = try service.execute(
      SearchQuery(pattern: "\\n\\0", mode: .escaped), in: "x\n\0y",
      operation: .replace(template: "$0\\"))
    XCTAssertEqual(escaped.matches, [NSRange(location: 1, length: 2)])
    XCTAssertEqual(escaped.replacement, "x$0\\y")
  }

  func testUnicodeResultsUseOriginalUTF16Coordinates() throws {
    let service = SearchService()

    let words = try service.execute(
      SearchQuery(pattern: "cat", mode: .literal, caseSensitive: false, wholeWord: true),
      in: "🐈 Cat scatter cat", operation: .find)
    XCTAssertEqual(
      words.matches,
      [NSRange(location: 3, length: 3), NSRange(location: 15, length: 3)])
    XCTAssertNil(words.replacement)

    let graphemes = try service.execute(
      SearchQuery(pattern: "🐈e\u{301}", mode: .literal), in: "x🐈e\u{301}y",
      operation: .replace(template: "Z"))
    XCTAssertEqual(graphemes.matches, [NSRange(location: 1, length: 4)])
    XCTAssertEqual(graphemes.replacement, "xZy")

    let preservedUnits = try service.execute(
      SearchQuery(pattern: "🐈", mode: .literal), in: "e\u{301}🐈y",
      operation: .replace(template: "Z"))
    XCTAssertEqual(preservedUnits.matches, [NSRange(location: 2, length: 2)])
    XCTAssertEqual(
      Array(try XCTUnwrap(preservedUnits.replacement).utf16),
      [0x0065, 0x0301, 0x005A, 0x0079])
  }

  func testNoMatchesProduceOperationSpecificOutput() throws {
    let service = SearchService()
    let query = SearchQuery(pattern: "z", mode: .literal)

    XCTAssertEqual(
      try service.execute(query, in: "abc", operation: .find),
      SearchExecutionOutput(matches: [], replacement: nil))
    XCTAssertEqual(
      try service.execute(query, in: "abc", operation: .replace(template: "x")),
      SearchExecutionOutput(matches: [], replacement: "abc"))
  }

  func testSearchValidationPrecedesReplacementValidation() {
    XCTAssertThrowsError(
      try SearchService().execute(
        SearchQuery(pattern: "[", mode: .regex), in: "abc",
        operation: .replace(template: "\\"))
    ) { XCTAssertEqual($0 as? SearchError, .invalidPattern) }

    XCTAssertThrowsError(
      try SearchService().execute(
        SearchQuery(pattern: "a", mode: .literal), in: "a",
        operation: .replace(template: String(repeating: "x", count: 4_097)))
    ) { XCTAssertEqual($0 as? SearchError, .outputLimit) }
  }

  func testInvalidSurrogateScopeDoesNotEnumerate() {
    var enumerations = 0
    let service = SearchService { expression, text, options, range, callback in
      enumerations += 1
      expression.enumerateMatches(in: text, options: options, range: range, using: callback)
    }

    XCTAssertThrowsError(
      try service.execute(
        SearchQuery(pattern: "a", mode: .literal), in: "a🐈a",
        scope: NSRange(location: 2, length: 1), operation: .find)
    ) { XCTAssertEqual($0 as? SearchError, .invalidScope) }
    XCTAssertEqual(enumerations, 0)
  }

  func testExecuteRejectsOversizedExpandedOutput() {
    XCTAssertThrowsError(
      try SearchService(maxOutputUTF16: 3).execute(
        SearchQuery(pattern: "a", mode: .literal), in: "aa",
        operation: .replace(template: "xxx"))
    ) { XCTAssertEqual($0 as? SearchError, .outputLimit) }
  }

  func testLegacyWrappersEachEnumerateOnce() throws {
    var enumerations = 0
    let service = SearchService { expression, text, options, range, callback in
      enumerations += 1
      expression.enumerateMatches(in: text, options: options, range: range, using: callback)
    }
    let query = SearchQuery(pattern: "(a)", mode: .regex)

    XCTAssertEqual(
      try service.matches(query, in: "a a"),
      [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    XCTAssertEqual(enumerations, 1)
    XCTAssertEqual(try service.replacing(query, in: "a a", with: "<$1>"), "<a> <a>")
    XCTAssertEqual(enumerations, 2)
  }
}
