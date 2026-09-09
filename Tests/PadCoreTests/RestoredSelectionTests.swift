import Foundation
import XCTest

@testable import PadCore

private final class CountingString: NSString {
  private var reportedLength = 0
  private var units: [Int: unichar] = [:]
  private(set) var lengthReads = 0
  private(set) var characterReads: [Int] = []
  convenience init(length: Int, units: [Int: unichar] = [:]) {
    self.init()
    reportedLength = length
    self.units = units
  }
  override var length: Int {
    lengthReads += 1
    return reportedLength
  }
  override func character(at index: Int) -> unichar {
    XCTAssertTrue(index >= 0 && index < reportedLength)
    characterReads.append(index)
    return units[index] ?? 65
  }
}

final class RestoredSelectionTests: XCTestCase {
  func testScalarClampingAndEmptyRangePolicy() throws {
    let source = "A😀\r\ne\u{301}Z" as NSString
    let cases: [(NSRange, NSRange)] = [
      (.init(location: 2, length: 0), .init(location: 1, length: 0)),
      (.init(location: 2, length: 1), .init(location: 1, length: 2)),
      (.init(location: 0, length: 2), .init(location: 0, length: 3)),
      (.init(location: 50, length: 3), .init(location: source.length, length: 0)),
      (.init(location: 6, length: 1), .init(location: 6, length: 1)),
      (.init(location: 3, length: 1), .init(location: 3, length: 1)),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(try RestoredSelection.resolve(input, inUTF16: source), expected)
    }
    XCTAssertEqual(source, "A😀\r\ne\u{301}Z")
    XCTAssertEqual(
      try RestoredSelection.resolve(.init(location: 20, length: 3), inUTF16: ""),
      .init(location: 0, length: 0))
  }
  func testHugeReportedSourceNeedsOnlyFourEndpointReads() throws {
    let source = CountingString(
      length: 100_000_000,
      units: [10: 0xD83D, 11: 0xDE00, 89_999_999: 0xD83D, 90_000_000: 0xDE00])
    XCTAssertEqual(
      try RestoredSelection.resolve(.init(location: 11, length: 89_999_989), inUTF16: source),
      .init(location: 10, length: 89_999_991))
    XCTAssertEqual(source.characterReads, [10, 11, 89_999_999, 90_000_000])
    XCTAssertEqual(source.lengthReads, 1)
  }
  func testMalformedRangeRefusesBeforeAnySourceAccess() {
    for range in [
      NSRange(location: -1, length: 0), .init(location: 0, length: -1),
      .init(location: Int.max, length: 1), .init(location: 0, length: Int.max),
      .init(location: 100_000_001, length: 0), .init(location: 100_000_000, length: 1),
    ] {
      let source = CountingString(length: 100_000_000)
      XCTAssertThrowsError(try RestoredSelection.resolve(range, inUTF16: source)) {
        guard case SessionStoreError.invalidMetadata = $0 else {
          return XCTFail("Expected metadata refusal")
        }
      }
      XCTAssertEqual(source.lengthReads, 0)
      XCTAssertTrue(source.characterReads.isEmpty)
    }
  }
  func testSourceLimitRefusesBeforeCharacterAccess() {
    for length in [-1, 100_000_001, Int.max] {
      let source = CountingString(length: length)
      XCTAssertThrowsError(
        try RestoredSelection.resolve(.init(location: 0, length: 0), inUTF16: source)
      ) {
        XCTAssertEqual($0 as? DocumentBookmarkError, .nativeTextLimit)
      }
      XCTAssertEqual(source.lengthReads, 1)
      XCTAssertTrue(source.characterReads.isEmpty)
    }
  }
  func testEOFAndFullRangeHaveNoCharacterReadsAtBoundary() throws {
    let source = CountingString(length: 100_000_000)
    let range = NSRange(location: 0, length: 100_000_000)
    XCTAssertEqual(try RestoredSelection.resolve(range, inUTF16: source), range)
    XCTAssertTrue(source.characterReads.isEmpty)
    let eof = NSRange(location: 100_000_000, length: 0)
    XCTAssertEqual(try RestoredSelection.resolve(eof, inUTF16: source), eof)
    XCTAssertTrue(source.characterReads.isEmpty)
  }
  func testCaretUsesTwoReadsAndDoesNotMutateMutableSource() throws {
    let counted = CountingString(length: 1_000_000, units: [5: 0xD83D, 6: 0xDE00])
    XCTAssertEqual(
      try RestoredSelection.resolve(.init(location: 6, length: 0), inUTF16: counted),
      .init(location: 5, length: 0))
    XCTAssertEqual(counted.characterReads, [5, 6])
    let mutable = NSMutableString(string: "x😀\r\ny")
    let before = String(mutable)
    _ = try RestoredSelection.resolve(.init(location: 2, length: 2), inUTF16: mutable)
    XCTAssertEqual(String(mutable).utf16.elementsEqual(before.utf16), true)
  }
}
