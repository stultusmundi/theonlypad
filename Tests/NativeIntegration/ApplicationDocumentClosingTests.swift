import Foundation
import PadCore
import XCTest

@testable import ClosingOwner

private enum ClosingFixtureError: Error { case injected }
private final class ClosingFault: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false
  private var calls = 0
  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }
  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    let value = armed
    armed = false
    return value
  }
}
@MainActor private final class ClosingHandle: WorkspaceDocumentHandle {
  let id = UUID()
  var ownershipGeneration = UUID()
  var workspaceKind: WorkspaceDocumentKind { .editable }
  var generation = UUID()
  var text = "synthetic 👩🏽‍💻\r\nsecond\r"
  var authority: RecoveryWriteAuthority!
  var highest: UInt64 = 0
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentCloseState {
    .init(
      kind: .editable, ownershipGeneration: ownershipGeneration, mutationGeneration: generation,
      operationID: nil, isDirty: true, hasPendingPublication: false, hasPendingTextEdits: false,
      isComposing: false, canRetainCleanHistory: false)
  }
  var snapshot: RecoverySnapshot { .init(id: id, text: text, encoding: .utf16BE, hasBOM: true) }
}
@MainActor private final class ClosingGate {
  var entered = false
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func open() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
@MainActor private final class ClosingFixture {
  let directory: URL
  let registry = ApplicationDocuments(closeServices: .init { ($0 as! ClosingHandle).state })
  let recovery: RecoveryCoordinator
  let scheduler = SessionCheckpointCoordinator(
    capture: { _ in throw ClosingFixtureError.injected },
    commit: { _ in throw ClosingFixtureError.injected })
  let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let fault = ClosingFault()
  var quit = false
  var confirmations = 0
  var acquired = 0
  var drained = 0
  var released = 0
  var checkpoints = 0
  var installs = 0
  var installationContexts: [DocumentClosingRepairContext] = []
  var installationLeases: [RecoveryWriteAuthority] = []
  var projects = 0
  var rejectInstall = false
  var rejectProjection = false
  var confirmationGate: ClosingGate?
  var legacyGate: ClosingGate?
  var cancelConfirmation = false
  var afterConfirmation: (() -> Void)?
  var afterInstall: ((ClosingHandle) -> Void)?
  init(limits: RecoveryLimits = .init()) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fault = fault
    recovery = RecoveryCoordinator(
      directory: directory, limits: limits,
      removeRecovery: { store, id in
        try store.removeChecked(id: id, fault: fault.take() ? .afterRename : nil)
      })
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
  }
  func add(persist: Bool = true, text: String? = nil) async throws -> ClosingHandle {
    let handle = ClosingHandle()
    if let text { handle.text = text }
    let receipt = try await recovery.adoptManagedDocument(id: handle.id)
    handle.authority = receipt.authority
    try registry.registerDocument(
      handle, metadata: .init(pinned: false), in: assignment,
      at: registry.window(id: assignment.windowID)!.groups[0].documentIDs.count, select: true)
    if persist {
      try await recovery.persistAuthorized(
        .init(authority: receipt.authority, revision: 1, snapshot: handle.snapshot))
      handle.highest = 1
    }
    return handle
  }
  func owner() -> ApplicationDocumentClosing {
    ApplicationDocumentClosing(
      registry: registry, recovery: recovery,
      publication: .init(
        requireApplicationAdmission: { if self.quit { throw ClosingFixtureError.injected } },
        acquirePause: {
          self.acquired += 1
          return try self.scheduler.acquirePause()
        },
        drainPause: {
          try await self.scheduler.drainPause($0)
          self.drained += 1
        },
        releasePause: {
          try self.scheduler.releasePause($0)
          self.released += 1
        },
        requestCheckpoint: { self.checkpoints += 1 }),
      native: .init(
        confirm: { _, _ in
          self.confirmations += 1
          await self.confirmationGate?.wait()
          self.afterConfirmation?()
          return self.cancelConfirmation ? nil : .discardWithoutHistory
        }, applyAdmission: { _ in }, drainLegacyWrites: { _ in await self.legacyGate?.wait() },
        readState: { ($0 as! ClosingHandle).state },
        capture: {
          let handle = $0 as! ClosingHandle
          return .init(
            state: handle.state, snapshot: handle.snapshot, authority: handle.authority,
            highestIssuedRevision: handle.highest)
        },
        installRepair: { handle, attempt, receipt, context in
          self.installationContexts.append(context)
          self.installationLeases.append(receipt.lease.authority)
          self.installs += 1
          if self.rejectInstall {
            self.rejectInstall = false
            throw ClosingFixtureError.injected
          }
          let handle = handle as! ClosingHandle
          guard handle.state == attempt.state, context.state == attempt.state,
            handle.authority == context.modelAuthority,
            handle.highest == context.highestIssuedRevision
          else { throw DocumentClosingError.staleState }
          handle.authority = receipt.authority
          handle.highest = receipt.nextRevision - 1
          self.afterInstall?(handle)
        },
        projectRegistry: {
          self.projects += 1
          if self.rejectProjection {
            self.rejectProjection = false
            throw ClosingFixtureError.injected
          }
        }))
  }
}
@MainActor final class ApplicationDocumentClosingTests: XCTestCase {
  private func fixture(limits: RecoveryLimits = .init()) throws -> ClosingFixture {
    let fixture = try ClosingFixture(limits: limits)
    let directory = fixture.directory
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return fixture
  }
  private func entered(_ gate: ClosingGate) async {
    for _ in 0..<1000 {
      if gate.entered { return }
      await Task.yield()
    }
    XCTFail("Owned task did not reach gate")
  }
  func testSuccessfulCloseUsesRealRegistryActorAndOnePause() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    if case .completed(let ids) = try await owner.wait(for: id) {
      XCTAssertEqual(ids, [handle.id])
    } else {
      XCTFail()
    }
    XCTAssertNil(fixture.registry.handle(id: handle.id))
    XCTAssertTrue(try RecoveryStore(directory: fixture.directory).loadAll().isEmpty)
    XCTAssertEqual(fixture.acquired, 1)
    XCTAssertEqual(fixture.drained, 1)
    XCTAssertEqual(fixture.released, 1)
    XCTAssertEqual(fixture.checkpoints, 1)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    try owner.requireSettledForFinalCheckpoint()
  }
  func testAdmittingCallbackCannotCancelDespiteTicketNotReturned() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    var id: DocumentClosingID!
    var witnessed = false
    fixture.registry.onChange = { _ in
      if case .closing = fixture.registry.closeStatus(documentID: handle.id) {
        witnessed = true
        XCTAssertEqual(owner.status?.stage, .admitting)
        do {
          try owner.cancelBeforeAdmission(id)
          XCTFail("admitting cancellation")
        } catch {}
        do {
          try owner.retry(id)
          XCTFail("admitting retry")
        } catch {}
        do {
          _ = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
          XCTFail("reentrant start")
        } catch {}
        do {
          try owner.requireCaptureAdmission()
          XCTFail("capture during admission")
        } catch {}
        XCTAssertEqual(fixture.acquired, 1)
      }
    }
    id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(witnessed)
  }
  func testCancelledConfirmationHasNoActorOrRegistryEffects() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let gate = ClosingGate()
    fixture.confirmationGate = gate
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    await entered(gate)
    try owner.cancelBeforeAdmission(id)
    gate.open()
    if case .cancelled = try await owner.wait(for: id) {} else { XCTFail() }
    XCTAssertTrue(fixture.registry.handle(id: handle.id) === handle)
    XCTAssertEqual(fixture.acquired, 0)
    XCTAssertEqual(try RecoveryStore(directory: fixture.directory).loadAll(), [handle.snapshot])
  }
  func testWaiterCancellationAndEndpointLossDoNotAbandonAdmittedClose() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let gate = ClosingGate()
    fixture.legacyGate = gate
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    let waiter = Task { try await owner.wait(for: id) }
    await entered(gate)
    waiter.cancel()
    owner.endpointDidClose(windowID: fixture.assignment.windowID)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertThrowsError(try owner.cancelBeforeAdmission(id))
    gate.open()
    _ = try await waiter.value
    XCTAssertNil(fixture.registry.handle(id: handle.id))
    XCTAssertEqual(fixture.released, 1)
  }
  func testDeletionFailureRetainsPauseAndFreshRepairInstallsBeforeOpen() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let old = handle.authority
    fixture.fault.arm()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.released, 0)
    XCTAssertThrowsError(try owner.requireSettledForFinalCheckpoint())
    var observed = false
    fixture.registry.onChange = { _ in
      if fixture.registry.allows(.edit, documentID: handle.id) {
        observed = true
        XCTAssertNotEqual(handle.authority, old)
      }
    }
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(observed)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertEqual(try RecoveryStore(directory: fixture.directory).loadAll(), [handle.snapshot])
    XCTAssertEqual(fixture.released, 1)
  }
  func testRejectedRepairInstallationReleasesFreshEpochAgainOnRetry() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let originalModelAuthority = handle.authority!
    fixture.fault.arm()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    fixture.rejectInstall = true
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.released, 0)
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.installs, 2)
    XCTAssertEqual(
      fixture.installationContexts.map(\.modelAuthority),
      [originalModelAuthority, originalModelAuthority])
    XCTAssertNotEqual(
      fixture.installationLeases[1], originalModelAuthority,
      "The retry actor lease is fresh while the model still legitimately retains its earlier epoch")
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertTrue(fixture.registry.allows(.edit, documentID: handle.id))
  }
  func testRepairExpectationRetainsFenceCapturedBeforeActorWait() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let originalAuthority = handle.authority!
    let originalFence = handle.highest
    fixture.fault.arm()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    var changed = false
    owner.onChange = {
      if owner.status?.stage == .repairing, !changed {
        changed = true
        // Revision issuance does not alter semantic close state; an illicit producer must still be detected.
        handle.highest += 1
      }
    }
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(changed)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.released, 0)
    XCTAssertEqual(fixture.installationContexts.last?.highestIssuedRevision, originalFence)
    XCTAssertEqual(handle.authority, originalAuthority)
    XCTAssertEqual(handle.highest, originalFence + 1)
    owner.onChange = nil
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.installationContexts.last?.highestIssuedRevision, originalFence + 1)
  }
  func testAcceptedRepairProjectionFailureRetriesProjectionOnly() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    fixture.fault.arm()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    fixture.rejectProjection = true
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.installs, 1)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    let authority = handle.authority
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.installs, 1)
    XCTAssertEqual(handle.authority, authority)
    XCTAssertFalse(owner.hasUnsettledTransactions)
  }
  func testCapacityRefusalBeforeRevocationReopensOriginalAuthority() async throws {
    let fixture = try fixture(limits: .init(maximumSnapshotUTF16: 10, maximumRestoredUTF16: 10))
    let other = RecoverySnapshot(id: UUID(), text: "123456789", encoding: .utf8, hasBOM: false)
    try await fixture.recovery.persist(other, revision: 1)
    let handle = try await fixture.add(persist: false, text: "12")
    let owner = fixture.owner()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.released, 1)
    XCTAssertTrue(fixture.registry.allows(.edit, documentID: handle.id))
    try await fixture.recovery.clear(id: other.id, revision: 2)
    try await fixture.recovery.persistAuthorized(
      .init(authority: handle.authority, revision: 1, snapshot: handle.snapshot))
  }
  func testSameGroupBatchUsesFreshRequestsAfterEachSettlement() async throws {
    let fixture = try fixture()
    let first = try await fixture.add()
    let second = try await fixture.add()
    let owner = fixture.owner()
    let id = try owner.start(
      documentIDs: [first.id, second.id], sourceWindowID: fixture.assignment.windowID)
    if case .completed(let ids) = try await owner.wait(for: id) {
      XCTAssertEqual(ids, [first.id, second.id])
    } else {
      XCTFail()
    }
    XCTAssertEqual(fixture.confirmations, 2)
    XCTAssertEqual(fixture.acquired, 1)
    XCTAssertEqual(fixture.released, 1)
  }
  func testAdmissionRefusalDrainsUnusedPauseAndKeepsAuthority() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    fixture.afterConfirmation = { handle.generation = UUID() }
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.acquired, 1)
    XCTAssertEqual(fixture.drained, 1)
    XCTAssertEqual(fixture.released, 1)
    XCTAssertEqual(fixture.fault.count(), 0)
    XCTAssertTrue(fixture.registry.allows(.edit, documentID: handle.id))
    XCTAssertFalse(owner.hasUnsettledTransactions)
    try await fixture.recovery.persistAuthorized(
      .init(authority: handle.authority, revision: 2, snapshot: handle.snapshot))
  }
  func testClosedModelRetainedThroughProjectionFailureWithoutSecondDelete() async throws {
    let fixture = try fixture()
    var handle: ClosingHandle? = try await fixture.add()
    let owner = fixture.owner()
    #if compiler(>=6.3)
      weak let observed = handle
    #else
      weak var observed = handle
    #endif
    let documentID = handle!.id
    fixture.rejectProjection = true
    let id = try owner.start(documentIDs: [documentID], sourceWindowID: fixture.assignment.windowID)
    handle = nil
    _ = try await owner.wait(for: id)
    XCTAssertNil(fixture.registry.handle(id: documentID))
    XCTAssertNotNil(observed, "process transaction must retain model after registry removal")
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.fault.count(), 1)
    owner.endpointDidClose(windowID: fixture.assignment.windowID)
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.fault.count(), 1)
    XCTAssertEqual(fixture.released, 1)
    XCTAssertFalse(owner.hasUnsettledTransactions)
  }
  func testMutationAfterDeletionAdmissionRetainsAndRepairsLatestText() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    var changed = false
    owner.onChange = {
      if owner.status?.stage == .deleting, !changed {
        changed = true
        handle.text = "new bypass text 👩🏽‍💻\r\n"
        handle.generation = UUID()
      }
    }
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertTrue(fixture.registry.handle(id: handle.id) === handle)
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(try RecoveryStore(directory: fixture.directory).loadAll(), [handle.snapshot])
  }
  func testMutationAfterRepairInstallReleasesNewEpochAndRetriesLatestState() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    fixture.fault.arm()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    var changed = false
    fixture.afterInstall = { handle in
      if !changed {
        changed = true
        handle.text = "after publication"
        handle.generation = UUID()
      }
    }
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.released, 0)
    try owner.retry(id)
    _ = try await owner.wait(for: id)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertEqual(try RecoveryStore(directory: fixture.directory).loadAll(), [handle.snapshot])
  }
  func testOtherPauseOwnerIsNotReleased() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    let external = try fixture.scheduler.acquirePause()
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.scheduler.phase, .paused)
    try await fixture.scheduler.drainPause(external)
    try fixture.scheduler.releasePause(external)
    XCTAssertEqual(fixture.scheduler.phase, .stopped)
  }
  func testSettledNotificationCanStartNewBatchWithoutOldCleanup() async throws {
    let fixture = try fixture()
    let first = try await fixture.add()
    let second = try await fixture.add()
    let owner = fixture.owner()
    var next: DocumentClosingID?
    owner.onChange = {
      if owner.status?.stage == .settled, next == nil {
        next = try! owner.start(
          documentIDs: [second.id], sourceWindowID: fixture.assignment.windowID)
      }
    }
    let initial = try owner.start(
      documentIDs: [first.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: initial)
    let nextID = try XCTUnwrap(next)
    _ = try await owner.wait(for: nextID)
    XCTAssertNil(fixture.registry.handle(id: second.id))
    XCTAssertEqual(fixture.released, 2)
  }
  func testCancelInConfirmingNotificationDoesNotOpenNewConfirmation() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    owner.onChange = {
      if let status = owner.status, status.stage == .confirming {
        try! owner.cancelBeforeAdmission(status.id)
      }
    }
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    XCTAssertEqual(fixture.confirmations, 0)
    XCTAssertEqual(fixture.acquired, 0)
    XCTAssertTrue(fixture.registry.handle(id: handle.id) === handle)
  }
  func testFailedNotificationMayLaunchRetryWithoutOldTaskClearingIt() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    fixture.fault.arm()
    var retried = false
    owner.onChange = {
      if let status = owner.status, status.stage == .failed, !retried {
        retried = true
        try! owner.retry(status.id)
      }
    }
    let id = try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID)
    _ = try await owner.wait(for: id)
    _ = try await owner.wait(for: id)
    XCTAssertTrue(retried)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.installs, 1)
    XCTAssertEqual(fixture.released, 1)
  }
  func testRunningPairedPublisherDrainsHeldPreparationAndPersistsPostCloseState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let recoveryDirectory = directory.appendingPathComponent("Recovery")
    let sessionDirectory = directory.appendingPathComponent("Session")
    let sessionStore = SessionStore(directory: sessionDirectory)
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try sessionStore.save($0) },
      readCheckpointSession: { try sessionStore.load() })
    let registry = ApplicationDocuments(closeServices: .init { ($0 as! ClosingHandle).state })
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    let first = ClosingHandle()
    let remaining = ClosingHandle()
    remaining.text = "remaining \u{0}👩🏽‍💻e\u{301}\r\nsecond\rthird\n"
    for handle in [first, remaining] {
      let adopted = try await recovery.adoptManagedDocument(id: handle.id)
      handle.authority = adopted.authority
      try registry.registerDocument(
        handle, metadata: .init(pinned: false), in: assignment,
        at: registry.window(id: assignment.windowID)!.groups[0].documentIDs.count, select: true)
    }
    let gate = ClosingGate()
    var holdNextPreparation = false
    var captureIDs: [Set<UUID>] = []
    var receipts: [SessionCheckpointReceipt] = []
    var owner: ApplicationDocumentClosing!
    let scheduler = SessionCheckpointCoordinator(
      capture: { generation in
        try owner.requireCaptureAdmission()
        let windows = try registry.captureWindows()
        var items: [RecoveryCheckpointItem] = []
        let sessionWindows = try windows.map { window -> SessionWindow in
          let ids = window.groups.flatMap(\.documentIDs)
          let tabs = try ids.map { id -> SessionTab in
            guard let handle = registry.handle(id: id) as? ClosingHandle,
              handle.highest < UInt64.max
            else {
              throw ClosingFixtureError.injected
            }
            handle.highest += 1
            items.append(
              .init(
                id: id, revision: handle.highest, snapshot: handle.snapshot,
                authority: handle.authority))
            return SessionTab(id: id, encoding: handle.snapshot.encoding)
          }
          return SessionWindow(
            id: window.id, tabs: tabs,
            selectedTabID: window.groups.first(where: { $0.id == window.focusedGroupID })?
              .selectedDocumentID)
        }
        let live = Set(items.map(\.id))
        captureIDs.append(live)
        return SessionCheckpointCapture(
          generation: generation, liveTabIDs: live, recovery: items,
          session: EditorSession(windows: sessionWindows))
      },
      commit: { capture in
        let receipt = try await recovery.commitAuthorizedSessionCheckpoint(capture)
        receipts.append(receipt)
        return receipt
      },
      prepareCapture: {
        if holdNextPreparation {
          holdNextPreparation = false
          await gate.wait()
        }
        try owner.requireCaptureAdmission()
      }, delay: { _ in await Task.yield() })
    addTeardownBlock {
      await scheduler.pauseAndDrain()
      try? FileManager.default.removeItem(at: directory)
    }
    defer { gate.open() }
    owner = ApplicationDocumentClosing(
      registry: registry, recovery: recovery,
      publication: .init(
        requireApplicationAdmission: {}, acquirePause: { try scheduler.acquirePause() },
        drainPause: { try await scheduler.drainPause($0) },
        releasePause: { try scheduler.releasePause($0) },
        requestCheckpoint: { scheduler.requestCheckpoint() }),
      native: .init(
        confirm: { _, _ in .discardWithoutHistory }, applyAdmission: { _ in },
        drainLegacyWrites: { _ in }, readState: { ($0 as! ClosingHandle).state },
        capture: {
          let handle = $0 as! ClosingHandle
          return .init(
            state: handle.state, snapshot: handle.snapshot, authority: handle.authority,
            highestIssuedRevision: handle.highest)
        }, installRepair: { _, _, _, _ in XCTFail("Successful deletion must not invoke repair") },
        projectRegistry: {}))
    func until(_ predicate: () -> Bool) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          XCTFail("Timed out waiting for actual checkpoint/close state")
          throw ClosingFixtureError.injected
        }
        try await Task.sleep(nanoseconds: 2_000_000)
      }
    }
    scheduler.startAfterRestoration()
    try await until { scheduler.lastAcknowledgedGeneration > 0 && !scheduler.hasPendingChanges }
    let initialGeneration = scheduler.lastAcknowledgedGeneration
    XCTAssertEqual(captureIDs, [[first.id, remaining.id]])
    XCTAssertEqual(
      Set(try XCTUnwrap(sessionStore.load()).windows.flatMap { $0.tabs.map(\.id) }),
      [first.id, remaining.id])

    holdNextPreparation = true
    scheduler.requestCheckpoint()
    try await until { gate.entered }
    let operation = try owner.start(documentIDs: [first.id], sourceWindowID: assignment.windowID)
    try await until { owner.status?.stage == .draining }
    XCTAssertTrue(registry.handle(id: first.id) === first)
    XCTAssertEqual(captureIDs.count, 1, "Held preparation cannot recapture the closing document")
    XCTAssertThrowsError(try owner.requireCaptureAdmission())
    gate.open()
    if case .completed(let ids) = try await owner.wait(for: operation) {
      XCTAssertEqual(ids, [first.id])
    } else {
      XCTFail("Close did not settle")
    }
    try await until {
      scheduler.lastAcknowledgedGeneration > initialGeneration && !scheduler.hasPendingChanges
    }
    await scheduler.pauseAndDrain()
    XCTAssertNil(scheduler.lastError)
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertTrue(captureIDs.dropFirst().allSatisfy { $0 == [remaining.id] })
    let postClose = try XCTUnwrap(receipts.last)
    XCTAssertGreaterThan(postClose.generation, initialGeneration)
    XCTAssertEqual(postClose.recoveryAuthorities, [remaining.id: remaining.authority])
    XCTAssertEqual(Set(postClose.recoveryRevisions.keys), [remaining.id])

    let reloaded = try XCTUnwrap(SessionStore(directory: sessionDirectory).load())
    XCTAssertEqual(reloaded.windows.flatMap { $0.tabs.map(\.id) }, [remaining.id])
    let freshReader = RecoveryCoordinator(directory: recoveryDirectory)
    let startup = try await freshReader.claimStartup()
    XCTAssertEqual(startup.snapshots.count, 1)
    XCTAssertEqual(startup.snapshots[0].id, remaining.id)
    XCTAssertTrue(startup.snapshots[0].text.utf16.elementsEqual(remaining.text.utf16))
    XCTAssertEqual(startup.snapshots[0].encoding, .utf16BE)
    XCTAssertTrue(startup.snapshots[0].hasBOM)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: recoveryDirectory.appendingPathComponent(first.id.uuidString + ".json").path))
  }
  func testQuitAdmissionRefusesWithoutCreatingPauseOrTicket() async throws {
    let fixture = try fixture()
    let handle = try await fixture.add()
    let owner = fixture.owner()
    fixture.quit = true
    XCTAssertThrowsError(
      try owner.start(documentIDs: [handle.id], sourceWindowID: fixture.assignment.windowID))
    XCTAssertFalse(owner.hasUnsettledTransactions)
    XCTAssertEqual(fixture.acquired, 0)
    XCTAssertEqual(fixture.registry.closeStatus(documentID: handle.id), .open)
  }
}
