import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchWirePartialHeaderTests: XCTestCase {
  private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private let requestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

  func testBufferedCountIncludesParsedHeaderAcrossEveryIncompletePrefix() throws {
    let frame = literalFrame(kind: 17, payload: Data([65, 0]))
    for split in 1..<frame.count {
      let decoder = SearchWireFrameDecoder()
      var frames = 0
      try Data(frame.prefix(split)).withUnsafeBytes {
        try decoder.consume($0) { _ in frames += 1 }
      }
      XCTAssertEqual(decoder.bufferedByteCount, split, "prefix \(split)")
      XCTAssertEqual(frames, 0)
      try Data(frame.dropFirst(split)).withUnsafeBytes {
        try decoder.consume($0) { decoded in
          frames += 1
          XCTAssertEqual(decoded.payload, Data([65, 0]))
        }
      }
      XCTAssertEqual(frames, 1)
      XCTAssertEqual(decoder.bufferedByteCount, 0)
      try decoder.finish()
    }
  }

  func testHeaderOnlyFrameRemainsIncompleteAtFinish() throws {
    let decoder = SearchWireFrameDecoder()
    let header = Data(literalFrame(kind: 17, payload: Data([65, 0])).prefix(32))
    try header.withUnsafeBytes {
      try decoder.consume($0) { _ in XCTFail("Incomplete frame emitted") }
    }
    XCTAssertEqual(decoder.bufferedByteCount, 32)
    XCTAssertThrowsError(try decoder.finish()) {
      XCTAssertEqual($0 as? SearchWireError, .truncated)
    }
    XCTAssertThrowsError(try decoder.finish()) { XCTAssertEqual($0 as? SearchWireError, .poisoned) }
  }

  func testChildHelloRejectsEveryPartialTrailingTerminal() throws {
    let suffix = literalFrame(kind: 35, payload: Data(repeating: 0, count: 16))
    for count in 1..<suffix.count {
      let reader = try SearchWireResponseReader(generation: generation)
      let sink = HeaderResponseSink()
      var bytes = try hello(child: true)
      bytes.append(suffix.prefix(count))
      XCTAssertThrowsError(
        try bytes.withUnsafeBytes { try reader.consume($0, sink: sink) }, "suffix \(count)"
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
      }
      // A provisional callback never authorizes handoff after a throw.
      XCTAssertEqual(sink.hellos, 1)
      XCTAssertEqual(sink.completions, 0)
      XCTAssertThrowsError(try reader.finish()) {
        XCTAssertEqual($0 as? SearchWireError, .poisoned)
      }
    }
  }

  func testSuccessTerminalRejectsEveryPartialTrailingTerminalBeforeCompletion() throws {
    try assertTerminalSuffixRejected(.success)
  }

  func testSemanticTerminalRejectsEveryPartialTrailingTerminalBeforeCompletion() throws {
    try assertTerminalSuffixRejected(.failure(.engineFailure))
  }

  func testExecuteRejectsEveryPartialTrailingFrame() throws {
    let suffix = literalFrame(kind: 17, payload: Data([65, 0]))
    for count in 1..<suffix.count {
      let reader = try SearchWireRequestReader(generation: generation)
      let sink = HeaderRequestSink()
      let parentHello = try hello(child: false)
      try parentHello.withUnsafeBytes { try reader.consume($0, sink: sink) }
      var bytes = Data()
      _ = try SearchWireWriter.request(request(), text: "x") { bytes.append($0) }
      bytes.append(suffix.prefix(count))
      XCTAssertThrowsError(
        try bytes.withUnsafeBytes { try reader.consume($0, sink: sink) }, "suffix \(count)"
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
      }
      XCTAssertEqual(sink.executions, 1)  // Execute is provisional until the outer consume returns.
      XCTAssertThrowsError(try reader.acknowledgeTerminal(request().identity)) {
        XCTAssertEqual($0 as? SearchWireError, .poisoned)
      }
    }
  }

  func testActiveResponseAcceptsHeaderOnlyThenFragmentedBody() throws {
    let request = try request()
    let reader = try SearchWireResponseReader(generation: generation)
    let sink = HeaderResponseSink()
    let childHello = try hello(child: true)
    try childHello.withUnsafeBytes { try reader.consume($0, sink: sink) }
    let boundaries = try SearchWireWriter.request(request, text: "x") { _ in }
    try reader.expect(request, boundaries: boundaries)
    var chunks: [Data] = []
    try SearchWireWriter.responseBody(
      SearchWireResponse(identity: request.identity, matchCount: 0, replacementUTF16: nil),
      output: SearchExecutionOutput(matches: [], replacement: nil)
    ) { chunks.append($0) }
    try SearchWireWriter.terminal(request.identity, result: .success) { chunks.append($0) }
    XCTAssertEqual(chunks.map(\.count), [32, 32, 32, 16])
    for chunk in chunks {
      try chunk.withUnsafeBytes { try reader.consume($0, sink: sink) }
    }
    XCTAssertEqual(sink.completions, 1)
    try reader.finish()
  }

  func testRequestHelloAndActiveBodyAcceptValidFragmentation() throws {
    let reader = try SearchWireRequestReader(generation: generation)
    let sink = HeaderRequestSink()
    var chunks: [Data] = []
    _ = try SearchWireWriter.request(request(), text: "x") { chunks.append($0) }
    XCTAssertEqual(chunks.first?.count, 32)
    // A request header following parentHello is legal while awaiting a request.
    var beginning = try hello(child: false)
    beginning.append(chunks.removeFirst())
    try beginning.withUnsafeBytes { try reader.consume($0, sink: sink) }
    XCTAssertEqual(sink.executions, 0)
    for chunk in chunks {
      try chunk.withUnsafeBytes { try reader.consume($0, sink: sink) }
    }
    XCTAssertEqual(sink.executions, 1)
    try reader.acknowledgeTerminal(request().identity)
    try reader.finish()
  }

  private func assertTerminalSuffixRejected(_ terminal: SearchWireTerminal) throws {
    let request = try request()
    let suffix = literalFrame(kind: 35, payload: Data(repeating: 0, count: 16))
    for count in 1..<suffix.count {
      let reader = try SearchWireResponseReader(generation: generation)
      let sink = HeaderResponseSink()
      let childHello = try hello(child: true)
      try childHello.withUnsafeBytes { try reader.consume($0, sink: sink) }
      let boundaries = try SearchWireWriter.request(request, text: "x") { _ in }
      try reader.expect(request, boundaries: boundaries)
      var bytes = Data()
      if terminal == .success {
        try SearchWireWriter.responseBody(
          SearchWireResponse(identity: request.identity, matchCount: 0, replacementUTF16: nil),
          output: SearchExecutionOutput(matches: [], replacement: nil)
        ) { bytes.append($0) }
      }
      try SearchWireWriter.terminal(request.identity, result: terminal) { bytes.append($0) }
      bytes.append(suffix.prefix(count))
      XCTAssertThrowsError(
        try bytes.withUnsafeBytes { try reader.consume($0, sink: sink) }, "suffix \(count)"
      ) {
        XCTAssertEqual($0 as? SearchWireError, .invalidPhase)
      }
      XCTAssertEqual(sink.completions, 0, "suffix \(count) published a provisional terminal")
      XCTAssertThrowsError(try reader.finish()) {
        XCTAssertEqual($0 as? SearchWireError, .poisoned)
      }
    }
  }

  private func request() throws -> SearchWireRequest {
    try SearchWireRequest(
      identity: SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 1),
      query: SearchQuery(pattern: "x", mode: .literal), operation: .find,
      inputUTF16: 1, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 8, cooperativeMilliseconds: 1))
  }

  private func hello(child: Bool) throws -> Data {
    var bytes = Data()
    try SearchWireWriter.hello(generation: generation, fromChild: child) { bytes.append($0) }
    return bytes
  }

  private func literalFrame(kind: UInt16, payload: Data) -> Data {
    var bytes = Data([0x50, 0x53, 0x52, 0x58, 1, 0, UInt8(kind), UInt8(kind >> 8)])
    for offset in 0..<8 {
      bytes.append(UInt8(truncatingIfNeeded: UInt64(payload.count) >> (offset * 8)))
    }
    var uuid = requestID.uuid
    withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
    bytes.append(payload)
    return bytes
  }
}

private final class HeaderResponseSink: SearchWireResponseSink {
  var hellos = 0
  var completions = 0
  func helloAccepted(generation: UUID) { hellos += 1 }
  func begin(_ response: SearchWireResponse) {}
  func appendRanges(_ ranges: [NSRange]) {}
  func appendReplacementUTF8(_ bytes: Data) {}
  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) { completions += 1 }
}
private final class HeaderRequestSink: SearchWireRequestSink {
  var executions = 0
  func helloAccepted(generation: UUID) {}
  func begin(_ request: SearchWireRequest) {}
  func appendInputUTF8(_ bytes: Data) {}
  func execute(_ identity: SearchWireIdentity) { executions += 1 }
}
