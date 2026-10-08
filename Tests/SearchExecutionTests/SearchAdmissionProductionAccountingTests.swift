import Foundation
import PadCore
import XCTest

@testable import SearchExecution

final class SearchAdmissionProductionAccountingTests: XCTestCase {
  func testEmptyFindRetainsMetadataAndEndpointWithoutChargingUnusedOutput() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let empty = try descriptor(input: 0, output: 100_000_000)
    XCTAssertEqual(
      try accounting.charge(for: empty), .init(active: 65_537, retained: 4_096))
    XCTAssertEqual(accounting.activeLimit, 1_610_612_736)
    XCTAssertEqual(accounting.retainedLimit, 1_342_177_280)
    XCTAssertEqual(accounting.resident, 1_048_576)
  }

  func testBoundaryBitmapIncludesZeroAndEndpointAcrossByteEdges() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let cases: [(input: Int, active: UInt64, retained: UInt64)] = [
      (0, 65_537, 4_096),
      (7, 65_579, 4_117),
      (8, 65_586, 4_120),
      (100_000_000, 612_565_537, 300_004_096),
    ]
    for row in cases {
      // Metadata only: no input text or large boundary index is constructed.
      let actual = try accounting.charge(for: descriptor(input: row.input))
      XCTAssertEqual(actual, .init(active: row.active, retained: row.retained), "I=\(row.input)")
    }
  }

  func testSupplementaryPatternAndTemplateUseUTF16RatherThanCharacterCounts() throws {
    let accounting = SearchAdmissionProductionAccounting()
    // Q=4 units (supplementary scalar plus decomposed accented e), T=3 units.
    let find = try descriptor(input: 8, output: 9, matches: 2, pattern: "😀e\u{301}")
    let replace = try descriptor(
      input: 8, output: 9, matches: 2, pattern: "😀e\u{301}",
      operation: .replace(template: "猫💡"))
    XCTAssertEqual(try accounting.charge(for: find), .init(active: 65_662, retained: 4_152))
    XCTAssertEqual(try accounting.charge(for: replace), .init(active: 65_725, retained: 4_179))
  }

  func testFindIgnoresDeclaredReplacementCeiling() throws {
    let accounting = SearchAdmissionProductionAccounting()
    for output in [0, 9, 100_000_000] {
      let value = try descriptor(input: 11, output: output, matches: 5, pattern: "😀")
      XCTAssertEqual(
        try accounting.charge(for: value), .init(active: 65_770, retained: 4_209),
        "Unused find output ceiling \(output)")
    }
  }

  func testZeroOutputReplacementStillChargesTemplateButNoReplacementText() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let find = try descriptor(input: 8, matches: 2, pattern: "😀e\u{301}")
    let replace = try descriptor(
      input: 8, matches: 2, pattern: "😀e\u{301}", operation: .replace(template: "猫💡"))
    XCTAssertEqual(try accounting.charge(for: find), .init(active: 65_662, retained: 4_152))
    XCTAssertEqual(try accounting.charge(for: replace), .init(active: 65_671, retained: 4_152))
  }

  func testSmallOrEmptyScopeCannotDiscountFullEstimatedSource() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let scopes: [NSRange?] = [
      nil, NSRange(location: 99_999_999, length: 1),
      NSRange(location: 100_000_000, length: 0),
    ]
    for scope in scopes {
      let value = try descriptor(input: 100_000_000, pattern: "x", scope: scope)
      XCTAssertEqual(
        try accounting.charge(for: value), .init(active: 612_565_540, retained: 300_004_096))
    }
  }

  func testMatchCeilingReservesBothActiveAndRetainedRangeContent() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let cases: [(matches: Int, active: UInt64, retained: UInt64)] = [
      (0, 65_537, 4_096), (1, 65_569, 4_112), (100_000, 3_265_537, 1_604_096),
    ]
    for row in cases {
      XCTAssertEqual(
        try accounting.charge(for: descriptor(matches: row.matches)),
        .init(active: row.active, retained: row.retained))
    }
  }

  func testGenuineMaximumDescriptorsHaveLiteralChargesWithoutLargeSourceAllocation() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let blob = String(repeating: "😀", count: 2048)  // Exactly 4096 UTF16 units.
    let find = try descriptor(
      input: 100_000_000, output: 100_000_000,
      matches: 100_000, pattern: blob)
    let replace = try maximumReplacement()
    XCTAssertEqual(
      try accounting.charge(for: find), .init(active: 615_777_825, retained: 301_604_096))
    XCTAssertEqual(
      try accounting.charge(for: replace), .init(active: 1_215_790_113, retained: 601_604_096))
  }

  func testExactLedgerLimitsAdmitButEachOneByteShortBudgetRefusesWithoutMutation() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let charge = try accounting.charge(for: maximumReplacement())
    var exact = try SearchAdmissionLedger(
      activeLimit: 1_216_838_689, retainedLimit: 601_604_096, resident: accounting.resident)
    let reservation = try exact.reserve(charge)
    XCTAssertEqual(
      exact.snapshot,
      .init(
        active: 1_216_838_689, retained: 0, reservedRetained: 601_604_096,
        reservationCount: 1, leaseCount: 0))
    exact.abandon(reservation)
    exact.abandon(reservation)
    XCTAssertEqual(
      exact.snapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )

    let shortLimits: [(active: UInt64, retained: UInt64)] = [
      (1_216_838_688, 601_604_096), (1_216_838_689, 601_604_095),
    ]
    for limits in shortLimits {
      var ledger = try SearchAdmissionLedger(
        activeLimit: limits.active, retainedLimit: limits.retained, resident: accounting.resident)
      let before = ledger.snapshot
      XCTAssertThrowsError(try ledger.reserve(charge)) {
        XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget)
      }
      XCTAssertEqual(ledger.snapshot, before)
    }
  }

  func testProductionBudgetsKeepOldLeaseAndFutureCreditThenRefuseThirdMaximum() throws {
    let accounting = SearchAdmissionProductionAccounting()
    let charge = try accounting.charge(for: maximumReplacement())
    var ledger = try SearchAdmissionLedger(
      activeLimit: accounting.activeLimit, retainedLimit: accounting.retainedLimit,
      resident: accounting.resident)
    let first = SearchResultLeaseID()
    let second = SearchResultLeaseID()
    let firstReservation = try ledger.reserve(charge)
    try ledger.retain(firstReservation, as: first)
    let future = try ledger.reserve(charge)
    XCTAssertEqual(
      ledger.snapshot,
      .init(
        active: 1_216_838_689, retained: 601_604_096, reservedRetained: 601_604_096,
        reservationCount: 1, leaseCount: 1))
    try ledger.retain(future, as: second)
    XCTAssertEqual(
      ledger.snapshot,
      .init(
        active: 1_048_576, retained: 1_203_208_192, reservedRetained: 0,
        reservationCount: 0, leaseCount: 2))
    let before = ledger.snapshot
    // Active is back to resident, so this refusal specifically needs retained credit.
    XCTAssertThrowsError(try ledger.reserve(charge)) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget)
    }
    XCTAssertEqual(ledger.snapshot, before)
    ledger.release(first)
    ledger.release(first)
    XCTAssertEqual(ledger.snapshot.retained, 601_604_096)
    XCTAssertEqual(ledger.snapshot.leaseCount, 1)
    ledger.release(second)
    ledger.release(second)
    XCTAssertEqual(
      ledger.snapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
  }

  private func maximumReplacement() throws -> SearchAdmissionDescriptor {
    let blob = String(repeating: "😀", count: 2048)
    return try descriptor(
      input: 100_000_000, output: 100_000_000, matches: 100_000,
      pattern: blob, operation: .replace(template: blob))
  }

  private func descriptor(
    input: Int = 0, output: Int = 0, matches: Int = 0, pattern: String = "",
    operation: SearchExecutionOperation = .find, scope: NSRange? = nil
  ) throws -> SearchAdmissionDescriptor {
    try SearchAdmissionDescriptor(
      query: .init(pattern: pattern, mode: .literal), operation: operation,
      estimatedInputUTF16: input, scope: scope,
      limits: SearchWireLimits(
        maxTextUTF16: input, maxOutputUTF16: output, maxMatches: matches, cooperativeMilliseconds: 0
      ))
  }
}
