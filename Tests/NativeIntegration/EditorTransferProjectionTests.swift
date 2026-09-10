import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor private final class TransferProjectionFixture {
  let registry: ApplicationDocuments
  let recovery: RecoveryCoordinator
  let source = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let target = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let sourceID = UUID(), targetID = UUID()
  var first: EditorWindowController!
  var second: EditorWindowController!
  var sourceCheck: (() throws -> Void)?
  var detached = 0
  let idle = NativeDocumentTransferPreparation(
    loading: false, macroWork: false,
    applicationPreparation: false, preparingQuit: false)
  init() throws {
    _ = NSApplication.shared
    recovery = RecoveryCoordinator(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { h in
          let m = h as! EditorDocument
          return .init(
            documentID: m.id, ownershipGeneration: m.ownershipGeneration,
            authority: m.recoveryAuthority, highestIssuedRevision: m.highestIssuedRecoveryRevision)
        }),
      transferServices: .init(
        rotateOwnership: { h in
          let p = (h as! EditorDocument).rotateTransferOwnership()
          return .init(
            ownershipGeneration: p.ownershipGeneration, mutationGeneration: p.mutationGeneration)
        },
        readState: { h in
          try (h as! EditorDocument).captureTransferState(
            preparation:
              .init(
                loading: false, macroWork: false, applicationPreparation: false,
                preparingQuit: false))
        }))
    for a in [source, target] {
      try registry.registerWindow(id: a.windowID, initialGroupID: a.groupID)
    }
    first = try endpoint(source, sourceID)
    second = try endpoint(target, targetID)
  }
  func endpoint(_ a: DocumentAssignment, _ id: UUID) throws -> EditorWindowController {
    let routing = EditorApplicationRouting(
      endpointID: id, assignment: a, registry: registry,
      requireEndpointCurrent: { if a == self.source { try self.sourceCheck?() } },
      requireUserAdmission: {}, submit: { _ in throw DocumentTransferError.unavailable },
      wait: { _ in throw DocumentTransferError.unavailable },
      requestClose: { _ in throw DocumentTransferError.unavailable },
      requestReopen: { throw DocumentTransferError.unavailable },
      detachDocumentEndpoint: { _ in
        self.detached += 1
        throw DocumentTransferError.unavailable
      },
      reattachDocumentEndpoint: { _, _, _ in throw DocumentTransferError.unavailable },
      endpointClosed: { _ in }, requestCheckpoint: {})
    return try EditorWindowController(id: a.windowID, application: routing, onError: { _ in })
  }
  func add(_ a: DocumentAssignment, text: String, select: Bool = true) async throws
    -> EditorDocument
  {
    let m = EditorDocument()
    m.storage.mutableString.setString(text)
    let ticket = try registry.registerPending(
      m, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: false), in: a,
      at: registry.window(id: a.windowID)!.groups[0].documentIDs.count, select: select)
    let adoption = try await recovery.adoptManagedDocument(id: m.id)
    try m.installRecoveryAdoption(adoption, expectedOwnershipGeneration: m.ownershipGeneration)
    try registry.activateAdoption(ticket, receipt: adoption)
    return m
  }
  func project() throws {
    try first.applyRegistryProjection(
      registry.window(id: source.windowID)!, revision: registry.workspaceRevision,
      endpointID: sourceID)
    try second.applyRegistryProjection(
      registry.window(id: target.windowID)!, revision: registry.workspaceRevision,
      endpointID: targetID)
  }
  func reserve(_ m: EditorDocument) throws -> DocumentTransferLease {
    try registry.reserveTransfer(
      .init(
        documentID: m.id, source: source, target: target, targetIndex: 0,
        workspaceRevision: registry.workspaceRevision, ownershipGeneration: m.ownershipGeneration))
  }
}
@MainActor final class EditorTransferProjectionTests: XCTestCase {
  func testExactExistingWindowProjectionPreservesModelUndoAndAvoidsDirtyReads() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "synthetic 😀 dirty")
    let neighbor = try await f.add(f.source, text: "neighbor", select: false)
    let target = try await f.add(f.target, text: "target")
    try f.project()
    moved.editor.setSelectedRange(NSRange(location: 2, length: 1))
    moved.undoManager.registerUndo(withTarget: moved) {
      $0.storage.mutableString.setString("undo preserved")
    }
    let reads = [moved, neighbor, target].map(\.transferHarnessDirtyReads)
    let lease = try f.reserve(moved)
    var snapshot = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snapshot, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snapshot, endpointID: f.targetID)
    XCTAssertEqual([moved, neighbor, target].map(\.transferHarnessDirtyReads), reads)
    try f.registry.stageTransfer(lease)
    snapshot = try f.registry.validateTransferSnapshot(lease)
    try f.first.applyTransferProjection(snapshot, receipt: left)
    try f.second.applyTransferProjection(snapshot, receipt: right)
    try f.first.validateTransferEndpoint(snapshot, receipt: left)
    try f.second.validateTransferEndpoint(snapshot, receipt: right)
    XCTAssertEqual(f.detached, 0)
    XCTAssertTrue(f.registry.handle(id: moved.id) === moved)
    XCTAssertEqual(moved.editor.selectedRange(), NSRange(location: 2, length: 1))
    XCTAssertTrue(moved.undoManager.canUndo)
    XCTAssertEqual([moved, neighbor, target].map(\.transferHarnessDirtyReads), reads)
    try f.registry.completeTransfer(lease, willNotify: {})
  }
  func testReentrantTargetChangeIsRefusedBeforeProjection() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "source")
    let target = try await f.add(f.target, text: "target")
    try f.project()
    let lease = try f.reserve(moved)
    let snapshot = try f.registry.validateTransferSnapshot(lease)
    let receipt = try f.second.captureTransferEndpoint(snapshot, endpointID: f.targetID)
    target.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
    XCTAssertThrowsError(try f.second.validateTransferEndpoint(snapshot, receipt: receipt))
  }
  func testProjectionRetryAfterMembershipCallbackFailureAndRollback() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "source")
    let neighbor = try await f.add(f.source, text: "neighbor", select: false)
    _ = try await f.add(f.target, text: "target")
    try f.project()
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snap, endpointID: f.targetID)
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    var fired = false
    f.sourceCheck = {
      if f.first.selectedDocumentID == neighbor.id {
        fired = true
        throw DocumentTransferError.unavailable
      }
    }
    XCTAssertThrowsError(try f.first.applyTransferProjection(snap, receipt: left))
    XCTAssertTrue(fired)
    f.sourceCheck = nil
    try f.first.applyTransferProjection(snap, receipt: left)
    try f.second.applyTransferProjection(snap, receipt: right)
    try f.registry.restoreTransferAssignment(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try f.second.applyTransferProjection(snap, receipt: right)
    try f.first.applyTransferProjection(snap, receipt: left)
    XCTAssertEqual(f.first.selectedDocumentID, moved.id)
    try f.registry.settleRestoredTransfer(lease, willNotify: {})
  }

  func testTwoPaneTransferHasBoundedMonitorContextAndBlocksOrdinaryProjection() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "a😀b\nsecond")
    let pane = try moved.makePane()
    moved.splitAxis = .stacked
    moved.preferredPaneID = pane.id
    try f.project()
    let monitor = ApplicationFileMonitoring()
    f.first.configureFileMonitoring(monitor)
    f.second.configureFileMonitoring(monitor)
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snap, endpointID: f.targetID)
    let reads = moved.transferHarnessDirtyReads
    let context = try XCTUnwrap(f.first.transferFileStateContext(moved, receipt: left))
    XCTAssertTrue(context.dirty)
    XCTAssertFalse(context.quitting)
    XCTAssertEqual(moved.transferHarnessDirtyReads, reads)
    XCTAssertNil(f.first.ordinaryFileStateContext(moved))
    XCTAssertThrowsError(
      try f.first.applyRegistryProjection(
        snap.source,
        revision: f.registry.workspaceRevision, endpointID: f.sourceID))
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try f.first.applyTransferProjection(snap, receipt: left)
    try f.second.applyTransferProjection(snap, receipt: right)
    XCTAssertEqual(moved.panePool.filter(\.isAttached).count, 2)
    XCTAssertEqual(moved.preferredPaneID, pane.id)
    XCTAssertEqual(moved.splitAxis, .stacked)
    XCTAssertEqual(moved.transferHarnessDirtyReads, reads)
    try f.registry.completeTransfer(lease, willNotify: {})
    monitor.stop()
  }

  func testReentrantScrollNotificationRefusesWithoutRestoringOldOrigin() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "source")
    let neighbor = try await f.add(
      f.source, text: String(repeating: "line\n", count: 200), select: false)
    try f.project()
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let receipt = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let interaction = neighbor.panePresentation.interaction
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    var fired = false
    f.sourceCheck = {
      if f.first.selectedDocumentID == neighbor.id && !fired {
        fired = true
        neighbor.panePool[0].scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 13))
      }
    }
    XCTAssertThrowsError(try f.first.applyTransferProjection(snap, receipt: receipt))
    XCTAssertTrue(fired)
    XCTAssertNotEqual(neighbor.panePresentation.interaction, interaction)
  }

}
