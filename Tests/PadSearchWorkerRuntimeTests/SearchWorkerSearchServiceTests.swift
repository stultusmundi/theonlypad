import Foundation
import PadCore
import SearchExecution
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerSearchServiceTests: XCTestCase {
  private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  private func request(
    _ text: String, pattern: String, mode: SearchMode = .literal,
    operation: SearchExecutionOperation = .find, scope: NSRange? = nil,
    caseSensitive: Bool = true, wholeWord: Bool = false,
    maxText: Int? = nil, maxMatches: Int = 20, maxOutput: Int = 100,
    milliseconds: UInt32 = 10_000
  ) throws -> SearchWireRequest {
    try SearchWireRequest(
      identity: SearchWireIdentity(
        generation: generation,
        requestID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, ordinal: 1),
      query: SearchQuery(
        pattern: pattern, mode: mode, caseSensitive: caseSensitive, wholeWord: wholeWord),
      operation: operation, inputUTF16: text.utf16.count, scope: scope,
      limits: SearchWireLimits(
        maxTextUTF16: maxText ?? text.utf16.count, maxOutputUTF16: maxOutput,
        maxMatches: maxMatches, cooperativeMilliseconds: milliseconds))
  }

  func testLiteralMetacharactersAndCaseOptions() throws {
    let text = "A.a a.a"
    let output = try FoundationSearchWorkerEngine().execute(
      request(text, pattern: "a.a", caseSensitive: false), text: text)
    XCTAssertEqual(
      output,
      SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)],
        replacement: nil))
  }

  func testRegexCapturesUseOneResultForRangesAndReplacement() throws {
    let output = try FoundationSearchWorkerEngine().execute(
      request("a a", pattern: "(a)", mode: .regex, operation: .replace(template: "$1!")),
      text: "a a")
    XCTAssertEqual(
      output,
      SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)],
        replacement: "a! a!"))
  }

  func testEscapedNULAndNewlineRemainLiteral() throws {
    let text = "a\0\na\0\n"
    let output = try FoundationSearchWorkerEngine().execute(
      request(text, pattern: "\\0\\n", mode: .escaped), text: text)
    XCTAssertEqual(
      output.matches, [NSRange(location: 1, length: 2), NSRange(location: 4, length: 2)])
    XCTAssertNil(output.replacement)
  }

  func testLiteralReplacementDoesNotExpandCaptureSyntax() throws {
    let output = try FoundationSearchWorkerEngine().execute(
      request("a", pattern: "a", operation: .replace(template: "$1\\n")), text: "a")
    XCTAssertEqual(output.replacement, "$1\\n")
  }

  func testOptionalCaptureExpandsAbsentGroupToEmpty() throws {
    let output = try FoundationSearchWorkerEngine().execute(
      request("b ab", pattern: "(a)?b", mode: .regex, operation: .replace(template: "<$1>")),
      text: "b ab")
    XCTAssertEqual(
      output,
      SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)],
        replacement: "<> <a>"))
  }

  func testZeroLengthEOFUsesUTF16Position() throws {
    let output = try FoundationSearchWorkerEngine().execute(
      request("😀", pattern: "$", mode: .regex, operation: .replace(template: "!")), text: "😀")
    XCTAssertEqual(
      output,
      SearchExecutionOutput(
        matches: [NSRange(location: 2, length: 0)], replacement: "😀!"))
  }

  func testEmojiExactTextAndOutputBoundary() throws {
    let text = "x😀x"
    let output = try FoundationSearchWorkerEngine().execute(
      request(text, pattern: "😀", operation: .replace(template: "💡"), maxText: 4, maxOutput: 4),
      text: text)
    XCTAssertEqual(
      output,
      SearchExecutionOutput(
        matches: [NSRange(location: 1, length: 2)], replacement: "x💡x"))
  }

  func testScalarSafeScopePreservesPrefixAndSuffix() throws {
    let text = "a😀a a"
    let output = try FoundationSearchWorkerEngine().execute(
      request(
        text, pattern: "a", operation: .replace(template: "!"),
        scope: NSRange(location: 3, length: 1)), text: text)
    XCTAssertEqual(
      output,
      SearchExecutionOutput(
        matches: [NSRange(location: 3, length: 1)], replacement: "a😀! a"))
  }

  func testSelectionDoesNotInventWordOrDocumentBoundaries() throws {
    let text = "cat"
    for query in [
      SearchQuery(pattern: "a", mode: .literal, wholeWord: true),
      SearchQuery(pattern: "^a$", mode: .regex),
    ] {
      let value = try request(
        text, pattern: query.pattern, mode: query.mode,
        scope: NSRange(location: 1, length: 1), wholeWord: query.wholeWord)
      XCTAssertEqual(try FoundationSearchWorkerEngine().execute(value, text: text).matches, [])
    }
  }

  func testSelectionRetainsTransparentLookbehind() throws {
    let text = "xa"
    let value = try request(
      text, pattern: "(?<=x)a", mode: .regex,
      scope: NSRange(location: 1, length: 1))
    XCTAssertEqual(
      try FoundationSearchWorkerEngine().execute(value, text: text).matches,
      [NSRange(location: 1, length: 1)])
  }

  func testExplicitMatchLimitIsNotServiceDefault() throws {
    try assertSemanticError(
      .matchLimit, code: 6,
      request("a a", pattern: "a", maxMatches: 1), text: "a a")
  }

  func testZeroMatchLimitAllowsNoMatchesButRejectsFirst() throws {
    let engine = FoundationSearchWorkerEngine()
    XCTAssertEqual(
      try engine.execute(request("a", pattern: "z", maxMatches: 0), text: "a").matches, [])
    try assertSemanticError(
      .matchLimit, code: 6,
      request("a", pattern: "a", maxMatches: 0), text: "a")
  }

  func testExplicitOutputLimitIsNotServiceDefault() throws {
    try assertSemanticError(
      .outputLimit, code: 7,
      request("a", pattern: "a", operation: .replace(template: "😀"), maxOutput: 1), text: "a")
  }

  func testZeroMatchReplacementStillAppliesOutputLimit() throws {
    try assertSemanticError(
      .outputLimit, code: 7,
      request("a", pattern: "z", operation: .replace(template: ""), maxOutput: 0), text: "a")
  }

  func testZeroCooperativeMillisecondsRemainZero() throws {
    try assertSemanticError(
      .timedOut, code: 9,
      request("a", pattern: "a", milliseconds: 0), text: "a")
  }

  func testInvalidEscapeTerminal() throws {
    try assertSemanticError(
      .invalidEscape, code: 2,
      request("a", pattern: "\\q", mode: .escaped), text: "a")
  }

  func testInvalidPatternTerminal() throws {
    try assertSemanticError(
      .invalidPattern, code: 3,
      request("a", pattern: "(", mode: .regex), text: "a")
  }

  func testInvalidReplacementTerminal() throws {
    try assertSemanticError(
      .invalidReplacement, code: 4,
      request("a", pattern: "(a)", mode: .regex, operation: .replace(template: "$2")), text: "a")
  }

  // Exercise the real adapter through the real runtime. Fixed terminal bytes are
  // an independent oracle; no direct Foundation internal-error seam is claimed.
  private func assertSemanticError(
    _ expected: SearchError, code: UInt8, _ request: SearchWireRequest, text: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    XCTAssertThrowsError(
      try FoundationSearchWorkerEngine().execute(request, text: text), file: file, line: line
    ) {
      XCTAssertEqual($0 as? SearchError, expected, file: file, line: line)
    }
    let channel = ServiceChannel([try wire(request, text: text)])
    let engine = CountingServiceEngine()
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { _ in ServiceAccumulator() }, engine: engine)
    XCTAssertEqual(runtime.run(), .cleanEOF, file: file, line: line)
    XCTAssertEqual(engine.calls, 1, file: file, line: line)
    let output = try frames(channel.output)
    XCTAssertEqual(output.map(\.kind), [.childHello, .terminal], file: file, line: line)
    let terminal = try XCTUnwrap(output.last, file: file, line: line)
    XCTAssertEqual(
      terminal.payload,
      Data([1, 0, 0, 0, 0, 0, 0, 0, code, 0, 0, 0, 0, 0, 0, 0]), file: file, line: line)
  }

  func testInputAboveExplicitLimitIsProtocolFailureBeforeEngine() throws {
    let value = try request("a", pattern: "a")
    var input = try frames(wire(value, text: "a"))
    var payload = input[1].payload
    payload[32] = 0  // maxTextUTF16=0 while declared inputUTF16=1.
    input[1] = try SearchWireFrame(
      kind: .requestStart, requestID: value.identity.requestID, payload: payload)
    try assertProtocolFailure(input)
    XCTAssertThrowsError(try request("a", pattern: "a", maxText: 0)) {
      XCTAssertEqual($0 as? SearchWireError, .invalidMetadata)
    }
  }

  func testScopeSplittingSurrogateIsProtocolFailureBeforeEngine() throws {
    let value = try request(
      "😀", pattern: ".", mode: .regex,
      scope: NSRange(location: 0, length: 2))
    var input = try frames(wire(value, text: "😀"))
    var payload = input[1].payload
    payload[16] = 1  // Same total extent, but starts inside the surrogate pair.
    payload[24] = 1
    input[1] = try SearchWireFrame(
      kind: .requestStart, requestID: value.identity.requestID, payload: payload)
    try assertProtocolFailure(input)
  }

  // Logical owner/autorelease-scope ordering only; this does not measure RSS
  // or prove release of Foundation's internal allocations.
  func testRealAdapterReleasesOwnerBeforeTerminalAndRefusalPreventsReuse() throws {
    for refusePayload in [false, true] {
      let value = try request(
        "a a", pattern: "(a)", mode: .regex,
        operation: .replace(template: "$1!"))
      let input = try wire(value, text: "a a")
      let channel = ServiceChannel(refusePayload ? [input, input] : [input])
      let engine = CountingServiceEngine()
      weak var owner: ServiceAccumulator?
      let decoder = SearchWireFrameDecoder()
      var completed: [SearchWireKind] = []
      var terminalHeaderSeen = false
      channel.onWrite = { bytes in
        if terminalHeaderSeen {
          XCTAssertNil(owner)
          if refusePayload { throw SearchError.engineFailure }
        }
        if bytes.count == 32 && Array(bytes.prefix(8)) == [80, 83, 82, 88, 1, 0, 35, 0] {
          XCTAssertNil(owner)
          XCTAssertEqual(completed.last, .replacementChunk)
          terminalHeaderSeen = true
        }
        try bytes.withUnsafeBytes {
          try decoder.consume($0) { frame in
            if frame.kind == .replacementChunk { XCTAssertNotNil(owner) }
            completed.append(frame.kind)
          }
        }
      }
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel,
        makeAccumulator: { _ in
          let value = ServiceAccumulator()
          owner = value
          return value
        }, engine: engine)
      XCTAssertEqual(runtime.run(), refusePayload ? .outputFailure : .cleanEOF)
      XCTAssertTrue(terminalHeaderSeen)
      XCTAssertNil(owner)
      XCTAssertEqual(engine.calls, 1)
      XCTAssertEqual(channel.reads, refusePayload ? 1 : 2)
      XCTAssertEqual(completed.last, refusePayload ? .replacementChunk : .terminal)
    }
  }

  private func assertProtocolFailure(_ frames: [SearchWireFrame]) throws {
    var bytes = Data()
    for frame in frames { try SearchWireFrameEncoder.write(frame) { bytes.append($0) } }
    let channel = ServiceChannel([bytes])
    let engine = CountingServiceEngine()
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { _ in ServiceAccumulator() }, engine: engine)
    XCTAssertEqual(runtime.run(), .protocolFailure)
    XCTAssertEqual(engine.calls, 0)
    XCTAssertTrue(channel.output.isEmpty)
  }

  private func wire(_ request: SearchWireRequest, text: String) throws -> Data {
    var data = Data()
    try SearchWireWriter.hello(generation: generation, fromChild: false) { data.append($0) }
    _ = try SearchWireWriter.request(request, text: text) { data.append($0) }
    return data
  }

  private func frames(_ bytes: Data) throws -> [SearchWireFrame] {
    let decoder = SearchWireFrameDecoder()
    var output: [SearchWireFrame] = []
    try bytes.withUnsafeBytes { try decoder.consume($0) { output.append($0) } }
    try decoder.finish()
    return output
  }
}

private final class ServiceAccumulator: SearchWorkerTextAccumulator {
  var bytes = Data()
  func appendUTF8(_ bytes: Data) { self.bytes.append(bytes) }
  func finish() -> String { String(decoding: bytes, as: UTF8.self) }
}

private final class CountingServiceEngine: SearchWorkerEngine {
  var calls = 0
  func execute(_ request: SearchWireRequest, text: String) throws -> SearchExecutionOutput {
    calls += 1
    return try FoundationSearchWorkerEngine().execute(request, text: text)
  }
}

private final class ServiceChannel: SearchWorkerBlockingChannel {
  var input: [Data]
  var output = Data()
  var reads = 0
  var onWrite: ((Data) throws -> Void)?
  init(_ input: [Data]) { self.input = input }
  func read(maxBytes: Int) -> Data {
    reads += 1
    return input.isEmpty ? Data() : input.removeFirst()
  }
  func write(_ bytes: Data) throws {
    try onWrite?(bytes)
    output.append(bytes)
  }
}
