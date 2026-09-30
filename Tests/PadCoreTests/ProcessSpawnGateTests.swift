import Darwin
import Foundation
import XCTest

@testable import PadCore

final class ProcessSpawnGateTests: XCTestCase {
  private enum Sample: Error { case expected }

  func testPoisonSurvivesThrowAndPreventsFollowingBody() {
    let gate = ProcessSpawnGate()
    XCTAssertThrowsError(
      try gate.withCriticalRegion { permit in
        permit.quarantine(EIO)
        throw Sample.expected
      })
    var admitted = false
    XCTAssertThrowsError(try gate.withCriticalRegion { _ in admitted = true }) {
      XCTAssertEqual($0 as? ProcessSpawnGateError, .quarantined(EIO))
    }
    XCTAssertFalse(admitted)
  }

  func testFirstNonzeroPoisonSurvivesSuccessfulRegion() throws {
    let gate = ProcessSpawnGate()
    try gate.withCriticalRegion {
      $0.quarantine(0)
      $0.quarantine(EBADF)
      $0.quarantine(EIO)
    }
    for _ in 0..<2 {
      XCTAssertThrowsError(try gate.withCriticalRegion { _ in XCTFail("admitted") }) {
        XCTAssertEqual($0 as? ProcessSpawnGateError, .quarantined(EBADF))
      }
    }
  }

  func testHealthyThrowAndZeroPoisonPermitFollowingBody() throws {
    let gate = ProcessSpawnGate()
    XCTAssertThrowsError(try gate.withCriticalRegion { _ in throw Sample.expected })
    XCTAssertEqual(
      try gate.withCriticalRegion {
        $0.quarantine(0)
        return 17
      }, 17)
    XCTAssertEqual(try gate.withCriticalRegion { _ in 19 }, 19)
  }

  func testFreshGateDoesNotInheritOtherInstancePoison() throws {
    let first = ProcessSpawnGate()
    try first.withCriticalRegion { $0.quarantine(EIO) }
    XCTAssertEqual(try ProcessSpawnGate().withCriticalRegion { _ in 23 }, 23)
  }

  func testFoundationAdapterRefusesPoisonBeforeConsultingUnconfiguredProcess() throws {
    let gate = ProcessSpawnGate()
    try gate.withCriticalRegion { $0.quarantine(EBADF) }
    let process = GateRefusingProcess()
    XCTAssertThrowsError(try gate.run(process)) {
      XCTAssertEqual($0 as? ProcessSpawnGateError, .quarantined(EBADF))
    }
    XCTAssertEqual(process.attempts, 0)
  }

  func testExactLockContentionPrecedesSecondBodyAndPoisonPublication() {
    for poison in [false, true] {
      let events = GateEvents()
      let gate = ProcessSpawnGate(onContention: { events.record("contended") })
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      defer { release.signal() }
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          try gate.withCriticalRegion { permit in
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else {
              XCTFail("Owner release missing")
              return
            }
            if poison { permit.quarantine(EIO) }
          }
        } catch { XCTFail("Unexpected owner failure: \(error)") }
      }
      XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do { try gate.withCriticalRegion { _ in events.record("entered") } } catch {
          XCTAssertEqual(error as? ProcessSpawnGateError, .quarantined(EIO))
          events.record("refused")
        }
      }
      // This event comes from the exact lock's failed try, or an erroneously
      // admitted body. An outside submitted signal is not an ordering oracle.
      XCTAssertEqual(events.next(), "contended")
      release.signal()
      XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
      XCTAssertEqual(events.next(), poison ? "refused" : "entered")
    }
  }
}

private final class GateRefusingProcess: Process, @unchecked Sendable {
  var attempts = 0
  override func run() throws {
    attempts += 1
    throw NSError(domain: "synthetic-spawn-refusal", code: 1)
  }
}

private final class GateEvents: @unchecked Sendable {
  private let lock = NSLock()
  private let available = DispatchSemaphore(value: 0)
  private var values: [String] = []
  func record(_ value: String) {
    lock.lock()
    values.append(value)
    lock.unlock()
    available.signal()
  }
  func next() -> String? {
    guard available.wait(timeout: .now() + 2) == .success else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return values.removeFirst()
  }
}
