import XCTest

@testable import PadCore

final class LanguageEditingTests: XCTestCase {
  func testConfigurationsDoNotInventUnsupportedComments() throws {
    XCTAssertEqual(LanguageConfiguration(language: .swift).lineComment, "//")
    XCTAssertEqual(LanguageConfiguration(language: .python).lineComment, "#")
    XCTAssertNil(LanguageConfiguration(language: .python).blockComment)
    XCTAssertNil(LanguageConfiguration(language: .css).lineComment)
    XCTAssertEqual(LanguageConfiguration(language: .go).indentation, "\t")
    for language in [DocumentLanguage.json, .plainText] {
      XCTAssertThrowsError(
        try LanguageEditing.toggleLineComment(
          text: "x", selection: NSRange(location: 0, length: 1), language: language))
      XCTAssertThrowsError(
        try LanguageEditing.toggleBlockComment(
          text: "x", selection: NSRange(location: 0, length: 1), language: language))
    }
  }
  func testLineSelectionEndpointMixedEndingsAndExactInverse() throws {
    let original = "  e\u{301}😀\r\n\tx\ry\n"
    let selected = NSRange(location: 1, length: 7)
    let result = try LanguageEditing.toggleLineComment(
      text: original, selection: selected, language: .swift)
    XCTAssertEqual(Data(result.text.utf8), Data("  // e\u{301}😀\r\n\tx\ry\n".utf8))
    let inverse = try LanguageEditing.toggleLineComment(
      text: result.text, selection: result.selection, language: .swift)
    XCTAssertEqual(Data(inverse.text.utf8), Data(original.utf8))
  }
  func testAllSelectedLinesToggleAndCaretMappings() throws {
    let text = "  a\r\n\tb\rc"
    let result = try LanguageEditing.toggleLineComment(
      text: text, selection: NSRange(location: 0, length: text.utf16.count), language: .python)
    XCTAssertEqual(result.text, "  # a\r\n\t# b\r# c")
    XCTAssertEqual(
      try LanguageEditing.toggleLineComment(
        text: result.text, selection: result.selection, language: .python
      ).text, text)
    let empty = try LanguageEditing.toggleLineComment(
      text: "a\r\n", selection: NSRange(location: 3, length: 0), language: .python)
    XCTAssertEqual(empty.text, "a\r\n# ")
    XCTAssertEqual(empty.selection, NSRange(location: 5, length: 0))
    XCTAssertEqual(
      try LanguageEditing.toggleLineComment(
        text: empty.text, selection: empty.selection, language: .python
      ).text, "a\r\n")
    let indentation = try LanguageEditing.toggleLineComment(
      text: "  a", selection: NSRange(location: 1, length: 0), language: .swift)
    XCTAssertEqual(indentation.selection.location, 1)
  }
  func testBlockSelectionUnicodeEmptyAndInverse() throws {
    let text = "xe\u{301}👩🏽‍💻y"
    let range = NSRange(location: 1, length: text.utf16.count - 2)
    let comment = try LanguageEditing.toggleBlockComment(
      text: text, selection: range, language: .css)
    XCTAssertTrue(comment.text.contains("/*e\u{301}👩🏽‍💻*/"))
    let inverse = try LanguageEditing.toggleBlockComment(
      text: comment.text, selection: comment.selection, language: .css)
    XCTAssertEqual(Data(inverse.text.utf8), Data(text.utf8))
    XCTAssertEqual(inverse.selection, range)
    let empty = try LanguageEditing.toggleBlockComment(
      text: "", selection: NSRange(location: 0, length: 0), language: .html)
    XCTAssertEqual(empty.text, "<!---->")
    XCTAssertEqual(
      try LanguageEditing.toggleBlockComment(
        text: empty.text, selection: empty.selection, language: .html
      ).text, "")
  }
  func testUnsafeCommentsAndInvalidSelectionsReject() throws {
    for content in ["a--b", "-->tail", "<!--nested"] {
      XCTAssertThrowsError(
        try LanguageEditing.toggleBlockComment(
          text: content, selection: NSRange(location: 0, length: content.utf16.count),
          language: .xml))
    }
    for content in ["a*/b", "a/*b"] {
      XCTAssertThrowsError(
        try LanguageEditing.toggleBlockComment(
          text: content, selection: NSRange(location: 0, length: content.utf16.count), language: .c)
      )
    }
    for range in [
      NSRange(location: 1, length: 0), NSRange(location: 0, length: 1),
      NSRange(location: Int.max, length: Int.max),
    ] {
      XCTAssertThrowsError(
        try LanguageEditing.toggleLineComment(text: "😀", selection: range, language: .swift))
      XCTAssertThrowsError(
        try LanguageEditing.toggleBlockComment(text: "😀", selection: range, language: .swift))
    }
    XCTAssertThrowsError(
      try LanguageEditing.toggleLineComment(
        text: "x", selection: NSRange(location: 0, length: 0), language: .swift,
        isCancelled: { true }))
  }
  func testLimitsAndCancelledBlock() throws {
    let huge = String(repeating: "x", count: 2_000_000)
    XCTAssertThrowsError(
      try LanguageEditing.toggleLineComment(
        text: huge, selection: NSRange(location: 0, length: 0), language: .swift))
    XCTAssertThrowsError(
      try LanguageEditing.toggleBlockComment(
        text: huge, selection: NSRange(location: 0, length: 0), language: .swift))
    let tooMany = String(repeating: "\r\n", count: 20_000)
    XCTAssertThrowsError(
      try LanguageEditing.toggleLineComment(
        text: tooMany, selection: NSRange(location: 0, length: 0), language: .swift))
    XCTAssertThrowsError(
      try LanguageEditing.toggleBlockComment(
        text: tooMany, selection: NSRange(location: 0, length: 0), language: .swift))
    XCTAssertThrowsError(
      try LanguageEditing.toggleBlockComment(
        text: "", selection: NSRange(location: 0, length: 0), language: .python))
    XCTAssertThrowsError(
      try LanguageEditing.toggleBlockComment(
        text: "x", selection: NSRange(location: 0, length: 1), language: .swift,
        isCancelled: { true }))
    XCTAssertThrowsError(
      try LanguageEditing.toggleBlockComment(
        text: "ends-", selection: NSRange(location: 0, length: 5), language: .xml))
  }
}
