import Foundation
import PadCore
import XCTest

@testable import DocumentRegistry

@MainActor private final class TransferHandle: WorkspaceDocumentHandle {
  let id = UUID()
  var ownershipGeneration = UUID()
  var mutation = UUID()
  var kind: WorkspaceDocumentKind = .editable
  var workspaceKind: WorkspaceDocumentKind { kind }
  var edit: UInt64 = 0
  var busy = false
  var failReadOnce = false
  var invalidRotation = false
  var authority: RecoveryWriteAuthority?
  var highest: UInt64 = 0
  var onRead: (() -> Void)?
  var onRotate: (() -> Void)?
  func advanceOwnershipGeneration() {
    ownershipGeneration = UUID()
    mutation = UUID()
    onRotate?()
  }
  var state: DocumentTransferState {
    onRead?()
    return .init(
      documentID: id, kind: kind, ownershipGeneration: ownershipGeneration,
      mutationGeneration: mutation, editRevision: edit, baselineRevision: 1,
      operationID: nil, pendingPublicationID: nil, isBusy: busy, hasPendingTextEdits: false,
      isComposing: false, recoveryAuthority: authority, highestIssuedRevision: highest)
  }
}
@MainActor final class ApplicationDocumentTransferRegistryTests: XCTestCase {
  private func refuses(_ body: () throws -> Void) {
    do {
      try body()
      XCTFail("Expected refusal")
    } catch {}
  }
  private func fixture(
    neighbor: Bool = false, targetPinned: Bool = false, sourcePinned: Bool = false
  ) async throws -> (ApplicationDocuments, DocumentAssignment, DocumentAssignment, TransferHandle) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let actor = RecoveryCoordinator(directory: directory)
    let registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: actor.coordinatorID,
        readState: { handle in
          let h = handle as! TransferHandle
          return .init(
            documentID: h.id, ownershipGeneration: h.ownershipGeneration, authority: h.authority,
            highestIssuedRevision: h.highest)
        }),
      transferServices: .init(
        rotateOwnership: { handle in
          let h = handle as! TransferHandle
          if h.invalidRotation {
            return .init(ownershipGeneration: h.ownershipGeneration, mutationGeneration: h.mutation)
          }
          let pair = DocumentTransferOwnership(
            ownershipGeneration: UUID(), mutationGeneration: UUID())
          h.ownershipGeneration = pair.ownershipGeneration
          h.mutation = pair.mutationGeneration
          h.onRotate?()
          return pair
        },
        readState: { handle in
          let h = handle as! TransferHandle
          if h.failReadOnce {
            h.failReadOnce = false
            throw DocumentTransferError.unavailable
          }
          return h.state
        }))
    let source = DocumentAssignment(windowID: UUID(), groupID: UUID())
    let target = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: source.windowID, initialGroupID: source.groupID)
    try registry.registerWindow(id: target.windowID, initialGroupID: target.groupID)
    let model = TransferHandle()
    let adoption = try registry.registerPending(
      model, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: sourcePinned), in: source, at: 0, select: true)
    let receipt = try await actor.adoptManagedDocument(id: model.id)
    model.authority = receipt.authority
    model.highest = receipt.nextRevision - 1
    try registry.activateAdoption(adoption, receipt: receipt)
    for (enabled, destination, pinned, index) in [
      (neighbor, source, false, 1), (targetPinned, target, true, 0),
    ] where enabled {
      let extra = TransferHandle()
      let lease = try registry.registerPending(
        extra, requestID: UUID(), expectedRevision: registry.workspaceRevision,
        metadata: .init(pinned: pinned), in: destination, at: index, select: destination == target)
      let adopted = try await actor.adoptManagedDocument(id: extra.id)
      extra.authority = adopted.authority
      extra.highest = adopted.nextRevision - 1
      try registry.activateAdoption(lease, receipt: adopted)
    }
    return (registry, source, target, model)
  }
  private func request(
    _ registry: ApplicationDocuments, _ source: DocumentAssignment, _ target: DocumentAssignment,
    _ model: TransferHandle, index: Int = 0
  ) -> DocumentTransferRequest {
    .init(
      documentID: model.id, source: source, target: target, targetIndex: index,
      workspaceRevision: registry.workspaceRevision, ownershipGeneration: model.ownershipGeneration)
  }
  func testSameActiveHandleStagesAndSettlesBeforeNotification() async throws {
    let (registry, source, target, model) = try await fixture()
    let oldOwnership = model.ownershipGeneration
    let authority = model.authority
    let revision = registry.workspaceRevision
    var notices = 0
    var settled = false
    registry.onChange = { _ in
      notices += 1
      XCTAssertTrue(settled)
      XCTAssertTrue(registry.handle(id: model.id) === model)
      XCTAssertEqual(registry.assignment(of: model.id), target)
    }
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    XCTAssertThrowsError(try registry.captureWindows())
    XCTAssertFalse(registry.allows(.edit, documentID: model.id))
    try registry.stageTransfer(lease)
    let staged = try registry.transferSnapshot(lease)
    XCTAssertTrue(staged.handle === model)
    XCTAssertEqual(staged.source.groups[0].documentIDs, [])
    XCTAssertEqual(staged.target.groups[0].documentIDs, [model.id])
    XCTAssertNotEqual(model.ownershipGeneration, oldOwnership)
    XCTAssertEqual(model.authority, authority)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertEqual(notices, 0)
    try registry.completeTransfer(lease) {
      settled = true
      self.refuses { _ = try registry.captureWindows() }
    }
    XCTAssertEqual(notices, 1)
    XCTAssertNotEqual(registry.workspaceRevision, revision)
    XCTAssertEqual(registry.adoptionStatus(documentID: model.id), .active)
    XCTAssertThrowsError(try registry.transferSnapshot(lease))
  }
  func testRollbackRotatesAgainAndRestoresOriginalPlacement() async throws {
    let (registry, source, target, model) = try await fixture()
    let before = try registry.captureWindows()
    let original = model.ownershipGeneration
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    try registry.stageTransfer(lease)
    let staged = model.ownershipGeneration
    try registry.restoreTransferAssignment(lease)
    XCTAssertNotEqual(model.ownershipGeneration, staged)
    XCTAssertNotEqual(model.ownershipGeneration, original)
    try registry.settleRestoredTransfer(lease) {}
    XCTAssertEqual(try registry.captureWindows(), before)
    XCTAssertTrue(registry.handle(id: model.id) === model)
  }
  func testReservationGatesReadCallbackAndUnstagedCancelDoesNotMutate() async throws {
    let (registry, source, target, model) = try await fixture()
    let revision = registry.workspaceRevision
    model.onRead = {
      self.refuses { _ = try registry.captureWindows() }
      self.refuses {
        try registry.setPinned(true, documentID: model.id, expectedRevision: revision)
      }
      XCTAssertFalse(registry.allows(.select, documentID: model.id))
    }
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    try registry.cancelUnstagedTransfer(lease)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertEqual(registry.assignment(of: model.id), source)
  }
  func testInvalidRequestsAndBusyStateRefuseWithoutOwnershipEffects() async throws {
    let (registry, source, target, model) = try await fixture()
    let before = try registry.captureWindows()
    let ownership = model.ownershipGeneration
    for index in [-1, 1] {
      refuses {
        _ = try registry.reserveTransfer(request(registry, source, target, model, index: index))
      }
    }
    refuses { _ = try registry.reserveTransfer(request(registry, source, source, model)) }
    model.busy = true
    refuses { _ = try registry.reserveTransfer(request(registry, source, target, model)) }
    model.busy = false
    XCTAssertEqual(model.ownershipGeneration, ownership)
    XCTAssertEqual(try registry.captureWindows(), before)
  }
  func testPostRotationMutationRetainsGateAndNeverAcceptsRefreshedState() async throws {
    let (registry, source, target, model) = try await fixture()
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    model.onRotate = { model.edit += 1 }
    refuses { try registry.stageTransfer(lease) }
    XCTAssertEqual(registry.assignment(of: model.id), source)
    XCTAssertEqual(model.edit, 1)
    let diagnostic = try registry.transferSnapshot(lease)
    XCTAssertTrue(diagnostic.effectsStarted)
    XCTAssertTrue(diagnostic.requiresReconciliation)
    refuses { _ = try registry.validateTransferSnapshot(lease) }
    refuses { try registry.cancelUnstagedTransfer(lease) }
    refuses { try registry.restoreTransferAssignment(lease) }
    refuses { try registry.completeTransfer(lease) {} }
    refuses { _ = try registry.captureWindows() }
    XCTAssertFalse(registry.allows(.edit, documentID: model.id))
    XCTAssertTrue(registry.handle(id: model.id) === model)
  }
  func testReentrantRotationAndOldCompletionCannotAffectNewReservation() async throws {
    let (registry, source, target, model) = try await fixture()
    var reentry = 0
    model.onRotate = {
      reentry += 1
      self.refuses {
        _ = try registry.reserveTransfer(self.request(registry, source, target, model))
      }
      self.refuses { _ = try registry.captureWindows() }
      self.refuses {
        try registry.selectDocument(
          model.id, in: source, expectedRevision: registry.workspaceRevision)
      }
    }
    let first = try registry.reserveTransfer(request(registry, source, target, model))
    try registry.stageTransfer(first)
    var second: DocumentTransferLease?
    registry.onChange = { _ in
      do {
        second = try registry.reserveTransfer(self.request(registry, target, source, model))
      } catch { XCTFail("new reservation after coherent notification: \(error)") }
    }
    try registry.completeTransfer(first) {}
    XCTAssertEqual(reentry, 1)
    let new = try XCTUnwrap(second)
    refuses { try registry.completeTransfer(first) {} }
    XCTAssertEqual(try registry.transferSnapshot(new).request.source, target)
    try registry.cancelUnstagedTransfer(new)
  }
  func testForeignLeaseAndChangedSelectionRefuse() async throws {
    let (registry, source, target, model) = try await fixture()
    let (foreign, _, _, _) = try await fixture()
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    refuses { _ = try foreign.transferSnapshot(lease) }
    refuses { try foreign.cancelUnstagedTransfer(lease) }
    try registry.cancelUnstagedTransfer(lease)
    let old = request(registry, source, target, model)
    try registry.setPinned(true, documentID: model.id, expectedRevision: registry.workspaceRevision)
    refuses { _ = try registry.reserveTransfer(old) }
  }

  func testNeighborSelectionAndPinnedPartitionPreserved() async throws {
    let (registry, source, target, model) = try await fixture(neighbor: true, targetPinned: true)
    let neighbor = try XCTUnwrap(registry.window(id: source.windowID)?.groups[0].documentIDs.last)
    let pinned = try XCTUnwrap(registry.window(id: target.windowID)?.groups[0].documentIDs.first)
    refuses { _ = try registry.reserveTransfer(request(registry, source, target, model, index: 0)) }
    let lease = try registry.reserveTransfer(request(registry, source, target, model, index: 1))
    try registry.stageTransfer(lease)
    let state = try registry.validateTransferSnapshot(lease)
    XCTAssertEqual(state.source.groups[0].selectedDocumentID, neighbor)
    XCTAssertEqual(state.target.groups[0].documentIDs, [pinned, model.id])
    XCTAssertEqual(state.target.groups[0].selectedDocumentID, model.id)
    XCTAssertEqual(registry.metadata(id: model.id)?.pinned, false)
    XCTAssertEqual(registry.closedHistoryCount(windowID: source.windowID), 0)
    try registry.completeTransfer(lease) {}
  }
  func testPinnedMoveCannotCrossUnpinnedSegment() async throws {
    let (registry, source, target, model) = try await fixture(neighbor: true, sourcePinned: true)
    let neighbor = try XCTUnwrap(registry.window(id: source.windowID)?.groups[0].documentIDs.last)
    let first = try registry.reserveTransfer(request(registry, source, target, model))
    try registry.stageTransfer(first)
    try registry.completeTransfer(first) {}
    // The original source now contains one unpinned neighbor; pinned insertion at its end is invalid.
    refuses { _ = try registry.reserveTransfer(request(registry, target, source, model, index: 1)) }
    let second = try registry.reserveTransfer(request(registry, target, source, model, index: 0))
    try registry.stageTransfer(second)
    try registry.completeTransfer(second) {}
    XCTAssertEqual(
      registry.window(id: source.windowID)?.groups[0].documentIDs, [model.id, neighbor])
    XCTAssertEqual(registry.metadata(id: model.id)?.pinned, true)
  }

  func testPreStageRefusalCanCancelWithoutOverwritingUnrelatedMutation() async throws {
    let (registry, source, target, model) = try await fixture()
    let revision = registry.workspaceRevision
    let ownership = model.ownershipGeneration
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    model.edit += 1
    refuses { try registry.stageTransfer(lease) }
    XCTAssertFalse(try registry.transferSnapshot(lease).effectsStarted)
    try registry.cancelUnstagedTransfer(lease)
    XCTAssertEqual(model.edit, 1)
    XCTAssertEqual(model.ownershipGeneration, ownership)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertTrue(registry.allows(.edit, documentID: model.id))
  }

  func testTransientReadAfterStageRotationRetriesKnownTokens() async throws {
    let (registry, source, target, model) = try await fixture()
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    model.onRotate = { model.failReadOnce = true }
    refuses { try registry.stageTransfer(lease) }
    let rotated = model.ownershipGeneration
    model.onRotate = nil
    try registry.stageTransfer(lease)
    XCTAssertEqual(model.ownershipGeneration, rotated)
    try registry.completeTransfer(lease) {}
    XCTAssertEqual(registry.assignment(of: model.id), target)
  }
  func testTransientReadAfterRollbackKeepsExactRestoredTokens() async throws {
    let (registry, source, target, model) = try await fixture()
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    try registry.stageTransfer(lease)
    model.onRotate = { model.failReadOnce = true }
    refuses { try registry.restoreTransferAssignment(lease) }
    let restored = model.ownershipGeneration
    model.onRotate = nil
    try registry.settleRestoredTransfer(lease) {}
    XCTAssertEqual(model.ownershipGeneration, restored)
    XCTAssertEqual(registry.assignment(of: model.id), source)
  }

  func testInvalidMintedPairRemainsExplicitlyUnsafe() async throws {
    let (registry, source, target, model) = try await fixture()
    let lease = try registry.reserveTransfer(request(registry, source, target, model))
    model.invalidRotation = true
    refuses { try registry.stageTransfer(lease) }
    XCTAssertTrue(try registry.transferSnapshot(lease).requiresReconciliation)
    XCTAssertTrue(try registry.transferSnapshot(lease).effectsStarted)
    model.invalidRotation = false
    refuses { _ = try registry.validateTransferSnapshot(lease) }
    refuses { try registry.stageTransfer(lease) }
    refuses { try registry.cancelUnstagedTransfer(lease) }
  }

}
