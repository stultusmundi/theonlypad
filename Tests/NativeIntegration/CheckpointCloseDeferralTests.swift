import Foundation
import PadCore
import XCTest

@testable import CheckpointCloseDeferral

private enum DeferralTestFailure: Error, Equatable { case genuine, readiness }
private enum PreparationDisposition { case ready, close, genuine }

@MainActor private final class DeferralSchedulerFixture {
  let directory: URL
  let store: SessionStore
  let recovery: RecoveryCoordinator
  var disposition = PreparationDisposition.close
  var captureRefusesClose = false
  var preparations = 0
  var captures = 0
  var commits = 0
  var delays: [CheckpointDelay] = []
  var receipts: [SessionCheckpointReceipt] = []

  init() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = SessionStore(directory: directory.appendingPathComponent("session"))
    let store = store
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
  }

  lazy var scheduler = SessionCheckpointCoordinator(
    capture: { generation in
      self.captures += 1
      if self.captureRefusesClose { throw CheckpointSchedulerError.closeInProgress }
      return SessionCheckpointCapture(
        generation: generation, liveTabIDs: [], recovery: [], session: EditorSession(windows: []))
    },
    commit: { capture in
      self.commits += 1
      let receipt = try await self.recovery.commitSessionCheckpoint(capture)
      self.receipts.append(receipt)
      return receipt
    },
    prepareCapture: {
      self.preparations += 1
      switch self.disposition {
      case .ready: return
      case .close: throw CheckpointSchedulerError.closeInProgress
      case .genuine: throw DeferralTestFailure.genuine
      }
    },
    delay: { kind in
      self.delays.append(kind)
      await Task.yield()
    })
}

@MainActor final class CheckpointCloseDeferralTests: XCTestCase {
  private func until(_ predicate: () -> Bool) async throws {
    for _ in 0..<10_000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("Existing scheduler boundary must be reached before deferral credit")
    throw DeferralTestFailure.readiness
  }

  func testOrdinaryPreparationCloseDefersWithoutErrorAndNextRequestPublishesRealReceipt()
    async throws
  {
    let f = DeferralSchedulerFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.scheduler.startAfterRestoration()
    try await until {
      f.preparations == 1 && (f.scheduler.phase == .idle || f.scheduler.phase == .failed)
    }
    XCTAssertNil(f.scheduler.lastError, "Expected close preparation is a pending deferral")
    XCTAssertEqual(f.scheduler.phase, .idle)
    XCTAssertEqual(f.captures, 0)
    XCTAssertEqual(f.commits, 0)
    XCTAssertTrue(f.receipts.isEmpty)
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 0)
    XCTAssertTrue(f.scheduler.hasPendingChanges)
    XCTAssertNil(try f.store.load())
    for _ in 0..<32 { await Task.yield() }
    XCTAssertEqual(f.preparations, 1, "Deferral consumes this attempt; idle must not self-retry")
    XCTAssertEqual(f.delays, [.debounce])
    f.disposition = .ready
    f.scheduler.requestCheckpoint()
    try await until { f.scheduler.phase == .idle && !f.scheduler.hasPendingChanges }
    XCTAssertEqual(f.preparations, 2)
    XCTAssertEqual(f.captures, 1)
    XCTAssertEqual(f.commits, 1)
    XCTAssertEqual(f.receipts.map(\.generation), [2])
    XCTAssertTrue(f.receipts[0].recoveryRevisions.isEmpty)
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 2)
    XCTAssertNil(f.scheduler.lastError)
    XCTAssertEqual(f.delays, [.debounce, .debounce])
    XCTAssertEqual(try XCTUnwrap(f.store.load()).windows, [])
    await f.scheduler.pauseAndDrain()
  }

  func testCloseDeferralPreservesPriorGenuineErrorUntilRealReceipt() async throws {
    let f = DeferralSchedulerFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.disposition = .genuine
    f.scheduler.startAfterRestoration()
    try await until { f.preparations == 1 && f.scheduler.phase == .failed }
    XCTAssertEqual(f.scheduler.lastError as? DeferralTestFailure, .genuine)
    f.disposition = .close
    f.scheduler.requestCheckpoint()
    try await until { f.preparations == 2 && f.scheduler.phase == .failed }
    XCTAssertEqual(
      f.scheduler.lastError as? DeferralTestFailure, .genuine,
      "Expected close deferral cannot overwrite or clear a prior genuine failure")
    XCTAssertEqual(f.captures, 0)
    XCTAssertEqual(f.commits, 0)
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 0)
    XCTAssertTrue(f.scheduler.hasPendingChanges)
    XCTAssertNil(try f.store.load())
    for _ in 0..<32 { await Task.yield() }
    XCTAssertEqual(f.preparations, 2)
    XCTAssertEqual(f.delays, [.debounce, .retry])
    f.disposition = .ready
    f.scheduler.requestCheckpoint()
    try await until { f.scheduler.phase == .idle && !f.scheduler.hasPendingChanges }
    XCTAssertEqual(f.receipts.map(\.generation), [3])
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 3)
    XCTAssertEqual(f.captures, 1)
    XCTAssertEqual(f.commits, 1)
    XCTAssertNil(f.scheduler.lastError)
    XCTAssertEqual(f.delays, [.debounce, .retry, .retry])
    await f.scheduler.pauseAndDrain()
  }

  func testFinalPreparationCloseStillThrowsAndRecordsItsError() async throws {
    let f = DeferralSchedulerFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.scheduler.pauseAndDrain()
    f.scheduler.startAfterRestoration()
    do {
      _ = try await f.scheduler.commitFinal()
      XCTFail("Final checkpoint cannot swallow close preparation refusal")
    } catch {
      guard case CheckpointSchedulerError.closeInProgress = error else {
        XCTFail("Final must preserve the exact existing closeInProgress error")
        throw error
      }
    }
    guard case CheckpointSchedulerError.closeInProgress? = f.scheduler.lastError else {
      XCTFail("Final failure must retain its actual error")
      await f.scheduler.pauseAndDrain()
      return
    }
    XCTAssertEqual(f.preparations, 1)
    XCTAssertEqual(f.captures, 0)
    XCTAssertEqual(f.commits, 0)
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 0)
    XCTAssertTrue(f.scheduler.hasPendingChanges)
    XCTAssertFalse(f.scheduler.isFinalizing)
    XCTAssertNil(try f.store.load())
    await f.scheduler.pauseAndDrain()
  }

  func testCaptureCloseErrorIsNotAnOrdinaryPreparationDeferral() async throws {
    let f = DeferralSchedulerFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.disposition = .ready
    f.captureRefusesClose = true
    f.scheduler.startAfterRestoration()
    try await until { f.scheduler.phase == .failed && f.captures == 1 }
    guard case CheckpointSchedulerError.closeInProgress? = f.scheduler.lastError else {
      XCTFail("Only prepareCapture close refusal may defer; a capture error remains genuine")
      await f.scheduler.pauseAndDrain()
      return
    }
    XCTAssertEqual(f.preparations, 1)
    XCTAssertEqual(f.commits, 0)
    XCTAssertTrue(f.receipts.isEmpty)
    XCTAssertTrue(f.scheduler.hasPendingChanges)
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 0)
    XCTAssertNil(try f.store.load())
    await f.scheduler.pauseAndDrain()
  }
}
