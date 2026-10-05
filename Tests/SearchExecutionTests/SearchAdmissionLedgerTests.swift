import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchAdmissionLedgerTests: XCTestCase {
  func testResidentMustFitActiveLimit() throws {
    XCTAssertThrowsError(try SearchAdmissionLedger(activeLimit: 2, retainedLimit: 9, resident: 3))
    let ledger = try SearchAdmissionLedger(activeLimit: 2, retainedLimit: 9, resident: 2)
    XCTAssertEqual(ledger.snapshot.active, 2)
  }

  func testExactLimitsAndOneBeyondRefuseWithoutMutation() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 6, resident: 2)
    _ = try ledger.reserve(.init(active: 8, retained: 6))
    XCTAssertEqual(ledger.snapshot.active, 10)
    XCTAssertEqual(ledger.snapshot.reservedRetained, 6)
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.reserve(.init(active: 1, retained: 0)))
    XCTAssertEqual(ledger.snapshot, before)
    XCTAssertThrowsError(try ledger.reserve(.init(active: 0, retained: 1)))
    XCTAssertEqual(ledger.snapshot, before)
  }

  func testOverflowCannotWrapEitherBudget() throws {
    var active = try SearchAdmissionLedger(activeLimit: .max, retainedLimit: .max, resident: 1)
    let before = active.snapshot
    XCTAssertThrowsError(try active.reserve(.init(active: .max, retained: 0)))
    XCTAssertEqual(active.snapshot, before)
    var retained = try SearchAdmissionLedger(activeLimit: 9, retainedLimit: .max, resident: 0)
    _ = try retained.reserve(.init(active: 1, retained: .max))
    let full = retained.snapshot
    XCTAssertThrowsError(try retained.reserve(.init(active: 0, retained: 1)))
    XCTAssertEqual(retained.snapshot, full)
  }

  func testCommittedLeaseAndFutureChargeCannotOverflowCombinedRetained() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 1, retainedLimit: .max, resident: 0)
    let reservation = try ledger.reserve(.init(active: 1, retained: .max))
    try ledger.retain(reservation, as: .fixture())
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.reserve(.init(active: 1, retained: 1)))
    XCTAssertEqual(ledger.snapshot, before)
  }

  func testAbandonedReservationCannotBecomeLease() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 2)
    let reservation = try ledger.reserve(.init(active: 3, retained: 4))
    ledger.abandon(reservation)
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.retain(reservation, as: .fixture()))
    XCTAssertEqual(ledger.snapshot, before)
  }

  func testFutureResultsCompeteBeforeRetention() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 20, retainedLimit: 10, resident: 1)
    _ = try ledger.reserve(.init(active: 3, retained: 6))
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.reserve(.init(active: 3, retained: 5)))
    XCTAssertEqual(ledger.snapshot, before)
  }

  func testOldLeaseRemainsChargedDuringReplacementReservation() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 2)
    let old = try ledger.reserve(.init(active: 8, retained: 6))
    let lease = SearchResultLeaseID.fixture()
    try ledger.retain(old, as: lease)
    XCTAssertEqual(ledger.snapshot.active, 2)
    XCTAssertEqual(ledger.snapshot.retained, 6)
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.reserve(.init(active: 8, retained: 6)))
    XCTAssertEqual(ledger.snapshot, before)
    ledger.release(lease)
    _ = try ledger.reserve(.init(active: 8, retained: 6))
    XCTAssertEqual(ledger.snapshot.active, 10)
    XCTAssertEqual(ledger.snapshot.reservedRetained, 6)
  }

  func testRetainTransfersExactlyOnceAndReleaseIsIdempotent() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 12, retainedLimit: 10, resident: 2)
    let reservation = try ledger.reserve(.init(active: 8, retained: 6))
    let lease = SearchResultLeaseID.fixture()
    try ledger.retain(reservation, as: lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 2, retained: 6, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.retain(reservation, as: .fixture()))
    XCTAssertEqual(ledger.snapshot, before)
    ledger.abandon(reservation)
    XCTAssertEqual(ledger.snapshot, before)
    ledger.release(lease)
    ledger.release(lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 2, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  func testForeignReservationAndUnknownLeaseCannotAffectOwnership() throws {
    var first = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 1)
    var second = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 1)
    let foreign = try first.reserve(.init(active: 4, retained: 3))
    _ = try second.reserve(.init(active: 4, retained: 3))
    let before = second.snapshot
    second.abandon(foreign)
    second.release(.fixture())
    XCTAssertThrowsError(try second.retain(foreign, as: .fixture()))
    XCTAssertEqual(second.snapshot, before)
  }

  func testDuplicateLeaseRefusalPreservesReservationForLaterCommit() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 1)
    let a = try ledger.reserve(.init(active: 4, retained: 3))
    let b = try ledger.reserve(.init(active: 5, retained: 7))
    let lease = SearchResultLeaseID.fixture()
    try ledger.retain(a, as: lease)
    let before = ledger.snapshot
    XCTAssertThrowsError(try ledger.retain(b, as: lease))
    XCTAssertEqual(ledger.snapshot, before)
    try ledger.retain(b, as: .fixture())
    XCTAssertEqual(ledger.snapshot.retained, 10)
    XCTAssertEqual(ledger.snapshot.active, 1)
  }

  func testIndependentReservationOrderAndIdempotentAbandon() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 20, retainedLimit: 20, resident: 2)
    let a = try ledger.reserve(.init(active: 3, retained: 4))
    let b = try ledger.reserve(.init(active: 5, retained: 6))
    try ledger.retain(b, as: .fixture())
    ledger.abandon(a)
    ledger.abandon(a)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 2, retained: 6, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
  }

  func testDescriptorRejectsUnsafeEstimateAndScope() throws {
    for estimate in [-1, 11, Int.max] {
      XCTAssertThrowsError(try descriptor(estimate: estimate)) {
        XCTAssertEqual($0 as? SearchAdmissionFailure, .invalidDescriptor)
      }
    }
    for scope in [
      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
      NSRange(location: Int.max, length: 1), NSRange(location: 1, length: Int.max),
      NSRange(location: 8, length: 3),
    ] {
      XCTAssertThrowsError(try descriptor(scope: scope)) {
        XCTAssertEqual($0 as? SearchAdmissionFailure, .invalidDescriptor)
      }
    }
    _ = try descriptor(scope: NSRange(location: 10, length: 0))
  }

  func testDescriptorBoundsQueryAndTemplateInUTF16() throws {
    let boundary = String(repeating: "😀", count: 2048)
    _ = try descriptor(pattern: boundary, operation: .replace(template: boundary))
    XCTAssertThrowsError(try descriptor(pattern: boundary + "x"))
    XCTAssertThrowsError(try descriptor(operation: .replace(template: boundary + "x")))
  }

  func testDescriptorPreservesFullSupportedLimitWithoutAllocatingSource() throws {
    let limits = try SearchWireLimits(
      maxTextUTF16: 100_000_000, maxOutputUTF16: 100_000_000, maxMatches: 100_000,
      cooperativeMilliseconds: 60_000)
    let descriptor = try SearchAdmissionDescriptor(
      query: .init(pattern: "x", mode: .literal), operation: .find,
      estimatedInputUTF16: 100_000_000, scope: NSRange(location: 99_999_999, length: 1),
      limits: limits)
    XCTAssertEqual(descriptor.estimatedInputUTF16, 100_000_000)
  }

  private func descriptor(
    estimate: Int = 10, scope: NSRange? = nil, pattern: String = "x",
    operation: SearchExecutionOperation = .find
  ) throws -> SearchAdmissionDescriptor {
    try SearchAdmissionDescriptor(
      query: .init(pattern: pattern, mode: .literal), operation: operation,
      estimatedInputUTF16: estimate, scope: scope,
      limits: SearchWireLimits(
        maxTextUTF16: 10, maxOutputUTF16: 10, maxMatches: 10, cooperativeMilliseconds: 10))
  }
}

extension SearchResultLeaseID {
  fileprivate static func fixture() -> Self { Self() }
}
