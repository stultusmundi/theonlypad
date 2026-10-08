import Foundation
import PadCore
import SearchExecution
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerAccumulatorRuntimeTests: XCTestCase {
  private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  func testConcreteAccumulatorFeedsUnicodeLiteralFind() throws {
    let text = "x😀e\u{301}😀"
    let request = try request(text, pattern: "😀")
    let channel = AccumulatorRuntimeChannel([try wire(request, text: text)])
    XCTAssertEqual(try runtime(channel).run(), .cleanEOF)
    let result = try XCTUnwrap(decode(channel.output, requests: [(request, text)]).first)
    XCTAssertEqual(result.terminal, .success)
    XCTAssertEqual(
      result.ranges, [NSRange(location: 1, length: 2), NSRange(location: 5, length: 2)])
    XCTAssertNil(result.replacement)
  }

  func testConcreteAccumulatorFeedsUnicodeCaptureReplacement() throws {
    let text = "é猫 😀 é猫"
    let request = try request(
      text, pattern: "(é)(猫)", mode: .regex, operation: .replace(template: "$2:$1"))
    let channel = AccumulatorRuntimeChannel([try wire(request, text: text)])
    XCTAssertEqual(try runtime(channel).run(), .cleanEOF)
    let result = try XCTUnwrap(decode(channel.output, requests: [(request, text)]).first)
    XCTAssertEqual(result.terminal, .success)
    XCTAssertEqual(
      result.ranges, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
    XCTAssertEqual(result.replacement, "猫:é 😀 猫:é")
  }

  func testNoMatchReplacementPreservesBOMNULCombiningTextAndMixedEndings() throws {
    let text = "\u{FEFF}A\u{0}€e\u{301}\r\n😀\rB\n\u{FEFF}"
    let request = try request(text, pattern: "absent", operation: .replace(template: "unused"))
    let channel = AccumulatorRuntimeChannel([try wire(request, text: text)])
    XCTAssertEqual(try runtime(channel).run(), .cleanEOF)
    let result = try XCTUnwrap(decode(channel.output, requests: [(request, text)]).first)
    XCTAssertEqual(result.terminal, .success)
    XCTAssertEqual(result.ranges, [])
    let replacement = try XCTUnwrap(result.replacement)
    XCTAssertEqual(
      Array(replacement.utf16),
      [0xFEFF, 65, 0, 0x20AC, 101, 0x301, 13, 10, 0xD83D, 0xDE00, 13, 66, 10, 0xFEFF])
  }

  func testMalformedRegexTerminalAllowsNextHealthyRequest() throws {
    let first = try request("😀", pattern: "(", mode: .regex)
    let second = try request("a😀a", pattern: "a", ordinal: 2)
    let channel = AccumulatorRuntimeChannel([
      try wire(first, text: "😀"), try wire(second, text: "a😀a", hello: false),
    ])
    XCTAssertEqual(try runtime(channel).run(), .cleanEOF)
    let results = try decode(channel.output, requests: [(first, "😀"), (second, "a😀a")])
    XCTAssertEqual(results.count, 2)
    let failure = try XCTUnwrap(results.first)
    let success = try XCTUnwrap(results.last)
    XCTAssertEqual(failure.identity, first.identity)
    XCTAssertEqual(failure.terminal, .failure(.invalidPattern))
    XCTAssertEqual(failure.ranges, [])
    XCTAssertNil(failure.replacement)
    XCTAssertEqual(success.identity, second.identity)
    XCTAssertEqual(success.terminal, .success)
    XCTAssertEqual(
      success.ranges, [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)])
    XCTAssertNil(success.replacement)
  }

  func testEmptyDocumentCompletesWithEmptyReplacement() throws {
    let request = try request("", pattern: "x", operation: .replace(template: "y"))
    let channel = AccumulatorRuntimeChannel([try wire(request, text: "")])
    XCTAssertEqual(try runtime(channel).run(), .cleanEOF)
    let result = try XCTUnwrap(decode(channel.output, requests: [(request, "")]).first)
    XCTAssertEqual(result.terminal, .success)
    XCTAssertEqual(result.ranges, [])
    XCTAssertEqual(result.replacement, "")
  }

  func testSurrogateSplitAcrossWireFramesReachesConcreteAccumulatorIntact() throws {
    let request = try request("A😀B", pattern: "😀", operation: .replace(template: "💡"))
    let original = try frames(wire(request, text: "A😀B"))
    XCTAssertEqual(original.map(\.kind), [.parentHello, .requestStart, .inputChunk, .execute])
    let start = try XCTUnwrap(original.first(where: { $0.kind == .requestStart }))
    let hello = try XCTUnwrap(original.first)
    let execute = try XCTUnwrap(original.last)
    let high = try SearchWireFrame(
      kind: .inputChunk, requestID: request.identity.requestID,
      payload: Data([0x41, 0x00, 0x3D, 0xD8]))
    let low = try SearchWireFrame(
      kind: .inputChunk, requestID: request.identity.requestID,
      payload: Data([0x00, 0xDE, 0x42, 0x00]))
    let channel = AccumulatorRuntimeChannel([
      try encode([hello, start]), try encode([high]), try encode([low]), try encode([execute]),
    ])
    XCTAssertEqual(try runtime(channel).run(), .cleanEOF)
    let result = try XCTUnwrap(decode(channel.output, requests: [(request, "A😀B")]).first)
    XCTAssertEqual(result.terminal, .success)
    XCTAssertEqual(result.ranges, [NSRange(location: 1, length: 2)])
    XCTAssertEqual(result.replacement, "A💡B")
  }

  func testMalformedAndTruncatedWireNeverExecuteAccumulatedPrefix() throws {
    let request = try request("A😀B", pattern: "A")
    var malformed = try frames(wire(request, text: "A😀B"))
    let inputIndex = try XCTUnwrap(malformed.firstIndex(where: { $0.kind == .inputChunk }))
    malformed[inputIndex] = try SearchWireFrame(
      kind: .inputChunk, requestID: request.identity.requestID,
      payload: Data([0x41, 0x00, 0x00, 0xDC, 0x42, 0x00, 0x43, 0x00]))
    let truncated = Data(try wire(request, text: "A😀B").dropLast())
    for input in [try encode(malformed), truncated] {
      let channel = AccumulatorRuntimeChannel([input])
      let engine = AccumulatorRefusalEngineSpy()
      weak var owner: SearchWorkerUTF8Accumulator?
      var created = 0
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel,
        makeAccumulator: { count in
          created += 1
          let value = try SearchWorkerUTF8Accumulator(declaredUTF16: count)
          owner = value
          return value
        }, engine: engine)
      XCTAssertEqual(runtime.run(), .protocolFailure)
      XCTAssertEqual(created, 1)
      XCTAssertEqual(engine.calls, 0)
      XCTAssertNil(owner)
      XCTAssertTrue(try frames(channel.output).allSatisfy { $0.kind == .childHello })
    }
  }

  func testCoalescedTrailingRequestDiscardsProvisionalExecuteAndOwner() throws {
    let first = try request("a", pattern: "a")
    let second = try request("b", pattern: "b", ordinal: 2)
    let next = try wire(second, text: "b", hello: false)
    for trailing in [Data(next.prefix(3)), Data(next.prefix(32)), next] {
      let channel = AccumulatorRuntimeChannel([try wire(first, text: "a") + trailing])
      let engine = AccumulatorRefusalEngineSpy()
      weak var owner: SearchWorkerUTF8Accumulator?
      var created = 0
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel,
        makeAccumulator: { count in
          created += 1
          let value = try SearchWorkerUTF8Accumulator(declaredUTF16: count)
          owner = value
          return value
        }, engine: engine)
      XCTAssertEqual(runtime.run(), .protocolFailure)
      XCTAssertEqual(created, 1)
      XCTAssertEqual(engine.calls, 0)
      XCTAssertTrue(channel.output.isEmpty)
      XCTAssertNil(owner)
    }
  }

  // Weak owners prove logical lifetime only, not backing-storage release or RSS.
  func testSequentialConcreteOwnersEndBeforeTerminalAndNextRead() throws {
    let first = try request("a", pattern: "a", operation: .replace(template: "😀"))
    let second = try request("猫", pattern: "猫", ordinal: 2)
    let channel = AccumulatorRuntimeChannel([
      try wire(first, text: "a"), try wire(second, text: "猫", hello: false),
    ])
    weak var owner: SearchWorkerUTF8Accumulator?
    let decoder = SearchWireFrameDecoder()
    var terminalHeaders = 0
    var terminals = 0
    var created = 0
    channel.onWrite = { bytes in
      if bytes.count == 32 && Array(bytes.prefix(8)) == [80, 83, 82, 88, 1, 0, 35, 0] {
        terminalHeaders += 1
        XCTAssertNil(owner, "Request accumulator must leave scope before terminal header")
      }
      try bytes.withUnsafeBytes {
        try decoder.consume($0) { frame in
          if frame.kind == .replacementChunk {
            XCTAssertNotNil(
              owner, "This check must observe the concrete owner during response body")
          }
          if frame.kind == .terminal {
            XCTAssertNil(owner)
            terminals += 1
          }
        }
      }
    }
    channel.onRead = { read in
      if read > 1 {
        XCTAssertEqual(terminals, read - 1, "Next request read must follow a complete terminal")
        XCTAssertNil(owner)
      }
    }
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { count in
        XCTAssertNil(owner)
        XCTAssertEqual(terminals, created)
        created += 1
        let value = try SearchWorkerUTF8Accumulator(declaredUTF16: count)
        owner = value
        return value
      }, engine: FoundationSearchWorkerEngine())
    XCTAssertEqual(runtime.run(), .cleanEOF)
    try decoder.finish()
    XCTAssertEqual(created, 2)
    XCTAssertEqual(terminalHeaders, 2)
    XCTAssertEqual(terminals, 2)
    XCTAssertEqual(channel.reads, 3)
    XCTAssertNil(owner)
    let results = try decode(channel.output, requests: [(first, "a"), (second, "猫")])
    XCTAssertEqual(results.map(\.terminal), [.success, .success])
    XCTAssertEqual(
      results.map(\.ranges),
      [[NSRange(location: 0, length: 1)], [NSRange(location: 0, length: 1)]])
    XCTAssertEqual(results.map(\.replacement), ["😀", nil])
  }

  private func request(
    _ text: String, pattern: String, mode: SearchMode = .literal,
    operation: SearchExecutionOperation = .find, ordinal: UInt64 = 1
  ) throws -> SearchWireRequest {
    try SearchWireRequest(
      identity: SearchWireIdentity(
        generation: generation,
        requestID: UUID(
          uuidString: ordinal == 1
            ? "22222222-2222-2222-2222-222222222222" : "33333333-3333-3333-3333-333333333333")!,
        ordinal: ordinal),
      query: SearchQuery(pattern: pattern, mode: mode, caseSensitive: true),
      operation: operation, inputUTF16: text.utf16.count, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 100, maxOutputUTF16: 100, maxMatches: 20,
        cooperativeMilliseconds: 10_000))
  }

  private func wire(_ request: SearchWireRequest, text: String, hello: Bool = true) throws -> Data {
    var bytes = Data()
    if hello {
      try SearchWireWriter.hello(generation: generation, fromChild: false) { bytes.append($0) }
    }
    _ = try SearchWireWriter.request(request, text: text) { bytes.append($0) }
    return bytes
  }

  private func runtime(_ channel: AccumulatorRuntimeChannel) throws -> SearchWorkerRuntime {
    try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { try SearchWorkerUTF8Accumulator(declaredUTF16: $0) },
      engine: FoundationSearchWorkerEngine())
  }

  private func frames(_ bytes: Data) throws -> [SearchWireFrame] {
    let decoder = SearchWireFrameDecoder()
    var result: [SearchWireFrame] = []
    try bytes.withUnsafeBytes { try decoder.consume($0) { result.append($0) } }
    try decoder.finish()
    return result
  }

  private func encode(_ frames: [SearchWireFrame]) throws -> Data {
    var bytes = Data()
    for frame in frames { try SearchWireFrameEncoder.write(frame) { bytes.append($0) } }
    return bytes
  }

  private func decode(_ bytes: Data, requests: [(SearchWireRequest, String)]) throws
    -> [AccumulatorRuntimeResponse]
  {
    let reader = try SearchWireResponseReader(generation: generation)
    let sink = AccumulatorRuntimeResponseSink()
    var expecting = false
    var index = 0
    for frame in try frames(bytes) {
      if frame.kind != .childHello && !expecting {
        guard index < requests.count else { throw AccumulatorRuntimeFixtureError.unexpectedOutput }
        let (request, text) = requests[index]
        let boundaries = try SearchWireWriter.request(request, text: text) { _ in }
        try reader.expect(request, boundaries: boundaries)
        expecting = true
      }
      let encoded = try encode([frame])
      try encoded.withUnsafeBytes { try reader.consume($0, sink: sink) }
      if frame.kind == .terminal {
        expecting = false
        index += 1
      }
    }
    try reader.finish()
    XCTAssertEqual(sink.hellos, [generation])
    XCTAssertEqual(index, requests.count)
    XCTAssertEqual(sink.results.count, requests.count)
    return sink.results
  }
}

private enum AccumulatorRuntimeFixtureError: Error {
  case oversizedRead, unexpectedOutput, invalidUTF8
}

private final class AccumulatorRuntimeChannel: SearchWorkerBlockingChannel {
  private var input: [Data]
  private(set) var output = Data()
  private(set) var reads = 0
  var onRead: ((Int) -> Void)?
  var onWrite: ((Data) throws -> Void)?

  init(_ input: [Data]) { self.input = input }

  func read(maxBytes: Int) throws -> Data {
    reads += 1
    onRead?(reads)
    guard !input.isEmpty else { return Data() }
    let next = input.removeFirst()
    guard next.count <= maxBytes else { throw AccumulatorRuntimeFixtureError.oversizedRead }
    return next
  }

  func write(_ bytes: Data) throws {
    try onWrite?(bytes)
    output.append(bytes)
  }
}

private final class AccumulatorRefusalEngineSpy: SearchWorkerEngine {
  private(set) var calls = 0

  func execute(_ request: SearchWireRequest, text: String) throws -> SearchExecutionOutput {
    calls += 1
    return try FoundationSearchWorkerEngine().execute(request, text: text)
  }
}

private struct AccumulatorRuntimeResponse {
  let identity: SearchWireIdentity
  let terminal: SearchWireTerminal
  let ranges: [NSRange]
  let replacement: String?
}

private final class AccumulatorRuntimeResponseSink: SearchWireResponseSink {
  private(set) var hellos: [UUID] = []
  private(set) var results: [AccumulatorRuntimeResponse] = []
  private var ranges: [NSRange] = []
  private var replacement = Data()
  private var hasReplacement = false

  func helloAccepted(generation: UUID) { hellos.append(generation) }

  func begin(_ response: SearchWireResponse) {
    hasReplacement = response.replacementUTF16 != nil
  }

  func appendRanges(_ ranges: [NSRange]) { self.ranges.append(contentsOf: ranges) }

  func appendReplacementUTF8(_ bytes: Data) { replacement.append(bytes) }

  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    let text: String?
    if hasReplacement {
      let invalid = transcode(
        replacement.makeIterator(), from: UTF8.self, to: UTF16.self,
        stoppingOnError: true, into: { _ in })
      guard !invalid else { throw AccumulatorRuntimeFixtureError.invalidUTF8 }
      text = String(decoding: replacement, as: UTF8.self)
    } else {
      text = nil
    }
    results.append(
      AccumulatorRuntimeResponse(
        identity: identity, terminal: terminal, ranges: ranges, replacement: text))
    ranges.removeAll()
    replacement.removeAll()
    hasReplacement = false
  }
}
