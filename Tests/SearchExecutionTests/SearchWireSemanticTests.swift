import Foundation
import XCTest

@testable import PadCore
@testable import SearchExecution

final class SearchWireSemanticTests: XCTestCase {
  func testRegexReplacementUsesOneWireExecutionAndDoesNotSerializeCaptures() throws {
    let query = SearchQuery(pattern: "(a)", mode: .regex)
    let operation = SearchExecutionOperation.replace(template: "$1!")
    let expected = SearchExecutionOutput(
      matches: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)],
      replacement: "a! a!")
    let connection = try SemanticWireConnection()

    let run = try assertSemanticRoundTrip(
      connection: connection, query: query, text: "a a", operation: operation,
      expected: expected, expectedReplacementUTF8: Data([0x61, 0x21, 0x20, 0x61, 0x21]))

    XCTAssertEqual(run.executeCalls, 1)
    XCTAssertEqual(run.enumerations, 1)
    XCTAssertFalse(run.engineStartedDuringRequestConsume)
    XCTAssertEqual(run.bodyFrames.map(\.kind), [.responseStart, .rangeChunk, .replacementChunk])
    XCTAssertEqual(run.bodyFrames.map { $0.payload.count }, [32, 32, 10])
    XCTAssertEqual(
      run.bodyFrames[1].payload,
      Data([
        0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
      ]))
    try connection.finish()
  }

  func testLiteralEscapedAndOptionalCaptureSemanticsRoundTrip() throws {
    let connection = try SemanticWireConnection()

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: ".", mode: .literal),
      text: "a.b", operation: .replace(template: "$1\\"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 1, length: 1)], replacement: "a$1\\b"),
      expectedReplacementUTF8: Data([0x61, 0x24, 0x31, 0x5C, 0x62]))

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "\\n\\0", mode: .escaped),
      text: "x\n\0y", operation: .replace(template: "$0\\"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 1, length: 2)], replacement: "x$0\\y"),
      expectedReplacementUTF8: Data([0x78, 0x24, 0x30, 0x5C, 0x79]))

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "(a)?b", mode: .regex),
      text: "b ab", operation: .replace(template: "<$1>"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)],
        replacement: "<> <a>"),
      expectedReplacementUTF8: Data("<> <a>".utf8))

    try connection.finish()
  }

  func testScopedSemanticsUseOriginalCoordinatesAndTransparentWordBounds() throws {
    let connection = try SemanticWireConnection()

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "a", mode: .literal, wholeWord: true),
      text: "cat", scope: NSRange(location: 1, length: 1), operation: .find,
      expected: SearchExecutionOutput(matches: [], replacement: nil),
      expectedReplacementUTF8: nil)

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "a", mode: .literal),
      text: "a a a", scope: NSRange(location: 2, length: 1),
      operation: .replace(template: "b"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 2, length: 1)], replacement: "a b a"),
      expectedReplacementUTF8: Data("a b a".utf8))

    try connection.finish()
  }

  func testZeroLengthReplacementSemanticsRoundTrip() throws {
    let connection = try SemanticWireConnection()

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "\\z", mode: .regex),
      text: "ab", operation: .replace(template: "!"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 2, length: 0)], replacement: "ab!"),
      expectedReplacementUTF8: Data("ab!".utf8))

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "(?=(a))", mode: .regex),
      text: "aa", operation: .replace(template: "$1"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)],
        replacement: "aaaa"),
      expectedReplacementUTF8: Data("aaaa".utf8))

    try connection.finish()
  }

  func testFoundationZeroLengthOrderingControlsRoundTripWithoutSorting() throws {
    let fixtures: [(String, String, [NSRange])] = [
      ("a*", "b", [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)]),
      ("(?=a)", "aa", [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)]),
      ("$", "a", [NSRange(location: 1, length: 0)]),
      ("a*", "a", [NSRange(location: 0, length: 1), NSRange(location: 1, length: 0)]),
    ]
    let connection = try SemanticWireConnection()

    for (pattern, text, ranges) in fixtures {
      _ = try assertSemanticRoundTrip(
        connection: connection,
        query: SearchQuery(pattern: pattern, mode: .regex),
        text: text, operation: .find,
        expected: SearchExecutionOutput(matches: ranges, replacement: nil),
        expectedReplacementUTF8: nil)
    }

    try connection.finish()
  }

  func testUnicodeUnitsAndSurrogateRegexControlsRoundTrip() throws {
    let connection = try SemanticWireConnection()
    let unicode = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "🐈", mode: .literal),
      text: "e\u{0301}🐈y", operation: .replace(template: "Z"),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 2, length: 2)], replacement: "e\u{0301}Zy"),
      expectedReplacementUTF8: Data([0x65, 0xCC, 0x81, 0x5A, 0x79]))
    XCTAssertEqual(
      Array(try XCTUnwrap(unicode.output?.replacement).utf16),
      [0x0065, 0x0301, 0x005A, 0x0079])

    let surrogateFixtures: [(String, [NSRange])] = [
      ("\\uD83D", []),
      ("\\uDE00", []),
      ("[\\uD83D]", []),
      (".", [NSRange(location: 0, length: 2)]),
    ]
    for (pattern, ranges) in surrogateFixtures {
      _ = try assertSemanticRoundTrip(
        connection: connection,
        query: SearchQuery(pattern: pattern, mode: .regex),
        text: "😀", operation: .find,
        expected: SearchExecutionOutput(matches: ranges, replacement: nil),
        expectedReplacementUTF8: nil)
    }

    try connection.finish()
  }

  func testFindEmptyReplacementAndNoMatchReplacementKeepDistinctShapes() throws {
    let connection = try SemanticWireConnection()

    let find = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "a", mode: .literal),
      text: "a", operation: .find,
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 1)], replacement: nil),
      expectedReplacementUTF8: nil)
    XCTAssertNil(find.output?.replacement)
    XCTAssertNil(find.replacementUTF8)

    let empty = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "a", mode: .literal),
      text: "a", operation: .replace(template: ""),
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 1)], replacement: ""),
      expectedReplacementUTF8: Data())
    XCTAssertEqual(empty.output?.replacement, "")
    XCTAssertEqual(empty.replacementUTF8, Data())

    _ = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "z", mode: .literal),
      text: "abc", operation: .replace(template: "x"),
      expected: SearchExecutionOutput(matches: [], replacement: "abc"),
      expectedReplacementUTF8: Data("abc".utf8))

    try connection.finish()
  }

  func testSemanticFailureDiscardsOutputAndAllowsNextOrdinal() throws {
    let connection = try SemanticWireConnection()

    let failure = try connection.run(
      query: SearchQuery(pattern: "[", mode: .regex), text: "abc", operation: .find)
    XCTAssertEqual(failure.identity.ordinal, 1)
    XCTAssertEqual(failure.terminal, .failure(.invalidPattern))
    XCTAssertNil(failure.output)
    XCTAssertNil(failure.replacementUTF8)
    XCTAssertTrue(failure.bodyFrames.isEmpty)
    XCTAssertEqual(failure.executeCalls, 1)
    XCTAssertEqual(failure.enumerations, 0)

    let success = try assertSemanticRoundTrip(
      connection: connection,
      query: SearchQuery(pattern: "a", mode: .literal),
      text: "a", operation: .find,
      expected: SearchExecutionOutput(
        matches: [NSRange(location: 0, length: 1)], replacement: nil),
      expectedReplacementUTF8: nil)
    XCTAssertEqual(success.identity.ordinal, 2)
    XCTAssertEqual(success.executeCalls, 1)
    XCTAssertEqual(success.enumerations, 1)
    try connection.finish()
  }

  func testEngineFailureTerminalTransportsTypedFailureWithoutRunningEngine() throws {
    let connection = try SemanticWireConnection()

    let failure = try connection.runTerminalOnly(
      query: SearchQuery(pattern: "a", mode: .literal), text: "a", operation: .find,
      terminal: .failure(.engineFailure))

    XCTAssertEqual(failure.terminal, .failure(.engineFailure))
    XCTAssertNil(failure.output)
    XCTAssertTrue(failure.bodyFrames.isEmpty)
    XCTAssertEqual(failure.executeCalls, 0)
    XCTAssertEqual(failure.enumerations, 0)
    try connection.finish()
  }

  @discardableResult
  private func assertSemanticRoundTrip(
    connection: SemanticWireConnection,
    query: SearchQuery,
    text: String,
    scope: NSRange? = nil,
    operation: SearchExecutionOperation,
    expected: SearchExecutionOutput,
    expectedReplacementUTF8: Data?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> SemanticWireRun {
    let direct = try SearchService(timeLimit: 10).execute(
      query, in: text, scope: scope, operation: operation)
    XCTAssertEqual(direct, expected, file: file, line: line)

    let wire = try connection.run(
      query: query, text: text, scope: scope, operation: operation)
    XCTAssertEqual(wire.terminal, .success, file: file, line: line)
    XCTAssertEqual(wire.output, expected, file: file, line: line)
    XCTAssertEqual(wire.output, direct, file: file, line: line)
    XCTAssertEqual(wire.replacementUTF8, expectedReplacementUTF8, file: file, line: line)
    XCTAssertEqual(wire.executeCalls, 1, file: file, line: line)
    XCTAssertEqual(wire.enumerations, 1, file: file, line: line)
    XCTAssertFalse(wire.engineStartedDuringRequestConsume, file: file, line: line)
    return wire
  }
}

private struct SemanticWireRun {
  let identity: SearchWireIdentity
  let terminal: SearchWireTerminal
  let output: SearchExecutionOutput?
  let replacementUTF8: Data?
  let bodyFrames: [SemanticFrame]
  let executeCalls: Int
  let enumerations: Int
  let engineStartedDuringRequestConsume: Bool
}

private struct SemanticFrame {
  let kind: SearchWireKind
  let payload: Data
}

private struct SemanticChildJob {
  let request: SearchWireRequest
  let text: String
}

private enum SemanticHarnessError: Error {
  case missingRequest
  case missingCompletion
  case invalidUTF8
  case unexpectedRequest
}

private final class SemanticWireConnection {
  private let generation = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
  private let requestReader: SearchWireRequestReader
  private let responseReader: SearchWireResponseReader
  private let requestSink = SemanticRequestSink()
  private let responseSink = SemanticResponseSink()
  private var ordinal: UInt64 = 1
  private var requestSplitOffset = 0
  private var responseSplitOffset = 0
  private var requestConsumeActive = false
  private var executeCalls = 0
  private var enumerations = 0
  private var engineStartedDuringRequestConsume = false
  private var bodyFrames: [SemanticFrame] = []

  init() throws {
    requestReader = try SearchWireRequestReader(generation: generation)
    responseReader = try SearchWireResponseReader(generation: generation)

    try emitHello(fromChild: false) { [self] bytes in
      try consumeRequest(bytes)
    }
    try emitHello(fromChild: true) { [self] bytes in
      try consumeResponse(bytes)
    }
    guard requestSink.hello == generation, responseSink.hello == generation else {
      throw SemanticHarnessError.unexpectedRequest
    }
  }

  func run(
    query: SearchQuery,
    text: String,
    scope: NSRange? = nil,
    operation: SearchExecutionOperation
  ) throws -> SemanticWireRun {
    let executionBefore = executeCalls
    let enumerationsBefore = enumerations
    let completionBefore = responseSink.completed.count
    let job = try prepare(query: query, text: text, scope: scope, operation: operation)

    let (identity, terminal) = try executeAndEmitBody(job)
    try emitTerminal(identity, terminal: terminal)
    try requestReader.acknowledgeTerminal(identity)
    ordinal += 1

    guard responseSink.completed.count == completionBefore + 1,
      let received = responseSink.completed.last,
      received.identity == identity,
      received.terminal == terminal
    else {
      throw SemanticHarnessError.missingCompletion
    }
    return SemanticWireRun(
      identity: identity,
      terminal: terminal,
      output: received.output,
      replacementUTF8: received.replacementUTF8,
      bodyFrames: bodyFrames,
      executeCalls: executeCalls - executionBefore,
      enumerations: enumerations - enumerationsBefore,
      engineStartedDuringRequestConsume: engineStartedDuringRequestConsume)
  }

  func runTerminalOnly(
    query: SearchQuery,
    text: String,
    scope: NSRange? = nil,
    operation: SearchExecutionOperation,
    terminal: SearchWireTerminal
  ) throws -> SemanticWireRun {
    let executionBefore = executeCalls
    let enumerationsBefore = enumerations
    let completionBefore = responseSink.completed.count
    bodyFrames = []
    let job = try prepare(query: query, text: text, scope: scope, operation: operation)
    let identity = job.request.identity

    try emitTerminal(identity, terminal: terminal)
    try requestReader.acknowledgeTerminal(identity)
    ordinal += 1

    guard responseSink.completed.count == completionBefore + 1,
      let received = responseSink.completed.last,
      received.identity == identity,
      received.terminal == terminal
    else {
      throw SemanticHarnessError.missingCompletion
    }
    return SemanticWireRun(
      identity: identity,
      terminal: terminal,
      output: received.output,
      replacementUTF8: received.replacementUTF8,
      bodyFrames: bodyFrames,
      executeCalls: executeCalls - executionBefore,
      enumerations: enumerations - enumerationsBefore,
      engineStartedDuringRequestConsume: engineStartedDuringRequestConsume)
  }

  func finish() throws {
    guard responseSink.provisional == nil else {
      throw SemanticHarnessError.missingCompletion
    }
    try requestReader.finish()
    try responseReader.finish()
  }

  private func prepare(
    query: SearchQuery,
    text: String,
    scope: NSRange?,
    operation: SearchExecutionOperation
  ) throws -> SemanticChildJob {
    bodyFrames = []
    engineStartedDuringRequestConsume = false
    let identity = try SearchWireIdentity(
      generation: generation, requestID: UUID(), ordinal: ordinal)
    let limits = try SearchWireLimits(
      maxTextUTF16: 10_000, maxOutputUTF16: 20_000, maxMatches: 100,
      cooperativeMilliseconds: 10_000)
    let request = try SearchWireRequest(
      identity: identity, query: query, operation: operation,
      inputUTF16: text.utf16.count, scope: scope, limits: limits)
    var emissions: [Data] = []
    let boundaries = try SearchWireWriter.request(request, text: text) {
      emissions.append($0)
    }
    XCTAssertEqual(boundaries.identity, identity)
    XCTAssertEqual(boundaries.expectedUTF16, text.utf16.count)
    try boundaries.validate(NSRange(location: 0, length: text.utf16.count), within: nil)
    try responseReader.expect(request, boundaries: boundaries)

    for emission in emissions {
      try consumeRequest(emission)
    }
    let job = try requestSink.takeJob()
    try validate(job: job, expectedRequest: request, expectedText: text)
    return job
  }

  private func executeAndEmitBody(_ job: SemanticChildJob) throws
    -> (SearchWireIdentity, SearchWireTerminal)
  {
    let identity = job.request.identity
    executeCalls += 1
    if requestConsumeActive {
      engineStartedDuringRequestConsume = true
    }

    do {
      let service = SearchService(
        maxTextUTF16: job.request.limits.maxTextUTF16,
        maxMatches: job.request.limits.maxMatches,
        maxOutputUTF16: job.request.limits.maxOutputUTF16,
        timeLimit: TimeInterval(job.request.limits.cooperativeMilliseconds) / 1_000,
        enumerateMatches: { [self] expression, text, options, range, callback in
          enumerations += 1
          expression.enumerateMatches(
            in: text, options: options, range: range, using: callback)
        })
      let output = try service.execute(
        job.request.query, in: job.text, scope: job.request.scope,
        operation: job.request.operation)
      let response = try SearchWireResponse(
        identity: identity, matchCount: output.matches.count,
        replacementUTF16: output.replacement?.utf16.count)
      let observer = SearchWireFrameDecoder()
      var observed: [SemanticFrame] = []
      try SearchWireWriter.responseBody(response, output: output) { [self] bytes in
        try bytes.withUnsafeBytes {
          try observer.consume($0) { frame in
            observed.append(SemanticFrame(kind: frame.kind, payload: frame.payload))
          }
        }
        try consumeResponse(bytes)
      }
      try observer.finish()
      bodyFrames = observed
      return (identity, .success)
    } catch let error as SearchError {
      bodyFrames = []
      return (identity, .failure(error))
    }
  }

  private func emitTerminal(
    _ identity: SearchWireIdentity,
    terminal: SearchWireTerminal
  ) throws {
    try SearchWireWriter.terminal(identity, result: terminal) { [self] bytes in
      try consumeResponse(bytes)
    }
  }

  private func emitHello(
    fromChild: Bool,
    emit: (Data) throws -> Void
  ) throws {
    try SearchWireWriter.hello(generation: generation, fromChild: fromChild, emit: emit)
  }

  private func consumeRequest(_ data: Data) throws {
    for piece in split(data, schedule: [1, 7, 3, 19, 2, 11], offset: &requestSplitOffset) {
      requestConsumeActive = true
      do {
        try piece.withUnsafeBytes { try requestReader.consume($0, sink: requestSink) }
        requestConsumeActive = false
      } catch {
        requestConsumeActive = false
        throw error
      }
    }
  }

  private func consumeResponse(_ data: Data) throws {
    for piece in split(data, schedule: [2, 1, 13, 5, 23, 3], offset: &responseSplitOffset) {
      do {
        try piece.withUnsafeBytes { try responseReader.consume($0, sink: responseSink) }
        responseSink.commitProvisional()
      } catch {
        responseSink.discardProvisional()
        throw error
      }
    }
  }

  private func validate(
    job: SemanticChildJob,
    expectedRequest: SearchWireRequest,
    expectedText: String
  ) throws {
    guard job.request.identity == expectedRequest.identity,
      job.request.inputUTF16 == expectedRequest.inputUTF16,
      job.request.scope == expectedRequest.scope,
      job.request.operation == expectedRequest.operation,
      job.request.limits == expectedRequest.limits,
      job.request.query.pattern == expectedRequest.query.pattern,
      job.request.query.caseSensitive == expectedRequest.query.caseSensitive,
      job.request.query.wholeWord == expectedRequest.query.wholeWord,
      modeCode(job.request.query.mode) == modeCode(expectedRequest.query.mode),
      job.text == expectedText,
      requestSink.executeObservedInsideConsume
    else {
      throw SemanticHarnessError.unexpectedRequest
    }
  }

  private func split(
    _ data: Data,
    schedule: [Int],
    offset: inout Int
  ) -> [Data] {
    var result: [Data] = []
    var index = data.startIndex
    while index < data.endIndex {
      let count = schedule[offset % schedule.count]
      offset += 1
      let end = min(index + count, data.endIndex)
      result.append(Data(data[index..<end]))
      index = end
    }
    return result
  }

  private func modeCode(_ mode: SearchMode) -> Int {
    switch mode {
    case .literal: return 0
    case .escaped: return 1
    case .regex: return 2
    }
  }
}

private final class SemanticRequestSink: SearchWireRequestSink {
  var hello: UUID?
  var executeObservedInsideConsume = false
  private var request: SearchWireRequest?
  private var inputUTF8 = Data()
  private var executeIdentity: SearchWireIdentity?

  func helloAccepted(generation: UUID) throws {
    hello = generation
  }

  func begin(_ request: SearchWireRequest) throws {
    self.request = request
    inputUTF8 = Data()
    executeIdentity = nil
    executeObservedInsideConsume = false
  }

  func appendInputUTF8(_ bytes: Data) throws {
    inputUTF8.append(bytes)
  }

  func execute(_ identity: SearchWireIdentity) throws {
    executeIdentity = identity
    executeObservedInsideConsume = true
  }

  func takeJob() throws -> SemanticChildJob {
    guard let request, executeIdentity == request.identity,
      let text = String(data: inputUTF8, encoding: .utf8)
    else {
      throw SemanticHarnessError.missingRequest
    }
    let job = SemanticChildJob(request: request, text: text)
    self.request = nil
    inputUTF8 = Data()
    executeIdentity = nil
    return job
  }
}

private struct SemanticReceived {
  let identity: SearchWireIdentity
  let terminal: SearchWireTerminal
  let output: SearchExecutionOutput?
  let replacementUTF8: Data?
}

private final class SemanticResponseSink: SearchWireResponseSink {
  var hello: UUID?
  var completed: [SemanticReceived] = []
  var provisional: SemanticReceived?
  private var response: SearchWireResponse?
  private var ranges: [NSRange] = []
  private var replacementUTF8 = Data()

  func helloAccepted(generation: UUID) throws {
    hello = generation
  }

  func begin(_ response: SearchWireResponse) throws {
    self.response = response
    ranges = []
    replacementUTF8 = Data()
  }

  func appendRanges(_ ranges: [NSRange]) throws {
    self.ranges.append(contentsOf: ranges)
  }

  func appendReplacementUTF8(_ bytes: Data) throws {
    replacementUTF8.append(bytes)
  }

  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    switch terminal {
    case .success:
      guard let response else {
        throw SemanticHarnessError.missingCompletion
      }
      let replacement: String?
      if response.replacementUTF16 == nil {
        replacement = nil
      } else {
        guard let decoded = String(data: replacementUTF8, encoding: .utf8) else {
          throw SemanticHarnessError.invalidUTF8
        }
        replacement = decoded
      }
      provisional = SemanticReceived(
        identity: identity, terminal: terminal,
        output: SearchExecutionOutput(matches: ranges, replacement: replacement),
        replacementUTF8: response.replacementUTF16 == nil ? nil : replacementUTF8)
    case .failure:
      provisional = SemanticReceived(
        identity: identity, terminal: terminal, output: nil, replacementUTF8: nil)
    }
    response = nil
    ranges = []
    replacementUTF8 = Data()
  }

  func commitProvisional() {
    if let provisional {
      completed.append(provisional)
      self.provisional = nil
    }
  }

  func discardProvisional() {
    provisional = nil
  }
}
