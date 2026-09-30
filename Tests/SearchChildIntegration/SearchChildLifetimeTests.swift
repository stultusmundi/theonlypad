import CryptoKit
import Darwin
import Dispatch
import Foundation
import XCTest

@testable import SearchExecution

/// No child process is created by this suite. Process-exit evidence is separate.
final class SearchChildLifetimeStateTests: XCTestCase {
  func testEOFExitsSuccessfullyWithoutReadingAgain() {
    assertReads([(0, 0)], expected: 0)
  }

  func testInterruptedReadsRetryUntilEOF() {
    assertReads([(-1, EINTR), (-1, EINTR), (0, 0)], expected: 0)
  }

  func testUnexpectedByteFailsEvenWhenErrnoIsStaleEINTR() {
    assertReads([(1, EINTR)], expected: 70)
  }

  func testReadFailureAndNonblockingDescriptorFailClosed() {
    for error in [EBADF, EIO, EAGAIN] {
      assertReads([(-1, error)], expected: 70)
    }
  }

  func testInterruptionDoesNotHideFollowingDataOrFailure() {
    assertReads([(-1, EINTR), (1, 0)], expected: 70)
    assertReads([(-1, EINTR), (-1, EBADF)], expected: 70)
  }

  private func assertReads(
    _ outcomes: [(Int, Int32)], expected: Int32,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var index = 0
    let exit = SearchParentLifetime.exitStatus(controlFD: 37) { fd in
      XCTAssertEqual(fd, 37, file: file, line: line)
      guard index < outcomes.count else {
        XCTFail("Reader continued after a terminal result", file: file, line: line)
        return (0, 0)
      }
      defer { index += 1 }
      return outcomes[index]
    }
    XCTAssertEqual(exit, expected, file: file, line: line)
    XCTAssertEqual(index, outcomes.count, file: file, line: line)
  }
}

final class SearchChildDispatchTimerTests: XCTestCase {
  func testFutureAbsoluteUptimeDeadlineArrivesWithoutEarlyDelivery() {
    let queue = DispatchQueue(label: "search.timer.test.absolute")
    let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
    let fired = expectation(description: "future absolute uptime deadline delivered")
    fired.assertForOverFulfill = true
    let timer = SearchChildDispatchTimer(deadline: deadline, queue: queue) {
      XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds, deadline)
      fired.fulfill()
    }
    wait(for: [fired], timeout: 2)
    timer.cancel()
  }

  func testPastAbsoluteDeadlineFiresOnSelectedQueue() {
    let queue = DispatchQueue(label: "search.timer.test.past")
    let key = DispatchSpecificKey<Int>()
    queue.setSpecific(key: key, value: 17)
    let fired = expectation(description: "absolute uptime deadline delivered")
    fired.assertForOverFulfill = true
    let timer = SearchChildDispatchTimer(deadline: 1, queue: queue) {
      XCTAssertEqual(DispatchQueue.getSpecific(key: key), 17)
      fired.fulfill()
    }
    wait(for: [fired], timeout: 2)
    timer.cancel()
  }

  func testFutureDeadlineDoesNotFireImmediatelyAndCanBeCancelledRepeatedly() {
    let queue = DispatchQueue(label: "search.timer.test.future")
    let fired = expectation(description: "future timer stays pending")
    fired.isInverted = true
    let timer = SearchChildDispatchTimer(
      deadline: DispatchTime.now().uptimeNanoseconds + 60_000_000_000, queue: queue
    ) { fired.fulfill() }
    wait(for: [fired], timeout: 0.05)
    timer.cancel()
    timer.cancel()
  }

  func testCancellationBeforeSourceDeliverySuppressesAction() {
    let queue = DispatchQueue(label: "search.timer.test.cancel")
    queue.suspend()
    let fired = expectation(description: "cancelled action")
    fired.isInverted = true
    let timer = SearchChildDispatchTimer(deadline: 1, queue: queue) { fired.fulfill() }
    timer.cancel()
    timer.cancel()
    queue.resume()
    wait(for: [fired], timeout: 0.05)
  }

  func testDestructionCancelsSourceBeforeDelivery() {
    let queue = DispatchQueue(label: "search.timer.test.deinit")
    queue.suspend()
    let fired = expectation(description: "destroyed timer action")
    fired.isInverted = true
    var timer: SearchChildDispatchTimer? = SearchChildDispatchTimer(deadline: 1, queue: queue) {
      fired.fulfill()
    }
    XCTAssertNotNil(timer)
    timer = nil
    queue.resume()
    wait(for: [fired], timeout: 0.05)
  }
}

/// Separately selected REAL child test. Root runs only after source review under
/// the checked-in owned watchdog, never as part of the injected-state filter.
final class SearchChildLifetimeProcessTests: XCTestCase {
  func testLifetimeEOFTerminatesOccupiedMainWithExactReap() async throws {
    let executable = try frozenFixture()
    let policy = try SearchChildPolicy(
      operationNanoseconds: 5_000_000_000, reapGraceNanoseconds: 1_000_000_000,
      idleNanoseconds: 5_000_000_000, maximumRequestsPerChild: 1)
    let timerQueue = DispatchQueue(label: "search.lifetime.fixture.timers")
    let lifecycle = try SearchChildLifecycle(
      executable: executable, policy: policy,
      system: SearchChildLauncher(arguments: ["--mode", "parent-lifetime-busy-main"]),
      now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { SearchChildDispatchTimer(deadline: $0, queue: timerQueue, action: $1) })
    do {
      let ticket = try await lifecycle.begin(requestID: UUID())
      let connection = try await lifecycle.connection(for: ticket)
      var header = Data()
      var terminated = false
      for _ in 0..<2_048 {
        let byte = try await connection.read(maxBytes: 1)
        guard byte.count == 1 else { throw LifetimeFixtureError.invalidReadiness }
        if byte[0] == 10 {
          terminated = true
          break
        }
        header.append(byte)
      }
      guard terminated else { throw LifetimeFixtureError.invalidReadiness }
      let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
      XCTAssertEqual(metadata["generation"] as? String, ticket.identity.generation.uuidString)
      XCTAssertEqual(metadata["mainLoopEntered"] as? Bool, true)
      // Fixture main never reads request EOF. Only the real lifetime watcher can
      // produce successful exit0 after this closes the retained control writer.
      await connection.close()
      let outcome = try await lifecycle.wait(for: ticket)
      XCTAssertEqual(outcome, .failed(.unexpectedExit))
      var observed = false
      for _ in 0..<20 {
        if case .reaped(let generation, let exit) = try await lifecycle.cleanup(for: ticket) {
          XCTAssertEqual(generation, ticket.identity.generation)
          XCTAssertEqual(exit, .exited(0))
          observed = true
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      XCTAssertTrue(observed, "Exact lifetime child reap was not observed")
    } catch {
      let receipt = await lifecycle.shutdown()
      XCTAssertTrue(receipt.stopped, "Failure must still settle the exact owned child")
      throw error
    }
    let receipt = await lifecycle.shutdown()
    XCTAssertTrue(receipt.stopped)
    XCTAssertTrue(receipt.channelsClosed)
  }

  private func frozenFixture() throws -> URL {
    var run = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { run.deleteLastPathComponent() }
    let metadata = run.appendingPathComponent("fixture.json")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
    let expected = run.appendingPathComponent("Build/FrozenFixture/SearchChildFixture")
    guard object["executable"] as? String == expected.path else {
      throw LifetimeFixtureError.invalidArtifact
    }
    var cursor = run
    for component in ["Build", "FrozenFixture", "SearchChildFixture"] {
      cursor.appendPathComponent(component)
      var info = stat()
      guard lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
        throw LifetimeFixtureError.invalidArtifact
      }
    }
    let observed = SHA256.hash(data: try Data(contentsOf: expected)).map {
      String(format: "%02x", $0)
    }.joined()
    guard object["sha256"] as? String == observed else {
      throw LifetimeFixtureError.invalidArtifact
    }
    return expected
  }
}

private enum LifetimeFixtureError: Error { case invalidReadiness, invalidArtifact }
