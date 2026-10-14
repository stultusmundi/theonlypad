// SPDX-License-Identifier: MIT
// Hidden native worker contracts with synthetic inputs.
import Darwin
import Foundation
import PadCore
import XCTest

@testable import FolderReplacementPreviewComponent

@MainActor
final class FolderReplacementPreviewWorkLaneTests: XCTestCase {
  // Break: execution on MainActor or lossy BOM/Unicode/line-ending reconstruction.
  func testActualCoreOffMainPreservesIndependentBytesAndWholeFileFacts() async throws {
    try await withFixture { fixture in
      let a = Data([0xef, 0xbb, 0xbf]) + Data("needle\r\n😀needle\r".utf8)
      let b = Data("e\u{301}\nneedle\r\nend\r".utf8)
      try fixture.write(a, to: fixture.a)
      try fixture.write(b, to: fixture.b)
      let (outcome, probe) = try await actual(fixture.input())
      guard case .ready(let display) = outcome else {
        return XCTFail("No complete actual Core result")
      }
      XCTAssertEqual(probe.threadFlags, [false])
      XCTAssertEqual(display.rows.count, 2)
      guard display.rows.count == 2 else { return }
      let first = display.rows[0]
      let second = display.rows[1]
      XCTAssertEqual(display.rows.map(\.path), ["a.txt", "b.txt"])
      XCTAssertEqual(display.rows.map(\.matches), [2, 1])
      XCTAssertEqual(display.rows.map(\.sourceBytes), [22, 16])
      XCTAssertEqual(display.rows.map(\.outputBytes), [12, 11])
      XCTAssertEqual(display.rows.map(\.hasBOM), [true, false])
      XCTAssertEqual(display.rows.map(\.wouldChange), [true, true])
      XCTAssertEqual(Data([0xef, 0xbb, 0xbf]) + Data(first.originalExcerpt.utf8), a)
      XCTAssertEqual(
        Data([0xef, 0xbb, 0xbf]) + Data(first.proposedExcerpt.utf8),
        Data([0xef, 0xbb, 0xbf]) + Data("X\r\n😀X\r".utf8))
      XCTAssertEqual(Data(second.originalExcerpt.utf8), b)
      XCTAssertEqual(Data(second.proposedExcerpt.utf8), Data("e\u{301}\nX\r\nend\r".utf8))
      XCTAssertEqual(first.originalMatchRange, NSRange(location: 0, length: 6))
      XCTAssertEqual(second.originalMatchRange, NSRange(location: 3, length: 6))
      XCTAssertEqual(first.proposedAnchorUTF16, 0)
      XCTAssertEqual(second.proposedAnchorUTF16, 3)
      XCTAssertEqual(first.originalExcerptRange, NSRange(location: 0, length: 17))
      XCTAssertEqual(first.proposedExcerptRange, NSRange(location: 0, length: 7))
      XCTAssertEqual(second.originalExcerptRange, NSRange(location: 0, length: 15))
      XCTAssertEqual(second.proposedExcerptRange, NSRange(location: 0, length: 10))
      XCTAssertFalse(first.excerptIsLimited)
      XCTAssertFalse(second.excerptIsLimited)
      XCTAssertEqual(display.sourceBytes, 38)
      XCTAssertEqual(display.outputBytes, 23)
      XCTAssertEqual(display.matchCount, 3)
    }
  }

  // Break: output re-matching/capture expansion, or rejecting deletion anchor at EOF/empty output.
  func testLiteralReplacementAndDeletionUseReplacementAnchorNotOutputMatch() async throws {
    try await withFixture { fixture in
      try fixture.write(Data("needle\r\nneedle".utf8), to: fixture.a)
      let (literal, _) = try await actual(
        fixture.input(files: [fixture.a], replacement: #"$1$&\n"#))
      guard case .ready(let display) = literal, let row = display.rows.first else {
        return XCTFail("No literal projection")
      }
      let six: [UInt8] = [0x24, 0x31, 0x24, 0x26, 0x5c, 0x6e]
      XCTAssertEqual(Data(row.proposedExcerpt.utf8), Data(six + [0x0d, 0x0a] + six))
      XCTAssertEqual(row.proposedAnchorUTF16, 0)
      try fixture.write(Data("😀needle".utf8), to: fixture.a)
      let (deletedEOF, _) = try await actual(fixture.input(files: [fixture.a], replacement: ""))
      guard case .ready(let end) = deletedEOF, let endRow = end.rows.first else {
        return XCTFail("No EOF deletion projection")
      }
      XCTAssertEqual(endRow.originalMatchRange, NSRange(location: 2, length: 6))
      XCTAssertEqual(endRow.proposedAnchorUTF16, 2)
      XCTAssertEqual(endRow.proposedExcerptRange, NSRange(location: 0, length: 2))
      XCTAssertEqual(Data(endRow.proposedExcerpt.utf8), Data([0xf0, 0x9f, 0x98, 0x80]))
      XCTAssertEqual(endRow.outputBytes, 4)
      try fixture.write(Data("needle".utf8), to: fixture.a)
      let (deletedAll, _) = try await actual(fixture.input(files: [fixture.a], replacement: ""))
      guard case .ready(let empty) = deletedAll, let emptyRow = empty.rows.first else {
        return XCTFail("No empty deletion projection")
      }
      XCTAssertEqual(emptyRow.proposedAnchorUTF16, 0)
      XCTAssertEqual(emptyRow.proposedExcerptRange, NSRange(location: 0, length: 0))
      XCTAssertEqual(emptyRow.proposedExcerpt, "")
      XCTAssertEqual(emptyRow.outputBytes, 0)
      XCTAssertEqual(empty.matchCount, 1)
    }
  }

  // Break: counting matches as byte changes or trimming whitespace literal input.
  func testNoMatchEqualReplacementAndWhitespaceHaveDistinctFacts() async throws {
    try await withFixture { fixture in
      for (pattern, replacement, count, anchor) in [
        ("absent", "X", 0, Int?.none), ("needle", "needle", 1, Int?.some(0)),
      ] {
        let (outcome, _) = try await actual(
          fixture.input(files: [fixture.a], pattern: pattern, replacement: replacement))
        guard case .ready(let display) = outcome, let row = display.rows.first else {
          return XCTFail("Missing factual projection")
        }
        XCTAssertEqual(row.matches, count)
        XCTAssertEqual(row.proposedAnchorUTF16, anchor)
        XCTAssertEqual(row.proposedExcerpt, "needle")
        XCTAssertFalse(row.wouldChange)
        XCTAssertEqual(display.outputBytes, 6)
      }
      try fixture.write(Data(" \t ".utf8), to: fixture.a)
      let (outcome, _) = try await actual(
        fixture.input(files: [fixture.a], pattern: " ", replacement: ""))
      guard case .ready(let display) = outcome, let row = display.rows.first else {
        return XCTFail("Whitespace literal refused")
      }
      XCTAssertEqual(row.matches, 2)
      XCTAssertEqual(Data(row.proposedExcerpt.utf8), Data([0x09]))
      XCTAssertTrue(row.wouldChange)
    }
  }

  // Break: excerpt counts masquerading as complete counts, full-file render, or split UTF8 scalar.
  func testTwoFileProjectionCapsFourExcerptsAndKeepsExactWholeFileFacts() async throws {
    try await withFixture { fixture in
      try fixture.write(
        Data(
          (String(repeating: "a", count: 20_000) + "needle" + String(repeating: "😀", count: 20_000))
            .utf8), to: fixture.a)
      try fixture.write(
        Data(
          (String(repeating: "b", count: 20_000) + "needle" + String(repeating: "😀", count: 20_000))
            .utf8), to: fixture.b)
      let (outcome, _) = try await actual(fixture.input())
      guard case .ready(let display) = outcome else { return XCTFail("No bounded projection") }
      XCTAssertEqual(display.rows.count, 2)
      guard display.rows.count == 2 else { return }
      for (row, letter) in zip(display.rows, ["a", "b"]) {
        XCTAssertEqual(
          row.originalExcerpt,
          String(repeating: letter, count: 8192) + "needle" + String(repeating: "😀", count: 2046))
        XCTAssertEqual(
          row.proposedExcerpt,
          String(repeating: letter, count: 8192) + "X" + String(repeating: "😀", count: 2047))
        XCTAssertEqual(row.originalExcerpt.utf8.count, 16_382)
        XCTAssertEqual(row.proposedExcerpt.utf8.count, 16_381)
        XCTAssertEqual(row.originalExcerptRange, NSRange(location: 11_808, length: 12_290))
        XCTAssertEqual(row.proposedExcerptRange, NSRange(location: 11_808, length: 12_287))
        XCTAssertEqual(row.originalMatchRange, NSRange(location: 20_000, length: 6))
        XCTAssertEqual(row.proposedAnchorUTF16, 20_000)
        XCTAssertTrue(row.excerptIsLimited)
        XCTAssertEqual(row.sourceBytes, 100_006)
        XCTAssertEqual(row.outputBytes, 100_001)
        XCTAssertEqual(row.matches, 1)
      }
      let rendered = display.rows.reduce(0) {
        $0 + $1.originalExcerpt.utf8.count + $1.proposedExcerpt.utf8.count
      }
      XCTAssertEqual(rendered, 65_526)
      XCTAssertLessThanOrEqual(rendered, 65_536)
      XCTAssertEqual(display.sourceBytes, 200_012)
      XCTAssertEqual(display.outputBytes, 200_002)
      XCTAssertEqual(display.matchCount, 2)
    }
  }

  // Break: retaining first-file presentation after actual selected-file failure or incidental writes.
  func testActualSecondFileFailureReturnsOnlyFailureAndPreservesSyntheticTree() async throws {
    try await withFixture { fixture in
      try fixture.write(Data([0xff]), to: fixture.b)
      let (outcome, probe) = try await actual(fixture.input())
      XCTAssertEqual(probe.threadFlags, [false])
      XCTAssertEqual(outcome, .failed(.core("unsupportedInput")))
    }
  }

  // Break: cancel prematurely releases admission, starts queued work or acknowledges before return.
  func testEnteredHeldOperationKeepsSingleAdmissionUntilActualSettlement() async throws {
    try await withFixture { fixture in
      let executor = HeldWorkExecutor()
      let gate = EnteredWorkGate()
      defer { gate.open() }
      let started = expectation(description: "operation entered off-main")
      let settled = expectation(description: "exact settlement")
      let lane = FolderReplacementPreviewWorkLane(
        executor: executor,
        operation: { _, token in
          started.fulfill()
          gate.wait()
          gate.recordCancelled(token.isCancelled)
          return Self.displayStub()
        })
      let id = UUID()
      var publicationIDs: [UUID] = []
      var settlementIDs: [UUID] = []
      XCTAssertTrue(
        try lane.start(
          fixture.input(), requestID: id,
          publish: { request, outcome in
            publicationIDs.append(request)
            XCTAssertEqual(outcome, .cancelled)
          },
          settled: { request in
            settlementIDs.append(request)
            settled.fulfill()
          }))
      try executor.launchOffMain()
      await fulfillment(of: [started], timeout: 5)
      try lane.cancel(requestID: id)
      XCTAssertFalse(
        try lane.start(
          fixture.input(), requestID: UUID(),
          publish: { _, _ in XCTFail("Rejected job published") },
          settled: { _ in XCTFail("Rejected job settled") }))
      XCTAssertEqual(executor.submissionCount, 1)
      XCTAssertTrue(publicationIDs.isEmpty)
      XCTAssertTrue(settlementIDs.isEmpty)
      gate.open()
      await fulfillment(of: [settled], timeout: 5)
      XCTAssertEqual(gate.cancelledObserved, true)
      XCTAssertEqual(publicationIDs, [id])
      XCTAssertEqual(settlementIDs, [id])
    }
  }

  // Required R1 break: publication invalidation also drops ownership settlement and freezes live panel.
  func testCancelledLiveRecipientUnfreezesOnExactSettlementAndCanStartAgain() async throws {
    try await withFixture { fixture in
      let executor = HeldWorkExecutor()
      let gate = EnteredWorkGate()
      defer { gate.open() }
      let started = expectation(description: "entered A")
      let retired = expectation(description: "A settled despite invalid publication")
      let lane = FolderReplacementPreviewWorkLane(
        executor: executor,
        operation: { _, _ in
          if gate.recordEntry() == 1 { started.fulfill() }
          gate.wait()
          return Self.displayStub()
        })
      let state = FolderReplacementPreviewWorkState()
      let a = UUID()
      let generation = try state.begin(requestID: a)
      XCTAssertTrue(
        try lane.start(
          fixture.input(), requestID: a,
          publish: { id, outcome in
            do {
              let published = try state.publish(
                requestID: id, generation: generation, outcome: outcome)
              XCTAssertFalse(published)
            } catch { XCTFail("Stale publication handling threw: \(error)") }
          },
          settled: { id in
            do {
              let acknowledged = try state.acknowledgeSettlement(requestID: id)
              XCTAssertTrue(acknowledged)
            } catch { XCTFail("Owned settlement handling threw: \(error)") }
            retired.fulfill()
          }))
      try executor.launchOffMain()
      await fulfillment(of: [started], timeout: 5)
      XCTAssertEqual(try state.requestCancellation(), a)
      try lane.cancel(requestID: a)
      XCTAssertNotEqual(state.publicationGeneration, generation)
      XCTAssertEqual(state.phase, .cancelRequested)
      XCTAssertFalse(state.canStart)
      XCTAssertFalse(
        try lane.start(
          fixture.input(), requestID: UUID(), publish: { _, _ in XCTFail() },
          settled: { _ in XCTFail() }))
      gate.open()
      await fulfillment(of: [retired], timeout: 5)
      XCTAssertEqual(state.phase, .inputReady)
      XCTAssertTrue(state.canStart)
      XCTAssertNil(state.activeRequestID)
      XCTAssertNil(state.lastOutcome)
      let b = UUID()
      let bGeneration = try state.begin(requestID: b)
      let next = expectation(description: "B settled")
      XCTAssertTrue(
        try lane.start(
          fixture.input(), requestID: b,
          publish: { id, outcome in
            do {
              let published = try state.publish(
                requestID: id, generation: bGeneration, outcome: outcome)
              XCTAssertTrue(published)
            } catch { XCTFail("Current publication threw: \(error)") }
          },
          settled: { id in
            do {
              let acknowledged = try state.acknowledgeSettlement(requestID: id)
              XCTAssertTrue(acknowledged)
            } catch { XCTFail("Successor settlement threw: \(error)") }
            next.fulfill()
          }))
      XCTAssertFalse(try state.acknowledgeSettlement(requestID: a))
      XCTAssertEqual(state.activeRequestID, b)
      try executor.launchOffMain()
      await fulfillment(of: [next], timeout: 5)
      XCTAssertEqual(state.phase, .ready)
      XCTAssertTrue(state.canStart)
      XCTAssertEqual(executor.submissionCount, 2)
    }
  }

  // Break: exact closed acknowledgement reopens UI, or old IDs clear successor ownership.
  func testClosedRecipientAndOldAcknowledgementsCannotAffectSuccessor() throws {
    let old = FolderReplacementPreviewWorkState()
    let successor = FolderReplacementPreviewWorkState()
    let a = UUID()
    let b = UUID()
    let generationA = try old.begin(requestID: a)
    _ = try successor.begin(requestID: b)
    XCTAssertEqual(try old.close(), a)
    XCTAssertFalse(
      try old.publish(requestID: a, generation: generationA, outcome: .ready(Self.displayStub())))
    XCTAssertTrue(try old.acknowledgeSettlement(requestID: a))
    XCTAssertEqual(old.phase, .closed)
    XCTAssertFalse(old.canStart)
    XCTAssertNil(old.lastOutcome)
    XCTAssertNil(old.activeRequestID)
    XCTAssertFalse(try old.acknowledgeSettlement(requestID: a))
    XCTAssertFalse(try successor.acknowledgeSettlement(requestID: a))
    XCTAssertEqual(successor.activeRequestID, b)
    XCTAssertEqual(successor.phase, .running)
    XCTAssertFalse(successor.canStart)
  }

  // Break: accepting stale success/error to unfreeze ownership also restores stale rows/error.
  func testInvalidatedSuccessAndErrorNeverPublishButOwnedSettlementStillRetires() throws {
    let state = FolderReplacementPreviewWorkState()
    let id = UUID()
    let generation = try state.begin(requestID: id)
    XCTAssertEqual(try state.requestCancellation(), id)
    XCTAssertFalse(
      try state.publish(requestID: id, generation: generation, outcome: .ready(Self.displayStub())))
    XCTAssertFalse(
      try state.publish(
        requestID: id, generation: generation,
        outcome: .failed(.io(domain: "SyntheticLateError", code: 42))))
    XCTAssertNil(state.lastOutcome)
    XCTAssertFalse(try state.acknowledgeSettlement(requestID: UUID()))
    XCTAssertEqual(state.phase, .cancelRequested)
    XCTAssertEqual(state.activeRequestID, id)
    XCTAssertTrue(try state.acknowledgeSettlement(requestID: id))
    XCTAssertTrue(state.canStart)
    XCTAssertEqual(state.phase, .inputReady)
    XCTAssertNil(state.lastOutcome)
  }

  // Break: failed/shared-busy admission leaves a pending UI intent permanently busy.
  func testRejectedAdmissionRetiresOnlyPendingIntentWithoutFakeWorkerReceipt() throws {
    let state = FolderReplacementPreviewWorkState()
    let id = UUID()
    _ = try state.begin(requestID: id)
    XCTAssertFalse(try state.rejectAdmission(requestID: UUID()))
    XCTAssertEqual(state.activeRequestID, id)
    XCTAssertTrue(try state.rejectAdmission(requestID: id))
    XCTAssertTrue(state.canStart)
    XCTAssertEqual(state.phase, .inputReady)
    XCTAssertNil(state.lastOutcome)
    XCTAssertFalse(try state.acknowledgeSettlement(requestID: id))
  }

  // Break: failed executor submission emits fabricated settlement/publication or leaks admission.
  func testExecutorSubmissionFailurePropagatesOriginalErrorWithoutCallbacks() throws {
    let executor = FailingWorkExecutor()
    let lane = FolderReplacementPreviewWorkLane(
      executor: executor, operation: { _, _ in Self.displayStub() })
    let input = FolderReplacementPreviewInput(
      root: URL(fileURLWithPath: "/synthetic-root"), files: [],
      query: .init(pattern: "needle", mode: .literal), replacement: "X")
    for _ in 0..<2 {
      XCTAssertThrowsError(
        try lane.start(
          input, requestID: UUID(), publish: { _, _ in XCTFail("Submission failure published") },
          settled: { _ in XCTFail("Unentered job acknowledged") })
      ) {
        XCTAssertEqual(($0 as NSError).domain, "SyntheticExecutorFailure")
        XCTAssertEqual(($0 as NSError).code, 42)
      }
    }
    XCTAssertEqual(executor.submissionCount, 2)
  }

  private func actual(_ input: FolderReplacementPreviewInput) async throws -> (
    FolderReplacementPreviewWorkOutcome, ThreadProbe
  ) {
    let probe = ThreadProbe()
    let lane = FolderReplacementPreviewWorkLane(operation: { input, cancellation in
      probe.record(Thread.isMainThread)
      return try FolderReplacementPreviewWorkOperation.run(input, cancellation: cancellation)
    })
    let id = UUID()
    let done = expectation(description: "actual job settled")
    var result: FolderReplacementPreviewWorkOutcome?
    let admitted = try lane.start(
      input, requestID: id,
      publish: { request, outcome in
        XCTAssertEqual(request, id)
        result = outcome
      },
      settled: { request in
        XCTAssertEqual(request, id)
        done.fulfill()
      })
    guard admitted else { throw NSError(domain: "SyntheticUnexpectedAdmissionRefusal", code: 1) }
    await fulfillment(of: [done], timeout: 5)
    guard let result else { throw NSError(domain: "SyntheticMissingPublishedOutcome", code: 1) }
    return (result, probe)
  }

  private func withFixture(_ body: (WorkFixture) async throws -> Void) async throws {
    let fixture = try WorkFixture()
    defer {
      fixture.assertPreserved()
      do { try FileManager.default.removeItem(at: fixture.container) } catch {
        XCTFail("Owned worker fixture cleanup failed: \(error)")
      }
    }
    try await body(fixture)
  }

  // Pure injected presentation data only. Never a Core snapshot or actual-reader acceptance oracle.
  nonisolated private static func displayStub() -> FolderReplacementPreviewDisplay {
    .init(operationID: UUID(), rows: [], matchCount: 0, sourceBytes: 0, outputBytes: 0)
  }
}

private final class ThreadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var flags: [Bool] = []
  func record(_ flag: Bool) {
    lock.lock()
    flags.append(flag)
    lock.unlock()
  }
  var threadFlags: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return flags
  }
}

private final class EnteredWorkGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var opened = false
  private var cancelled: Bool?
  private var entries = 0
  func recordEntry() -> Int {
    condition.lock()
    defer { condition.unlock() }
    entries += 1
    return entries
  }
  func wait() {
    condition.lock()
    defer { condition.unlock() }
    while !opened { condition.wait() }
  }
  func open() {
    condition.lock()
    opened = true
    condition.broadcast()
    condition.unlock()
  }
  func recordCancelled(_ value: Bool) {
    condition.lock()
    cancelled = value
    condition.unlock()
  }
  var cancelledObserved: Bool? {
    condition.lock()
    defer { condition.unlock() }
    return cancelled
  }
}

private final class HeldWorkExecutor: FolderReplacementPreviewWorkExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: (@Sendable () -> Void)?
  private var count = 0
  func submit(_ work: @escaping @Sendable () -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    guard pending == nil else { throw NSError(domain: "SyntheticUnexpectedExecutorQueue", code: 1) }
    count += 1
    pending = work
  }
  func launchOffMain() throws {
    lock.lock()
    let work = pending
    pending = nil
    lock.unlock()
    guard let work else { throw NSError(domain: "SyntheticNoSubmittedWork", code: 1) }
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
  }
  var submissionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class FailingWorkExecutor: FolderReplacementPreviewWorkExecuting, @unchecked Sendable
{
  private let lock = NSLock()
  private var count = 0
  func submit(_ work: @escaping @Sendable () -> Void) throws {
    lock.lock()
    count += 1
    lock.unlock()
    throw NSError(domain: "SyntheticExecutorFailure", code: 42)
  }
  var submissionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

@MainActor
private final class WorkFixture {
  let container: URL
  let root: URL
  var a: URL { root.appendingPathComponent("a.txt") }
  var b: URL { root.appendingPathComponent("b.txt") }
  private var expected: [String: WorkObservedEntry] = [:]
  init() throws {
    guard
      let pointer = realpath(
        FileManager.default.temporaryDirectory.path(percentEncoded: false), nil)
    else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let base = String(cString: pointer)
    free(pointer)
    container = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(
      UUID().uuidString)
    root = container.appendingPathComponent("selected-root")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let backups = container.appendingPathComponent("sentinel-backups")
      try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
      try Data([0x00, 0xff, 0x42]).write(to: backups.appendingPathComponent("sentinel.bin"))
      try Data("needle".utf8).write(to: a)
      try Data("needle".utf8).write(to: b)
      expected = try observe()
    } catch {
      try? FileManager.default.removeItem(at: container)
      throw error
    }
  }
  func input(files: [URL]? = nil, pattern: String = "needle", replacement: String = "X")
    -> FolderReplacementPreviewInput
  {
    .init(
      root: root, files: files ?? [a, b], query: .init(pattern: pattern, mode: .literal),
      replacement: replacement)
  }
  func write(_ data: Data, to url: URL) throws {
    assertPreserved()
    try data.write(to: url)
    expected = try observe()
  }
  func assertPreserved(file: StaticString = #filePath, line: UInt = #line) {
    do {
      let actual = try observe()
      XCTAssertEqual(actual, expected, file: file, line: line)
    } catch { XCTFail("Cannot inspect owned worker fixture: \(error)", file: file, line: line) }
  }
  private func observe() throws -> [String: WorkObservedEntry] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: container, includingPropertiesForKeys: nil)
    else {
      throw NSError(domain: "SyntheticWorkerInventory", code: 1)
    }
    var base = container.path(percentEncoded: false)
    while base.count > 1, base.hasSuffix("/") { base.removeLast() }
    var result: [String: WorkObservedEntry] = [:]
    for case let url as URL in enumerator {
      let path = url.path(percentEncoded: false)
      var info = stat()
      guard lstat(path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      guard path.hasPrefix(base + "/") else {
        throw NSError(domain: "SyntheticWorkerInventory", code: 2)
      }
      let kind = info.st_mode & S_IFMT
      let bytes = kind == S_IFREG ? try Data(contentsOf: url) : nil
      let link =
        kind == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
      if kind == S_IFLNK { enumerator.skipDescendants() }
      result[String(path.dropFirst(base.count + 1))] = WorkObservedEntry(
        device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
        mode: UInt32(info.st_mode), owner: UInt32(info.st_uid), links: UInt64(info.st_nlink),
        msec: Int64(info.st_mtimespec.tv_sec), mnsec: Int64(info.st_mtimespec.tv_nsec),
        csec: Int64(info.st_ctimespec.tv_sec), cnsec: Int64(info.st_ctimespec.tv_nsec),
        bytes: bytes, link: link)
    }
    return result
  }
}

private struct WorkObservedEntry: Equatable {
  let device: UInt64
  let inode: UInt64
  let mode: UInt32
  let owner: UInt32
  let links: UInt64
  let msec: Int64
  let mnsec: Int64
  let csec: Int64
  let cnsec: Int64
  let bytes: Data?
  let link: String?
}
