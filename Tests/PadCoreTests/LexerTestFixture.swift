import Foundation
import XCTest

@testable import PadCore

enum LexerTestFixture {
  static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
  static func definition(
    keywords: [String] = ["let", "print", "café", "cafe\u{301}"],
    line: String? = "#", block: BlockCommentDelimiters? = .init(opening: "(*", closing: "*)"),
    quotes: [LiteralQuoteRule]? = nil, numbers: Bool = true
  ) throws -> LiteralLanguageDefinition {
    let selected: [LiteralQuoteRule]
    if let quotes {
      selected = quotes
    } else {
      selected = [
        try LiteralQuoteRule(
          opening: "\"", closing: "\"", escape: "\\", multiline: false)
      ]
    }
    return try LiteralLanguageDefinition(
      id: id, name: "Original Lexer Fixture", fileExtensions: [], keywords: keywords,
      lineComment: line, blockComment: block, quotes: selected,
      highlightDecimalNumbers: numbers, indentation: .legacy)
  }
}

extension XCTestCase {
  func lexerTokens(
    _ text: String, definition: LiteralLanguageDefinition,
    file: StaticString = #filePath, line: UInt = #line
  ) -> [SyntaxToken]? {
    do { return try CustomLanguageLexer.tokens(in: text, definition: definition) } catch {
      XCTFail("Valid literal input refused: \(error)", file: file, line: line)
      return nil
    }
  }
  func lexerScalarRanges(
    _ tokens: [SyntaxToken], in text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let units = Array(text.utf16)
    var end = 0
    for token in tokens {
      let range = token.range
      XCTAssertGreaterThan(range.length, 0, file: file, line: line)
      XCTAssertGreaterThanOrEqual(range.location, end, file: file, line: line)
      guard range.location >= 0, range.length > 0, range.location <= units.count,
        range.length <= units.count - range.location
      else {
        XCTFail("Token geometry is out of bounds", file: file, line: line)
        continue
      }
      for offset in [range.location, range.location + range.length] {
        if offset < units.count {
          XCTAssertFalse(
            (0xDC00...0xDFFF).contains(units[offset]),
            "Token must never divide a surrogate", file: file, line: line)
        }
      }
      end = range.location + range.length
    }
  }
  func lexerLimit(
    _ operation: () throws -> [SyntaxToken],
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      _ = try operation()
      XCTFail("Bounded limit must refuse, not truncate", file: file, line: line)
    } catch {
      guard case .analysisLimit? = error as? LanguageError else {
        XCTFail("Expected analysisLimit, got \(error)", file: file, line: line)
        return
      }
    }
  }
}
