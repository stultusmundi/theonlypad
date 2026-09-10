import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchWireRequestTests: XCTestCase {
  private let generation = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
  private let requestID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

  func testLimitsAcceptExactBoundsAndRejectValuesOutsideThem() throws {
    let zero = try SearchWireLimits(
      maxTextUTF16: 0, maxOutputUTF16: 0, maxMatches: 0, cooperativeMilliseconds: 0)
    XCTAssertEqual(zero.maxTextUTF16, 0)
    XCTAssertEqual(zero.maxOutputUTF16, 0)
    XCTAssertEqual(zero.maxMatches, 0)
    XCTAssertEqual(zero.cooperativeMilliseconds, 0)

    let maximum = try SearchWireLimits(
      maxTextUTF16: 100_000_000,
      maxOutputUTF16: 100_000_000,
      maxMatches: 100_000,
      cooperativeMilliseconds: 60_000)
    XCTAssertEqual(maximum.maxTextUTF16, 100_000_000)
    XCTAssertEqual(maximum.maxOutputUTF16, 100_000_000)
    XCTAssertEqual(maximum.maxMatches, 100_000)
    XCTAssertEqual(maximum.cooperativeMilliseconds, 60_000)

    for values in [
      (-1, 0, 0, UInt32(0)),
      (100_000_001, 0, 0, UInt32(0)),
      (0, -1, 0, UInt32(0)),
      (0, 100_000_001, 0, UInt32(0)),
      (0, 0, -1, UInt32(0)),
      (0, 0, 100_001, UInt32(0)),
      (0, 0, 0, UInt32(60_001)),
    ] {
      XCTAssertThrowsError(
        try SearchWireLimits(
          maxTextUTF16: values.0,
          maxOutputUTF16: values.1,
          maxMatches: values.2,
          cooperativeMilliseconds: values.3)
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
      }
    }
  }

  func testRequestRetainsValidatedMetadata() throws {
    let identity = try makeIdentity()
    let limits = try makeLimits()
    let request = try SearchWireRequest(
      identity: identity,
      query: SearchQuery(pattern: "a😀", mode: .regex, caseSensitive: false, wholeWord: true),
      operation: .replace(template: "e\u{301}"),
      inputUTF16: 8,
      scope: NSRange(location: 1, length: 6),
      limits: limits)

    XCTAssertEqual(request.identity, identity)
    XCTAssertEqual(request.query.pattern, "a😀")
    if case .regex = request.query.mode {} else { XCTFail("expected regex mode") }
    XCTAssertFalse(request.query.caseSensitive)
    XCTAssertTrue(request.query.wholeWord)
    XCTAssertEqual(request.operation, .replace(template: "e\u{301}"))
    XCTAssertEqual(request.inputUTF16, 8)
    XCTAssertEqual(request.scope, NSRange(location: 1, length: 6))
    XCTAssertEqual(request.limits, limits)

    let exactMaximum = String(repeating: "x", count: 4_096)
    XCTAssertNoThrow(
      try SearchWireRequest(
        identity: identity,
        query: SearchQuery(pattern: exactMaximum, mode: .literal),
        operation: .replace(template: exactMaximum),
        inputUTF16: 0,
        scope: nil,
        limits: limits))
  }

  func testRequestRejectsStructurallyInvalidMetadata() throws {
    let identity = try makeIdentity()
    let limits = try makeLimits(maxTextUTF16: 10)
    let query = SearchQuery(pattern: "a", mode: .literal)

    let invalidInputs: [(Int, NSRange?)] = [
      (-1, nil),
      (11, nil),
      (10, NSRange(location: -1, length: 0)),
      (10, NSRange(location: 0, length: -1)),
      (10, NSRange(location: 9, length: 2)),
      (10, NSRange(location: Int.max, length: 1)),
    ]
    for (inputUTF16, scope) in invalidInputs {
      XCTAssertThrowsError(
        try SearchWireRequest(
          identity: identity,
          query: query,
          operation: .find,
          inputUTF16: inputUTF16,
          scope: scope,
          limits: limits)
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
      }
    }

    let maximumLimits = try makeLimits(maxTextUTF16: 100_000_000)
    XCTAssertThrowsError(
      try SearchWireRequest(
        identity: identity,
        query: query,
        operation: .find,
        inputUTF16: 100_000_001,
        scope: nil,
        limits: maximumLimits)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
    }

    XCTAssertThrowsError(
      try SearchWireRequest(
        identity: identity,
        query: SearchQuery(pattern: String(repeating: "x", count: 4_097), mode: .literal),
        operation: .find,
        inputUTF16: 10,
        scope: nil,
        limits: limits)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
    }
    XCTAssertThrowsError(
      try SearchWireRequest(
        identity: identity,
        query: query,
        operation: .replace(template: String(repeating: "x", count: 4_097)),
        inputUTF16: 10,
        scope: nil,
        limits: limits)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
    }
  }

  func testWriterHelloUsesExactLiteralPayloadAndRejectsZeroGeneration() throws {
    var emissions: [Data] = []
    try SearchWireWriter.hello(generation: generation, fromChild: false) {
      emissions.append($0)
    }

    var helloPayload = Data(uuidBytes(generation))
    helloPayload.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])
    XCTAssertEqual(
      joined(emissions), literalFrame(kind: 1, requestID: zeroUUID, payload: helloPayload))
    XCTAssertEqual(emissions.map(\.count), [32, 24])

    emissions.removeAll()
    try SearchWireWriter.hello(generation: generation, fromChild: true) {
      emissions.append($0)
    }
    XCTAssertEqual(
      joined(emissions), literalFrame(kind: 2, requestID: zeroUUID, payload: helloPayload))

    emissions.removeAll()
    XCTAssertThrowsError(
      try SearchWireWriter.hello(generation: zeroUUID, fromChild: true) {
        emissions.append($0)
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
    XCTAssertTrue(emissions.isEmpty)
  }

  func testWriterRequestEmitsExactMetadataAndReturnsCompletedIdentityBoundIndex() throws {
    let identity = try makeIdentity()
    let limits = try makeLimits(
      maxTextUTF16: 99, maxOutputUTF16: 88, maxMatches: 77, cooperativeMilliseconds: 1_234)
    let request = try SearchWireRequest(
      identity: identity,
      query: SearchQuery(pattern: "A😀", mode: .escaped, caseSensitive: false, wholeWord: true),
      operation: .replace(template: "\0€"),
      inputUTF16: 4,
      scope: NSRange(location: 0, length: 4),
      limits: limits)
    var emissions: [Data] = []

    let index = try SearchWireWriter.request(request, text: "B😀C") {
      emissions.append($0)
    }

    let metadata = requestMetadata(
      ordinal: 1,
      inputUTF16: 4,
      scopeLocation: 0,
      scopeLength: 4,
      maxTextUTF16: 99,
      maxOutputUTF16: 88,
      maxMatches: 77,
      cooperativeMilliseconds: 1_234,
      pattern: [0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE],
      template: [0x00, 0x00, 0xAC, 0x20],
      mode: 1,
      operation: 1,
      options: 2,
      hasScope: 1)
    let input = Data([0x42, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x43, 0x00])
    var expected = literalFrame(kind: 16, requestID: requestID, payload: metadata)
    expected.append(literalFrame(kind: 17, requestID: requestID, payload: input))
    expected.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    XCTAssertEqual(joined(emissions), expected)
    XCTAssertEqual(index.identity, identity)
    try index.validate(NSRange(location: 0, length: 4), within: request.scope)
    XCTAssertThrowsError(try index.validate(NSRange(location: 2, length: 0), within: nil)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidRange)
    }
  }

  func testWriterRequestStreamsMultipleBoundedInputFrames() throws {
    let text = String(repeating: "a", count: 32_769)
    let request = try SearchWireRequest(
      identity: makeIdentity(),
      query: SearchQuery(pattern: "a", mode: .literal),
      operation: .find,
      inputUTF16: 32_769,
      scope: nil,
      limits: makeLimits(maxTextUTF16: 32_769))
    var emissions: [Data] = []

    let index = try SearchWireWriter.request(request, text: text) {
      emissions.append($0)
    }

    XCTAssertEqual(frameKinds(in: emissions), [.requestStart, .inputChunk, .inputChunk, .execute])
    XCTAssertEqual(emissions.map(\.count), [32, 66, 32, 65_536, 32, 2, 32])
    XCTAssertTrue(emissions.allSatisfy { $0.count <= 65_536 })
    try index.validate(NSRange(location: 0, length: 32_769), within: nil)
  }

  func testWriterRequestRejectsTextLengthAndScalarScopeBeforeExecute() throws {
    let shortRequest = try SearchWireRequest(
      identity: makeIdentity(),
      query: SearchQuery(pattern: "a", mode: .literal),
      operation: .find,
      inputUTF16: 1,
      scope: nil,
      limits: makeLimits())
    var lengthEmissions: [Data] = []
    XCTAssertThrowsError(
      try SearchWireWriter.request(shortRequest, text: "AB") {
        lengthEmissions.append($0)
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .lengthMismatch)
    }
    XCTAssertEqual(frameKinds(in: lengthEmissions), [.requestStart])

    let splitScope = try SearchWireRequest(
      identity: makeIdentity(),
      query: SearchQuery(pattern: "a", mode: .literal),
      operation: .find,
      inputUTF16: 2,
      scope: NSRange(location: 1, length: 0),
      limits: makeLimits())
    var scopeEmissions: [Data] = []
    XCTAssertThrowsError(
      try SearchWireWriter.request(splitScope, text: "😀") {
        scopeEmissions.append($0)
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidRange)
    }
    XCTAssertEqual(frameKinds(in: scopeEmissions), [.requestStart, .inputChunk])
  }

  func testWriterStopsOnFirstEmissionFailureIncludingWriteThenThrowAtExecute() throws {
    enum Refusal: Error { case stop }
    let request = try SearchWireRequest(
      identity: makeIdentity(),
      query: SearchQuery(pattern: "a", mode: .literal),
      operation: .find,
      inputUTF16: 0,
      scope: nil,
      limits: makeLimits())
    var firstFailureCalls = 0
    XCTAssertThrowsError(
      try SearchWireWriter.request(request, text: "") { _ in
        firstFailureCalls += 1
        throw Refusal.stop
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(firstFailureCalls, 1)

    var escapedEmissions: [Data] = []
    XCTAssertThrowsError(
      try SearchWireWriter.request(request, text: "") { bytes in
        escapedEmissions.append(bytes)
        if escapedEmissions.count == 3 {
          throw Refusal.stop
        }
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    XCTAssertEqual(escapedEmissions.count, 3)
    XCTAssertEqual(frameKinds(in: escapedEmissions), [.requestStart, .execute])
    XCTAssertEqual(escapedEmissions[2][6], UInt8(SearchWireKind.execute.rawValue))
  }

  func testReaderAcceptsExactParentHelloBeforeRequests() throws {
    let reader = try SearchWireRequestReader(generation: generation)
    let sink = RecordingRequestSink()

    try consume(parentHello(), with: reader, sink: sink)

    XCTAssertEqual(sink.hellos, [generation])
    XCTAssertTrue(sink.requests.isEmpty)
    XCTAssertTrue(sink.executions.isEmpty)
  }

  func testReaderRejectsExecuteAfterShortDeclaredInputWithoutExecuting() throws {
    let reader = try SearchWireRequestReader(generation: generation)
    let sink = RecordingRequestSink()
    try consume(parentHello(), with: reader, sink: sink)
    let metadata = requestMetadata(
      ordinal: 1,
      inputUTF16: 2,
      scopeLocation: 0,
      scopeLength: 0,
      maxTextUTF16: 10,
      maxOutputUTF16: 10,
      maxMatches: 10,
      cooperativeMilliseconds: 10,
      pattern: [0x61, 0x00],
      template: [],
      mode: 0,
      operation: 0,
      options: 1,
      hasScope: 0)
    var bytes = literalFrame(kind: 16, requestID: requestID, payload: metadata)
    bytes.append(literalFrame(kind: 17, requestID: requestID, payload: Data([0x41, 0x00])))
    bytes.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .lengthMismatch)
    }
    XCTAssertEqual(sink.requests.count, 1)
    XCTAssertEqual(sink.inputUTF8, Data([0x41]))
    XCTAssertTrue(sink.executions.isEmpty)
  }

  func testReaderDecodesSplitHelloAndCoalescedRequestThenAcknowledgesExactIdentity() throws {
    let reader = try SearchWireRequestReader(generation: generation)
    let sink = RecordingRequestSink()
    for byte in parentHello() {
      try consume(Data([byte]), with: reader, sink: sink)
    }

    let firstMetadata = requestMetadata(
      ordinal: 1,
      inputUTF16: 3,
      scopeLocation: 0,
      scopeLength: 3,
      maxTextUTF16: 100,
      maxOutputUTF16: 200,
      maxMatches: 10,
      cooperativeMilliseconds: 500,
      pattern: [0xAC, 0x20],
      template: [0x78, 0x00],
      mode: 2,
      operation: 1,
      options: 3,
      hasScope: 1)
    var first = literalFrame(kind: 16, requestID: requestID, payload: firstMetadata)
    first.append(
      literalFrame(
        kind: 17, requestID: requestID, payload: Data([0x41, 0x00, 0x3D, 0xD8])))
    first.append(
      literalFrame(kind: 17, requestID: requestID, payload: Data([0x00, 0xDE])))
    first.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    for byte in first {
      try consume(Data([byte]), with: reader, sink: sink)
    }

    XCTAssertEqual(sink.hellos, [generation])
    XCTAssertEqual(sink.requests.count, 1)
    XCTAssertEqual(sink.requests[0].identity, try makeIdentity())
    XCTAssertEqual(sink.requests[0].query.pattern, "€")
    if case .regex = sink.requests[0].query.mode {} else { XCTFail("expected regex mode") }
    XCTAssertTrue(sink.requests[0].query.caseSensitive)
    XCTAssertTrue(sink.requests[0].query.wholeWord)
    XCTAssertEqual(sink.requests[0].operation, .replace(template: "x"))
    XCTAssertEqual(sink.requests[0].scope, NSRange(location: 0, length: 3))
    XCTAssertEqual(sink.inputUTF8, Data([0x41, 0xF0, 0x9F, 0x98, 0x80]))
    XCTAssertEqual(sink.executions, [try makeIdentity()])

    try reader.acknowledgeTerminal(try makeIdentity())
    let secondMetadata = requestMetadata(
      ordinal: 2,
      inputUTF16: 0,
      scopeLocation: 0,
      scopeLength: 0,
      maxTextUTF16: 0,
      maxOutputUTF16: 0,
      maxMatches: 0,
      cooperativeMilliseconds: 0,
      pattern: [],
      template: [],
      mode: 0,
      operation: 0,
      options: 0,
      hasScope: 0)
    var second = literalFrame(kind: 16, requestID: requestID, payload: secondMetadata)
    second.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    try consume(second, with: reader, sink: sink)
    let secondIdentity = try SearchWireIdentity(
      generation: generation, requestID: requestID, ordinal: 2)
    XCTAssertEqual(sink.executions.last, secondIdentity)
    try reader.acknowledgeTerminal(secondIdentity)
    try reader.finish()
    XCTAssertNoThrow(try reader.finish())
  }

  func testReaderRejectsInvalidHandshakeWithExactErrorAndPoisons() throws {
    XCTAssertThrowsError(try SearchWireRequestReader(generation: zeroUUID)) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }

    let otherGeneration = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let cases: [(Data, SearchWireError)] = [
      (parentHello(generation: otherGeneration), .identityMismatch),
      (parentHello(semanticVersion: 2), .unsupportedVersion),
      (parentHello(reserved: 1), .invalidMetadata),
      (
        literalFrame(
          kind: 16,
          requestID: requestID,
          payload: requestMetadata(
            ordinal: 1, inputUTF16: 0, scopeLocation: 0, scopeLength: 0,
            maxTextUTF16: 0, maxOutputUTF16: 0, maxMatches: 0,
            cooperativeMilliseconds: 0, pattern: [], template: [], mode: 0,
            operation: 0, options: 0, hasScope: 0)),
        .invalidPhase
      ),
      (
        literalFrame(kind: 1, requestID: zeroUUID, payload: Data(repeating: 0, count: 23)),
        .invalidMetadata
      ),
    ]

    for (bytes, expected) in cases {
      let reader = try SearchWireRequestReader(generation: generation)
      let sink = RecordingRequestSink()
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertTrue(sink.hellos.isEmpty)
      assertPoisoned(reader)
    }
  }

  func testReaderPreservesMetadataValidationErrorsAcrossFrameCallbackWrapper() throws {
    let valid = requestMetadata(
      ordinal: 1,
      inputUTF16: 2,
      scopeLocation: 0,
      scopeLength: 0,
      maxTextUTF16: 2,
      maxOutputUTF16: 3,
      maxMatches: 4,
      cooperativeMilliseconds: 5,
      pattern: [0x61, 0x00],
      template: [],
      mode: 0,
      operation: 0,
      options: 1,
      hasScope: 0)
    var malformed: [Data] = []
    malformed.append(mutating(valid, at: 62, to: 0x04))
    malformed.append(mutating(valid, at: 63, to: 0x02))
    malformed.append(mutating(valid, at: 16, to: 0x01))
    malformed.append(mutating(valid, at: 60, to: 0x03))
    malformed.append(mutating(valid, at: 61, to: 0x02))
    var trailing = valid
    trailing.append(0)
    malformed.append(trailing)
    var findWithTemplate = valid
    findWithTemplate[58] = 1
    findWithTemplate.append(contentsOf: [0x78, 0x00])
    malformed.append(findWithTemplate)
    var inputOverText = valid
    inputOverText[32] = 1
    malformed.append(inputOverText)
    var scopeOutside = valid
    scopeOutside[16] = 2
    scopeOutside[24] = 1
    scopeOutside[63] = 1
    malformed.append(scopeOutside)
    var oversizedInput = valid
    overwrite(UInt64(100_000_001), in: &oversizedInput, at: 8)
    malformed.append(oversizedInput)
    var oversizedScopeLocation = valid
    overwrite(UInt64(100_000_001), in: &oversizedScopeLocation, at: 16)
    malformed.append(oversizedScopeLocation)
    var oversizedScopeLength = valid
    overwrite(UInt64(100_000_001), in: &oversizedScopeLength, at: 24)
    malformed.append(oversizedScopeLength)
    var oversizedTextLimit = valid
    overwrite(UInt64(100_000_001), in: &oversizedTextLimit, at: 32)
    malformed.append(oversizedTextLimit)
    var oversizedOutputLimit = valid
    overwrite(UInt64(100_000_001), in: &oversizedOutputLimit, at: 40)
    malformed.append(oversizedOutputLimit)
    var oversizedMatches = valid
    overwrite(UInt32(100_001), in: &oversizedMatches, at: 48)
    malformed.append(oversizedMatches)
    var oversizedTime = valid
    overwrite(UInt32(60_001), in: &oversizedTime, at: 52)
    malformed.append(oversizedTime)
    var oversizedPattern = valid
    overwrite(UInt16(4_097), in: &oversizedPattern, at: 56)
    malformed.append(oversizedPattern)
    var oversizedTemplate = valid
    overwrite(UInt16(4_097), in: &oversizedTemplate, at: 58)
    malformed.append(oversizedTemplate)

    for payload in malformed {
      let reader = try readyReader()
      let sink = RecordingRequestSink()
      XCTAssertThrowsError(
        try consume(
          literalFrame(kind: 16, requestID: requestID, payload: payload),
          with: reader,
          sink: sink)
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
      }
      XCTAssertTrue(sink.requests.isEmpty)
      XCTAssertTrue(sink.executions.isEmpty)
      assertPoisoned(reader)
    }
  }

  func testReaderRejectsMalformedPatternAndInputWithoutExecute() throws {
    let malformedPattern = requestMetadata(
      ordinal: 1,
      inputUTF16: 0,
      scopeLocation: 0,
      scopeLength: 0,
      maxTextUTF16: 0,
      maxOutputUTF16: 0,
      maxMatches: 0,
      cooperativeMilliseconds: 0,
      pattern: [0x00, 0xD8],
      template: [],
      mode: 0,
      operation: 0,
      options: 0,
      hasScope: 0)
    let patternReader = try readyReader()
    let patternSink = RecordingRequestSink()
    XCTAssertThrowsError(
      try consume(
        literalFrame(kind: 16, requestID: requestID, payload: malformedPattern),
        with: patternReader,
        sink: patternSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .malformedUTF16)
    }
    XCTAssertTrue(patternSink.requests.isEmpty)

    let malformedInputs: [(Data, SearchWireError)] = [
      (Data([0x00, 0xDC]), .malformedUTF16),
      (Data([0x41]), .lengthMismatch),
    ]
    for (payload, expected) in malformedInputs {
      let reader = try readyReader()
      let sink = RecordingRequestSink()
      let metadata = basicRequestMetadata(inputUTF16: 1)
      var bytes = literalFrame(kind: 16, requestID: requestID, payload: metadata)
      bytes.append(literalFrame(kind: 17, requestID: requestID, payload: payload))
      XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
        XCTAssertEqual($0 as? SearchWireError, expected)
      }
      XCTAssertEqual(sink.requests.count, 1)
      XCTAssertTrue(sink.executions.isEmpty)
    }
  }

  func testReaderValidatesScalarScopeBeforeExecute() throws {
    let reader = try readyReader()
    let sink = RecordingRequestSink()
    let metadata = requestMetadata(
      ordinal: 1,
      inputUTF16: 2,
      scopeLocation: 1,
      scopeLength: 0,
      maxTextUTF16: 2,
      maxOutputUTF16: 0,
      maxMatches: 1,
      cooperativeMilliseconds: 0,
      pattern: [],
      template: [],
      mode: 0,
      operation: 0,
      options: 0,
      hasScope: 1)
    var bytes = literalFrame(kind: 16, requestID: requestID, payload: metadata)
    bytes.append(
      literalFrame(
        kind: 17, requestID: requestID, payload: Data([0x3D, 0xD8, 0x00, 0xDE])))
    bytes.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidRange)
    }
    XCTAssertTrue(sink.executions.isEmpty)
  }

  func testReaderRejectsWrongFrameIdentityAndOrdinal() throws {
    let otherRequestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    for ordinal in [UInt64(0), 2, 3] {
      let reader = try readyReader()
      let sink = RecordingRequestSink()
      let payload = basicRequestMetadata(inputUTF16: 0, ordinal: ordinal)
      XCTAssertThrowsError(
        try consume(
          literalFrame(kind: 16, requestID: requestID, payload: payload),
          with: reader,
          sink: sink)
      ) {
        XCTAssertEqual($0 as? SearchWireError, .ordinalMismatch)
      }
    }

    let reader = try readyReader()
    let sink = RecordingRequestSink()
    var bytes = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 1))
    bytes.append(
      literalFrame(kind: 17, requestID: otherRequestID, payload: Data([0x41, 0x00])))
    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
    XCTAssertTrue(sink.executions.isEmpty)
  }

  func testReaderRequiresAcknowledgementBeforeDuplicateExecuteOrNextRequest() throws {
    let otherRequestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let executeReader = try readyReader()
    let executeSink = RecordingRequestSink()
    var duplicateExecute = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 0))
    duplicateExecute.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    duplicateExecute.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    XCTAssertThrowsError(try consume(duplicateExecute, with: executeReader, sink: executeSink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertEqual(executeSink.executions.count, 1)

    let nextReader = try readyReader()
    let nextSink = RecordingRequestSink()
    var nextRequest = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 0))
    nextRequest.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    nextRequest.append(
      literalFrame(
        kind: 16,
        requestID: otherRequestID,
        payload: basicRequestMetadata(inputUTF16: 0, ordinal: 2)))
    XCTAssertThrowsError(try consume(nextRequest, with: nextReader, sink: nextSink)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertEqual(nextSink.executions.count, 1)
  }

  func testReaderRejectsIllegalRequestFramesBeforeExecution() throws {
    let zeroIDReader = try readyReader()
    let zeroIDSink = RecordingRequestSink()
    XCTAssertThrowsError(
      try consume(
        literalFrame(
          kind: 16,
          requestID: zeroUUID,
          payload: basicRequestMetadata(inputUTF16: 0)),
        with: zeroIDReader,
        sink: zeroIDSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .identityMismatch)
    }
    XCTAssertTrue(zeroIDSink.requests.isEmpty)

    let emptyChunkReader = try readyReader()
    let emptyChunkSink = RecordingRequestSink()
    var emptyChunk = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 1))
    emptyChunk.append(literalFrame(kind: 17, requestID: requestID, payload: Data()))
    XCTAssertThrowsError(try consume(emptyChunk, with: emptyChunkReader, sink: emptyChunkSink)) {
      XCTAssertEqual($0 as? SearchWireError, .lengthMismatch)
    }
    XCTAssertTrue(emptyChunkSink.executions.isEmpty)

    let executePayloadReader = try readyReader()
    let executePayloadSink = RecordingRequestSink()
    var executePayload = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 0))
    executePayload.append(
      literalFrame(kind: 18, requestID: requestID, payload: Data([0x00])))
    XCTAssertThrowsError(
      try consume(executePayload, with: executePayloadReader, sink: executePayloadSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
    }
    XCTAssertTrue(executePayloadSink.executions.isEmpty)

    let duplicateStartReader = try readyReader()
    let duplicateStartSink = RecordingRequestSink()
    var duplicateStart = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 1))
    duplicateStart.append(
      literalFrame(
        kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 1)))
    XCTAssertThrowsError(
      try consume(duplicateStart, with: duplicateStartReader, sink: duplicateStartSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    XCTAssertEqual(duplicateStartSink.requests.count, 1)
    XCTAssertTrue(duplicateStartSink.executions.isEmpty)
  }

  func testReaderAcknowledgementRequiresExactIdentityAndRejectsReplay() throws {
    let otherRequestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let otherGeneration = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
    let wrongIdentities = [
      try SearchWireIdentity(generation: otherGeneration, requestID: requestID, ordinal: 1),
      try SearchWireIdentity(generation: generation, requestID: otherRequestID, ordinal: 1),
      try SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 2),
    ]
    for (index, wrong) in wrongIdentities.enumerated() {
      let reader = try executingReader()
      XCTAssertThrowsError(try reader.acknowledgeTerminal(wrong)) {
        XCTAssertEqual(
          $0 as? SearchWireError, index < 2 ? .identityMismatch : .ordinalMismatch)
      }
      assertPoisoned(reader)
    }

    let replayReader = try executingReader()
    let identity = try makeIdentity()
    try replayReader.acknowledgeTerminal(identity)
    XCTAssertThrowsError(try replayReader.acknowledgeTerminal(identity)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(replayReader)
  }

  func testReaderRejectsReplayedAndSkippedOrdinalAfterAcknowledgement() throws {
    for ordinal in [UInt64(1), 3] {
      let reader = try executingReader()
      try reader.acknowledgeTerminal(try makeIdentity())
      let sink = RecordingRequestSink()
      XCTAssertThrowsError(
        try consume(
          literalFrame(
            kind: 16,
            requestID: requestID,
            payload: basicRequestMetadata(inputUTF16: 0, ordinal: ordinal)),
          with: reader,
          sink: sink)
      ) {
        XCTAssertEqual($0 as? SearchWireError, .ordinalMismatch)
      }
    }
  }

  func testReaderFinishEnforcesCompleteReadyConnectionLifecycle() throws {
    let beforeHello = try SearchWireRequestReader(generation: generation)
    XCTAssertThrowsError(try beforeHello.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    assertPoisoned(beforeHello)

    let partial = try readyReader()
    let sink = RecordingRequestSink()
    try consume(Data([0x50]), with: partial, sink: sink)
    XCTAssertThrowsError(try partial.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    assertPoisoned(partial)

    let partialBody = try readyReader()
    let start = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 0))
    try consume(Data(start.prefix(40)), with: partialBody, sink: RecordingRequestSink())
    XCTAssertThrowsError(try partialBody.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    assertPoisoned(partialBody)

    let receiving = try readyReader()
    try consume(
      literalFrame(
        kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 1)),
      with: receiving,
      sink: RecordingRequestSink())
    XCTAssertThrowsError(try receiving.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }

    let executing = try executingReader()
    XCTAssertThrowsError(try executing.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }

    let finished = try readyReader()
    try finished.finish()
    XCTAssertNoThrow(try finished.finish())
    XCTAssertThrowsError(
      try Data().withUnsafeBytes {
        try finished.consume($0, sink: RecordingRequestSink())
      }
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(finished)
  }

  func testReaderMapsExternalSinkFailuresToSinkRejected() throws {
    enum Refusal: Error { case stop }
    let helloReader = try SearchWireRequestReader(generation: generation)
    let helloSink = RecordingRequestSink()
    helloSink.onHello = { throw Refusal.stop }
    XCTAssertThrowsError(try consume(parentHello(), with: helloReader, sink: helloSink)) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
    assertPoisoned(helloReader)

    let beginReader = try readyReader()
    let beginSink = RecordingRequestSink()
    beginSink.onBegin = { _ in throw SearchWireError.invalidMetadata }
    XCTAssertThrowsError(
      try consume(
        literalFrame(
          kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 0)),
        with: beginReader,
        sink: beginSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }

    let inputReader = try readyReader()
    let inputSink = RecordingRequestSink()
    inputSink.onInput = { _ in throw Refusal.stop }
    var input = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 1))
    input.append(literalFrame(kind: 17, requestID: requestID, payload: Data([0x41, 0x00])))
    XCTAssertThrowsError(try consume(input, with: inputReader, sink: inputSink)) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }

    let executeReader = try readyReader()
    let executeSink = RecordingRequestSink()
    executeSink.onExecute = { _ in throw Refusal.stop }
    XCTAssertThrowsError(
      try consume(emptyRequestWire(), with: executeReader, sink: executeSink)
    ) {
      XCTAssertEqual($0 as? SearchWireError, .sinkRejected)
    }
  }

  func testReaderExecuteCallbackReentryPoisonsOuterAndPreventsAcknowledgement() throws {
    let reader = try readyReader()
    let sink = RecordingRequestSink()
    var nestedError: SearchWireError?
    sink.onExecute = { identity in
      do {
        try reader.acknowledgeTerminal(identity)
      } catch {
        nestedError = error as? SearchWireError
      }
    }

    XCTAssertThrowsError(try consume(emptyRequestWire(), with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    XCTAssertEqual(sink.executions, [try makeIdentity()])
    assertPoisoned(reader)
  }

  func testReaderInputCallbackUncaughtReentryPreservesOuterPoison() throws {
    let reader = try readyReader()
    let sink = RecordingRequestSink()
    var nestedCallReached = false
    sink.onInput = { _ in
      nestedCallReached = true
      try reader.finish()
    }
    let bytes = twoChunkRequestWire()

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertTrue(nestedCallReached)
    XCTAssertEqual(sink.inputUTF8, Data([0x41]))
    XCTAssertTrue(sink.executions.isEmpty)
    assertPoisoned(reader)
  }

  func testReaderInputCallbackErrorCannotOverrideCaughtReentry() throws {
    enum Refusal: Error { case stop }
    let reader = try readyReader()
    let sink = RecordingRequestSink()
    var nestedError: SearchWireError?
    sink.onInput = { _ in
      do {
        try reader.finish()
      } catch {
        nestedError = error as? SearchWireError
      }
      throw Refusal.stop
    }
    let bytes = twoChunkRequestWire()

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    XCTAssertEqual(sink.inputUTF8, Data([0x41]))
    XCTAssertTrue(sink.executions.isEmpty)
    assertPoisoned(reader)
  }

  func testReaderRejectsEveryPartialHeaderAfterExecuteBeforeDrivingPendingWork() throws {
    let trailing = literalFrame(
      kind: 16,
      requestID: requestID,
      payload: basicRequestMetadata(inputUTF16: 0, ordinal: 2))

    for suffixCount in 1...31 {
      let reader = try readyReader()
      let sink = RecordingRequestSink()
      var pending: [SearchWireIdentity] = []
      var engineExecutions = 0
      sink.onExecute = { pending.append($0) }
      var bytes = emptyRequestWire()
      bytes.append(trailing.prefix(suffixCount))
      var consumeError: SearchWireError?

      do {
        try consume(bytes, with: reader, sink: sink)
        engineExecutions += pending.count
      } catch {
        consumeError = error as? SearchWireError
      }

      XCTAssertEqual(consumeError, .invalidPhase, "suffix \(suffixCount)")
      XCTAssertEqual(pending, [try makeIdentity()], "suffix \(suffixCount)")
      XCTAssertEqual(engineExecutions, 0, "suffix \(suffixCount)")
      assertPoisoned(reader)
    }
  }

  func testReaderRejectsTrailingHeaderWithPartialPayloadAfterExecute() throws {
    let reader = try readyReader()
    let sink = RecordingRequestSink()
    var pending: [SearchWireIdentity] = []
    var engineExecutions = 0
    sink.onExecute = { pending.append($0) }
    let trailing = literalFrame(
      kind: 16,
      requestID: requestID,
      payload: basicRequestMetadata(inputUTF16: 0, ordinal: 2))
    var bytes = emptyRequestWire()
    bytes.append(trailing.prefix(40))
    var consumeError: SearchWireError?

    do {
      try consume(bytes, with: reader, sink: sink)
      engineExecutions += pending.count
    } catch {
      consumeError = error as? SearchWireError
    }

    XCTAssertEqual(consumeError, .invalidPhase)
    XCTAssertEqual(pending, [try makeIdentity()])
    XCTAssertEqual(engineExecutions, 0)
    assertPoisoned(reader)
  }

  func testReaderRejectsNonemptyConsumeWhileExecutingButAllowsEmptyNoOp() throws {
    let rejecting = try executingReader()
    XCTAssertThrowsError(
      try consume(Data([0x50]), with: rejecting, sink: RecordingRequestSink())
    ) {
      XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
    }
    assertPoisoned(rejecting)

    let empty = try executingReader()
    XCTAssertNoThrow(try consume(Data(), with: empty, sink: RecordingRequestSink()))
    XCTAssertNoThrow(try empty.acknowledgeTerminal(makeIdentity()))
  }

  func testReaderCallbackErrorCannotOverrideCaughtReentryOrDeliverLaterFrame() throws {
    enum Refusal: Error { case stop }
    let reader = try SearchWireRequestReader(generation: generation)
    let sink = RecordingRequestSink()
    var nestedError: SearchWireError?
    sink.onHello = {
      do {
        try reader.finish()
      } catch {
        nestedError = error as? SearchWireError
      }
      throw Refusal.stop
    }
    var bytes = parentHello()
    bytes.append(emptyRequestWire())

    XCTAssertThrowsError(try consume(bytes, with: reader, sink: sink)) {
      XCTAssertEqual($0 as? SearchWireError, .poisoned)
    }
    XCTAssertEqual(nestedError, .reentrantUse)
    XCTAssertTrue(sink.requests.isEmpty)
    assertPoisoned(reader)
  }

  func testOrdinalSuccessorCompletesMaximumOnceWithoutWrapping() {
    XCTAssertEqual(searchWireSuccessor(after: 1), 2)
    XCTAssertNil(searchWireSuccessor(after: UInt64.max))
  }

  private func makeIdentity(ordinal: UInt64 = 1) throws -> SearchWireIdentity {
    try SearchWireIdentity(generation: generation, requestID: requestID, ordinal: ordinal)
  }

  private func makeLimits(
    maxTextUTF16: Int = 100,
    maxOutputUTF16: Int = 200,
    maxMatches: Int = 10,
    cooperativeMilliseconds: UInt32 = 500
  ) throws -> SearchWireLimits {
    try SearchWireLimits(
      maxTextUTF16: maxTextUTF16,
      maxOutputUTF16: maxOutputUTF16,
      maxMatches: maxMatches,
      cooperativeMilliseconds: cooperativeMilliseconds)
  }

  private func readyReader() throws -> SearchWireRequestReader {
    let reader = try SearchWireRequestReader(generation: generation)
    try consume(parentHello(), with: reader, sink: RecordingRequestSink())
    return reader
  }

  private func executingReader() throws -> SearchWireRequestReader {
    let reader = try readyReader()
    try consume(emptyRequestWire(), with: reader, sink: RecordingRequestSink())
    return reader
  }

  private func emptyRequestWire(
    ordinal: UInt64 = 1,
    requestID: UUID? = nil
  ) -> Data {
    let frameRequestID = requestID ?? self.requestID
    var bytes = literalFrame(
      kind: 16,
      requestID: frameRequestID,
      payload: basicRequestMetadata(inputUTF16: 0, ordinal: ordinal))
    bytes.append(literalFrame(kind: 18, requestID: frameRequestID, payload: Data()))
    return bytes
  }

  private func twoChunkRequestWire() -> Data {
    var bytes = literalFrame(
      kind: 16, requestID: requestID, payload: basicRequestMetadata(inputUTF16: 2))
    bytes.append(literalFrame(kind: 17, requestID: requestID, payload: Data([0x41, 0x00])))
    bytes.append(literalFrame(kind: 17, requestID: requestID, payload: Data([0x42, 0x00])))
    bytes.append(literalFrame(kind: 18, requestID: requestID, payload: Data()))
    return bytes
  }

  private func basicRequestMetadata(
    inputUTF16: UInt64,
    ordinal: UInt64 = 1
  ) -> Data {
    requestMetadata(
      ordinal: ordinal,
      inputUTF16: inputUTF16,
      scopeLocation: 0,
      scopeLength: 0,
      maxTextUTF16: max(inputUTF16, 10),
      maxOutputUTF16: 10,
      maxMatches: 10,
      cooperativeMilliseconds: 10,
      pattern: [0x61, 0x00],
      template: [],
      mode: 0,
      operation: 0,
      options: 1,
      hasScope: 0)
  }

  private func assertPoisoned(
    _ reader: SearchWireRequestReader,
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

  private func joined(_ chunks: [Data]) -> Data {
    chunks.reduce(into: Data()) { $0.append($1) }
  }

  private func frameKinds(in emissions: [Data]) -> [SearchWireKind] {
    emissions.compactMap { bytes in
      guard bytes.count == 32, bytes.starts(with: [0x50, 0x53, 0x52, 0x58]) else { return nil }
      let raw = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
      return SearchWireKind(rawValue: raw)
    }
  }

  private func requestMetadata(
    ordinal: UInt64,
    inputUTF16: UInt64,
    scopeLocation: UInt64,
    scopeLength: UInt64,
    maxTextUTF16: UInt64,
    maxOutputUTF16: UInt64,
    maxMatches: UInt32,
    cooperativeMilliseconds: UInt32,
    pattern: [UInt8],
    template: [UInt8],
    mode: UInt8,
    operation: UInt8,
    options: UInt8,
    hasScope: UInt8
  ) -> Data {
    var bytes = Data()
    append(ordinal, to: &bytes)
    append(inputUTF16, to: &bytes)
    append(scopeLocation, to: &bytes)
    append(scopeLength, to: &bytes)
    append(maxTextUTF16, to: &bytes)
    append(maxOutputUTF16, to: &bytes)
    append(maxMatches, to: &bytes)
    append(cooperativeMilliseconds, to: &bytes)
    append(UInt16(pattern.count / 2), to: &bytes)
    append(UInt16(template.count / 2), to: &bytes)
    bytes.append(contentsOf: [mode, operation, options, hasScope])
    bytes.append(contentsOf: pattern)
    bytes.append(contentsOf: template)
    return bytes
  }

  private func mutating(_ data: Data, at offset: Int, to byte: UInt8) -> Data {
    var result = data
    result[offset] = byte
    return result
  }

  private func overwrite(_ value: UInt32, in data: inout Data, at offset: Int) {
    for byteOffset in 0..<4 {
      data[offset + byteOffset] = UInt8(truncatingIfNeeded: value >> UInt32(byteOffset * 8))
    }
  }

  private func overwrite(_ value: UInt16, in data: inout Data, at offset: Int) {
    for byteOffset in 0..<2 {
      data[offset + byteOffset] = UInt8(truncatingIfNeeded: value >> UInt16(byteOffset * 8))
    }
  }

  private func overwrite(_ value: UInt64, in data: inout Data, at offset: Int) {
    for byteOffset in 0..<8 {
      data[offset + byteOffset] = UInt8(truncatingIfNeeded: value >> UInt64(byteOffset * 8))
    }
  }

  private func literalFrame(kind: UInt16, requestID: UUID, payload: Data) -> Data {
    var bytes = Data([0x50, 0x53, 0x52, 0x58, 1, 0])
    append(kind, to: &bytes)
    append(UInt64(payload.count), to: &bytes)
    bytes.append(contentsOf: uuidBytes(requestID))
    bytes.append(payload)
    return bytes
  }

  private func uuidBytes(_ uuid: UUID) -> [UInt8] {
    var tuple = uuid.uuid
    return withUnsafeBytes(of: &tuple) { Array($0) }
  }

  private func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  private func append(_ value: UInt32, to data: inout Data) {
    for offset in 0..<4 {
      data.append(UInt8(truncatingIfNeeded: value >> UInt32(offset * 8)))
    }
  }

  private func append(_ value: UInt64, to data: inout Data) {
    for offset in 0..<8 {
      data.append(UInt8(truncatingIfNeeded: value >> UInt64(offset * 8)))
    }
  }

  private func parentHello(
    generation: UUID? = nil,
    semanticVersion: UInt32 = 1,
    reserved: UInt32 = 0
  ) -> Data {
    var payload = Data(uuidBytes(generation ?? self.generation))
    append(semanticVersion, to: &payload)
    append(reserved, to: &payload)
    return literalFrame(kind: 1, requestID: zeroUUID, payload: payload)
  }

  private func consume(
    _ bytes: Data,
    with reader: SearchWireRequestReader,
    sink: SearchWireRequestSink
  ) throws {
    try bytes.withUnsafeBytes {
      try reader.consume($0, sink: sink)
    }
  }
}

private final class RecordingRequestSink: SearchWireRequestSink {
  var hellos: [UUID] = []
  var requests: [SearchWireRequest] = []
  var inputUTF8 = Data()
  var executions: [SearchWireIdentity] = []
  var onHello: (() throws -> Void)?
  var onBegin: ((SearchWireRequest) throws -> Void)?
  var onInput: ((Data) throws -> Void)?
  var onExecute: ((SearchWireIdentity) throws -> Void)?

  func helloAccepted(generation: UUID) throws {
    hellos.append(generation)
    try onHello?()
  }

  func begin(_ request: SearchWireRequest) throws {
    requests.append(request)
    try onBegin?(request)
  }

  func appendInputUTF8(_ bytes: Data) throws {
    inputUTF8.append(bytes)
    try onInput?(bytes)
  }

  func execute(_ identity: SearchWireIdentity) throws {
    executions.append(identity)
    try onExecute?(identity)
  }
}
