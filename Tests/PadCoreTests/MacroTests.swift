import XCTest

@testable import PadCore

final class MacroTests: XCTestCase {
  func testDeterministicReplayAndRepeat() throws {
    let macro = EditorMacro(
      name: "Clean", commands: [.transform(.trimTrailingWhitespace), .transform(.uppercase)])
    XCTAssertEqual(try MacroPlayer.replay(macro, on: "b  \na\t", repeatCount: 2), "B\nA")
    XCTAssertEqual(
      try JSONDecoder().decode(EditorMacro.self, from: JSONEncoder().encode(macro)), macro)
  }
  func testReplayRejectsUnboundedWorkAndCancellation() {
    let macro = EditorMacro(name: "Upper", commands: [.transform(.uppercase)])
    XCTAssertThrowsError(try MacroPlayer.replay(macro, on: "a", repeatCount: 0))
    XCTAssertThrowsError(try MacroPlayer.replay(macro, on: "a", repeatCount: 10_001))
    XCTAssertThrowsError(try MacroPlayer.replay(macro, on: "a", isCancelled: { true }))
  }
  func testRecordedEditsAreValidatedOnReplay() throws {
    let macro = EditorMacro(name: "Insert", commands: [.replace(location: 1, length: 0, text: "!")])
    XCTAssertEqual(try MacroPlayer.replay(macro, on: "ab"), "a!b")
    XCTAssertThrowsError(try MacroPlayer.replay(macro, on: "😀"))
  }
  func testReplacementLimitSubtractsRemovedText() throws {
    let text = String(repeating: "a", count: 6_000_000)
    let macro = EditorMacro(
      name: "Replace", commands: [.replace(location: 0, length: 6_000_000, text: text)])
    XCTAssertEqual(try MacroPlayer.replay(macro, on: text).utf8.count, 6_000_000)
  }
  func testCancellationIsCheckedAfterTheLastCommand() {
    var checks = 0
    let macro = EditorMacro(name: "Upper", commands: [.transform(.uppercase)])
    XCTAssertThrowsError(
      try MacroPlayer.replay(
        macro, on: "a",
        isCancelled: {
          checks += 1
          return checks >= 2
        }))
  }
}
