import Foundation
import XCTest

@testable import SearchExecution

final class SearchWireUTF16Tests: XCTestCase {
  private let identity = try! SearchWireIdentity(
    generation: UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!,
    requestID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
    ordinal: 1)

  func testDecoderPreservesLiteralScalarsWithoutNormalization() throws {
    let decoder = try SearchWireUTF16Decoder(expectedUTF16: 8)
    var output = Data()

    try decoder.consume(Data([0x41, 0x00, 0x00, 0x00, 0xFF, 0xFE, 0xAC, 0x20])) {
      output.append($0)
    }
    try decoder.consume(Data([0x3D, 0xD8])) { output.append($0) }
    XCTAssertEqual(output, Data([0x41, 0x00, 0xEF, 0xBB, 0xBF, 0xE2, 0x82, 0xAC]))
    try decoder.consume(Data([0x00, 0xDE, 0x65, 0x00, 0x01, 0x03])) {
      output.append($0)
    }
    try decoder.finish()

    XCTAssertEqual(
      output,
      Data([
        0x41, 0x00, 0xEF, 0xBB, 0xBF, 0xE2, 0x82, 0xAC,
        0xF0, 0x9F, 0x98, 0x80, 0x65, 0xCC, 0x81,
      ]))
  }

  func testDecoderEmitsOnlyBoundedNonemptyUTF8Chunks() throws {
    let scalarCount = 32_768
    let decoder = try SearchWireUTF16Decoder(expectedUTF16: scalarCount)
    let input = repeatingBytes([0xAC, 0x20], count: scalarCount)
    var chunks: [Data] = []

    try decoder.consume(input) { chunks.append($0) }
    try decoder.finish()

    XCTAssertEqual(chunks.map(\.count), [65_535, 32_769])
    XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 65_536 })
    XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, 98_304)
    XCTAssertTrue(
      chunks.allSatisfy { chunk in
        chunk.enumerated().allSatisfy { offset, byte in
          byte == [0xE2, 0x82, 0xAC][offset % 3]
        }
      })
  }

  func testDecoderRejectsInvalidConstructorAndDirectCallLengths() throws {
    assertError(.invalidMetadata) { _ = try SearchWireUTF16Decoder(expectedUTF16: -1) }
    assertError(.invalidMetadata) {
      _ = try SearchWireUTF16Decoder(expectedUTF16: 100_000_001)
    }

    let empty = try SearchWireUTF16Decoder(expectedUTF16: 0)
    assertError(.lengthMismatch) { try empty.consume(Data()) { _ in } }
    assertError(.poisoned) { try empty.finish() }

    let odd = try SearchWireUTF16Decoder(expectedUTF16: 1)
    assertError(.lengthMismatch) { try odd.consume(Data([0x41])) { _ in } }
    assertError(.poisoned) { try odd.finish() }

    let oversized = try SearchWireUTF16Decoder(expectedUTF16: 32_769)
    assertError(.payloadLimit) {
      try oversized.consume(Data(repeating: 0, count: 65_538)) { _ in }
    }
    assertError(.poisoned) { try oversized.finish() }

    let maximum = try SearchWireUTF16Decoder(expectedUTF16: 32_768)
    var outputBytes = 0
    try maximum.consume(Data(repeating: 0, count: 65_536)) { outputBytes += $0.count }
    try maximum.finish()
    XCTAssertEqual(outputBytes, 32_768)
  }

  func testDecoderRejectsShortAndLongDeclaredLengthsBeforeSuccessfulEnd() throws {
    let short = try SearchWireUTF16Decoder(expectedUTF16: 2)
    try short.consume(Data([0x41, 0x00])) { _ in }
    assertError(.lengthMismatch) { try short.finish() }
    assertError(.poisoned) { try short.finish() }

    let long = try SearchWireUTF16Decoder(expectedUTF16: 1)
    var callbacks = 0
    assertError(.lengthMismatch) {
      try long.consume(Data([0x41, 0x00, 0x42, 0x00])) { _ in callbacks += 1 }
    }
    XCTAssertEqual(callbacks, 0)
    assertError(.poisoned) { try long.finish() }
  }

  func testDecoderRejectsMalformedSurrogateSequencesWithExactPrecedence() throws {
    let lowFirst = try SearchWireUTF16Decoder(expectedUTF16: 1)
    assertError(.malformedUTF16) {
      try lowFirst.consume(Data([0x00, 0xDE])) { _ in }
    }

    let wrongAfterSplit = try SearchWireUTF16Decoder(expectedUTF16: 2)
    try wrongAfterSplit.consume(Data([0x3D, 0xD8])) { _ in
      XCTFail("a pending high surrogate must not emit")
    }
    assertError(.malformedUTF16) {
      try wrongAfterSplit.consume(Data([0x41, 0x00])) { _ in }
    }

    let exactDangling = try SearchWireUTF16Decoder(expectedUTF16: 1)
    try exactDangling.consume(Data([0x3D, 0xD8])) { _ in
      XCTFail("a pending high surrogate must not emit")
    }
    assertError(.malformedUTF16) { try exactDangling.finish() }

    let shortDangling = try SearchWireUTF16Decoder(expectedUTF16: 2)
    try shortDangling.consume(Data([0x3D, 0xD8])) { _ in }
    assertError(.lengthMismatch) { try shortDangling.finish() }
  }

  func testDecoderSuccessfulFinishIsIdempotentAndLaterConsumePoisons() throws {
    let decoder = try SearchWireUTF16Decoder(expectedUTF16: 0)

    try decoder.finish()
    XCTAssertNoThrow(try decoder.finish())
    assertError(.invalidPhase) { try decoder.consume(Data([0x41, 0x00])) { _ in } }
    assertError(.poisoned) { try decoder.finish() }
  }

  func testDecoderMapsOrdinaryCallbackFailureAndPoisons() throws {
    enum Refusal: Error { case stop }
    let decoder = try SearchWireUTF16Decoder(expectedUTF16: 1)

    XCTAssertThrowsError(try decoder.consume(Data([0x41, 0x00])) { _ in throw Refusal.stop }) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    assertError(.poisoned) { try decoder.finish() }
  }

  func testDecoderCallbackErrorCannotOverrideCaughtReentryOrEmitLaterChunk() throws {
    enum Refusal: Error { case stop }
    let scalarCount = 32_768
    let decoder = try SearchWireUTF16Decoder(expectedUTF16: scalarCount)
    let input = repeatingBytes([0xAC, 0x20], count: scalarCount)
    var nestedError: SearchWireError?
    var emittedChunks = 0

    XCTAssertThrowsError(
      try decoder.consume(input) { _ in
        emittedChunks += 1
        do {
          try decoder.finish()
        } catch {
          nestedError = error as? SearchWireError
        }
        throw Refusal.stop
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    XCTAssertEqual(emittedChunks, 1)
    assertError(.poisoned) { try decoder.finish() }
  }

  func testEncoderProducesLiteralUTF16LEWithoutNormalization() throws {
    let encoder = try SearchWireUTF16Encoder(text: "A\0\u{FEFF}€😀e\u{0301}", expectedUTF16: 8)
    var chunks: [Data] = []

    while let chunk = try encoder.nextChunk() {
      chunks.append(chunk)
    }

    let chunk = try XCTUnwrap(chunks.first)
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(
      chunk,
      Data([
        0x41, 0x00, 0x00, 0x00, 0xFF, 0xFE, 0xAC, 0x20,
        0x3D, 0xD8, 0x00, 0xDE, 0x65, 0x00, 0x01, 0x03,
      ]))
    XCTAssertNil(try encoder.nextChunk())
  }

  func testEncoderBoundsChunksAndPreservesExactUnits() throws {
    let scalarCount = 40_000
    let encoder = try SearchWireUTF16Encoder(
      text: String(repeating: "€", count: scalarCount), expectedUTF16: scalarCount)
    var output = Data()
    var chunkCounts: [Int] = []

    while let chunk = try encoder.nextChunk() {
      chunkCounts.append(chunk.count)
      XCTAssertLessThanOrEqual(chunk.count, 65_536)
      XCTAssertEqual(chunk.count % 2, 0)
      output.append(chunk)
    }

    XCTAssertEqual(chunkCounts, [65_536, 14_464])
    XCTAssertEqual(output, repeatingBytes([0xAC, 0x20], count: scalarCount))
  }

  func testEncoderRejectsInvalidOrMismatchedExpectedLengthAndPoisons() throws {
    assertError(.invalidMetadata) {
      _ = try SearchWireUTF16Encoder(text: "", expectedUTF16: -1)
    }
    assertError(.invalidMetadata) {
      _ = try SearchWireUTF16Encoder(text: "", expectedUTF16: 100_000_001)
    }

    let short = try SearchWireUTF16Encoder(text: "A", expectedUTF16: 2)
    assertError(.lengthMismatch) { _ = try short.nextChunk() }
    assertError(.poisoned) { _ = try short.nextChunk() }

    let long = try SearchWireUTF16Encoder(text: "AB", expectedUTF16: 1)
    assertError(.lengthMismatch) { _ = try long.nextChunk() }
    assertError(.poisoned) { _ = try long.nextChunk() }
  }

  func testEncoderEmptyTextReturnsStableNil() throws {
    let encoder = try SearchWireUTF16Encoder(text: "", expectedUTF16: 0)

    XCTAssertNil(try encoder.nextChunk())
    XCTAssertNil(try encoder.nextChunk())
  }

  func testBoundaryIndexMarksScalarEndpointsAndRetainsCorrelation() throws {
    let index = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 4)

    try index.append(Data([0x41, 0x00, 0x3D, 0xD8]))
    try index.append(Data([0x00, 0xDE, 0x42, 0x00]))
    try index.finish()

    XCTAssertEqual(index.identity, identity)
    XCTAssertEqual(index.expectedUTF16, 4)
    XCTAssertEqual(index.storageByteCount, 1)
    try index.validate(NSRange(location: 0, length: 4), within: nil)
    try index.validate(NSRange(location: 1, length: 2), within: nil)
    try index.validate(NSRange(location: 3, length: 0), within: nil)
    assertError(.invalidRange) {
      try index.validate(NSRange(location: 2, length: 0), within: nil)
    }
    try index.validate(NSRange(location: 4, length: 0), within: nil)
  }

  func testBoundaryIndexZeroInputHasOnlyZeroEndpoint() throws {
    let index = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 0)

    try index.finish()

    XCTAssertEqual(index.storageByteCount, 1)
    try index.validate(NSRange(location: 0, length: 0), within: nil)
    assertError(.invalidRange) {
      try index.validate(NSRange(location: 1, length: 0), within: nil)
    }
  }

  func testBoundaryIndexRejectsInvalidConstructorAndAppendLengths() throws {
    assertError(.invalidMetadata) {
      _ = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: -1)
    }
    assertError(.invalidMetadata) {
      _ = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 100_000_001)
    }

    let empty = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 0)
    assertError(.lengthMismatch) { try empty.append(Data()) }
    assertError(.poisoned) { try empty.validate(NSRange(location: 0, length: 0), within: nil) }

    let odd = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 1)
    assertError(.lengthMismatch) { try odd.append(Data([0x41])) }
    assertError(.poisoned) { try odd.finish() }

    let oversized = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 32_769)
    assertError(.payloadLimit) { try oversized.append(Data(repeating: 0, count: 65_538)) }
    assertError(.poisoned) { try oversized.finish() }

    let maximum = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 32_768)
    try maximum.append(Data(repeating: 0, count: 65_536))
    try maximum.finish()
    XCTAssertEqual(maximum.storageByteCount, 4_097)
  }

  func testBoundaryIndexRejectsLengthAndSurrogateFailures() throws {
    let short = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 2)
    try short.append(Data([0x41, 0x00]))
    assertError(.lengthMismatch) { try short.finish() }

    let long = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 1)
    assertError(.lengthMismatch) { try long.append(Data([0x41, 0x00, 0x42, 0x00])) }

    let lowFirst = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 1)
    assertError(.malformedUTF16) { try lowFirst.append(Data([0x00, 0xDE])) }

    let wrongAfterSplit = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 2)
    try wrongAfterSplit.append(Data([0x3D, 0xD8]))
    assertError(.malformedUTF16) { try wrongAfterSplit.append(Data([0x41, 0x00])) }

    let exactDangling = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 1)
    try exactDangling.append(Data([0x3D, 0xD8]))
    assertError(.malformedUTF16) { try exactDangling.finish() }

    let shortDangling = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 2)
    try shortDangling.append(Data([0x3D, 0xD8]))
    assertError(.lengthMismatch) { try shortDangling.finish() }
  }

  func testBoundaryIndexValidatesRangesAndScopesWithoutOverflow() throws {
    let index = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 4)
    try index.append(Data([0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x42, 0x00]))
    try index.finish()

    let emojiScope = NSRange(location: 1, length: 2)
    try index.validate(NSRange(location: 1, length: 2), within: emojiScope)
    try index.validate(NSRange(location: 3, length: 0), within: emojiScope)
    assertError(.invalidRange) {
      try index.validate(NSRange(location: 0, length: 1), within: emojiScope)
    }
    assertError(.invalidRange) {
      try index.validate(NSRange(location: 1, length: 2), within: NSRange(location: 2, length: 1))
    }
    assertError(.invalidRange) {
      try index.validate(NSRange(location: -1, length: 0), within: nil)
    }
    assertError(.invalidRange) {
      try index.validate(NSRange(location: 0, length: -1), within: nil)
    }
    assertError(.invalidRange) {
      try index.validate(NSRange(location: Int.max - 1, length: 8), within: nil)
    }
    assertError(.invalidRange) {
      try index.validate(NSRange(location: 3, length: 1), within: NSRange(location: 3, length: 2))
    }

    try index.validate(NSRange(location: 0, length: 1), within: nil)
  }

  func testBoundaryIndexLifecycleMisusePoisonsButInvalidRangeDoesNot() throws {
    let unfinished = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 0)
    assertError(.invalidPhase) {
      try unfinished.validate(NSRange(location: 0, length: 0), within: nil)
    }
    assertError(.poisoned) { try unfinished.finish() }

    let finished = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 0)
    try finished.finish()
    XCTAssertNoThrow(try finished.finish())
    assertError(.invalidRange) {
      try finished.validate(NSRange(location: 1, length: 0), within: nil)
    }
    try finished.validate(NSRange(location: 0, length: 0), within: nil)
    assertError(.invalidPhase) { try finished.append(Data([0x41, 0x00])) }
    assertError(.poisoned) {
      try finished.validate(NSRange(location: 0, length: 0), within: nil)
    }
  }

  func testBoundaryIndexPackedStorageAnswersOneHundredThousandDistributedRanges() throws {
    let repetitions = 25_001
    let expectedUTF16 = repetitions * 4
    let index = try SearchWireBoundaryIndex(
      identity: identity, expectedUTF16: expectedUTF16)
    let input = repeatingBytes(
      [0x41, 0x00, 0xAC, 0x20, 0x3D, 0xD8, 0x00, 0xDE], count: repetitions)
    var offset = 0

    for _ in 0..<8 {
      try index.append(Data(input[offset..<(offset + 6)]))
      offset += 6
      try index.append(Data(input[offset..<(offset + 2)]))
      offset += 2
    }
    while offset < input.count {
      let end = min(offset + 65_536, input.count)
      try index.append(Data(input[offset..<end]))
      offset = end
    }
    try index.finish()

    XCTAssertEqual(index.storageByteCount, 12_501)
    let starts = [0, 1, 2, 4]
    let ends = [1, 2, 4, 4]
    var validated = 0
    for number in 0..<100_000 {
      let cycle = number * repetitions / 100_000
      let selector = number % 4
      let location = cycle * 4 + starts[selector]
      try index.validate(
        NSRange(location: location, length: ends[selector] - starts[selector]), within: nil)
      validated += 1
    }
    XCTAssertEqual(validated, 100_000)

    for cycle in [0, 1, 123, 12_500, 25_000] {
      assertError(.invalidRange) {
        try index.validate(NSRange(location: cycle * 4 + 3, length: 0), within: nil)
      }
    }
    assertError(.invalidRange) {
      try index.validate(
        NSRange(location: expectedUTF16 - 4, length: 4),
        within: NSRange(location: expectedUTF16 - 2, length: 2))
    }
    try index.validate(NSRange(location: 0, length: expectedUTF16), within: nil)
  }

  private func repeatingBytes(_ bytes: [UInt8], count: Int) -> Data {
    var result = Data()
    result.reserveCapacity(bytes.count * count)
    for _ in 0..<count {
      result.append(contentsOf: bytes)
    }
    return result
  }

  private func assertError(
    _ expected: SearchWireError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) {
      XCTAssertEqual($0 as? SearchWireError, expected, file: file, line: line)
    }
  }
}
