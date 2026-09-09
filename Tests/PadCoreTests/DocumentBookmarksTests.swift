import Foundation
import XCTest

@testable import PadCore

final class DocumentBookmarksTests: XCTestCase {
  func testToggleMixedEndingRangesExportAndFinalEmptyLine() throws {
    let text = "a\r\n😀\rb\n"
    var marks = DocumentBookmarks()
    try marks.toggle(atUTF16Offset: 1, in: text)
    XCTAssertThrowsError(try marks.toggle(atUTF16Offset: 4, in: text))
    XCTAssertEqual(marks.offsets, [0])
  }
  func testRangesAndNavigationRespectLogicalLines() throws {
    let text = "a\r\n😀\rb\n"
    var marks = DocumentBookmarks()
    for offset in [1, 3, 8] { try marks.toggle(atUTF16Offset: offset, in: text) }
    XCTAssertEqual(marks.offsets, [0, 3, 8])
    XCTAssertEqual(
      try marks.ranges(in: text),
      [
        NSRange(location: 0, length: 3), NSRange(location: 3, length: 3),
        NSRange(location: 8, length: 0),
      ])
    XCTAssertEqual(try marks.export(from: text), "a\r\n😀\r")
    XCTAssertEqual(try marks.destination(from: 2, direction: .next, in: text), 3)
    XCTAssertEqual(try marks.destination(from: 3, direction: .previous, in: text), 0)
    XCTAssertEqual(try marks.destination(from: 8, direction: .next, in: text), 0)
    XCTAssertEqual(try marks.destination(from: 0, direction: .previous, in: text), 8)
    try marks.toggle(atUTF16Offset: 5, in: text)
    XCTAssertEqual(marks.offsets, [0, 8])
  }
  func testInsertionFollowsOriginalContentAndPartialEditSurvives() throws {
    let text = "a\nbcd\nend"
    var marks = DocumentBookmarks()
    try marks.toggle(atUTF16Offset: 3, in: text)
    try marks.remap(
      through: TextEdit(range: NSRange(location: 2, length: 0), replacement: "new\r\n"), in: text)
    XCTAssertEqual(marks.offsets, [7])
    let inserted = "a\nnew\r\nbcd\nend"
    try marks.remap(
      through: TextEdit(range: NSRange(location: 7, length: 1), replacement: "B"), in: inserted)
    XCTAssertEqual(marks.offsets, [7])
  }
  func testFullLineDeletionDropsBookmarkAndUndoRestoresSnapshot() throws {
    let text = "a\nb\nc"
    var marks = DocumentBookmarks()
    try marks.toggle(atUTF16Offset: 2, in: text)
    try marks.toggle(atUTF16Offset: 4, in: text)
    let before = marks
    try marks.remap(
      through: TextEdit(range: NSRange(location: 2, length: 2), replacement: ""), in: text)
    XCTAssertEqual(marks.offsets, [2])
    let after = marks
    marks = before  // native undo restores metadata and the matching original text
    XCTAssertEqual(marks.offsets, [2, 4])
    marks = after  // redo restores the recorded post-edit metadata
    XCTAssertEqual(marks.offsets, [2])
  }
  func testJoiningLinesDeduplicatesAndDeletingFinalEmptyLineDropsMark() throws {
    var marks = DocumentBookmarks()
    for offset in [0, 2] { try marks.toggle(atUTF16Offset: offset, in: "a\nb") }
    try marks.remap(
      through: TextEdit(range: NSRange(location: 1, length: 1), replacement: ""), in: "a\nb")
    XCTAssertEqual(marks.offsets, [0])
    var end = DocumentBookmarks()
    try end.toggle(atUTF16Offset: 3, in: "a\r\n")
    try end.remap(
      through: TextEdit(range: NSRange(location: 1, length: 2), replacement: ""), in: "a\r\n")
    XCTAssertEqual(end.offsets, [])
  }
  func testRejectedEditsNeverMutateAndStaleAnchorsFail() throws {
    var marks = DocumentBookmarks()
    try marks.toggle(atUTF16Offset: 0, in: "😀\nx")
    let before = marks
    for range in [NSRange(location: 1, length: 0), NSRange(location: 0, length: Int.max)] {
      XCTAssertThrowsError(
        try marks.remap(through: TextEdit(range: range, replacement: ""), in: "😀\nx"))
      XCTAssertEqual(marks, before)
    }
    try marks.toggle(atUTF16Offset: 3, in: "😀\nx")
    XCTAssertThrowsError(try marks.ranges(in: "abcdef"))
  }
  func testSparseLookupsDoNotCapUnmarkedLineCountAndEmptyNavigation() throws {
    let text = String(repeating: "\n", count: 200_001)
    var marks = DocumentBookmarks()
    XCTAssertNil(try marks.destination(from: 0, direction: .next, in: text))
    try marks.toggle(atUTF16Offset: text.utf16.count, in: text)
    XCTAssertEqual(try marks.ranges(in: text), [NSRange(location: 200_001, length: 0)])
    XCTAssertEqual(try marks.destination(from: 200_001, direction: .next, in: text), 200_001)
  }
  func testExactNoOpReplacementPreservesMarks() throws {
    let text = "a\r\nb"
    var marks = try DocumentBookmarks(offsets: [0, 3], in: text)
    let before = marks
    try marks.remap(
      through: TextEdit(range: NSRange(location: 0, length: text.utf16.count), replacement: text),
      in: text)
    XCTAssertEqual(marks, before)
  }
  func testBoundedBulkConstructionTextAndBookmarkCapacity() throws {
    let text = String(repeating: "\n", count: 10_000)
    var marks = try DocumentBookmarks(offsets: Array(0..<10_000), in: text)
    XCTAssertEqual(try marks.ranges(in: text).count, 10_000)
    let before = marks
    XCTAssertThrowsError(try marks.toggle(atUTF16Offset: 10_000, in: text))
    XCTAssertEqual(marks, before)
    XCTAssertThrowsError(try DocumentBookmarks(offsets: Array(0...10_000), in: text))
    let oversized = String(repeating: "x", count: 100_000_001)
    XCTAssertThrowsError(try DocumentBookmarks(offsets: [], in: oversized))
    XCTAssertThrowsError(
      try marks.remap(
        through: TextEdit(range: NSRange(location: 0, length: 0), replacement: oversized), in: text)
    )
    XCTAssertEqual(marks, before)
    marks.removeAll()
    XCTAssertEqual(marks.offsets, [])
  }

  func testIncrementalMatchesReferenceAcrossMixedUnicodeEdits() throws {
    let fixtures = ["", "a\r\n😀b\n", "é\né", "e\u{301}\r\nx\r", "\n\n"]
    let replacements = ["", "x", "\r", "\n", "\r\n", "😀\n"]
    for text in fixtures {
      let units = Array(text.utf16)
      let boundaries = (0...units.count).filter {
        $0 == units.count || !(0xDC00...0xDFFF).contains(units[$0])
      }
      let starts = boundaries.filter {
        $0 == 0 || units[$0 - 1] == 10
          || (units[$0 - 1] == 13 && ($0 == units.count || units[$0] != 10))
      }
      for anchors in [starts, Array(starts.prefix(1)), Array(starts.suffix(1))] {
        let initial = try DocumentBookmarks(offsets: anchors, in: text)
        for start in boundaries {
          for end in boundaries where end >= start {
            for replacement in replacements {
              let edit = TextEdit(
                range: NSRange(location: start, length: end - start), replacement: replacement)
              var reference = initial
              var incremental = initial
              try reference.remap(through: edit, in: text)
              try incremental.remap(through: edit, inUTF16: text as NSString)
              XCTAssertEqual(
                incremental, reference, "Mismatch at \(edit.range), anchors \(anchors)")
            }
          }
        }
      }
    }
  }
  func testIncrementalRejectsSurrogateAndStaleAnchorsWithoutMutation() throws {
    var marks = try DocumentBookmarks(offsets: [0, 3], in: "😀\nx")
    let original = marks
    XCTAssertThrowsError(
      try marks.remap(
        through: TextEdit(range: NSRange(location: 1, length: 0), replacement: "x"),
        inUTF16: "😀\nx" as NSString))
    XCTAssertThrowsError(
      try marks.remap(
        through: TextEdit(range: NSRange(location: Int.max, length: 1), replacement: "x"),
        inUTF16: "😀\nx" as NSString))
    XCTAssertThrowsError(
      try marks.remap(
        through: TextEdit(range: NSRange(location: 0, length: 0), replacement: "x"),
        inUTF16: "abcd" as NSString))
    XCTAssertEqual(marks, original)
  }

  func testIncrementalRejectsNativeResultCapacityWithoutMutating() throws {
    var marks = try DocumentBookmarks(offsets: [0], in: "a")
    let original = marks
    let native = NSMutableString(
      string: String(repeating: "a", count: DocumentBookmarks.maximumNativeUTF16))
    XCTAssertThrowsError(
      try marks.remap(
        through: TextEdit(range: NSRange(location: 1, length: 0), replacement: "x"), inUTF16: native
      ))
    XCTAssertEqual(marks, original)
    try marks.remap(
      through: TextEdit(range: NSRange(location: 1, length: 1), replacement: "x"), inUTF16: native)
    XCTAssertEqual(marks, original)
    XCTAssertEqual(native.character(at: 1), 97, "Metadata remapping must not mutate native text")
  }

  func testNativeInitializerValidatesMixedEndingsAndScalarOffsets() throws {
    let text: NSString = "a\r\nb\rc\n😀\n"
    XCTAssertEqual(
      try DocumentBookmarks(offsets: [10, 0, 3, 5, 7, 3], inUTF16: text).offsets, [0, 3, 5, 7, 10])
    for offset in [-1, 2, 4, 8, 11] {
      XCTAssertThrowsError(try DocumentBookmarks(offsets: [offset], inUTF16: text))
    }
    XCTAssertEqual(try DocumentBookmarks(offsets: [0], inUTF16: "").offsets, [0])
    XCTAssertThrowsError(
      try DocumentBookmarks(offsets: Array(repeating: 0, count: 10_001), inUTF16: ""))
  }

}
