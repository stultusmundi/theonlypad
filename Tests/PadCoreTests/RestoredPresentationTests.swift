import Foundation
import XCTest

@testable import PadCore

final class RestoredPresentationTests: XCTestCase {
  func testBothPaneRangesResolveAgainstExactMixedEndingText() throws {
    let text = "A😀\r\nB\re\u{301}\nZ"
    let originalUnits = Array(text.utf16)
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        SessionPaneState(
          selection: NSRange(location: 2, length: 0), scrollOrigin: .init(x: 0, y: 120)),
        SessionPaneState(
          selection: NSRange(location: 2, length: 4), scrollOrigin: .init(x: 12, y: 420)),
      ], focusedPaneIndex: 1)
    let state = try RestoredPresentationState.resolve(
      presentation, bookmarks: [0, 4, 5, 7, 10, 11, 90], in: text)
    XCTAssertEqual(
      state.presentation.panes.map(\.selection),
      [NSRange(location: 1, length: 0), NSRange(location: 1, length: 5)])
    XCTAssertEqual(
      state.presentation.panes.map(\.scrollOrigin), presentation.panes.map(\.scrollOrigin))
    XCTAssertEqual(state.presentation.axis, .stacked)
    XCTAssertEqual(state.presentation.focusedPaneIndex, 1)
    XCTAssertEqual(state.adjustedPaneIndices, [0, 1])
    XCTAssertEqual(state.bookmarks.offsets, [0, 5, 7, 10])
    XCTAssertEqual(state.invalidBookmarks, [4, 11, 90])
    XCTAssertEqual(state.focusedViewState.selection, NSRange(location: 1, length: 5))
    XCTAssertTrue(state.focusedViewState.selectionAdjusted)
    XCTAssertEqual(state.focusedViewState.bookmarks, state.bookmarks)
    XCTAssertEqual(state.focusedViewState.invalidBookmarks, state.invalidBookmarks)
    XCTAssertEqual(Array(text.utf16), originalUnits)
  }
  func testFocusedCompatibilityReportsOnlyItsOwnAdjustment() throws {
    let ranges = [NSRange(location: 0, length: 2), NSRange(location: 1, length: 0)]
    for focus in [0, 1] {
      let input = SessionPresentation(
        axis: .sideBySide,
        panes: ranges.map { .init(selection: $0, scrollOrigin: .init(x: 4, y: 9)) },
        focusedPaneIndex: focus)
      let result = try RestoredPresentationState.resolve(input, bookmarks: [0, 3], in: "😀\nxyz")
      XCTAssertEqual(result.adjustedPaneIndices, [1])
      XCTAssertEqual(result.focusedViewState.selectionAdjusted, focus == 1)
      XCTAssertEqual(
        result.focusedViewState,
        try RestoredViewState.resolve(selection: ranges[focus], bookmarks: [0, 3], in: "😀\nxyz"))
    }
  }
  func testShortEmptyAndTerminalNewlineSourcesClampEveryPane() throws {
    for text in ["", "x\r\n", "😀"] {
      let input = SessionPresentation(
        axis: .stacked,
        panes: [
          .init(
            selection: NSRange(location: 100_000_000, length: 0),
            scrollOrigin: .init(x: 1_000_000_000, y: 0)),
          .init(
            selection: NSRange(location: 0, length: 100_000_000),
            scrollOrigin: .init(x: 0, y: 1_000_000_000)),
        ], focusedPaneIndex: 1)
      let result = try RestoredPresentationState.resolve(input, bookmarks: [0], in: text)
      XCTAssertEqual(
        result.presentation.panes.map(\.selection),
        [
          NSRange(location: text.utf16.count, length: 0),
          NSRange(location: 0, length: text.utf16.count),
        ])
      XCTAssertEqual(result.presentation.panes.map(\.scrollOrigin), input.panes.map(\.scrollOrigin))
      XCTAssertEqual(result.adjustedPaneIndices, [0, 1])
      XCTAssertEqual(result.bookmarks.offsets, [0])
    }
    let eof = try RestoredPresentationState.resolve(
      .single(selection: NSRange(location: 3, length: 0)), bookmarks: [0, 3], in: "x\r\n")
    XCTAssertEqual(eof.bookmarks.offsets, [0, 3])
    XCTAssertTrue(eof.adjustedPaneIndices.isEmpty)
  }
  func testInvalidDirectPresentationsThrowBeforeFocusedAccess() throws {
    let valid = SessionPaneState(
      selection: NSRange(location: 0, length: 0), scrollOrigin: .init(x: 0, y: 0))
    var inputs = [
      SessionPresentation(axis: .stacked, panes: [], focusedPaneIndex: 0),
      SessionPresentation(axis: .stacked, panes: [valid, valid, valid], focusedPaneIndex: 0),
    ]
    for focus in [-1, 1, Int.max] {
      inputs.append(.init(axis: .sideBySide, panes: [valid], focusedPaneIndex: focus))
    }
    for range in [
      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
      NSRange(location: NSNotFound, length: 1), NSRange(location: 100_000_000, length: 1),
    ] {
      inputs.append(
        .init(
          axis: .sideBySide,
          panes: [valid, .init(selection: range, scrollOrigin: .init(x: 0, y: 0))],
          focusedPaneIndex: 0))
    }
    for coordinate in [-1.0, .infinity, -.infinity, .nan, 1_000_000_001] {
      for origin in [
        SessionScrollOrigin(x: coordinate, y: 0), SessionScrollOrigin(x: 0, y: coordinate),
      ] {
        inputs.append(
          .init(
            axis: .sideBySide, panes: [.init(selection: valid.selection, scrollOrigin: origin)],
            focusedPaneIndex: 0))
      }
    }
    for input in inputs {
      XCTAssertThrowsError(try RestoredPresentationState.resolve(input, bookmarks: [], in: "")) {
        error in
        guard case SessionStoreError.invalidMetadata = error else {
          return XCTFail("Expected structural metadata rejection")
        }
      }
    }
  }
  func testInvalidBookmarkMetadataIsRejectedForWholeDocument() throws {
    for marks in [
      [-1], [0, 0], [2, 1], [100_000_001], Array(0...DocumentBookmarks.maximumBookmarks),
    ] {
      XCTAssertThrowsError(
        try RestoredPresentationState.resolve(
          .single(selection: NSRange(location: 0, length: 0)), bookmarks: marks, in: "text"))
    }
  }
  func testRangeResolutionMatchesLegacyAcrossScalarBoundaries() throws {
    let text = "😀e\u{301}\r\n🐱\n"
    let units = Array(text.utf16)
    for start in 0...units.count {
      for end in start...units.count {
        let input = NSRange(location: start, length: end - start)
        let state = try RestoredPresentationState.resolve(
          .single(selection: input), bookmarks: [0], in: text)
        XCTAssertEqual(
          state.focusedViewState,
          try RestoredViewState.resolve(selection: input, bookmarks: [0], in: text))
        let range = state.focusedViewState.selection
        func splits(_ position: Int) -> Bool {
          position > 0 && position < units.count && (0xD800...0xDBFF).contains(units[position - 1])
            && (0xDC00...0xDFFF).contains(units[position])
        }
        XCTAssertFalse(splits(range.location))
        XCTAssertFalse(splits(range.location + range.length))
      }
    }
    XCTAssertEqual(Array(text.utf16), units)
  }
  func testLargeNativeUTF16TextDoesNotRegressToUTF8ReferenceLimit() throws {
    let text = String(repeating: "€", count: 33_333_334)
    XCTAssertGreaterThan(text.utf8.count, DocumentBookmarks.maximumTextBytes)
    let input = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: NSRange(location: 0, length: 0), scrollOrigin: .init(x: 0, y: 0)),
        .init(selection: NSRange(location: 33_333_334, length: 0), scrollOrigin: .init(x: 0, y: 1)),
      ], focusedPaneIndex: 1)
    for marks in [[], [0]] {
      let result = try RestoredPresentationState.resolve(input, bookmarks: marks, in: text)
      XCTAssertEqual(result.presentation, input)
      XCTAssertEqual(result.bookmarks.offsets, marks)
      XCTAssertTrue(result.adjustedPaneIndices.isEmpty)
    }
  }
  func testOversizedNativeSourceIsRejected() throws {
    let text = String(repeating: "a", count: DocumentBookmarks.maximumNativeUTF16 + 1)
    XCTAssertThrowsError(
      try RestoredPresentationState.resolve(
        .single(selection: NSRange(location: 0, length: 0)), bookmarks: [], in: text)
    ) { error in
      XCTAssertEqual(error as? DocumentBookmarkError, .nativeTextLimit)
    }
  }
}
