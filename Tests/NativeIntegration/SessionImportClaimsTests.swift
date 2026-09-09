import Foundation
import PadCore
import XCTest

@testable import SessionImportClaims

@MainActor final class SessionImportClaimsTests: XCTestCase {
  enum Failure: Error { case synthetic }

  private func fixture(tabs: [SessionTab] = [SessionTab()]) async -> SessionCoordinator {
    let window = SessionWindow(tabs: tabs, selectedTabID: tabs.first?.id)
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [window]) },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Claims cannot publish a session") },
      readFile: { _, _ in throw Failure.synthetic })
    await coordinator.restore { _ in
      XCTFail("Missing fixture cannot import")
      return [:]
    }
    return coordinator
  }

  func testClaimValidatesAndResolvesExactlyOnce() async throws {
    let coordinator = await fixture()
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    let revision = coordinator.capacityRevision
    let claim = try coordinator.claimImport(entry)
    XCTAssertEqual(claim.documentID, entry.metadata.id)
    XCTAssertEqual(claim.windowID, entry.windowID)
    try coordinator.validateImport(claim)
    XCTAssertEqual(coordinator.capacityRevision, revision)
    var callbacks = 0
    coordinator.onSessionChange = {
      callbacks += 1
      XCTAssertTrue(coordinator.unresolved.isEmpty)
      do {
        try coordinator.validateImport(claim)
        XCTFail("Resolved claim must already be stale in callback")
      } catch {}
      if callbacks == 1 {
        do {
          try coordinator.resolveImport(claim)
          XCTFail("Callback cannot replay resolution")
        } catch {}
      }
    }
    try coordinator.resolveImport(claim)
    XCTAssertEqual(callbacks, 1)
    XCTAssertNotEqual(coordinator.capacityRevision, revision)
    XCTAssertThrowsError(try coordinator.resolveImport(claim))
  }

  func testForeignCoordinatorRefusesClaimWithoutConsumingIt() async throws {
    let first = await fixture()
    let second = await fixture()
    let claim = try first.claimImport(XCTUnwrap(first.unresolved.first))
    XCTAssertThrowsError(try second.validateImport(claim))
    XCTAssertThrowsError(try second.resolveImport(claim))
    XCTAssertEqual(second.unresolved.count, 1)
    try first.validateImport(claim)
  }

  func testOtherMembershipChangeInvalidatesClaimForStillUnresolvedEntry() async throws {
    let coordinator = await fixture(tabs: [SessionTab(), SessionTab()])
    let entries = coordinator.unresolved
    let claim = try coordinator.claimImport(entries[0])
    coordinator.resolved(entries[1])
    XCTAssertEqual(coordinator.unresolved.count, 1)
    XCTAssertThrowsError(try coordinator.validateImport(claim))
    XCTAssertThrowsError(try coordinator.resolveImport(claim))
    let fresh = try coordinator.claimImport(entries[0])
    try coordinator.resolveImport(fresh)
  }

  func testErrorProseDoesNotChangeSemanticProvenance() async throws {
    let coordinator = await fixture()
    var entry = try XCTUnwrap(coordinator.unresolved.first)
    entry.errorMessage = "Different presentation-only explanation"
    let claim = try coordinator.claimImport(entry)
    try coordinator.validateImport(claim)
  }

  func testChangedMetadataOrRecoveryDispositionCannotClaimReservedID() async throws {
    let coordinator = await fixture()
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    let altered = UnresolvedSessionEntry(
      windowID: entry.windowID, metadata: SessionTab(id: entry.metadata.id, pinned: true),
      errorMessage: entry.errorMessage)
    XCTAssertThrowsError(try coordinator.claimImport(altered))
    XCTAssertThrowsError(
      try coordinator.claimImport(
        .init(
          windowID: entry.windowID, metadata: entry.metadata, errorMessage: entry.errorMessage,
          hasRecovery: !entry.hasRecovery)))
    XCTAssertEqual(coordinator.unresolved, [entry])
  }

  func testCanonicallyEquivalentButByteDistinctPathCannotClaim() async throws {
    let tab = SessionTab(originalPath: "/synthetic/e\u{301}.txt")
    let coordinator = await fixture(tabs: [tab])
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    let other = SessionTab(id: tab.id, originalPath: "/synthetic/é.txt")
    XCTAssertEqual(tab, other, "Control: synthesized String equality normalizes equivalence")
    XCTAssertFalse(tab.originalPath!.utf8.elementsEqual(other.originalPath!.utf8))
    XCTAssertThrowsError(
      try coordinator.claimImport(
        .init(
          windowID: entry.windowID, metadata: other, errorMessage: entry.errorMessage)))
    try coordinator.validateImport(coordinator.claimImport(entry))
  }

  func testUnstartedAndPreservationErrorRefuseClaims() async throws {
    let ready = await fixture()
    let entry = try XCTUnwrap(ready.unresolved.first)
    let claim = try ready.claimImport(entry)
    let unstarted = SessionCoordinator()
    XCTAssertThrowsError(try unstarted.claimImport(entry))
    XCTAssertThrowsError(try unstarted.validateImport(claim))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Session.json")
    let original = Data("invalid session".utf8)
    try original.write(to: file)
    let blocked = SessionCoordinator(
      loadSession: { try SessionStore(directory: directory).load() },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    await blocked.restore { _ in [:] }
    XCTAssertFalse(blocked.startupErrors.isEmpty)
    XCTAssertThrowsError(try blocked.claimImport(entry))
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testResolutionTransfersRecoveryOwnershipWithoutDeletingDisk() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "synthetic 😀\r\n", encoding: .utf8, hasBOM: false)
    let store = try RecoveryStore(directory: directory)
    try store.save(snapshot)
    var removals = 0
    let coordinator = SessionCoordinator(
      loadSession: { nil },
      claimRecovery: { .init(snapshots: try store.loadReport().snapshots, quarantinedCount: 0) },
      removeRecovery: { _ in removals += 1 })
    await coordinator.restore { window in
      Dictionary(
        uniqueKeysWithValues: window.tabs.map { ($0.metadata.id, "Synthetic import refusal") })
    }
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    XCTAssertTrue(entry.hasRecovery)
    let claim = try coordinator.claimImport(entry)
    try coordinator.resolveImport(claim)
    do {
      _ = try await coordinator.retry(entry)
      XCTFail("Resolved recovery is no longer an unresolved source")
    } catch {}
    try await coordinator.remove(entry)
    XCTAssertEqual(removals, 0, "Stale unresolved removal no longer owns this imported recovery ID")
    XCTAssertEqual(try store.loadReport().snapshots, [snapshot])
  }

  func testPendingCleanupRefusesNewAndCapturedClaims() async throws {
    let snapshot = RecoverySnapshot(id: UUID(), text: "synthetic", encoding: .utf8, hasBOM: false)
    var release: CheckedContinuation<Void, Never>?
    let coordinator = SessionCoordinator(
      loadSession: { nil }, claimRecovery: { .init(snapshots: [snapshot], quarantinedCount: 0) },
      removeRecovery: { _ in await withCheckedContinuation { release = $0 } })
    await coordinator.restore { window in
      Dictionary(
        uniqueKeysWithValues: window.tabs.map { ($0.metadata.id, "Synthetic import refusal") })
    }
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    let claim = try coordinator.claimImport(entry)
    let recoveryClaim = try coordinator.claimRecoveryImport(entry)
    let task = Task { try await coordinator.remove(entry) }
    for _ in 0..<1000 {
      if release != nil { break }
      await Task.yield()
    }
    let pending = try XCTUnwrap(release)
    do {
      _ = try coordinator.claimImport(entry)
      XCTFail("Pending cleanup must explain why import is unavailable")
    } catch SessionImportError.cleanupPending {}
    XCTAssertThrowsError(try coordinator.validateImport(claim))
    XCTAssertThrowsError(try coordinator.claimRecoveryImport(entry))
    XCTAssertThrowsError(try coordinator.validateRecoveryImport(recoveryClaim))
    pending.resume()
    try await task.value
    XCTAssertThrowsError(try coordinator.resolveImport(claim))
  }
  func testRecoveryOnlyClaimPreservesCorruptSessionAndExactSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionFile = directory.appendingPathComponent("Session.json")
    let corrupt = Data("synthetic corrupt session".utf8)
    try corrupt.write(to: sessionFile)
    let store = try RecoveryStore(directory: directory.appendingPathComponent("recovery"))
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "👩🏽‍💻e\u{301}\r\n", encoding: .utf16BE, hasBOM: true)
    try store.save(snapshot)
    var deletes = 0
    let coordinator = SessionCoordinator(
      loadSession: { try SessionStore(directory: directory).load() },
      claimRecovery: { .init(snapshots: try store.loadReport().snapshots, quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Preservation must block publication") },
      removeRecovery: { _ in deletes += 1 })
    await coordinator.restore { window in
      Dictionary(uniqueKeysWithValues: window.tabs.map { ($0.metadata.id, "Pending import") })
    }
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    XCTAssertThrowsError(try coordinator.claimImport(entry))
    let claim = try coordinator.claimRecoveryImport(entry)
    XCTAssertEqual(claim.snapshot, snapshot)
    XCTAssertEqual(Array(claim.snapshot.text.utf16), Array(snapshot.text.utf16))
    XCTAssertEqual(claim.documentID, entry.metadata.id)
    XCTAssertEqual(claim.windowID, entry.windowID)
    try coordinator.validateRecoveryImport(claim)
    let capacity = try coordinator.preflightImport(claim, liveWindows: [:])
    XCTAssertEqual(capacity.documentIDs, [snapshot.id])
    XCTAssertEqual(capacity.windowIDs, [entry.windowID])
    var callbacks = 0
    coordinator.onSessionChange = {
      callbacks += 1
      do {
        try coordinator.validateRecoveryImport(claim)
        XCTFail("Resolved recovery claim must be stale before callbacks")
      } catch {}
    }
    try coordinator.resolveRecoveryImport(claim)
    XCTAssertEqual(callbacks, 1)
    XCTAssertThrowsError(try coordinator.resolveRecoveryImport(claim))
    XCTAssertThrowsError(try coordinator.captureSession(windows: []))
    do {
      try await coordinator.persist(windows: [])
      XCTFail("Must not publish")
    } catch {}
    try await coordinator.remove(entry)
    XCTAssertEqual(deletes, 0)
    XCTAssertEqual(try store.loadReport().snapshots, [snapshot])
    XCTAssertEqual(try Data(contentsOf: sessionFile), corrupt)
  }

  func testRecoveryOnlyClaimRefusesMissingForeignAndStaleSources() async throws {
    let missing = await fixture()
    XCTAssertThrowsError(try missing.claimRecoveryImport(XCTUnwrap(missing.unresolved.first)))
    let snapshots = (0..<2).map { _ in
      RecoverySnapshot(id: UUID(), text: "synthetic", encoding: .utf8, hasBOM: false)
    }
    let coordinator = SessionCoordinator(
      loadSession: { nil },
      claimRecovery: { .init(snapshots: snapshots, quarantinedCount: 0) })
    await coordinator.restore { window in
      Dictionary(uniqueKeysWithValues: window.tabs.map { ($0.metadata.id, "Pending import") })
    }
    let entries = coordinator.unresolved
    let claim = try coordinator.claimRecoveryImport(entries[0])
    XCTAssertThrowsError(try missing.validateRecoveryImport(claim))
    XCTAssertThrowsError(try missing.resolveRecoveryImport(claim))
    let unstarted = SessionCoordinator()
    XCTAssertThrowsError(try unstarted.claimRecoveryImport(entries[0]))
    coordinator.resolved(entries[1])
    XCTAssertThrowsError(try coordinator.validateRecoveryImport(claim))
    let fresh = try coordinator.claimRecoveryImport(entries[0])
    try coordinator.resolveRecoveryImport(fresh)
    XCTAssertTrue(coordinator.unresolved.isEmpty)
  }

  func testReservedImportMayReplaceWithoutGrowingOverCapacityUnion() async throws {
    let tabs = (0..<129).map { _ in SessionTab() }
    let coordinator = await fixture(tabs: tabs)
    XCTAssertEqual(coordinator.unresolved.count, 129)
    for restored in Array(coordinator.unresolved.prefix(127)) {
      try coordinator.resolveImport(coordinator.claimImport(restored))
    }
    let entry = coordinator.unresolved[0]
    let claim = try coordinator.claimImport(entry)
    let live = Set(tabs.prefix(127).map(\.id))
    let capacity = try coordinator.preflightImport(claim, liveWindows: [entry.windowID: live])
    XCTAssertEqual(capacity.documentIDs, Set(tabs.map(\.id)))
    XCTAssertEqual(capacity.windowIDs, [entry.windowID])
    XCTAssertEqual(capacity.sessionRevision, coordinator.capacityRevision)
    XCTAssertEqual(coordinator.unresolved.count, 2, "Admission never consumes a reservation")
    try coordinator.resolveImport(claim)
    let last = try coordinator.claimImport(coordinator.unresolved[0])
    XCTAssertThrowsError(
      try coordinator.preflightImport(
        last,
        liveWindows: [entry.windowID: Set(tabs.prefix(128).map(\.id))]))
  }

  func testImportPreflightRefusesDuplicateLiveOwnershipAndWindowCollision() async throws {
    let coordinator = await fixture()
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    let claim = try coordinator.claimImport(entry)
    XCTAssertThrowsError(
      try coordinator.preflightImport(
        claim,
        liveWindows: [entry.windowID: [entry.metadata.id]]))
    XCTAssertThrowsError(
      try coordinator.preflightImport(
        claim,
        liveWindows: [entry.metadata.id: []]))
    let other = UUID()
    XCTAssertThrowsError(
      try coordinator.preflightImport(
        claim,
        liveWindows: [UUID(): [other], UUID(): [other]]))
    let windows = Dictionary(uniqueKeysWithValues: (0..<32).map { _ in (UUID(), Set<UUID>()) })
    XCTAssertThrowsError(try coordinator.preflightImport(claim, liveWindows: windows))
    try coordinator.validateImport(claim)
  }

  func testRenewalRetainsExactProvenanceAfterOtherMembershipChange() async throws {
    let coordinator = await fixture(tabs: [SessionTab(), SessionTab()])
    let entries = coordinator.unresolved
    let original = try coordinator.claimImport(entries[0])
    coordinator.resolved(entries[1])
    XCTAssertThrowsError(try coordinator.validateImport(original))
    let renewed = try coordinator.renewImportClaim(original)
    XCTAssertEqual(renewed.documentID, original.documentID)
    XCTAssertEqual(renewed.windowID, original.windowID)
    let foreign = await fixture()
    XCTAssertThrowsError(try foreign.renewImportClaim(original))
    try coordinator.resolveImport(renewed)
    XCTAssertThrowsError(try coordinator.renewImportClaim(original))
    XCTAssertThrowsError(try coordinator.renewImportClaim(renewed))
  }

  func testRecoveryRenewalKeepsPreservationFenceAndExactRetainedSnapshot() async throws {
    let snapshots = (0..<2).map { _ in
      RecoverySnapshot(id: UUID(), text: "synthetic 👩🏽‍💻", encoding: .utf16LE, hasBOM: true)
    }
    let coordinator = SessionCoordinator(
      loadSession: { throw Failure.synthetic },
      claimRecovery: { .init(snapshots: snapshots, quarantinedCount: 0) })
    await coordinator.restore { window in
      Dictionary(uniqueKeysWithValues: window.tabs.map { ($0.metadata.id, "Pending") })
    }
    let entries = coordinator.unresolved
    let claim = try coordinator.claimRecoveryImport(entries[0])
    coordinator.resolved(entries[1])
    XCTAssertThrowsError(try coordinator.validateRecoveryImport(claim))
    let renewed = try coordinator.renewImportClaim(claim)
    XCTAssertEqual(renewed.snapshot, claim.snapshot)
    XCTAssertEqual(renewed.windowID, claim.windowID)
    XCTAssertThrowsError(try coordinator.claimImport(entries[0]))
    XCTAssertThrowsError(try coordinator.captureSession(windows: []))
    let foreign = await fixture()
    XCTAssertThrowsError(try foreign.renewImportClaim(claim))
    try coordinator.resolveRecoveryImport(renewed)
    XCTAssertThrowsError(try coordinator.renewImportClaim(claim))
  }

}
