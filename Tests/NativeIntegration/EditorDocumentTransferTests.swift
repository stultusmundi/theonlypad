import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class EditorDocumentTransferTests: XCTestCase {
  private let idle = NativeDocumentTransferPreparation(
    loading: false, macroWork: false, applicationPreparation: false, preparingQuit: false)
  private func managed() async throws -> EditorDocument {
    _ = NSApplication.shared
    let model = EditorDocument()
    let actor = RecoveryCoordinator(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try model.installRecoveryAdoption(
      try await actor.adoptManagedDocument(id: model.id),
      expectedOwnershipGeneration: model.ownershipGeneration)
    return model
  }
  func testScalarAndViewCapturePreserveDirtyTextUndoAndAuthorityWithoutDirtyRead() async throws {
    let model = try await managed()
    model.storage.mutableString.setString("😀dirty\r\n")
    model.editor.setSelectedRange(NSRange(location: 2, length: 0))
    model.undoManager.registerUndo(withTarget: model) {
      $0.storage.mutableString.setString("restored")
    }
    XCTAssertTrue(model.dirty)
    let dirtyReads = model.transferHarnessDirtyReads
    let text = model.storage.string
    let revision = model.editRevision
    let authority = model.recoveryAuthority
    let state = try model.captureTransferState(preparation: idle)
    XCTAssertEqual(state.documentID, model.id)
    XCTAssertEqual(state.recoveryAuthority, authority)
    XCTAssertFalse(state.isBusy)
    XCTAssertFalse(state.hasPendingTextEdits)
    let receipt = try model.captureTransferView(preparation: idle)
    try model.validateTransferView(receipt, expectedState: state, preparation: idle)
    XCTAssertEqual(model.transferHarnessDirtyReads, dirtyReads)
    XCTAssertEqual(model.storage.string, text)
    XCTAssertEqual(model.editRevision, revision)
    XCTAssertEqual(model.editor.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertTrue(model.undoManager.canUndo)
    model.undoManager.undo()
    XCTAssertEqual(model.storage.string, "restored")
  }
  func testControllerPreparationFlagsRemainExplicitAndRefuseViewCapture() async throws {
    let model = try await managed()
    let values = [
      NativeDocumentTransferPreparation(
        loading: true, macroWork: false, applicationPreparation: false, preparingQuit: false),
      .init(loading: false, macroWork: true, applicationPreparation: false, preparingQuit: false),
      .init(loading: false, macroWork: false, applicationPreparation: true, preparingQuit: false),
      .init(loading: false, macroWork: false, applicationPreparation: false, preparingQuit: true),
    ]
    for value in values {
      XCTAssertTrue(try model.captureTransferState(preparation: value).isBusy)
      XCTAssertThrowsError(try model.captureTransferView(preparation: value))
    }
  }
  func testPendingProcessingIsVisibleBeforeEditRevisionAdvances() async throws {
    let model = try await managed()
    let revision = model.editRevision
    let reads = model.transferHarnessDirtyReads
    model.storage.beginEditing()
    defer { model.storage.endEditing() }
    model.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "pending")
    XCTAssertEqual(model.editRevision, revision)
    XCTAssertTrue(try model.captureTransferState(preparation: idle).hasPendingTextEdits)
    XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
    XCTAssertEqual(model.transferHarnessDirtyReads, reads)
  }
  func testCompositionOperationAndPaneInstallAreUnsafe() async throws {
    let model = try await managed()
    model.editor.setMarkedText(
      "marked", selectedRange: NSRange(location: 0, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(try model.captureTransferState(preparation: idle).isComposing)
    XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
    model.editor.unmarkText()
    let operation = model.beginFileOperation()
    XCTAssertEqual(try model.captureTransferState(preparation: idle).operationID, operation)
    XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
    XCTAssertTrue(model.finishFileOperation(operation))
    model.panePresentation.installing = UUID()
    XCTAssertTrue(try model.captureTransferState(preparation: idle).isBusy)
    XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
    model.panePresentation.installing = nil
    model.saving = true
    XCTAssertTrue(try model.captureTransferState(preparation: idle).isBusy)
  }
  func testPooledPaneAndDeferredGeometryIsCopiedAndValidatedExactly() async throws {
    let model = try await managed()
    model.storage.mutableString.setString("a😀\r\nb")
    let first = model.panePool[0]
    let second = try model.makePane()
    first.editor.setSelectedRange(NSRange(location: 1, length: 2))
    second.editor.setSelectedRange(NSRange(location: 0, length: 0))
    model.preferredPaneID = first.id
    second.detach()
    model.splitAxis = .stacked
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: NSRange(location: 1, length: 2), scrollOrigin: .init(x: 0, y: 4)),
        .init(selection: NSRange(location: 0, length: 0), scrollOrigin: .init(x: 0, y: 8)),
      ], focusedPaneIndex: 1)
    model.panePresentation.pending = .init(
      presentation: presentation, livePaneID: first.id,
      liveSlot: 0, resolvedAtRevision: model.editRevision, presented: true)
    model.panePresentation.warning = "Deferred split"
    let receipt = try model.captureTransferView(preparation: idle)
    XCTAssertEqual(receipt.panes.map(\.id), [first.id, second.id])
    XCTAssertEqual(receipt.panes.map(\.attached), [true, false])
    XCTAssertEqual(receipt.pending?.presentation, presentation)
    XCTAssertEqual(receipt.warning, "Deferred split")
    XCTAssertEqual(receipt.axis, .stacked)
    model.panePresentation.warning = "New warning"
    XCTAssertThrowsError(
      try model.validateTransferView(receipt, expectedState: receipt.state, preparation: idle))
    XCTAssertEqual(receipt.warning, "Deferred split")
  }
  func testMutationAndNewRecoveryIssuanceCannotBeBlessedByExpectedState() async throws {
    let model = try await managed()
    let receipt = try model.captureTransferView(preparation: idle)
    model.acknowledgeFileBaseline()
    XCTAssertThrowsError(
      try model.validateTransferView(
        receipt,
        expectedState: model.captureTransferState(preparation: idle), preparation: idle))
    let next = try model.captureTransferView(preparation: idle)
    _ = try model.captureAuthorizedRecovery()
    XCTAssertThrowsError(
      try model.validateTransferView(
        next,
        expectedState: model.captureTransferState(preparation: idle), preparation: idle))
  }
  func testOnlyExplicitOwnershipRotationMayChangeExpectedScalarState() async throws {
    let model = try await managed()
    let receipt = try model.captureTransferView(preparation: idle)
    model.advanceOwnershipGeneration()
    XCTAssertThrowsError(
      try model.validateTransferView(receipt, expectedState: receipt.state, preparation: idle))
    let expected = try model.captureTransferState(preparation: idle)
    try model.validateTransferView(receipt, expectedState: expected, preparation: idle)
    let other = EditorDocument(id: model.id)
    XCTAssertThrowsError(
      try other.validateTransferView(receipt, expectedState: expected, preparation: idle))
    model.editor.setSelectedRange(NSRange(location: 0, length: 0))
    model.settingsApplied.toggle()
    XCTAssertThrowsError(
      try model.validateTransferView(receipt, expectedState: expected, preparation: idle))
  }
  func testMalformedPendingPresentationRefusesWithoutIndexing() async throws {
    let model = try await managed()
    model.panePresentation.pending = .init(
      presentation: .init(axis: .sideBySide, panes: [], focusedPaneIndex: -1),
      livePaneID: model.panePool[0].id, liveSlot: Int.max, resolvedAtRevision: 0)
    XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
  }
  func testPendingPublicationIdentityIsReportedAndNeverTransferable() async throws {
    let model = try await managed()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try AtomicFileStore().save(
        Data("same".utf8), to: directory.appendingPathComponent("saved.txt"),
        expected: nil, fault: .directorySync)
      XCTFail("expected real publication uncertainty")
    } catch FileStoreError.publicationUncertain(let evidence) {
      model.pendingPublication = .init(evidence: evidence, bytes: Data("same".utf8))
      let pending = try XCTUnwrap(model.pendingPublication)
      let reads = model.transferHarnessDirtyReads
      XCTAssertEqual(
        try model.captureTransferState(preparation: idle).pendingPublicationID, pending.id)
      XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
      XCTAssertEqual(model.transferHarnessDirtyReads, reads)
      XCTAssertEqual(model.pendingPublication?.id, pending.id)
    }
  }
  func testActualUndoCallbackAndPendingBookmarksReportBusyWithoutChangingHistory() async throws {
    let model = try await managed()
    var observed = false
    let idle = self.idle
    model.undoManager.registerUndo(withTarget: model) { target in
      do {
        observed = try target.captureTransferState(preparation: idle).isBusy
        XCTAssertThrowsError(try target.captureTransferView(preparation: idle))
      } catch { XCTFail("unexpected scalar refusal: \(error)") }
    }
    model.undoManager.undo()
    XCTAssertTrue(observed)
    model.pendingBookmarks = DocumentBookmarks()
    XCTAssertTrue(try model.captureTransferState(preparation: idle).hasPendingTextEdits)
    XCTAssertThrowsError(try model.captureTransferView(preparation: idle))
  }
  func testSelectionOriginAndMutationOnlyABAInvalidateReceipt() async throws {
    let model = try await managed()
    model.storage.mutableString.setString("ab")
    model.editor.setSelectedRange(NSRange(location: 0, length: 0))
    let receipt = try model.captureTransferView(preparation: idle)
    model.editor.setSelectedRange(NSRange(location: 1, length: 0))
    XCTAssertThrowsError(
      try model.validateTransferView(receipt, expectedState: receipt.state, preparation: idle))
    model.editor.setSelectedRange(NSRange(location: 0, length: 0))
    model.scroll.contentView.setBoundsOrigin(NSPoint(x: 4, y: 7))
    XCTAssertThrowsError(
      try model.validateTransferView(receipt, expectedState: receipt.state, preparation: idle))
    model.scroll.contentView.setBoundsOrigin(receipt.panes[0].origin)
    model.encoding = .utf16LE
    model.encoding = .utf8
    XCTAssertThrowsError(
      try model.validateTransferView(
        receipt,
        expectedState: model.captureTransferState(preparation: idle), preparation: idle))
  }

  func testDedicatedRotationReturnsExactlyAssignedFreshPairWithoutCallbacks() async throws {
    let model = try await managed()
    let oldOwnership = model.ownershipGeneration
    let oldMutation = model.closeMutationGeneration
    let authority = model.recoveryAuthority
    let highest = model.highestIssuedRecoveryRevision
    let revision = model.editRevision
    var callbacks = 0
    model.onCharactersChanged = { callbacks += 1 }
    let pair = model.rotateTransferOwnership()
    XCTAssertNotEqual(pair.ownershipGeneration, oldOwnership)
    XCTAssertNotEqual(pair.mutationGeneration, oldMutation)
    XCTAssertEqual(pair.ownershipGeneration, model.ownershipGeneration)
    XCTAssertEqual(pair.mutationGeneration, model.closeMutationGeneration)
    XCTAssertEqual(model.recoveryAuthority, authority)
    XCTAssertEqual(model.highestIssuedRecoveryRevision, highest)
    XCTAssertEqual(model.editRevision, revision)
    XCTAssertEqual(callbacks, 0)
    model.acknowledgeFileBaseline()
    XCTAssertNotEqual(pair.mutationGeneration, model.closeMutationGeneration)
    XCTAssertEqual(pair.ownershipGeneration, model.ownershipGeneration)
  }

}
