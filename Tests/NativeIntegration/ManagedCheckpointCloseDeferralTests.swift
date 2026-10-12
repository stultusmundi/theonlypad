import Foundation
import PadCore
import XCTest

@testable import CheckpointCloseDeferral

private enum PublisherDeferralFailure: Error { case readiness, unexpectedClosePath }

@MainActor private final class DeferralConfirmationGate {
  var entered = false
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func cancel() {
    released = true
    let value = continuation
    continuation = nil
    value?.resume()
  }
}

@MainActor private final class DeferralManagedHandle: WorkspaceDocumentHandle {
  let id = UUID()
  var ownershipGeneration = UUID()
  let mutation = UUID()
  let text = "synthetic 😀 checkpoint"
  var authority: RecoveryWriteAuthority?
  var revision: UInt64 = 0
  var workspaceKind: WorkspaceDocumentKind { .editable }
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentCloseState {
    .init(
      kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: mutation, operationID: nil, isDirty: true,
      hasPendingPublication: false, hasPendingTextEdits: false, isComposing: false,
      canRetainCleanHistory: false)
  }
  var adoption: DocumentAdoptionState {
    .init(
      documentID: id, ownershipGeneration: ownershipGeneration,
      authority: authority, highestIssuedRevision: revision)
  }
}

@MainActor private final class ManagedCloseDeferralFixture {
  let directory: URL
  let store: SessionStore
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  let session: SessionCoordinator
  let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let handle = DeferralManagedHandle()
  let confirmation = DeferralConfirmationGate()
  var closeChecks = 0
  var captureCalls = 0
  var pauseAcquisitions = 0
  var projectCalls = 0

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = SessionStore(directory: directory.appendingPathComponent("session"))
    let store = store
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    registry = ApplicationDocuments(
      closeServices: .init { ($0 as! DeferralManagedHandle).state },
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { ($0 as! DeferralManagedHandle).adoption }))
    session = SessionCoordinator(
      loadSession: { nil },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) },
      saveSession: { try store.save($0) }, removeRecovery: { _ in },
      readFile: { _, _ in throw PublisherDeferralFailure.unexpectedClosePath })
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
  }

  lazy var publisher: ApplicationSessionCheckpoints = ApplicationSessionCheckpoints(
    session: session, recovery: recovery,
    managed: .init(
      registry: registry,
      requireIntakeSettled: {},
      requireCloseSettled: {
        self.closeChecks += 1
        try self.closing.requireSettledForFinalCheckpoint()
      },
      validateProjection: { windows in
        guard windows.count == 1, windows[0].id == self.assignment.windowID,
          windows[0].groups.count == 1,
          windows[0].groups[0].documentIDs == [self.handle.id],
          windows[0].groups[0].selectedDocumentID == self.handle.id
        else {
          throw ApplicationCheckpointError.invalidProjection
        }
      },
      captureWindow: { window in
        self.captureCalls += 1
        let h = self.handle
        guard let authority = h.authority, h.revision < UInt64.max else {
          throw PublisherDeferralFailure.unexpectedClosePath
        }
        h.revision += 1
        return .init(
          window: .init(
            id: window.id,
            tabs: [SessionTab(id: h.id, encoding: .utf8)], selectedTabID: h.id),
          liveTabIDs: [h.id],
          recovery: [
            .init(
              id: h.id, revision: h.revision,
              snapshot: .init(id: h.id, text: h.text, encoding: .utf8, hasBOM: false),
              authority: authority)
          ])
      }, preflightResources: { _ in }, renderStatus: { _, _ in }),
    delay: { _ in await Task.yield() })

  lazy var closing: ApplicationDocumentClosing = ApplicationDocumentClosing(
    registry: registry, recovery: recovery,
    publication: .init(
      requireApplicationAdmission: {},
      acquirePause: {
        self.pauseAcquisitions += 1
        return try self.publisher.acquirePause()
      },
      drainPause: { try await self.publisher.drainPause($0) },
      releasePause: { try self.publisher.releasePause($0) },
      requestCheckpoint: { self.publisher.requestCheckpoint() }),
    native: .init(
      confirm: { _, _ in
        await self.confirmation.wait()
        return nil
      },
      applyAdmission: { _ in throw PublisherDeferralFailure.unexpectedClosePath },
      drainLegacyWrites: { _ in throw PublisherDeferralFailure.unexpectedClosePath },
      readState: { ($0 as! DeferralManagedHandle).state },
      capture: { _ in throw PublisherDeferralFailure.unexpectedClosePath },
      installRepair: { _, _, _, _ in throw PublisherDeferralFailure.unexpectedClosePath },
      projectRegistry: { self.projectCalls += 1 }))

  func prepare() async throws {
    await session.restore { _ in [:] }
    let lease = try registry.registerPending(
      handle, requestID: UUID(),
      expectedRevision: registry.workspaceRevision, metadata: .init(pinned: false),
      in: assignment, at: 0, select: true)
    let receipt = try await recovery.adoptManagedDocument(id: handle.id)
    handle.authority = receipt.authority
    try registry.activateAdoption(lease, receipt: receipt)
    let activation = try publisher.beginManagedActivation()
    try await publisher.drainManagedActivation(activation)
    try publisher.finishManagedActivation(activation)
  }
}

@MainActor final class ManagedCheckpointCloseDeferralTests: XCTestCase {
  private func until(_ predicate: () -> Bool) async throws {
    for _ in 0..<10_000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("Real publisher/close boundary must be reached before deferral credit")
    throw PublisherDeferralFailure.readiness
  }

  func testRealConfirmingCloseDefersManagedCheckpointAndSettlementPublishes() async throws {
    let f = try ManagedCloseDeferralFixture()
    defer {
      f.confirmation.cancel()
      try? FileManager.default.removeItem(at: f.directory)
    }
    try await f.prepare()
    try await until {
      f.publisher.lastAcknowledgedGeneration > 0 && !f.publisher.hasPendingChanges
    }
    XCTAssertNil(f.publisher.lastError)
    let initialGeneration = f.publisher.lastAcknowledgedGeneration
    let initialCaptures = f.captureCalls
    let initialSession = try XCTUnwrap(f.store.load())
    XCTAssertEqual(initialSession.windows.flatMap { $0.tabs.map(\.id) }, [f.handle.id])
    let closeID = try f.closing.start(
      documentIDs: [f.handle.id], sourceWindowID: f.assignment.windowID)
    try await until { f.confirmation.entered }
    XCTAssertEqual(f.closing.status?.stage, .confirming)
    XCTAssertTrue(f.closing.hasUnsettledTransactions)
    XCTAssertEqual(f.pauseAcquisitions, 0, "Actual confirmation precedes pause acquisition")
    XCTAssertEqual(f.registry.closeStatus(documentID: f.handle.id), .open)
    XCTAssertThrowsError(try f.closing.requireSettledForFinalCheckpoint()) { error in
      XCTAssertEqual(error as? DocumentClosingError, .pendingRecovery)
    }
    let checks = f.closeChecks
    f.publisher.requestCheckpoint()
    try await until { f.closeChecks > checks }
    for _ in 0..<32 { await Task.yield() }
    XCTAssertNil(
      f.publisher.lastError, "Real pendingRecovery during confirmation is a managed deferral")
    XCTAssertTrue(f.publisher.hasPendingChanges)
    XCTAssertEqual(f.publisher.lastAcknowledgedGeneration, initialGeneration)
    XCTAssertEqual(f.captureCalls, initialCaptures)
    XCTAssertEqual(try f.store.load(), initialSession)
    let consumedChecks = f.closeChecks
    for _ in 0..<32 { await Task.yield() }
    XCTAssertEqual(f.closeChecks, consumedChecks, "An idle deferral must not spin")
    f.confirmation.cancel()
    let result = try await f.closing.wait(for: closeID)
    guard case .cancelled(let ids) = result else {
      XCTFail("Actual nil confirmation must settle through the original cancellation path")
      throw PublisherDeferralFailure.unexpectedClosePath
    }
    XCTAssertTrue(ids.isEmpty)
    try f.closing.requireSettledForFinalCheckpoint()
    XCTAssertEqual(f.closing.status?.stage, .settled)
    XCTAssertFalse(f.closing.hasUnsettledTransactions)
    XCTAssertEqual(f.pauseAcquisitions, 0)
    XCTAssertEqual(f.projectCalls, 0)
    XCTAssertTrue(f.registry.handle(id: f.handle.id) === f.handle)
    try await until {
      f.publisher.lastAcknowledgedGeneration > initialGeneration && !f.publisher.hasPendingChanges
    }
    XCTAssertNil(f.publisher.lastError)
    XCTAssertEqual(f.captureCalls, initialCaptures + 1)
    XCTAssertEqual(
      try XCTUnwrap(f.store.load()).windows.flatMap { $0.tabs.map(\.id) }, [f.handle.id])
    await f.publisher.pauseAndDrain()
    let restored = try await RecoveryCoordinator(
      directory: f.directory.appendingPathComponent("recovery")
    ).claimStartup()
    XCTAssertEqual(restored.snapshots.map(\.id), [f.handle.id])
    XCTAssertEqual(restored.snapshots[0].text.utf16.map { $0 }, f.handle.text.utf16.map { $0 })
  }
}
