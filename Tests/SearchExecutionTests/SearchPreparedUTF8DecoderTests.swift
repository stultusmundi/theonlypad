import XCTest

@testable import SearchExecution

final class SearchPreparedUTF8DecoderTests: XCTestCase {
  func testCanonicalScalarClassesAcrossEverySplit() throws {
    let cases: [([UInt8], String, Int)] = [
      ([0x41], "A", 1),
      ([0x7F], "\u{7F}", 1),
      ([0xC2, 0x80], "\u{80}", 1),
      ([0xDF, 0xBF], "\u{7FF}", 1),
      ([0xE0, 0xA0, 0x80], "\u{800}", 1),
      ([0xED, 0x9F, 0xBF], "\u{D7FF}", 1),
      ([0xEE, 0x80, 0x80], "\u{E000}", 1),
      ([0xEF, 0xBF, 0xBF], "\u{FFFF}", 1),
      ([0xF0, 0x90, 0x80, 0x80], "\u{10000}", 2),
      ([0xF4, 0x8F, 0xBF, 0xBF], "\u{10FFFF}", 2),
    ]
    for (bytes, expected, units) in cases {
      for split in 0...bytes.count {
        let decoder = try make(bytes, units: units)
        try consume(Array(bytes[..<split]), into: decoder)
        try consume(Array(bytes[split...]), into: decoder)
        let result = try decoder.finish()
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.inputUTF16, units)
        XCTAssertEqual(Array(result.text.utf8), bytes)
      }
    }
  }

  func testOneByteWindowsPreserveCombiningTextAndMiddleBOM() throws {
    let bytes: [UInt8] = [
      0x41, 0xEF, 0xBB, 0xBF, 0x65, 0xCC, 0x81, 0xF0, 0x9F, 0x98, 0x80,
    ]
    let decoder = try make(bytes, units: 6, window: 1)
    for byte in bytes { try consume([byte], into: decoder) }
    let result = try decoder.finish()
    XCTAssertEqual(result.text, "A\u{FEFF}e\u{301}😀")
    XCTAssertEqual(result.inputUTF16, 6)
    XCTAssertEqual(Array(result.text.utf8), bytes)
  }

  func testInitialBOMIsStrippedAcrossEverySplit() throws {
    let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0x41, 0xF0, 0x9F, 0x98, 0x80]
    for split in 0...bytes.count {
      let decoder = try make(bytes, units: 3)
      try consume(Array(bytes[..<split]), into: decoder)
      try consume(Array(bytes[split...]), into: decoder)
      let result = try decoder.finish()
      XCTAssertEqual(result.text, "A😀")
      XCTAssertEqual(result.inputUTF16, 3)
      XCTAssertEqual(Array(result.text.utf8), [0x41, 0xF0, 0x9F, 0x98, 0x80])
    }
  }

  func testEmptyAndBOMOnlyNeedNoUTF16Capacity() throws {
    let cases: [[UInt8]] = [[], [0xEF, 0xBB, 0xBF]]
    for bytes in cases {
      let decoder = try make(bytes, units: 0, output: 0)
      for byte in bytes { try consume([byte], into: decoder) }
      let result = try decoder.finish()
      XCTAssertEqual(result.text, "")
      XCTAssertEqual(result.inputUTF16, 0)
    }
  }

  func testDivergingInitialBOMPrefixIsReplayedExactlyOnce() throws {
    let cases: [([UInt8], String)] = [
      ([0xEF, 0xB9, 0x80], "\u{FE40}"),
      ([0xEF, 0xBB, 0x80], "\u{FEC0}"),
    ]
    for (bytes, expected) in cases {
      let decoder = try make(bytes, units: 1, window: 1)
      for byte in bytes { try consume([byte], into: decoder) }
      let result = try decoder.finish()
      XCTAssertEqual(result.text, expected)
      XCTAssertEqual(result.inputUTF16, 1)
      XCTAssertEqual(Array(result.text.utf8), bytes)
    }
  }

  func testRejectsMalformedLeadContinuationOverlongSurrogateAndRange() throws {
    let cases: [[UInt8]] = [
      [0x80], [0xBF], [0xC0, 0xAF], [0xC1, 0x81],
      [0xE0, 0x9F, 0x80], [0xED, 0xA0, 0x80],
      [0xF0, 0x8F, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80],
      [0xF5, 0x80, 0x80, 0x80], [0xFE], [0xFF],
      [0xC2, 0x41], [0xE2, 0x82, 0x41], [0xF0, 0x9F, 0x98, 0x41],
    ]
    for bytes in cases {
      let decoder = try make(bytes)
      assertError(.invalidUTF8) { try consume(bytes, into: decoder) }
      assertError(.poisoned) { _ = try decoder.finish() }
    }
  }

  func testExactLengthTruncatedScalarAndBOMPrefixesFailAtFinish() throws {
    let cases: [[UInt8]] = [
      [0xC2], [0xE2], [0xE2, 0x82], [0xF0], [0xF0, 0x9F],
      [0xF0, 0x9F, 0x98], [0xEF], [0xEF, 0xBB],
    ]
    for bytes in cases {
      let decoder = try make(bytes)
      try consume(bytes, into: decoder)
      assertError(.invalidUTF8) { _ = try decoder.finish() }
      assertError(.poisoned) { _ = try decoder.finish() }
    }
  }

  func testNULAndUTF16BOMHaveNoEncodingFallback() throws {
    let nullCases: [[UInt8]] = [[0], [0x41, 0, 0x42], [0xEF, 0xBB, 0xBF, 0]]
    for bytes in nullCases {
      let decoder = try make(bytes)
      assertError(.binaryInput) { try consume(bytes, into: decoder) }
      assertError(.poisoned) { _ = try decoder.finish() }
    }
    let utf16Cases: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]
    for bytes in utf16Cases {
      let decoder = try make(bytes)
      assertError(.invalidUTF8) { try consume(bytes, into: decoder) }
    }
  }

  func testConstructorRefusesInvalidDimensionsBeforeAnyLargeBuilder() throws {
    let cases: [(Int, Int, Int, Int)] = [
      (-1, 0, 1, 0), (10_000_001, 0, 1, 0),
      (0, -1, 1, 0), (0, 10_000_001, 1, 0),
      (0, 0, 0, 0), (0, 0, 65_537, 0),
      (1, 1, 1, -1), (1, 1, 1, 4), (1, 1, 1, Int.max),
      (Int.max, 0, 1, 0), (0, Int.max, 1, 0),
    ]
    for (bytes, units, window, output) in cases {
      assertError(.invalidBounds) {
        _ = try SearchPreparedUTF8Decoder(
          expectedInputBytes: bytes, maxInputUTF16: units,
          maxWindowBytes: window, maxOutputUTF8Bytes: output)
      }
    }
    // Exact byte/window maxima with unit capacity0 exercise metadata only.
    let maximumMetadata = try SearchPreparedUTF8Decoder(
      expectedInputBytes: 10_000_000, maxInputUTF16: 0,
      maxWindowBytes: 65_536, maxOutputUTF8Bytes: 0)
    assertError(.lengthMismatch) { _ = try maximumMetadata.finish() }
  }

  func testWindowAndTotalByteCeilingsHaveSeparateRefusals() throws {
    let window = try make([0x41, 0x42], window: 1)
    assertError(.windowLimit) { try consume([0x41, 0x42], into: window) }
    assertError(.poisoned) { _ = try window.finish() }

    let total = try make([0x41], window: 2)
    assertError(.inputByteLimit) { try consume([0x41, 0x42], into: total) }

    let late = try make([0x41], window: 1)
    try consume([0x41], into: late)
    assertError(.inputByteLimit) { try consume([0x42], into: late) }
    assertError(.poisoned) { _ = try late.finish() }
  }

  func testUTF16LimitRefusesSupplementaryScalarAndExactCapacitySucceeds() throws {
    let bytes: [UInt8] = [0x41, 0xF0, 0x9F, 0x98, 0x80]
    let short = try make(bytes, units: 2)
    assertError(.inputUnitLimit) { try consume(bytes, into: short) }
    assertError(.poisoned) { _ = try short.finish() }

    let exact = try make(bytes, units: 3)
    try consume(bytes, into: exact)
    let result = try exact.finish()
    XCTAssertEqual(result.text, "A😀")
    XCTAssertEqual(result.inputUTF16, 3)

    let zero = try make([0x41], units: 0, output: 0)
    assertError(.inputUnitLimit) { try consume([0x41], into: zero) }
  }

  func testOutputByteLimitRefusesBeforeStringAndExactBoundarySucceeds() throws {
    let bytes: [UInt8] = [0xE2, 0x82, 0xAC]
    let short = try make(bytes, units: 1, output: 2)
    try consume(bytes, into: short)
    assertError(.outputLimit) { _ = try short.finish() }
    assertError(.poisoned) { _ = try short.finish() }

    let exact = try make(bytes, units: 1, output: 3)
    try consume(bytes, into: exact)
    let result = try exact.finish()
    XCTAssertEqual(result.text, "€")
    XCTAssertEqual(result.inputUTF16, 1)
    XCTAssertEqual(Array(result.text.utf8), bytes)
  }

  func testShortDeclaredLengthPrecedesIncompleteScalarAtFinish() throws {
    let decoder = try SearchPreparedUTF8Decoder(
      expectedInputBytes: 2, maxInputUTF16: 2,
      maxWindowBytes: 2, maxOutputUTF8Bytes: 6)
    try consume([0xE2], into: decoder)
    assertError(.lengthMismatch) { _ = try decoder.finish() }
    assertError(.poisoned) { _ = try decoder.finish() }
  }

  func testFinishedAndFailedStatesCannotRestartOrReturnCachedResult() throws {
    let finished = try make([0x41])
    try consume([], into: finished)
    try consume([0x41], into: finished)
    let result = try finished.finish()
    XCTAssertEqual(result.text, "A")
    XCTAssertEqual(result.inputUTF16, 1)
    assertError(.invalidPhase) { _ = try finished.finish() }
    assertError(.invalidPhase) { try consume([], into: finished) }
    assertError(.invalidPhase) { _ = try finished.finish() }

    let failed = try make([0xFF])
    assertError(.invalidUTF8) { try consume([0xFF], into: failed) }
    assertError(.poisoned) { try consume([0x41], into: failed) }
    assertError(.poisoned) { _ = try failed.finish() }
  }

  func testBuilderSupplementaryRefusalLeavesUnusedTailUntouched() throws {
    let builder = try SearchPreparedUTF16Builder(capacity: 2)
    try builder.append(scalar: 0x41)
    assertError(.inputUnitLimit) { try builder.append(scalar: 0x1F600) }
    var storage: [UInt16] = []
    var count = -1
    try builder.withStorage { units, committed in
      storage = Array(units)
      count = committed
    }
    XCTAssertEqual(count, 1)
    XCTAssertEqual(storage, [0x41, 0])
    // A high surrogate written into the unused tail would be observable above.
    try builder.append(scalar: 0x42)
    try builder.withStorage { units, committed in
      XCTAssertEqual(committed, 2)
      XCTAssertEqual(Array(units), [0x41, 0x42])
    }
  }

  func testBuilderExactFitInvalidScalarAndBoundsPreserveStorage() throws {
    let exact = try SearchPreparedUTF16Builder(capacity: 3)
    try exact.append(scalar: 0x41)
    try exact.append(scalar: 0x1F600)
    try exact.withStorage { units, committed in
      XCTAssertEqual(committed, 3)
      XCTAssertEqual(Array(units), [0x41, 0xD83D, 0xDE00])
    }
    assertError(.inputUnitLimit) { try exact.append(scalar: 0x42) }

    let invalid = try SearchPreparedUTF16Builder(capacity: 2)
    try invalid.append(scalar: 0x41)
    let invalidScalars: [UInt32] = [0xD800, 0xDFFF, 0x110000]
    for scalar in invalidScalars {
      assertError(.invalidScalar) { try invalid.append(scalar: scalar) }
      try invalid.withStorage { units, committed in
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(Array(units), [0x41, 0])
      }
    }
    assertError(.invalidBounds) { _ = try SearchPreparedUTF16Builder(capacity: -1) }
    assertError(.invalidBounds) {
      _ = try SearchPreparedUTF16Builder(capacity: 10_000_001)
    }
    let zero = try SearchPreparedUTF16Builder(capacity: 0)
    assertError(.inputUnitLimit) { try zero.append(scalar: 0x41) }
    try zero.withStorage { units, committed in
      XCTAssertTrue(units.isEmpty)
      XCTAssertEqual(committed, 0)
    }
  }

  func testBuilderMutationIsRefusedUntilReadOnlyBorrowActuallyReturns() throws {
    let builder = try SearchPreparedUTF16Builder(capacity: 2)
    try builder.append(scalar: 0x41)
    try builder.withStorage { units, committed in
      assertError(.invalidPhase) { try builder.append(scalar: 0x42) }
      XCTAssertEqual(committed, 1)
      XCTAssertEqual(Array(units), [0x41, 0])
    }
    assertError(.invalidScalar) {
      try builder.withStorage { _, _ in throw SearchPreparedUTF8Error.invalidScalar }
    }
    try builder.append(scalar: 0x42)
    try builder.withStorage { units, committed in
      XCTAssertEqual(committed, 2)
      XCTAssertEqual(Array(units), [0x41, 0x42])
    }
  }

  private func make(
    _ bytes: [UInt8], units: Int? = nil, window: Int = 32, output: Int? = nil
  ) throws -> SearchPreparedUTF8Decoder {
    let capacity = units ?? bytes.count
    return try SearchPreparedUTF8Decoder(
      expectedInputBytes: bytes.count, maxInputUTF16: capacity,
      maxWindowBytes: window, maxOutputUTF8Bytes: output ?? capacity * 3)
  }

  private func consume(_ bytes: [UInt8], into decoder: SearchPreparedUTF8Decoder) throws {
    try bytes.withUnsafeBufferPointer { try decoder.consume($0) }
  }

  private func assertError(
    _ expected: SearchPreparedUTF8Error, file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual(error as? SearchPreparedUTF8Error, expected, file: file, line: line)
    }
  }
}
