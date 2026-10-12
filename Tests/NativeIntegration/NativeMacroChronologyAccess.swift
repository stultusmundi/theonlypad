// SPDX-License-Identifier: MIT
// Frozen native-test access only. Each marker payload is the exact accepted tail.
// Includes controlled setters/forwarders and teardown; never production authority.
// MACRO-ApprovedViewCommitBroker-ACCESS-BEGIN

struct NativeApprovedBookkeepingFamilySample {
  let range: NSRange?
  let replacementUTF16: [UInt16]?
  let currentInvocation: Bool
  let edgeCount: Int
  let primitiveSequence: UInt64?
}
@MainActor extension ApprovedViewCommitBroker {
  var nativeApprovedTestRetainedEntryCount: Int {
    invocations.count + decisions.count + barriers.count
      + (pending == nil ? 0 : 1) + (reserved == nil ? 0 : 1)
  }
  func nativeApprovedTestFamily(_ view: ObjectIdentifier)
    -> NativeApprovedBookkeepingFamilySample?
  {
    guard let current = decisions.last,
      barriers.last?.decision == current.token.id,
      let family = decisions.first(where: { $0.token.id == current.family }),
      family.view == view, let text = family.replacement,
      text.utf16.count <= 4096
    else { return nil }
    return NativeApprovedBookkeepingFamilySample(
      range: family.range,
      replacementUTF16: Array(text.utf16),
      currentInvocation: invocations.last?.token.id == current.invocation,
      edgeCount: family.edgeCount, primitiveSequence: family.snapshot?.primitive.sequence)
  }
}
// MACRO-ApprovedViewCommitBroker-ACCESS-END
// MACRO-DocumentCommitTextStorage-ACCESS-BEGIN
extension DocumentCommitTextStorage {
  var nativeMacroTestPrimitiveSequence: UInt64 { primitiveSequence }
  var nativeMacroTestSequenceExhausted: Bool { primitiveSequenceExhausted }
  var nativeMacroTestLastPrimitiveCommit: PrimitiveCommitObservation? { lastPrimitiveCommit }
}
// MACRO-DocumentCommitTextStorage-ACCESS-END
// MACRO-EditorDocument-ACCESS-BEGIN
// NATIVE-SEARCH-MODEL-ACCESS-BEGIN
extension EditorDocument {
  func nativeSearchTestSeedRevision(_ revision: UInt64) { editRevision = revision }
  var nativeSearchTestExhausted: Bool { searchRevisionExhausted }
}
// NATIVE-SEARCH-MODEL-ACCESS-END
// MACRO-EditorDocument-ACCESS-END
// MACRO-EditorWindowController-ACCESS-BEGIN
// NATIVE-SEARCH-CONTROLLER-ACCESS-BEGIN
extension EditorWindowController {
  func nativeSearchTestSource(document: EditorDocument, pane: EditorPane)
    throws -> EditorDocumentSearchSource
  {
    try makeDocumentSearchSource(document: document, pane: pane)
  }
  var nativeSearchTestCurrent: EditorDocument? { current }
  var nativeSearchTestProposal: Bool { nativeEditPreparation?.commit != nil }
  var nativeSearchTestRecordingID: UUID? { recordingDocumentID }
  var nativeSearchTestCommands: [MacroCommand] { recordedCommands }
  var nativeSearchTestUnits: Int { recordedUnits }
  func nativeSearchTestRecording(_ id: UUID?, commands: [MacroCommand], units: Int) {
    recordingDocumentID = id
    recordedCommands = commands
    recordedUnits = units
  }
  func nativeSearchTestQuitState(_ preparing: Bool) { preparingToQuit = preparing }
  func nativeSearchTestIncompatibleProjection(_ model: EditorDocument) {
    documents = [model]
    selectedID = model.id
  }
  func nativeSearchTestSelectTab(_ index: Int) {
    tabs.selectItem(at: index)
    selectTab()
  }
  func nativeSearchTestCloseNotification() {
    if let window {
      windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }
  }
  func nativeSearchTestTearDown() {
    recoveryDebounce?.cancel()
    recoveryPeriodic?.cancel()
    recoveryWork?.cancel()
    statisticsTask?.cancel()
    if !windowClosed { nativeSearchTestCloseNotification() }
    for document in documents {
      document.onCharactersChanged = nil
      document.canUndoRedo = nil
      for pane in document.panePool {
        pane.editor.delegate = nil
        pane.editor.onFocus = nil
        pane.editor.onTypingRunEnded = nil
        pane.editor.onMarkedTextUpdated = nil
        pane.editor.onCompositionBegan = nil
        pane.editor.onCompositionEnded = nil
        pane.editor.canFocus = nil
        pane.editor.canMutate = nil
        pane.editor.canChangeSelection = nil
        pane.onBoundsChanged = nil
      }
    }
    window?.orderOut(nil)
    window?.delegate = nil
    window?.contentView = nil
    window = nil
    documents = []
    nativeEditPreparation = nil
  }
  func nativeMacroTestSetBookmarks(_ document: EditorDocument, value: DocumentBookmarks) {
    setBookmarks(document, value: value)
  }
}

// NATIVE-SEARCH-CONTROLLER-ACCESS-END

// TASK2A-SCALAR-TEST-ACCESS-BEGIN
@MainActor extension EditorWindowController {
  func nativeMacroTestIntegrityState() -> (
    epoch: UUID?, serial: UInt64, exhausted: Bool, complete: Bool,
    active: Bool, reason: MacroRecordingGap?, bindingCount: Int
  ) {
    (
      recordingIntegrity?.epoch, recordingStateSerial, recordingStateSerialExhausted,
      recordingIntegrity != nil && recordingIntegrity?.firstReason == nil,
      recordingIntegrity?.active ?? false, recordingIntegrity?.firstReason, macroBindings.count
    )
  }
}
// TASK2A-SCALAR-TEST-ACCESS-END

// SPDX-License-Identifier: MIT
// Test-only forwarding and scalar reads; append once to the actual controller file.
struct NativeMacroHelperBookkeepingSnapshot: Equatable {
  let bookmarks: [Int]
  let pending: [Int]?
  let pendingHasUndo: Bool
  let typingNext: Int?
  let composingPaneID: UUID?
}

@MainActor extension EditorWindowController {
  func nativeMacroExistingHelperApply(
    _ document: EditorDocument, pane: EditorPane, expected: String,
    range: NSRange, replacement: String
  ) -> Bool {
    applyNativeTextEdit(
      document, source: pane, expected: expected,
      edit: TextEdit(range: range, replacement: replacement),
      action: "Helper characterization", context: nil, requireFocus: false,
      operationID: nil, cancellation: nil)
  }

  func nativeMacroExistingHelperBookkeeping(
    _ document: EditorDocument
  ) -> NativeMacroHelperBookkeepingSnapshot {
    NativeMacroHelperBookkeepingSnapshot(
      bookmarks: document.bookmarks.offsets,
      pending: document.pendingBookmarks?.offsets,
      pendingHasUndo: document.pendingBookmarksHaveUndo,
      typingNext: document.typingBookmarkNextLocation,
      composingPaneID: document.composingPaneID)
  }
}

// SPDX-License-Identifier: MIT
// TASK2B-NOTICE-C-TEST-ACCESS-BEGIN
struct NativeMacroTask2BNoticeTestState {
  let epoch: UUID?
  let documentID: UUID?
  let active: Bool
  let reason: MacroRecordingGap?
  let pending: Bool
  let serial: UInt64
  let serialExhausted: Bool
  let saving: Bool
  let hasSaveAttempt: Bool
}

@MainActor extension EditorWindowController {
  func nativeMacroTask2BNoticeTestState() -> NativeMacroTask2BNoticeTestState {
    NativeMacroTask2BNoticeTestState(
      epoch: recordingIntegrity?.epoch,
      documentID: recordingIntegrity?.documentID, active: recordingIntegrity?.active ?? false,
      reason: recordingIntegrity?.firstReason, pending: recordingIntegrity?.noticePending ?? false,
      serial: recordingStateSerial, serialExhausted: recordingStateSerialExhausted,
      saving: macroSaving, hasSaveAttempt: recordingSaveAttempt != nil)
  }
}
// TASK2B-NOTICE-C-TEST-ACCESS-END

@MainActor extension EditorWindowController {
  static func nativeApprovedTestBarrierState()
    -> (broker: Int, context: Int, overflow: Bool, contextInstalled: Bool)
  {
    (
      approvedViewBroker.nativeApprovedTestRetainedEntryCount,
      macroCommitContext?.entryCount ?? 0,
      macroCommitContext?.overflowBarrierIsActive ?? false,
      macroCommitContext != nil
    )
  }
  func nativeApprovedTestFamily(_ view: DocumentTextView)
    -> NativeApprovedBookkeepingFamilySample?
  {
    Self.approvedViewBroker.nativeApprovedTestFamily(ObjectIdentifier(view))
  }
}

// SPDX-License-Identifier: MIT
// APPROVED-EXPLICIT-CAPACITY-C-ACCESS-BEGIN
@MainActor extension EditorWindowController {
  static func nativeApprovedTestHasActiveExplicitFrame() -> Bool {
    macroCommitContext?.hasActiveExplicitFrame ?? false
  }
}
// APPROVED-EXPLICIT-CAPACITY-C-ACCESS-END
// MACRO-EditorWindowController-ACCESS-END
// MACRO-NativeMacroCommitContext-ACCESS-BEGIN
// TASK2B-PROCESSING-CONTEXT-TEST-ACCESS-BEGIN
@MainActor extension NativeMacroCommitContext {
  var nativeMacroTask2BTestTopIsCallbackBarrier: Bool {
    guard let entry = entries.last else { return false }
    if case .barrier = entry { return true }
    return false
  }
}
// TASK2B-PROCESSING-CONTEXT-TEST-ACCESS-END
// MACRO-NativeMacroCommitContext-ACCESS-END
