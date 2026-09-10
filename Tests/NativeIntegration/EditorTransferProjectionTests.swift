import AppKit
import PadCore
import XCTest

@testable import NativeRouting

// NATIVE-ACCESS-BEGIN
@MainActor enum ProjectionFocusProbe {
  static var beforeFocus: ((EditorWindowController, NSResponder?) -> Bool?)?
  static var afterOrigin: ((EditorWindowController) -> Void)?
}
extension EditorWindowController {
  var focusTestInstalling: Bool { current?.panePresentation.installing != nil }
  var focusTestProjectionActive: Bool { projectionToken != nil }
  func focusTestInstall(_ presentation: SessionPresentation, document: EditorDocument) throws {
    try installResolvedPanes(presentation, on: document)
  }
  func focusTestProjected(_ pane: EditorPane) -> Bool { focusProjectedPane(pane) }
}
// NATIVE-ACCESS-END

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
  var onDetach: ((EditorDocument) -> Void)?
  var liveEndpoints: [UUID: UUID] = [:]
  var reattachCalls = 0
  var lastAttachmentContext: (() -> FileStateLiveContext?)?
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
    liveEndpoints[a.windowID] = id
    let routing = EditorApplicationRouting(
      endpointID: id, assignment: a, registry: registry,
      requireEndpointCurrent: { if a == self.source { try self.sourceCheck?() } },
      requireUserAdmission: {}, submit: { _ in throw DocumentTransferError.unavailable },
      wait: { _ in throw DocumentTransferError.unavailable },
      requestClose: { _ in throw DocumentTransferError.unavailable },
      requestReopen: { throw DocumentTransferError.unavailable },
      detachDocumentEndpoint: { model in
        self.onDetach?(model)
        self.detached += 1
        throw DocumentTransferError.unavailable
      },
      reattachDocumentEndpoint: { _, context, _ in
        self.lastAttachmentContext = context
        _ = context()
        self.reattachCalls += 1
        throw DocumentTransferError.unavailable
      },
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
  func testManagedStartupSinglePaneRestoresActualResponderAndUndo() async throws {
    try await checkManagedRestoredFocus(axis: .sideBySide, paneCount: 1, focusedSlot: 0)
  }
  func testManagedStartupSideBySideFirstPaneRestoresActualResponderAndUndo() async throws {
    try await checkManagedRestoredFocus(axis: .sideBySide, paneCount: 2, focusedSlot: 0)
  }
  func testManagedStartupSideBySideSecondPaneRestoresActualResponderAndUndo() async throws {
    try await checkManagedRestoredFocus(axis: .sideBySide, paneCount: 2, focusedSlot: 1)
  }
  func testManagedStartupStackedFirstPaneRestoresActualResponderAndUndo() async throws {
    try await checkManagedRestoredFocus(axis: .stacked, paneCount: 2, focusedSlot: 0)
  }
  func testManagedStartupStackedSecondPaneRestoresActualResponderAndUndo() async throws {
    try await checkManagedRestoredFocus(axis: .stacked, paneCount: 2, focusedSlot: 1)
  }
  func testManagedStartupFocusRefusalRetainsPendingLayoutAndOwnership() async throws {
    try await checkManagedRestoredFocus(
      axis: .stacked, paneCount: 2, focusedSlot: 1, refusal: .refuse)
  }
  func testManagedStartupFalseFocusSuccessRetainsPendingLayoutAndOwnership() async throws {
    try await checkManagedRestoredFocus(
      axis: .sideBySide, paneCount: 2, focusedSlot: 1, refusal: .falseSuccess)
  }
  func testManagedStartupResponderDisplacementAfterOriginRollsBack() async throws {
    try await checkManagedRestoredFocus(
      axis: .stacked, paneCount: 2, focusedSlot: 0, refusal: .afterOrigin)
  }
  func testOrdinaryInstallFocusRefusalRollsBackWithoutProjectionAuthority() async throws {
    let f = try TransferProjectionFixture()
    let model = try await f.add(f.source, text: "ALPHA\nOMEGA")
    try f.project()
    let original = try XCTUnwrap(f.first.visiblePanes.first)
    original.editor.setSelectedRange(NSRange(location: 1, length: 2))
    let selection = original.editor.selectedRange()
    let ownership = model.ownershipGeneration
    let axis = model.splitAxis
    let preferred = model.preferredPaneID
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: .init(location: 0, length: 5), scrollOrigin: .init(x: 0, y: 0)),
        .init(selection: .init(location: 6, length: 5), scrollOrigin: .init(x: 0, y: 0)),
      ], focusedPaneIndex: 1)
    model.panePresentation.pending = .init(
      presentation: presentation, livePaneID: original.id,
      liveSlot: 0, resolvedAtRevision: model.editRevision)
    var attempts = 0
    ProjectionFocusProbe.beforeFocus = { controller, responder in
      guard controller === f.first, controller.focusTestInstalling, responder is DocumentTextView
      else { return nil }
      XCTAssertFalse(controller.focusTestProjectionActive)
      attempts += 1
      return false
    }
    defer { ProjectionFocusProbe.beforeFocus = nil }
    XCTAssertFalse(
      f.first.focusTestProjected(original),
      "A scoped helper cannot manufacture projection authority")
    XCTAssertThrowsError(try f.first.focusTestInstall(presentation, document: model))
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(f.first.visiblePanes.map(\.id), [original.id])
    XCTAssertEqual(model.panePool.filter(\.isAttached).map(\.id), [original.id])
    XCTAssertEqual(original.editor.selectedRange(), selection)
    XCTAssertEqual(model.splitAxis, axis)
    XCTAssertEqual(model.preferredPaneID, preferred)
    XCTAssertEqual(model.ownershipGeneration, ownership)
    XCTAssertEqual(model.panePresentation.pending?.presentation, presentation)
    XCTAssertNil(model.panePresentation.installing)
    XCTAssertEqual(model.panePresentation.suppression, 0)
    XCTAssertTrue(f.registry.handle(id: model.id) === model)
    XCTAssertEqual(f.registry.assignment(of: model.id), f.source)
    XCTAssertFalse(try XCTUnwrap(f.first.window).isVisible)
  }
  func testOrdinaryInstallRestoresActualResponderWithoutProjectionScope() async throws {
    let f = try TransferProjectionFixture()
    let model = try await f.add(f.source, text: "ALPHA\nOMEGA")
    try f.project()
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: .init(location: 0, length: 5), scrollOrigin: .init(x: 0, y: 0)),
        .init(selection: .init(location: 6, length: 5), scrollOrigin: .init(x: 0, y: 0)),
      ], focusedPaneIndex: 1)
    var attempts = 0
    ProjectionFocusProbe.beforeFocus = { controller, responder in
      guard controller === f.first, controller.focusTestInstalling, responder is DocumentTextView
      else { return nil }
      XCTAssertFalse(controller.focusTestProjectionActive)
      attempts += 1
      return nil
    }
    defer { ProjectionFocusProbe.beforeFocus = nil }
    try f.first.focusTestInstall(presentation, document: model)
    XCTAssertEqual(attempts, 1)
    let target = try XCTUnwrap(f.first.visiblePanes.last)
    XCTAssertTrue(f.first.window?.firstResponder === target.editor)
    guard f.first.window?.firstResponder === target.editor else { return }
    let responder = try XCTUnwrap(f.first.window?.firstResponder as? DocumentTextView)
    responder.insertText("preferred", replacementRange: .init(location: NSNotFound, length: 0))
    XCTAssertEqual(model.storage.string, "ALPHA\npreferred")
    model.undoManager.undo()
    XCTAssertEqual(model.storage.string, "ALPHA\nOMEGA")
    XCTAssertTrue(f.first.window?.firstResponder === target.editor)
    XCTAssertFalse(try XCTUnwrap(f.first.window).isVisible)
  }
  func testManagedStartupReentrantAuthorityLossDuringFocusRollsBack() async throws {
    try await checkManagedRestoredFocus(
      axis: .sideBySide, paneCount: 2, focusedSlot: 0, refusal: .invalidate)
  }
  private enum FocusRefusal { case refuse, falseSuccess, afterOrigin, invalidate }
  private func checkManagedRestoredFocus(
    axis: SessionPaneAxis, paneCount: Int, focusedSlot: Int, refusal: FocusRefusal? = nil
  ) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("synthetic-focus.txt")
    let original = "ALPHA\nOMEGA"
    try Data(original.utf8).write(to: input)
    let ranges = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5)]
    let presentation = SessionPresentation(
      axis: axis,
      panes: (0..<paneCount).map {
        .init(selection: ranges[$0], scrollOrigin: .init(x: 0, y: 0))
      }, focusedPaneIndex: focusedSlot)
    let tab = SessionTab(originalPath: input.path, presentation: presentation)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    try store.save(.init(windows: [.init(tabs: [tab], selectedTabID: tab.id)]))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    var attempts = 0
    var origins = 0
    var capturedOwnership: UUID?
    var capturedRevision: UInt64?
    var capturedModel: EditorDocument?
    ProjectionFocusProbe.beforeFocus = { controller, responder in
      guard controller.focusTestInstalling, let editor = responder as? DocumentTextView,
        let pane = controller.visiblePanes.first(where: { $0.editor === editor })
      else { return nil }
      XCTAssertTrue(controller.focusTestProjectionActive)
      attempts += 1
      capturedModel = pane.document
      capturedOwnership = pane.document.ownershipGeneration
      capturedRevision = pane.document.editRevision
      switch refusal {
      case .refuse: return false
      case .invalidate:
        pane.document.panePresentation.invalidate(force: true)
        return nil
      case .falseSuccess:
        _ = controller.window?.makeFirstResponder(nil)
        return true
      default: return nil
      }
    }
    ProjectionFocusProbe.afterOrigin = { controller in
      guard controller.focusTestInstalling else { return }
      origins += 1
      if refusal == .afterOrigin { _ = controller.window?.makeFirstResponder(nil) }
    }
    defer {
      ProjectionFocusProbe.beforeFocus = nil
      ProjectionFocusProbe.afterOrigin = nil
    }
    try await owner.start()
    let controller = try XCTUnwrap(owner.windows.first)
    if refusal != nil {
      let model = try XCTUnwrap(capturedModel)
      let live = try XCTUnwrap(controller.visiblePanes.first)
      XCTAssertEqual(attempts, 1)
      XCTAssertEqual(origins, refusal == .afterOrigin ? paneCount : 0)
      XCTAssertEqual(controller.visiblePanes.count, 1)
      XCTAssertEqual(model.panePool.filter(\.isAttached).map(\.id), [live.id])
      XCTAssertTrue(live.document === model)
      XCTAssertEqual(model.ownershipGeneration, capturedOwnership)
      XCTAssertEqual(model.editRevision, capturedRevision)
      XCTAssertEqual(model.storage.string, original)
      XCTAssertEqual(live.editor.selectedRange(), ranges[focusedSlot])
      XCTAssertEqual(model.preferredPaneID, live.id)
      XCTAssertEqual(model.panePresentation.pending?.presentation, presentation)
      XCTAssertEqual(controller.sessionMetadata.tabs.first?.presentation, presentation)
      XCTAssertNil(model.panePresentation.installing)
      XCTAssertEqual(model.panePresentation.suppression, 0)
      XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
      _ = try await owner.prepareQuit()
      return
    }
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(origins, paneCount)
    let panes = controller.visiblePanes
    XCTAssertEqual(panes.count, paneCount)
    XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    guard panes.indices.contains(focusedSlot) else {
      _ = try await owner.prepareQuit()
      return
    }
    let expected = panes[focusedSlot]
    XCTAssertTrue(controller.focusedPane === expected)
    XCTAssertEqual(expected.editor.selectedRange(), ranges[focusedSlot])
    XCTAssertTrue(expected.editor.isEditable && expected.editor.isSelectable)
    XCTAssertTrue(
      controller.window?.firstResponder === expected.editor,
      "Managed startup must restore the actual preferred native responder")
    if controller.window?.firstResponder === expected.editor {
      let responder = try XCTUnwrap(controller.window?.firstResponder as? DocumentTextView)
      responder.insertText("preferred", replacementRange: NSRange(location: NSNotFound, length: 0))
      let edited = focusedSlot == 0 ? "preferred\nOMEGA" : "ALPHA\npreferred"
      for pane in panes { XCTAssertEqual(pane.editor.string, edited) }
      expected.document.undoManager.undo()
      for pane in panes { XCTAssertEqual(pane.editor.string, original) }
      XCTAssertTrue(controller.window?.firstResponder === expected.editor)
    }
    XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    _ = try await owner.prepareQuit()
  }
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

  func testExplicitActiveReplacementRetainsRollbackReceiptAndRefusesOldIncarnation() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "source")
    try f.project()
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snap, endpointID: f.targetID)
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try f.first.applyTransferProjection(snap, receipt: left)
    let newID = UUID()
    let replacement = try f.endpoint(f.target, newID)
    XCTAssertThrowsError(try replacement.applyTransferProjection(snap, receipt: right))
    let rebound = try replacement.reconcileTransferEndpoint(snap, receipt: right, endpointID: newID)
    XCTAssertEqual(rebound.views, right.views)
    XCTAssertEqual(rebound.states, right.states)
    XCTAssertEqual(rebound.original, right.original)
    try replacement.applyTransferProjection(snap, receipt: rebound)
    XCTAssertEqual(replacement.selectedDocumentID, moved.id)
    try f.registry.restoreTransferAssignment(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try replacement.applyTransferProjection(snap, receipt: rebound)
    try f.first.applyTransferProjection(snap, receipt: left)
    XCTAssertEqual(f.first.selectedDocumentID, moved.id)
    try f.registry.settleRestoredTransfer(lease, willNotify: {})
  }
  func testTerminalReplacementKeepsEditsAndCurrentSelectionWithoutOldLease() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "source")
    try f.project()
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snap, endpointID: f.targetID)
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try f.first.applyTransferProjection(snap, receipt: left)
    try f.second.applyTransferProjection(snap, receipt: right)
    try f.registry.completeTransfer(lease, willNotify: {})
    moved.storage.mutableString.setString("after commit edit")
    moved.editor.setSelectedRange(NSRange(location: 4, length: 2))
    let revision = moved.editRevision
    let newID = UUID()
    let replacement = try f.endpoint(f.target, newID)
    let result = try replacement.reconcileSettledTransferEndpoint(
      receipt: right,
      expected: f.registry.window(id: f.target.windowID)!, endpointID: newID)
    XCTAssertEqual(result.endpointID, newID)
    XCTAssertEqual(replacement.selectedDocumentID, moved.id)
    XCTAssertEqual(moved.storage.string, "after commit edit")
    XCTAssertEqual(moved.editRevision, revision)
    XCTAssertEqual(moved.editor.selectedRange(), NSRange(location: 4, length: 2))
    moved.advanceOwnershipGeneration()
    XCTAssertThrowsError(
      try replacement.reconcileSettledTransferEndpoint(
        receipt: result,
        expected: f.registry.window(id: f.target.windowID)!, endpointID: newID))
    XCTAssertEqual(moved.storage.string, "after commit edit")
  }

  func testReplacementCanRetryItsOwnFailedNeighborAttachment() async throws {
    let f = try TransferProjectionFixture()
    let moved = try await f.add(f.source, text: "source")
    let neighbor = try await f.add(f.source, text: "neighbor", select: false)
    try f.project()
    let monitor = ApplicationFileMonitoring()
    neighbor.fileState = DocumentFileStateController(
      documentID: neighbor.id, client: monitor.client,
      liveContext: { nil }, onChange: {})
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let original = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    let id = UUID()
    let replacement = try f.endpoint(f.source, id)
    replacement.configureFileMonitoring(monitor)
    let reads = neighbor.transferHarnessDirtyReads
    var receipt: EditorTransferEndpointReceipt? = try replacement.reconcileTransferEndpoint(
      snap, receipt: original, endpointID: id)
    XCTAssertThrowsError(try replacement.applyTransferProjection(snap, receipt: receipt!))
    XCTAssertEqual(f.reattachCalls, 1)
    XCTAssertEqual(neighbor.transferHarnessDirtyReads, reads)
    XCTAssertTrue(try XCTUnwrap(f.lastAttachmentContext?()).dirty)
    XCTAssertEqual(neighbor.transferHarnessDirtyReads, reads)
    receipt = nil
    XCTAssertNil(f.lastAttachmentContext?())
    XCTAssertEqual(neighbor.transferHarnessDirtyReads, reads)
    // Retry must reach the real injected attachment failure again, not strand on its own pending flag.
    let next = try replacement.reconcileTransferEndpoint(snap, receipt: original, endpointID: id)
    XCTAssertThrowsError(try replacement.applyTransferProjection(snap, receipt: next))
    XCTAssertEqual(f.reattachCalls, 2)
    try f.registry.restoreTransferAssignment(lease)
    try f.registry.settleRestoredTransfer(lease, willNotify: {})
    XCTAssertTrue(try replacement.captureTransferPreparation().isBusy)
    XCTAssertNotNil(f.lastAttachmentContext?())
    XCTAssertEqual(neighbor.transferHarnessDirtyReads, reads + 1)
    monitor.stop()
  }

  func testClosingEndpointRetainsClosedBindingContextForDetachment() async throws {
    let f = try TransferProjectionFixture()
    let model = try await f.add(f.source, text: "source")
    try f.project()
    let monitor = ApplicationFileMonitoring()
    f.first.configureFileMonitoring(monitor)
    let lease = try f.reserve(model)
    let snapshot = try f.registry.validateTransferSnapshot(lease)
    let receipt = try f.first.captureTransferEndpoint(snapshot, endpointID: f.sourceID)
    try f.registry.cancelUnstagedTransfer(lease)
    var observed = false
    f.onDetach = { [weak f] document in
      guard let f else { return }
      observed = true
      XCTAssertEqual(f.first.transferFileStateContext(document, receipt: receipt)?.closed, true)
      XCTAssertEqual(f.first.ordinaryFileStateContext(document)?.closed, true)
    }
    f.first.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: f.first.window))
    XCTAssertTrue(observed)
    monitor.stop()
  }

}
