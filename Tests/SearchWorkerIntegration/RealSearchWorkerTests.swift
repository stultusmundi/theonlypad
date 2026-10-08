import CryptoKit
import Darwin
import Dispatch
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Actual fixed helper, real parent protocol and exact owned lifecycle.
/// Run only with the frozen coordinator and its direct owned-process watchdog.
final class RealSearchWorkerTests: XCTestCase {
  // Break: treating supplementary scalars as one UTF16 unit shifts both ranges.
  func testUnicodeFindUsesLiteralUTF16Ranges() async throws {
    try await withHelper { helper in
      let result = try await helper.success(
        text: "x😀e\u{301}😀", pattern: "😀", operation: .find)
      XCTAssertEqual(
        result.matches, [NSRange(location: 1, length: 2), NSRange(location: 5, length: 2)])
      XCTAssertNil(result.replacement)
    }
  }

  // Break: an echo engine or dropped capture expansion cannot produce this output.
  func testRegexCaptureReplacementUsesRealEngine() async throws {
    try await withHelper { helper in
      let result = try await helper.success(
        text: "é猫 😀 é猫", pattern: "(é)(猫)", mode: .regex,
        operation: .replace(template: "$2:$1"))
      XCTAssertEqual(
        result.matches, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
      XCTAssertEqual(
        Array(try XCTUnwrap(result.replacement).utf16),
        [0x732B, 0x003A, 0x00E9, 0x0020, 0xD83D, 0xDE00, 0x0020, 0x732B, 0x003A, 0x00E9])
    }
  }

  // Break: BOM stripping, NUL truncation, normalization or newline conversion loses units.
  func testNoMatchReplacementPreservesEveryLiteralCodeUnit() async throws {
    try await withHelper { helper in
      let result = try await helper.success(
        text: "\u{FEFF}A\0e\u{301}\u{FEFF}😀\r\nB\rC\n", pattern: "absent",
        operation: .replace(template: "unused"))
      XCTAssertEqual(result.matches, [])
      XCTAssertEqual(
        Array(try XCTUnwrap(result.replacement).utf16),
        [
          0xFEFF, 0x0041, 0, 0x0065, 0x0301, 0xFEFF, 0xD83D, 0xDE00,
          0x000D, 0x000A, 0x0042, 0x000D, 0x0043, 0x000A,
        ])
    }
  }

  // Break: terminating/replacing the child after invalidPattern violates healthy reuse.
  func testSemanticErrorThenHealthyRequestUsesSameGeneration() async throws {
    try await withHelper { helper in
      let first = try await helper.request(text: "x", pattern: "(", mode: .regex, operation: .find)
      guard case .semanticFailure(let failedIdentity, let error) = first else {
        throw HelperTestFailure("Expected invalidPattern terminal")
      }
      XCTAssertEqual(error, .invalidPattern)
      let second = try await helper.request(text: "x😀e\u{301}😀", pattern: "😀", operation: .find)
      guard case .completed(let healthyIdentity, _, let output) = second else {
        throw HelperTestFailure("Expected healthy result after semantic failure")
      }
      XCTAssertEqual(healthyIdentity.generation, failedIdentity.generation)
      XCTAssertEqual(healthyIdentity.ordinal, failedIdentity.ordinal + 1)
      XCTAssertNotEqual(healthyIdentity.requestID, failedIdentity.requestID)
      XCTAssertEqual(
        output.matches, [NSRange(location: 1, length: 2), NSRange(location: 5, length: 2)])
      XCTAssertNil(output.replacement)
    }
  }

  // Break: dropping empty terminals or assuming write boundaries corrupts subsequent Unicode.
  func testEmptyThenFragmentedSupplementaryReplacement() async throws {
    try await withHelper(fragment: true) { helper in
      let empty = try await helper.success(
        text: "", pattern: "x", operation: .replace(template: "y"))
      XCTAssertEqual(empty.matches, [])
      XCTAssertEqual(Array(try XCTUnwrap(empty.replacement).utf16), [])
      let changed = try await helper.success(
        text: "A😀B", pattern: "😀", operation: .replace(template: "💡"))
      XCTAssertEqual(changed.matches, [NSRange(location: 1, length: 2)])
      XCTAssertEqual(
        Array(try XCTUnwrap(changed.replacement).utf16), [0x0041, 0xD83D, 0xDCA1, 0x0042])
      let writes = helper.observations.snapshot
      XCTAssertGreaterThan(writes.forwardedWrites, writes.originalWrites)
      XCTAssertGreaterThan(writes.forwardedWrites, 1)
      // Pipes may coalesce these actual writes; no separate-read/inputChunk claim.
    }
  }

  private func withHelper(
    fragment: Bool = false, _ body: (RealHelperHarness) async throws -> Void
  ) async throws {
    let helper = try RealHelperHarness(fragment: fragment)
    var failure: Error?
    do { try await body(helper) } catch { failure = error }
    // Always settle the retained production owner, including assertion/throwing failures.
    await helper.finish()
    do { try helper.artifact.verify() } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
  }
}

private struct HelperTestFailure: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}

private struct HelperArtifact: Decodable {
  let version: Int
  let mode: String
  let executable: String
  let sha256: String
  let sourceManifestSHA256: String
  let applicationBundle: String?
  var run: URL? = nil

  static func load() throws -> Self {
    var run = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { run.deleteLastPathComponent() }
    var value = try JSONDecoder().decode(
      Self.self, from: Data(contentsOf: run.appendingPathComponent("helper.json")))
    value.run = run
    try value.verify()
    return value
  }
  func verify() throws {
    guard version == 1, let run,
      hash(try Data(contentsOf: run.appendingPathComponent("sources.json"))) == sourceManifestSHA256
    else { throw HelperTestFailure("Source manifest binding mismatch") }
    let expected: URL
    if mode == "built" {
      guard applicationBundle == nil else { throw HelperTestFailure("Unexpected bundle override") }
      expected = run.appendingPathComponent("Build/FrozenHelper/PadSearchWorker")
    } else if mode == "packaged", let applicationBundle {
      expected = try SearchWorkerBundleResolver.candidate(
        in: URL(fileURLWithPath: applicationBundle))
    } else {
      throw HelperTestFailure("Unknown artifact mode")
    }
    guard expected.path == executable else { throw HelperTestFailure("Unexpected helper path") }
    var cursor = URL(fileURLWithPath: "/")
    for component in expected.pathComponents.dropFirst() {
      cursor.appendPathComponent(component)
      var info = stat()
      guard lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
        throw HelperTestFailure("Symlink or missing artifact component")
      }
    }
    _ = try SearchWorkerBundleResolver.validateForLaunch(expected)
    let data = try Data(contentsOf: expected)
    guard !data.isEmpty, hash(data) == sha256 else {
      throw HelperTestFailure("Helper bytes changed")
    }
  }
  private func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}

private struct HelperObservedState {
  struct Launch {
    let generation: UUID
    let pid: Int32
  }
  struct Signal {
    let pid: Int32
    let signal: Int32
    let result: Int32
  }
  struct Reap {
    let pid: Int32
    let exit: SearchChildExit
  }
  var launches: [Launch] = []
  var signals: [Signal] = []
  var reaps: [Reap] = []
  var pollFailures: [Int32] = []
  var released: [UUID] = []
  var originalWrites = 0
  var forwardedWrites = 0
}

private final class HelperObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var value = HelperObservedState()
  func update(_ body: (inout HelperObservedState) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&value)
  }
  var snapshot: HelperObservedState {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Delegates every authority-bearing operation to the real default launcher.
/// Recording never polls, signals, closes descriptors or substitutes a result.
private final class ObservedHelperSystem: SearchChildSystem, @unchecked Sendable {
  let base = SearchChildLauncher()
  let observations: HelperObservations
  let fragment: Bool
  init(observations: HelperObservations, fragment: Bool) {
    self.observations = observations
    self.fragment = fragment
  }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    base.launch(executable: executable, generation: generation) { [self] result in
      switch result {
      case .success(let child):
        observations.update { $0.launches.append(.init(generation: generation, pid: child.pid)) }
        let connection: any SearchChildConnection =
          fragment
          ? FragmentedHelperConnection(base: child.connection, observations: observations)
          : child.connection
        completion(
          .success(
            SearchLaunchedChild(
              pid: child.pid, connection: connection, startupFailure: child.startupFailure)))
      case .failure: completion(result)
      }
    }
  }
  func signal(pid: Int32, signal: Int32) -> Int32 {
    let result = base.signal(pid: pid, signal: signal)
    observations.update { $0.signals.append(.init(pid: pid, signal: signal, result: result)) }
    return result
  }
  func pollExit(pid: Int32) -> SearchChildPoll {
    let result = base.pollExit(pid: pid)
    observations.update {
      switch result {
      case .reaped(let exit): $0.reaps.append(.init(pid: pid, exit: exit))
      case .failed(let code): $0.pollFailures.append(code)
      case .running, .interrupted: break
      }
    }
    return result
  }
}

/// Only chunks actual outbound bytes; reads/closure delegate unchanged.
private final class FragmentedHelperConnection: SearchChildConnection, @unchecked Sendable {
  let base: any SearchChildConnection
  let observations: HelperObservations
  init(base: any SearchChildConnection, observations: HelperObservations) {
    self.base = base
    self.observations = observations
  }
  func write(_ bytes: Data) async throws {
    observations.update { $0.originalWrites += 1 }
    for start in stride(from: bytes.startIndex, to: bytes.endIndex, by: 3) {
      try await base.write(Data(bytes[start..<min(start + 3, bytes.endIndex)]))
      observations.update { $0.forwardedWrites += 1 }
    }
  }
  func read(maxBytes: Int) async throws -> Data { try await base.read(maxBytes: maxBytes) }
  func close() async { await base.close() }
}

private final class RealHelperHarness {
  let artifact: HelperArtifact
  let observations: HelperObservations
  let driver: SearchParentWireDriver
  var latest: SearchParentWireHandle?
  private var ordinal: UInt64 = 0
  init(fragment: Bool) throws {
    let artifact = try HelperArtifact.load()
    self.artifact = artifact
    let observations = HelperObservations()
    self.observations = observations
    let timers = DispatchQueue(label: "search.worker.integration.timers")
    let lifecycle = try SearchChildLifecycle(
      executable: URL(fileURLWithPath: artifact.executable),
      policy: SearchChildPolicy(
        operationNanoseconds: 10_000_000_000, reapGraceNanoseconds: 2_000_000_000,
        idleNanoseconds: 10_000_000_000, maximumRequestsPerChild: 8),
      system: ObservedHelperSystem(observations: observations, fragment: fragment),
      now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { SearchChildDispatchTimer(deadline: $0, queue: timers, action: $1) })
    driver = try SearchParentWireDriver(
      lifecycle: lifecycle, accumulatorFactory: { SearchParentResponseAccumulator(request: $0) },
      maximumWireBytesPerChild: 1_000_000,
      observe: {
        if case .sessionReleased(let generation) = $0 {
          observations.update { $0.released.append(generation) }
        }
      })
  }
  func request(
    text: String, pattern: String, mode: SearchMode = .literal, operation: SearchExecutionOperation
  ) async throws -> SearchParentWireOutcome {
    let id = UUID()
    let job = try SearchParentWireJob(
      requestID: id, query: SearchQuery(pattern: pattern, mode: mode), operation: operation,
      text: text, inputUTF16: text.utf16.count, scope: nil,
      // Zero is an immediate deadline; these benign protocol fixtures need time to succeed.
      limits: SearchWireLimits(
        maxTextUTF16: 128, maxOutputUTF16: 256, maxMatches: 16, cooperativeMilliseconds: 1_000))
    let handle = try await driver.submit(job)
    latest = handle
    let outcome = try await driver.wait(for: handle)
    ordinal += 1
    let identity: SearchWireIdentity
    switch outcome {
    case .completed(let received, let source, _):
      identity = received
      guard Array(source.utf16) == Array(text.utf16) else {
        throw HelperTestFailure("Source changed")
      }
    case .semanticFailure(let received, _): identity = received
    case .failed: throw HelperTestFailure("Parent protocol/lifecycle failed")
    }
    let observed = observations.snapshot
    guard observed.launches.count == 1, let child = observed.launches.first, child.pid > 0,
      identity.generation == child.generation, identity.requestID == id,
      identity.ordinal == ordinal,
      observed.signals.isEmpty, observed.reaps.isEmpty
    else { throw HelperTestFailure("Result lacks live exact generation/PID/request binding") }
    return outcome
  }
  func success(
    text: String, pattern: String, mode: SearchMode = .literal, operation: SearchExecutionOperation
  ) async throws -> SearchExecutionOutput {
    let outcome = try await request(
      text: text, pattern: pattern, mode: mode, operation: operation)
    switch outcome {
    case .completed(_, _, let output):
      return output
    case .semanticFailure(let identity, let error):
      throw HelperTestFailure(
        "Expected successful terminal; received semanticFailure \(error) "
          + "generation=\(identity.generation.uuidString) ordinal=\(identity.ordinal)")
    case .failed(_, let failure):
      throw HelperTestFailure("Expected successful terminal; received lifecycle failure \(failure)")
    }
  }
  func finish() async {
    let result = await driver.shutdownJoined(after: latest)
    guard case .completed(let receipt) = result else {
      XCTFail("Joined shutdown owner refused")
      return
    }
    XCTAssertEqual(receipt.ownership, .admitted)
    XCTAssertEqual(receipt.laneStop, .acknowledged)
    XCTAssertTrue(receipt.shutdown.child.stopped)
    XCTAssertTrue(receipt.shutdown.child.channelsClosed)
    XCTAssertEqual(receipt.shutdown.child.cleanup, .noChild)
    XCTAssertTrue(receipt.shutdown.parentLaneSettled)
    XCTAssertEqual(receipt.shutdown.retainedParentLanes, 0)
    let observed = observations.snapshot
    XCTAssertEqual(observed.launches.count, 1)
    XCTAssertEqual(observed.reaps.count, 1)
    XCTAssertEqual(observed.pollFailures, [])
    guard let child = observed.launches.first, let reap = observed.reaps.first else { return }
    XCTAssertEqual(reap.pid, child.pid)
    XCTAssertEqual(observed.released, [child.generation])
    XCTAssertLessThanOrEqual(observed.signals.count, 1)
    for signal in observed.signals {
      XCTAssertEqual(signal.pid, child.pid)
      XCTAssertEqual(signal.signal, SIGKILL)
      XCTAssertTrue(signal.result == 0 || signal.result == ESRCH)
    }
    switch reap.exit {
    case .exited(let code): XCTAssertEqual(code, 0)
    case .signaled(let signal):
      XCTAssertEqual(signal, SIGKILL)
      XCTAssertTrue(
        observed.signals.contains { $0.pid == child.pid && $0.signal == SIGKILL && $0.result == 0 })
    }
    // Ordinary synthetic identity/status only; raw records remain in ignored capture.
    let exit: String
    switch reap.exit {
    case .exited(let code): exit = "exited:\(code)"
    case .signaled(let signal): exit = "signaled:\(signal)"
    }
    print(
      "WORKER-SETTLED generation=\(child.generation.uuidString) pid=\(child.pid) exit=\(exit) reaps=\(observed.reaps.count) signals=\(observed.signals.count) released=\(observed.released.count)"
    )
    for signal in observed.signals {
      print(
        "WORKER-SIGNAL generation=\(child.generation.uuidString) pid=\(signal.pid) signal=\(signal.signal) result=\(signal.result)"
      )
    }
  }
}
