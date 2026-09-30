import CryptoKit
import Darwin
import Dispatch
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchChildLauncherStateTests: XCTestCase {
  func testPipeProtectionExcludesFoundationAdmissionUntilBothEndsAreProtected() async throws {
    let events = SpawnGateEvents()
    let gate = ProcessSpawnGate(onContention: { events.record("contended") })
    let h = LaunchHarness(spawnGate: gate)
    let entered = expectation(description: "raw pipe returned")
    let release = DispatchSemaphore(value: 0)
    let protected = LaunchLocked<Set<Int32>>([])
    h.fake.onFlag = { flag, fd in
      if flag == .closeOnExec { protected.withValue { _ = $0.insert(fd) } }
    }
    h.fake.onPipe = { read, _ in
      if read == 10 {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
      }
    }
    defer { release.signal() }
    let child = Task { await h.launch() }
    await fulfillment(of: [entered], timeout: 2)
    let completed = expectation(description: "Foundation admission settled")
    DispatchQueue.global().async {
      defer { completed.fulfill() }
      do {
        try gate.withCriticalRegion { _ in
          events.record("entered")
          XCTAssertTrue(protected.withValue { $0.isSuperset(of: [10, 11]) })
        }
      } catch { XCTFail("Unexpected admission failure: \(error)") }
    }
    XCTAssertEqual(events.next(), "contended")
    release.signal()
    _ = try await child.value.get()
    await fulfillment(of: [completed], timeout: 2)
  }

  func testActiveFoundationAdmissionExcludesRawPipeCreation() async throws {
    let events = SpawnGateEvents()
    let gate = ProcessSpawnGate(onContention: { events.record("contended") })
    let h = LaunchHarness(spawnGate: gate)
    h.fake.onPipe = { read, _ in if read == 10 { events.record("pipe") } }
    let held = expectation(description: "Foundation region held")
    let finished = expectation(description: "Foundation region released")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    DispatchQueue.global().async {
      defer { finished.fulfill() }
      do {
        try gate.withCriticalRegion { _ in
          held.fulfill()
          XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }
      } catch { XCTFail("Unexpected admission failure: \(error)") }
    }
    await fulfillment(of: [held], timeout: 2)
    let child = Task { await h.launch() }
    XCTAssertEqual(events.next(), "contended")
    release.signal()
    _ = try await child.value.get()
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(events.next(), "pipe")
  }

  func testUnprotectedUncertainClosePoisonsQueuedFoundationBeforeUnlock() async {
    let events = SpawnGateEvents()
    let gate = ProcessSpawnGate(onContention: { events.record("contended") })
    let h = LaunchHarness(spawnGate: gate)
    h.fake.failAt = "closeOnExec:10"
    h.fake.closeErrorFD = 11
    h.fake.closeErrorCode = EBADF
    let held = expectation(description: "unsafe pipe held")
    let release = DispatchSemaphore(value: 0)
    h.fake.onPipe = { _, _ in
      held.fulfill()
      XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
    }
    defer { release.signal() }
    let child = Task { await h.launch() }
    await fulfillment(of: [held], timeout: 2)
    let finished = expectation(description: "queued Foundation refusal")
    DispatchQueue.global().async {
      defer { finished.fulfill() }
      do { try gate.withCriticalRegion { _ in events.record("entered") } } catch {
        XCTAssertEqual(error as? ProcessSpawnGateError, .quarantined(EBADF))
        events.record("refused")
      }
    }
    XCTAssertEqual(events.next(), "contended")
    release.signal()
    assertFailure(await child.value, .launchFailed(EIO))
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(events.next(), "refused")
  }

  func testFlagFailureAndUncertainCloseMatrixPreservesSafetyAndFirstError() async throws {
    for failedFD: Int32 in [10, 11] {
      for stage in ["get", "set", "verify"] {
        for closeFD: Int32 in [10, 11] {
          for closeError in [EINTR, EBADF, EIO] {
            let gate = ProcessSpawnGate()
            let h = LaunchHarness(spawnGate: gate)
            h.fake.flagFailure = (failedFD, stage)
            h.fake.closeErrorFD = closeFD
            h.fake.closeErrorCode = closeError
            assertFailure(await h.launch(), .launchFailed(EACCES))
            XCTAssertEqual(h.fake.created, [10, 11])
            XCTAssertEqual(h.fake.closed, [10, 11])
            XCTAssertFalse(h.fake.log.contains("spawn"))
            let unsafe = failedFD == 10 || closeFD == 11
            if unsafe {
              XCTAssertThrowsError(try gate.withCriticalRegion { _ in XCTFail("unsafe admission") })
              {
                XCTAssertEqual($0 as? ProcessSpawnGateError, .quarantined(closeError))
              }
              let replacement = LaunchHarness(spawnGate: gate)
              assertFailure(await replacement.launch(), .launchFailed(closeError))
              XCTAssertTrue(replacement.fake.created.isEmpty)
            } else {
              XCTAssertEqual(try gate.withCriticalRegion { _ in 17 }, 17)
            }
            // The original search owner stays quarantined for either uncertainty.
            let calls = h.fake.log.count
            assertFailure(await h.launch(), .launchFailed(closeError))
            XCTAssertEqual(h.fake.log.count, calls)
          }
        }
      }
    }
  }

  func testFlagFailureWithConfirmedClosesAllowsNextFoundationAndSearch() async throws {
    for fd: Int32 in [10, 11] {
      let gate = ProcessSpawnGate()
      let h = LaunchHarness(spawnGate: gate)
      h.fake.failAt = "closeOnExec:\(fd)"
      assertFailure(await h.launch(), .launchFailed(EIO))
      XCTAssertEqual(h.fake.closed, [10, 11])
      XCTAssertEqual(try gate.withCriticalRegion { _ in 17 }, 17)
      _ = try await LaunchHarness(spawnGate: gate).launch().get()
    }
  }

  func testProtectedNormalizationAndAncillaryUncertaintyDoNotPoisonFoundation() async throws {
    for lowFD in [false, true] {
      let gate = ProcessSpawnGate()
      let h = LaunchHarness(spawnGate: gate)
      h.fake.nextFD = lowFD ? 0 : 10
      h.fake.closeErrorFD = lowFD ? 0 : 10
      if lowFD {
        assertFailure(await h.launch(), .launchFailed(EBADF))
      } else {
        let child = try await h.launch().get()
        XCTAssertEqual(child.startupFailure, .launchFailed(EBADF))
      }
      XCTAssertEqual(try gate.withCriticalRegion { _ in 17 }, 17)
      let calls = h.fake.log.count
      assertFailure(await h.launch(), .launchFailed(EBADF))
      XCTAssertEqual(h.fake.log.count, calls)
    }
  }

  func testPoisonBetweenSetupAndSpawnRefusesChildAndClosesProtectedDescriptors() async throws {
    let gate = ProcessSpawnGate()
    let h = LaunchHarness(spawnGate: gate)
    h.fake.onConfigure = { attribute in
      if attribute == .defaultSignals {
        try gate.withCriticalRegion { $0.quarantine(ENFILE) }
      }
    }
    assertFailure(await h.launch(), .launchFailed(ENFILE))
    XCTAssertFalse(h.fake.log.contains("spawn"))
    XCTAssertTrue(h.fake.adopted.isEmpty)
    XCTAssertEqual(h.fake.closed.sorted(), h.fake.created.sorted())
  }

  func testPoisonBeforeAllocationRefusesFreshSearchFacade() async throws {
    let gate = ProcessSpawnGate()
    try gate.withCriticalRegion { $0.quarantine(ENFILE) }
    for _ in 0..<2 {
      let h = LaunchHarness(spawnGate: gate)
      assertFailure(await h.launch(), .launchFailed(ENFILE))
      XCTAssertTrue(h.fake.created.isEmpty)
      XCTAssertFalse(h.fake.log.contains("spawn"))
    }
  }

  func testHealthyTransactionTransfersOnlyParentEndsAndClosesAllAncillaryOnce() async throws {
    let h = LaunchHarness()
    let child = try await h.launch().get()
    XCTAssertEqual(child.pid, 719)
    XCTAssertNil(child.startupFailure)
    XCTAssertTrue(child.connection === h.connection)
    XCTAssertEqual(h.fake.adopted, [11, 12, 15])
    XCTAssertEqual(h.fake.closed.sorted(), [10, 13, 14, 16])
    XCTAssertEqual(h.fake.duplicates, [[10, 0], [13, 1], [16, 2], [14, 3]])
    XCTAssertEqual(h.fake.childCloses.sorted(), Array(10...16))
    XCTAssertEqual(h.fake.attributes, [.flags, .emptyMask, .defaultSignals])
    XCTAssertEqual(
      h.fake.spawnArguments, ["/synthetic/fixture", "--generation", h.generation.uuidString])
    XCTAssertEqual(h.fake.environment, ["LANG=C", "LC_ALL=C"])
    XCTAssertEqual(
      h.fake.log.filter { $0.hasPrefix("nonblocking:") }, ["nonblocking:11", "nonblocking:12"])
    XCTAssertEqual(h.fake.log.filter { $0.hasPrefix("noSigPipe:") }, ["noSigPipe:11"])
    XCTAssertEqual(h.fake.log.suffix(2), ["destroyAttributes", "destroyActions"])
    XCTAssertFalse(h.fake.log.contains("wait"))
  }

  func testEverySetupFailureClosesExactlyOwnedDescriptorsAndInitializedStructures() async {
    for startFD: Int32 in [10, 0] {
      let successful = LaunchHarness()
      successful.fake.nextFD = startFD
      _ = await successful.launch()
      let steps = successful.fake.log.filter {
        !$0.hasPrefix("close:") && !$0.hasPrefix("adopt:") && !$0.hasPrefix("destroy")
          && !$0.hasSuffix("Ready")
      }
      XCTAssertGreaterThan(steps.count, 20)
      for step in steps where step != "spawn" {
        let h = LaunchHarness()
        h.fake.nextFD = startFD
        h.fake.failAt = step
        let result = await h.launch()
        assertFailure(result, .launchFailed(EIO), step)
        XCTAssertEqual(h.fake.closed.sorted(), h.fake.created.sorted(), step)
        XCTAssertEqual(Set(h.fake.closed).count, h.fake.closed.count, step)
        XCTAssertFalse(h.fake.log.contains("spawn"), step)
        XCTAssertEqual(
          h.fake.log.filter { $0 == "destroyActions" }.count,
          h.fake.log.contains("actionsReady") ? 1 : 0, step)
        XCTAssertEqual(
          h.fake.log.filter { $0 == "destroyAttributes" }.count,
          h.fake.log.contains("attributesReady") ? 1 : 0, step)
      }
    }
  }

  func testSpawnErrorNeverGrantsAuthorityToMisleadingPIDAndAllowsRetry() async throws {
    let h = LaunchHarness()
    h.fake.spawnResult = .init(code: ENOEXEC, pid: 999)
    assertFailure(await h.launch(), .launchFailed(ENOEXEC))
    XCTAssertTrue(h.fake.adopted.isEmpty)
    XCTAssertEqual(h.fake.closed, h.fake.created)
    XCTAssertFalse(h.fake.log.contains("signal"))
    XCTAssertFalse(h.fake.log.contains("wait"))
    h.fake.spawnResult = .init(code: 0, pid: 720)
    let retried = try await h.launch().get()
    XCTAssertEqual(retried.pid, 720)
  }

  func testPreSpawnUncertainClosePoisonsSharedOwnerAcrossNewLauncherAndReentry() async {
    let h = LaunchHarness()
    h.fake.failAt = "nonblocking:11"
    h.fake.closeErrorFD = 10
    assertFailure(await h.launch(), .launchFailed(EIO))
    let count = h.fake.log.count
    assertFailure(await h.launch(), .launchFailed(EBADF))
    let replacement = h.makeLauncher()
    let result = await withCheckedContinuation { continuation in
      replacement.launch(executable: h.url, generation: h.generation) {
        continuation.resume(returning: $0)
      }
    }
    assertFailure(result, .launchFailed(EBADF))
    XCTAssertEqual(h.fake.log.count, count)
    XCTAssertEqual(h.fake.closed.sorted(), h.fake.created.sorted())
  }

  func testLowDescriptorNormalizationNeverOverwritesParentStdio() async throws {
    let h = LaunchHarness()
    h.fake.nextFD = 0
    _ = try await h.launch().get()
    XCTAssertTrue(h.fake.adopted.allSatisfy { $0 > 3 })
    XCTAssertTrue(h.fake.duplicates.allSatisfy { $0[0] > 3 })
    XCTAssertTrue(h.fake.closed.contains(0))
    XCTAssertTrue(h.fake.closed.contains(1))
    XCTAssertEqual(Set(h.fake.closed).count, h.fake.closed.count)
    let firstNormalization = try XCTUnwrap(h.fake.log.firstIndex(of: "normalize:0"))
    let peerProtected = try XCTUnwrap(h.fake.log.firstIndex(of: "closeOnExec:1"))
    XCTAssertLessThan(
      peerProtected, firstNormalization, "Protect both pipe ends before normalization work")
  }

  func testPoisonSurvivesLauncherReleaseAndCallbackReentry() async throws {
    let h = LaunchHarness()
    h.fake.failAt = "nonblocking:11"
    h.fake.closeErrorFD = 10
    var launcher: SearchChildLauncher? = h.makeLauncher()
    weak var released: SearchChildLauncher?
    released = launcher
    let first = await withCheckedContinuation { continuation in
      launcher!.launch(executable: h.url, generation: h.generation) {
        continuation.resume(returning: $0)
      }
    }
    assertFailure(first, .launchFailed(EIO))
    launcher = nil
    // A queue fence observes completion of the retained transaction's release.
    await withCheckedContinuation { continuation in
      h.coordinator.queue.async { continuation.resume() }
    }
    XCTAssertNil(released)
    let count = h.fake.log.count
    let replacement = h.makeLauncher()
    let reentered = await withCheckedContinuation { continuation in
      replacement.launch(executable: h.url, generation: h.generation) { _ in
        replacement.launch(executable: h.url, generation: h.generation) {
          continuation.resume(returning: $0)
        }
      }
    }
    assertFailure(reentered, .launchFailed(EBADF))
    XCTAssertEqual(h.fake.log.count, count)
  }

  func testHeldValidationDoesNotBlockCallerOrDropCancelledLateSuccess() async throws {
    let h = LaunchHarness()
    let entered = expectation(description: "validation entered on spawn lane")
    let release = DispatchSemaphore(value: 0)
    h.fake.onValidate = {
      entered.fulfill()
      release.wait()
    }
    let result = Task { await h.launch() }
    await fulfillment(of: [entered], timeout: 1)
    result.cancel()
    release.signal()
    let child = try await result.value.get()
    XCTAssertEqual(child.pid, 719)
    XCTAssertEqual(h.fake.log.filter { $0 == "spawn" }.count, 1)
    XCTAssertEqual(h.fake.adopted, [11, 12, 15])
  }

  func testNormalizationCloseUncertaintyStopsBeforeSpawnAndDoesNotRetry() async {
    let h = LaunchHarness()
    h.fake.nextFD = 0
    h.fake.closeErrorFD = 0
    assertFailure(await h.launch(), .launchFailed(EBADF))
    XCTAssertFalse(h.fake.log.contains("spawn"))
    XCTAssertEqual(h.fake.closed.filter { $0 == 0 }.count, 1)
    XCTAssertEqual(h.fake.closed.sorted(), h.fake.created.sorted())
    let count = h.fake.log.count
    _ = await h.launch()
    XCTAssertEqual(h.fake.log.count, count)
  }

  func testPostSpawnCloseFailureStillHandsOffPIDAndRealConnectionCleanup() async throws {
    let h = LaunchHarness()
    h.fake.closeErrorFD = 10
    let child = try await h.launch().get()
    XCTAssertEqual(child.pid, 719)
    XCTAssertEqual(child.startupFailure, .launchFailed(EBADF))
    XCTAssertEqual(h.fake.adopted, [11, 12, 15])
    XCTAssertEqual(h.fake.closed, [10, 13, 14, 16])
    do {
      try await child.connection.write(Data([1]))
      XCTFail("startup-failed connection published bytes")
    } catch { XCTAssertEqual(error as? SearchChildFailure, .launchFailed(EBADF)) }
    let started = expectation(description: "underlying close initiated")
    h.connection.onClose = { started.fulfill() }
    // The single retained quarantine intentionally cannot confirm ancillary closure.
    let close = Task { await child.connection.close() }
    await fulfillment(of: [started], timeout: 1)
    close.cancel()
    XCTAssertEqual(h.connection.closeCount, 1)
    let count = h.fake.log.count
    _ = await h.launch()
    XCTAssertEqual(h.fake.log.count, count)
  }

  func testReaperPolicyRefusesIgnoredCustomNoChildWaitAndQueryFailureBeforePipe() async {
    for policy in [LaunchReaperPolicy.ignored, .custom, .noChildWait] {
      let h = LaunchHarness()
      h.fake.policy = policy
      assertFailure(await h.launch(), .launchFailed(ECHILD))
      XCTAssertTrue(h.fake.created.isEmpty)
    }
    let h = LaunchHarness()
    h.fake.failAt = "policy"
    assertFailure(await h.launch(), .launchFailed(EIO))
    XCTAssertTrue(h.fake.created.isEmpty)
  }

  func testAncillaryWaitSurvivesUnderlyingCloseExactReapAndRepeatedShutdown() async throws {
    let observation = LaunchCloseProbe()
    let h = LaunchHarness(closeObservation: { observation.record($0) })
    h.fake.closeErrorFD = 10
    let system = LauncherRecordingSystem(h.launcher)
    let clock = LaunchManualClock()
    let policy = try SearchChildPolicy(
      operationNanoseconds: 1_000_000_000,
      reapGraceNanoseconds: 100_000_000, idleNanoseconds: 2_000_000_000,
      maximumRequestsPerChild: 1)
    let lifecycle = try SearchChildLifecycle(
      executable: h.url, policy: policy, system: system,
      now: { clock.now }, schedule: { clock.schedule($0, event: $1) })
    let ticket = try await lifecycle.begin(requestID: UUID())
    let outcome = try await lifecycle.wait(for: ticket)
    XCTAssertEqual(outcome, .failed(.launchFailed(EBADF)))

    // Either branch reports explicitly. Bypassing the ancillary await produces
    // finished, so this negative control fails without an inverted wait or sleep.
    let milestone = await observation.wait(for: .milestone)
    XCTAssertEqual(milestone.first { $0 != .closeRequested }, .ancillaryWaitInstalled)
    let child = try XCTUnwrap(system.child)
    let second = Task { await child.connection.close() }
    let third = Task { await child.connection.close() }
    _ = await observation.wait(for: .requests(3))
    XCTAssertEqual(h.connection.closeCount, 1)

    // Finish initial lifecycle stop/poll before mutating the queue-confined fake.
    // No scheduled callback can run until this test explicitly advances time.
    _ = try await lifecycle.cleanup(for: ticket)
    h.fake.waitResult = .init(value: 719, status: SIGKILL, error: 0)
    clock.advance(to: 100_000_000)
    let reaped = try await lifecycle.cleanup(for: ticket)
    XCTAssertEqual(
      reaped, .reaped(generation: ticket.identity.generation, exit: .signaled(SIGKILL)))
    XCTAssertEqual(h.fake.waitPIDs, [719, 719])
    XCTAssertEqual(h.fake.signalArguments, [719, SIGKILL])
    XCTAssertEqual(h.fake.log.filter { $0 == "signal" }.count, 1)

    let shutdownRace = LaunchShutdownRace()
    clock.onSchedule = { deadline in
      if deadline == 200_000_000 { shutdownRace.record(.scheduled) }
    }
    let shutdown = Task {
      let value = await lifecycle.shutdown()
      shutdownRace.record(.returned)
      return value
    }
    let first = await shutdownRace.wait()
    // A gate-removal mutant may already have acknowledged close and return early.
    // Never wait for a grace timer that such a mutant correctly does not schedule.
    XCTAssertEqual(first, .scheduled)
    clock.advance(to: 200_000_000)
    let receipt = await shutdown.value
    XCTAssertEqual(receipt.cleanup, reaped)
    XCTAssertFalse(receipt.channelsClosed)
    XCTAssertFalse(receipt.stopped)
    let repeated = await lifecycle.shutdown()
    XCTAssertEqual(repeated.cleanup, receipt.cleanup)
    XCTAssertEqual(repeated.channelsClosed, receipt.channelsClosed)
    XCTAssertEqual(repeated.stopped, receipt.stopped)
    XCTAssertEqual(clock.deadlines.filter { $0 == 200_000_000 }.count, 1)
    XCTAssertEqual(h.connection.closeCount, 1)
    XCTAssertFalse(observation.events.contains(.closeTaskFinished))
    second.cancel()
    third.cancel()
  }

  func testMalformedURLGenerationAndArgumentsRefusedBeforeFilesystem() async {
    let base = URL(fileURLWithPath: "/synthetic-base/", isDirectory: true)
    for url in [
      URL(string: "https://example.invalid/f")!, URL(string: "file:///x%00hidden")!,
      URL(string: "file:relative")!, URL(string: "relative", relativeTo: base)!,
      URL(string: "file://remote.invalid/helper")!, URL(string: "file:///helper?override=x")!,
      URL(string: "file:///helper#fragment")!,
    ] {
      let h = LaunchHarness()
      assertFailure(await h.launch(url: url), .invalidExecutable)
      XCTAssertTrue(h.fake.log.isEmpty)
    }
    let h = LaunchHarness()
    assertFailure(
      await h.launch(generation: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))),
      .launchFailed(EINVAL))
    XCTAssertTrue(h.fake.log.isEmpty)
    for args in [
      ["--generation", UUID().uuidString], ["--unknown"], ["--mode", "echo\0bad"],
      ["--mode", "echo", "--mode", "exit17"],
    ] {
      let h = LaunchHarness(arguments: args)
      assertFailure(await h.launch(), .launchFailed(EINVAL))
      XCTAssertTrue(h.fake.log.isEmpty)
    }
  }

  func testExplicitAbsoluteURLWithBaseRemainsAccepted() async throws {
    let base = URL(fileURLWithPath: "/synthetic-base/", isDirectory: true)
    let absolute = URL(string: "file:///synthetic-helper", relativeTo: base)!
    let h = LaunchHarness()
    _ = try await h.launch(url: absolute).get()
    XCTAssertTrue(h.fake.log.contains("validate"))
  }

  func testFixedFixtureModePreservesMandatoryBootstrap() async throws {
    for mode in ["echo", "exit17"] {
      let h = LaunchHarness(arguments: ["--mode", mode])
      _ = try await h.launch().get()
      XCTAssertEqual(h.fake.spawnArguments.suffix(2), ["--mode", mode])
      XCTAssertEqual(h.fake.spawnArguments.filter { $0 == "--generation" }.count, 1)
    }
  }

  func testExactNonblockingWaitStatusAndSignalAdapter() {
    let h = LaunchHarness()
    let cases: [(LaunchWaitResult, SearchChildPoll)] = [
      (.init(value: 0, status: 0, error: 0), .running),
      (.init(value: 719, status: 17 << 8, error: 0), .reaped(.exited(17))),
      (.init(value: 719, status: 0, error: 0), .reaped(.exited(0))),
      (.init(value: 719, status: SIGKILL, error: 0), .reaped(.signaled(SIGKILL))),
      (.init(value: -1, status: 0, error: EINTR), .interrupted),
      (.init(value: -1, status: 0, error: ECHILD), .failed(ECHILD)),
      (.init(value: 719, status: 0x7f, error: 0), .failed(EPROTO)),
      (.init(value: 999, status: 0, error: 0), .failed(EPROTO)),
    ]
    for (raw, expected) in cases {
      h.fake.waitResult = raw
      XCTAssertEqual(
        String(describing: h.launcher.pollExit(pid: 719)), String(describing: expected))
    }
    XCTAssertEqual(h.fake.waitPIDs, Array(repeating: 719, count: cases.count))
    h.fake.signalError = ESRCH
    XCTAssertEqual(h.launcher.signal(pid: 719, signal: SIGKILL), ESRCH)
    XCTAssertEqual(h.fake.signalArguments, [719, SIGKILL])
  }

  private func assertFailure(
    _ result: Result<SearchLaunchedChild, SearchChildFailure>,
    _ expected: SearchChildFailure, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
  ) {
    switch result {
    case .failure(let error): XCTAssertEqual(error, expected, message, file: file, line: line)
    case .success: XCTFail("unexpected child: " + message, file: file, line: line)
    }
  }
}

private final class LaunchHarness: @unchecked Sendable {
  let fake = FakeLaunchOperations()
  let coordinator: SearchLaunchCoordinator
  let connection = LaunchTestConnection()
  let generation = UUID()
  let url = URL(fileURLWithPath: "/synthetic/fixture")
  let arguments: [String]
  let closeObservation: (@Sendable (LaunchCloseEvent) -> Void)?
  lazy var launcher = makeLauncher()
  init(
    arguments: [String] = [], closeObservation: (@Sendable (LaunchCloseEvent) -> Void)? = nil,
    spawnGate: ProcessSpawnGate = ProcessSpawnGate()
  ) {
    coordinator = SearchLaunchCoordinator(spawnGate: spawnGate)
    self.arguments = arguments
    self.closeObservation = closeObservation
  }
  func makeLauncher() -> SearchChildLauncher {
    SearchChildLauncher(
      arguments: arguments, operations: fake, coordinator: coordinator,
      closeObservation: closeObservation
    ) {
      [fake, connection] a, b, c in
      fake.adopted = [a, b, c]
      fake.log.append("adopt:\(a)")
      return connection
    }
  }
  func launch(url: URL? = nil, generation: UUID? = nil) async -> Result<
    SearchLaunchedChild, SearchChildFailure
  > {
    await withCheckedContinuation { continuation in
      launcher.launch(executable: url ?? self.url, generation: generation ?? self.generation) {
        continuation.resume(returning: $0)
      }
    }
  }
}

// Setup observations are confined to the spawn queue and inspected only after its
// completion handoff. No fixture descriptor or syscall is used by this fake.
private final class FakeLaunchOperations: LaunchOperations, LaunchSpawnOperations,
  @unchecked Sendable
{
  var log: [String] = []
  var failAt: String?
  var nextFD: Int32 = 10
  var created: [Int32] = []
  var closed: [Int32] = []
  var adopted: [Int32] = []
  var duplicates: [[Int32]] = []
  var childCloses: [Int32] = []
  var attributes: [LaunchAttribute] = []
  var spawnArguments: [String] = []
  var environment: [String] = []
  var policy = LaunchReaperPolicy.standard
  var closeErrorFD: Int32?
  var closeErrorCode: Int32 = EBADF
  var flagFailure: (Int32, String)?
  var onValidate: (@Sendable () -> Void)?
  var onPipe: (@Sendable (Int32, Int32) -> Void)?
  var onFlag: (@Sendable (LaunchFlag, Int32) -> Void)?
  var onConfigure: (@Sendable (LaunchAttribute) throws -> Void)?
  var spawnResult = LaunchSpawnResult(code: 0, pid: 719)
  var waitResult = LaunchWaitResult(value: 0, status: 0, error: 0)
  var waitPIDs: [Int32] = []
  var signalError: Int32 = 0
  var signalArguments: [Int32] = []
  func step(_ name: String) throws {
    log.append(name)
    if failAt == name { throw LaunchError(code: EIO) }
  }
  func allocate() -> Int32 {
    let value = nextFD
    nextFD += 1
    created.append(value)
    return value
  }
  func validateExecutable(_ path: String) throws {
    try step("validate")
    onValidate?()
  }
  func reaperPolicy() throws -> LaunchReaperPolicy {
    try step("policy")
    return policy
  }
  func pipe() throws -> (Int32, Int32) {
    try step("pipe:\(created.count)")
    let pair = (allocate(), allocate())
    onPipe?(pair.0, pair.1)
    return pair
  }
  func openNull() throws -> Int32 {
    try step("null")
    return allocate()
  }
  func setAndVerify(_ flag: LaunchFlag, fd: Int32) throws {
    try step("\(flag):\(fd)")
    if flag == .closeOnExec {
      // Inject the composite collaborator's failure before/after its flag write;
      // this does not claim actual Darwin fcntl error-path execution.
      for stage in ["get", "set", "verify"] {
        if let failure = flagFailure, failure.0 == fd && failure.1 == stage {
          throw LaunchError(code: EACCES)
        }
      }
    }
    onFlag?(flag, fd)
  }
  func duplicateAboveStdio(_ fd: Int32) throws -> Int32 {
    try step("normalize:\(fd)")
    nextFD = max(20, nextFD)
    return allocate()
  }
  func close(_ fd: Int32) -> Int32 {
    log.append("close:\(fd)")
    closed.append(fd)
    return fd == closeErrorFD ? closeErrorCode : 0
  }
  func makeSpawn() -> any LaunchSpawnOperations { self }
  func initializeActions() throws {
    try step("actions")
    log.append("actionsReady")
  }
  func initializeAttributes() throws {
    try step("attributes")
    log.append("attributesReady")
  }
  func duplicate(_ fd: Int32, to: Int32) throws {
    try step("dup:\(to)")
    duplicates.append([fd, to])
  }
  func closeInChild(_ fd: Int32) throws {
    try step("childClose:\(fd)")
    childCloses.append(fd)
  }
  func configure(_ attribute: LaunchAttribute) throws {
    try step("attribute:\(attribute)")
    attributes.append(attribute)
    try onConfigure?(attribute)
  }
  func spawn(path: String, arguments: [String], environment: [String]) -> LaunchSpawnResult {
    log.append("spawn")
    spawnArguments = arguments
    self.environment = environment
    return spawnResult
  }
  func destroyActions() { log.append("destroyActions") }
  func destroyAttributes() { log.append("destroyAttributes") }
  func signal(_ pid: Int32, _ signal: Int32) -> Int32 {
    log.append("signal")
    signalArguments = [pid, signal]
    return signalError
  }
  func wait(_ pid: Int32) -> LaunchWaitResult {
    log.append("wait")
    waitPIDs.append(pid)
    return waitResult
  }
}

private final class LaunchTestConnection: SearchChildConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var onClose: (@Sendable () -> Void)?
  var closeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func write(_ bytes: Data) async throws {}
  func read(maxBytes: Int) async throws -> Data { Data() }
  func close() async { closed() }
  private func closed() {
    lock.lock()
    count += 1
    let callback = onClose
    lock.unlock()
    callback?()
  }
}

private final class LaunchLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withValue<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

private final class SpawnGateEvents: @unchecked Sendable {
  private let values = LaunchLocked<[String]>([])
  private let available = DispatchSemaphore(value: 0)
  func record(_ value: String) {
    values.withValue { $0.append(value) }
    available.signal()
  }
  func next() -> String? {
    guard available.wait(timeout: .now() + 2) == .success else { return nil }
    return values.withValue { $0.removeFirst() }
  }
}

private final class LaunchCloseProbe: @unchecked Sendable {
  enum Target {
    case milestone
    case requests(Int)
  }
  private struct State {
    var events: [LaunchCloseEvent] = []
    var waiter: (Target, CheckedContinuation<[LaunchCloseEvent], Never>)?
    func ready(_ target: Target) -> Bool {
      switch target {
      case .milestone: return events.contains { $0 != .closeRequested }
      case .requests(let count): return events.filter { $0 == .closeRequested }.count >= count
      }
    }
  }
  private let state = LaunchLocked(State())
  var events: [LaunchCloseEvent] { state.withValue { $0.events } }
  func record(_ event: LaunchCloseEvent) {
    let delivery = state.withValue {
      value -> (CheckedContinuation<[LaunchCloseEvent], Never>, [LaunchCloseEvent])? in
      value.events.append(event)
      guard let (target, waiter) = value.waiter, value.ready(target) else { return nil }
      value.waiter = nil
      return (waiter, value.events)
    }
    if let (waiter, events) = delivery { waiter.resume(returning: events) }
  }
  func wait(for target: Target) async -> [LaunchCloseEvent] {
    await withCheckedContinuation { continuation in
      let immediate = state.withValue { value -> [LaunchCloseEvent]? in
        if value.ready(target) { return value.events }
        precondition(value.waiter == nil)
        value.waiter = (target, continuation)
        return nil
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }
}

private final class LauncherRecordingSystem: SearchChildSystem, @unchecked Sendable {
  private let launcher: SearchChildLauncher
  private let captured = LaunchLocked<SearchLaunchedChild?>(nil)
  init(_ launcher: SearchChildLauncher) { self.launcher = launcher }
  var child: SearchLaunchedChild? { captured.withValue { $0 } }
  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    launcher.launch(executable: executable, generation: generation) { [self] result in
      if case .success(let child) = result { captured.withValue { $0 = child } }
      completion(result)
    }
  }
  func signal(pid: Int32, signal: Int32) -> Int32 { launcher.signal(pid: pid, signal: signal) }
  func pollExit(pid: Int32) -> SearchChildPoll { launcher.pollExit(pid: pid) }
}

private final class LaunchManualTimer: SearchChildTimer, @unchecked Sendable {
  let deadline: UInt64
  private let active = LaunchLocked(true)
  private let event: @Sendable () -> Void
  init(_ deadline: UInt64, event: @escaping @Sendable () -> Void) {
    self.deadline = deadline
    self.event = event
  }
  func cancel() { active.withValue { $0 = false } }
  func fire() {
    let shouldFire = active.withValue { value in
      let old = value
      value = false
      return old
    }
    if shouldFire { event() }
  }
}

private final class LaunchManualClock: @unchecked Sendable {
  private struct State {
    var now: UInt64 = 0
    var timers: [LaunchManualTimer] = []
    var onSchedule: (@Sendable (UInt64) -> Void)?
  }
  private let state = LaunchLocked(State())
  var now: UInt64 { state.withValue { $0.now } }
  var deadlines: [UInt64] { state.withValue { $0.timers.map(\.deadline) } }
  var onSchedule: (@Sendable (UInt64) -> Void)? {
    get { state.withValue { $0.onSchedule } }
    set { state.withValue { $0.onSchedule = newValue } }
  }
  func schedule(_ deadline: UInt64, event: @escaping @Sendable () -> Void) -> any SearchChildTimer {
    let timer = LaunchManualTimer(deadline, event: event)
    let callback = state.withValue { value in
      value.timers.append(timer)
      return value.onSchedule
    }
    callback?(deadline)
    return timer
  }
  func advance(to time: UInt64) {
    let due = state.withValue { value in
      value.now = time
      return value.timers.filter { $0.deadline <= time }
    }
    for timer in due { timer.fire() }
  }
}

private final class LaunchShutdownRace: @unchecked Sendable {
  enum Event: Equatable { case scheduled, returned }
  private struct State {
    var first: Event?
    var waiter: CheckedContinuation<Event, Never>?
  }
  private let state = LaunchLocked(State())
  func record(_ event: Event) {
    let waiter = state.withValue { value -> CheckedContinuation<Event, Never>? in
      guard value.first == nil else { return nil }
      value.first = event
      let waiter = value.waiter
      value.waiter = nil
      return waiter
    }
    waiter?.resume(returning: event)
  }
  func wait() async -> Event {
    await withCheckedContinuation { continuation in
      let immediate = state.withValue { value -> Event? in
        if let first = value.first { return first }
        precondition(value.waiter == nil)
        value.waiter = continuation
        return nil
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }
}

/// REAL process tests. These are excluded by the default lifecycle filter and by
/// SearchChildLauncherStateTests. Run only after review under the owned watchdog.
final class SearchChildLauncherTests: XCTestCase {
  func testBenignBootstrapEchoAndExactExitCleanup() async throws {
    try await withFixture(mode: "echo") { lifecycle, ticket in
      let connection = try await lifecycle.connection(for: ticket)
      var header = Data()
      for _ in 0..<2_048 {
        let byte = try await connection.read(maxBytes: 1)
        guard byte.count == 1 else { throw LaunchError(code: EPROTO) }
        if byte[0] == 10 { break }
        header.append(byte)
      }
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
      XCTAssertEqual(object["generation"] as? String, ticket.identity.generation.uuidString)
      XCTAssertEqual(object["descriptorFlags"] as? [Int32], [0, 0, 0, 0])
      let flags = try XCTUnwrap(object["statusFlags"] as? [Int32])
      XCTAssertEqual(flags.count, 4)
      XCTAssertTrue(flags.allSatisfy { $0 & O_NONBLOCK == 0 })
      XCTAssertEqual(flags.map { $0 & O_ACCMODE }, [O_RDONLY, O_WRONLY, O_RDWR, O_RDONLY])
      XCTAssertEqual(
        object["kinds"] as? [UInt16],
        [UInt16(S_IFIFO), UInt16(S_IFIFO), UInt16(S_IFCHR), UInt16(S_IFIFO)])
      XCTAssertEqual(object["blockedSignals"] as? [Int32], [])
      XCTAssertEqual(object["sigpipeDefault"] as? Bool, true)
      let bytes = Data((0..<64).map(UInt8.init))
      try await connection.write(bytes)
      var echo = Data()
      for _ in 0..<64 where echo.count < bytes.count {
        let part = try await connection.read(maxBytes: bytes.count - echo.count)
        guard !part.isEmpty else { throw LaunchError(code: EPROTO) }
        echo.append(part)
      }
      XCTAssertEqual(echo, bytes)
      // Fixture waits for request EOF after its fixed echo, preventing an idle reap
      // from racing unread response bytes. This is not a search-wire terminal.
      await connection.close()
      _ = try await lifecycle.wait(for: ticket)
      try await self.assertExit(.exited(0), lifecycle: lifecycle, ticket: ticket)
    }
  }

  func testImmediateExit17UsesSoleLifecycleReaper() async throws {
    try await withFixture(mode: "exit17") { lifecycle, ticket in
      let outcome = try await lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .failed(.unexpectedExit))
      try await self.assertExit(.exited(17), lifecycle: lifecycle, ticket: ticket)
    }
  }

  private func withFixture(
    mode: String,
    body: (SearchChildLifecycle, SearchChildTicket) async throws -> Void
  ) async throws {
    let executable = try frozenFixture()
    let policy = try SearchChildPolicy(
      operationNanoseconds: 3_000_000_000,
      reapGraceNanoseconds: 1_000_000_000, idleNanoseconds: 3_000_000_000,
      maximumRequestsPerChild: 1)
    let lifecycle = try SearchChildLifecycle(
      executable: executable, policy: policy,
      system: SearchChildLauncher(arguments: ["--mode", mode]),
      now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { LauncherFixtureTimer(deadline: $0, event: $1) })
    do {
      let ticket = try await lifecycle.begin(requestID: UUID())
      try await body(lifecycle, ticket)
    } catch {
      let receipt = await lifecycle.shutdown()
      XCTAssertTrue(receipt.stopped, "Failure cleanup must retain/settle exact ownership")
      throw error
    }
    let receipt = await lifecycle.shutdown()
    XCTAssertTrue(receipt.stopped)
    XCTAssertTrue(receipt.channelsClosed)
  }

  private func assertExit(
    _ expected: SearchChildExit, lifecycle: SearchChildLifecycle,
    ticket: SearchChildTicket
  ) async throws {
    // Only snapshots: the production adapter remains the sole waitpid consumer.
    for _ in 0..<20 {
      let receipt = try await lifecycle.cleanup(for: ticket)
      if case .reaped(let generation, let exit) = receipt {
        XCTAssertEqual(generation, ticket.identity.generation)
        XCTAssertEqual(exit, expected)
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("No exact child reap within bounded fixture observation")
  }

  private func frozenFixture() throws -> URL {
    var run = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { run.deleteLastPathComponent() }
    let metadata = run.appendingPathComponent("fixture.json")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
    let expected = run.appendingPathComponent("Build/FrozenFixture/SearchChildFixture")
    guard object["executable"] as? String == expected.path else { throw LaunchError(code: EINVAL) }
    var cursor = run
    for component in ["Build", "FrozenFixture", "SearchChildFixture"] {
      cursor.appendPathComponent(component)
      var info = stat()
      guard lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
        throw LaunchError(code: EINVAL)
      }
    }
    let observed = SHA256.hash(data: try Data(contentsOf: expected)).map {
      String(format: "%02x", $0)
    }.joined()
    guard object["sha256"] as? String == observed else { throw LaunchError(code: EINVAL) }
    return expected
  }
}

/// Test-only real monotonic scheduling. Production timer/public factory is a later slice.
private final class LauncherFixtureTimer: SearchChildTimer, @unchecked Sendable {
  private let source: DispatchSourceTimer
  init(deadline: UInt64, event: @escaping @Sendable () -> Void) {
    source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    source.setEventHandler(handler: event)
    source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
    source.activate()
  }
  func cancel() { source.cancel() }
  deinit { source.cancel() }
}

/// Real Darwin validation only: inert filesystem entries, no child or descriptor setup.
final class SearchChildLauncherResolverTests: XCTestCase {
  func testDefaultValidationPreservesMissingAndNonDirectoryErrno() async throws {
    let root = try temporaryRoot()
    await expectFailure(root.appendingPathComponent("missing").path, ENOENT)
    let file = try inertFile(in: root)
    await expectFailure(file.appendingPathComponent("child").path, ENOTDIR)
  }

  func testDefaultValidationAcceptsExactRegularExecutableWithoutExecutingIt() async throws {
    let file = try inertFile(in: temporaryRoot())
    try await validate(file.path)
    XCTAssertEqual(try Data(contentsOf: file), Data("inert forwarding marker".utf8))
  }

  func testDefaultValidationRejectsDirectoryFIFOAndLinkedEntries() async throws {
    let root = try temporaryRoot()
    await expectFailure(root.path, EACCES)
    let fifo = root.appendingPathComponent("fifo")
    XCTAssertEqual(mkfifo(fifo.path, 0o700), 0)
    await expectFailure(fifo.path, EACCES)
    let file = try inertFile(in: root)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    await expectFailure(link.path, EACCES)
    try FileManager.default.removeItem(at: file)
    await expectFailure(link.path, EACCES)
  }

  func testDefaultValidationRejectsNoExecuteBit() async throws {
    let file = try inertFile(in: temporaryRoot())
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    await expectFailure(file.path, EACCES)
  }

  func testDefaultValidationRefusesRelativeAndNULBeforeURLConversion() async throws {
    let file = try inertFile(in: temporaryRoot())
    await expectFailure("relative-forwarding-" + UUID().uuidString, EINVAL)
    await expectFailure("", EINVAL)
    await expectFailure(file.path + "\0suffix", EINVAL)
  }

  func testDefaultLauncherPreservesMissingExecutableFailure() async throws {
    let file = try temporaryRoot().appendingPathComponent("missing")
    let launcher = SearchChildLauncher()
    let result = await withCheckedContinuation { continuation in
      launcher.launch(executable: file, generation: UUID()) { continuation.resume(returning: $0) }
    }
    switch result {
    case .failure(let failure): XCTAssertEqual(failure, .launchFailed(ENOENT))
    case .success: XCTFail("missing inert path must never produce a child")
    }
  }

  private func validate(_ path: String) async throws {
    let launcher = SearchChildLauncher()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      launcher.coordinator.queue.async {
        do {
          try launcher.operations.validateExecutable(path)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func expectFailure(
    _ path: String, _ code: Int32,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await validate(path)
      XCTFail("expected validation refusal", file: file, line: line)
    } catch {
      XCTAssertEqual((error as? LaunchError)?.code, code, file: file, line: line)
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "search-forwarding-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }

  private func inertFile(in root: URL) throws -> URL {
    let file = root.appendingPathComponent("inert-worker")
    try Data("inert forwarding marker".utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o700), 0)
    return file
  }
}
