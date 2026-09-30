import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchParentWireCodecSessionTests: XCTestCase {
  func testHandAuthoredHelloOneByteAtATimeAndEverySplit() async throws {
    for split in [0] + Array(1..<56) {
      let f = try await CodecFixture.readyForHello()
      let bytes = f.hello
      if split == 0 {
        for index in 0..<55 {
          assertProgress(try await f.consume(bytes.subdata(in: index..<index + 1)), .needMore)
        }
        assertProgress(try await f.consume(bytes.suffix(1)), .hello(f.generation))
      } else {
        assertProgress(try await f.consume(bytes.prefix(split)), .needMore)
        assertProgress(try await f.consume(bytes.suffix(56 - split)), .hello(f.generation))
      }
      await f.stop()
    }
  }

  func testCompletingHelloWithPartialOrCompleteTrailingBytesPoisons() async throws {
    for length in Array(1...31) + [33, 56] {
      let f = try await CodecFixture.readyForHello()
      await expectFailure { _ = try await f.consume(f.hello + f.hello.prefix(length)) }
      await expectFailure { _ = try await f.consume(Data()) }
      await f.stop()
    }
  }

  func testSmallUnicodeRequestAndFixedResponseUseExactBoundaries() async throws {
    let f = try await CodecFixture.ready()
    let encoded = try await f.upload()
    XCTAssertEqual(encoded.identity, f.identity)
    XCTAssertEqual(encoded.inputUTF16, 4)
    XCTAssertEqual(f.counts.value.emits, 7)  // hello2 + metadata2 + input2 + execute1
    try await f.expect()
    let result = try await f.consume(f.success())
    XCTAssertEqual(
      result,
      .terminal(
        .init(
          identity: f.identity, terminal: .success,
          output: .init(matches: [NSRange(location: 1, length: 2)], replacement: nil))))
    XCTAssertEqual(f.sink.takes, 1)
    XCTAssertEqual(f.sink.discards, 1)
    XCTAssertTrue(f.sink.sameThread)
    XCTAssertEqual(f.sink.callbackDepth, 0)
    XCTAssertTrue(f.sink.takesAfterUnwind)
    XCTAssertTrue(f.sink.discardsAfterUnwind)
    await f.stop()
  }

  func testFactoryFailureOccursBeforeAnyRequestEmission() async throws {
    let f = try await CodecFixture.ready(factoryThrows: true)
    let before = f.counts.value.emits
    await expectFailure { _ = try await f.upload() }
    XCTAssertEqual(f.counts.value.emits, before)
    XCTAssertEqual(f.counts.value.factories, 1)
    await f.stop()
  }

  func testExecuteWriteFailureNeverInstallsExpectation() async throws {
    let f = try await CodecFixture.ready()
    await expectFailure { _ = try await f.upload(failAt: 5) }
    await expectFailure { try await f.expect() }
    XCTAssertEqual(f.sink.takes, 0)
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  func testEarlyWriteFailureDoesNotAttemptExecute() async throws {
    let f = try await CodecFixture.ready()
    let before = f.counts.value.emits
    await expectFailure { _ = try await f.upload(failAt: 1) }
    XCTAssertEqual(f.counts.value.emits - before, 1)
    await expectFailure { try await f.expect() }
    await f.stop()
  }

  func testTerminalWithTrailingJunkNeverTakesOutput() async throws {
    for length in [1, 31, 32, 48] {
      let f = try await CodecFixture.ready()
      _ = try await f.upload()
      try await f.expect()
      await expectFailure { _ = try await f.consume(f.success() + f.terminal().prefix(length)) }
      XCTAssertEqual(f.sink.takes, 0)
      XCTAssertEqual(f.sink.discards, 1)
      XCTAssertEqual(f.sink.callbackDepth, 0)
      XCTAssertTrue(f.sink.takesAfterUnwind)
      XCTAssertTrue(f.sink.discardsAfterUnwind)
      await expectFailure { _ = try await f.consume(Data()) }
      await f.stop()
    }
  }

  func testSemanticFailureDiscardsPartialRanges() async throws {
    let f = try await CodecFixture.ready()
    _ = try await f.upload()
    try await f.expect()
    let output = try await f.consume(f.body() + f.terminal(status: 10))
    XCTAssertEqual(
      output,
      .terminal(.init(identity: f.identity, terminal: .failure(.engineFailure), output: nil)))
    XCTAssertTrue(f.sink.ranges.isEmpty)
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  func testInvalidScalarBoundaryRangeRejectedBeforeTransfer() async throws {
    let f = try await CodecFixture.ready()
    _ = try await f.upload()
    try await f.expect()
    await expectFailure {
      _ = try await f.consume(f.body(range: NSRange(location: 2, length: 1)) + f.terminal())
    }
    XCTAssertEqual(f.sink.takes, 0)
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  func testSinkSearchErrorIsInfrastructureFailure() async throws {
    let f = try await CodecFixture.ready()
    f.sink.throwOnBegin = true
    _ = try await f.upload()
    try await f.expect()
    await expectFailure { _ = try await f.consume(f.success()) }
    XCTAssertEqual(f.sink.takes, 0)
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  func testAccumulatorShapeAndTerminalContractViolationsFail() async throws {
    for mutation in 1...4 {
      let f = try await CodecFixture.ready()
      f.sink.mutation = mutation
      _ = try await f.upload()
      try await f.expect()
      await expectFailure { _ = try await f.consume(f.success()) }
      XCTAssertEqual(f.sink.discards, 1)
      await f.stop()
    }
  }

  func testCaughtSinkTakeAndDiscardReentryStillPoisonsOuterCall() async throws {
    for at in ["begin", "take", "discard"] {
      let f = try await CodecFixture.ready()
      f.sink.reenterAt = at
      f.sink.reenter = { [unowned f] in _ = try? f.session.consume(token: f.token, bytes: Data()) }
      _ = try await f.upload()
      try await f.expect()
      await expectFailure { _ = try await f.consume(f.success()) }
      XCTAssertEqual(f.sink.discards, 1)
      await f.stop()
    }
  }

  func testWrongLaneDoesNotInvokeAccumulator() async throws {
    let f = try await CodecFixture.ready()
    XCTAssertThrowsError(try f.session.discard(token: f.token))
    XCTAssertEqual(f.sink.discards, 0)
    await f.stop()
  }

  func testWrongBridgeIdentityAndReusedEpochEmitNothing() async throws {
    for mode in 0...2 {
      let f = try await CodecFixture.ready()
      let identity = try SearchParentWriterIdentity(
        generation: mode == 0 ? UUID() : f.generation,
        requestID: mode == 1 ? UUID() : f.identity.requestID, writerEpoch: mode == 2 ? 1 : 2)
      let before = f.counts.value.emits
      await expectFailure { _ = try await f.upload(writerIdentity: identity) }
      XCTAssertEqual(f.counts.value.emits, before)
      XCTAssertEqual(f.counts.value.factories, 0)
      await f.stop()
    }
  }

  func testPreHandshakeAndWrongOrdinalRejectBeforeEmit() async throws {
    let first = try await CodecFixture.readyForHello()
    let before = first.counts.value.emits
    await expectFailure { _ = try await first.upload() }
    XCTAssertEqual(first.counts.value.emits, before)
    await first.stop()
    let f = try await CodecFixture.ready()
    let wrong = try f.request(ordinal: 2)
    let previous = f.counts.value.emits
    await expectFailure { _ = try await f.upload(request: wrong) }
    XCTAssertEqual(f.counts.value.emits, previous)
    await f.stop()
  }

  func testDifferentJobTokensWorkButStaleSessionEpochRefuses() async throws {
    let f = try await CodecFixture.ready()
    let next = try SearchParentCodecToken(
      generation: f.generation, sessionEpoch: 1, operationID: UUID())
    assertProgress(
      try await f.run(token: next) { try f.session.consume(token: next, bytes: Data()) }, .needMore)
    let stale = try SearchParentCodecToken(
      generation: f.generation, sessionEpoch: 2, operationID: UUID())
    await expectFailure {
      _ = try await f.run(token: stale) { try f.session.consume(token: stale, bytes: Data()) }
    }
    await f.stop()
  }

  func testHeldExecuteWriteHasNoReceiptOrResponseCallbacks() async throws {
    let f = try await CodecFixture.ready()
    let entered = expectation(description: "execute write entered")
    let gate = CodecAsyncGate()
    let completed = CodecLocked(false)
    let operation = Task {
      let result = try await f.upload(writeHook: { index in
        if index == 5 {
          entered.fulfill()
          await gate.wait()
        }
      })
      completed.update { $0 = true }
      return result
    }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertTrue(f.lane.snapshot.busy)
    XCTAssertFalse(completed.value)
    XCTAssertEqual(f.sink.takes, 0)
    XCTAssertThrowsError(
      try f.lane.submit(token: f.token) {
        try f.session.expect(token: f.token, identity: f.identity)
      })
    await gate.release()
    let encoded = try await operation.value
    XCTAssertEqual(encoded.identity, f.identity)
    try await f.expect()
    let response = try await f.consume(f.success())
    if case .terminal = response {} else { XCTFail("held response not parsed after expect") }
    await f.stop()
  }

  func testFactoryCaughtReentryFailsBeforeEmission() async throws {
    let f = try await CodecFixture.ready(factoryReentry: true)
    let before = f.counts.value.emits
    await expectFailure { _ = try await f.upload() }
    XCTAssertEqual(f.counts.value.emits, before)
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  func testDiscardAfterPoisonAndAfterDiscardIsIdempotent() async throws {
    let f = try await CodecFixture.ready()
    _ = try await f.upload()
    try await f.expect()
    await expectFailure { _ = try await f.consume(f.body(range: .init(location: 2, length: 1))) }
    try await f.run { try f.session.discard(token: f.token) }
    try await f.run { try f.session.discard(token: f.token) }
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  func testPersistentReaderNextOrdinalAndLateOldTerminalFence() async throws {
    for oldTerminal in [false, true] {
      let f = try await CodecFixture.ready()
      _ = try await f.upload()
      try await f.expect()
      let first = try await f.consume(f.success())
      let second = try f.request(ordinal: 2)
      let bridgeID = try SearchParentWriterIdentity(
        generation: f.generation, requestID: f.requestID, writerEpoch: 3)
      _ = try await f.upload(writerIdentity: bridgeID, request: second)
      try await f.run { try f.session.expect(token: f.token, identity: second.identity) }
      if oldTerminal {
        await expectFailure { _ = try await f.consume(f.terminal()) }
        XCTAssertEqual(f.sink.takes, 1)
      } else {
        let result = try await f.consume(f.body(ordinal: 2) + f.terminal(ordinal: 2))
        XCTAssertEqual(
          result,
          .terminal(
            .init(
              identity: second.identity, terminal: .success,
              output: .init(matches: [.init(location: 1, length: 2)], replacement: nil))))
        XCTAssertEqual(f.sink.takes, 2)
      }
      XCTAssertEqual(
        first,
        .terminal(
          .init(
            identity: f.identity, terminal: .success,
            output: .init(matches: [.init(location: 1, length: 2)], replacement: nil))))
      await f.stop()
    }
  }

  func testAdvertisedInputLengthMismatchNeverReturnsIndex() async throws {
    let f = try await CodecFixture.ready()
    let normal = try f.request()
    let wrong = try SearchWireRequest(
      identity: normal.identity, query: normal.query, operation: normal.operation, inputUTF16: 5,
      scope: nil, limits: normal.limits)
    await expectFailure { _ = try await f.upload(request: wrong) }
    await expectFailure { try await f.expect() }
    XCTAssertEqual(f.sink.discards, 1)
    await f.stop()
  }

  private func assertProgress(
    _ actual: SearchParentCodecProgress, _ expected: SearchParentCodecProgress,
    file: StaticString = #filePath, line: UInt = #line
  ) { XCTAssertEqual(actual, expected, file: file, line: line) }

  private func expectFailure(
    _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("expected failure", file: file, line: line)
    } catch {}
  }
}

final class CodecLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value
  init(_ value: Value) { storage = value }
  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func update(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }
}
struct CodecCounts {
  var emits = 0
  var factories = 0
}
final class CodecFixture: @unchecked Sendable {
  let generation = UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
  let requestID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
  let lane = SearchParentCodecLane()
  let counts = CodecLocked(CodecCounts())
  let sink = CodecAccumulator()
  var session: SearchParentWireCodecSession!
  var token: SearchParentCodecToken {
    try! .init(generation: generation, sessionEpoch: 1, operationID: requestID)
  }
  var identity: SearchWireIdentity {
    try! .init(generation: generation, requestID: requestID, ordinal: 1)
  }
  var hello: Data {
    frame(2, zero: true, payload: Data(uuidBytes(generation)) + le(1, 4) + le(0, 4))
  }
  static func readyForHello(factoryThrows: Bool = false, factoryReentry: Bool = false) async throws
    -> CodecFixture
  {
    let f = CodecFixture()
    f.session = try await f.run {
      try SearchParentWireCodecSession(token: f.token) { _ in
        f.counts.update { $0.factories += 1 }
        if factoryThrows { throw SearchError.engineFailure }
        if factoryReentry { _ = try? f.session.consume(token: f.token, bytes: Data()) }
        f.sink.owner = Thread.current
        return f.sink
      }
    }
    let bridge = SearchParentWireUploadBridge(
      identity: try .init(generation: f.generation, requestID: nil, writerEpoch: 1))
    try await f.produce(bridge) { try f.session.writeHello(token: f.token, bridge: bridge) }
    return f
  }
  static func ready(factoryThrows: Bool = false, factoryReentry: Bool = false) async throws
    -> CodecFixture
  {
    let f = try await readyForHello(factoryThrows: factoryThrows, factoryReentry: factoryReentry)
    _ = try await f.consume(f.hello)
    return f
  }
  func request(ordinal: UInt64 = 1) throws -> SearchWireRequest {
    try .init(
      identity: .init(generation: generation, requestID: requestID, ordinal: ordinal),
      query: .init(pattern: "😀", mode: .literal), operation: .find, inputUTF16: 4, scope: nil,
      limits: .init(
        maxTextUTF16: 10, maxOutputUTF16: 10, maxMatches: 10, cooperativeMilliseconds: 1))
  }
  func run<T>(token: SearchParentCodecToken? = nil, _ body: @escaping @Sendable () throws -> T)
    async throws -> T
  {
    let work = try lane.submit(token: token ?? self.token, body)
    return try await work.value()
  }
  func produce<T>(
    _ bridge: SearchParentWireUploadBridge, failAt: Int? = nil,
    writeHook: (@Sendable (Int) async -> Void)? = nil, _ body: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let local = CodecLocked(0)
    let consumer = Task {
      try await bridge.consume { _ in
        self.counts.update { $0.emits += 1 }
        local.update { $0 += 1 }
        if let writeHook { await writeHook(local.value) }
        if local.value == failAt { throw SearchChildFailure.channelFailure(5) }
      }
    }
    let result: Result<T, Error>
    do { result = .success(try await run(body)) } catch { result = .failure(error) }
    bridge.producerExited(result.map { _ in () })
    do { try await consumer.value } catch {
      if case .success = result { throw error }
    }
    return try result.get()
  }
  func upload(
    failAt: Int? = nil, writerIdentity: SearchParentWriterIdentity? = nil,
    request: SearchWireRequest? = nil, writeHook: (@Sendable (Int) async -> Void)? = nil
  ) async throws -> SearchParentRequestEncoded {
    let r = try request ?? self.request()
    let bridge = SearchParentWireUploadBridge(
      identity: try writerIdentity
        ?? .init(generation: generation, requestID: requestID, writerEpoch: 2))
    return try await produce(bridge, failAt: failAt, writeHook: writeHook) {
      try self.session.writeRequest(token: self.token, request: r, text: "A😀B", bridge: bridge)
    }
  }
  func expect() async throws {
    try await run { try self.session.expect(token: self.token, identity: self.identity) }
  }
  func consume(_ data: Data) async throws -> SearchParentCodecProgress {
    try await run { try self.session.consume(token: self.token, bytes: data) }
  }
  func stop() async {
    if session != nil { try? await run { try self.session.discard(token: self.token) } }
    lane.requestStop()
    try? await lane.waitForStop()
  }
  func body(range: NSRange = .init(location: 1, length: 2), ordinal: UInt64 = 1) -> Data {
    frame(
      32, payload: le(ordinal, 8) + le(1, 4) + le(0, 4) + le(0, 8) + Data(repeating: 0, count: 8))
      + frame(33, payload: le(UInt64(range.location), 8) + le(UInt64(range.length), 8))
  }
  func terminal(status: UInt64 = 0, ordinal: UInt64 = 1) -> Data {
    frame(35, payload: le(ordinal, 8) + le(status, 2) + Data(repeating: 0, count: 6))
  }
  func success() -> Data { body() + terminal() }
  func frame(_ kind: UInt64, zero: Bool = false, payload: Data) -> Data {
    Data([0x50, 0x53, 0x52, 0x58]) + le(1, 2) + le(kind, 2) + le(UInt64(payload.count), 4)
      + Data(repeating: 0, count: 4)
      + Data(zero ? Array(repeating: 0, count: 16) : uuidBytes(requestID)) + payload
  }
  func uuidBytes(_ value: UUID) -> [UInt8] {
    var bytes = value.uuid
    return withUnsafeBytes(of: &bytes) { Array($0) }
  }
  func le(_ value: UInt64, _ size: Int) -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
  }
}

final class CodecAccumulator: SearchParentWireResponseAccumulator, @unchecked Sendable {
  var owner: Thread?
  var sameThread = true
  var callbackDepth = 0
  var takesAfterUnwind = true
  var discardsAfterUnwind = true
  var ranges: [NSRange] = []
  var replacement = Data()
  var hasReplacement = false
  var terminal: SearchWireTerminal?
  var takes = 0
  var discards = 0
  var throwOnBegin = false
  var mutation = 0
  var reenterAt: String?
  var reenter: (() -> Void)?
  private func callback(_ name: String) {
    sameThread = sameThread && Thread.current === owner && !Thread.isMainThread
    callbackDepth += 1
    if reenterAt == name { reenter?() }
    callbackDepth -= 1
  }
  func helloAccepted(generation: UUID) throws { callback("hello") }
  func begin(_ response: SearchWireResponse) throws {
    hasReplacement = response.replacementUTF16 != nil
    callback("begin")
    if throwOnBegin { throw SearchError.engineFailure }
  }
  func appendRanges(_ ranges: [NSRange]) throws {
    callback("ranges")
    self.ranges += ranges
  }
  func appendReplacementUTF8(_ bytes: Data) throws {
    callback("replacement")
    replacement.append(bytes)
  }
  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    callback("complete")
    self.terminal = terminal
  }
  func takeTerminal(for identity: SearchWireIdentity) throws -> (
    terminal: SearchWireTerminal, output: SearchExecutionOutput?
  ) {
    takesAfterUnwind = takesAfterUnwind && callbackDepth == 0
    callback("take")
    takes += 1
    let t = terminal ?? .success
    if mutation == 1 { return (t, nil) }
    if mutation == 2 { return (.failure(.engineFailure), nil) }
    if mutation == 3 { return (t, .init(matches: [], replacement: nil)) }
    if mutation == 4 { return (t, .init(matches: ranges, replacement: "")) }
    if case .failure = t {
      ranges.removeAll()
      return (t, nil)
    }
    return (
      t,
      .init(
        matches: ranges,
        replacement: hasReplacement ? String(decoding: replacement, as: UTF8.self) : nil)
    )
  }
  func discard() {
    discardsAfterUnwind = discardsAfterUnwind && callbackDepth == 0
    callback("discard")
    discards += 1
    ranges.removeAll()
    replacement.removeAll()
    hasReplacement = false
    terminal = nil
  }
}

private actor CodecAsyncGate {
  private var opened = false
  private var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    opened = true
    waiter?.resume()
    waiter = nil
  }
}
