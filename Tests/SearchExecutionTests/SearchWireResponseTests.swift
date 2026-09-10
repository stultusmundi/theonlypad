import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchWireResponseTests: XCTestCase {
  private let generation = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
  private let requestID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

  func testResponseRetainsValidatedShapeAndRejectsGlobalBounds() throws {
    let identity = try makeIdentity()
    XCTAssertEqual(
      try SearchWireResponse(identity: identity, matchCount: 0, replacementUTF16: nil),
      try SearchWireResponse(identity: identity, matchCount: 0, replacementUTF16: nil))
    XCTAssertEqual(
      try SearchWireResponse(
        identity: identity, matchCount: 100_000, replacementUTF16: 100_000_000
      ).replacementUTF16,
      100_000_000)

    for (count, replacement) in [(-1, nil), (100_001, nil), (0, -1), (0, 100_000_001)] {
      XCTAssertThrowsError(
        try SearchWireResponse(
          identity: identity, matchCount: count, replacementUTF16: replacement)
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
      }
    }
  }

  func testWriterEmitsIndependentExactBodyAndTerminalFixtures() throws {
    let identity = try makeIdentity()
    let response = try SearchWireResponse(identity: identity, matchCount: 1, replacementUTF16: 3)
    let output = SearchExecutionOutput(
      matches: [NSRange(location: 1, length: 2)], replacement: "A😀")
    var bodyChunks: [Data] = []

    try SearchWireWriter.responseBody(response, output: output) { bodyChunks.append($0) }

    var metadata = Data()
    append(UInt64(1), to: &metadata)
    append(UInt32(1), to: &metadata)
    append(UInt32(0), to: &metadata)
    append(UInt64(3), to: &metadata)
    metadata.append(1)
    metadata.append(contentsOf: repeatElement(UInt8(0), count: 7))
    var range = Data()
    append(UInt64(1), to: &range)
    append(UInt64(2), to: &range)
    var expected = literalFrame(kind: 32, requestID: requestID, payload: metadata)
    expected.append(literalFrame(kind: 33, requestID: requestID, payload: range))
    expected.append(
      literalFrame(
        kind: 34, requestID: requestID,
        payload: Data([0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE])))
    XCTAssertEqual(joined(bodyChunks), expected)
    XCTAssertFalse(frameKinds(in: bodyChunks).contains(.terminal))

    var terminal = Data()
    try SearchWireWriter.terminal(identity, result: .failure(.engineFailure)) {
      terminal.append($0)
    }
    XCTAssertEqual(terminal.count, 48)
    XCTAssertEqual(
      Array(terminal.suffix(16)),
      [1, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0])
  }

  func testWriterRejectsShapeCountAndSignedRangesBeforeResponseStart() throws {
    let identity = try makeIdentity()
    let cases: [(SearchWireResponse, SearchExecutionOutput, SearchWireError)] = [
      (
        try SearchWireResponse(identity: identity, matchCount: 1, replacementUTF16: nil),
        SearchExecutionOutput(matches: [], replacement: nil), .lengthMismatch
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 0, replacementUTF16: nil),
        SearchExecutionOutput(matches: [], replacement: ""), .invalidMetadata
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 0, replacementUTF16: 0),
        SearchExecutionOutput(matches: [], replacement: nil), .invalidMetadata
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 0, replacementUTF16: 1),
        SearchExecutionOutput(matches: [], replacement: ""), .lengthMismatch
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 1, replacementUTF16: nil),
        SearchExecutionOutput(matches: [NSRange(location: -1, length: 0)], replacement: nil),
        .invalidRange
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 1, replacementUTF16: nil),
        SearchExecutionOutput(matches: [NSRange(location: 0, length: -1)], replacement: nil),
        .invalidRange
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 1, replacementUTF16: nil),
        SearchExecutionOutput(
          matches: [NSRange(location: NSNotFound, length: 0)], replacement: nil),
        .invalidRange
      ),
      (
        try SearchWireResponse(identity: identity, matchCount: 1, replacementUTF16: nil),
        SearchExecutionOutput(
          matches: [NSRange(location: 100_000_000, length: 1)], replacement: nil),
        .invalidRange
      ),
    ]

    for (response, output, expected) in cases {
      var emissions = 0
      XCTAssertThrowsError(
        try SearchWireWriter.responseBody(response, output: output) { _ in emissions += 1 }
      ) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertEqual(emissions, 0)
    }
  }

  func testWriterStreamsRangeBatchesAndStopsAtFirstRejectedEmission() throws {
    let identity = try makeIdentity()
    let ranges = (0..<4_097).map { NSRange(location: $0 * 2, length: 1) }
    let response = try SearchWireResponse(
      identity: identity, matchCount: ranges.count, replacementUTF16: nil)
    var chunks: [Data] = []
    try SearchWireWriter.responseBody(
      response,
      output: SearchExecutionOutput(matches: ranges, replacement: nil)
    ) { chunks.append($0) }
    XCTAssertEqual(frameKinds(in: chunks), [.responseStart, .rangeChunk, .rangeChunk])
    XCTAssertEqual(chunks.map(\.count), [32, 32, 32, 65_536, 32, 16])
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 65_536 })

    enum Refusal: Error { case stop }
    var refused = 0
    XCTAssertThrowsError(
      try SearchWireWriter.responseBody(
        response,
        output: SearchExecutionOutput(matches: ranges, replacement: nil)
      ) { _ in
        refused += 1
        throw Refusal.stop
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(refused, 1)

    var writeThenRefuse = 0
    XCTAssertThrowsError(
      try SearchWireWriter.responseBody(
        response,
        output: SearchExecutionOutput(matches: ranges, replacement: nil)
      ) { _ in
        writeThenRefuse += 1
        if writeThenRefuse == 2 { throw Refusal.stop }
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(writeThenRefuse, 2)
  }

  func testWriterStreamsReplacementInBoundedFrames() throws {
    let replacement = String(repeating: "a", count: 32_769)
    let response = try SearchWireResponse(
      identity: makeIdentity(), matchCount: 0, replacementUTF16: 32_769)
    var chunks: [Data] = []

    try SearchWireWriter.responseBody(
      response,
      output: SearchExecutionOutput(matches: [], replacement: replacement)
    ) { chunks.append($0) }

    XCTAssertEqual(frameKinds(in: chunks), [.responseStart, .replacementChunk, .replacementChunk])
    XCTAssertEqual(chunks.map(\.count), [32, 32, 32, 65_536, 32, 2])
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 65_536 })
  }

  func testReaderFailureTerminalDiscardsPartialBodyWithoutSuccess() throws {
    let (reader, request, boundaries, sink) = try readyFixture(operation: .replace(template: "x"))
    try reader.expect(request, boundaries: boundaries)
    var bytes = responseStart(matchCount: 1, replacementUTF16: 1, hasReplacement: 1)
    bytes.append(rangeFrame(location: 0, length: 1))
    bytes.append(replacementFrame([0x58, 0x00]))
    bytes.append(terminalFrame(status: 10))

    try consume(bytes, with: reader, sink: sink)

    XCTAssertEqual(sink.terminals, [.failure(.engineFailure)])
    XCTAssertTrue(sink.completedOutputs.isEmpty)
    XCTAssertTrue(sink.ranges.isEmpty)
    XCTAssertTrue(sink.replacementUTF8.isEmpty)
  }

  func testReaderBuildsSuccessOnlyAfterExactRangesAndCompletedReplacement() throws {
    let (reader, request, boundaries, sink) = try readyFixture(operation: .replace(template: "x"))
    try reader.expect(request, boundaries: boundaries)
    var bytes = responseStart(matchCount: 2, replacementUTF16: 3, hasReplacement: 1)
    bytes.append(rangeFrame(location: 0, length: 1))
    bytes.append(rangeFrame(location: 1, length: 1))
    bytes.append(replacementFrame([0x41, 0x00, 0x3D, 0xD8]))
    bytes.append(replacementFrame([0x00, 0xDE]))
    bytes.append(terminalFrame(status: 0))

    try consume(bytes, with: reader, sink: sink)

    XCTAssertEqual(sink.terminals, [.success])
    XCTAssertEqual(
      sink.completedOutputs,
      [
        SearchExecutionOutput(
          matches: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)],
          replacement: "A😀")
      ])
  }

  func testReaderRejectsEarlySuccessAndPoisons() throws {
    let (reader, request, boundaries, sink) = try readyFixture(operation: .replace(template: "x"))
    try reader.expect(request, boundaries: boundaries)
    var bytes = responseStart(matchCount: 1, replacementUTF16: 2, hasReplacement: 1)
    bytes.append(rangeFrame(location: 0, length: 1))
    bytes.append(replacementFrame([0x3D, 0xD8]))
    bytes.append(terminalFrame(status: 0))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .lengthMismatch)
    }
    XCTAssertTrue(sink.terminals.isEmpty)
    assertPoisoned(reader)
  }

  func testReaderRequiresExactHandshakeExpectationAndCompletedIndex() throws {
    let wrongGeneration = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let handshakeReader = try SearchWireResponseReader(generation: generation)
    let handshakeSink = RecordingResponseSink()
    XCTAssertThrowsError(
      try consume(
        childHello(generation: wrongGeneration), with: handshakeReader, sink: handshakeSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }

    let reader = try SearchWireResponseReader(generation: generation)
    try consume(childHello(), with: reader, sink: RecordingResponseSink())
    let request = try makeRequest()
    let active = try SearchWireBoundaryIndex(identity: request.identity, expectedUTF16: 2)
    XCTAssertThrowsError(try reader.expect(request, boundaries: active)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(reader)

    let lengthReader = try readyReader()
    let shortIndex = try SearchWireBoundaryIndex(identity: request.identity, expectedUTF16: 1)
    try shortIndex.append(Data([0x41, 0x00]))
    try shortIndex.finish()
    XCTAssertThrowsError(try lengthReader.expect(request, boundaries: shortIndex)) {
      XCTAssertEqual($0 as? SearchWireError, .lengthMismatch)
    }
  }

  func testReaderRejectsWrongExpectedGenerationIdentityAndOrdinal() throws {
    let otherGeneration = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let otherRequest = UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
    let baseRequest = try makeRequest()
    let baseIndex = try makeIndex(for: baseRequest, text: "AB")
    for identity in [
      try SearchWireIdentity(generation: otherGeneration, requestID: requestID, ordinal: 1),
      try SearchWireIdentity(generation: generation, requestID: otherRequest, ordinal: 1),
      try SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 2),
    ] {
      let reader = try readyReader()
      let request = try makeRequest(identity: identity)
      XCTAssertThrowsError(try reader.expect(request, boundaries: baseIndex)) {
        XCTAssertEqual(
          $0 as? SearchWireError,
          identity.ordinal == 2 ? .ordinalMismatch : .identityMismatch)
      }
    }
  }

  func testReaderRejectsResponseMetadataIdentityShapeAndLimits() throws {
    let otherID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
    let mutations: [(Data, SearchWireError)] = [
      (
        responseStart(requestID: otherID, matchCount: 0, replacementUTF16: 0, hasReplacement: 0),
        .identityMismatch
      ),
      (
        responseStart(ordinal: 2, matchCount: 0, replacementUTF16: 0, hasReplacement: 0),
        .ordinalMismatch
      ),
      (responseStart(matchCount: 11, replacementUTF16: 0, hasReplacement: 0), .invalidMetadata),
      (responseStart(matchCount: 0, replacementUTF16: 201, hasReplacement: 1), .invalidMetadata),
      (responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 2), .invalidMetadata),
      (
        mutating(
          responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0), at: 44, to: 1),
        .invalidMetadata
      ),
      (
        mutating(
          responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0), at: 57, to: 1),
        .invalidMetadata
      ),
    ]
    for (wire, expected) in mutations {
      let (reader, request, boundaries, sink) = try readyFixture()
      try reader.expect(request, boundaries: boundaries)
      XCTAssertThrowsError(try consume(wire, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertTrue(sink.responses.isEmpty)
    }

    let (replaceReader, replaceRequest, replaceIndex, replaceSink) = try readyFixture(
      operation: .replace(template: "x"))
    try replaceReader.expect(replaceRequest, boundaries: replaceIndex)
    XCTAssertThrowsError(
      try consume(
        responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0),
        with: replaceReader, sink: replaceSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
    }

    let (duplicateReader, duplicateRequest, duplicateIndex, duplicateSink) = try readyFixture()
    try duplicateReader.expect(duplicateRequest, boundaries: duplicateIndex)
    var duplicate = responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0)
    duplicate.append(responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0))
    XCTAssertThrowsError(try consume(duplicate, with: duplicateReader, sink: duplicateSink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertEqual(duplicateSink.responses.count, 1)
  }

  func testReaderRejectsMalformedAndOversizedReplacementChunks() throws {
    let payloads: [([UInt8], Int, SearchWireError)] = [
      ([0x41], 1, .lengthMismatch),
      ([0x00, 0xDC], 1, .malformedUTF16),
      ([0x3D, 0xD8], 1, .malformedUTF16),
      ([0x41, 0x00, 0x42, 0x00], 1, .lengthMismatch),
    ]
    for (payload, declared, expected) in payloads {
      let (reader, request, boundaries, sink) = try readyFixture(
        operation: .replace(template: "x"))
      try reader.expect(request, boundaries: boundaries)
      var bytes = responseStart(
        matchCount: 0, replacementUTF16: UInt64(declared), hasReplacement: 1)
      bytes.append(replacementFrame(payload))
      if payload == [0x3D, 0xD8] { bytes.append(terminalFrame(status: 0)) }
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertTrue(sink.terminals.isEmpty)
    }
  }

  func testReaderRejectsMalformedRangePayloadsAndAuthoritativeBounds() throws {
    let cases: [(Data, SearchWireError)] = [
      (literalFrame(kind: 33, requestID: requestID, payload: Data()), .lengthMismatch),
      (
        literalFrame(kind: 33, requestID: requestID, payload: Data(repeating: 0, count: 15)),
        .lengthMismatch
      ),
      (rangeFrame(location: UInt64.max, length: 0), .invalidRange),
      (rangeFrame(location: 0, length: UInt64.max), .invalidRange),
      (rangeFrame(location: 1, length: 0), .invalidRange),
      (rangeFrame(location: 0, length: 3), .invalidRange),
    ]
    for (range, expected) in cases {
      let (reader, request, boundaries, sink) = try readyFixture(input: "😀")
      try reader.expect(request, boundaries: boundaries)
      var bytes = responseStart(matchCount: 1, replacementUTF16: 0, hasReplacement: 0)
      bytes.append(range)
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertTrue(sink.ranges.isEmpty)
    }

    let (scopeReader, scopeRequest, scopeIndex, scopeSink) = try readyFixture(
      input: "ABC", scope: NSRange(location: 1, length: 1))
    try scopeReader.expect(scopeRequest, boundaries: scopeIndex)
    var outside = responseStart(matchCount: 1, replacementUTF16: 0, hasReplacement: 0)
    outside.append(rangeFrame(location: 0, length: 1))
    XCTAssertThrowsError(try consume(outside, with: scopeReader, sink: scopeSink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidRange)
    }
  }

  func testReaderRejectsUnsortedOverlappingDuplicateZeroAndExtraRanges() throws {
    let sequences: [[NSRange]] = [
      [NSRange(location: 1, length: 1), NSRange(location: 0, length: 1)],
      [NSRange(location: 0, length: 2), NSRange(location: 1, length: 1)],
      [NSRange(location: 0, length: 0), NSRange(location: 0, length: 0)],
    ]
    for ranges in sequences {
      let (reader, request, boundaries, sink) = try readyFixture(input: "AB")
      try reader.expect(request, boundaries: boundaries)
      var bytes = responseStart(matchCount: 2, replacementUTF16: 0, hasReplacement: 0)
      for range in ranges {
        bytes.append(rangeFrame(location: UInt64(range.location), length: UInt64(range.length)))
      }
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, .invalidRange)
      }
    }

    let (extraReader, extraRequest, extraIndex, extraSink) = try readyFixture(input: "AB")
    try extraReader.expect(extraRequest, boundaries: extraIndex)
    var extra = responseStart(matchCount: 1, replacementUTF16: 0, hasReplacement: 0)
    extra.append(rangeFrame(location: 0, length: 1))
    extra.append(rangeFrame(location: 1, length: 1))
    XCTAssertThrowsError(try consume(extra, with: extraReader, sink: extraSink)) {
      XCTAssertEqual($0 as? SearchWireError, .lengthMismatch)
    }
  }

  func testReaderEnforcesBodyShapeAndTerminalStatus() throws {
    let wires: [(SearchExecutionOperation, Data, SearchWireError)] = [
      (.find, replacementFrame([0x41, 0x00]), .invalidPhase),
      (.replace(template: "x"), terminalFrame(status: 0), .lengthMismatch),
      (.find, terminalFrame(status: 11), .invalidMetadata),
      (.find, mutating(terminalFrame(status: 0), at: 42, to: 1), .invalidMetadata),
    ]
    for (operation, suffix, expected) in wires {
      let (reader, request, boundaries, sink) = try readyFixture(operation: operation)
      try reader.expect(request, boundaries: boundaries)
      var bytes = responseStart(
        matchCount: 0,
        replacementUTF16: operation == .find ? 0 : 1,
        hasReplacement: operation == .find ? 0 : 1)
      bytes.append(suffix)
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertTrue(sink.terminals.isEmpty)
    }
  }

  func testReaderAcceptsFailureBeforeBodyAndAllFixedStatuses() throws {
    let expected: [SearchError] = [
      .invalidScope, .invalidEscape, .invalidPattern, .invalidReplacement, .textLimit,
      .matchLimit, .outputLimit, .cancelled, .timedOut, .engineFailure,
    ]
    for (offset, error) in expected.enumerated() {
      let (reader, request, boundaries, sink) = try readyFixture()
      try reader.expect(request, boundaries: boundaries)
      try consume(terminalFrame(status: UInt16(offset + 1)), with: reader, sink: sink)
      XCTAssertEqual(sink.terminals, [.failure(error)])
    }
  }

  func testReaderRejectsWrongTerminalIdentityOrdinalAndDuplicates() throws {
    let otherID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
    for wire in [
      terminalFrame(requestID: otherID, status: 10), terminalFrame(ordinal: 2, status: 10),
    ] {
      let (reader, request, boundaries, sink) = try readyFixture()
      try reader.expect(request, boundaries: boundaries)
      XCTAssertThrowsError(try consume(wire, with: reader, sink: sink)) {
        let expected: SearchWireError =
          wire[16] == otherID.uuid.0 ? .identityMismatch : .ordinalMismatch
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
    }

    let (reader, request, boundaries, sink) = try readyFixture()
    try reader.expect(request, boundaries: boundaries)
    var duplicate = terminalFrame(status: 10)
    duplicate.append(terminalFrame(status: 10))
    XCTAssertThrowsError(try consume(duplicate, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertTrue(sink.terminals.isEmpty)
  }

  func testReaderFinishRequiresReadyAndIsIdempotentOnlyAfterSuccess() throws {
    let beforeHello = try SearchWireResponseReader(generation: generation)
    XCTAssertThrowsError(try beforeHello.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    assertPoisoned(beforeHello)

    let (waiting, request, boundaries, _) = try readyFixture()
    try waiting.expect(request, boundaries: boundaries)
    XCTAssertThrowsError(try waiting.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }

    let ready = try readyReader()
    try ready.finish()
    XCTAssertNoThrow(try ready.finish())
    XCTAssertThrowsError(try ready.expect(request, boundaries: boundaries)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(ready)

    let (partial, partialRequest, partialBoundaries, partialSink) = try readyFixture(
      operation: .replace(template: "x"))
    try partial.expect(partialRequest, boundaries: partialBoundaries)
    var partialBody = responseStart(
      matchCount: 0, replacementUTF16: 2, hasReplacement: 1)
    partialBody.append(replacementFrame([0x41, 0x00]))
    try consume(partialBody, with: partial, sink: partialSink)
    XCTAssertThrowsError(try partial.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
  }

  func testReaderReadyRejectsPeerBytesButAllowsEmptyConsume() throws {
    let reader = try readyReader()
    XCTAssertNoThrow(try consume(Data(), with: reader, sink: RecordingResponseSink()))
    XCTAssertThrowsError(
      try consume(Data([0x50]), with: reader, sink: RecordingResponseSink())
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(reader)
  }

  func testReaderRejectsEveryPartialHeaderCoalescedAfterHello() throws {
    let trailing = terminalFrame(status: 10)
    for count in 1...31 {
      let reader = try SearchWireResponseReader(generation: generation)
      let sink = RecordingResponseSink()
      var bytes = childHello()
      bytes.append(trailing.prefix(count))
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, .invalidPhase, "suffix \(count)")
      }
      assertPoisoned(reader)
    }

    let payloadReader = try SearchWireResponseReader(generation: generation)
    var payloadBytes = childHello()
    payloadBytes.append(trailing.prefix(40))
    XCTAssertThrowsError(
      try consume(payloadBytes, with: payloadReader, sink: RecordingResponseSink())
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
  }

  func testReaderAdvancesExactlyOneOrdinalAfterAcceptedSuccess() throws {
    let (reader, request, boundaries, sink) = try readyFixture()
    try reader.expect(request, boundaries: boundaries)
    var success = responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0)
    success.append(terminalFrame(status: 0))
    try consume(success, with: reader, sink: sink)
    XCTAssertEqual(sink.completedOutputs, [SearchExecutionOutput(matches: [], replacement: nil)])

    XCTAssertThrowsError(try reader.expect(request, boundaries: boundaries)) {
      XCTAssertEqual($0 as? SearchWireError, .ordinalMismatch)
    }

    let scheduledReader = try readyReader()
    let scheduledRequest = try makeRequest()
    try scheduledReader.expect(
      scheduledRequest, boundaries: try makeIndex(for: scheduledRequest, text: "AB"))
    try consume(success, with: scheduledReader, sink: RecordingResponseSink())
    let nextRequestID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
    let nextRequest = try makeRequest(
      identity: makeIdentity(requestID: nextRequestID, ordinal: 2))
    XCTAssertNoThrow(
      try scheduledReader.expect(
        nextRequest, boundaries: makeIndex(for: nextRequest, text: "AB")))
  }

  func testReaderRejectsTrailingPartialFrameAfterTerminalWithoutCompleting() throws {
    let trailing = responseStart(
      ordinal: 2, matchCount: 0, replacementUTF16: 0, hasReplacement: 0)
    for count in 1...31 {
      let (reader, request, boundaries, sink) = try readyFixture()
      try reader.expect(request, boundaries: boundaries)
      var bytes = terminalFrame(status: 10)
      bytes.append(trailing.prefix(count))
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, .invalidPhase, "suffix \(count)")
      }
      XCTAssertTrue(sink.terminals.isEmpty, "suffix \(count)")
      assertPoisoned(reader)
    }

    let (reader, request, boundaries, sink) = try readyFixture()
    try reader.expect(request, boundaries: boundaries)
    var bytes = terminalFrame(status: 10)
    bytes.append(trailing.prefix(40))
    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertTrue(sink.terminals.isEmpty)

    let (successReader, successRequest, successBoundaries, successSink) = try readyFixture()
    try successReader.expect(successRequest, boundaries: successBoundaries)
    var success = responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0)
    success.append(terminalFrame(status: 0))
    success.append(trailing.prefix(1))
    XCTAssertThrowsError(try consume(success, with: successReader, sink: successSink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertTrue(successSink.terminals.isEmpty)
    XCTAssertTrue(successSink.completedOutputs.isEmpty)
  }

  func testReaderMapsSinkRefusalAndStopsLaterCallbacks() throws {
    enum Refusal: Error { case stop }
    let (reader, request, boundaries, sink) = try readyFixture()
    try reader.expect(request, boundaries: boundaries)
    sink.onRanges = { _ in throw Refusal.stop }
    var bytes = responseStart(matchCount: 2, replacementUTF16: 0, hasReplacement: 0)
    bytes.append(rangeFrame(location: 0, length: 1))
    bytes.append(rangeFrame(location: 1, length: 1))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(sink.rangeCallbacks, 1)
    assertPoisoned(reader)

    let (beginReader, beginRequest, beginBoundaries, beginSink) = try readyFixture()
    try beginReader.expect(beginRequest, boundaries: beginBoundaries)
    beginSink.onBegin = { _ in throw SearchWireError.invalidMetadata }
    XCTAssertThrowsError(
      try consume(
        responseStart(matchCount: 0, replacementUTF16: 0, hasReplacement: 0),
        with: beginReader, sink: beginSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }

    let (completeReader, completeRequest, completeBoundaries, completeSink) = try readyFixture()
    try completeReader.expect(completeRequest, boundaries: completeBoundaries)
    completeSink.onComplete = { _, _ in throw Refusal.stop }
    XCTAssertThrowsError(
      try consume(terminalFrame(status: 10), with: completeReader, sink: completeSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
  }

  func testReplacementCallbackUncaughtNestedMutationPoisonsOuter() throws {
    let (reader, request, boundaries, sink) = try readyFixture(operation: .replace(template: "x"))
    try reader.expect(request, boundaries: boundaries)
    sink.onReplacement = { _ in try reader.finish() }
    var bytes = responseStart(matchCount: 0, replacementUTF16: 1, hasReplacement: 1)
    bytes.append(replacementFrame([0x41, 0x00]))
    bytes.append(terminalFrame(status: 0))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertTrue(sink.terminals.isEmpty)
    assertPoisoned(reader)
  }

  func testReplacementCallbackArbitraryErrorCannotOverrideCaughtNestedReentry() throws {
    enum Refusal: Error { case stop }
    let (reader, request, boundaries, sink) = try readyFixture(operation: .replace(template: "x"))
    try reader.expect(request, boundaries: boundaries)
    var nestedError: SearchWireError?
    sink.onReplacement = { _ in
      do { try reader.finish() } catch { nestedError = error as? SearchWireError }
      throw Refusal.stop
    }
    var bytes = responseStart(matchCount: 0, replacementUTF16: 1, hasReplacement: 1)
    bytes.append(replacementFrame([0x41, 0x00]))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    assertPoisoned(reader)
  }

  func testReplacementCallbackCaughtNestedReentryStillPoisonsNormalReturn() throws {
    let (reader, request, boundaries, sink) = try readyFixture(operation: .replace(template: "x"))
    try reader.expect(request, boundaries: boundaries)
    var nestedError: SearchWireError?
    sink.onReplacement = { _ in
      do { try reader.finish() } catch { nestedError = error as? SearchWireError }
    }
    var bytes = responseStart(matchCount: 0, replacementUTF16: 1, hasReplacement: 1)
    bytes.append(replacementFrame([0x41, 0x00]))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    assertPoisoned(reader)
  }

  func testCompleteCallbackCannotReenterExpectAndScheduledNextExpectationSucceeds() throws {
    let (reader, request, boundaries, sink) = try readyFixture()
    try reader.expect(request, boundaries: boundaries)
    let nextIdentity = try makeIdentity(
      requestID: UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!, ordinal: 2)
    let nextRequest = try makeRequest(identity: nextIdentity)
    let nextIndex = try makeIndex(for: nextRequest, text: "AB")
    var nestedError: SearchWireError?
    sink.onComplete = { _, _ in
      do { try reader.expect(nextRequest, boundaries: nextIndex) } catch {
        nestedError = error as? SearchWireError
      }
    }
    XCTAssertThrowsError(try consume(terminalFrame(status: 10), with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)

    let (scheduledReader, scheduledRequest, scheduledIndex, scheduledSink) = try readyFixture()
    try scheduledReader.expect(scheduledRequest, boundaries: scheduledIndex)
    try consume(terminalFrame(status: 10), with: scheduledReader, sink: scheduledSink)
    let scheduledNext = try makeRequest(identity: nextIdentity)
    try scheduledReader.expect(
      scheduledNext, boundaries: try makeIndex(for: scheduledNext, text: "AB"))
  }

  func testOrdinalSuccessorDoesNotWrapAtMaximum() throws {
    XCTAssertNil(searchWireSuccessor(after: UInt64.max))
  }

  private func makeIdentity(
    requestID: UUID? = nil,
    ordinal: UInt64 = 1
  ) throws -> SearchWireIdentity {
    try SearchWireIdentity(
      generation: generation, requestID: requestID ?? self.requestID, ordinal: ordinal)
  }

  private func makeRequest(
    identity: SearchWireIdentity? = nil,
    input: String = "AB",
    scope: NSRange? = nil,
    operation: SearchExecutionOperation = .find
  ) throws -> SearchWireRequest {
    try SearchWireRequest(
      identity: identity ?? makeIdentity(),
      query: SearchQuery(pattern: "A", mode: .literal),
      operation: operation,
      inputUTF16: input.utf16.count,
      scope: scope,
      limits: SearchWireLimits(
        maxTextUTF16: 100, maxOutputUTF16: 200, maxMatches: 10,
        cooperativeMilliseconds: 500))
  }

  private func makeIndex(for request: SearchWireRequest, text: String) throws
    -> SearchWireBoundaryIndex
  {
    let index = try SearchWireBoundaryIndex(
      identity: request.identity, expectedUTF16: request.inputUTF16)
    let bytes = utf16LE(text)
    if !bytes.isEmpty { try index.append(bytes) }
    try index.finish()
    return index
  }

  private func readyReader() throws -> SearchWireResponseReader {
    let reader = try SearchWireResponseReader(generation: generation)
    try consume(childHello(), with: reader, sink: RecordingResponseSink())
    return reader
  }

  private func readyFixture(
    input: String = "AB",
    scope: NSRange? = nil,
    operation: SearchExecutionOperation = .find
  ) throws -> (
    SearchWireResponseReader, SearchWireRequest, SearchWireBoundaryIndex, RecordingResponseSink
  ) {
    let reader = try readyReader()
    let request = try makeRequest(input: input, scope: scope, operation: operation)
    return (reader, request, try makeIndex(for: request, text: input), RecordingResponseSink())
  }

  private func responseStart(
    requestID: UUID? = nil,
    ordinal: UInt64 = 1,
    matchCount: UInt32,
    replacementUTF16: UInt64,
    hasReplacement: UInt8
  ) -> Data {
    var payload = Data()
    append(ordinal, to: &payload)
    append(matchCount, to: &payload)
    append(UInt32(0), to: &payload)
    append(replacementUTF16, to: &payload)
    payload.append(hasReplacement)
    payload.append(contentsOf: repeatElement(UInt8(0), count: 7))
    return literalFrame(kind: 32, requestID: requestID ?? self.requestID, payload: payload)
  }

  private func rangeFrame(location: UInt64, length: UInt64) -> Data {
    var payload = Data()
    append(location, to: &payload)
    append(length, to: &payload)
    return literalFrame(kind: 33, requestID: requestID, payload: payload)
  }

  private func replacementFrame(_ payload: [UInt8]) -> Data {
    literalFrame(kind: 34, requestID: requestID, payload: Data(payload))
  }

  private func terminalFrame(
    requestID: UUID? = nil,
    ordinal: UInt64 = 1,
    status: UInt16
  ) -> Data {
    var payload = Data()
    append(ordinal, to: &payload)
    append(status, to: &payload)
    payload.append(contentsOf: repeatElement(UInt8(0), count: 6))
    return literalFrame(kind: 35, requestID: requestID ?? self.requestID, payload: payload)
  }

  private func childHello(generation: UUID? = nil) -> Data {
    var payload = Data(uuidBytes(generation ?? self.generation))
    append(UInt32(1), to: &payload)
    append(UInt32(0), to: &payload)
    return literalFrame(kind: 2, requestID: zeroUUID, payload: payload)
  }

  private func literalFrame(kind: UInt16, requestID: UUID, payload: Data) -> Data {
    var bytes = Data([0x50, 0x53, 0x52, 0x58])
    append(UInt16(1), to: &bytes)
    append(kind, to: &bytes)
    append(UInt64(payload.count), to: &bytes)
    bytes.append(contentsOf: uuidBytes(requestID))
    bytes.append(payload)
    return bytes
  }

  private func frameKinds(in emissions: [Data]) -> [SearchWireKind] {
    emissions.compactMap { chunk in
      guard chunk.count == 32, chunk.prefix(4) == Data([0x50, 0x53, 0x52, 0x58]) else {
        return nil
      }
      return SearchWireKind(rawValue: UInt16(chunk[6]) | UInt16(chunk[7]) << 8)
    }
  }

  private func joined(_ chunks: [Data]) -> Data {
    chunks.reduce(into: Data()) { $0.append($1) }
  }

  private func mutating(_ data: Data, at offset: Int, to byte: UInt8) -> Data {
    var result = data
    result[offset] = byte
    return result
  }

  private func utf16LE(_ text: String) -> Data {
    var result = Data()
    for unit in text.utf16 { append(unit, to: &result) }
    return result
  }

  private func uuidBytes(_ uuid: UUID) -> [UInt8] {
    var value = uuid.uuid
    return withUnsafeBytes(of: &value) { Array($0) }
  }

  private func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  private func append(_ value: UInt32, to data: inout Data) {
    for offset in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> UInt32(offset * 8))) }
  }

  private func append(_ value: UInt64, to data: inout Data) {
    for offset in 0..<8 { data.append(UInt8(truncatingIfNeeded: value >> UInt64(offset * 8))) }
  }

  private func consume(
    _ data: Data,
    with reader: SearchWireResponseReader,
    sink: SearchWireResponseSink
  ) throws {
    try data.withUnsafeBytes { try reader.consume($0, sink: sink) }
  }

  private func assertPoisoned(
    _ reader: SearchWireResponseReader,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try reader.finish(), file: file, line: line) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned, file: file, line: line)
    }
  }

  private var zeroUUID: UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}

private final class RecordingResponseSink: SearchWireResponseSink {
  var hellos: [UUID] = []
  var responses: [SearchWireResponse] = []
  var ranges: [NSRange] = []
  var replacementUTF8 = Data()
  var terminals: [SearchWireTerminal] = []
  var completedOutputs: [SearchExecutionOutput] = []
  var rangeCallbacks = 0
  var onRanges: (([NSRange]) throws -> Void)?
  var onBegin: ((SearchWireResponse) throws -> Void)?
  var onReplacement: ((Data) throws -> Void)?
  var onComplete: ((SearchWireIdentity, SearchWireTerminal) throws -> Void)?

  func helloAccepted(generation: UUID) throws { hellos.append(generation) }

  func begin(_ response: SearchWireResponse) throws {
    responses.append(response)
    try onBegin?(response)
  }

  func appendRanges(_ ranges: [NSRange]) throws {
    rangeCallbacks += 1
    self.ranges.append(contentsOf: ranges)
    try onRanges?(ranges)
  }

  func appendReplacementUTF8(_ bytes: Data) throws {
    replacementUTF8.append(bytes)
    try onReplacement?(bytes)
  }

  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    terminals.append(terminal)
    if terminal == .success {
      completedOutputs.append(
        SearchExecutionOutput(
          matches: ranges,
          replacement: responses.last?.replacementUTF16 == nil
            ? nil : String(data: replacementUTF8, encoding: .utf8)))
    } else {
      ranges.removeAll()
      replacementUTF8.removeAll()
    }
    try onComplete?(identity, terminal)
  }
}
