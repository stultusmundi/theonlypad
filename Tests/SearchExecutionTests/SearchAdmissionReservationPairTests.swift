import XCTest

@testable import SearchExecution

final class SearchAdmissionReservationPairTests: XCTestCase {
  // Break: the pair uses separate budgets or omits either real reservation.
  func testPairReservesBothChargesInSameSnapshot() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 100, retainedLimit: 70, resident: 10)
    let existing = try ledger.reserve(.init(active: 20, retained: 10))
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 30, retained: 0, reservedRetained: 10, reservationCount: 1, leaseCount: 0))
    let pair = try ledger.reservePair(
      base: .init(active: 30, retained: 20), producer: .init(active: 15, retained: 0))
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 75, retained: 0, reservedRetained: 30, reservationCount: 3, leaseCount: 0))
    ledger.abandon(pair.base)
    ledger.abandon(pair.producer)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 30, retained: 0, reservedRetained: 10, reservationCount: 1, leaseCount: 0))
    let lease = SearchResultLeaseID()
    try ledger.retain(existing, as: lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 10, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    ledger.release(lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: a rejected second admission leaves the admitted base behind.
  func testSecondAdmissionFailureRestoresExactExistingSnapshot() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 80, retainedLimit: 70, resident: 10)
    let existing = try ledger.reserve(.init(active: 20, retained: 10))
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 30, retained: 0, reservedRetained: 10, reservationCount: 1, leaseCount: 0))
    // Base raises active to70; only producer would cross80 to90.
    XCTAssertThrowsError(
      try ledger.reservePair(
        base: .init(active: 40, retained: 20), producer: .init(active: 20, retained: 0))
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget) }
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 30, retained: 0, reservedRetained: 10, reservationCount: 1, leaseCount: 0))
    ledger.abandon(existing)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: producer future-retained credit is admitted, or zero active skips its entry.
  func testProducerRetainedChargeRefusesBeforeBaseAdmission() throws {
    for active in [UInt64(1), UInt64.max] {
      var ledger = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 1)
      XCTAssertThrowsError(
        try ledger.reservePair(
          base: .init(active: active, retained: 1), producer: .init(active: 1, retained: 1))
      ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .invalidDescriptor) }
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
    }
    var zero = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 10, resident: 1)
    let pair = try zero.reservePair(
      base: .init(active: 6, retained: 4), producer: .init(active: 0, retained: 0))
    XCTAssertEqual(
      zero.snapshot,
      .init(active: 7, retained: 0, reservedRetained: 4, reservationCount: 2, leaseCount: 0))
    zero.abandon(pair.base)
    XCTAssertEqual(
      zero.snapshot,
      .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 1, leaseCount: 0))
    zero.abandon(pair.producer)
    XCTAssertEqual(
      zero.snapshot,
      .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: pair admission ignores already-retained leases or future reservations.
  func testSharedRetainedLimitIncludesExistingLeasesAndReservations() throws {
    do {
      var ledger = try SearchAdmissionLedger(activeLimit: 1000, retainedLimit: 60, resident: 1)
      let old = try ledger.reserve(.init(active: 10, retained: 30))
      let lease = SearchResultLeaseID()
      try ledger.retain(old, as: lease)
      let pending = try ledger.reserve(.init(active: 20, retained: 20))
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 21, retained: 30, reservedRetained: 20, reservationCount: 1, leaseCount: 1))
      // Combined retained would be30+20+11=61; the base admission itself refuses.
      XCTAssertThrowsError(
        try ledger.reservePair(
          base: .init(active: 30, retained: 11), producer: .init(active: 15, retained: 0))
      ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget) }
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 21, retained: 30, reservedRetained: 20, reservationCount: 1, leaseCount: 1))
      ledger.abandon(pending)
      ledger.release(lease)
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
    }
    do {
      // Fresh equivalent ownership reaches exact60 rather than reusing a full ledger.
      var ledger = try SearchAdmissionLedger(activeLimit: 1000, retainedLimit: 60, resident: 1)
      let old = try ledger.reserve(.init(active: 10, retained: 30))
      let lease = SearchResultLeaseID()
      try ledger.retain(old, as: lease)
      let pending = try ledger.reserve(.init(active: 20, retained: 20))
      let pair = try ledger.reservePair(
        base: .init(active: 30, retained: 10), producer: .init(active: 15, retained: 0))
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 66, retained: 30, reservedRetained: 30, reservationCount: 3, leaseCount: 1))
      ledger.abandon(pair.base)
      ledger.abandon(pair.producer)
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 21, retained: 30, reservedRetained: 20, reservationCount: 1, leaseCount: 1))
      ledger.abandon(pending)
      ledger.release(lease)
      XCTAssertEqual(
        ledger.snapshot,
        .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
    }
  }

  // Break: retaining base also retires producer, or producer token aliases base.
  func testRetainBaseKeepsProducerActiveUntilSeparateAbandon() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 100, retainedLimit: 70, resident: 10)
    let pair = try ledger.reservePair(
      base: .init(active: 30, retained: 20), producer: .init(active: 15, retained: 0))
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 55, retained: 0, reservedRetained: 20, reservationCount: 2, leaseCount: 0))
    let lease = SearchResultLeaseID()
    try ledger.retain(pair.base, as: lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 25, retained: 20, reservedRetained: 0, reservationCount: 1, leaseCount: 1))
    ledger.abandon(pair.producer)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 20, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    ledger.release(lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: abandoning producer destroys the still-pending base's retain authority.
  func testAbandonProducerKeepsBaseReservationForLaterRetention() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 100, retainedLimit: 70, resident: 10)
    let pair = try ledger.reservePair(
      base: .init(active: 30, retained: 20), producer: .init(active: 15, retained: 0))
    ledger.abandon(pair.producer)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 40, retained: 0, reservedRetained: 20, reservationCount: 1, leaseCount: 0))
    let lease = SearchResultLeaseID()
    XCTAssertNoThrow(try ledger.retain(pair.base, as: lease))
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 20, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    ledger.release(lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: failed base retention consumes producer or accepts foreign pair tokens.
  func testDuplicateLeaseAndForeignBaseRefuseWithoutLosingProducer() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 100, retainedLimit: 100, resident: 1)
    let old = try ledger.reserve(.init(active: 20, retained: 10))
    let sharedLease = SearchResultLeaseID()
    try ledger.retain(old, as: sharedLease)
    let pair = try ledger.reservePair(
      base: .init(active: 30, retained: 20), producer: .init(active: 15, retained: 0))
    XCTAssertThrowsError(try ledger.retain(pair.base, as: sharedLease)) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .internalFailure)
    }
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 46, retained: 10, reservedRetained: 20, reservationCount: 2, leaseCount: 1))

    var origin = try SearchAdmissionLedger(activeLimit: 100, retainedLimit: 100, resident: 2)
    let foreign = try origin.reservePair(
      base: .init(active: 7, retained: 9), producer: .init(active: 3, retained: 0))
    XCTAssertEqual(
      origin.snapshot,
      .init(active: 12, retained: 0, reservedRetained: 9, reservationCount: 2, leaseCount: 0))
    XCTAssertThrowsError(try ledger.retain(foreign.base, as: SearchResultLeaseID())) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .internalFailure)
    }
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 46, retained: 10, reservedRetained: 20, reservationCount: 2, leaseCount: 1))
    XCTAssertEqual(
      origin.snapshot,
      .init(active: 12, retained: 0, reservedRetained: 9, reservationCount: 2, leaseCount: 0))
    ledger.abandon(foreign.base)
    ledger.abandon(foreign.producer)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 46, retained: 10, reservedRetained: 20, reservationCount: 2, leaseCount: 1))
    XCTAssertEqual(
      origin.snapshot,
      .init(active: 12, retained: 0, reservedRetained: 9, reservationCount: 2, leaseCount: 0))

    let freshLease = SearchResultLeaseID()
    try ledger.retain(pair.base, as: freshLease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 16, retained: 30, reservedRetained: 0, reservationCount: 1, leaseCount: 2))
    ledger.abandon(pair.producer)
    ledger.release(sharedLease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 1, retained: 20, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    ledger.release(freshLease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
    origin.abandon(foreign.producer)
    let originLease = SearchResultLeaseID()
    XCTAssertNoThrow(try origin.retain(foreign.base, as: originLease))
    XCTAssertEqual(
      origin.snapshot,
      .init(active: 2, retained: 9, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    origin.release(originLease)
    XCTAssertEqual(
      origin.snapshot,
      .init(active: 2, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: checked second admission wraps, or a full first variant masks that branch.
  func testActiveOverflowAndExactBoundaryAreTransactional() throws {
    var overflow = try SearchAdmissionLedger(activeLimit: .max, retainedLimit: 0, resident: 1)
    // First admission reaches max-1; the second alone would overflow to max+1.
    XCTAssertThrowsError(
      try overflow.reservePair(
        base: .init(active: UInt64.max - 2, retained: 0), producer: .init(active: 2, retained: 0))
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget) }
    XCTAssertEqual(
      overflow.snapshot,
      .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))

    var exact = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 0, resident: 1)
    let pair = try exact.reservePair(
      base: .init(active: 5, retained: 0), producer: .init(active: 4, retained: 0))
    XCTAssertEqual(
      exact.snapshot,
      .init(active: 10, retained: 0, reservedRetained: 0, reservationCount: 2, leaseCount: 0))
    exact.abandon(pair.base)
    exact.abandon(pair.producer)
    XCTAssertEqual(
      exact.snapshot,
      .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))

    var beyond = try SearchAdmissionLedger(activeLimit: 10, retainedLimit: 0, resident: 1)
    // Fresh resident1+base5 fits; only producer5 crosses10 to11.
    XCTAssertThrowsError(
      try beyond.reservePair(
        base: .init(active: 5, retained: 0), producer: .init(active: 5, retained: 0))
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget) }
    XCTAssertEqual(
      beyond.snapshot,
      .init(active: 1, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }

  // Break: a stale half or repeated release retires another still-live obligation.
  func testRepeatedHalfRetirementDoesNotReleaseOtherHalf() throws {
    var ledger = try SearchAdmissionLedger(activeLimit: 100, retainedLimit: 70, resident: 10)
    let pair = try ledger.reservePair(
      base: .init(active: 30, retained: 20), producer: .init(active: 15, retained: 0))
    let lease = SearchResultLeaseID()
    try ledger.retain(pair.base, as: lease)
    XCTAssertThrowsError(try ledger.retain(pair.base, as: SearchResultLeaseID())) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .internalFailure)
    }
    ledger.abandon(pair.base)
    ledger.abandon(pair.base)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 25, retained: 20, reservedRetained: 0, reservationCount: 1, leaseCount: 1))
    ledger.abandon(pair.producer)
    ledger.abandon(pair.producer)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 20, reservedRetained: 0, reservationCount: 0, leaseCount: 1))
    ledger.release(lease)
    ledger.release(lease)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 10, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0))
  }
}
