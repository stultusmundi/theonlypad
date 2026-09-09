import XCTest

@testable import PadCore

final class LanguageTests: XCTestCase {
  func testDetectionAndPlainText() {
    XCTAssertEqual(LanguageService.detect(filename: "a.swift", text: ""), .swift)
    XCTAssertEqual(
      LanguageService.detect(filename: "script", text: "#!/usr/bin/env python3\n"), .python)
    XCTAssertEqual(LanguageService.detect(filename: "notes.txt", text: ""), .plainText)
  }
  func testTokensDoNotHighlightKeywordsInsideStringsOrComments() throws {
    let source = "let name = \"class\" // return\n42"
    let tokens = try LanguageService.tokens(in: source, language: .swift)
    XCTAssertEqual(
      tokens.filter { $0.kind == .keyword }.map { (source as NSString).substring(with: $0.range) },
      ["let"])
    XCTAssertTrue(tokens.contains { $0.kind == .comment })
    XCTAssertTrue(tokens.contains { $0.kind == .number })
    XCTAssertEqual(try LanguageService.tokens(in: source, language: .plainText), [])
  }
  func testJSONFormattingValidation() throws {
    let value = try LanguageService.formatJSON("{\"b\":2,\"a\":[true]}")
    XCTAssertTrue(value.contains("\n"))
    XCTAssertThrowsError(try LanguageService.formatJSON("{bad}"))
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: Data(value.utf8)) as? NSDictionary,
      ["b": 2, "a": [true]])
  }
  func testJSONFormattingPreservesNumberLexemesAndDuplicateKeys() throws {
    let source = "{\"n\":1234567890123456789012345678901234567890123456789,\"a\":1,\"a\":2}"
    let formatted = try LanguageService.formatJSON(source)
    XCTAssertEqual(formatted.filter { !$0.isWhitespace }, source)
    XCTAssertTrue(try LanguageService.formatJSON("{\"s\":\"a b\\\" c\"}").contains("a b\\\" c"))
  }
  func testUnterminatedCommentIsOneBoundedToken() throws {
    let source = String(repeating: "/* ", count: 100_000)
    let tokens = try LanguageService.tokens(in: source, language: .swift)
    XCTAssertEqual(tokens.count, 1)
    XCTAssertEqual(tokens.first?.range.length, source.utf16.count)
    XCTAssertEqual(tokens.first?.kind, .comment)
  }
  func testJSONCombiningMarkAfterQuotePreservesWhitespace() throws {
    let source = "{\"s\":\"\u{301} a\"}"
    let result = try LanguageService.formatJSON(source)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String])
    XCTAssertEqual(Data(try XCTUnwrap(object["s"]).utf8), Data("\u{301} a".utf8))
  }
  func testJSONIndentationCannotAmplifyBeyondOutputBudget() {
    let source =
      String(repeating: "[", count: 400)
      + Array(repeating: "0", count: 10_000).joined(separator: ",")
      + String(repeating: "]", count: 400)
    XCTAssertThrowsError(try LanguageService.formatJSON(source))
  }
}
