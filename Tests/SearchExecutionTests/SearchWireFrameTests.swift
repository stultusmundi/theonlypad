import Foundation
import XCTest

@testable import SearchExecution

final class SearchWireFrameTests: XCTestCase {
  private let requestID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
  private let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

  func testIdentityRejectsZeroComponentsAndOrdinal() throws {
    let generation = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!

    XCTAssertThrowsError(
      try SearchWireIdentity(generation: zeroUUID, requestID: requestID, ordinal: 1)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
    XCTAssertThrowsError(
      try SearchWireIdentity(generation: generation, requestID: zeroUUID, ordinal: 1)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
    XCTAssertThrowsError(
      try SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 0)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .ordinalMismatch)
    }

    let identity = try SearchWireIdentity(
      generation: generation, requestID: requestID, ordinal: UInt64.max)
    XCTAssertEqual(identity.generation, generation)
    XCTAssertEqual(identity.requestID, requestID)
    XCTAssertEqual(identity.ordinal, UInt64.max)
  }

  func testFrameInitializerEnforcesPayloadAndIdentityBounds() throws {
    XCTAssertNoThrow(
      try SearchWireFrame(
        kind: .inputChunk,
        requestID: requestID,
        payload: Data(repeating: 0x41, count: 65_536)))
    XCTAssertThrowsError(
      try SearchWireFrame(
        kind: .inputChunk,
        requestID: requestID,
        payload: Data(repeating: 0x41, count: 65_537))
    ) {
      XCTAssertEqual($0 as? SearchWireError, .payloadLimit)
    }
    XCTAssertNoThrow(
      try SearchWireFrame(kind: .parentHello, requestID: zeroUUID, payload: Data()))
    XCTAssertNoThrow(
      try SearchWireFrame(kind: .childHello, requestID: zeroUUID, payload: Data()))
    XCTAssertThrowsError(
      try SearchWireFrame(kind: .execute, requestID: zeroUUID, payload: Data())
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
    XCTAssertThrowsError(
      try SearchWireFrame(kind: .parentHello, requestID: requestID, payload: Data())
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
  }

  func testEncoderEmitsLiteralHeaderThenPayload() throws {
    let frame = try SearchWireFrame(
      kind: .inputChunk, requestID: requestID, payload: Data([0xAA, 0xBB]))
    var emissions: [Data] = []

    try SearchWireFrameEncoder.write(frame) { emissions.append($0) }

    XCTAssertEqual(emissions.count, 2)
    let header = try XCTUnwrap(emissions.first)
    XCTAssertEqual(
      header,
      Data([
        0x50, 0x53, 0x52, 0x58, 1, 0, 17, 0,
        2, 0, 0, 0, 0, 0, 0, 0,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
      ]))
    XCTAssertEqual(emissions.last, Data([0xAA, 0xBB]))
  }

  func testEncoderEmitsOnlyHeaderForEmptyPayload() throws {
    let frame = try SearchWireFrame(kind: .execute, requestID: requestID, payload: Data())
    var emissions: [Data] = []

    try SearchWireFrameEncoder.write(frame) { emissions.append($0) }

    XCTAssertEqual(emissions.count, 1)
    let header = try XCTUnwrap(emissions.first)
    XCTAssertEqual(header.count, 32)
    XCTAssertEqual(Array(header[6..<8]), [18, 0])
    XCTAssertEqual(Array(header[8..<16]), Array(repeating: 0, count: 8))
  }

  func testEncoderMapsEmitFailureAndStopsBeforePayload() throws {
    enum Refusal: Error { case stop }
    let frame = try SearchWireFrame(
      kind: .inputChunk, requestID: requestID, payload: Data([0xAA, 0xBB]))
    var emissions = 0

    XCTAssertThrowsError(
      try SearchWireFrameEncoder.write(frame) { _ in
        emissions += 1
        throw Refusal.stop
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(emissions, 1)
  }

  func testDecoderAcceptsEveryHeaderSplitFromLiteralFixture() throws {
    let fixture = literalFrame(kind: 17, payload: [0x34, 0x12])

    for split in 0...32 {
      let decoder = SearchWireFrameDecoder()
      var frames: [SearchWireFrame] = []
      try consume(Data(fixture[..<split]), with: decoder) { frames.append($0) }
      try consume(Data(fixture[split...]), with: decoder) { frames.append($0) }
      try decoder.finish()

      XCTAssertEqual(frames.count, 1, "header split \(split)")
      XCTAssertEqual(frames.first?.kind, .inputChunk, "header split \(split)")
      XCTAssertEqual(frames.first?.requestID, requestID, "header split \(split)")
      XCTAssertEqual(frames.first?.payload, Data([0x34, 0x12]), "header split \(split)")
      XCTAssertEqual(decoder.bufferedByteCount, 0, "header split \(split)")
    }
  }

  func testDecoderEmitsCoalescedLiteralFramesInOrder() throws {
    var bytes = literalFrame(kind: 18, payload: [])
    bytes.append(contentsOf: literalFrame(kind: 17, payload: [0x41, 0x00]))
    let decoder = SearchWireFrameDecoder()
    var frames: [SearchWireFrame] = []

    try consume(bytes, with: decoder) { frames.append($0) }

    XCTAssertEqual(frames.map(\.kind), [.execute, .inputChunk])
    XCTAssertEqual(frames.map(\.payload), [Data(), Data([0x41, 0x00])])
    XCTAssertEqual(decoder.bufferedByteCount, 0)
  }

  func testDecoderAcceptsHeaderAndBodyOneByteAtATime() throws {
    let fixture = literalFrame(kind: 17, payload: [0x3D, 0xD8, 0x00, 0xDE])
    let decoder = SearchWireFrameDecoder()
    var frames: [SearchWireFrame] = []

    for byte in fixture {
      try consume(Data([byte]), with: decoder) { frames.append($0) }
    }
    try decoder.finish()

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames.first?.payload, Data([0x3D, 0xD8, 0x00, 0xDE]))
  }

  func testDecoderRejectsOversizedDeclaredPayloadBeforeBodyOrSink() throws {
    let decoder = SearchWireFrameDecoder()
    var emitted = 0
    let bad = Data(
      [
        0x50, 0x53, 0x52, 0x58, 1, 0, 17, 0,
        1, 0, 1, 0, 0, 0, 0, 0,
      ] + Array(repeating: 1, count: 16))

    XCTAssertThrowsError(
      try bad.withUnsafeBytes {
        try decoder.consume($0) { _ in emitted += 1 }
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .payloadLimit)
    }
    XCTAssertEqual(emitted, 0)
    XCTAssertLessThanOrEqual(decoder.bufferedByteCount, 32)
    assertPoisoned(decoder)
  }

  func testDecoderRejectsInvalidHeaderFieldsWithoutSinkInvocation() throws {
    let cases: [(String, Data, SearchWireError)] = [
      (
        "magic",
        literalFrame(kind: 18, payload: [], overrides: [0: 0]),
        .invalidHeader
      ),
      (
        "version",
        literalFrame(kind: 18, payload: [], overrides: [4: 2]),
        .unsupportedVersion
      ),
      (
        "kind",
        literalFrame(kind: 0xFFFF, payload: []),
        .unknownKind
      ),
      (
        "uint64 max payload",
        literalFrame(
          kind: 17,
          payload: [],
          overrides: Dictionary(uniqueKeysWithValues: (8..<16).map { ($0, 0xFF) })
        ),
        .payloadLimit
      ),
    ]

    for (name, bytes, expectedError) in cases {
      let decoder = SearchWireFrameDecoder()
      var emitted = 0
      XCTAssertThrowsError(try consume(bytes, with: decoder) { _ in emitted += 1 }, name) {
        XCTAssertEqual($0 as? SearchWireError, expectedError, name)
      }
      XCTAssertEqual(emitted, 0, name)
      XCTAssertLessThanOrEqual(decoder.bufferedByteCount, 32, name)
      assertPoisoned(decoder, file: #filePath, line: #line)
    }
  }

  func testDecoderRejectsInvalidFrameUUIDRelationshipWithoutSinkInvocation() throws {
    let cases = [
      literalFrame(kind: 1, payload: [], uuid: requestID),
      literalFrame(kind: 18, payload: [], uuid: zeroUUID),
    ]

    for bytes in cases {
      let decoder = SearchWireFrameDecoder()
      var emitted = 0
      XCTAssertThrowsError(try consume(bytes, with: decoder) { _ in emitted += 1 }) {
        XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
      }
      XCTAssertEqual(emitted, 0)
      assertPoisoned(decoder, file: #filePath, line: #line)
    }
  }

  func testDecoderAcceptsEmptyFrameAndMaximumPayload() throws {
    let emptyDecoder = SearchWireFrameDecoder()
    var emptyFrames: [SearchWireFrame] = []
    try consume(literalFrame(kind: 18, payload: []), with: emptyDecoder) {
      emptyFrames.append($0)
    }
    XCTAssertEqual(emptyFrames.count, 1)
    XCTAssertTrue(try XCTUnwrap(emptyFrames.first).payload.isEmpty)

    let payload = Data(repeating: 0xA5, count: 65_536)
    let maximumDecoder = SearchWireFrameDecoder()
    var maximumFrames: [SearchWireFrame] = []
    try consume(literalFrame(kind: 17, payload: Array(payload)), with: maximumDecoder) {
      maximumFrames.append($0)
    }
    XCTAssertEqual(maximumFrames.count, 1)
    let maximumFrame = try XCTUnwrap(maximumFrames.first)
    XCTAssertEqual(maximumFrame.payload.count, 65_536)
    XCTAssertEqual(maximumFrame.payload.first, 0xA5)
    XCTAssertEqual(maximumFrame.payload.last, 0xA5)
    XCTAssertEqual(maximumDecoder.bufferedByteCount, 0)
  }

  func testDecoderRejectsTransportBuffersOverOneMaximumFrame() throws {
    let decoder = SearchWireFrameDecoder()
    var emitted = 0
    let oversizedRead = Data(repeating: 0, count: 65_569)

    XCTAssertThrowsError(try consume(oversizedRead, with: decoder) { _ in emitted += 1 }) {
      XCTAssertEqual($0 as? SearchWireError, .payloadLimit)
    }
    XCTAssertEqual(emitted, 0)
    XCTAssertEqual(decoder.bufferedByteCount, 0)
    assertPoisoned(decoder)
  }

  func testFinishRejectsTrailingPartialHeaderAndPoisons() throws {
    let decoder = SearchWireFrameDecoder()
    try consume(Data(literalFrame(kind: 18, payload: []).prefix(31)), with: decoder) { _ in
      XCTFail("partial header must not emit")
    }
    XCTAssertEqual(decoder.bufferedByteCount, 31)

    XCTAssertThrowsError(try decoder.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    assertPoisoned(decoder)
  }

  func testFinishRejectsTrailingPartialBodyAndPoisons() throws {
    let decoder = SearchWireFrameDecoder()
    let body = literalFrame(kind: 17, payload: [0x41, 0x00])
    try consume(Data(body.dropLast()), with: decoder) { _ in
      XCTFail("partial body must not emit")
    }
    XCTAssertEqual(decoder.bufferedByteCount, 1)

    XCTAssertThrowsError(try decoder.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    assertPoisoned(decoder)
  }

  func testSuccessfulFinishIsIdempotentAndConsumeAfterFinishPoisons() throws {
    let decoder = SearchWireFrameDecoder()

    try decoder.finish()
    XCTAssertNoThrow(try decoder.finish())
    XCTAssertThrowsError(try consume(Data(), with: decoder) { _ in }) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(decoder)
  }

  func testCallbackFailureMapsToSinkRejectedAndPoisons() throws {
    enum Refusal: Error { case stop }
    let decoder = SearchWireFrameDecoder()
    var emitted = 0

    XCTAssertThrowsError(
      try consume(literalFrame(kind: 18, payload: []), with: decoder) { _ in
        emitted += 1
        throw Refusal.stop
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(emitted, 1)
    assertPoisoned(decoder)
  }

  func testCaughtCallbackReentryPoisonsOuterAndSubsequentUse() throws {
    let decoder = SearchWireFrameDecoder()
    var nestedError: SearchWireError?
    var emitted = 0

    XCTAssertThrowsError(
      try consume(literalFrame(kind: 18, payload: []), with: decoder) { _ in
        emitted += 1
        do {
          try decoder.finish()
        } catch {
          nestedError = error as? SearchWireError
        }
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    XCTAssertEqual(emitted, 1)
    assertPoisoned(decoder)
  }

  func testCallbackErrorCannotOverrideCaughtReentryOrDeliverLaterFrame() throws {
    enum Refusal: Error { case stop }
    let decoder = SearchWireFrameDecoder()
    var nestedError: SearchWireError?
    var emittedKinds: [SearchWireKind] = []
    var bytes = literalFrame(kind: 18, payload: [])
    bytes.append(contentsOf: literalFrame(kind: 17, payload: [0x41, 0x00]))

    XCTAssertThrowsError(
      try consume(bytes, with: decoder) { frame in
        emittedKinds.append(frame.kind)
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
    XCTAssertEqual(emittedKinds, [.execute])
    assertPoisoned(decoder)
  }

  private func literalFrame(
    kind: UInt16,
    payload: [UInt8],
    uuid: UUID? = nil,
    overrides: [Int: UInt8] = [:]
  ) -> Data {
    let frameUUID = uuid ?? requestID
    let uuidBytes = withUnsafeBytes(of: frameUUID.uuid) { Array($0) }
    let count = UInt64(payload.count)
    var bytes: [UInt8] = [
      0x50, 0x53, 0x52, 0x58,
      1, 0,
      UInt8(truncatingIfNeeded: kind), UInt8(truncatingIfNeeded: kind >> 8),
    ]
    bytes.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: count >> UInt64($0 * 8)) })
    bytes.append(contentsOf: uuidBytes)
    bytes.append(contentsOf: payload)
    for (offset, value) in overrides {
      bytes[offset] = value
    }
    return Data(bytes)
  }

  private func consume(
    _ data: Data,
    with decoder: SearchWireFrameDecoder,
    onFrame: (SearchWireFrame) throws -> Void
  ) throws {
    try data.withUnsafeBytes {
      try decoder.consume($0, onFrame: onFrame)
    }
  }

  private func assertPoisoned(
    _ decoder: SearchWireFrameDecoder,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try decoder.finish(), file: file, line: line) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned, file: file, line: line)
    }
  }
}
