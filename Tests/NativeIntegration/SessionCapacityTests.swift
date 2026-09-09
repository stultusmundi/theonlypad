import Foundation
import XCTest

@testable import PadCore
@testable import SessionCapacity

@MainActor final class SessionCapacityTests: XCTestCase {
  enum Failure: Error { case synthetic }

  func testHeldStartupInvalidatesBeforeCompletionAndResolutionCallbackSeesFreshRevision()
    async throws
  {
    var release: CheckedContinuation<EditorSession?, Error>?
    let tab = SessionTab()
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let coordinator = SessionCoordinator(
      loadSession: { try await withCheckedThrowingContinuation { release = $0 } },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    let initial = coordinator.capacityRevision
    let task = Task { await coordinator.restore { _ in [:] } }
    for _ in 0..<1000 {
      if release != nil { break }
      await Task.yield()
    }
    let held = try XCTUnwrap(release)
    XCTAssertNotEqual(coordinator.capacityRevision, initial)
    XCTAssertThrowsError(try coordinator.transferCapacity(liveWindows: [:]))
    let pendingRevision = coordinator.capacityRevision
    held.resume(returning: EditorSession(windows: [window]))
    await task.value
    XCTAssertNotEqual(coordinator.capacityRevision, pendingRevision)
    let beforeResolve = coordinator.capacityRevision
    var callbackSnapshot: SessionCapacitySnapshot?
    coordinator.onSessionChange = {
      callbackSnapshot = try? coordinator.transferCapacity(liveWindows: [:])
    }
    coordinator.resolved(try XCTUnwrap(coordinator.unresolved.first))
    let observed = try XCTUnwrap(callbackSnapshot)
    XCTAssertNotEqual(observed.sessionRevision, beforeResolve)
    XCTAssertEqual(observed.sessionRevision, coordinator.capacityRevision)
    XCTAssertTrue(observed.documentIDs.isEmpty)
  }

  func testActualCorruptFileIsPreservedAndCapacityDoesNotRetryIO() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Session.json")
    let corrupt = Data("{\"version\":99}".utf8)
    try corrupt.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var reads = 0
    var writes = 0
    let coordinator = SessionCoordinator(
      loadSession: {
        reads += 1
        return try SessionStore(directory: directory).load()
      },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in writes += 1 })
    await coordinator.restore { _ in
      XCTFail("Corrupt file cannot import")
      return [:]
    }
    XCTAssertFalse(coordinator.startupErrors.isEmpty)
    let revision = coordinator.capacityRevision
    for _ in 0..<3 { XCTAssertThrowsError(try coordinator.transferCapacity(liveWindows: [:])) }
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(coordinator.capacityRevision, revision)
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }

  func testSuccessfulActualFileAndUnresolvedOnlyWindowUnion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("synthetic.txt")
    try Data("synthetic 😀".utf8).write(to: file)
    let saved = SessionTab(originalPath: file.path)
    let missing = SessionTab()
    let first = SessionWindow(tabs: [saved], selectedTabID: saved.id)
    let second = SessionWindow(tabs: [missing], selectedTabID: missing.id)
    var fileReads = 0
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [first, second]) },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) },
      readFile: { metadata, url in
        fileReads += 1
        return try SessionCoordinator.read(metadata, at: url)
      })
    var live: [UUID: Set<UUID>] = [:]
    await coordinator.restore { window in
      live[window.id] = Set(window.tabs.map { $0.metadata.id })
      return [:]
    }
    XCTAssertEqual(live, [first.id: [saved.id]])
    let snapshot = try coordinator.transferCapacity(liveWindows: live)
    XCTAssertEqual(snapshot.windowIDs, [first.id, second.id])
    XCTAssertEqual(snapshot.documentIDs, [saved.id, missing.id])
    XCTAssertEqual(fileReads, 1)
  }

  func testUnfinishedAndPreservedFailureRefuseSnapshot() async throws {
    let unfinished = SessionCoordinator(
      loadSession: { nil }, claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    XCTAssertThrowsError(try unfinished.transferCapacity(liveWindows: [:]))
    let corrupt = SessionCoordinator(
      loadSession: { throw Failure.synthetic },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    let before = corrupt.capacityRevision
    await corrupt.restore { _ in [:] }
    XCTAssertTrue(corrupt.restorationComplete)
    XCTAssertNotEqual(before, corrupt.capacityRevision)
    XCTAssertThrowsError(try corrupt.transferCapacity(liveWindows: [:]))
  }

  func testUnionIncludesUnresolvedOnlyWindowsAndSnapshotHasNoEffects() async throws {
    let missing = SessionTab()
    let window = SessionWindow(tabs: [missing], selectedTabID: missing.id)
    var calls = 0
    let coordinator = SessionCoordinator(
      loadSession: {
        calls += 1
        return EditorSession(windows: [window])
      },
      claimRecovery: {
        calls += 1
        return .init(snapshots: [], quarantinedCount: 0)
      },
      saveSession: { _ in calls += 1 }, removeRecovery: { _ in calls += 1 },
      readFile: { _, _ in
        calls += 1
        throw Failure.synthetic
      })
    var notices = 0
    coordinator.onSessionChange = { notices += 1 }
    await coordinator.restore { _ in
      XCTFail("Missing scratch cannot import")
      return [:]
    }
    let liveWindow = UUID()
    let liveDocument = UUID()
    let revision = coordinator.capacityRevision
    let count = calls
    let notifications = notices
    let snapshot = try coordinator.transferCapacity(liveWindows: [liveWindow: [liveDocument]])
    XCTAssertEqual(snapshot.windowIDs, [window.id, liveWindow])
    XCTAssertEqual(snapshot.documentIDs, [missing.id, liveDocument])
    XCTAssertEqual(snapshot.sessionRevision, revision)
    XCTAssertEqual(
      try coordinator.transferCapacity(liveWindows: [liveWindow: [liveDocument]]), snapshot)
    XCTAssertEqual(calls, count)
    XCTAssertEqual(notices, notifications)
    XCTAssertEqual(coordinator.capacityRevision, revision)
    try coordinator.recordRecentOpen(URL(fileURLWithPath: "/synthetic/recent-only"))
    coordinator.clearRecent()
    XCTAssertEqual(coordinator.capacityRevision, revision)
    coordinator.resolved(try XCTUnwrap(coordinator.unresolved.first))
    XCTAssertNotEqual(coordinator.capacityRevision, revision)
    let after = try coordinator.transferCapacity(liveWindows: [
      liveWindow: [liveDocument, missing.id]
    ])
    XCTAssertEqual(after.windowIDs, [liveWindow], "Old historical window isn't live or unresolved")
    XCTAssertEqual(after.documentIDs, [liveDocument, missing.id])
  }

  func testTruthfulOverCapacitySetsAndDeduplication() async throws {
    let coordinator = SessionCoordinator(
      loadSession: { nil }, claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    await coordinator.restore { _ in [:] }
    let ids = Set((0..<129).map { _ in UUID() })
    let windows = Dictionary(uniqueKeysWithValues: (0..<33).map { _ in (UUID(), ids) })
    let result = try coordinator.transferCapacity(liveWindows: windows)
    XCTAssertEqual(result.windowIDs, Set(windows.keys))
    XCTAssertEqual(
      result.documentIDs, ids, "Snapshot does not hide excess or multiply duplicate IDs")
  }

  func testHeldCleanupBlocksThenFailureAndSuccessInvalidateRevision() async throws {
    let tab = SessionTab()
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    var continuation: CheckedContinuation<Void, Error>?
    var cleanupCalls = 0
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [window]) },
      claimRecovery: {
        .init(
          snapshots: [
            RecoverySnapshot(id: tab.id, text: "synthetic", encoding: .utf8, hasBOM: false)
          ], quarantinedCount: 0)
      },
      removeRecovery: { _ in
        cleanupCalls += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
      })
    await coordinator.restore { _ in [tab.id: "synthetic import refusal"] }
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    for shouldFail in [true, false] {
      let before = coordinator.capacityRevision
      let task = Task { try await coordinator.remove(entry) }
      for _ in 0..<1000 {
        if continuation != nil { break }
        await Task.yield()
      }
      let held = try XCTUnwrap(continuation)
      XCTAssertNotEqual(coordinator.capacityRevision, before)
      XCTAssertThrowsError(try coordinator.transferCapacity(liveWindows: [:]))
      let during = coordinator.capacityRevision
      continuation = nil
      if shouldFail { held.resume(throwing: Failure.synthetic) } else { held.resume() }
      do {
        try await task.value
        XCTAssertFalse(shouldFail)
      } catch { XCTAssertTrue(shouldFail) }
      XCTAssertNotEqual(coordinator.capacityRevision, during)
      let snapshot = try coordinator.transferCapacity(liveWindows: [:])
      XCTAssertEqual(snapshot.documentIDs, shouldFail ? [tab.id] : [])
      XCTAssertEqual(snapshot.windowIDs, shouldFail ? [window.id] : [])
    }
    XCTAssertEqual(cleanupCalls, 2)
  }
}
