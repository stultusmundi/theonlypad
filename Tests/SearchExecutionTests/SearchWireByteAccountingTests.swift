import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Counts actual writer emissions without retaining a wire stream. These small
/// controls validate measurement arithmetic, not allocation or process limits.
final class SearchWireByteAccountingTests: XCTestCase {
  func testBothGenerationHellosCost112Bytes() throws {
    var bytes = 0
    let generation = UUID()
    try SearchWireWriter.hello(generation: generation, fromChild: false) { bytes += $0.count }
    XCTAssertEqual(bytes, 56)
    try SearchWireWriter.hello(generation: generation, fromChild: true) { bytes += $0.count }
    XCTAssertEqual(bytes, 112)
  }

  func testEmptyFindAndReplacementHaveNoTextChunkFrames() throws {
    XCTAssertEqual(try emitted(text: "", replacement: nil), 242)
    XCTAssertEqual(try emitted(text: "", replacement: ""), 244)
  }

  func testSupplementaryAndCombiningTextAreChargedAsUTF16() throws {
    // Request: 4 units, response: 3 units, pattern/template: 3/2 units,
    // one 16-byte range and three 32-byte body-frame headers.
    XCTAssertEqual(
      try emitted(
        text: "B😀C", replacement: "A😀", pattern: "A😀", template: "e\u{301}",
        matches: [NSRange(location: 1, length: 2)]), 376)
  }

  func testInputAndReplacementFrameBoundariesAddExactlyOneHeader() throws {
    let exact = String(repeating: "a", count: 32_768)
    let over = exact + "b"
    XCTAssertEqual(try emitted(text: exact, replacement: nil), 65_810)
    XCTAssertEqual(try emitted(text: over, replacement: nil), 65_844)
    XCTAssertEqual(try emitted(text: "", replacement: exact), 65_812)
    XCTAssertEqual(try emitted(text: "", replacement: over), 65_846)
    // The surrogate pair crosses a wire chunk; framing still counts code units.
    let splitPair = String(repeating: "a", count: 32_767) + "😀"
    XCTAssertEqual(try emitted(text: splitPair, replacement: nil), 65_844)
  }

  func testRange4097AddsOneRangeAndOneFrameHeader() throws {
    let text = String(repeating: "a", count: 4_097)
    let ranges = (0..<4_097).map { NSRange(location: $0, length: 1) }
    XCTAssertEqual(
      try emitted(text: text, replacement: nil, matches: Array(ranges.prefix(4_096))), 74_036)
    XCTAssertEqual(try emitted(text: text, replacement: nil, matches: ranges), 74_084)
  }

  func testSemanticFailureEmitsTerminalWithoutSuccessBody() throws {
    // 96-byte requestStart + two pattern bytes + 32-byte input header +
    // eight UTF16 bytes + 32-byte execute + 48-byte failure terminal.
    XCTAssertEqual(
      try emitted(text: "B😀C", replacement: nil, failure: .invalidPattern), 218)
  }

  private func emitted(
    text: String, replacement: String?, pattern: String = "Z", template: String = "Ω",
    matches: [NSRange] = [], failure: SearchError? = nil
  ) throws -> Int {
    let identity = try SearchWireIdentity(generation: UUID(), requestID: UUID(), ordinal: 1)
    let request = try SearchWireRequest(
      identity: identity, query: SearchQuery(pattern: pattern, mode: .literal),
      operation: replacement == nil ? .find : .replace(template: template),
      inputUTF16: text.utf16.count, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 100_000_000, maxOutputUTF16: 100_000_000,
        maxMatches: 100_000, cooperativeMilliseconds: 1_000))
    var bytes = 0
    _ = try SearchWireWriter.request(request, text: text) { bytes += $0.count }
    if let failure {
      try SearchWireWriter.terminal(identity, result: .failure(failure)) { bytes += $0.count }
    } else {
      let response = try SearchWireResponse(
        identity: identity, matchCount: matches.count, replacementUTF16: replacement?.utf16.count)
      let output = SearchExecutionOutput(matches: matches, replacement: replacement)
      try SearchWireWriter.responseBody(response, output: output) { bytes += $0.count }
      try SearchWireWriter.terminal(identity, result: .success) { bytes += $0.count }
    }
    return bytes
  }
}
