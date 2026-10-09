import Darwin
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Exercises fixed construction and one internal parent-constructor companion.
/// The first three cases use only the package applicationBundle factory.
/// The fourth is a separately identified internal parent-constructor companion.
final class SearchAdmissionServiceConstructionTests: XCTestCase {
  @MainActor
  func testAbsentBundleConstructsAndJoinedClosePreservesResidentCharge() async throws {
    // Catches filesystem preflight and terminal resident-credit erasure.
    let owned = ConstructionServiceOwner()
    addTeardownBlock { await owned.cleanup() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.root.path))
    let bundle = owned.root.appendingPathComponent("Absent.app", isDirectory: true)
    let service = try SearchAdmissionService<String>(applicationBundle: bundle)
    owned.services.append(service)
    let consumer = service.register()
    owned.consumers.append((service, consumer))
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.root.path))

    let result: SearchAdmissionJoinedShutdownResult = await service.shutdownJoined()
    assertConstructionJoin(result)
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.root.path))
    // noChild is a current ownership fact, never a historical zero-launch claim.
  }

  @MainActor
  func testInvalidBundleURLsPropagateResolverInvalidURL() async throws {
    // Catches facade normalization, wrapping or swallowing of exact resolver refusal.
    let owned = ConstructionServiceOwner()
    addTeardownBlock { await owned.cleanup() }
    let base = owned.root.appendingPathComponent("Base.app", isDirectory: true)
    let cases: [URL] = [
      try XCTUnwrap(URL(string: "https://example.invalid/Synthetic.app")),
      try XCTUnwrap(URL(string: "file://remote.invalid/Synthetic.app")),
      try XCTUnwrap(URL(string: "relative.app", relativeTo: base)),
      try XCTUnwrap(URL(string: "file:///synthetic/Synthetic.app?helper=x")),
      try XCTUnwrap(URL(string: "file:///synthetic/Synthetic.app#fragment")),
      try XCTUnwrap(URL(string: "file:///synthetic/Synthetic%00.app")),
    ]
    for bundle in cases {
      do {
        let service = try SearchAdmissionService<String>(applicationBundle: bundle)
        // Retain even an incorrectly accepted service for unconditional actual close.
        owned.services.append(service)
        XCTFail("Invalid bundle URL was accepted")
      } catch {
        XCTAssertEqual(error as? SearchWorkerBundleResolverError, .invalidURL)
      }
    }
    // This method requests no register/capture/input/launch operation.
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.root.path))
  }

  @MainActor
  func testMissingFixedHelperDeliversActualLaunchFailedENOENTWithoutFallback() async throws {
    // Catches helper path search, synchronous preflight and in-process fallback.
    // Root must execute this exact method in a fresh isolated test process.
    // Exact ENOENT is the request's positive validation witness, not a quarantine getter.
    let owned = ConstructionServiceOwner()
    addTeardownBlock { await owned.cleanup() }
    try requireStandardReapableSIGCHLD()
    try owned.createRoot()
    let bundle = owned.root.appendingPathComponent("Missing.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    let markerURLs = [
      owned.root.appendingPathComponent("PadSearchWorker", isDirectory: false),
      owned.root.appendingPathComponent("Build/PadSearchWorker", isDirectory: false),
      owned.root.appendingPathComponent("Path/PadSearchWorker", isDirectory: false),
    ]
    for marker in markerURLs { try owned.createMarker(at: marker) }
    try owned.installSyntheticPATH()
    let fixed = bundle.appendingPathComponent("Contents/Helpers/PadSearchWorker")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixed.path))

    let service = try SearchAdmissionService<String>(applicationBundle: bundle)
    owned.services.append(service)
    let consumer = service.register()
    owned.consumers.append((service, consumer))
    let descriptor = try SearchAdmissionDescriptor(
      query: SearchQuery(pattern: "x", mode: .literal), operation: .replace(template: "Q"),
      estimatedInputUTF16: 1, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 1, maxOutputUTF16: 1, maxMatches: 1, cooperativeMilliseconds: 1000))
    let delivered = expectation(description: "actual fixed-helper launch failure delivered")
    delivered.assertForOverFulfill = true
    let id = try service.submit(
      consumer: consumer, descriptor: descriptor,
      capture: {
        owned.captureCount += 1
        return SearchAdmissionCapture(text: "x", inputUTF16: 1, context: "synthetic")
      },
      completion: { delivery in
        owned.deliveries.append(delivery)
        if case .completed(let lease) = delivery { owned.leases.append((service, lease)) }
        delivered.fulfill()
      })
    owned.jobs.append((service, id))
    // No test-owned completion Task exists: the actual completion records/fulfills inline.
    await fulfillment(of: [delivered], timeout: 5)
    XCTAssertEqual(owned.captureCount, 1)
    XCTAssertEqual(owned.deliveries, [.failed(.child(.launchFailed(ENOENT)))])
    XCTAssertTrue(owned.leases.isEmpty)
    let result: SearchAdmissionJoinedShutdownResult = await service.shutdownJoined()
    assertConstructionJoin(result)
    XCTAssertEqual(owned.deliveries.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixed.path))
    for marker in markerURLs {
      XCTAssertEqual(try Data(contentsOf: marker), Data("inert synthetic fallback marker\n".utf8))
      let permissions =
        try FileManager.default.attributesOfItem(atPath: marker.path)[
          .posixPermissions] as? NSNumber
      XCTAssertEqual(permissions?.intValue, 0o700)
    }
    // A deadline, cancel, quarantine, permission error or completion lease fails this oracle.
    // This case allocates no owned helper; actual child history is not inferred from noChild.
  }

  @MainActor
  func testActualParentConstructionDoesNotEnterInjectedLauncherBeforeBegin() async throws {
    // Catches synchronous eager launch in the actual constructor chain. This is
    // injected lower-seam evidence, complementary to the public factory cases.
    let owned = ConstructionParentOwner()
    addTeardownBlock { await owned.cleanup() }
    let timers = ConstructionTimers()
    let system = ConstructionLaunchRecorder(timers: timers)
    owned.timers = timers
    owned.system = system
    let root = owned.root
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    let parent = try SearchParentWireDriver(
      applicationBundle: root.appendingPathComponent("Absent.app", isDirectory: true),
      system: system, now: { 17 }, schedule: { timers.schedule($0, action: $1) })
    owned.parent = parent
    let constructionEntries = system.snapshot.entries.count
    let constructionTimers = timers.snapshot.count
    XCTAssertEqual(constructionEntries, 0)
    XCTAssertEqual(constructionTimers, 0)
    // Already-recorded constructor failures return through genuine parent teardown.
    // Use the same captured facts so no later entry can silently skip the body.
    guard constructionEntries == 0, constructionTimers == 0 else { return }
    let fresh = try await parent.settlement(after: nil)
    XCTAssertEqual(fresh, .settled(admissionClosed: false))
    XCTAssertEqual(system.snapshot.entries.count, 0)
    let request = try SearchParentWireJob(
      requestID: UUID(), query: SearchQuery(pattern: "x", mode: .literal), operation: .find,
      text: "x", inputUTF16: 1, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 1, maxOutputUTF16: 1, maxMatches: 1, cooperativeMilliseconds: 1000))
    let entered = expectation(description: "first actual parent submit enters launch seam")
    entered.assertForOverFulfill = true
    system.arm(entered)
    // Independently retain every created task before its first suspension.
    let submit = Task { try await parent.submit(request) }
    owned.submitTask = submit
    let handle = try await submit.value
    owned.handle = handle
    let wait = Task { try await parent.wait(for: handle) }
    owned.waitTask = wait
    await fulfillment(of: [entered], timeout: 2)
    let launch = try XCTUnwrap(system.snapshot.entries.first)
    XCTAssertEqual(system.snapshot.entries.count, 1)
    XCTAssertEqual(
      launch.executable.path, root.path + "/Absent.app/Contents/Helpers/PadSearchWorker")
    XCTAssertEqual(launch.activeDeadlines, [10_000_000_017])
    let outcome = try await wait.value
    XCTAssertEqual(
      outcome,
      .failed(
        identity: try SearchWireIdentity(
          generation: launch.generation, requestID: request.requestID, ordinal: 1),
        failure: .launchFailed(ENOENT)))
    let result = await parent.shutdownJoined(after: handle)
    assertConstructionParentJoin(result)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    // No sleeping, polling, inverted expectation, real descriptor or synthetic PID.
  }
}

private func assertConstructionJoin(
  _ result: SearchAdmissionJoinedShutdownResult,
  file: StaticString = #filePath, line: UInt = #line
) {
  guard case .observed(let observation) = result else {
    return XCTFail("Expected actual joined observation: \(result)", file: file, line: line)
  }
  assertConstructionParentJoin(observation.parent, file: file, line: line)
  XCTAssertEqual(
    observation.driverSettlement, .settled(admissionClosed: true), file: file, line: line)
  XCTAssertEqual(observation.retainedActiveJobs, 0, file: file, line: line)
  XCTAssertEqual(observation.retainedLeases, 0, file: file, line: line)
  XCTAssertEqual(observation.activeCharge, 1_048_576, file: file, line: line)
  XCTAssertEqual(observation.retainedCharge, 0, file: file, line: line)
  XCTAssertEqual(observation.reservedRetainedCharge, 0, file: file, line: line)
}

private func assertConstructionParentJoin(
  _ result: SearchParentJoinedShutdownResult,
  file: StaticString = #filePath, line: UInt = #line
) {
  guard case .completed(let completion) = result else {
    return XCTFail("Expected actual parent joined completion: \(result)", file: file, line: line)
  }
  XCTAssertEqual(completion.ownership, .admitted, file: file, line: line)
  XCTAssertEqual(completion.laneStop, .acknowledged, file: file, line: line)
  XCTAssertEqual(completion.shutdown.child.cleanup, .noChild, file: file, line: line)
  XCTAssertTrue(completion.shutdown.child.channelsClosed, file: file, line: line)
  XCTAssertTrue(completion.shutdown.child.stopped, file: file, line: line)
  XCTAssertTrue(completion.shutdown.parentLaneSettled, file: file, line: line)
  XCTAssertEqual(completion.shutdown.retainedParentLanes, 0, file: file, line: line)
}

private enum ConstructionInfrastructureError: Error {
  case nonstandardSIGCHLD
  case syscall(Int32)
}

private func requireStandardReapableSIGCHLD() throws {
  var action = sigaction()
  guard sigaction(SIGCHLD, nil, &action) == 0 else {
    throw ConstructionInfrastructureError.syscall(errno)
  }
  let handler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
  guard action.sa_flags & SA_NOCLDWAIT == 0,
    handler == unsafeBitCast(SIG_DFL, to: UInt.self)
  else { throw ConstructionInfrastructureError.nonstandardSIGCHLD }
  // Inspect only. Never install a signal handler or change host reaping policy.
}

@MainActor private final class ConstructionServiceOwner {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "search-admission-construction-" + UUID().uuidString, isDirectory: true)
  var services: [SearchAdmissionService<String>] = []
  var consumers: [(SearchAdmissionService<String>, SearchConsumerID)] = []
  var jobs: [(SearchAdmissionService<String>, SearchJobID)] = []
  var leases: [(SearchAdmissionService<String>, SearchResultLeaseID)] = []
  var captureCount = 0
  var deliveries: [SearchAdmissionDelivery] = []
  private var restorePATH = false
  private var previousPATH: String?

  func createRoot() throws {
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  func createMarker(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("inert synthetic fallback marker\n".utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else { throw ConstructionInfrastructureError.syscall(errno) }
  }
  func installSyntheticPATH() throws {
    previousPATH = getenv("PATH").map { String(cString: $0) }
    // Cleanup owns restoration even if setenv or later setup fails.
    restorePATH = true
    guard setenv("PATH", root.appendingPathComponent("Path").path, 1) == 0 else {
      throw ConstructionInfrastructureError.syscall(errno)
    }
  }
  func cleanup() async {
    for (service, id) in jobs { service.cancel(id) }
    for (service, id) in consumers { service.unregister(id) }
    for (service, id) in leases { service.release(id) }
    // Genuine joined calls, independently of body success, run for every retained service.
    // Returned DTOs are asserted; merely awaiting them is not successful cleanup.
    for service in services { assertConstructionJoin(await service.shutdownJoined()) }
    jobs.removeAll()
    consumers.removeAll()
    leases.removeAll()
    services.removeAll()
    if restorePATH {
      let result: Int32
      if let previousPATH {
        result = setenv("PATH", previousPATH, 1)
      } else {
        result = unsetenv("PATH")
      }
      XCTAssertEqual(result, 0)
      restorePATH = false
    }
    if FileManager.default.fileExists(atPath: root.path) {
      do { try FileManager.default.removeItem(at: root) } catch {
        XCTFail("Synthetic root cleanup failed")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}

/// This owner retains actual parent work independently of assertion outcomes.
@MainActor private final class ConstructionParentOwner {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "search-admission-parent-" + UUID().uuidString, isDirectory: true)
  var parent: SearchParentWireDriver?
  var handle: SearchParentWireHandle?
  var submitTask: Task<SearchParentWireHandle, Error>?
  var waitTask: Task<SearchParentWireOutcome, Error>?
  var timers: ConstructionTimers?
  var system: ConstructionLaunchRecorder?
  func cleanup() async {
    if let submitTask {
      do { handle = try await submitTask.value } catch {
        XCTFail("Actual parent submit failed during cleanup")
      }
    }
    if let parent, let handle {
      // The fixture returns its failure immediately, so no launch completion is held.
      // Do not cancel the sole waiter: retain and await its real return.
      if waitTask == nil {
        do { try await parent.cancel(handle) } catch {
          XCTFail("Actual parent cancellation failed during cleanup")
        }
        waitTask = Task { try await parent.wait(for: handle) }
      }
      if let waitTask {
        do { _ = try await waitTask.value } catch {
          XCTFail("Actual parent sole wait failed during cleanup")
        }
      }
    }
    if let parent { assertConstructionParentJoin(await parent.shutdownJoined(after: handle)) }
    XCTAssertEqual(system?.snapshot.signals ?? 0, 0)
    XCTAssertEqual(system?.snapshot.polls ?? 0, 0)
    XCTAssertTrue(timers?.snapshot.allSatisfy { !$0.active } ?? true)
    submitTask = nil
    waitTask = nil
    parent = nil
    if FileManager.default.fileExists(atPath: root.path) {
      do { try FileManager.default.removeItem(at: root) } catch {
        XCTFail("Synthetic parent root cleanup failed")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}

private final class ConstructionLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value
  init(_ value: Value) { storage = value }
  func withValue<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }
}

private final class ConstructionTimer: SearchChildTimer, @unchecked Sendable {
  let deadline: UInt64
  let action: @Sendable () -> Void
  private let activeState = ConstructionLocked(true)
  init(deadline: UInt64, action: @escaping @Sendable () -> Void) {
    self.deadline = deadline
    self.action = action
  }
  var active: Bool { activeState.withValue { $0 } }
  func cancel() { activeState.withValue { $0 = false } }
}

private final class ConstructionTimers: @unchecked Sendable {
  private let storage = ConstructionLocked<[ConstructionTimer]>([])
  var snapshot: [ConstructionTimer] { storage.withValue { $0 } }
  func schedule(_ deadline: UInt64, action: @escaping @Sendable () -> Void) -> any SearchChildTimer
  {
    let timer = ConstructionTimer(deadline: deadline, action: action)
    storage.withValue {
      precondition($0.count < 16, "Finite constructor companion timer bound")
      $0.append(timer)
    }
    return timer
  }
}

private final class ConstructionLaunchRecorder: SearchChildSystem, @unchecked Sendable {
  struct Entry {
    let executable: URL
    let generation: UUID
    let activeDeadlines: [UInt64]
  }
  struct Snapshot {
    var entries: [Entry] = []
    var signals = 0
    var polls = 0
  }
  private let storage = ConstructionLocked(Snapshot())
  private let timers: ConstructionTimers
  private let entered = ConstructionLocked<XCTestExpectation?>(nil)
  init(timers: ConstructionTimers) {
    self.timers = timers
  }
  var snapshot: Snapshot { storage.withValue { $0 } }
  func arm(_ expectation: XCTestExpectation) {
    entered.withValue {
      precondition($0 == nil, "Finite constructor companion expectation bound")
      $0 = expectation
    }
  }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    let deadlines = timers.snapshot.filter(\.active).map(\.deadline)
    storage.withValue {
      precondition($0.entries.count < 16, "Finite constructor companion launch bound")
      $0.entries.append(
        .init(executable: executable, generation: generation, activeDeadlines: deadlines))
    }
    entered.withValue { $0 }?.fulfill()
    // No PID, channel or held callback is fabricated. The real lifecycle owns this result.
    completion(.failure(.launchFailed(ENOENT)))
  }
  func signal(pid: Int32, signal: Int32) -> Int32 {
    storage.withValue { $0.signals += 1 }
    return ECHILD
  }
  func pollExit(pid: Int32) -> SearchChildPoll {
    storage.withValue { $0.polls += 1 }
    return .failed(ECHILD)
  }
}
