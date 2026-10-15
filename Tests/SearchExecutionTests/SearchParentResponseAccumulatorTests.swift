import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchParentResponseAccumulatorTests: XCTestCase {
  private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private let requestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

  // Break: rejecting adjacent/zero matches or manufacturing replacement text for find.
  func testFindPreservesOrderedAdjacentAndZeroLengthRanges() throws {
    let request = try request(input: 8)
    let collector = SearchParentResponseAccumulator(request: request)
    try collector.begin(response(request, count: 4))
    try collector.appendRanges([NSRange(location: 0, length: 1), NSRange(location: 1, length: 2)])
    try collector.appendRanges([])
    try collector.appendRanges([NSRange(location: 3, length: 0), NSRange(location: 4, length: 1)])
    try collector.complete(request.identity, terminal: .success)
    let result = try collector.takeTerminal(for: request.identity)
    XCTAssertEqual(result.terminal, .success)
    XCTAssertEqual(
      result.output?.matches,
      [
        NSRange(location: 0, length: 1), NSRange(location: 1, length: 2),
        NSRange(location: 3, length: 0), NSRange(location: 4, length: 1),
      ])
    XCTAssertNil(result.output?.replacement)
    collector.discard()
    XCTAssertEqual(result.output?.matches.count, 4)
  }

  // Break: confusing a successful empty replacement with nil/no response.
  func testZeroMatchFindAndEmptyReplacementRemainDistinct() throws {
    for replace in [false, true] {
      let request = try request(replace: replace)
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(response(request, count: 0, replacement: replace ? 0 : nil))
      try collector.appendRanges([])
      if replace { try collector.appendReplacementUTF8(Data()) }
      try collector.complete(request.identity, terminal: .success)
      let result = try collector.takeTerminal(for: request.identity)
      XCTAssertEqual(result.terminal, .success)
      XCTAssertEqual(result.output?.matches, [])
      if replace {
        XCTAssertEqual(result.output?.replacement, "")
      } else {
        XCTAssertNil(result.output?.replacement)
      }
    }
  }

  // Break: BOM removal, repair, normalization or newline conversion changes literal units.
  func testNineteenBytesPreserveTwelveLiteralUTF16Units() throws {
    let request = try request(replace: true)
    let collector = SearchParentResponseAccumulator(request: request)
    let bytes = Data([
      0xEF, 0xBB, 0xBF, 0x41, 0xF0, 0x9F, 0x98, 0x80, 0x65, 0xCC, 0x81, 0, 0x0D, 0x0A, 0x0D, 0x0A,
      0xEF, 0xBB, 0xBF,
    ])
    try collector.begin(response(request, count: 0, replacement: 12))
    try collector.appendReplacementUTF8(bytes)
    try collector.complete(request.identity, terminal: .success)
    let text = try XCTUnwrap(collector.takeTerminal(for: request.identity).output?.replacement)
    XCTAssertEqual(
      Array(text.utf16),
      [0xFEFF, 0x41, 0xD83D, 0xDE00, 0x65, 0x301, 0, 0x0D, 0x0A, 0x0D, 0x0A, 0xFEFF])
    XCTAssertEqual(
      Array(text.utf8),
      [
        0xEF, 0xBB, 0xBF, 0x41, 0xF0, 0x9F, 0x98, 0x80, 0x65, 0xCC, 0x81, 0, 0x0D, 0x0A, 0x0D, 0x0A,
        0xEF, 0xBB, 0xBF,
      ])
    XCTAssertEqual(text.utf16.count, 12)
    XCTAssertEqual(text.utf8.count, 19)
  }

  // Break: imposing the append limit on the whole accumulated result rejects two legal chunks.
  func testMaximumChunksAndLargerWholeOutputAreAccepted() throws {
    let request = try request(replace: true, outputLimit: 131_072)
    let collector = SearchParentResponseAccumulator(request: request)
    try collector.begin(response(request, count: 0, replacement: 131_072))
    try collector.appendReplacementUTF8(Data(repeating: 0x41, count: 65_536))
    try collector.appendReplacementUTF8(Data(repeating: 0x42, count: 65_536))
    try collector.complete(request.identity, terminal: .success)
    let text = try XCTUnwrap(collector.takeTerminal(for: request.identity).output?.replacement)
    XCTAssertEqual(
      Array(text.utf16),
      [UInt16](repeating: 0x41, count: 65_536) + [UInt16](repeating: 0x42, count: 65_536))
  }

  // Break: accepting a chunk one byte above the transport contract.
  func testOversizedChunkRefusesAndPoisons() throws {
    let request = try request(replace: true, outputLimit: 65_537)
    let collector = SearchParentResponseAccumulator(request: request)
    try collector.begin(response(request, count: 0, replacement: 65_537))
    assertError(.invalidChunk) {
      try collector.appendReplacementUTF8(Data(repeating: 0x41, count: 65_537))
    }
    assertPoisoned(collector, request)
  }

  // Break: allowing early completion under a large advertised output length.
  func testTinyAppendUnderMaximumDeclarationStillRequiresExactCompletion() throws {
    let request = try request(replace: true, outputLimit: 100_000_000)
    let collector = SearchParentResponseAccumulator(request: request)
    try collector.begin(response(request, count: 0, replacement: 100_000_000))
    try collector.appendReplacementUTF8(Data([0x41]))
    assertError(.lengthMismatch) { try collector.complete(request.identity, terminal: .success) }
    assertPoisoned(collector, request)
    // This checks content admission/completeness, not allocation or RSS.
  }

  // Break: indexing a Data slice from zero corrupts a valid supplementary scalar.
  func testNonzeroIndexSlicePreservesSupplementaryScalar() throws {
    let request = try request(replace: true)
    let collector = SearchParentResponseAccumulator(request: request)
    let padded = Data([0x41, 0xF0, 0x9F, 0x98, 0x80, 0x42])
    let slice = padded[1..<5]
    XCTAssertEqual(slice.startIndex, 1)
    try collector.begin(response(request, count: 0, replacement: 2))
    try collector.appendReplacementUTF8(slice)
    try collector.complete(request.identity, terminal: .success)
    let text = try XCTUnwrap(collector.takeTerminal(for: request.identity).output?.replacement)
    XCTAssertEqual(Array(text.utf16), [0xD83D, 0xDE00])
  }

  // Break: repairing malformed UTF8 instead of refusing it before storage.
  func testMalformedUTF8VariantsRefuseBeforeLengthAccounting() throws {
    let malformed: [[UInt8]] = [
      [0x80], [0xC0, 0xAF], [0xE0, 0x80, 0xAF], [0xED, 0xA0, 0x80],
      [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFF],
      [0xC2], [0xE2, 0x82], [0xF0, 0x9F, 0x98], [0xE2, 0x28, 0xA1],
    ]
    for bytes in malformed {
      let request = try request(replace: true)
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(response(request, count: 0, replacement: 0))
      assertError(.invalidChunk) { try collector.appendReplacementUTF8(Data(bytes)) }
      assertPoisoned(collector, request)
    }
  }

  // Break: retaining a partial UTF8 scalar across direct sink calls (wire carry is upstream).
  func testSplitUTF8ScalarDoesNotBecomeAnImplicitStreamingDecoder() throws {
    let request = try request(replace: true)
    let collector = SearchParentResponseAccumulator(request: request)
    try collector.begin(response(request, count: 0, replacement: 2))
    assertError(.invalidChunk) { try collector.appendReplacementUTF8(Data([0xF0, 0x9F])) }
    assertError(.poisoned) { try collector.appendReplacementUTF8(Data([0x98, 0x80])) }
    assertPoisoned(collector, request)
  }

  // Break: counting UTF8 bytes as UTF16 units or admitting more than the declared content.
  func testUTF16OverrunAndExactThreeByteBound() throws {
    let request = try request(replace: true)
    let valid = SearchParentResponseAccumulator(request: request)
    try valid.begin(response(request, count: 0, replacement: 1))
    try valid.appendReplacementUTF8(Data([0xE2, 0x82, 0xAC]))
    try valid.complete(request.identity, terminal: .success)
    XCTAssertEqual(
      Array(try XCTUnwrap(valid.takeTerminal(for: request.identity).output?.replacement).utf16),
      [0x20AC])
    for bytes in [[UInt8](arrayLiteral: 0x41, 0x42), [0xF0, 0x9F, 0x98, 0x80]] {
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(response(request, count: 0, replacement: 1))
      assertError(.lengthMismatch) { try collector.appendReplacementUTF8(Data(bytes)) }
      assertPoisoned(collector, request)
    }
    let cumulative = SearchParentResponseAccumulator(request: request)
    try cumulative.begin(response(request, count: 0, replacement: 2))
    try cumulative.appendReplacementUTF8(Data([0x41]))
    assertError(.lengthMismatch) {
      try cumulative.appendReplacementUTF8(Data([0xF0, 0x9F, 0x98, 0x80]))
    }
    assertPoisoned(cumulative, request)
  }

  // Break: successful completion with incomplete declared ranges or replacement units.
  func testIncompleteSuccessRefusesBothRangeAndReplacementDeficits() throws {
    let find = try request()
    let missingRange = SearchParentResponseAccumulator(request: find)
    try missingRange.begin(response(find, count: 1))
    assertError(.lengthMismatch) { try missingRange.complete(find.identity, terminal: .success) }
    assertPoisoned(missingRange, find)
    let replace = try request(replace: true)
    let missingText = SearchParentResponseAccumulator(request: replace)
    try missingText.begin(response(replace, count: 0, replacement: 2))
    try missingText.appendReplacementUTF8(Data([0x41]))
    assertError(.lengthMismatch) { try missingText.complete(replace.identity, terminal: .success) }
    assertPoisoned(missingText, replace)
  }

  // Break: overflowing or negative NSRange endpoints escape subtraction-based admission.
  func testNegativeOverflowAndBeyondInputRangesAreRefused() throws {
    let invalid = [
      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
      NSRange(location: Int.max, length: 1), NSRange(location: 1, length: Int.max),
      NSRange(location: 5, length: 0), NSRange(location: 3, length: 2),
    ]
    for range in invalid {
      let request = try request()
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(response(request, count: 1))
      assertError(.invalidRange) { try collector.appendRanges([range]) }
      assertPoisoned(collector, request)
    }
  }

  // Break: accepting a valid-input range outside the narrower request scope.
  func testScopeEndpointsUseValidatedSubtractiveBounds() throws {
    let request = try request(input: 8, scope: NSRange(location: 2, length: 3))
    for range in [
      NSRange(location: 1, length: 1), NSRange(location: 5, length: 1),
      NSRange(location: 6, length: 0),
    ] {
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(response(request, count: 1))
      assertError(.invalidRange) { try collector.appendRanges([range]) }
    }
    let valid = SearchParentResponseAccumulator(request: request)
    try valid.begin(response(request, count: 2))
    try valid.appendRanges([NSRange(location: 2, length: 3), NSRange(location: 5, length: 0)])
    try valid.complete(request.identity, terminal: .success)
    XCTAssertEqual(
      try valid.takeTerminal(for: request.identity).output?.matches,
      [NSRange(location: 2, length: 3), NSRange(location: 5, length: 0)])
  }

  // Break: losing the previous range across batches or allowing duplicate zero matches.
  func testOrderOverlapAndDuplicateZeroAreRejectedAcrossBatches() throws {
    let pairs = [
      [NSRange(location: 1, length: 2), NSRange(location: 2, length: 1)],
      [NSRange(location: 2, length: 0), NSRange(location: 1, length: 0)],
      [NSRange(location: 2, length: 0), NSRange(location: 2, length: 0)],
      [NSRange(location: 2, length: 0), NSRange(location: 2, length: 1)],
    ]
    for pair in pairs {
      for split in [false, true] {
        let request = try request()
        let collector = SearchParentResponseAccumulator(request: request)
        try collector.begin(response(request, count: 2))
        if split { try collector.appendRanges([pair[0]]) }
        assertError(.invalidRange) { try collector.appendRanges(split ? [pair[1]] : pair) }
        assertPoisoned(collector, request)
      }
    }
  }

  // Break: checking individual ranges before advertised count, or returning a partial batch.
  func testCountPrecedesRangeValidationAndBadBatchPoisonsAllPayload() throws {
    let request = try request()
    let full = SearchParentResponseAccumulator(request: request)
    try full.begin(response(request, count: 0))
    assertError(.lengthMismatch) { try full.appendRanges([NSRange(location: -1, length: 0)]) }
    assertPoisoned(full, request)
    let cumulative = SearchParentResponseAccumulator(request: request)
    try cumulative.begin(response(request, count: 1))
    try cumulative.appendRanges([NSRange(location: 0, length: 1)])
    assertError(.lengthMismatch) { try cumulative.appendRanges([NSRange(location: 1, length: 1)]) }
    assertPoisoned(cumulative, request)
    let batch = SearchParentResponseAccumulator(request: request)
    try batch.begin(response(request, count: 3))
    try batch.appendRanges([NSRange(location: 0, length: 1)])
    assertError(.invalidRange) {
      try batch.appendRanges([
        NSRange(location: 1, length: 1), NSRange(location: Int.max, length: 1),
      ])
    }
    assertPoisoned(batch, request)
  }

  // Break: trusting global response bounds instead of the narrower request/operation shape.
  func testBeginChecksShapeAndRequestCeilings() throws {
    let find = try request(matchLimit: 1, outputLimit: 2)
    let replace = try request(replace: true, matchLimit: 1, outputLimit: 2)
    for (request, count, replacement) in [
      (find, 1, Optional(0)), (find, 2, nil), (replace, 0, nil), (replace, 0, Optional(3)),
    ] {
      let collector = SearchParentResponseAccumulator(request: request)
      assertError(.invalidMetadata) {
        try collector.begin(response(request, count: count, replacement: replacement))
      }
      assertPoisoned(collector, request)
    }
  }

  // Break: comparing only part of the identity, or allowing correction after a mismatched take.
  func testAllIdentityComponentsFenceBeginCompleteAndTake() throws {
    let request = try request()
    let wrong = [
      try SearchWireIdentity(
        generation: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, requestID: requestID,
        ordinal: 1),
      try SearchWireIdentity(
        generation: generation,
        requestID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, ordinal: 1),
      try SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 2),
    ]
    for identity in wrong {
      let begin = SearchParentResponseAccumulator(request: request)
      // Wrong identity must precede the simultaneous request-count overrun.
      let metadata = try SearchWireResponse(
        identity: identity, matchCount: 17, replacementUTF16: nil)
      assertError(.identityMismatch) { try begin.begin(metadata) }
      assertPoisoned(begin, request)
      let complete = SearchParentResponseAccumulator(request: request)
      try complete.begin(response(request, count: 1))
      assertError(.identityMismatch) { try complete.complete(identity, terminal: .success) }
      assertPoisoned(complete, request)
      let failure = SearchParentResponseAccumulator(request: request)
      assertError(.identityMismatch) {
        try failure.complete(identity, terminal: .failure(.engineFailure))
      }
      assertPoisoned(failure, request)
      let take = SearchParentResponseAccumulator(request: request)
      try take.begin(response(request, count: 0))
      try take.complete(request.identity, terminal: .success)
      assertError(.identityMismatch) { _ = try take.takeTerminal(for: identity) }
      assertPoisoned(take, request)
    }
  }

  // Break: requiring responseStart for semantic failure or coercing a status to engineFailure.
  func testEverySemanticFailureBeforeBeginReturnsNilOutputOnce() throws {
    for error in semanticErrors {
      let request = try request()
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.complete(request.identity, terminal: .failure(error))
      let result = try collector.takeTerminal(for: request.identity)
      XCTAssertEqual(result.terminal, .failure(error))
      XCTAssertNil(result.output)
      assertError(.invalidPhase) { _ = try collector.takeTerminal(for: request.identity) }
      assertPoisoned(collector, request)
    }
  }

  // Break: completeness errors override semantic failures or leak partial response data.
  func testEverySemanticFailureDiscardsPartialRangesAndReplacement() throws {
    for error in semanticErrors {
      for partialReplacement in [false, true] {
        let request = try request(replace: true)
        let collector = SearchParentResponseAccumulator(request: request)
        try collector.begin(response(request, count: partialReplacement ? 1 : 2, replacement: 4))
        try collector.appendRanges([NSRange(location: 1, length: 2)])
        if partialReplacement { try collector.appendReplacementUTF8(Data([0x41])) }
        try collector.complete(request.identity, terminal: .failure(error))
        let result = try collector.takeTerminal(for: request.identity)
        XCTAssertEqual(result.terminal, .failure(error))
        XCTAssertNil(result.output)
      }
    }
  }

  // Break: accepting duplicate control callbacks or a second terminal extraction.
  func testDuplicateBeginCompleteAndTakePoison() throws {
    let request = try request()
    let begin = SearchParentResponseAccumulator(request: request)
    try begin.begin(response(request, count: 0))
    assertError(.invalidPhase) { try begin.begin(response(request, count: 0)) }
    assertPoisoned(begin, request)
    for secondFailure in [false, true] {
      let complete = SearchParentResponseAccumulator(request: request)
      try complete.begin(response(request, count: 0))
      try complete.complete(request.identity, terminal: .success)
      assertError(.invalidPhase) {
        try complete.complete(
          request.identity, terminal: secondFailure ? .failure(.engineFailure) : .success)
      }
      assertPoisoned(complete, request)
    }
    let take = SearchParentResponseAccumulator(request: request)
    try take.begin(response(request, count: 0))
    try take.complete(request.identity, terminal: .success)
    _ = try take.takeTerminal(for: request.identity)
    assertError(.invalidPhase) { _ = try take.takeTerminal(for: request.identity) }
    assertPoisoned(take, request)
  }

  // Break: admitting callbacks out of phase, including empty replacement as an ordering bypass.
  func testCallbackPhaseAndReplacementOrderingPrecedePayloadValidation() throws {
    let find = try request()
    let hello = SearchParentResponseAccumulator(request: find)
    assertError(.invalidPhase) { try hello.helloAccepted(generation: generation) }
    assertPoisoned(hello, find)
    let before = SearchParentResponseAccumulator(request: find)
    assertError(.invalidPhase) { try before.appendRanges([]) }
    let noReplacement = SearchParentResponseAccumulator(request: find)
    try noReplacement.begin(response(find, count: 0))
    assertError(.invalidPhase) { try noReplacement.appendReplacementUTF8(Data([0xFF])) }
    let replace = try request(replace: true)
    let early = SearchParentResponseAccumulator(request: replace)
    try early.begin(response(replace, count: 1, replacement: 0))
    assertError(.invalidPhase) { try early.appendReplacementUTF8(Data([0xFF])) }
    let lateRanges = SearchParentResponseAccumulator(request: replace)
    try lateRanges.begin(response(replace, count: 0, replacement: 0))
    try lateRanges.appendReplacementUTF8(Data())
    assertError(.invalidPhase) { try lateRanges.appendRanges([]) }
  }

  // Break: discard revives an instance or clearing storage invalidates a returned value.
  func testDiscardIsIdempotentAndDetachedOutputSurvivesOwnerRelease() throws {
    let request = try request(replace: true)
    for terminal in [false, true] {
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(response(request, count: 0, replacement: 1))
      try collector.appendReplacementUTF8(Data([0x41]))
      if terminal { try collector.complete(request.identity, terminal: .success) }
      collector.discard()
      collector.discard()
      assertError(.invalidPhase) { _ = try collector.takeTerminal(for: request.identity) }
      assertPoisoned(collector, request)
    }
    var collector: SearchParentResponseAccumulator? = SearchParentResponseAccumulator(
      request: request)
    #if compiler(>=6.3)
      weak let weakOwner = collector
    #else
      weak var weakOwner = collector
    #endif
    try collector!.begin(response(request, count: 0, replacement: 1))
    try collector!.appendReplacementUTF8(Data([0x41]))
    try collector!.complete(request.identity, terminal: .success)
    let output = try collector!.takeTerminal(for: request.identity).output
    collector!.discard()
    collector!.discard()
    collector = nil
    XCTAssertNil(weakOwner)
    XCTAssertEqual(output?.matches, [])
    XCTAssertEqual(output?.replacement, "A")
  }

  // Break: foreign calls mutate/poison the collector instead of rejecting before state access.
  func testEveryThrowingForeignThreadCallLeavesOwnerStateUnchanged() throws {
    let request = try request()
    let metadata = try response(request, count: 0)
    let calls: [(SearchParentResponseAccumulator) throws -> Void] = [
      { try $0.helloAccepted(generation: request.identity.generation) },
      { try $0.begin(metadata) }, { try $0.appendRanges([]) },
      { try $0.appendReplacementUTF8(Data([0xFF])) },
      { try $0.complete(request.identity, terminal: .success) },
      { _ = try $0.takeTerminal(for: request.identity) },
    ]
    for call in calls {
      let collector = SearchParentResponseAccumulator(request: request)
      try collector.begin(metadata)
      let foreign = ParentCollectorForeignCall(collector: collector, call: call)
      try foreign.joinedCall()
      XCTAssertEqual(foreign.error as? SearchParentResponseAccumulatorError, .wrongLane)
      try collector.complete(request.identity, terminal: .success)
      XCTAssertEqual(try collector.takeTerminal(for: request.identity).output?.matches, [])
    }
  }

  // Break: checking identity before legal phase or poison before foreign ownership.
  func testOwnerFailedPhaseAndIdentityErrorPrecedence() throws {
    let request = try request()
    let wrong = try SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 2)
    let collector = SearchParentResponseAccumulator(request: request)
    assertError(.invalidPhase) { _ = try collector.takeTerminal(for: wrong) }
    assertError(.poisoned) { try collector.complete(wrong, terminal: .failure(.engineFailure)) }
    collector.discard()
    let foreign = ParentCollectorForeignCall(collector: collector) { try $0.appendRanges([]) }
    try foreign.joinedCall()
    XCTAssertEqual(foreign.error as? SearchParentResponseAccumulatorError, .wrongLane)
    assertPoisoned(collector, request)
  }

  private var semanticErrors: [SearchError] {
    [
      .invalidScope, .invalidEscape, .invalidPattern, .invalidReplacement, .textLimit,
      .matchLimit, .outputLimit, .cancelled, .timedOut, .engineFailure,
    ]
  }
  private func request(
    replace: Bool = false, input: Int = 4, scope: NSRange? = nil,
    matchLimit: Int = 16, outputLimit: Int = 128
  ) throws -> SearchWireRequest {
    try SearchWireRequest(
      identity: SearchWireIdentity(generation: generation, requestID: requestID, ordinal: 1),
      query: SearchQuery(pattern: "😀", mode: .literal),
      operation: replace ? .replace(template: "x") : .find,
      inputUTF16: input, scope: scope,
      limits: SearchWireLimits(
        maxTextUTF16: max(input, 4), maxOutputUTF16: outputLimit,
        maxMatches: matchLimit, cooperativeMilliseconds: 1_000))
  }
  private func response(_ request: SearchWireRequest, count: Int, replacement: Int? = nil) throws
    -> SearchWireResponse
  {
    try SearchWireResponse(
      identity: request.identity, matchCount: count, replacementUTF16: replacement)
  }
  private func assertError(
    _ expected: SearchParentResponseAccumulatorError, file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual($0 as? SearchParentResponseAccumulatorError, expected, file: file, line: line)
    }
  }
  private func assertPoisoned(
    _ collector: SearchParentResponseAccumulator, _ request: SearchWireRequest,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    collector.discard()
    assertError(.poisoned, file: file, line: line) {
      _ = try collector.takeTerminal(for: request.identity)
    }
  }
}

/// A real join provides a sequential handoff; no foreign discard, concurrent
/// collector calls, test production hooks, sleeps or semaphore polling.
private final class ParentCollectorForeignCall {
  let collector: SearchParentResponseAccumulator
  let call: (SearchParentResponseAccumulator) throws -> Void
  var error: Error?
  init(
    collector: SearchParentResponseAccumulator,
    call: @escaping (SearchParentResponseAccumulator) throws -> Void
  ) {
    self.collector = collector
    self.call = call
  }
  func joinedCall() throws {
    let argument = Unmanaged.passRetained(self).toOpaque()
    var thread: pthread_t?
    let code = pthread_create(
      &thread, nil,
      { raw in
        let owner = Unmanaged<ParentCollectorForeignCall>.fromOpaque(raw).takeRetainedValue()
        do { try owner.call(owner.collector) } catch { owner.error = error }
        return nil
      }, argument)
    guard code == 0 else {
      Unmanaged<ParentCollectorForeignCall>.fromOpaque(argument).release()
      throw ParentCollectorThreadFailure(code: code)
    }
    // Creation success transferred the retained argument even if the callback
    // finished immediately. Never reclaim it on the success path.
    guard let thread else { throw ParentCollectorThreadFailure(code: EINVAL) }
    let joined = pthread_join(thread, nil)
    guard joined == 0 else { throw ParentCollectorThreadFailure(code: joined) }
  }
}
private struct ParentCollectorThreadFailure: Error { let code: Int32 }
