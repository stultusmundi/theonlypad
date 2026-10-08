import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchParentResponseCodecTests: XCTestCase {
  // Break: factory/reader handoff loses actual source boundary metadata or find shape.
  func testRealFindOutputSurvivesSessionDiscard() async throws {
    var retained: SearchExecutionOutput?
    try await withCodec { fixture in
      let request = try fixture.request(text: "A😀B", scope: NSRange(location: 1, length: 2))
      let encoded = try await fixture.upload(request, text: "A😀B")
      XCTAssertEqual(encoded.inputUTF16, 4)
      XCTAssertEqual(encoded.identity, request.identity)
      let progress = try await fixture.consume(
        try fixture.success(
          request, matches: [NSRange(location: 1, length: 2)], replacement: nil))
      guard case .terminal(let terminal) = progress else {
        throw ParentResponseCodecFailure.expectedTerminal
      }
      XCTAssertEqual(terminal.identity, request.identity)
      XCTAssertEqual(terminal.terminal, .success)
      XCTAssertEqual(terminal.output?.matches, [NSRange(location: 1, length: 2)])
      XCTAssertNil(terminal.output?.replacement)
      retained = terminal.output
    }
    XCTAssertEqual(retained?.matches, [NSRange(location: 1, length: 2)])
    XCTAssertNil(retained?.replacement)
  }

  // Break: the production factory drops FEFF/NUL/decomposed text at actual codec cleanup.
  func testRealReplacementPreservesLiteralUnitsAfterCodecCleanup() async throws {
    var retained: String?
    try await withCodec { fixture in
      let request = try fixture.request(text: "A😀B", replace: true)
      _ = try await fixture.upload(request, text: "A😀B")
      let wire = try fixture.success(
        request, matches: [NSRange(location: 1, length: 2)],
        replacement: "\u{FEFF}A😀e\u{301}\0\r\n\r\n\u{FEFF}")
      let progress = try await fixture.consume(wire)
      guard case .terminal(let terminal) = progress else {
        throw ParentResponseCodecFailure.expectedTerminal
      }
      XCTAssertEqual(terminal.identity, request.identity)
      XCTAssertEqual(terminal.terminal, .success)
      XCTAssertEqual(terminal.output?.matches, [NSRange(location: 1, length: 2)])
      retained = terminal.output?.replacement
    }
    let text = try XCTUnwrap(retained)
    XCTAssertEqual(
      Array(text.utf16),
      [0xFEFF, 0x41, 0xD83D, 0xDE00, 0x65, 0x301, 0, 0x0D, 0x0A, 0x0D, 0x0A, 0xFEFF])
    XCTAssertEqual(
      Array(text.utf8),
      [
        0xEF, 0xBB, 0xBF, 0x41, 0xF0, 0x9F, 0x98, 0x80, 0x65, 0xCC, 0x81, 0, 0x0D, 0x0A, 0x0D, 0x0A,
        0xEF, 0xBB, 0xBF,
      ])
  }

  // Break: treating an actual wire-frame split surrogate as a malformed direct UTF8 chunk.
  func testFragmentedWireCarriesSurrogateAcrossRealReplacementFrames() async throws {
    try await withCodec { fixture in
      let request = try fixture.request(text: "x", replace: true)
      _ = try await fixture.upload(request, text: "x")
      let text = String(repeating: "a", count: 32_767) + "😀"
      let wire = try fixture.success(request, matches: [], replacement: text)
      let replacements = try fixture.frames(wire).filter { $0.kind == .replacementChunk }
      XCTAssertEqual(replacements.count, 2)
      guard replacements.count == 2 else { throw ParentResponseCodecFailure.missingBody }
      XCTAssertEqual(Array(replacements[0].payload.suffix(2)), [0x3D, 0xD8])
      XCTAssertEqual(Array(replacements[1].payload), [0x00, 0xDE])
      var last = SearchParentCodecProgress.needMore
      for start in stride(from: 0, to: wire.count, by: 257) {
        let end = min(start + 257, wire.count)
        last = try await fixture.consume(wire.subdata(in: start..<end))
        if end != wire.count { XCTAssertEqual(last, .needMore) }
      }
      guard case .terminal(let terminal) = last else {
        throw ParentResponseCodecFailure.expectedTerminal
      }
      XCTAssertEqual(terminal.identity, request.identity)
      XCTAssertEqual(terminal.terminal, .success)
      XCTAssertEqual(terminal.output?.matches, [])
      let output = try XCTUnwrap(terminal.output?.replacement)
      XCTAssertEqual(
        Array(output.utf16), [UInt16](repeating: 0x61, count: 32_767) + [0xD83D, 0xDE00])
    }
  }

  // Break: semantic failure requires responseStart or poisons the next fresh collector.
  func testSemanticTerminalWithoutBodyThenFreshNextOrdinal() async throws {
    try await withCodec { fixture in
      let first = try fixture.request(text: "A😀B")
      _ = try await fixture.upload(first, text: "A😀B")
      let failure = try await fixture.consume(
        try fixture.terminal(first.identity, .failure(.invalidPattern)))
      XCTAssertEqual(
        failure,
        .terminal(.init(identity: first.identity, terminal: .failure(.invalidPattern), output: nil))
      )
      let second = try fixture.request(text: "A😀B", ordinal: 2)
      _ = try await fixture.upload(second, text: "A😀B")
      let success = try await fixture.consume(
        try fixture.success(
          second, matches: [NSRange(location: 1, length: 2)], replacement: nil))
      XCTAssertEqual(
        success,
        .terminal(
          .init(
            identity: second.identity, terminal: .success,
            output: .init(matches: [NSRange(location: 1, length: 2)], replacement: nil))))
      XCTAssertEqual(second.identity.generation, first.identity.generation)
      XCTAssertNotEqual(second.identity.requestID, first.identity.requestID)
    }
  }

  // Break: a failure after partial ranges/text is overridden by completeness or leaks output.
  func testSemanticFailureAfterPartialBodyDiscardsPayloadAndAllowsNextRequest() async throws {
    for replacementStarted in [false, true] {
      try await withCodec { fixture in
        let first = try fixture.request(text: "A😀B", replace: true)
        _ = try await fixture.upload(first, text: "A😀B")
        let partial = try fixture.partialResponse(first, replacementStarted: replacementStarted)
        let partialProgress = try await fixture.consume(partial)
        XCTAssertEqual(partialProgress, .needMore)
        let failure = try await fixture.consume(
          try fixture.terminal(first.identity, .failure(.engineFailure)))
        XCTAssertEqual(
          failure,
          .terminal(
            .init(identity: first.identity, terminal: .failure(.engineFailure), output: nil)))
        let second = try fixture.request(text: "", replace: true, ordinal: 2)
        _ = try await fixture.upload(second, text: "")
        let empty = try await fixture.consume(
          try fixture.success(second, matches: [], replacement: ""))
        XCTAssertEqual(
          empty,
          .terminal(
            .init(
              identity: second.identity, terminal: .success,
              output: .init(matches: [], replacement: ""))))
      }
    }
  }

  // Break: collector-only arithmetic replaces the real source scalar-boundary index.
  func testActualSourceBoundaryRejectsRangeInsideSupplementaryScalar() async throws {
    try await withCodec { fixture in
      let request = try fixture.request(text: "A😀B")
      _ = try await fixture.upload(request, text: "A😀B")
      // The response writer has no source index and legitimately encodes this
      // arithmetic-valid range. The actual reader must reject its scalar endpoint.
      let wire = try fixture.success(
        request, matches: [NSRange(location: 2, length: 1)], replacement: nil)
      await assertError(.wire(.invalidRange)) { _ = try await fixture.consume(wire) }
      await assertError(.poisoned) { _ = try await fixture.consume(Data()) }
    }
  }

  // Break: exposing a completed output before the reader rejects trailing terminal junk.
  func testTrailingByteWithTerminalPoisonsInsteadOfReturningOutput() async throws {
    try await withCodec { fixture in
      let request = try fixture.request(text: "A😀B")
      _ = try await fixture.upload(request, text: "A😀B")
      let wire = try fixture.success(
        request, matches: [NSRange(location: 1, length: 2)], replacement: nil)
      await assertError(.wire(.invalidPhase)) { _ = try await fixture.consume(wire + Data([0])) }
      await assertError(.poisoned) { _ = try await fixture.consume(Data()) }
    }
  }

  // Break: replacing a legitimate empty String with nil at the production take boundary.
  func testEmptyReplacementIsSuccessfulOutputNotNil() async throws {
    try await withCodec { fixture in
      let request = try fixture.request(text: "", replace: true)
      _ = try await fixture.upload(request, text: "")
      let progress = try await fixture.consume(
        try fixture.success(request, matches: [], replacement: ""))
      XCTAssertEqual(
        progress,
        .terminal(
          .init(
            identity: request.identity, terminal: .success,
            output: .init(matches: [], replacement: ""))))
    }
  }

  private func withCodec(_ body: (ParentResponseCodecFixture) async throws -> Void) async throws {
    let fixture = try await ParentResponseCodecFixture.ready()
    var failure: Error?
    do { try await body(fixture) } catch { failure = error }
    do { try await fixture.stop() } catch {
      XCTFail("Actual codec lane cleanup failed: \(error)")
      if failure == nil { failure = error }
    }
    if let failure { throw failure }
  }
  private func assertError(
    _ expected: SearchParentCodecSessionError, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? SearchParentCodecSessionError, expected, file: file, line: line)
    }
  }
}

private enum ParentResponseCodecFailure: Error { case expectedTerminal, missingBody }

/// No fake codec, sink spy or production hook: factory instances and all codec
/// callbacks run on the actual retained production lane. The bridge sink only
/// retires outgoing bytes; this component suite does not launch a native child.
private final class ParentResponseCodecFixture: @unchecked Sendable {
  let generation = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
  let lane = SearchParentCodecLane()
  var session: SearchParentWireCodecSession!
  var writerEpoch: UInt64 = 1
  var token: SearchParentCodecToken {
    try! SearchParentCodecToken(
      generation: generation, sessionEpoch: 1,
      operationID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!)
  }
  static func ready() async throws -> ParentResponseCodecFixture {
    let fixture = ParentResponseCodecFixture()
    do {
      fixture.session = try await fixture.run {
        try SearchParentWireCodecSession(token: fixture.token) {
          SearchParentResponseAccumulator(request: $0)
        }
      }
      let bridge = SearchParentWireUploadBridge(
        identity: try SearchParentWriterIdentity(
          generation: fixture.generation, requestID: nil, writerEpoch: 1))
      try await fixture.produce(bridge) {
        try fixture.session.writeHello(token: fixture.token, bridge: bridge)
      }
      var hello = Data()
      try SearchWireWriter.hello(generation: fixture.generation, fromChild: true) {
        hello.append($0)
      }
      let accepted = try await fixture.consume(hello)
      guard accepted == .hello(fixture.generation) else {
        throw ParentResponseCodecFailure.expectedTerminal
      }
      return fixture
    } catch {
      try await fixture.stop()
      throw error
    }
  }
  func request(text: String, replace: Bool = false, scope: NSRange? = nil, ordinal: UInt64 = 1)
    throws -> SearchWireRequest
  {
    try SearchWireRequest(
      identity: SearchWireIdentity(
        generation: generation,
        requestID: UUID(
          uuidString: ordinal == 1
            ? "77777777-7777-7777-7777-777777777777" : "88888888-8888-8888-8888-888888888888")!,
        ordinal: ordinal),
      query: SearchQuery(pattern: "😀", mode: .literal),
      operation: replace ? .replace(template: "x") : .find,
      inputUTF16: text.utf16.count, scope: scope,
      limits: SearchWireLimits(
        maxTextUTF16: 100_000, maxOutputUTF16: 100_000, maxMatches: 16,
        cooperativeMilliseconds: 1_000))
  }
  func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let work = try lane.submit(token: token, body)
    return try await work.value()
  }
  func produce<T>(
    _ bridge: SearchParentWireUploadBridge, _ body: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let consumer = Task { try await bridge.consume { _ in } }
    let result: Result<T, Error>
    do { result = .success(try await run(body)) } catch { result = .failure(error) }
    bridge.producerExited(result.map { _ in () })
    do { try await consumer.value } catch { if case .success = result { throw error } }
    return try result.get()
  }
  func upload(_ request: SearchWireRequest, text: String) async throws -> SearchParentRequestEncoded
  {
    writerEpoch += 1
    let bridge = SearchParentWireUploadBridge(
      identity: try SearchParentWriterIdentity(
        generation: generation, requestID: request.identity.requestID, writerEpoch: writerEpoch))
    let encoded = try await produce(bridge) {
      try self.session.writeRequest(token: self.token, request: request, text: text, bridge: bridge)
    }
    try await run { try self.session.expect(token: self.token, identity: request.identity) }
    return encoded
  }
  func consume(_ bytes: Data) async throws -> SearchParentCodecProgress {
    try await run { try self.session.consume(token: self.token, bytes: bytes) }
  }
  func body(_ request: SearchWireRequest, matches: [NSRange], replacement: String?) throws -> Data {
    let response = try SearchWireResponse(
      identity: request.identity, matchCount: matches.count,
      replacementUTF16: replacement?.utf16.count)
    var wire = Data()
    try SearchWireWriter.responseBody(
      response, output: .init(matches: matches, replacement: replacement)
    ) { wire.append($0) }
    return wire
  }
  func terminal(_ identity: SearchWireIdentity, _ terminal: SearchWireTerminal) throws -> Data {
    var wire = Data()
    try SearchWireWriter.terminal(identity, result: terminal) { wire.append($0) }
    return wire
  }
  func success(_ request: SearchWireRequest, matches: [NSRange], replacement: String?) throws
    -> Data
  {
    try body(request, matches: matches, replacement: replacement)
      + terminal(request.identity, .success)
  }
  func frames(_ wire: Data) throws -> [SearchWireFrame] {
    let reader = SearchWireFrameDecoder()
    var result: [SearchWireFrame] = []
    for start in stride(from: 0, to: wire.count, by: 4096) {
      try wire.subdata(in: start..<min(start + 4096, wire.count)).withUnsafeBytes {
        try reader.consume($0) { result.append($0) }
      }
    }
    try reader.finish()
    return result
  }
  func partialResponse(_ request: SearchWireRequest, replacementStarted: Bool) throws -> Data {
    let matches =
      replacementStarted
      ? [NSRange(location: 1, length: 2)]
      : [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)]
    let full = try frames(body(request, matches: matches, replacement: "A😀B"))
    var prefix = Data()
    for frame in full {
      if frame.kind == .responseStart {
        try SearchWireFrameEncoder.write(frame) { prefix.append($0) }
      } else if frame.kind == .rangeChunk {
        // Whole-body writer correctly forbids mismatched advertised/output
        // counts. A valid partial frame is needed to test failure before completion.
        let payload = replacementStarted ? frame.payload : Data(frame.payload.prefix(16))
        let partial = try SearchWireFrame(
          kind: .rangeChunk, requestID: request.identity.requestID, payload: payload)
        try SearchWireFrameEncoder.write(partial) { prefix.append($0) }
      } else if frame.kind == .replacementChunk, replacementStarted {
        // Exactly one complete 'A' unit under the advertised four-unit output.
        let partial = try SearchWireFrame(
          kind: .replacementChunk, requestID: request.identity.requestID, payload: Data([0x41, 0]))
        try SearchWireFrameEncoder.write(partial) { prefix.append($0) }
      }
    }
    guard !prefix.isEmpty else { throw ParentResponseCodecFailure.missingBody }
    return prefix
  }
  func stop() async throws {
    var failure: Error?
    if session != nil {
      do { try await run { try self.session.discard(token: self.token) } } catch { failure = error }
    }
    lane.requestStop()
    try await lane.waitForStop()
    if let failure { throw failure }
  }
}
