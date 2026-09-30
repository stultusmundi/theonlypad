import Darwin
import Dispatch
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Injected queue/control collaboration, no descriptors allocated and no child.
final class SearchWorkerResolverLaneTests: XCTestCase {
  func testValidationRunsAfterAdmissionDeadlineOnRetainedPreparationQueue() async throws {
    let clock = ResolverClock()
    let entered = expectation(description: "preparation entered")
    let operations = ResolverHeldOperations(clock: clock, entered: entered)
    let coordinator = SearchLaunchCoordinator(spawnGate: ProcessSpawnGate())
    coordinator.queue.setSpecific(key: operations.queueKey, value: 1)
    let launcher = SearchChildLauncher(operations: operations, coordinator: coordinator) {
      _, _, _ in
      fatalError("fixture fails validation before channel adoption")
    }
    let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
      "absent-resolver-" + UUID().uuidString, isDirectory: false)
    let lifecycle = try SearchChildLifecycle(
      executable: executable,
      policy: SearchChildPolicy(
        operationNanoseconds: 100, reapGraceNanoseconds: 10,
        idleNanoseconds: 100, maximumRequestsPerChild: 1),
      system: launcher, now: { clock.now }, schedule: { clock.schedule($0, $1) })
    XCTAssertFalse(operations.observed.value.entered)
    let ticket = try await lifecycle.begin(requestID: UUID())
    defer { operations.release.signal() }
    await fulfillment(of: [entered], timeout: 1)
    XCTAssertTrue(operations.observed.value.deadlineWasArmed)
    XCTAssertTrue(operations.observed.value.onPreparationQueue)
    XCTAssertFalse(operations.observed.value.onMainThread)
    await MainActor.run { XCTAssertTrue(Thread.isMainThread) }
    let pending = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(pending, .pendingLaunch(generation: ticket.identity.generation))
    clock.advanceToDeadline()
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.deadline))
    XCTAssertFalse(operations.observed.value.resolverReturned)
    operations.release.signal()
    let stopped = await lifecycle.shutdown()
    XCTAssertTrue(stopped.stopped)
    XCTAssertTrue(stopped.channelsClosed)
    XCTAssertFalse(operations.observed.value.holdTimedOut)
    XCTAssertTrue(operations.observed.value.resolverRejectedMissing)
  }
}

private final class ResolverLocked<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: T
  init(_ value: T) { storage = value }
  var value: T {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func update(_ body: (inout T) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }
}
private final class ResolverTimer: SearchChildTimer, @unchecked Sendable {
  private let action: @Sendable () -> Void
  private let active = ResolverLocked(true)
  init(_ action: @escaping @Sendable () -> Void) { self.action = action }
  func cancel() { active.update { $0 = false } }
  func fire() {
    var shouldFire = false
    active.update {
      shouldFire = $0
      $0 = false
    }
    if shouldFire { action() }
  }
}
private final class ResolverClock: @unchecked Sendable {
  private struct State {
    var now: UInt64 = 0
    var scheduled: [(UInt64, ResolverTimer)] = []
  }
  private let state = ResolverLocked(State())
  var now: UInt64 { state.value.now }
  var armed: Bool { !state.value.scheduled.isEmpty }
  func schedule(_ deadline: UInt64, _ action: @escaping @Sendable () -> Void)
    -> any SearchChildTimer
  {
    let timer = ResolverTimer(action)
    state.update { $0.scheduled.append((deadline, timer)) }
    return timer
  }
  func advanceToDeadline() {
    var timer: ResolverTimer?
    state.update {
      guard !$0.scheduled.isEmpty else { return }
      let item = $0.scheduled.removeFirst()
      $0.now = item.0
      timer = item.1
    }
    timer?.fire()
  }
}
private final class ResolverHeldOperations: LaunchOperations, @unchecked Sendable {
  struct Observation {
    var entered = false
    var deadlineWasArmed = false
    var onPreparationQueue = false
    var onMainThread = false
    var holdTimedOut = false
    var resolverReturned = false
    var resolverRejectedMissing = false
  }
  let observed = ResolverLocked(Observation())
  let release = DispatchSemaphore(value: 0)
  let queueKey = DispatchSpecificKey<Int>()
  private let clock: ResolverClock
  private let entered: XCTestExpectation
  init(clock: ResolverClock, entered: XCTestExpectation) {
    self.clock = clock
    self.entered = entered
  }
  func validateExecutable(_ path: String) throws {
    observed.update {
      $0.entered = true
      $0.deadlineWasArmed = clock.armed
      $0.onPreparationQueue = DispatchQueue.getSpecific(key: queueKey) == 1
      $0.onMainThread = Thread.isMainThread
    }
    entered.fulfill()
    let timeout = release.wait(timeout: .now() + 3) == .timedOut
    observed.update { $0.holdTimedOut = timeout }
    do {
      _ = try SearchWorkerBundleResolver.validateForLaunch(
        URL(fileURLWithPath: path, isDirectory: false))
      observed.update { $0.resolverReturned = true }
    } catch SearchWorkerBundleResolverError.filesystem(let code) {
      observed.update { $0.resolverRejectedMissing = code == ENOENT }
      throw LaunchError(code: code)
    } catch { throw LaunchError(code: EINVAL) }
    // RED contract may incorrectly accept: still stop before descriptor/process work.
    throw LaunchError(code: ENOENT)
  }
  func reaperPolicy() throws -> LaunchReaperPolicy { fatalError("no reaper query") }
  func pipe() throws -> (Int32, Int32) { fatalError("no pipe allocation") }
  func openNull() throws -> Int32 { fatalError("no descriptor allocation") }
  func setAndVerify(_ flag: LaunchFlag, fd: Int32) throws { fatalError("no descriptor flags") }
  func duplicateAboveStdio(_ fd: Int32) throws -> Int32 { fatalError("no descriptor duplication") }
  func close(_ fd: Int32) -> Int32 { fatalError("no descriptor close") }
  func makeSpawn() -> any LaunchSpawnOperations { fatalError("no process spawn") }
  func signal(_ pid: Int32, _ signal: Int32) -> Int32 { fatalError("no child signal") }
  func wait(_ pid: Int32) -> LaunchWaitResult { fatalError("no child wait") }
}
