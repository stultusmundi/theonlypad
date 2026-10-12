import Foundation
import XCTest

@testable import PadCore

final class CustomLanguageLexerTests: XCTestCase {
  func testLiteralMaskingUsesExactUTF16RangesAndOriginalKinds() throws {
    let text = "😀 let x = \"print\" # café\r\nprint 42"
    guard let tokens = lexerTokens(text, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 3, length: 3), kind: .keyword),
        .init(range: NSRange(location: 11, length: 7), kind: .string),
        .init(range: NSRange(location: 19, length: 6), kind: .comment),
        .init(range: NSRange(location: 27, length: 5), kind: .keyword),
        .init(range: NSRange(location: 33, length: 2), kind: .number),
      ])
    XCTAssertEqual(
      tokens.map { (text as NSString).substring(with: $0.range) },
      [
        "let", "\"print\"", "# café", "print", "42",
      ])
    lexerScalarRanges(tokens, in: text)
  }

  func testLongestBlockCommentBeatsShorterLinePrefix() throws {
    let d = try LexerTestFixture.definition(line: "/", block: .init(opening: "/*", closing: "*/"))
    let text = "/* let\nlet */ let"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 13), kind: .comment),
        .init(range: NSRange(location: 14, length: 3), kind: .keyword),
      ])
  }

  func testLongerLineCommentBeatsShorterBlockPrefix() throws {
    let d = try LexerTestFixture.definition(line: "/*/", block: .init(opening: "/*", closing: "*/"))
    let text = "/*/ let */ let\nlet"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 14), kind: .comment),
        .init(range: NSRange(location: 15, length: 3), kind: .keyword),
      ])
  }

  func testCommentPrecedenceBeatsEvenLongerQuoteOpening() throws {
    let quote = try LiteralQuoteRule(opening: "/**", closing: "!", escape: nil, multiline: true)
    let d = try LexerTestFixture.definition(line: "/", block: nil, quotes: [quote])
    let text = "/** let!\nlet"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 8), kind: .comment),
        .init(range: NSRange(location: 9, length: 3), kind: .keyword),
      ])
  }

  func testLongestQuotePrefixAndUnterminatedQuoteMaskWholeSpan() throws {
    let short = try LiteralQuoteRule(opening: "<", closing: ">", escape: nil, multiline: true)
    let long = try LiteralQuoteRule(opening: "<<", closing: ">>", escape: nil, multiline: true)
    let d = try LexerTestFixture.definition(quotes: [short, long])
    let text = "<< let >> let"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 9), kind: .string),
        .init(range: NSRange(location: 10, length: 3), kind: .keyword),
      ])
    let unfinished = "<< let"
    guard let tail = lexerTokens(unfinished, definition: d) else { return }
    XCTAssertEqual(tail, [.init(range: NSRange(location: 0, length: 6), kind: .string)])
  }

  func testWholeIdentifierBoundariesAndCaseSensitivity() throws {
    let text = "let letx xlet _let let_ let2 LET let\u{301} print"
    let d = try LexerTestFixture.definition(keywords: ["let", "print"])
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 3), kind: .keyword),
        .init(range: NSRange(location: 38, length: 5), kind: .keyword),
      ])
    XCTAssertEqual(tokens.map { (text as NSString).substring(with: $0.range) }, ["let", "print"])
  }

  func testComposedAndDecomposedKeywordsMatchOnlyTheirExactRawSpelling() throws {
    let text = "café cafe\u{301}"
    let onlyComposed = try LexerTestFixture.definition(keywords: ["café"])
    guard let first = lexerTokens(text, definition: onlyComposed) else { return }
    XCTAssertEqual(first, [.init(range: NSRange(location: 0, length: 4), kind: .keyword)])
    let onlyDecomposed = try LexerTestFixture.definition(keywords: ["cafe\u{301}"])
    guard let second = lexerTokens(text, definition: onlyDecomposed) else { return }
    XCTAssertEqual(second, [.init(range: NSRange(location: 5, length: 5), kind: .keyword)])
    let both = try LexerTestFixture.definition(keywords: ["café", "cafe\u{301}"])
    guard let combined = lexerTokens(text, definition: both) else { return }
    XCTAssertEqual(
      combined,
      [
        .init(range: NSRange(location: 0, length: 4), kind: .keyword),
        .init(range: NSRange(location: 5, length: 5), kind: .keyword),
      ])
  }

  func testAstralIdentifierAndEmojiSeparatorsNeverDivideScalarRanges() throws {
    let text = "😀 𐐀a let 😀let"
    let d = try LexerTestFixture.definition(keywords: ["𐐀a", "let"])
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 3, length: 3), kind: .keyword),
        .init(range: NSRange(location: 7, length: 3), kind: .keyword),
        .init(range: NSRange(location: 13, length: 3), kind: .keyword),
      ])
    lexerScalarRanges(tokens, in: text)
  }

  func testRawDelimiterSpellingDoesNotCanonicalizeQuoteOpeners() throws {
    let quote = try LiteralQuoteRule(opening: "é", closing: "!", escape: nil, multiline: false)
    let d = try LexerTestFixture.definition(
      keywords: ["let"], line: nil, block: nil, quotes: [quote])
    let text = "e\u{301} let! élet! let"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 3, length: 3), kind: .keyword),
        .init(range: NSRange(location: 8, length: 5), kind: .string),
        .init(range: NSRange(location: 14, length: 3), kind: .keyword),
      ])
    lexerScalarRanges(tokens, in: text)
  }

  func testRawLineAndBlockCommentOpenersRemainCanonicalDistinct() throws {
    let lineText = "e\u{301} let\né let\nlet"
    let lineDefinition = try LexerTestFixture.definition(
      keywords: ["let"], line: "é", block: nil, quotes: [])
    guard let lineTokens = lexerTokens(lineText, definition: lineDefinition) else { return }
    XCTAssertEqual(
      lineTokens,
      [
        .init(range: NSRange(location: 3, length: 3), kind: .keyword),
        .init(range: NSRange(location: 7, length: 5), kind: .comment),
        .init(range: NSRange(location: 13, length: 3), kind: .keyword),
      ])
    let blockText = "e\u{301} let! é let! let"
    let blockDefinition = try LexerTestFixture.definition(
      keywords: ["let"], line: nil, block: .init(opening: "é", closing: "!"), quotes: [])
    guard let blockTokens = lexerTokens(blockText, definition: blockDefinition) else { return }
    XCTAssertEqual(
      blockTokens,
      [
        .init(range: NSRange(location: 3, length: 3), kind: .keyword),
        .init(range: NSRange(location: 8, length: 6), kind: .comment),
        .init(range: NSRange(location: 15, length: 3), kind: .keyword),
      ])
    lexerScalarRanges(lineTokens, in: lineText)
    lexerScalarRanges(blockTokens, in: blockText)
  }

  func testEscapedSupplementaryClosingDelimiterConsumesWholeScalar() throws {
    let quote = try LiteralQuoteRule(opening: "[", closing: "😀", escape: "\\", multiline: true)
    let d = try LexerTestFixture.definition(quotes: [quote])
    let text = "[\\😀 let😀 let"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 10), kind: .string),
        .init(range: NSRange(location: 11, length: 3), kind: .keyword),
      ])
    lexerScalarRanges(tokens, in: text)
  }

  func testLineCommentCRLFLoneCRAndLFEndsPreserveNextKeyword() throws {
    let text = "# let\rlet\n# let\r\nlet"
    guard let tokens = lexerTokens(text, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 5), kind: .comment),
        .init(range: NSRange(location: 6, length: 3), kind: .keyword),
        .init(range: NSRange(location: 10, length: 5), kind: .comment),
        .init(range: NSRange(location: 17, length: 3), kind: .keyword),
      ])
  }

  func testNonmultilineQuoteStopsBeforeCRLFWhileMultilineMasksBothLines() throws {
    let text = "\"let\r\nlet"
    let single = try LiteralQuoteRule(opening: "\"", closing: "\"", escape: nil, multiline: false)
    let multi = try LiteralQuoteRule(opening: "\"", closing: "\"", escape: nil, multiline: true)
    guard
      let first = lexerTokens(text, definition: try LexerTestFixture.definition(quotes: [single]))
    else { return }
    XCTAssertEqual(
      first,
      [
        .init(range: NSRange(location: 0, length: 4), kind: .string),
        .init(range: NSRange(location: 6, length: 3), kind: .keyword),
      ])
    guard
      let second = lexerTokens(text, definition: try LexerTestFixture.definition(quotes: [multi]))
    else { return }
    XCTAssertEqual(second, [.init(range: NSRange(location: 0, length: 9), kind: .string)])
  }

  func testNonnestingBlockClosesAtFirstClosingAndUnterminatedConsumesEOF() throws {
    let text = "(* a (* b *) let *)"
    guard let tokens = lexerTokens(text, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(
      tokens,
      [
        .init(range: NSRange(location: 0, length: 12), kind: .comment),
        .init(range: NSRange(location: 13, length: 3), kind: .keyword),
      ])
    let unfinished = "(* let\r\nprint"
    guard let tail = lexerTokens(unfinished, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(tail, [.init(range: NSRange(location: 0, length: 13), kind: .comment)])
  }

  func testASCIIIntegerRunsRespectFlagAndIdentifierMasking() throws {
    let text = "12 007 x42 １２"
    guard let enabled = lexerTokens(text, definition: try LexerTestFixture.definition()) else {
      return
    }
    XCTAssertEqual(
      enabled,
      [
        .init(range: NSRange(location: 0, length: 2), kind: .number),
        .init(range: NSRange(location: 3, length: 3), kind: .number),
      ])
    guard
      let disabled = lexerTokens(
        text, definition: try LexerTestFixture.definition(numbers: false))
    else { return }
    XCTAssertEqual(disabled, [])
  }

  func testEditingOnlyDefinitionDoesNotInventTokens() throws {
    let d = try LexerTestFixture.definition(
      keywords: [], line: nil, block: nil, quotes: [], numbers: false)
    let text = "😀 let \"print\" # 42 (* café *)"
    guard let tokens = lexerTokens(text, definition: d) else { return }
    XCTAssertEqual(tokens, [])
  }
}
