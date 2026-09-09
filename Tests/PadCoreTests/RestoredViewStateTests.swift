import Foundation
import XCTest

@testable import PadCore

final class RestoredViewStateTests: XCTestCase {
  func testValidSelectionAndMixedEndingBookmarksArePreserved() throws {
    let text = "a\r\nb\rc\n😀"
    let state = try RestoredViewState.resolve(
      selection: NSRange(location: 7, length: 2), bookmarks: [0, 3, 5, 7], in: text)
    XCTAssertEqual(state.selection, NSRange(location: 7, length: 2))
    XCTAssertEqual(state.bookmarks.offsets, [0, 3, 5, 7])
    XCTAssertFalse(state.selectionAdjusted)
    XCTAssertEqual(state.invalidBookmarks, [])
  }

  func testChangedFileClampsSelectionAndReportsInvalidAnchors() throws {
    let state = try RestoredViewState.resolve(
      selection: NSRange(location: 99, length: 40), bookmarks: [0, 2, 3, 4, 99],
      in: "a\r\nb")
    XCTAssertEqual(state.selection, NSRange(location: 4, length: 0))
    XCTAssertEqual(state.bookmarks.offsets, [0, 3])
    XCTAssertEqual(state.invalidBookmarks, [2, 4, 99])
    XCTAssertTrue(state.selectionAdjusted)
  }

  func testSurrogateBoundariesExpandToPreserveWholeScalar() throws {
    let state = try RestoredViewState.resolve(
      selection: NSRange(location: 2, length: 2), bookmarks: [], in: "x😀😀z")
    XCTAssertEqual(state.selection, NSRange(location: 1, length: 4))
    XCTAssertTrue(state.selectionAdjusted)
    let caret = try RestoredViewState.resolve(
      selection: NSRange(location: 2, length: 0), bookmarks: [], in: "x😀z")
    XCTAssertEqual(caret.selection, NSRange(location: 1, length: 0))
  }

  func testEmptyTrailingLineAndInvalidInput() throws {
    let state = try RestoredViewState.resolve(
      selection: NSRange(location: 0, length: 0), bookmarks: [0, 1], in: "\n")
    XCTAssertEqual(state.bookmarks.offsets, [0, 1])
    XCTAssertThrowsError(
      try RestoredViewState.resolve(
        selection: NSRange(location: -1, length: 0), bookmarks: [], in: ""))
    XCTAssertThrowsError(
      try RestoredViewState.resolve(
        selection: NSRange(location: Int.max, length: 1), bookmarks: [], in: ""))
    XCTAssertThrowsError(
      try RestoredViewState.resolve(
        selection: NSRange(location: 0, length: 0), bookmarks: [0, 0], in: ""))
  }
  func testValidLegacyAndRecoveryTextBeyondUTF8ReferenceLimitRestores() throws {
    // 33.3MB of Windows1252 Euro bytes expand beyond100MB UTF8 but fit native UTF16 limits.
    var bytes = Data(repeating: 0x80, count: 33_333_334)
    bytes.insert(10, at: 0)
    let decoded = try DocumentCodec.decode(bytes, encoding: .windows1252)
    XCTAssertGreaterThan(decoded.text.utf8.count, DocumentBookmarks.maximumTextBytes)
    XCTAssertLessThan(decoded.text.utf16.count, DocumentBookmarks.maximumNativeUTF16)
    let snapshot = RecoverySnapshot(
      id: UUID(), text: decoded.text, encoding: .windows1252, hasBOM: false)
    let plan = try SessionRestoration.plan(session: nil, recoveries: [snapshot])
    XCTAssertEqual(plan.windows.count, 1)
    for marks in [[], [0, 1]] {
      let view = try RestoredViewState.resolve(
        selection: NSRange(location: 1, length: 0), bookmarks: marks, in: decoded.text)
      XCTAssertEqual(view.bookmarks.offsets, marks)
      XCTAssertEqual(view.selection, NSRange(location: 1, length: 0))
      XCTAssertFalse(view.selectionAdjusted)
    }
  }

}
