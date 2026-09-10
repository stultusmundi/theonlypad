import AppKit
import PadCore

struct NativeClosePaneState: Equatable {
  let id: UUID
  let attached: Bool
  let selection: NSRange
  let origin: NSPoint
}
struct NativeCloseGeometry: Equatable {
  let panes: [NativeClosePaneState]
  let preferredPaneID: UUID?
  let axis: PaneAxis
}
struct NativeCloseRecoveryCapture {
  let state: DocumentCloseState
  let snapshot: RecoverySnapshot
  let authority: RecoveryWriteAuthority
  let highestIssuedRevision: UInt64
}
struct NativeRepairInstallationContext {
  let state: DocumentCloseState
  let modelAuthority: RecoveryWriteAuthority
  let highestIssuedRevision: UInt64
}
enum NativeCloseModelError: Error { case busy, changed }
@MainActor extension EditorDocument {
  /// Exact dirty classification is reused; no new text snapshot or layout is requested here.
  func captureCloseState() throws -> DocumentCloseState {
    guard nativeConfigurationToken == nil, !undoManager.isUndoing, !undoManager.isRedoing,
      !(saving && operationID == nil),
      !storage.editedMask.contains(.editedCharacters), pendingBookmarks == nil,
      !pendingBookmarksHaveUndo
    else { throw NativeCloseModelError.busy }
    return .init(
      kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: closeMutationGeneration, operationID: operationID, isDirty: dirty,
      hasPendingPublication: pendingPublication != nil, hasPendingTextEdits: false,
      isComposing: composingPaneID != nil || compositionOriginalText != nil
        || compositionBookmarks != nil
        || panePool.contains(where: { $0.editor.isComposingText || $0.editor.hasMarkedText() }),
      canRetainCleanHistory: true)
  }
  func captureCloseGeometry() -> NativeCloseGeometry {
    .init(
      panes: panePool.map {
        .init(
          id: $0.id, attached: $0.isAttached,
          selection: $0.editor.selectedRange(), origin: $0.scroll.contentView.bounds.origin)
      },
      preferredPaneID: preferredPaneID, axis: splitAxis)
  }
  func captureCloseRecovery() throws -> NativeCloseRecoveryCapture {
    let state = try captureCloseState()
    guard state.operationID == nil, !state.isComposing else { throw NativeCloseModelError.busy }
    guard let authority = recoveryAuthority else { throw RecoveryAuthorityError.authorityRequired }
    let revision = highestIssuedRecoveryRevision
    let snapshot = RecoverySnapshot(
      id: id, text: storage.string, encoding: encoding,
      hasBOM: hasBOM, originalPath: url?.path)
    guard try captureCloseState() == state, recoveryAuthority == authority,
      highestIssuedRecoveryRevision == revision
    else { throw NativeCloseModelError.changed }
    return .init(
      state: state, snapshot: snapshot, authority: authority, highestIssuedRevision: revision)
  }
  func installCloseRepair(
    _ receipt: RecoveryRepairReceipt,
    expected: NativeRepairInstallationContext
  ) throws {
    // The process caller separately checks exact registry attempt and actor lease/receipt correlation.
    let current = try captureCloseState()
    guard current == expected.state, current.operationID == nil, !current.isComposing else {
      throw NativeCloseModelError.changed
    }
    try installRecoveryRepair(
      receipt, expectedAuthority: expected.modelAuthority,
      expectedHighestIssuedRevision: expected.highestIssuedRevision,
      expectedOwnershipGeneration: expected.state.ownershipGeneration,
      expectedMutationGeneration: expected.state.mutationGeneration)
  }
}
