import Foundation
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerUTF8AccumulatorTests: XCTestCase {
  func testASCIIChunksConcatenateInInputOrder() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 5)
    try value.appendUTF8(Data([0x61, 0x62]))
    try value.appendUTF8(Data([0x63, 0x64, 0x65]))
    XCTAssertEqual(try value.finish(), "abcde")
  }

  func testThreeByteBMPScalarsUseUTF16LengthRatherThanByteLength() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    try value.appendUTF8(Data([0xE6, 0xBC, 0xA2, 0xE5, 0xAD, 0x97]))
    XCTAssertEqual(Array(try value.finish().utf16), [0x6F22, 0x5B57])
  }

  func testSupplementaryScalarConsumesTwoUTF16Units() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    try value.appendUTF8(Data([0xF0, 0x9F, 0x98, 0x80]))
    XCTAssertEqual(Array(try value.finish().utf16), [0xD83D, 0xDE00])
  }

  func testDecomposedAccentIsNotNormalized() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    try value.appendUTF8(Data([0x65]))
    try value.appendUTF8(Data([0xCC, 0x81]))
    XCTAssertEqual(Array(try value.finish().utf16), [0x0065, 0x0301])
  }

  func testInitialAndInteriorFEFFAreTextNotByteOrderMarkers() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 4)
    try value.appendUTF8(Data([0xEF, 0xBB, 0xBF, 0x41]))
    try value.appendUTF8(Data([0xEF, 0xBB, 0xBF, 0x42]))
    XCTAssertEqual(Array(try value.finish().utf16), [0xFEFF, 0x0041, 0xFEFF, 0x0042])
  }

  func testNULAndMixedLineEndingsRemainExact() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 9)
    try value.appendUTF8(Data([0x41, 0x00, 0x42, 0x0D]))
    try value.appendUTF8(Data([0x0A, 0x43, 0x0D, 0x44, 0x0A]))
    XCTAssertEqual(
      Array(try value.finish().utf16),
      [0x0041, 0x0000, 0x0042, 0x000D, 0x000A, 0x0043, 0x000D, 0x0044, 0x000A])
  }

  func testZeroLengthDocumentAcceptsEmptyAppendsAndFinishesEmpty() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 0)
    try value.appendUTF8(Data())
    try value.appendUTF8(Data())
    XCTAssertEqual(try value.finish(), "")
  }

  func testEmptyAppendDoesNotResetPreviouslyReceivedText() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    try value.appendUTF8(Data())
    try value.appendUTF8(Data([0x41]))
    try value.appendUTF8(Data())
    try value.appendUTF8(Data([0x42]))
    try value.appendUTF8(Data())
    XCTAssertEqual(try value.finish(), "AB")
  }

  func testInvalidDeclarationsRejectWithoutArithmeticOverflow() {
    for length in [-1, 100_000_001, Int.max, Int.min] {
      assertError(.invalidDeclaredLength) {
        _ = try SearchWorkerUTF8Accumulator(declaredUTF16: length)
      }
    }
  }

  func testMalformedUTF8IsNotRepairedAndPoisonsReceivedPrefix() throws {
    let malformed: [[UInt8]] = [
      [0x80],  // Lone continuation.
      [0xFF],  // Invalid leading byte.
      [0xC0, 0x80],  // Overlong NUL.
      [0xE0, 0x80, 0x80],  // Overlong three-byte sequence.
      [0xF0, 0x80, 0x80, 0x80],  // Overlong four-byte sequence.
      [0xED, 0xA0, 0x80],  // Encoded high surrogate.
      [0xED, 0xBF, 0xBF],  // Encoded low surrogate.
      [0xF4, 0x90, 0x80, 0x80],  // Scalar above U+10FFFF.
      [0xC2], [0xE2, 0x82], [0xF0, 0x9F, 0x98],  // Truncated scalar lengths.
      [0xE2, 0x28, 0xA1],  // Non-continuation inside a scalar.
    ]
    for bytes in malformed {
      let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 4)
      try value.appendUTF8(Data([0x41]))
      assertError(.invalidChunk) { try value.appendUTF8(Data(bytes)) }
      assertError(.invalidState) { try value.appendUTF8(Data([0x42, 0x43, 0x44])) }
      assertError(.invalidState) { try value.appendUTF8(Data()) }
      assertError(.invalidState) { _ = try value.finish() }
    }
  }

  func testDirectSplitScalarRejectsInsteadOfIncrementallyJoiningBytes() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    assertError(.invalidChunk) { try value.appendUTF8(Data([0xF0, 0x9F])) }
    assertError(.invalidState) { try value.appendUTF8(Data([0x98, 0x80])) }
    assertError(.invalidState) { _ = try value.finish() }
  }

  func testExact65536ByteChunkIsAccepted() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 65_536)
    try value.appendUTF8(Data(repeating: 0x41, count: 65_536))
    XCTAssertEqual(try value.finish(), String(repeating: "A", count: 65_536))
  }

  func test65537ByteChunkRejectsEvenWhenDeclarationAllowsItAndPoisons() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 65_537)
    assertError(.invalidChunk) {
      try value.appendUTF8(Data(repeating: 0x41, count: 65_537))
    }
    assertError(.invalidState) { try value.appendUTF8(Data([0x42])) }
    assertError(.invalidState) { _ = try value.finish() }
  }

  func testSupplementaryScalarCannotOverrunDeclaredUTF16Count() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 1)
    assertError(.inputExceeded) {
      try value.appendUTF8(Data([0xF0, 0x9F, 0x98, 0x80]))
    }
    assertError(.invalidState) { try value.appendUTF8(Data([0x41])) }
    assertError(.invalidState) { _ = try value.finish() }
  }

  func testAggregateChunkCountCannotExceedDeclarationOrReturnCompletedPrefix() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    try value.appendUTF8(Data([0x41]))
    try value.appendUTF8(Data([0x42]))
    assertError(.inputExceeded) { try value.appendUTF8(Data([0x43])) }
    assertError(.invalidState) { _ = try value.finish() }
  }

  func testEarlyFinishReportsLengthMismatchAndCannotResume() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 2)
    try value.appendUTF8(Data([0x41]))
    assertError(.lengthMismatch) { _ = try value.finish() }
    assertError(.invalidState) { try value.appendUTF8(Data([0x42])) }
    assertError(.invalidState) { _ = try value.finish() }
  }

  func testFinishCannotReturnTheSameRequestTwice() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 1)
    try value.appendUTF8(Data([0x41]))
    let result = try value.finish()
    assertError(.invalidState) { _ = try value.finish() }
    XCTAssertEqual(result, "A")
  }

  func testFinishedObjectCannotBeReusedButIndependentRequestStillWorks() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 1)
    try value.appendUTF8(Data([0x41]))
    let result = try value.finish()
    assertError(.invalidState) { try value.appendUTF8(Data()) }
    assertError(.invalidState) { try value.appendUTF8(Data([0x42])) }
    assertError(.invalidState) { _ = try value.finish() }
    let next = try SearchWorkerUTF8Accumulator(declaredUTF16: 1)
    try next.appendUTF8(Data([0x42]))
    XCTAssertEqual(try next.finish(), "B")
    XCTAssertEqual(result, "A")
  }

  func testDeclaredCeilingAcceptsTinyInputThenReportsPrematureFinish() throws {
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 100_000_000)
    try value.appendUTF8(Data([0x41]))
    assertError(.lengthMismatch) { _ = try value.finish() }
    assertError(.invalidState) { _ = try value.finish() }
  }

  func testNonzeroIndexedDataSliceReadsOnlyItsActualScalarAlignedBytes() throws {
    let envelope = Data([0xFF, 0x61, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, 0xFF])
    let bytes = envelope[1..<9]
    XCTAssertGreaterThan(bytes.startIndex, 0, "fixture preserves a nonzero Data index")
    let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 4)
    try value.appendUTF8(bytes)
    XCTAssertEqual(Array(try value.finish().utf16), [0x0061, 0x20AC, 0xD83D, 0xDE00])
  }

  private func assertError(
    _ expected: SearchWorkerTextAccumulatorError, file: StaticString = #filePath,
    line: UInt = #line, _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual($0 as? SearchWorkerTextAccumulatorError, expected, file: file, line: line)
    }
  }
}
