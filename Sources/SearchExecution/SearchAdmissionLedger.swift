import Foundation

struct SearchAdmissionReservation: Hashable {
  fileprivate let id: UUID
}

struct SearchAdmissionReservationPair {
  let base: SearchAdmissionReservation
  let producer: SearchAdmissionReservation

  fileprivate init(base: SearchAdmissionReservation, producer: SearchAdmissionReservation) {
    self.base = base
    self.producer = producer
  }
}

struct SearchAdmissionLedgerSnapshot: Equatable {
  let active: UInt64
  let retained: UInt64
  let reservedRetained: UInt64
  let reservationCount: Int
  let leaseCount: Int
}

/// The owner bounds the number of entries and releases them only after their payload scopes exit.
/// Resident transport remains charged for this ledger's entire lifetime.
struct SearchAdmissionLedger {
  private let activeLimit: UInt64
  private let retainedLimit: UInt64
  private var active: UInt64
  private var retained: UInt64 = 0
  private var reservedRetained: UInt64 = 0
  private var reservations: [SearchAdmissionReservation: SearchAdmissionCharge] = [:]
  private var leases: [SearchResultLeaseID: UInt64] = [:]

  init(activeLimit: UInt64, retainedLimit: UInt64, resident: UInt64) throws {
    guard resident <= activeLimit else { throw SearchAdmissionFailure.resultBudget }
    self.activeLimit = activeLimit
    self.retainedLimit = retainedLimit
    active = resident
  }

  var snapshot: SearchAdmissionLedgerSnapshot {
    .init(
      active: active, retained: retained, reservedRetained: reservedRetained,
      reservationCount: reservations.count, leaseCount: leases.count)
  }

  mutating func reserve(_ charge: SearchAdmissionCharge) throws -> SearchAdmissionReservation {
    let newActive = active.addingReportingOverflow(charge.active)
    let newReserved = reservedRetained.addingReportingOverflow(charge.retained)
    let totalRetained = retained.addingReportingOverflow(newReserved.partialValue)
    guard !newActive.overflow, !newReserved.overflow, !totalRetained.overflow,
      newActive.partialValue <= activeLimit, totalRetained.partialValue <= retainedLimit
    else { throw SearchAdmissionFailure.resultBudget }
    let reservation = SearchAdmissionReservation(id: UUID())
    guard reservations[reservation] == nil else { throw SearchAdmissionFailure.internalFailure }
    reservations[reservation] = charge
    active = newActive.partialValue
    reservedRetained = newReserved.partialValue
    return reservation
  }

  /// Admit both phases together while preserving their independent retirement authority.
  mutating func reservePair(
    base: SearchAdmissionCharge, producer: SearchAdmissionCharge
  ) throws -> SearchAdmissionReservationPair {
    guard producer.retained == 0 else { throw SearchAdmissionFailure.invalidDescriptor }
    let baseReservation = try reserve(base)
    do {
      let producerReservation = try reserve(producer)
      return .init(base: baseReservation, producer: producerReservation)
    } catch {
      abandon(baseReservation)
      throw error
    }
  }

  mutating func abandon(_ reservation: SearchAdmissionReservation) {
    guard let charge = reservations[reservation] else { return }
    let newActive = active.subtractingReportingOverflow(charge.active)
    let newReserved = reservedRetained.subtractingReportingOverflow(charge.retained)
    // Private entries and counters change together. An underflow is an internal invariant breach.
    precondition(!newActive.overflow && !newReserved.overflow)
    reservations.removeValue(forKey: reservation)
    active = newActive.partialValue
    reservedRetained = newReserved.partialValue
  }

  mutating func retain(_ reservation: SearchAdmissionReservation, as lease: SearchResultLeaseID)
    throws
  {
    guard let charge = reservations[reservation], leases[lease] == nil else {
      throw SearchAdmissionFailure.internalFailure
    }
    let newActive = active.subtractingReportingOverflow(charge.active)
    let newReserved = reservedRetained.subtractingReportingOverflow(charge.retained)
    let newRetained = retained.addingReportingOverflow(charge.retained)
    let totalRetained = newRetained.partialValue.addingReportingOverflow(newReserved.partialValue)
    guard !newActive.overflow, !newReserved.overflow, !newRetained.overflow,
      !totalRetained.overflow, totalRetained.partialValue <= retainedLimit
    else { throw SearchAdmissionFailure.internalFailure }
    reservations.removeValue(forKey: reservation)
    leases[lease] = charge.retained
    active = newActive.partialValue
    reservedRetained = newReserved.partialValue
    retained = newRetained.partialValue
  }

  mutating func release(_ lease: SearchResultLeaseID) {
    guard let charge = leases[lease] else { return }
    let newRetained = retained.subtractingReportingOverflow(charge)
    precondition(!newRetained.overflow)
    leases.removeValue(forKey: lease)
    retained = newRetained.partialValue
  }
}
