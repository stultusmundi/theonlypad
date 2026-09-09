import Foundation
import XCTest

@testable import PadCore

final class DocumentOutlineTests: XCTestCase {
  func testSwiftDeclarationsIgnoreNestedCommentsAndRawTripleStrings() throws {
    let source =
      "// func fake() {}\r\npublic struct Café {\n  func e\u{301}cho() {}\r}\n/* outer /* nested */\nfunc hidden() {}\n*/\nlet text = #\"\"\"\nfunc insideString() {}\n\"\"\"#\nactor Worker {}"
    let symbols = try DocumentOutline.symbols(in: source, language: .swift)
    XCTAssertEqual(symbols.map(\.name), ["Café", "e\u{301}cho", "Worker"])
    XCTAssertEqual(symbols.map(\.kind), ["struct", "func", "actor"])
    XCTAssertEqual(symbols.map(\.line), [2, 3, 11])
    for symbol in symbols {
      XCTAssertEqual((source as NSString).substring(with: symbol.range), symbol.name)
    }
  }
  func testPythonTripleQuotesAndAsyncDefinitions() throws {
    let source =
      "# def fake():\nclass Real:\n    async def fetch(self):\n        value = '''text \" quote\ndef hidden():\n'''\ndef done(): pass"
    let symbols = try DocumentOutline.symbols(in: source, language: .python)
    XCTAssertEqual(symbols.map(\.name), ["Real", "fetch", "done"])
    XCTAssertEqual(symbols.map(\.line), [2, 3, 7])
  }
  func testJavaScriptTemplatesAndTypeScriptNamedDeclarations() throws {
    let source =
      "const text = `\nfunction fake() {}\n`;\nexport async function fetch() {}\nexport default class View {}\ninterface Shape {}\ntype Result = number\nenum State {}"
    XCTAssertEqual(
      try DocumentOutline.symbols(in: source, language: .javascript).map(\.name), ["fetch", "View"])
    XCTAssertEqual(
      try DocumentOutline.symbols(in: source, language: .typescript).map(\.name),
      ["fetch", "View", "Shape", "Result", "State"])
  }
  func testMarkdownATXHeadingsExcludeFencesCommentsAndOverindenting() throws {
    let source =
      "# Title\r\n```swift\n# fake\n```\n<!--\n## hidden\n-->\n   ## Two ##\n    # indented\n~~~\n### fake2\n~~~\n###### 六\n####### no"
    let symbols = try DocumentOutline.symbols(in: source, language: .markdown)
    XCTAssertEqual(symbols.map(\.name), ["Title", "Two", "六"])
    XCTAssertEqual(symbols.map(\.kind), ["heading 1", "heading 2", "heading 6"])
    for symbol in symbols {
      XCTAssertEqual((source as NSString).substring(with: symbol.range), symbol.name)
    }
  }
  func testCancellationIsPolledInsideLongMaskedString() throws {
    let text =
      "let value = \"\"\"\n" + String(repeating: "func masked() {}\n", count: 10_000)
      + "\"\"\"\nfunc real() {}"
    var checks = 0
    XCTAssertThrowsError(
      try DocumentOutline.symbols(
        in: text, language: .swift,
        isCancelled: {
          checks += 1
          return checks > 50
        })
    ) { error in
      guard case OutlineError.cancelled = error else { return XCTFail("Expected cancellation") }
    }
    XCTAssertGreaterThan(checks, 50)
  }
  func testUnsupportedCancellationAndBoundsAreExplicit() throws {
    XCTAssertThrowsError(try DocumentOutline.symbols(in: "class A", language: .java))
    XCTAssertThrowsError(
      try DocumentOutline.symbols(in: "func a() {}", language: .swift, isCancelled: { true }))
    XCTAssertThrowsError(
      try DocumentOutline.symbols(in: String(repeating: "x", count: 2_000_001), language: .swift))
    XCTAssertThrowsError(
      try DocumentOutline.symbols(in: String(repeating: "\n", count: 20_000), language: .python))
    XCTAssertThrowsError(
      try DocumentOutline.symbols(
        in: String(repeating: "def a(): pass\n", count: 10_001), language: .python))
    XCTAssertThrowsError(
      try DocumentOutline.symbols(
        in: "class " + String(repeating: "a", count: 513), language: .python))
  }
}
