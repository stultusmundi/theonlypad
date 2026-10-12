import Foundation
import PadCore
import XCTest

@testable import TransferProcess

private enum TransferProcessFailure: Error { case injected }
@MainActor private final class ProcessTransferHandle: WorkspaceDocumentHandle {
  let id = UUID()
  var ownershipGeneration = UUID()
  var mutation = UUID()
  var workspaceKind: WorkspaceDocumentKind { .editable }
  var authority: RecoveryWriteAuthority?
  var highest: UInt64 = 0
  var rejectReadOnce = false
  var rotationCount = 0
  var failReadAfterRotation: Int?
  func advanceOwnershipGeneration() {
    ownershipGeneration = UUID()
    mutation = UUID()
  }
  var state: DocumentTransferState {
    .init(
      documentID: id, kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: mutation, editRevision: 7, baselineRevision: 1, operationID: nil,
      pendingPublicationID: nil, isBusy: false, hasPendingTextEdits: false, isComposing: false,
      recoveryAuthority: authority, highestIssuedRevision: highest)
  }
}
@MainActor private final class ProcessTransferGate {
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func open() {
    continuation?.resume()
    continuation = nil
  }
}
@MainActor private final class ProcessTransferReceipt: ApplicationDocumentTransferReceipt {}
// Fixture-owned synthetic identity only; this is not native storage or a recording grant.
@MainActor private final class ProcessTransferStorageMarker {}
@MainActor private final class ProcessTransferFixture {
  let registry: ApplicationDocuments
  let handle = ProcessTransferHandle()
  let source = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let target = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let scheduler = SessionCheckpointCoordinator(
    capture: { _ in throw TransferProcessFailure.injected },
    commit: { _ in throw TransferProcessFailure.injected })
  let macroStorage = ProcessTransferStorageMarker()
  var macroBindingAssignment: DocumentAssignment?
  var macroBindingOwnership: UUID?
  var macroSuspension: MacroTransferSuspension?
  var macroRequest: DocumentTransferRequest?
  var macroFinishedToken: MacroTransferSuspension?
  var macroEvents: [String] = []
  var approvedRouteEvents: [String] = []
  var rejectApprovedRoutingOnce = false
  var atomicFinishAttempts = 0
  var approvedRoutingAttempts = 0
  var approvedRoutingRetryEvents: [String] = []
  var macroTerminalRepairs = 0
  var macroNilReceiptRepairs = 0
  var rejectMacroFinishOnce = false
  var events: [String] = []
  var sourceProjection: DocumentWindowSnapshot?
  var targetProjection: DocumentWindowSnapshot?
  var duringCapture: (() -> Void)?
  var drainGate: ProcessTransferGate?
  var onCheckpoint: (() -> Void)?
  var monitorPhase = 0
  var rejectFinishOnce = false
  var rejectSuspendOnce = false
  var rejectRefreshOnce = false
  var duringRefresh: (() -> Void)?
  var rejectSettlementOnce = false
  var rejectCapture = false
  var rejectTargetOnce = false
  var rejectRestoredSource = false
  var rejectReleaseOnce = false
  var targetInvalidatesSource = false
  var nativeGeometryValid = true
  init(actor: RecoveryCoordinator) {
    registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: actor.coordinatorID,
        readState: { value in
          let value = value as! ProcessTransferHandle
          return .init(
            documentID: value.id, ownershipGeneration: value.ownershipGeneration,
            authority: value.authority, highestIssuedRevision: value.highest)
        }),
      transferServices: .init(
        rotateOwnership: {
          let handle = $0 as! ProcessTransferHandle
          let ownership = UUID()
          let mutation = UUID()
          handle.ownershipGeneration = ownership
          handle.mutation = mutation
          handle.rotationCount += 1
          if handle.failReadAfterRotation == handle.rotationCount { handle.rejectReadOnce = true }
          return .init(ownershipGeneration: ownership, mutationGeneration: mutation)
        },
        readState: {
          let handle = $0 as! ProcessTransferHandle
          if handle.rejectReadOnce {
            handle.rejectReadOnce = false
            throw TransferProcessFailure.injected
          }
          return handle.state
        }))
  }
  func prepare(actor: RecoveryCoordinator) async throws {
    try registry.registerWindow(id: source.windowID, initialGroupID: source.groupID)
    try registry.registerWindow(id: target.windowID, initialGroupID: target.groupID)
    let token = try registry.registerPending(
      handle, requestID: UUID(),
      expectedRevision: registry.workspaceRevision, metadata: .init(pinned: false),
      in: source, at: 0, select: true)
    let receipt = try await actor.adoptManagedDocument(id: handle.id)
    handle.authority = receipt.authority
    handle.highest = receipt.nextRevision - 1
    try registry.activateAdoption(token, receipt: receipt)
    macroBindingAssignment = source
    macroBindingOwnership = handle.ownershipGeneration
  }
  var request: DocumentTransferRequest {
    .init(
      documentID: handle.id, source: source, target: target, targetIndex: 0,
      workspaceRevision: registry.workspaceRevision, ownershipGeneration: handle.ownershipGeneration
    )
  }
  // These Foundation collaborators enforce process custody of the actual reserved
  // lease. They do not model a native macro grant or an AppKit binding.
  private func suspendFixtureMacroBinding(_ snapshot: DocumentTransferSnapshot) throws
    -> MacroTransferSuspension
  {
    let current = try registry.validateTransferSnapshot(snapshot.lease)
    guard current.phase == .reserved, !current.effectsStarted,
      !current.requiresReconciliation, current.request == snapshot.request,
      current.handle === snapshot.handle, current.handle === handle,
      current.request.documentID == handle.id,
      registry.handle(id: handle.id) === handle,
      registry.assignment(of: handle.id) == current.request.source,
      current.expectedState == handle.state
    else { throw DocumentTransferError.stale }
    let token = MacroTransferSuspension(
      lease: current.lease, documentID: handle.id,
      documentObjectID: ObjectIdentifier(handle), storageID: ObjectIdentifier(macroStorage))
    if let held = macroSuspension {
      guard held == token, macroRequest == current.request,
        macroBindingAssignment == nil, macroBindingOwnership == nil
      else { throw DocumentTransferError.stale }
      return held
    }
    guard macroBindingAssignment == current.request.source,
      macroBindingOwnership == current.expectedState.ownershipGeneration
    else { throw DocumentTransferError.stale }
    macroEvents.append("suspend")
    macroRequest = current.request
    macroSuspension = token
    macroBindingAssignment = nil
    macroBindingOwnership = nil
    return token
  }

  private func finishFixtureMacroBinding(
    _ token: MacroTransferSuspension, terminal: ApplicationDocumentTransferTerminalReceipt,
    receipt: (any ApplicationDocumentTransferReceipt)?
  ) throws {
    guard macroRequest == terminal.request, token.documentID == handle.id,
      terminal.request.documentID == handle.id,
      token.documentObjectID == ObjectIdentifier(handle),
      token.storageID == ObjectIdentifier(macroStorage),
      registry.handle(id: handle.id) === handle,
      !registry.hasActiveTransferLease(token.lease),
      registry.closeStatus(documentID: handle.id) == .open,
      registry.adoptionStatus(documentID: handle.id) == .active,
      receipt == nil || receipt is ProcessTransferReceipt,
      receipt != nil || !terminal.moved
    else { throw DocumentTransferError.stale }
    let placement = terminal.moved ? terminal.request.target : terminal.request.source
    let windows = try registry.captureWindows()
    guard registry.assignment(of: handle.id) == placement,
      windows.first(where: { $0.id == placement.windowID })?.groups
        .first(where: { $0.id == placement.groupID })?.documentIDs.contains(handle.id) == true
    else { throw DocumentTransferError.stale }
    // Unrelated settlement callbacks may change workspaceRevision. Read actual
    // placement afresh rather than reusing the consumed reservation or old revision.
    let ownership = handle.ownershipGeneration
    atomicFinishAttempts += 1
    approvedRoutingRetryEvents.append("atomicFinishValidated")
    if macroSuspension == nil, macroFinishedToken == token {
      guard macroBindingAssignment == placement, macroBindingOwnership == ownership else {
        throw DocumentTransferError.stale
      }
      return
    }
    guard macroSuspension == token, macroBindingAssignment == nil,
      macroBindingOwnership == nil
    else { throw DocumentTransferError.stale }
    if rejectMacroFinishOnce {
      rejectMacroFinishOnce = false
      macroEvents.append("finishRefused")
      throw TransferProcessFailure.injected
    }
    // No callbacks or throwing operations after the fixture's atomic repair begins.
    macroEvents.append("finish")
    macroTerminalRepairs += 1
    if receipt == nil { macroNilReceiptRepairs += 1 }
    macroBindingAssignment = placement
    macroBindingOwnership = ownership
    macroFinishedToken = token
    macroSuspension = nil
  }

  private func completeFixtureApprovedRouting(
    _ token: MacroTransferSuspension, terminal: ApplicationDocumentTransferTerminalReceipt,
    receipt: (any ApplicationDocumentTransferReceipt)?
  ) throws {
    let placement = terminal.moved ? terminal.request.target : terminal.request.source
    guard macroFinishedToken == token, macroSuspension == nil, macroRequest == terminal.request,
      token.documentID == handle.id, token.documentObjectID == ObjectIdentifier(handle),
      token.storageID == ObjectIdentifier(macroStorage), registry.handle(id: handle.id) === handle,
      !registry.hasActiveTransferLease(token.lease),
      registry.assignment(of: handle.id) == placement, macroBindingAssignment == placement,
      macroBindingOwnership == handle.ownershipGeneration,
      registry.closeStatus(documentID: handle.id) == .open,
      registry.adoptionStatus(documentID: handle.id) == .active,
      receipt == nil || receipt is ProcessTransferReceipt, receipt != nil || !terminal.moved
    else {
      throw DocumentTransferError.stale
    }
    let windows = try registry.captureWindows()
    guard
      windows.first(where: { $0.id == placement.windowID })?.groups
        .first(where: { $0.id == placement.groupID })?.documentIDs.contains(handle.id) == true
    else {
      throw DocumentTransferError.stale
    }
    approvedRoutingAttempts += 1
    approvedRoutingRetryEvents.append("routingValidated")
    if rejectApprovedRoutingOnce {
      rejectApprovedRoutingOnce = false
      approvedRoutingRetryEvents.append("routingRefused")
      throw TransferProcessFailure.injected
    }
    approvedRoutingRetryEvents.append("routingCompleted")
    approvedRouteEvents.append("completeApprovedRouting")
  }

  func owner() -> ApplicationDocumentTransfer {
    .init(
      registry: registry,
      publication: .init(
        requireAdmission: {},
        acquirePause: {
          XCTAssertNotNil(self.macroSuspension, "Actual reserved quarantine must precede pause")
          XCTAssertNil(self.macroBindingAssignment)
          XCTAssertNil(self.macroBindingOwnership)
          self.events.append("pause")
          return try self.scheduler.acquirePause()
        },
        drainPause: {
          if let gate = self.drainGate { await gate.wait() }
          try await self.scheduler.drainPause($0)
          self.events.append("drain")
        },
        releasePause: {
          if self.rejectReleaseOnce {
            self.rejectReleaseOnce = false
            throw TransferProcessFailure.injected
          }
          try self.scheduler.releasePause($0)
          self.events.append("release")
        },
        requestCheckpoint: {
          self.events.append("checkpoint")
          self.onCheckpoint?()
        }),
      native: .init(
        suspendMacroBinding: { snapshot in
          try self.suspendFixtureMacroBinding(snapshot)
        },
        finishMacroBinding: { token, terminal, receipt in
          try self.finishFixtureMacroBinding(token, terminal: terminal, receipt: receipt)
        },
        completeApprovedViewRouting: { token, terminal, receipt in
          try self.completeFixtureApprovedRouting(token, terminal: terminal, receipt: receipt)
        },
        capture: { _ in
          self.events.append("capture")
          self.duringCapture?()
          if self.rejectCapture { throw TransferProcessFailure.injected }
          self.monitorPhase = 0
          return ProcessTransferReceipt()
        },
        validate: { _, _ in
          guard self.nativeGeometryValid else { throw TransferProcessFailure.injected }
        },
        suspendMonitor: { _, _ in
          guard self.monitorPhase != 3 else { throw TransferProcessFailure.injected }
          self.monitorPhase = 1
          self.events.append("suspend")
          if self.rejectSuspendOnce {
            self.rejectSuspendOnce = false
            throw TransferProcessFailure.injected
          }
        },
        projectSource: { snapshot, _ in
          if snapshot.phase == .restored && self.rejectRestoredSource {
            throw TransferProcessFailure.injected
          }
          self.sourceProjection = snapshot.source
          self.nativeGeometryValid = true
        },
        projectTarget: { snapshot, _ in
          if self.rejectTargetOnce {
            self.rejectTargetOnce = false
            throw TransferProcessFailure.injected
          }
          self.targetProjection = snapshot.target
          if self.targetInvalidatesSource { self.nativeGeometryValid = false }
        },
        attachMonitor: { _, _ in
          guard self.monitorPhase == 1 else { throw TransferProcessFailure.injected }
          self.monitorPhase = 2
          self.events.append("attach")
        },
        refreshAdmission: { _ in
          self.duringRefresh?()
          if self.rejectRefreshOnce {
            self.rejectRefreshOnce = false
            throw TransferProcessFailure.injected
          }
          self.events.append("refresh")
        },
        finishMonitor: { _, _ in
          guard self.monitorPhase == 2 else { throw TransferProcessFailure.injected }
          if self.rejectFinishOnce {
            self.rejectFinishOnce = false
            throw TransferProcessFailure.injected
          }
          self.monitorPhase = 3
          self.events.append("finish")
          if self.rejectSettlementOnce {
            self.rejectSettlementOnce = false
            self.handle.rejectReadOnce = true
          }
        }))
  }
}
@MainActor final class ApplicationDocumentTransferProcessTests: XCTestCase {
  func testMoveOwnsPauseAndGatesReentrantCaptureUntilExactSettlement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let actor = RecoveryCoordinator(directory: directory)
    let fixture = ProcessTransferFixture(actor: actor)
    try await fixture.prepare(actor: actor)
    let owner = fixture.owner()
    let originalAuthority = fixture.handle.authority
    fixture.duringCapture = {
      do {
        _ = try owner.start(fixture.request)
        XCTFail("Reentrant start admitted")
      } catch {}
      do {
        try owner.requireSettled()
        XCTFail("Unsettled transfer admitted")
      } catch {}
      do {
        _ = try fixture.registry.captureWindows()
        XCTFail("Reserved capture admitted")
      } catch {}
    }
    let id = try owner.start(fixture.request)
    guard case .moved = try await owner.wait(for: id) else { return XCTFail("Move did not settle") }
    try owner.requireSettled()
    XCTAssertTrue(fixture.registry.handle(id: fixture.handle.id) === fixture.handle)
    XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
    XCTAssertEqual(fixture.handle.authority, originalAuthority)
    XCTAssertEqual(fixture.sourceProjection?.groups[0].documentIDs, [])
    XCTAssertEqual(fixture.targetProjection?.groups[0].documentIDs, [fixture.handle.id])
    XCTAssertEqual(
      fixture.events,
      [
        "pause", "drain", "capture", "suspend", "attach", "finish", "release", "refresh",
        "checkpoint",
      ])
  }
  private func withFixture(_ body: (ProcessTransferFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let actor = RecoveryCoordinator(directory: directory)
    let fixture = ProcessTransferFixture(actor: actor)
    try await fixture.prepare(actor: actor)
    try await body(fixture)
  }
  func testTerminalReceiptPrecedesSettlementCallbackABAAndSurvivesCleanupRetry() async throws {
    try await withFixture { fixture in
      fixture.rejectTargetOnce = true
      fixture.rejectRefreshOnce = true
      let owner = fixture.owner()
      let request = fixture.request
      var settlement: UUID?
      var callbackMutation = false
      fixture.registry.onChange = { revision in
        guard (try? fixture.registry.captureWindows()) != nil,
          fixture.registry.assignment(of: fixture.handle.id) == fixture.source,
          fixture.handle.rotationCount == 2
        else { return }
        fixture.registry.onChange = nil
        settlement = revision
        let temporary = UUID()
        do {
          try fixture.registry.registerWindow(id: temporary, initialGroupID: UUID())
          try fixture.registry.unregisterEmptyWindow(
            temporary, expectedRevision: fixture.registry.workspaceRevision)
          callbackMutation = true
        } catch { XCTFail("Callback fixture failed: \(error)") }
      }
      let id = try owner.start(request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Refresh must retain")
      }
      let receipt = try owner.terminalReceipt(for: id)
      XCTAssertTrue(callbackMutation)
      XCTAssertEqual(receipt.request, request)
      XCTAssertFalse(receipt.moved)
      XCTAssertEqual(receipt.workspaceRevision, settlement)
      XCTAssertNotEqual(receipt.workspaceRevision, fixture.registry.workspaceRevision)
      XCTAssertThrowsError(try owner.terminalReceipt(for: .init(rawValue: UUID())))
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Retry must restore")
      }
      XCTAssertEqual(try owner.terminalReceipt(for: id).workspaceRevision, settlement)
    }
  }
  func testUnstagedTerminalReceiptNeverBlessesChangedRequestRevision() async throws {
    try await withFixture { fixture in
      let owner = fixture.owner()
      let request = fixture.request
      try fixture.registry.registerWindow(id: UUID(), initialGroupID: UUID())
      let id = try owner.start(request)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Stale request must restore")
      }
      let receipt = try owner.terminalReceipt(for: id)
      XCTAssertEqual(receipt.workspaceRevision, request.workspaceRevision)
      XCTAssertNotEqual(receipt.workspaceRevision, fixture.registry.workspaceRevision)
      XCTAssertFalse(receipt.moved)
    }
  }
  func testCaptureRefusalReleasesReservationAndPause() async throws {
    try await withFixture { fixture in
      fixture.rejectCapture = true
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Unstaged refusal retained")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
      XCTAssertEqual(try fixture.registry.captureWindows().count, 2)
      XCTAssertEqual(fixture.events.filter { $0 == "release" }.count, 1)
    }
  }
  func testTargetFailureRestoresBothProjectionsAndRotatesAgain() async throws {
    try await withFixture { fixture in
      fixture.rejectTargetOnce = true
      let original = fixture.handle.ownershipGeneration
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Rollback failed")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
      XCTAssertNotEqual(fixture.handle.ownershipGeneration, original)
      XCTAssertEqual(fixture.sourceProjection?.groups[0].documentIDs, [fixture.handle.id])
      XCTAssertEqual(fixture.targetProjection?.groups[0].documentIDs, [])
      XCTAssertEqual(fixture.events.filter { $0 == "suspend" }.count, 2)
    }
  }
  func testFailedRollbackRetainsAndRetriesSameModelAndPause() async throws {
    try await withFixture { fixture in
      fixture.rejectTargetOnce = true
      fixture.rejectRestoredSource = true
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      XCTAssertThrowsError(try owner.retryLease(for: id), "In-flight repair is forbidden")
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Failure not retained")
      }
      XCTAssertThrowsError(try owner.requireSettled())
      XCTAssertThrowsError(try fixture.registry.captureWindows())
      XCTAssertEqual(
        fixture.targetProjection?.groups[0].documentIDs, [],
        "Attempt target even when source rollback throws")
      let rollbackOwnership = fixture.handle.ownershipGeneration
      let retainedLease = try XCTUnwrap(owner.retryLease(for: id))
      XCTAssertTrue(fixture.registry.hasActiveTransferLease(retainedLease))
      XCTAssertThrowsError(try owner.retryLease(for: .init(rawValue: UUID())))
      fixture.rejectRestoredSource = false
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Retry did not settle")
      }
      try owner.requireSettled()
      XCTAssertThrowsError(try owner.retryLease(for: id), "Settled transaction cannot be repaired")
      XCTAssertFalse(fixture.registry.hasActiveTransferLease(retainedLease))
      XCTAssertEqual(fixture.handle.ownershipGeneration, rollbackOwnership)
      XCTAssertTrue(fixture.registry.handle(id: fixture.handle.id) === fixture.handle)
      XCTAssertEqual(fixture.events.filter { $0 == "pause" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "capture" }.count, 1)
    }
  }
  func testPauseReleaseFailureRetriesOnlyCleanupOfCommittedMove() async throws {
    try await withFixture { fixture in
      fixture.rejectReleaseOnce = true
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Pause failure not retained")
      }
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
      XCTAssertThrowsError(try owner.requireSettled())
      XCTAssertNil(try owner.retryLease(for: id), "Committed cleanup must not reuse the old lease")
      try owner.retryLayout(id)
      guard case .moved = try await owner.wait(for: id) else {
        return XCTFail("Committed move lost")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.events.filter { $0 == "finish" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "pause" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "release" }.count, 1)
    }
  }

  func testWaiterCancellationCannotDiscardReservedTransaction() async throws {
    try await withFixture { fixture in
      let gate = ProcessTransferGate()
      fixture.drainGate = gate
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      for _ in 0..<1000 {
        if gate.entered { break }
        await Task.yield()
      }
      XCTAssertTrue(gate.entered)
      let waiter = Task { try await owner.wait(for: id) }
      waiter.cancel()
      XCTAssertThrowsError(try owner.requireSettled())
      XCTAssertThrowsError(try fixture.registry.captureWindows())
      XCTAssertTrue(fixture.registry.handle(id: fixture.handle.id) === fixture.handle)
      gate.open()
      guard case .moved = try await waiter.value else { return XCTFail("Waiter cancelled owner") }
      try owner.requireSettled()
    }
  }
  func testRegistryNotificationRemainsPublicationHeldAndCheckpointCanStartNextTransfer()
    async throws
  {
    try await withFixture { fixture in
      let owner = fixture.owner()
      var notices = 0
      fixture.registry.onChange = { _ in
        notices += 1
        do {
          try owner.requireSettled()
          XCTFail("Pause still held during registry notification")
        } catch {}
      }
      var next: ApplicationDocumentTransferID?
      fixture.onCheckpoint = {
        fixture.onCheckpoint = nil
        let reverse = DocumentTransferRequest(
          documentID: fixture.handle.id,
          source: fixture.target, target: fixture.source, targetIndex: 0,
          workspaceRevision: fixture.registry.workspaceRevision,
          ownershipGeneration: fixture.handle.ownershipGeneration)
        do { next = try owner.start(reverse) } catch {
          XCTFail("Settled callback could not start next move")
        }
      }
      let id = try owner.start(fixture.request)
      guard case .moved = try await owner.wait(for: id) else {
        return XCTFail("First transfer failed")
      }
      let nextID = try XCTUnwrap(next)
      guard case .moved = try await owner.wait(for: nextID) else {
        return XCTFail("Old cleanup destroyed new owner")
      }
      XCTAssertEqual(notices, 2)
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
      try owner.requireSettled()
    }
  }
  func testInvalidReservationDoesNotLeaveProcessBusy() async throws {
    try await withFixture { fixture in
      let owner = fixture.owner()
      let request = DocumentTransferRequest(
        documentID: fixture.handle.id,
        source: fixture.source, target: fixture.target, targetIndex: -1,
        workspaceRevision: fixture.registry.workspaceRevision,
        ownershipGeneration: fixture.handle.ownershipGeneration)
      let id = try owner.start(request)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Refusal retained process")
      }
      try owner.requireSettled()
      XCTAssertFalse(fixture.events.contains("pause"))
      XCTAssertEqual(try fixture.registry.captureWindows().count, 2)
    }
  }

  func testFinishedMonitorThenTransientRegistryFailureRetriesSettlementOnly() async throws {
    try await withFixture { fixture in
      fixture.rejectSettlementOnce = true
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Failure not retained")
      }
      let ownership = fixture.handle.ownershipGeneration
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
      try owner.retryLayout(id)
      guard case .moved = try await owner.wait(for: id) else {
        return XCTFail("Settlement retry stranded consumed receipt")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.handle.ownershipGeneration, ownership)
      XCTAssertEqual(fixture.events.filter { $0 == "finish" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "attach" }.count, 1)
    }
  }

  func testTransientPostRotationReadRestoresExactKnownOwnership() async throws {
    try await withFixture { fixture in
      fixture.handle.failReadAfterRotation = 1
      let authority = fixture.handle.authority
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Known rotation stranded")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.handle.rotationCount, 2)
      XCTAssertEqual(fixture.handle.authority, authority)
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
    }
  }
  func testTransientRollbackReadRetriesWithoutThirdRotation() async throws {
    try await withFixture { fixture in
      fixture.rejectTargetOnce = true
      fixture.handle.failReadAfterRotation = 2
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Rollback fault not retained")
      }
      let generation = fixture.handle.ownershipGeneration
      XCTAssertEqual(fixture.handle.rotationCount, 2)
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Rollback retry stranded")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.handle.rotationCount, 2)
      XCTAssertEqual(fixture.handle.ownershipGeneration, generation)
    }
  }

  func testAdmissionRefreshRetriesAfterPauseReleaseWithoutRepeatingCommit() async throws {
    try await withFixture { fixture in
      fixture.rejectRefreshOnce = true
      let owner = fixture.owner()
      fixture.duringRefresh = {
        XCTAssertTrue(owner.allowsNativeAdmission)
        do {
          try owner.requireSettled()
          XCTFail("Competing process admitted during refresh")
        } catch {}
      }
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Refresh failure not retained")
      }
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
      try owner.retryLayout(id)
      guard case .moved = try await owner.wait(for: id) else {
        return XCTFail("Refresh retry failed")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.events.filter { $0 == "release" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "finish" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "refresh" }.count, 1)
    }
  }

  func testRollbackFinishRefusalSuspendsAcceptedAttachmentBeforeRetry() async throws {
    try await withFixture { fixture in
      fixture.rejectTargetOnce = true
      fixture.rejectFinishOnce = true
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Finish refusal not retained")
      }
      XCTAssertEqual(fixture.monitorPhase, 2)
      let generation = fixture.handle.ownershipGeneration
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Attached monitor cannot retry")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.handle.ownershipGeneration, generation)
      XCTAssertEqual(fixture.monitorPhase, 3)
    }
  }

  func testPrestageFinishRefusalSuspendsAcceptedAttachmentBeforeRetry() async throws {
    try await withFixture { fixture in
      fixture.rejectSuspendOnce = true
      fixture.rejectFinishOnce = true
      let owner = fixture.owner()
      let original = fixture.handle.ownershipGeneration
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Prestage finish refusal not retained")
      }
      XCTAssertEqual(fixture.monitorPhase, 2)
      XCTAssertEqual(fixture.handle.rotationCount, 0)
      XCTAssertEqual(fixture.sourceProjection?.groups[0].documentIDs, [fixture.handle.id])
      XCTAssertEqual(fixture.targetProjection?.groups[0].documentIDs, [])
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Prestage monitor cannot retry")
      }
      try owner.requireSettled()
      XCTAssertEqual(fixture.handle.ownershipGeneration, original)
      XCTAssertEqual(fixture.monitorPhase, 3)
    }
  }

  func testPrestageCancellationValidatesBothNativeEndpointsBeforeReattaching() async throws {
    try await withFixture { fixture in
      fixture.rejectSuspendOnce = true
      fixture.targetInvalidatesSource = true
      let owner = fixture.owner()
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Changed source geometry must retain the transaction")
      }
      XCTAssertFalse(fixture.events.contains("attach"))
      XCTAssertEqual(fixture.monitorPhase, 1)
      fixture.targetInvalidatesSource = false
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Exact original presentation could not be restored")
      }
      XCTAssertEqual(fixture.handle.rotationCount, 0)
      try owner.requireSettled()
    }
  }

}

// Additive real process/registry port-compatibility controls. Original event
// arrays and test bodies above are unchanged; macroEvents is a separate ledger.
@MainActor extension ApplicationDocumentTransferProcessTests {
  func testMacroQuarantineNilReceiptRefusalRetriesOneTerminalRepair() async throws {
    try await withFixture { fixture in
      fixture.rejectCapture = true
      fixture.rejectMacroFinishOnce = true
      let owner = fixture.owner()
      let request = fixture.request
      let originalOwnership = fixture.handle.ownershipGeneration
      let id = try owner.start(request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("A refused macro finish must retain the actual cleanup transaction")
      }
      let held = try XCTUnwrap(fixture.macroSuspension)
      XCTAssertEqual(held.documentID, fixture.handle.id)
      XCTAssertEqual(held.documentObjectID, ObjectIdentifier(fixture.handle))
      XCTAssertEqual(held.storageID, ObjectIdentifier(fixture.macroStorage))
      XCTAssertFalse(fixture.registry.hasActiveTransferLease(held.lease))
      XCTAssertNil(fixture.macroBindingAssignment)
      XCTAssertNil(fixture.macroBindingOwnership)
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finishRefused"])
      XCTAssertEqual(fixture.macroTerminalRepairs, 0)
      XCTAssertEqual(fixture.macroNilReceiptRepairs, 0)
      XCTAssertThrowsError(try owner.requireSettled())
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
      XCTAssertEqual(try owner.terminalReceipt(for: id).request, request)
      XCTAssertNil(try owner.retryLease(for: id), "Unstaged reservation was really cancelled")
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("The same real nil-receipt cleanup must restore")
      }
      try owner.requireSettled()
      XCTAssertNil(fixture.macroSuspension)
      XCTAssertEqual(fixture.macroFinishedToken, held)
      XCTAssertEqual(fixture.macroBindingAssignment, fixture.source)
      XCTAssertEqual(fixture.macroBindingOwnership, originalOwnership)
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finishRefused", "finish"])
      XCTAssertEqual(fixture.macroTerminalRepairs, 1)
      XCTAssertEqual(fixture.macroNilReceiptRepairs, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "pause" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "capture" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "release" }.count, 1)
      XCTAssertFalse(fixture.events.contains("suspend"), "No native monitor receipt was created")
    }
  }

  func testMacroQuarantineMovedTerminalRetriesFreshAssignmentWithoutRepeatingNativeMove()
    async throws
  {
    try await withFixture { fixture in
      fixture.rejectMacroFinishOnce = true
      let owner = fixture.owner()
      let oldOwnership = fixture.handle.ownershipGeneration
      fixture.duringCapture = {
        guard let token = fixture.macroSuspension else {
          return XCTFail("Real reserved quarantine must precede native capture")
        }
        XCTAssertTrue(fixture.registry.hasActiveTransferLease(token.lease))
        XCTAssertNil(fixture.macroBindingAssignment)
        do {
          let current = try fixture.registry.validateTransferSnapshot(token.lease)
          XCTAssertTrue(current.handle === fixture.handle)
          XCTAssertEqual(current.request.documentID, fixture.handle.id)
          XCTAssertEqual(current.phase, .reserved)
        } catch { XCTFail("Real reserved token was not valid: \(error)") }
      }
      let id = try owner.start(fixture.request)
      guard case .retained = try await owner.wait(for: id) else {
        return XCTFail("Committed move must retain only refused macro cleanup")
      }
      let token = try XCTUnwrap(fixture.macroSuspension)
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
      XCTAssertNotEqual(fixture.handle.ownershipGeneration, oldOwnership)
      XCTAssertNil(fixture.macroBindingAssignment)
      XCTAssertEqual(fixture.macroTerminalRepairs, 0)
      XCTAssertNil(try owner.retryLease(for: id))
      try owner.retryLayout(id)
      guard case .moved = try await owner.wait(for: id) else {
        return XCTFail("Current target placement must finish the same committed move")
      }
      try owner.requireSettled()
      XCTAssertNil(fixture.macroSuspension)
      XCTAssertEqual(fixture.macroFinishedToken, token)
      XCTAssertEqual(fixture.macroBindingAssignment, fixture.target)
      XCTAssertEqual(fixture.macroBindingOwnership, fixture.handle.ownershipGeneration)
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finishRefused", "finish"])
      XCTAssertEqual(fixture.macroTerminalRepairs, 1)
      XCTAssertEqual(fixture.macroNilReceiptRepairs, 0)
      XCTAssertEqual(fixture.events.filter { $0 == "capture" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "finish" }.count, 1)
      XCTAssertEqual(fixture.events.filter { $0 == "release" }.count, 1)
    }
  }
}

// SPDX-License-Identifier: MIT
// Same-file additive Foundation controls. Synthetic storage identity, no native route proof.
@MainActor extension ApplicationDocumentTransferProcessTests {
  func testApprovedRoutingMovedRefusalRetriesWithoutCallingConsumedAtomicFinishAgain()
    async throws
  {
    try await withFixture { fixture in
      fixture.rejectApprovedRoutingOnce = true
      let owner = fixture.owner()
      let request = fixture.request
      let authority = fixture.handle.authority
      let originalOwnership = fixture.handle.ownershipGeneration
      let id = try owner.start(request)
      guard case .retained(let error) = try await owner.wait(for: id) else {
        return XCTFail("Post-atomic routing refusal must retain this real cleanup transaction")
      }
      XCTAssertTrue(error is TransferProcessFailure)
      let consumed = try XCTUnwrap(fixture.macroFinishedToken)
      let terminal = try owner.terminalReceipt(for: id)
      XCTAssertTrue(terminal.moved)
      XCTAssertEqual(terminal.request, request)
      XCTAssertEqual(fixture.macroRequest, request)
      XCTAssertNil(fixture.macroSuspension, "Actual fixture atomic finish consumed quarantine")
      XCTAssertEqual(consumed.documentID, fixture.handle.id)
      XCTAssertEqual(consumed.documentObjectID, ObjectIdentifier(fixture.handle))
      XCTAssertEqual(consumed.storageID, ObjectIdentifier(fixture.macroStorage))
      XCTAssertFalse(fixture.registry.hasActiveTransferLease(consumed.lease))
      XCTAssertTrue(fixture.registry.handle(id: fixture.handle.id) === fixture.handle)
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
      XCTAssertEqual(fixture.macroBindingAssignment, fixture.target)
      XCTAssertEqual(fixture.macroBindingOwnership, fixture.handle.ownershipGeneration)
      XCTAssertNotEqual(fixture.handle.ownershipGeneration, originalOwnership)
      XCTAssertEqual(fixture.handle.authority, authority)
      XCTAssertEqual(fixture.macroTerminalRepairs, 1)
      XCTAssertEqual(fixture.macroNilReceiptRepairs, 0)
      XCTAssertEqual(fixture.atomicFinishAttempts, 1)
      XCTAssertEqual(fixture.approvedRoutingAttempts, 1)
      XCTAssertEqual(
        fixture.approvedRoutingRetryEvents,
        ["atomicFinishValidated", "routingValidated", "routingRefused"])
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finish"])
      XCTAssertEqual(fixture.approvedRouteEvents, [])
      XCTAssertTrue(owner.hasUnsettledTransactions)
      XCTAssertThrowsError(try owner.requireSettled())
      XCTAssertNil(try owner.retryLease(for: id), "Only cleanup is retained, not a reservation")
      XCTAssertThrowsError(try owner.start(request))
      let currentOwnership = fixture.handle.ownershipGeneration
      let currentRevision = fixture.registry.workspaceRevision
      try owner.retryLayout(id)
      guard case .moved = try await owner.wait(for: id) else {
        return XCTFail("Same committed placement must complete routing on the retry")
      }
      try owner.requireSettled()
      XCTAssertFalse(owner.hasUnsettledTransactions)
      XCTAssertEqual(try owner.terminalReceipt(for: id).request, request)
      XCTAssertEqual(
        try owner.terminalReceipt(for: id).workspaceRevision, terminal.workspaceRevision)
      XCTAssertEqual(fixture.registry.workspaceRevision, currentRevision)
      XCTAssertEqual(fixture.handle.ownershipGeneration, currentOwnership)
      XCTAssertEqual(fixture.handle.authority, authority)
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.target)
      XCTAssertEqual(fixture.macroBindingAssignment, fixture.target)
      XCTAssertEqual(fixture.macroBindingOwnership, currentOwnership)
      XCTAssertEqual(fixture.macroFinishedToken, consumed)
      XCTAssertNil(fixture.macroSuspension)
      XCTAssertEqual(fixture.macroTerminalRepairs, 1)
      XCTAssertEqual(
        fixture.atomicFinishAttempts, 1, "Consumed process flag must skip even idempotent service")
      XCTAssertEqual(fixture.approvedRoutingAttempts, 2)
      XCTAssertEqual(
        fixture.approvedRoutingRetryEvents,
        [
          "atomicFinishValidated", "routingValidated", "routingRefused",
          "routingValidated", "routingCompleted",
        ])
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finish"])
      XCTAssertEqual(fixture.approvedRouteEvents, ["completeApprovedRouting"])
      XCTAssertEqual(
        fixture.events,
        [
          "pause", "drain", "capture", "suspend", "attach", "finish", "release",
          "refresh", "refresh", "checkpoint",
        ])
      XCTAssertEqual(fixture.handle.rotationCount, 1)
      XCTAssertEqual(fixture.sourceProjection?.groups[0].documentIDs, [])
      XCTAssertEqual(fixture.targetProjection?.groups[0].documentIDs, [fixture.handle.id])
    }
  }

  func testApprovedRoutingNilReceiptRestoredRefusalRetriesWithoutRepeatingAtomicFinish()
    async throws
  {
    try await withFixture { fixture in
      fixture.rejectCapture = true
      fixture.rejectApprovedRoutingOnce = true
      let owner = fixture.owner()
      let request = fixture.request
      let ownership = fixture.handle.ownershipGeneration
      let authority = fixture.handle.authority
      let id = try owner.start(request)
      guard case .retained(let error) = try await owner.wait(for: id) else {
        return XCTFail("Nil-receipt restored outcome must retain refused post-atomic cleanup")
      }
      XCTAssertTrue(error is TransferProcessFailure)
      let consumed = try XCTUnwrap(fixture.macroFinishedToken)
      let terminal = try owner.terminalReceipt(for: id)
      XCTAssertFalse(terminal.moved)
      XCTAssertEqual(terminal.request, request)
      XCTAssertEqual(fixture.macroRequest, request)
      XCTAssertNil(fixture.macroSuspension)
      XCTAssertFalse(fixture.registry.hasActiveTransferLease(consumed.lease))
      XCTAssertEqual(consumed.documentID, fixture.handle.id)
      XCTAssertEqual(consumed.documentObjectID, ObjectIdentifier(fixture.handle))
      XCTAssertEqual(consumed.storageID, ObjectIdentifier(fixture.macroStorage))
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
      XCTAssertEqual(fixture.macroBindingAssignment, fixture.source)
      XCTAssertEqual(fixture.macroBindingOwnership, ownership)
      XCTAssertEqual(fixture.handle.ownershipGeneration, ownership)
      XCTAssertEqual(fixture.handle.authority, authority)
      XCTAssertEqual(fixture.macroTerminalRepairs, 1)
      XCTAssertEqual(fixture.macroNilReceiptRepairs, 1)
      XCTAssertEqual(fixture.atomicFinishAttempts, 1)
      XCTAssertEqual(fixture.approvedRoutingAttempts, 1)
      XCTAssertEqual(
        fixture.approvedRoutingRetryEvents,
        ["atomicFinishValidated", "routingValidated", "routingRefused"])
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finish"])
      XCTAssertEqual(fixture.approvedRouteEvents, [])
      XCTAssertTrue(owner.hasUnsettledTransactions)
      XCTAssertThrowsError(try owner.requireSettled())
      XCTAssertNil(try owner.retryLease(for: id))
      let currentRevision = fixture.registry.workspaceRevision
      try owner.retryLayout(id)
      guard case .restored = try await owner.wait(for: id) else {
        return XCTFail("Same actual nil-receipt source placement must complete on retry")
      }
      try owner.requireSettled()
      XCTAssertFalse(owner.hasUnsettledTransactions)
      XCTAssertEqual(try owner.terminalReceipt(for: id).request, request)
      XCTAssertEqual(
        try owner.terminalReceipt(for: id).workspaceRevision, terminal.workspaceRevision)
      XCTAssertEqual(fixture.registry.workspaceRevision, currentRevision)
      XCTAssertEqual(fixture.registry.assignment(of: fixture.handle.id), fixture.source)
      XCTAssertEqual(fixture.macroBindingAssignment, fixture.source)
      XCTAssertEqual(fixture.macroBindingOwnership, ownership)
      XCTAssertEqual(fixture.handle.ownershipGeneration, ownership)
      XCTAssertEqual(fixture.handle.authority, authority)
      XCTAssertEqual(fixture.macroFinishedToken, consumed)
      XCTAssertNil(fixture.macroSuspension)
      XCTAssertEqual(fixture.macroTerminalRepairs, 1)
      XCTAssertEqual(fixture.macroNilReceiptRepairs, 1)
      XCTAssertEqual(fixture.atomicFinishAttempts, 1)
      XCTAssertEqual(fixture.approvedRoutingAttempts, 2)
      XCTAssertEqual(
        fixture.approvedRoutingRetryEvents,
        [
          "atomicFinishValidated", "routingValidated", "routingRefused",
          "routingValidated", "routingCompleted",
        ])
      XCTAssertEqual(fixture.macroEvents, ["suspend", "finish"])
      XCTAssertEqual(fixture.approvedRouteEvents, ["completeApprovedRouting"])
      XCTAssertEqual(fixture.events, ["pause", "drain", "capture", "release", "checkpoint"])
      XCTAssertEqual(fixture.handle.rotationCount, 0)
      XCTAssertNil(fixture.sourceProjection)
      XCTAssertNil(fixture.targetProjection)
    }
  }
}
