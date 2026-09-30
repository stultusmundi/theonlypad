import CryptoKit
import Darwin
import Dispatch
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// REAL children: root executes only after ownership/source review under the
/// accepted direct watchdog. Not selected by the default deterministic filter.
final class SearchChildSpawnInheritanceTests: XCTestCase {
  func testFoundationPeerRemainsAliveWhileHelperLifetimeEOFIsReaped() async throws {
    let helperURL = try artifact(.helper)
    let peerURL = try artifact(.peer)
    let events = InheritanceEvents()
    let gate = ProcessSpawnGate(onContention: { events.record("contended") })
    let operations = HeldLifetimeOperations(base: SearchChildLauncher().operations, events: events)
    let launcher = SearchChildLauncher(
      arguments: ["--mode", "parent-lifetime-busy-main"], operations: operations,
      coordinator: SearchLaunchCoordinator(spawnGate: gate)
    ) { SearchChildChannels(requestWriteFD: $0, responseReadFD: $1, lifetimeWriteFD: $2) }
    let system = InheritanceRecordingSystem(launcher)
    let timers = DispatchQueue(label: "inheritance.fixture.timers")
    let lifecycle = try SearchChildLifecycle(
      executable: helperURL,
      policy: SearchChildPolicy(
        operationNanoseconds: 20_000_000_000, reapGraceNanoseconds: 1_000_000_000,
        idleNanoseconds: 20_000_000_000, maximumRequestsPerChild: 1),
      system: system, now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { SearchChildDispatchTimer(deadline: $0, queue: timers, action: $1) })
    let peer = try InheritancePeerOwner(executable: peerURL, gate: gate, events: events)
    var start: Task<Void, Error>?
    var failure: Error?
    defer { operations.release.signal() }
    do {
      let ticket = try await lifecycle.begin(requestID: UUID())
      try require(events.next() == "pipeHeld", "lifetime pipe did not reach controlled hold")
      start = Task { try await peer.start() }
      // Exact-lock failed try, not mere task submission. A bypassed gate emits
      // peerSpawned/peerFailed here instead; all branches release the hold.
      try require(events.next() == "contended", "Foundation did not contend on held gate")
      operations.release.signal()
      try await start!.value
      try require(!operations.holdTimedOut, "lifetime hold timed out")
      let connection = try await lifecycle.connection(for: ticket)
      let metadata = try await helperReadiness(connection)
      try require(
        metadata["generation"] as? String == ticket.identity.generation.uuidString,
        "helper generation mismatch")
      try require(metadata["mainLoopEntered"] as? Bool == true, "helper main-loop marker absent")
      try require(await peer.isAlive(), "peer exited before helper control close")
      await connection.close()
      let outcome = try await lifecycle.wait(for: ticket)
      try require(outcome == .failed(.unexpectedExit), "helper did not independently exit")
      var exactExit = false
      for _ in 0..<30 {
        if case .reaped(let generation, let exit) = try await lifecycle.cleanup(for: ticket) {
          exactExit = generation == ticket.identity.generation && exit == .exited(0)
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      try require(exactExit, "helper did not produce exact exit0/reap receipt")
      let settled = await lifecycle.shutdown()
      try require(settled.stopped && settled.channelsClosed, "helper channels not settled")
      let childPID = system.pid
      try require(
        childPID != nil && operations.waitedPIDs.allSatisfy { $0 == childPID! }
          && !operations.waitedPIDs.isEmpty, "sole reaper PID mismatch")
      // stdin writer is still retained here: unrelated-peer exit cannot explain EOF.
      try require(
        await peer.isAlive(), "peer must remain alive through helper reap and channel close")
    } catch { failure = error }

    // Release first, including early assertion failure. A successful raw pipe
    // allocation must be returned to the real launcher, never hidden on timeout.
    operations.release.signal()
    if let start {
      do { try await start.value } catch { if failure == nil { failure = error } }
    }
    let helperCleanup = await lifecycle.shutdown()
    if !helperCleanup.stopped && failure == nil {
      failure = InheritanceFailure("helper cleanup uncertain")
    }
    let peerCleanup = await peer.finish()
    XCTAssertTrue(helperCleanup.stopped, "helper failure cleanup must settle exact ownership")
    XCTAssertTrue(peerCleanup.closed, "peer descriptor closure was not confirmed")
    XCTAssertTrue(peerCleanup.waited || !peerCleanup.launched, "peer wait was not confirmed")
    if failure == nil {
      XCTAssertTrue(peerCleanup.launched)
      XCTAssertTrue(peerCleanup.normalEOF)
      XCTAssertEqual(peerCleanup.exitCode, 0)
    }
    if let failure { throw failure }
  }

  private func helperReadiness(_ connection: any SearchChildConnection) async throws -> [String:
    Any]
  {
    var bytes = Data()
    for _ in 0..<2_048 {
      let part = try await connection.read(maxBytes: 1)
      guard part.count == 1 else { throw InheritanceFailure("short helper readiness") }
      if part[0] == 10 {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
          throw InheritanceFailure("invalid helper readiness")
        }
        return object
      }
      bytes.append(part)
    }
    throw InheritanceFailure("oversized helper readiness")
  }

  private enum Artifact: Equatable {
    case helper, peer
    var metadata: String { self == .helper ? "fixture.json" : "peer.json" }
    var folder: String { self == .helper ? "FrozenFixture" : "FrozenPeer" }
    var name: String { self == .helper ? "SearchChildFixture" : "SpawnPeerFixture" }
  }

  private func artifact(_ kind: Artifact) throws -> URL {
    var run = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { run.deleteLastPathComponent() }
    let sourceBytes = try Data(contentsOf: run.appendingPathComponent("sources.json"))
    let sourceHash = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: run.appendingPathComponent(kind.metadata))) as? [String: Any])
    let executable = run.appendingPathComponent("Build/\(kind.folder)/\(kind.name)")
    guard object["executable"] as? String == executable.path,
      object["sourceManifestSHA256"] as? String == sourceHash
    else { throw InheritanceFailure("artifact source binding mismatch") }
    var cursor = run
    for component in ["Build", kind.folder, kind.name] {
      cursor.appendPathComponent(component)
      var info = stat()
      guard lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
        throw InheritanceFailure("artifact path refused")
      }
    }
    let observed = SHA256.hash(data: try Data(contentsOf: executable)).map {
      String(format: "%02x", $0)
    }.joined()
    guard object["sha256"] as? String == observed else {
      throw InheritanceFailure("artifact changed")
    }
    return executable
  }

  private func require(_ value: Bool, _ reason: String) throws {
    if !value { throw InheritanceFailure(reason) }
  }
}

private struct InheritanceFailure: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}

private final class InheritanceLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func access<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

private final class InheritanceEvents: @unchecked Sendable {
  private let values = InheritanceLocked<[String]>([])
  private let signal = DispatchSemaphore(value: 0)
  func record(_ value: String) {
    values.access { $0.append(value) }
    signal.signal()
  }
  func next() -> String? {
    guard signal.wait(timeout: .now() + 3) == .success else { return nil }
    return values.access { $0.removeFirst() }
  }
}

private final class HeldLifetimeOperations: LaunchOperations, @unchecked Sendable {
  let base: any LaunchOperations
  let events: InheritanceEvents
  let release = DispatchSemaphore(value: 0)
  private var pipeCount = 0  // Actual launcher's one serial spawn lane only.
  private let timeout = InheritanceLocked(false)
  private let waits = InheritanceLocked<[Int32]>([])
  private let holdInterval: DispatchTimeInterval
  var holdTimedOut: Bool { timeout.access { $0 } }
  var waitedPIDs: [Int32] { waits.access { $0 } }
  init(
    base: any LaunchOperations, events: InheritanceEvents,
    holdInterval: DispatchTimeInterval = .seconds(8)
  ) {
    self.base = base
    self.events = events
    self.holdInterval = holdInterval
  }
  func pipe() throws -> (Int32, Int32) {
    let pair = try base.pipe()
    pipeCount += 1
    if pipeCount == 3 {
      events.record("pipeHeld")
      if release.wait(timeout: .now() + holdInterval) != .success { timeout.access { $0 = true } }
    }
    return pair  // ALWAYS return both owned FDs after successful allocation.
  }
  func validateExecutable(_ path: String) throws { try base.validateExecutable(path) }
  func reaperPolicy() throws -> LaunchReaperPolicy { try base.reaperPolicy() }
  func openNull() throws -> Int32 { try base.openNull() }
  func setAndVerify(_ flag: LaunchFlag, fd: Int32) throws { try base.setAndVerify(flag, fd: fd) }
  func duplicateAboveStdio(_ fd: Int32) throws -> Int32 { try base.duplicateAboveStdio(fd) }
  func close(_ fd: Int32) -> Int32 { base.close(fd) }
  func makeSpawn() -> any LaunchSpawnOperations { base.makeSpawn() }
  func signal(_ pid: Int32, _ signal: Int32) -> Int32 { base.signal(pid, signal) }
  func wait(_ pid: Int32) -> LaunchWaitResult {
    waits.access { $0.append(pid) }
    return base.wait(pid)
  }
}

private final class InheritanceRecordingSystem: SearchChildSystem, @unchecked Sendable {
  private let launcher: SearchChildLauncher
  private let recordedPID = InheritanceLocked<Int32?>(nil)
  var pid: Int32? { recordedPID.access { $0 } }
  init(_ launcher: SearchChildLauncher) { self.launcher = launcher }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    launcher.launch(executable: executable, generation: generation) { [self] result in
      if case .success(let child) = result { recordedPID.access { $0 = child.pid } }
      completion(result)
    }
  }
  func signal(pid: Int32, signal: Int32) -> Int32 { launcher.signal(pid: pid, signal: signal) }
  func pollExit(pid: Int32) -> SearchChildPoll { launcher.pollExit(pid: pid) }
}

private final class PeerHandle {
  let handle: FileHandle
  private var consumed = false
  private(set) var confirmed = false
  init(_ handle: FileHandle) { self.handle = handle }
  func close() {
    guard !consumed else { return }
    consumed = true
    do {
      try handle.close()
      confirmed = true
    } catch {
      // Retained; never retry this integer.
    }
  }
}

private struct PeerCleanup: Sendable {
  let launched: Bool
  let waited: Bool
  let closed: Bool
  let normalEOF: Bool
  let exitCode: Int32?
}

private final class InheritancePeerOwner: @unchecked Sendable {
  private let queue = DispatchQueue(label: "inheritance.foundation.peer")
  private let process = Process()
  private let gate: ProcessSpawnGate
  private let events: InheritanceEvents
  private let terminated = DispatchSemaphore(value: 0)
  private let input: Pipe
  private let output: Pipe
  private let inputRead: PeerHandle
  private let inputWrite: PeerHandle
  private let outputRead: PeerHandle
  private let outputWrite: PeerHandle
  private var launched = false
  private var receipt: PeerCleanup?

  init(executable: URL, gate: ProcessSpawnGate, events: InheritanceEvents) throws {
    self.gate = gate
    self.events = events
    input = Pipe()
    output = Pipe()
    inputRead = PeerHandle(input.fileHandleForReading)
    inputWrite = PeerHandle(input.fileHandleForWriting)
    outputRead = PeerHandle(output.fileHandleForReading)
    outputWrite = PeerHandle(output.fileHandleForWriting)
    process.executableURL = executable
    process.arguments = []
    process.environment = ["LANG": "C", "LC_ALL": "C"]
    // FileHandle ownership stays here; do not delegate Pipe's parent-end closure.
    process.standardInput = inputRead.handle
    process.standardOutput = outputWrite.handle
    process.standardError = FileHandle.nullDevice
    let signal = terminated
    process.terminationHandler = { _ in signal.signal() }
    let fd = outputRead.handle.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      for handle in [inputRead, inputWrite, outputRead, outputWrite] { handle.close() }
      if ![inputRead, inputWrite, outputRead, outputWrite].allSatisfy(\.confirmed) {
        PeerQuarantine.retain(self)
      }
      throw InheritanceFailure("peer nonblocking setup failed")
    }
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        do {
          try gate.run(process)
          launched = true
          events.record("peerSpawned")
          inputRead.close()
          outputWrite.close()
          guard inputRead.confirmed && outputWrite.confirmed else {
            throw InheritanceFailure("peer parent child-ends close uncertain")
          }
          try readReadiness()
          continuation.resume()
        } catch {
          events.record("peerFailed")
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func isAlive() async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { [self] in continuation.resume(returning: launched && process.isRunning) }
    }
  }

  func finish() async -> PeerCleanup {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if let receipt {
          continuation.resume(returning: receipt)
          return
        }
        inputWrite.close()
        var observed = !launched
        var normalEOF = true
        if launched {
          observed = terminated.wait(timeout: .now() + 3) == .success
          if !observed {
            normalEOF = false
            if process.isRunning { process.terminate() }
            observed = terminated.wait(timeout: .now() + 3) == .success
          }
        }
        var waited = false
        var exitCode: Int32?
        if launched && observed && !process.isRunning {
          process.waitUntilExit()  // Foundation's one wait owner; never raw waitpid.
          waited = true
          if process.terminationReason == .exit { exitCode = process.terminationStatus }
        }
        for handle in [inputRead, inputWrite, outputRead, outputWrite] { handle.close() }
        let closed = [inputRead, inputWrite, outputRead, outputWrite].allSatisfy(\.confirmed)
        let value = PeerCleanup(
          launched: launched, waited: waited, closed: closed,
          normalEOF: normalEOF, exitCode: exitCode)
        receipt = value
        if !closed || (launched && !waited) { PeerQuarantine.retain(self) }
        continuation.resume(returning: value)
      }
    }
  }

  private func readReadiness() throws {
    let expected = Data([82, 69, 65, 68, 89, 10])
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    var bytes = Data()
    let fd = outputRead.handle.fileDescriptor
    while bytes.count < expected.count && DispatchTime.now().uptimeNanoseconds < deadline {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = poll(&descriptor, 1, 25)
      if ready < 0 {
        if errno == EINTR { continue }
        throw InheritanceFailure("peer readiness poll failed")
      }
      if ready == 0 { continue }
      var byte: UInt8 = 0
      let count = Darwin.read(fd, &byte, 1)
      if count == 1 {
        bytes.append(byte)
      } else if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) {
        continue
      } else {
        throw InheritanceFailure("peer readiness ended early")
      }
    }
    guard bytes == expected else { throw InheritanceFailure("peer readiness timed out or changed") }
  }
}

private enum PeerQuarantine {
  private static let retained = InheritanceLocked<[InheritancePeerOwner]>([])
  static func retain(_ owner: InheritancePeerOwner) {
    retained.access {
      precondition($0.count < 4, "bounded peer fixture quarantine exhausted")
      $0.append(owner)
    }
  }
}

/// No OS descriptors/children: verifies the decorator never hides a successfully
/// allocated pair when its diagnostic hold expires or is released.
final class SearchChildSpawnInheritanceFixtureTests: XCTestCase {
  func testTimedOutHoldStillReturnsBothOwnedDescriptors() throws {
    let base = InheritanceFakePipes()
    let operations = HeldLifetimeOperations(
      base: base, events: InheritanceEvents(), holdInterval: .nanoseconds(0))
    _ = try operations.pipe()
    _ = try operations.pipe()
    let pair = try operations.pipe()
    XCTAssertEqual([pair.0, pair.1], [14, 15])
    XCTAssertTrue(operations.holdTimedOut)
    XCTAssertEqual(base.allocated, 6)
  }

  func testReleasedHoldReturnsPairWithoutTimeout() throws {
    let base = InheritanceFakePipes()
    let operations = HeldLifetimeOperations(
      base: base, events: InheritanceEvents(), holdInterval: .nanoseconds(0))
    operations.release.signal()
    _ = try operations.pipe()
    _ = try operations.pipe()
    let pair = try operations.pipe()
    XCTAssertEqual([pair.0, pair.1], [14, 15])
    XCTAssertFalse(operations.holdTimedOut)
  }
}

private final class InheritanceFakePipes: LaunchOperations, @unchecked Sendable {
  var allocated: Int32 = 0
  func pipe() throws -> (Int32, Int32) {
    let read = 10 + allocated
    allocated += 2
    return (read, read + 1)
  }
  func validateExecutable(_ path: String) throws { fatalError("unused fake operation") }
  func reaperPolicy() throws -> LaunchReaperPolicy { fatalError("unused fake operation") }
  func openNull() throws -> Int32 { fatalError("unused fake operation") }
  func setAndVerify(_ flag: LaunchFlag, fd: Int32) throws { fatalError("unused fake operation") }
  func duplicateAboveStdio(_ fd: Int32) throws -> Int32 { fatalError("unused fake operation") }
  func close(_ fd: Int32) -> Int32 { fatalError("unused fake operation") }
  func makeSpawn() -> any LaunchSpawnOperations { fatalError("unused fake operation") }
  func signal(_ pid: Int32, _ signal: Int32) -> Int32 { fatalError("unused fake operation") }
  func wait(_ pid: Int32) -> LaunchWaitResult { fatalError("unused fake operation") }
}
