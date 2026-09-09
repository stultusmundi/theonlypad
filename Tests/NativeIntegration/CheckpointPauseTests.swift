import Foundation
import PadCore
import XCTest

@testable import CheckpointPause

@MainActor private final class PauseFixture {
  var prepares = 0
  var captures = 0
  var writes = 0
  var holdPreparation = false
  var holdWrite = false
  var preparation: CheckedContinuation<Void, Never>?
  var publication: CheckedContinuation<Void, Never>?
  lazy var scheduler = SessionCheckpointCoordinator(
    capture: { generation in
      self.captures += 1
      return SessionCheckpointCapture(
        generation: generation, liveTabIDs: [], recovery: [], session: EditorSession(windows: []))
    },
    commit: { value in
      self.writes += 1
      if self.holdWrite { await withCheckedContinuation { self.publication = $0 } }
      return SessionCheckpointReceipt(generation: value.generation, recoveryRevisions: [:])
    },
    prepareCapture: {
      self.prepares += 1
      if self.holdPreparation { await withCheckedContinuation { self.preparation = $0 } }
    }, delay: { _ in await Task.yield() })
  func releasePreparation() {
    let value = preparation
    preparation = nil
    value?.resume()
  }
  func releaseWrite() {
    let value = publication
    publication = nil
    value?.resume()
  }
}

final class CheckpointPauseTests: XCTestCase {
  @MainActor private func until(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Deterministic boundary was not reached", file: file, line: line)
  }

  @MainActor func testAcquireBeforeStartPreventsCaptureAndLastReleaseResumes() async throws {
    let f = PauseFixture()
    let token = try f.scheduler.acquirePause()
    f.scheduler.startAfterRestoration()
    f.scheduler.requestCheckpoint()
    try await f.scheduler.drainPause(token)
    XCTAssertEqual(f.captures, 0)
    try f.scheduler.releasePause(token)
    await until { f.writes == 1 }
    await f.scheduler.pauseAndDrain()
  }

  @MainActor func testTwoTokensCannotResumeEachOther() async throws {
    let f = PauseFixture()
    let first = try f.scheduler.acquirePause()
    let second = try f.scheduler.acquirePause()
    f.scheduler.startAfterRestoration()
    try await f.scheduler.drainPause(second)
    try await f.scheduler.drainPause(first)
    try f.scheduler.releasePause(first)
    f.scheduler.requestCheckpoint()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(f.captures, 0)
    try f.scheduler.releasePause(second)
    await until { f.writes == 1 }
    await f.scheduler.pauseAndDrain()
  }

  @MainActor func testPreparationDrainsWithoutSubsequentCapture() async throws {
    let f = PauseFixture()
    f.holdPreparation = true
    f.scheduler.startAfterRestoration()
    await until { f.preparation != nil }
    let token = try f.scheduler.acquirePause()
    var drained = false
    let task = Task {
      try await f.scheduler.drainPause(token)
      drained = true
    }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(drained)
    XCTAssertThrowsError(try f.scheduler.releasePause(token))
    f.releasePreparation()
    try await task.value
    XCTAssertTrue(drained)
    XCTAssertEqual(f.captures, 0)
    f.holdPreparation = false
    try f.scheduler.releasePause(token)
    await until { f.writes == 1 }
    await f.scheduler.pauseAndDrain()
  }

  @MainActor func testPublicationMustFinishBeforeTokenCanRelease() async throws {
    let f = PauseFixture()
    f.holdWrite = true
    f.scheduler.startAfterRestoration()
    await until { f.publication != nil }
    let token = try f.scheduler.acquirePause()
    var drained = false
    let task = Task {
      try await f.scheduler.drainPause(token)
      drained = true
    }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(drained)
    XCTAssertEqual(f.scheduler.lastAcknowledgedGeneration, 0)
    f.releaseWrite()
    try await task.value
    XCTAssertGreaterThan(f.scheduler.lastAcknowledgedGeneration, 0)
    await f.scheduler.pauseAndDrain()
    try f.scheduler.releasePause(token)
  }

  @MainActor func testForeignDuplicateAndUndrainedTokensRefused() async throws {
    let f = PauseFixture()
    let other = PauseFixture()
    let token = try f.scheduler.acquirePause()
    XCTAssertThrowsError(try other.scheduler.releasePause(token))
    do {
      try await other.scheduler.drainPause(token)
      XCTFail("foreign drain")
    } catch {}
    XCTAssertThrowsError(try f.scheduler.releasePause(token))
    try await f.scheduler.drainPause(token)
    try f.scheduler.releasePause(token)
    XCTAssertThrowsError(try f.scheduler.releasePause(token))
    do {
      try await f.scheduler.drainPause(token)
      XCTFail("retired drain")
    } catch {}
  }

  @MainActor func testCanceledDrainRetainsPauseUntilExplicitRelease() async throws {
    let f = PauseFixture()
    f.holdWrite = true
    f.scheduler.startAfterRestoration()
    await until { f.publication != nil }
    let token = try f.scheduler.acquirePause()
    let task = Task { try await f.scheduler.drainPause(token) }
    task.cancel()
    f.releaseWrite()
    _ = try? await task.value
    f.scheduler.resumeAfterVeto()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(f.captures, 1)
    try await f.scheduler.drainPause(token)
    await f.scheduler.pauseAndDrain()
    try f.scheduler.releasePause(token)
  }

  @MainActor func testLegacyAndLeasePausesAreIndependent() async throws {
    let f = PauseFixture()
    f.scheduler.startAfterRestoration()
    await f.scheduler.pauseAndDrain()
    let token = try f.scheduler.acquirePause()
    try await f.scheduler.drainPause(token)
    try f.scheduler.releasePause(token)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(f.captures, 0)
    let second = try f.scheduler.acquirePause()
    f.scheduler.resumeAfterVeto()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(f.captures, 0)
    try await f.scheduler.drainPause(second)
    try f.scheduler.releasePause(second)
    await until { f.writes == 1 }
    await f.scheduler.pauseAndDrain()
  }

  @MainActor func testFinalAndCloseAdmissionExcludeEachOther() async throws {
    let f = PauseFixture()
    let token = try f.scheduler.acquirePause()
    f.scheduler.startAfterRestoration()
    do {
      _ = try await f.scheduler.commitFinal()
      XCTFail("final while close paused")
    } catch {}
    XCTAssertEqual(f.captures, 0)
    try await f.scheduler.drainPause(token)
    await f.scheduler.pauseAndDrain()
    try f.scheduler.releasePause(token)
    f.holdWrite = true
    let final = Task { try await f.scheduler.commitFinal() }
    await until { f.publication != nil }
    XCTAssertThrowsError(try f.scheduler.acquirePause())
    f.releaseWrite()
    _ = try await final.value
    XCTAssertEqual(f.captures, 1)
  }
}
