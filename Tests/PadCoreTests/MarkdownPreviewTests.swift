import XCTest

@testable import PadCore

final class MarkdownPreviewTests: XCTestCase {
  func testBlockAndInlineFormatting() throws {
    let blocks = try MarkdownPreview.parse(
      "# Heading\n- **bold** and *italic* with `code`\n```swift\nlet x = 1\n```")
    XCTAssertEqual(blocks.map(\.kind), [.heading(1), .list, .code])
    XCTAssertEqual(blocks[0].runs.map(\.text).joined(), "Heading")
    XCTAssertTrue(blocks[1].runs.contains { $0.text == "bold" && $0.bold })
    XCTAssertTrue(blocks[1].runs.contains { $0.text == "italic" && $0.italic })
    XCTAssertTrue(blocks[1].runs.contains { $0.text == "code" && $0.code })
    XCTAssertEqual(blocks[2].runs.map(\.text).joined(), "let x = 1")
  }
  func testUnsafeMarkupStaysLiteralAndUnicodeExact() throws {
    let lines = [
      "<script>alert(1)</script>", "![alt](https://invalid.test/pixel)",
      "[link](file:///synthetic)", "e\u{301}👩🏽‍💻אב",
    ]
    let blocks = try MarkdownPreview.parse(lines.joined(separator: "\r\n"))
    XCTAssertEqual(blocks.count, lines.count)
    for (block, line) in zip(blocks, lines) {
      XCTAssertTrue(block.runs.map(\.text).joined().utf16.elementsEqual(line.utf16))
    }
  }
  func testBoundsAndCancellation() throws {
    XCTAssertThrowsError(try MarkdownPreview.parse(String(repeating: "x", count: 2_000_001)))
    XCTAssertThrowsError(try MarkdownPreview.parse(String(repeating: "\n", count: 20_001)))
    XCTAssertThrowsError(try MarkdownPreview.parse("# title", isCancelled: { true }))
    let expanding = String(
      repeating: "- " + String(repeating: "x", count: 97) + "\n", count: 19_900)
    XCTAssertLessThan(expanding.utf8.count, 2_000_000)
    XCTAssertThrowsError(try MarkdownPreview.parse(expanding))
    let excessiveRuns = String(repeating: String(repeating: "*a* ", count: 3_000) + "\n", count: 20)
    XCTAssertThrowsError(try MarkdownPreview.parse(excessiveRuns))
    var checks = 0
    XCTAssertThrowsError(
      try MarkdownPreview.parse(
        "one\ntwo\nthree",
        isCancelled: {
          checks += 1
          return checks > 3
        }))
    let long = String(repeating: "*", count: 20_000)
    XCTAssertEqual(try MarkdownPreview.parse(long)[0].runs.map(\.text).joined(), long)
  }
}
