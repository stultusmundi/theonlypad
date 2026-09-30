import Foundation
import XCTest

@testable import SearchExecution

final class SearchParentWireByteCounterTests: XCTestCase {
  func testWholeStreamBytesReachExactLimitAndStayRetired() throws {
    let generation = UUID()
    var counter = try SearchParentWireByteCounter(
      generation: generation, sessionEpoch: 3, maximumWireBytes: 100)
    try counter.record(32, generation: generation, sessionEpoch: 3)
    try counter.record(67, generation: generation, sessionEpoch: 3)
    XCTAssertEqual(counter.totalBytes, 99)
    XCTAssertFalse(counter.retirementRequired)
    try counter.record(1, generation: generation, sessionEpoch: 3)
    XCTAssertTrue(counter.retirementRequired)
    try counter.record(0, generation: generation, sessionEpoch: 3)
    try counter.record(12, generation: generation, sessionEpoch: 3)
    XCTAssertEqual(counter.totalBytes, 112)
    XCTAssertTrue(counter.retirementRequired)
  }
  func testStaleGenerationAndSessionCannotDebitReplacement() throws {
    let generation = UUID()
    var counter = try SearchParentWireByteCounter(
      generation: generation, sessionEpoch: 4, maximumWireBytes: 10)
    try counter.record(100, generation: UUID(), sessionEpoch: 4)
    try counter.record(100, generation: generation, sessionEpoch: 3)
    try counter.record(-1, generation: UUID(), sessionEpoch: 4)
    XCTAssertEqual(counter.totalBytes, 0)
    XCTAssertFalse(counter.retirementRequired)
    try counter.record(10, generation: generation, sessionEpoch: 4)
    XCTAssertTrue(counter.retirementRequired)
  }
  func testInvalidIdentityAndZeroThresholdAreRejected() {
    XCTAssertThrowsError(
      try SearchParentWireByteCounter(generation: UUID(), sessionEpoch: 1, maximumWireBytes: 0))
    XCTAssertThrowsError(
      try SearchParentWireByteCounter(generation: UUID(), sessionEpoch: 0, maximumWireBytes: 1))
    XCTAssertThrowsError(
      try SearchParentWireByteCounter(
        generation: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), sessionEpoch: 1,
        maximumWireBytes: 1))
  }
  func testNegativeMatchingByteCountDoesNotMutateCounter() throws {
    let generation = UUID()
    var counter = try SearchParentWireByteCounter(
      generation: generation, sessionEpoch: 1, maximumWireBytes: 20)
    try counter.record(3, generation: generation, sessionEpoch: 1)
    XCTAssertThrowsError(try counter.record(-1, generation: generation, sessionEpoch: 1))
    XCTAssertEqual(counter.totalBytes, 3)
  }
  func testOverflowSaturatesWithoutWrappingOrClearingRetirement() throws {
    let generation = UUID()
    var counter = try SearchParentWireByteCounter(
      generation: generation, sessionEpoch: 1, maximumWireBytes: UInt64.max)
    try counter.record(Int.max, generation: generation, sessionEpoch: 1)
    try counter.record(Int.max, generation: generation, sessionEpoch: 1)
    XCTAssertEqual(counter.totalBytes, UInt64.max - 1)
    XCTAssertFalse(counter.retirementRequired)
    try counter.record(2, generation: generation, sessionEpoch: 1)
    XCTAssertEqual(counter.totalBytes, UInt64.max)
    XCTAssertTrue(counter.retirementRequired)
    try counter.record(1, generation: generation, sessionEpoch: 1)
    XCTAssertEqual(counter.totalBytes, UInt64.max)
  }
  func testNewGenerationCounterStartsAtZero() throws {
    let old = UUID()
    var first = try SearchParentWireByteCounter(
      generation: old, sessionEpoch: 1, maximumWireBytes: 1)
    try first.record(1, generation: old, sessionEpoch: 1)
    let next = try SearchParentWireByteCounter(
      generation: UUID(), sessionEpoch: 2, maximumWireBytes: 1)
    XCTAssertTrue(first.retirementRequired)
    XCTAssertEqual(next.totalBytes, 0)
    XCTAssertFalse(next.retirementRequired)
  }
}
