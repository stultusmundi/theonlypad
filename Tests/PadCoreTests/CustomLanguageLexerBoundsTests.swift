import Foundation
import XCTest

@testable import PadCore

final class CustomLanguageLexerBoundsTests: XCTestCase {
  private func routes() -> [(CustomLanguageLexerCheckpointPhase, String, [SyntaxToken])] {
    let plain = String(repeating: "x", count: 32_768)
    let block = "(*" + String(repeating: "x\r\n", count: 11_000) + "*)"
    let escaped = "\"" + String(repeating: "\\😀", count: 10_923) + "\""
    return [
      (.preflight, String(repeating: "😀", count: 16_384), []),
      (.scan, String(repeating: "! ", count: 16_384), []),
      (.comment, "#" + plain, [.init(range: NSRange(location: 0, length: 32_769), kind: .comment)]),
      (.comment, block, [.init(range: NSRange(location: 0, length: 33_004), kind: .comment)]),
      (
        .quote, "\"" + plain + "\"",
        [.init(range: NSRange(location: 0, length: 32_770), kind: .string)]
      ),
      (.quote, escaped, [.init(range: NSRange(location: 0, length: 32_771), kind: .string)]),
      (.identifier, plain, []),
      (.identifier, String(repeating: "𐐀", count: 16_384), []),
      (
        .number, String(repeating: "7", count: 32_768),
        [.init(range: NSRange(location: 0, length: 32_768), kind: .number)]
      ),
    ]
  }

  func testEveryLongScanPhasePollsWithin4096ConsumedUTF16Units() throws {
    let d = try LexerTestFixture.definition()
    for (phase, text, expected) in routes() {
      let end = text.utf16.count
      var seen = false
      var last = 0
      var largestGap = 0
      var invalidOffset = false
      var checks = 0
      do {
        let tokens = try CustomLanguageLexer.tokens(
          in: text, definition: d, isCancelled: { false },
          onCheckpoint: { current, offset in
            guard current == phase else { return }
            seen = true
            checks += 1
            if offset < last || offset < 0 || offset > end { invalidOffset = true }
            largestGap = max(largestGap, offset - last)
            last = offset
          })
        XCTAssertEqual(tokens, expected, "Independent literal output for \(phase)")
        lexerScalarRanges(tokens, in: text)
      } catch {
        XCTFail("Valid bounded scan refused during \(phase): \(error)")
      }
      XCTAssertTrue(seen, "Actual cancellation boundary must reach named phase \(phase)")
      XCTAssertGreaterThan(checks, 0)
      XCTAssertFalse(invalidOffset)
      XCTAssertLessThanOrEqual(largestGap, 4_096, "Consumed gap in \(phase)")
      XCTAssertLessThanOrEqual(end - last, 4_096, "Unpolled phase tail in \(phase)")
    }
  }

  func testCancellationAtActualNamedPhaseNeverReturnsPartialTokens() throws {
    let d = try LexerTestFixture.definition()
    for (phase, text, _) in routes() {
      let end = text.utf16.count
      var cancelled = false
      var seen = false
      var last = 0
      var largestGap = 0
      var invalidOffset = false
      do {
        _ = try CustomLanguageLexer.tokens(
          in: text, definition: d, isCancelled: { cancelled },
          onCheckpoint: { current, offset in
            guard current == phase else { return }
            seen = true
            if offset < last || offset < 0 || offset > end { invalidOffset = true }
            largestGap = max(largestGap, offset - last)
            last = offset
            if offset >= 12_288 { cancelled = true }
          })
        XCTFail("Named-phase cancellation must throw, not return any partial result: \(phase)")
      } catch {
        XCTAssertTrue(error is CancellationError, "Expected cancellation in \(phase), got \(error)")
      }
      XCTAssertTrue(seen, "No synthetic loop may substitute for actual \(phase) scan")
      XCTAssertTrue(cancelled, "Actual scan must reach cancellation threshold in \(phase)")
      XCTAssertFalse(invalidOffset)
      XCTAssertLessThanOrEqual(largestGap, 4_096)
    }
  }

  func testBoolOnlyMidCallCancellationRefusesWholeResultWithKeywordInput() throws {
    let d = try LexerTestFixture.definition()
    let text = "let #" + String(repeating: "x", count: 32_768)
    guard let prefix = lexerTokens("let", definition: d) else { return }
    XCTAssertEqual(prefix, [.init(range: NSRange(location: 0, length: 3), kind: .keyword)])
    var checks = 0
    do {
      _ = try CustomLanguageLexer.tokens(
        in: text, definition: d,
        isCancelled: {
          checks += 1
          return checks >= 3
        })
      XCTFail("Mid-call cancellation must refuse the whole result")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertGreaterThanOrEqual(checks, 3, "Cancellation must be tested inside real work")
  }

  func testLongCommentCancellationAfterLeadingKeywordReturnsNoPartialResult() throws {
    let d = try LexerTestFixture.definition()
    guard let prefix = lexerTokens("let", definition: d) else { return }
    XCTAssertEqual(prefix, [.init(range: NSRange(location: 0, length: 3), kind: .keyword)])
    let text = "let #" + String(repeating: "x", count: 32_768)
    var cancelled = false
    var reachedComment = false
    do {
      _ = try CustomLanguageLexer.tokens(
        in: text, definition: d, isCancelled: { cancelled },
        onCheckpoint: { phase, offset in
          guard phase == .comment else { return }
          reachedComment = true
          if offset >= 12_288 { cancelled = true }
        })
      XCTFail("Cancellation during actual comment scan must return no partial keyword prefix")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertTrue(reachedComment)
    XCTAssertTrue(cancelled)
  }

  func testInitialCancellationPrecedesOversizedInputRefusal() throws {
    let d = try LexerTestFixture.definition()
    let text = String(repeating: "x", count: 2_000_001)
    do {
      _ = try CustomLanguageLexer.tokens(in: text, definition: d, isCancelled: { true })
      XCTFail("Initial cancellation must refuse")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testExactlyTwoMillionUnitsAcceptsRealKeywordOutput() throws {
    let text = "let" + String(repeating: " ", count: 1_999_997)
    guard let tokens = lexerTokens(text, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(tokens, [.init(range: NSRange(location: 0, length: 3), kind: .keyword)])
    lexerScalarRanges(tokens, in: text)
  }

  func testTwoMillionPlusOneRefusesRatherThanTruncates() throws {
    let d = try LexerTestFixture.definition()
    lexerLimit {
      try CustomLanguageLexer.tokens(
        in: String(repeating: "x", count: 2_000_001), definition: d)
    }
  }

  func testOversizePreflightPollsAndStopsByTwoMillionPlusOneBeforeAllocation() throws {
    let d = try LexerTestFixture.definition()
    let text = String(repeating: "x", count: 2_004_098)
    var last = 0
    var largestGap = 0
    var invalidOffset = false
    var seen = false
    lexerLimit {
      try CustomLanguageLexer.tokens(
        in: text, definition: d, isCancelled: { false },
        onCheckpoint: { phase, offset in
          guard phase == .preflight else { return }
          seen = true
          if offset < last || offset < 0 || offset > 2_000_001 { invalidOffset = true }
          largestGap = max(largestGap, offset - last)
          last = offset
        })
    }
    XCTAssertTrue(seen)
    XCTAssertFalse(invalidOffset)
    XCTAssertLessThanOrEqual(largestGap, 4_096)
    XCTAssertLessThanOrEqual(
      2_000_001 - last, 4_096,
      "Rejecting preflight must have actual bounded-progress cancellation observations")
  }

  func testExactlyOneHundredThousandTokensAcceptsAllLiteralRanges() throws {
    let text = String(repeating: "let ", count: 100_000)
    guard let tokens = lexerTokens(text, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(tokens.count, 100_000)
    guard tokens.count == 100_000 else { return }
    XCTAssertEqual(
      tokens.first, SyntaxToken(range: NSRange(location: 0, length: 3), kind: .keyword))
    XCTAssertEqual(
      tokens.last, SyntaxToken(range: NSRange(location: 399_996, length: 3), kind: .keyword))
    for (index, token) in tokens.enumerated() {
      XCTAssertEqual(token.range, NSRange(location: index * 4, length: 3))
      XCTAssertEqual(token.kind, .keyword)
    }
    lexerScalarRanges(tokens, in: text)
  }

  func testOneHundredThousandPlusOneTokensThrowsWithoutPartialResult() throws {
    let d = try LexerTestFixture.definition()
    lexerLimit {
      try CustomLanguageLexer.tokens(
        in: String(repeating: "let ", count: 100_001), definition: d)
    }
  }
}
