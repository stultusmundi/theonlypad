import Foundation
import PadCore
import SearchExecution
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerRuntimeTests: XCTestCase {
  let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  func request(_ ordinal: UInt64 = 1, operation: SearchExecutionOperation = .find) throws
    -> SearchWireRequest
  {
    try SearchWireRequest(
      identity: SearchWireIdentity(
        generation: generation,
        requestID: UUID(
          uuidString: ordinal == 1
            ? "22222222-2222-2222-2222-222222222222" : "33333333-3333-3333-3333-333333333333")!,
        ordinal: ordinal),
      query: SearchQuery(pattern: "a", mode: .literal), operation: operation, inputUTF16: 1,
      scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 10, maxOutputUTF16: 10, maxMatches: 1, cooperativeMilliseconds: 10))
  }
  func bytes(_ ordinal: UInt64 = 1, hello: Bool = true, operation: SearchExecutionOperation = .find)
    throws -> Data
  {
    var result = Data()
    if hello {
      try SearchWireWriter.hello(generation: generation, fromChild: false) { result.append($0) }
    }
    _ = try SearchWireWriter.request(request(ordinal, operation: operation), text: "a") {
      result.append($0)
    }
    return result
  }
  func testCoalescedCompleteNextRequestDiscardsExecute() throws {
    try invalidTrailing(partial: false)
  }
  func testCoalescedPartialNextHeaderDiscardsExecute() throws { try invalidTrailing(partial: true) }
  func invalidTrailing(partial: Bool) throws {
    // Verify the real collector receives the provisional execute before the
    // outer reader rejects the trailing frame. Runtime must discard that event.
    let collector = SearchWorkerRequestCollector(makeAccumulator: { _ in Accumulator() })
    let recorder = RecordingSink(collector)
    let reader = try SearchWireRequestReader(generation: generation)
    let next = try bytes(2, hello: false)
    let invalid = try bytes() + (partial ? Data(next.prefix(3)) : next)
    XCTAssertThrowsError(try invalid.withUnsafeBytes { try reader.consume($0, sink: recorder) })
    XCTAssertEqual(recorder.executions, 1)
    XCTAssertNotNil(collector.takeSealedRequest())
    collector.discard()
    let channel = Channel([try bytes() + (partial ? Data(next.prefix(3)) : next)])
    let engine = Engine()
    weak var owner: Accumulator?
    var created = 0
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { _ in
        created += 1
        let value = Accumulator()
        owner = value
        return value
      }, engine: engine)
    XCTAssertEqual(runtime.run(), .protocolFailure)
    XCTAssertEqual(engine.calls.count, 0)
    XCTAssertTrue(channel.output.isEmpty)
    XCTAssertNil(owner)
    XCTAssertEqual(created, 1)
  }
  func testSequentialRequestsWaitForCompleteTerminalAndReleaseOwner() throws {
    let channel = Channel([try bytes(), try bytes(2, hello: false)])
    let engine = Engine()
    weak var owner: Accumulator?
    let decoder = SearchWireFrameDecoder()
    var frames: [SearchWireFrame] = []
    var terminalHeaders = 0
    channel.onWrite = { data in
      if data.count == 32 && Array(data.prefix(8)) == [80, 83, 82, 88, 1, 0, 35, 0] {
        terminalHeaders += 1
        XCTAssertNil(owner)
        XCTAssertEqual(frames.last?.kind, .rangeChunk)
      }
      try data.withUnsafeBytes {
        try decoder.consume($0) { frame in
          if frame.kind == .terminal { XCTAssertNil(owner) }
          frames.append(frame)
        }
      }
    }
    channel.onRead = { [unowned channel] in
      if channel.reads > 1 {
        XCTAssertEqual(frames.filter { $0.kind == .terminal }.count, channel.reads - 1)
      }
    }
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { count in
        XCTAssertEqual(count, 1)
        let value = Accumulator()
        owner = value
        return value
      }, engine: engine)
    XCTAssertEqual(runtime.run(), .cleanEOF)
    XCTAssertEqual(terminalHeaders, 2)
    XCTAssertEqual(engine.calls.map { $0.0.ordinal }, [1, 2])
    XCTAssertEqual(engine.calls.map { $0.1 }, ["a", "a"])
    XCTAssertEqual(
      frames.map(\.kind),
      [.childHello, .responseStart, .rangeChunk, .terminal, .responseStart, .rangeChunk, .terminal])
    guard frames.count == 7 else { return }
    XCTAssertEqual(
      frames[1].payload,
      Data([
        1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,
      ]))
    XCTAssertEqual(frames[2].payload, Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]))
    XCTAssertEqual(frames[3].payload, Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    XCTAssertEqual(frames[6].payload, Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    XCTAssertEqual(frames[3].requestID, try request().identity.requestID)
    XCTAssertEqual(frames[6].requestID, try request(2).identity.requestID)
  }
  func testEOFRequiresCompletedHelloAndRequest() throws {
    var hello = Data()
    try SearchWireWriter.hello(generation: generation, fromChild: false) { hello.append($0) }
    for (input, expected) in [
      ([], SearchWorkerRunExit.protocolFailure), ([hello], .cleanEOF),
      ([Data(try bytes().dropLast(1))], .protocolFailure),
    ] {
      let channel = Channel(input)
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
        engine: Engine())
      XCTAssertEqual(runtime.run(), expected)
    }
  }
  func testAccumulatorSameTypeErrorIsFatal() throws {
    let channel = Channel([try bytes(), try bytes(2, hello: false)])
    let engine = Engine()
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { _ in
        let value = Accumulator()
        value.finishError = SearchError.invalidPattern
        return value
      }, engine: engine)
    XCTAssertEqual(runtime.run(), .inputSinkFailure)
    XCTAssertTrue(engine.calls.isEmpty)
    XCTAssertEqual(channel.reads, 1)
    XCTAssertEqual(try frames(channel.output).map(\.kind), [.childHello])
  }
  func testFactoryAndAppendErrorsAreInputSinkFailures() throws {
    for factoryFailure in [true, false] {
      let channel = Channel([try bytes()])
      let engine = Engine()
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel,
        makeAccumulator: { _ in
          if factoryFailure { throw SearchError.invalidPattern }
          let value = Accumulator()
          value.onAppend = { throw SearchWireError.invalidMetadata }
          return value
        }, engine: engine)
      XCTAssertEqual(runtime.run(), .inputSinkFailure)
      XCTAssertTrue(engine.calls.isEmpty)
      XCTAssertTrue(channel.output.isEmpty)
    }
  }
  func testReadErrorIsInputFailure() throws {
    let channel = Channel([])
    channel.onRead = { throw SearchError.invalidPattern }
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
      engine: Engine())
    XCTAssertEqual(runtime.run(), .inputFailure)
  }
  func testBodyAndTerminalWriteErrorsDoNotPermitReuse() throws {
    for failingWrite in [3, 7, 8] {
      let channel = Channel([try bytes(), try bytes(2, hello: false)])
      let engine = Engine()
      var writes = 0
      channel.onWrite = { _ in
        writes += 1
        if writes == failingWrite { throw SearchError.invalidPattern }
      }
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
        engine: engine)
      XCTAssertEqual(runtime.run(), .outputFailure)
      XCTAssertEqual(engine.calls.count, 1)
      XCTAssertEqual(channel.reads, 1)
    }
  }
  func testDirectEngineErrorProducesSemanticTerminalAndAllowsReuse() throws {
    let channel = Channel([try bytes(), try bytes(2, hello: false)])
    let engine = Engine()
    engine.error = SearchError.engineFailure
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
      engine: engine)
    XCTAssertEqual(runtime.run(), .cleanEOF)
    let output = try frames(channel.output)
    XCTAssertEqual(output.map(\.kind), [.childHello, .terminal, .terminal])
    guard output.count == 3 else { return }
    XCTAssertEqual(output[1].payload[8], 10)
    XCTAssertEqual(engine.calls.count, 2)
  }
  func testArbitraryEngineErrorAndInvalidResultAreFatal() throws {
    for invalidResult in [false, true] {
      let channel = Channel([try bytes()])
      let engine = Engine()
      if invalidResult {
        engine.output = SearchExecutionOutput(matches: [], replacement: "bad")
      } else {
        engine.error = SearchWireError.invalidMetadata
      }
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
        engine: engine)
      XCTAssertEqual(runtime.run(), .internalFailure)
      XCTAssertEqual(try frames(channel.output).map(\.kind), [.childHello])
    }
  }

  func testReentrantRunFromAccumulatorPoisonsOuterRun() throws {
    let channel = Channel([try bytes()])
    let engine = Engine()
    var runtime: SearchWorkerRuntime!
    defer { runtime = nil }
    runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { _ in
        let accumulator = Accumulator()
        accumulator.onAppend = { XCTAssertEqual(runtime.run(), .internalFailure) }
        return accumulator
      }, engine: engine)
    XCTAssertEqual(runtime.run(), .internalFailure)
    XCTAssertTrue(engine.calls.isEmpty)
    XCTAssertTrue(channel.output.isEmpty)
  }
  func testReentrantRunFromWriterPoisonsOuterRun() throws {
    let channel = Channel([try bytes()])
    let engine = Engine()
    var runtime: SearchWorkerRuntime!
    defer { runtime = nil }
    channel.onWrite = { _ in XCTAssertEqual(runtime.run(), .internalFailure) }
    runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
      engine: engine)
    XCTAssertEqual(runtime.run(), .internalFailure)
    XCTAssertTrue(engine.calls.isEmpty)
    XCTAssertEqual(channel.reads, 1)
  }

  func testFragmentedInputDoesNotExecuteUntilSealed() throws {
    let wire = try bytes()
    let channel = Channel(wire.map { Data([$0]) })
    let engine = Engine()
    channel.onRead = { if channel.reads <= wire.count { XCTAssertTrue(engine.calls.isEmpty) } }
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
      engine: engine)
    XCTAssertEqual(runtime.run(), .cleanEOF)
    XCTAssertEqual(engine.calls.count, 1)
    XCTAssertEqual(engine.calls.first?.1, "a")
  }
  func testEmptyReplacementRemainsPresentInWireMetadata() throws {
    let channel = Channel([try bytes(operation: .replace(template: ""))])
    let engine = Engine()
    engine.output = SearchExecutionOutput(
      matches: [NSRange(location: 0, length: 1)], replacement: "")
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
      engine: engine)
    XCTAssertEqual(runtime.run(), .cleanEOF)
    let output = try frames(channel.output)
    XCTAssertEqual(output.map(\.kind), [.childHello, .responseStart, .rangeChunk, .terminal])
    guard output.count == 4 else { return }
    XCTAssertEqual(output[1].payload[24], 1)
    XCTAssertEqual(Array(output[1].payload[16..<24]), [0, 0, 0, 0, 0, 0, 0, 0])
  }
  func testEngineResultLimitsAndShapeAreCheckedBeforeResponseStart() throws {
    let cases: [(SearchExecutionOperation, SearchExecutionOutput)] = [
      (
        .find,
        SearchExecutionOutput(
          matches: [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)],
          replacement: nil)
      ),
      (.replace(template: "b"), SearchExecutionOutput(matches: [], replacement: nil)),
      (.replace(template: "b"), SearchExecutionOutput(matches: [], replacement: "12345678901")),
      (.find, SearchExecutionOutput(matches: [NSRange(location: -1, length: 1)], replacement: nil)),
    ]
    for (operation, result) in cases {
      let channel = Channel([try bytes(operation: operation)])
      let engine = Engine()
      engine.output = result
      let runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
        engine: engine)
      XCTAssertEqual(runtime.run(), .internalFailure)
      XCTAssertEqual(try frames(channel.output).map(\.kind), [.childHello])
    }
  }
  func testHelloWriteRefusalPreventsEngineAndReuse() throws {
    let channel = Channel([try bytes()])
    let engine = Engine()
    channel.onWrite = { _ in throw SearchError.invalidPattern }
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: channel, makeAccumulator: { _ in Accumulator() },
      engine: engine)
    XCTAssertEqual(runtime.run(), .outputFailure)
    XCTAssertTrue(engine.calls.isEmpty)
    XCTAssertEqual(runtime.run(), .internalFailure)
    XCTAssertEqual(channel.reads, 1)
  }
  func testCollectorSealsWithoutFinalizingAndRequiresExactIdentity() throws {
    let accumulator = Accumulator()
    let collector = SearchWorkerRequestCollector(makeAccumulator: { _ in accumulator })
    try collector.helloAccepted(generation: generation)
    try collector.begin(request())
    try collector.appendInputUTF8(Data([97]))
    try collector.execute(request().identity)
    XCTAssertEqual(accumulator.finishes, 0)
    XCTAssertEqual(collector.takeHelloGeneration(), generation)
    XCTAssertNil(collector.takeHelloGeneration())
    let sealed = try XCTUnwrap(collector.takeSealedRequest())
    XCTAssertEqual(sealed.request.identity, try request().identity)
    XCTAssertNil(collector.takeSealedRequest())
    XCTAssertEqual(try sealed.accumulator.finish(), "a")

    try collector.begin(request(2))
    XCTAssertThrowsError(try collector.execute(request().identity))
    XCTAssertTrue(collector.rejected)
    XCTAssertNil(collector.takeSealedRequest())
  }
  func testCollectorSwallowedReentryFromFactoryAndAppendStaysPoisoned() throws {
    for fromFactory in [true, false] {
      var collector: SearchWorkerRequestCollector!
      defer { collector = nil }
      collector = SearchWorkerRequestCollector(makeAccumulator: { _ in
        if fromFactory { try? collector.begin(self.request()) }
        let accumulator = Accumulator()
        accumulator.onAppend = { try? collector.execute(self.request().identity) }
        return accumulator
      })
      try collector.helloAccepted(generation: generation)
      if fromFactory {
        XCTAssertThrowsError(try collector.begin(request()))
      } else {
        try collector.begin(request())
        XCTAssertThrowsError(try collector.appendInputUTF8(Data([97])))
      }
      XCTAssertTrue(collector.rejected)
      XCTAssertNil(collector.takeHelloGeneration())
      XCTAssertNil(collector.takeSealedRequest())
    }
  }
  func testCollectorCannotDrainEventsDuringAccumulatorCallback() throws {
    var collector: SearchWorkerRequestCollector!
    defer { collector = nil }
    collector = SearchWorkerRequestCollector(makeAccumulator: { _ in
      let accumulator = Accumulator()
      accumulator.onAppend = { XCTAssertNil(collector.takeHelloGeneration()) }
      return accumulator
    })
    try collector.helloAccepted(generation: generation)
    try collector.begin(request())
    XCTAssertThrowsError(try collector.appendInputUTF8(Data([97])))
    XCTAssertTrue(collector.rejected)
    XCTAssertNil(collector.takeSealedRequest())
  }
  func testReentryFromReadFinishAndEnginePoisonsRuntime() throws {
    for phase in [0, 1, 2] {
      let channel = Channel([try bytes()])
      let engine = Engine()
      var runtime: SearchWorkerRuntime!
      defer { runtime = nil }
      let reenter = { XCTAssertEqual(runtime.run(), .internalFailure) }
      if phase == 0 { channel.onRead = reenter }
      if phase == 2 { engine.onExecute = reenter }
      runtime = try SearchWorkerRuntime(
        generation: generation, channel: channel,
        makeAccumulator: { _ in
          let accumulator = Accumulator()
          if phase == 1 { accumulator.onFinish = reenter }
          return accumulator
        }, engine: engine)
      XCTAssertEqual(runtime.run(), .internalFailure)
      XCTAssertEqual(engine.calls.count, phase == 2 ? 1 : 0)
      XCTAssertEqual(channel.reads, 1)
      XCTAssertFalse(try frames(channel.output).contains { $0.kind == .terminal })
    }
  }
  func testOversizedReadAndIncorrectAccumulatorTextAreFatal() throws {
    let oversized = Channel([Data(repeating: 0, count: 65_569)])
    let engine = Engine()
    let runtime = try SearchWorkerRuntime(
      generation: generation, channel: oversized, makeAccumulator: { _ in Accumulator() },
      engine: engine)
    XCTAssertEqual(runtime.run(), .inputFailure)
    XCTAssertTrue(engine.calls.isEmpty)
    let channel = Channel([try bytes()])
    let wrongText = try SearchWorkerRuntime(
      generation: generation, channel: channel,
      makeAccumulator: { _ in
        let accumulator = Accumulator()
        accumulator.onFinish = { [weak accumulator] in accumulator?.bytes = Data() }
        return accumulator
      }, engine: engine)
    XCTAssertEqual(wrongText.run(), .inputSinkFailure)
    XCTAssertTrue(engine.calls.isEmpty)
  }
  func frames(_ data: Data) throws -> [SearchWireFrame] {
    let decoder = SearchWireFrameDecoder()
    var result: [SearchWireFrame] = []
    try data.withUnsafeBytes { try decoder.consume($0) { result.append($0) } }
    try decoder.finish()
    return result
  }

}
private final class Accumulator: SearchWorkerTextAccumulator {
  var bytes = Data()
  var finishError: Error?
  var finishes = 0
  var onFinish: (() -> Void)?
  var onAppend: (() throws -> Void)?
  func appendUTF8(_ bytes: Data) throws {
    try onAppend?()
    self.bytes.append(bytes)
  }
  func finish() throws -> String {
    finishes += 1
    onFinish?()
    if let finishError { throw finishError }
    return String(decoding: bytes, as: UTF8.self)
  }
}
private final class Engine: SearchWorkerEngine {
  var calls: [(SearchWireIdentity, String)] = []
  var error: Error?
  var onExecute: (() -> Void)?
  var output = SearchExecutionOutput(matches: [NSRange(location: 0, length: 1)], replacement: nil)
  func execute(_ request: SearchWireRequest, text: String) throws -> SearchExecutionOutput {
    calls.append((request.identity, text))
    onExecute?()
    if let error { throw error }
    return output
  }
}
private final class Channel: SearchWorkerBlockingChannel {
  var input: [Data]
  var output = Data()
  var reads = 0
  var onRead: (() throws -> Void)?
  var onWrite: ((Data) throws -> Void)?
  init(_ input: [Data]) { self.input = input }
  func read(maxBytes: Int) throws -> Data {
    XCTAssertEqual(maxBytes, 65_568)
    reads += 1
    try onRead?()
    return input.isEmpty ? Data() : input.removeFirst()
  }
  func write(_ bytes: Data) throws {
    XCTAssertTrue((1...65_536).contains(bytes.count))
    try onWrite?(bytes)
    output.append(bytes)
  }
}

private final class RecordingSink: SearchWireRequestSink {
  let collector: SearchWorkerRequestCollector
  var executions = 0
  init(_ collector: SearchWorkerRequestCollector) { self.collector = collector }
  func helloAccepted(generation: UUID) throws {
    try collector.helloAccepted(generation: generation)
  }
  func begin(_ request: SearchWireRequest) throws { try collector.begin(request) }
  func appendInputUTF8(_ bytes: Data) throws { try collector.appendInputUTF8(bytes) }
  func execute(_ identity: SearchWireIdentity) throws {
    executions += 1
    try collector.execute(identity)
  }
}
