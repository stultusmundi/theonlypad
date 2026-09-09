import XCTest

@testable import PadCore

final class EditingTests: XCTestCase {
  func testMultipleEditsUseOriginalUTF16Offsets() throws {
    let result = try TextEdits.apply(
      [
        TextEdit(range: NSRange(location: 0, length: 1), replacement: "AA"),
        TextEdit(range: NSRange(location: 3, length: 1), replacement: "B"),
      ], to: "a😀b")
    XCTAssertEqual(result, "AA😀B")
  }
  func testRejectsOverlapAndSplitSurrogate() {
    XCTAssertThrowsError(
      try TextEdits.apply(
        [TextEdit(range: NSRange(location: 1, length: 1), replacement: "")], to: "😀"))
    XCTAssertThrowsError(
      try TextEdits.apply(
        [
          TextEdit(range: NSRange(location: 0, length: 2), replacement: ""),
          TextEdit(range: NSRange(location: 1, length: 1), replacement: ""),
        ], to: "abc"))
  }
  func testLineTransformsPreserveCRLFAndFinalNewline() {
    XCTAssertEqual(LineTransform.sorted.apply(to: "z\r\na\r\n"), "a\r\nz\r\n")
    XCTAssertEqual(LineTransform.deduplicated.apply(to: "a\na\nb"), "a\nb")
    XCTAssertEqual(LineTransform.trimTrailingWhitespace.apply(to: " a  \r\nb\t"), " a\r\nb")
  }
  func testCommandRegistryRejectsShortcutCollision() throws {
    var registry = CommandRegistry()
    try registry.register(CommandDescriptor(id: "save", title: "Save", shortcut: "cmd+s"))
    XCTAssertThrowsError(
      try registry.register(CommandDescriptor(id: "sort", title: "Sort", shortcut: "cmd+s")))
    XCTAssertEqual(registry.commands.map(\.id), ["save"])
  }
  func testModifierOrderDoesNotBypassCollisionDetection() throws {
    var registry = CommandRegistry()
    try registry.register(.init(id: "one", title: "One", shortcut: "cmd+shift+s"))
    XCTAssertThrowsError(
      try registry.register(.init(id: "two", title: "Two", shortcut: "shift+cmd+s")))
  }
  func testDeduplicationKeepsExactDistinctTextAndSurvivingSeparators() {
    XCTAssertEqual(
      Array(LineTransform.deduplicated.apply(to: "a\r\na\nb\r").utf8), Array("a\r\nb\r".utf8))
    XCTAssertEqual(
      Array(LineTransform.deduplicated.apply(to: "é\ne\u{301}\n").utf8), Array("é\ne\u{301}\n".utf8)
    )
  }
}
