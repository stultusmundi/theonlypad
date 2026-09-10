import Foundation
import XCTest

@testable import PadCore

final class SearchEngineFailureTests: XCTestCase {
  private typealias Callback = (
    NSTextCheckingResult?, NSRegularExpression.MatchingFlags, UnsafeMutablePointer<ObjCBool>
  ) -> Void

  private func callback(
    _ block: Callback, result: NSTextCheckingResult? = nil,
    flags: NSRegularExpression.MatchingFlags
  ) {
    var stop = ObjCBool(false)
    block(result, flags, &stop)
  }

  private func firstMatch(
    _ expression: NSRegularExpression, text: String, range: NSRange
  ) -> NSTextCheckingResult {
    expression.firstMatch(in: text, range: range)!
  }

  func testNilInternalErrorFailsFindAndReplacement() {
    let service = SearchService { _, _, _, _, block in
      self.callback(block, flags: .internalError)
    }
    let query = SearchQuery(pattern: "a", mode: .regex)

    XCTAssertThrowsError(try service.matches(query, in: "aa")) {
      XCTAssertEqual($0 as? SearchError, .engineFailure)
    }
    XCTAssertThrowsError(try service.replacing(query, in: "aa", with: "b")) {
      XCTAssertEqual($0 as? SearchError, .engineFailure)
    }
  }

  func testCompletionInternalErrorRejectsEarlierPartialMatch() {
    let service = SearchService { expression, text, _, range, block in
      self.callback(block, result: self.firstMatch(expression, text: text, range: range), flags: [])
      self.callback(block, flags: [.completed, .internalError])
    }

    XCTAssertThrowsError(
      try service.matches(SearchQuery(pattern: "a", mode: .regex), in: "aa")
    ) { XCTAssertEqual($0 as? SearchError, .engineFailure) }
  }

  func testExecuteReplacementRejectsEarlierPartialMatchOnEngineFailure() {
    let service = SearchService { expression, text, _, range, block in
      self.callback(block, result: self.firstMatch(expression, text: text, range: range), flags: [])
      self.callback(block, flags: [.completed, .internalError])
    }

    XCTAssertThrowsError(
      try service.execute(
        SearchQuery(pattern: "a", mode: .regex), in: "aa",
        operation: .replace(template: "b"))
    ) { XCTAssertEqual($0 as? SearchError, .engineFailure) }
  }

  func testResultInternalErrorWinsBeforeMatchLimit() {
    let service = SearchService(maxMatches: 0) { expression, text, _, range, block in
      self.callback(
        block, result: self.firstMatch(expression, text: text, range: range), flags: .internalError)
    }

    XCTAssertThrowsError(
      try service.matches(SearchQuery(pattern: "a", mode: .regex), in: "aa")
    ) { XCTAssertEqual($0 as? SearchError, .engineFailure) }
  }

  func testRequestsCompletionProgressAndExistingBoundsOptions() throws {
    var received: NSRegularExpression.MatchingOptions = []
    let service = SearchService { _, _, options, _, block in
      received = options
      self.callback(block, flags: [.progress, .completed, .hitEnd, .requiredEnd])
    }

    XCTAssertEqual(
      try service.matches(SearchQuery(pattern: "a", mode: .regex), in: "aa"), [])
    XCTAssertTrue(received.contains(.reportProgress))
    XCTAssertTrue(received.contains(.reportCompletion))
    XCTAssertTrue(received.contains(.withTransparentBounds))
    XCTAssertTrue(received.contains(.withoutAnchoringBounds))
  }

  func testFirstMatchLimitFailureSurvivesLaterEngineError() {
    let service = SearchService(maxMatches: 1) { expression, text, _, range, block in
      let result = self.firstMatch(expression, text: text, range: range)
      self.callback(block, result: result, flags: [])
      self.callback(block, result: result, flags: [])
      self.callback(block, flags: [.completed, .internalError])
    }

    XCTAssertThrowsError(
      try service.matches(SearchQuery(pattern: "a", mode: .regex), in: "aa")
    ) { XCTAssertEqual($0 as? SearchError, .matchLimit) }
  }

  func testFirstCancellationSurvivesLaterEngineError() {
    var cancelled = false
    let service = SearchService(
      isCancelled: { cancelled },
      enumerateMatches: { _, _, _, _, block in
        cancelled = true
        self.callback(block, flags: .progress)
        self.callback(block, flags: [.completed, .internalError])
      })

    XCTAssertThrowsError(
      try service.matches(SearchQuery(pattern: "a", mode: .regex), in: "aa")
    ) { XCTAssertEqual($0 as? SearchError, .cancelled) }
  }

  func testRealFoundationEnumerationStillFindsAndReplaces() throws {
    let service = SearchService()
    let query = SearchQuery(pattern: "(a)", mode: .regex)

    XCTAssertEqual(
      try service.matches(query, in: "aa"),
      [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
    XCTAssertEqual(try service.replacing(query, in: "aa", with: "<$1>"), "<a><a>")
  }
}
