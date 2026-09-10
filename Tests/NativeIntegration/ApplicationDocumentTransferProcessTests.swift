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
@MainActor private final class ProcessTransferFixture {
  let registry: ApplicationDocuments
  let handle = ProcessTransferHandle()
  let source = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let target = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let scheduler = SessionCheckpointCoordinator(
    capture: { _ in throw TransferProcessFailure.injected },
    commit: { _ in throw TransferProcessFailure.injected })
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
  }
  var request: DocumentTransferRequest {
    .init(
      documentID: handle.id, source: source, target: target, targetIndex: 0,
      workspaceRevision: registry.workspaceRevision, ownershipGeneration: handle.ownershipGeneration
    )
  }
  func owner() -> ApplicationDocumentTransfer {
    .init(
      registry: registry,
      publication: .init(
        requireAdmission: {},
        acquirePause: {
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
