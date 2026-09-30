import Foundation
import PadCore
import SearchExecution
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerProgramTests: XCTestCase {
  private let generation = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
  private var arguments: [String] { ["worker", "--generation", generation.uuidString] }

  func testBootstrapRefusalPerformsNoChannelLifetimeOrAccumulatorWork() {
    let invalid: [[String]] = [
      [], ["worker"], ["worker", "--generation"],
      arguments + ["extra"], arguments + ["--generation", generation.uuidString],
      ["worker", "--generation", "not-a-uuid"],
      ["worker", "--generation", "00000000-0000-0000-0000-000000000000"],
      ["worker", "--generation", "{" + generation.uuidString + "}"],
    ]
    for argv in invalid {
      var calls: [String] = []
      let channel = ProgramChannel([])
      let code = SearchWorkerProgram.run(
        arguments: argv,
        inputFD: 101, outputFD: 202, controlFD: 303,
        makeChannel: { _, _ in
          calls.append("channel")
          return channel
        },
        makeAccumulator: { _ in
          calls.append("accumulator")
          return ProgramAccumulator()
        },
        startParentLifetime: { _ in calls.append("lifetime") })
      XCTAssertEqual(code, 64)
      XCTAssertTrue(calls.isEmpty)
      XCTAssertEqual(channel.reads, 0)
      XCTAssertTrue(channel.output.isEmpty)
    }
  }

  func testInvalidOrAliasedDescriptorsRefuseBeforeAnyBoundaryWork() {
    let descriptors: [(Int32, Int32, Int32)] = [
      (-1, 202, 303), (101, -1, 303), (101, 202, -1),
      (101, 101, 303), (101, 202, 101), (101, 202, 202),
    ]
    for (input, output, control) in descriptors {
      var calls: [String] = []
      let code = SearchWorkerProgram.run(
        arguments: arguments,
        inputFD: input, outputFD: output, controlFD: control,
        makeChannel: { _, _ in
          calls.append("channel")
          return ProgramChannel([])
        },
        makeAccumulator: { _ in
          calls.append("accumulator")
          return ProgramAccumulator()
        },
        startParentLifetime: { _ in calls.append("lifetime") })
      XCTAssertEqual(code, 74)
      XCTAssertTrue(calls.isEmpty)
    }
  }

  func testBootstrapRefusalPrecedesDescriptorValidation() {
    let code = SearchWorkerProgram.run(
      arguments: [], inputFD: -1, outputFD: -1, controlFD: -1,
      makeChannel: { _, _ in
        XCTFail("Unexpected channel construction")
        return ProgramChannel([])
      },
      makeAccumulator: { _ in
        XCTFail("Unexpected accumulator construction")
        return ProgramAccumulator()
      },
      startParentLifetime: { _ in XCTFail("Unexpected lifetime start") })
    XCTAssertEqual(code, 64)
  }

  func testChannelConstructionFailureIsIOExitBeforeLifetimeStart() {
    var calls: [String] = []
    let code = SearchWorkerProgram.run(
      arguments: arguments,
      inputFD: 101, outputFD: 202, controlFD: 303,
      makeChannel: { input, output in
        XCTAssertEqual(input, 101)
        XCTAssertEqual(output, 202)
        calls.append("channel")
        throw SearchError.invalidPattern
      },
      makeAccumulator: { _ in
        calls.append("accumulator")
        return ProgramAccumulator()
      },
      startParentLifetime: { _ in calls.append("lifetime") })
    XCTAssertEqual(code, 74)
    XCTAssertEqual(calls, ["channel"])
  }

  func testLifetimeStartsOnceAfterChannelBeforeFirstReadAndGenerationIsBound() throws {
    var events: [String] = []
    let channel = ProgramChannel([try hello(generation)])
    channel.onRead = { events.append("read") }
    channel.onWrite = { _ in events.append("write") }
    let code = SearchWorkerProgram.run(
      arguments: ["worker", "--generation", generation.uuidString.lowercased()],
      inputFD: 101, outputFD: 202, controlFD: 303,
      makeChannel: { input, output in
        XCTAssertEqual(input, 101)
        XCTAssertEqual(output, 202)
        events.append("channel")
        return channel
      },
      makeAccumulator: { _ in
        XCTFail("Hello must not allocate request text")
        return ProgramAccumulator()
      },
      startParentLifetime: { fd in
        XCTAssertEqual(fd, 303)
        events.append("lifetime")
      })
    XCTAssertEqual(code, 0)
    XCTAssertEqual(events, ["channel", "lifetime", "read", "write", "write", "read"])
    var expected = Data()
    try SearchWireWriter.hello(generation: generation, fromChild: true) { expected.append($0) }
    XCTAssertEqual(channel.output, expected)
  }

  func testWrongHelloGenerationIsProtocolExitWithoutResponse() throws {
    let wrong = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let channel = ProgramChannel([try hello(wrong)])
    XCTAssertEqual(run(channel), 65)
    XCTAssertEqual(channel.reads, 1)
    XCTAssertTrue(channel.output.isEmpty)
  }

  func testEOFBeforeHelloAndTruncatedInputAreProtocolExits() throws {
    for input in [[], [Data(try hello(generation).dropLast())]] {
      let channel = ProgramChannel(input)
      XCTAssertEqual(run(channel), 65)
      XCTAssertTrue(channel.output.isEmpty)
    }
  }

  func testInputErrorIsIOExitEvenWhenSameTypeAsSemanticError() {
    let channel = ProgramChannel([])
    channel.onRead = { throw SearchError.invalidPattern }
    XCTAssertEqual(run(channel), 74)
    XCTAssertEqual(channel.reads, 1)
    XCTAssertTrue(channel.output.isEmpty)
  }

  func testOutputErrorIsIOExitWithoutAnotherRead() throws {
    let channel = ProgramChannel([try hello(generation)])
    channel.onWrite = { _ in throw SearchError.invalidPattern }
    XCTAssertEqual(run(channel), 74)
    XCTAssertEqual(channel.reads, 1)
    XCTAssertTrue(channel.output.isEmpty)
  }

  func testAccumulatorFactoryAndFinishFailuresAreInternalExit() throws {
    for refuseFactory in [true, false] {
      let channel = ProgramChannel([try requestBytes()])
      XCTAssertEqual(
        run(
          channel,
          makeAccumulator: { _ in
            if refuseFactory { throw SearchError.invalidPattern }
            let accumulator = ProgramAccumulator()
            accumulator.finishFailure = SearchError.invalidPattern
            return accumulator
          }), 70)
      XCTAssertEqual(channel.reads, 1)
      XCTAssertFalse(try frames(channel.output).contains { $0.kind == .terminal })
    }
  }

  func testFixedFoundationEngineProducesExactReplacementFrames() throws {
    let channel = ProgramChannel([try requestBytes()])
    var declared: [Int] = []
    XCTAssertEqual(
      run(
        channel,
        makeAccumulator: { count in
          declared.append(count)
          return ProgramAccumulator()
        }), 0)
    XCTAssertEqual(declared, [3])
    let result = try frames(channel.output)
    XCTAssertEqual(
      result.map(\.kind), [.childHello, .responseStart, .rangeChunk, .replacementChunk, .terminal])
    guard result.count == 5 else { return }
    XCTAssertEqual(
      result[1].payload,
      Data([
        1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
      ]))
    XCTAssertEqual(
      result[2].payload,
      Data([
        0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
      ]))
    XCTAssertEqual(result[3].payload, Data([97, 0, 33, 0, 32, 0, 97, 0, 33, 0]))
    XCTAssertEqual(result[4].payload, Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  }

  func testSemanticFailureTerminalStillHasCleanProcessExit() throws {
    let channel = ProgramChannel([try requestBytes(milliseconds: 0)])
    XCTAssertEqual(run(channel), 0)
    let result = try frames(channel.output)
    XCTAssertEqual(result.map(\.kind), [.childHello, .terminal])
    XCTAssertEqual(result.last?.payload, Data([1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0]))
  }

  private func run(
    _ channel: ProgramChannel,
    makeAccumulator: @escaping SearchWorkerAccumulatorFactory = { _ in ProgramAccumulator() }
  ) -> Int32 {
    SearchWorkerProgram.run(
      arguments: arguments,
      inputFD: 101, outputFD: 202, controlFD: 303,
      makeChannel: { _, _ in channel }, makeAccumulator: makeAccumulator,
      startParentLifetime: { _ in })
  }

  private func hello(_ generation: UUID) throws -> Data {
    var bytes = Data()
    try SearchWireWriter.hello(generation: generation, fromChild: false) { bytes.append($0) }
    return bytes
  }

  private func requestBytes(milliseconds: UInt32 = 10_000) throws -> Data {
    let request = try SearchWireRequest(
      identity: SearchWireIdentity(
        generation: generation,
        requestID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, ordinal: 1),
      query: SearchQuery(pattern: "(a)", mode: .regex), operation: .replace(template: "$1!"),
      inputUTF16: 3, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 3, maxOutputUTF16: 5, maxMatches: 2,
        cooperativeMilliseconds: milliseconds))
    var bytes = try hello(generation)
    _ = try SearchWireWriter.request(request, text: "a a") { bytes.append($0) }
    return bytes
  }

  private func frames(_ bytes: Data) throws -> [SearchWireFrame] {
    let decoder = SearchWireFrameDecoder()
    var output: [SearchWireFrame] = []
    try bytes.withUnsafeBytes { try decoder.consume($0) { output.append($0) } }
    try decoder.finish()
    return output
  }
}

private final class ProgramAccumulator: SearchWorkerTextAccumulator {
  var bytes = Data()
  var finishFailure: Error?
  func appendUTF8(_ bytes: Data) { self.bytes.append(bytes) }
  func finish() throws -> String {
    if let finishFailure { throw finishFailure }
    return String(decoding: bytes, as: UTF8.self)
  }
}

private final class ProgramChannel: SearchWorkerBlockingChannel {
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
    try onWrite?(bytes)
    output.append(bytes)
  }
}
