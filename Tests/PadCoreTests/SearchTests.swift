import Foundation
import XCTest

@testable import PadCore

final class SearchTests: XCTestCase {
  func testCaptureStorageBudgetRejectsLargeAggregate() {
    let query = SearchQuery(pattern: String(repeating: "()", count: 256), mode: .regex)
    XCTAssertThrowsError(
      try SearchService().matches(query, in: String(repeating: "a", count: 5_000)))
  }
  func testLiteralUnicodeCaseAndWholeWords() throws {
    let service = SearchService()
    XCTAssertEqual(
      try service.matches(
        SearchQuery(pattern: "cat", mode: .literal, caseSensitive: false, wholeWord: true),
        in: "🐈 Cat scatter cat"),
      [NSRange(location: 3, length: 3), NSRange(location: 15, length: 3)])
    XCTAssertEqual(
      try service.matches(SearchQuery(pattern: ".", mode: .literal), in: "a.b"),
      [NSRange(location: 1, length: 1)])
  }
  func testEscapedModeAndInvalidEscape() throws {
    let service = SearchService()
    XCTAssertEqual(
      try service.matches(SearchQuery(pattern: "\\n\\t", mode: .escaped), in: "a\n\tb"),
      [NSRange(location: 1, length: 2)])
    XCTAssertThrowsError(try service.matches(SearchQuery(pattern: "\\q", mode: .escaped), in: "q"))
  }
  func testSelectionBoundsAndSurrogateSafety() throws {
    let service = SearchService()
    let query = SearchQuery(pattern: "a", mode: .literal)
    XCTAssertEqual(
      try service.matches(query, in: "a🐈a", scope: NSRange(location: 3, length: 1)),
      [NSRange(location: 3, length: 1)])
    for range in [
      NSRange(location: -1, length: 1), NSRange(location: Int.max, length: 2),
      NSRange(location: 2, length: 1),
    ] {
      XCTAssertThrowsError(try service.matches(query, in: "a🐈a", scope: range))
    }
  }
  func testRegexZeroLengthMultilineAndMalformed() throws {
    let service = SearchService()
    XCTAssertEqual(
      try service.matches(SearchQuery(pattern: "(?m)^", mode: .regex), in: "a\nb"),
      [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
    XCTAssertThrowsError(try service.matches(SearchQuery(pattern: "[", mode: .regex), in: "abc"))
  }
  func testReplacementCaptureGroupsAndLiteralDollars() throws {
    let service = SearchService()
    XCTAssertEqual(
      try service.replacing(
        SearchQuery(pattern: "([a-z]+):(\\d+)", mode: .regex), in: "x:12 y:3", with: "$2=$1"),
      "12=x 3=y")
    XCTAssertEqual(
      try service.replacing(SearchQuery(pattern: "x", mode: .literal), in: "xx", with: "$1\\"),
      "$1\\$1\\")
  }
  func testLimitsNeverSilentlyTruncate() throws {
    XCTAssertThrowsError(
      try SearchService(maxTextUTF16: 2).matches(
        SearchQuery(pattern: "a", mode: .literal), in: "aaa")
    ) { XCTAssertEqual($0 as? SearchError, .textLimit) }
    XCTAssertThrowsError(
      try SearchService(maxMatches: 1).matches(SearchQuery(pattern: "a", mode: .literal), in: "aa")
    ) { XCTAssertEqual($0 as? SearchError, .matchLimit) }
    XCTAssertThrowsError(
      try SearchService(maxOutputUTF16: 3).replacing(
        SearchQuery(pattern: "a", mode: .literal), in: "aa", with: "xxx")
    ) { XCTAssertEqual($0 as? SearchError, .outputLimit) }
  }
  func testBoundedCaptureExpansionAndTemplateEscapes() throws {
    let query = SearchQuery(pattern: "(a)", mode: .regex)
    XCTAssertEqual(
      try SearchService(maxOutputUTF16: 3).replacing(query, in: "a", with: "$0$1$1"), "aaa")
    XCTAssertThrowsError(
      try SearchService(maxOutputUTF16: 3).replacing(query, in: "a", with: "$1$1$1$1")
    ) { XCTAssertEqual($0 as? SearchError, .outputLimit) }
    XCTAssertEqual(try SearchService().replacing(query, in: "a", with: "\\$1\\\\"), "$1\\")
    XCTAssertThrowsError(try SearchService().replacing(query, in: "a", with: "$2"))
    XCTAssertThrowsError(try SearchService().replacing(query, in: "a", with: "\\"))
  }

  func testCancellationAndExpiredBudget() throws {
    XCTAssertThrowsError(
      try SearchService(isCancelled: { true }).matches(
        SearchQuery(pattern: "a", mode: .literal), in: "a")
    ) { XCTAssertEqual($0 as? SearchError, .cancelled) }
    XCTAssertThrowsError(
      try SearchService(timeLimit: 0).matches(SearchQuery(pattern: "a", mode: .literal), in: "a")
    ) { XCTAssertEqual($0 as? SearchError, .timedOut) }
  }
  func testCatastrophicRegexReceivesProgressCancellation() throws {
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(
      try SearchService(timeLimit: 0.02).matches(
        SearchQuery(pattern: "(a+)+$", mode: .regex), in: String(repeating: "a", count: 200) + "!")
    ) { XCTAssertEqual($0 as? SearchError, .timedOut) }
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
  }
}
