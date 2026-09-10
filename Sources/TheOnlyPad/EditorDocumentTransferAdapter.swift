import AppKit
import PadCore

/// Supplied by the owning endpoint; no default silently assumes controller work is settled.
struct NativeDocumentTransferPreparation: Equatable {
  let loading: Bool
  let macroWork: Bool
  let applicationPreparation: Bool
  let preparingQuit: Bool
  var isBusy: Bool { loading || macroWork || applicationPreparation || preparingQuit }
}
struct NativeTransferPaneReceipt: Equatable {
  let id: UUID
  let object: ObjectIdentifier
  let attached: Bool
  let selection: NSRange
  let origin: NSPoint
}
struct NativeTransferPendingPresentation: Equatable {
  let presentation: SessionPresentation
  let livePaneID: UUID
  let liveSlot: Int
  let resolvedAtRevision: UInt64
  let presented: Bool
}
struct NativeDocumentTransferViewReceipt: Equatable {
  let model: ObjectIdentifier
  let state: DocumentTransferState
  let panes: [NativeTransferPaneReceipt]
  let preferredPaneID: UUID?
  let axis: PaneAxis
  let pending: NativeTransferPendingPresentation?
  let interaction: UUID
  let warning: String?
  let settingsApplied: Bool
}
enum NativeDocumentTransferError: Error { case busy, changed, invalidGeometry, unmanaged }

@MainActor extension EditorDocument {
  /// Bounded scalar inspection. In particular, this never evaluates exact dirty classification.
  func captureTransferState(preparation: NativeDocumentTransferPreparation) throws
    -> DocumentTransferState
  {
    guard (1...2).contains(panePool.count) else {
      throw NativeDocumentTransferError.invalidGeometry
    }
    return .init(
      documentID: id, kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: closeMutationGeneration, editRevision: editRevision,
      baselineRevision: baselineRevision, operationID: operationID,
      pendingPublicationID: pendingPublication?.id,
      isBusy: preparation.isBusy || saving || undoManager.isUndoing || undoManager.isRedoing
        || panePresentation.installing != nil || panePresentation.suppression != 0
        || panePresentation.frozenCapture != nil,
      hasPendingTextEdits: storage.editedMask.contains(.editedCharacters)
        || pendingBookmarks != nil || pendingBookmarksHaveUndo,
      isComposing: composingPaneID != nil || compositionOriginalText != nil
        || compositionBookmarks != nil || compositionUndoRegistered
        || panePool.contains { $0.editor.isComposingText || $0.editor.hasMarkedText() },
      recoveryAuthority: recoveryAuthority, highestIssuedRevision: highestIssuedRecoveryRevision)
  }
  func captureTransferView(preparation: NativeDocumentTransferPreparation) throws
    -> NativeDocumentTransferViewReceipt
  {
    let state = try captureTransferState(preparation: preparation)
    guard !state.isBusy, !state.hasPendingTextEdits, !state.isComposing,
      state.operationID == nil, state.pendingPublicationID == nil
    else { throw NativeDocumentTransferError.busy }
    guard let authority = state.recoveryAuthority, authority.documentID == id else {
      throw NativeDocumentTransferError.unmanaged
    }
    let length = storage.length
    guard length >= 0, length <= 100_000_000,
      panePool.contains(where: \.isAttached),
      preferredPaneID == nil
        || panePool.contains(where: { $0.id == preferredPaneID && $0.isAttached }),
      storage.layoutManagers.count == panePool.filter(\.isAttached).count
    else { throw NativeDocumentTransferError.invalidGeometry }
    var panes: [NativeTransferPaneReceipt] = []
    for pane in panePool {
      let range = pane.editor.selectedRange()
      let origin = pane.scroll.contentView.bounds.origin
      // Detached panes retain their old selection until reuse. Preserve it without clamping.
      let limit = pane.isAttached ? length : 100_000_000
      guard pane.document === self,
        pane.isAttached
          ? pane.layoutManager.textStorage === storage : pane.layoutManager.textStorage == nil,
        range.location >= 0, range.location <= limit,
        range.length >= 0, range.length <= limit - range.location,
        origin.x.isFinite, origin.y.isFinite
      else { throw NativeDocumentTransferError.invalidGeometry }
      panes.append(
        .init(
          id: pane.id, object: ObjectIdentifier(pane), attached: pane.isAttached,
          selection: range, origin: origin))
    }
    let pending: NativeTransferPendingPresentation?
    if let value = panePresentation.pending {
      try value.presentation.validate()
      guard value.liveSlot >= 0, value.liveSlot < value.presentation.panes.count,
        panePool.contains(where: { $0.id == value.livePaneID && $0.isAttached })
      else { throw NativeDocumentTransferError.invalidGeometry }
      pending = .init(
        presentation: value.presentation, livePaneID: value.livePaneID,
        liveSlot: value.liveSlot, resolvedAtRevision: value.resolvedAtRevision,
        presented: value.presented)
    } else {
      pending = nil
    }
    let result = NativeDocumentTransferViewReceipt(
      model: ObjectIdentifier(self), state: state,
      panes: panes, preferredPaneID: preferredPaneID, axis: splitAxis, pending: pending,
      interaction: panePresentation.interaction, warning: panePresentation.warning,
      settingsApplied: settingsApplied)
    guard try captureTransferState(preparation: preparation) == state else {
      throw NativeDocumentTransferError.changed
    }
    return result
  }
  /// expectedState comes from the exact registry lease, never from refreshing arbitrary callback changes.
  /// A registry stage/rollback may rotate ownership plus mutation; every other scalar remains frozen.
  func validateTransferView(
    _ receipt: NativeDocumentTransferViewReceipt,
    expectedState: DocumentTransferState, preparation: NativeDocumentTransferPreparation
  ) throws {
    guard receipt.model == ObjectIdentifier(self) else { throw NativeDocumentTransferError.changed }
    let original = receipt.state
    if expectedState.ownershipGeneration == original.ownershipGeneration {
      guard expectedState == original else { throw NativeDocumentTransferError.changed }
    } else {
      let rotated = DocumentTransferState(
        documentID: original.documentID, kind: original.kind,
        ownershipGeneration: expectedState.ownershipGeneration,
        mutationGeneration: expectedState.mutationGeneration, editRevision: original.editRevision,
        baselineRevision: original.baselineRevision, operationID: original.operationID,
        pendingPublicationID: original.pendingPublicationID, isBusy: original.isBusy,
        hasPendingTextEdits: original.hasPendingTextEdits, isComposing: original.isComposing,
        recoveryAuthority: original.recoveryAuthority,
        highestIssuedRevision: original.highestIssuedRevision)
      guard expectedState.mutationGeneration != original.mutationGeneration,
        expectedState == rotated
      else {
        throw NativeDocumentTransferError.changed
      }
    }
    let current = try captureTransferView(preparation: preparation)
    guard current.state == expectedState,
      current.panes == receipt.panes, current.preferredPaneID == receipt.preferredPaneID,
      current.axis == receipt.axis, current.pending == receipt.pending,
      current.interaction == receipt.interaction, current.warning == receipt.warning,
      current.settingsApplied == receipt.settingsApplied
    else { throw NativeDocumentTransferError.changed }
  }
}
