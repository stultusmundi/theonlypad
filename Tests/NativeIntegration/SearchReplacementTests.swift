import AppKit
import PadCore
import XCTest

@testable import NativeRouting

// SEARCH-CONTROLLER-ACCESS-BEGIN
@MainActor enum NativeEditTestCompletion {
  static var finish: (() -> Void)?
}
extension EditorWindowController {
  func replacementTestDocument(_ text: String) -> EditorDocument {
    newDocument()
    let document = current!
    document.storage.mutableString.setString(text)
    return document
  }
  func replacementTestPanel() -> SearchPanelController? {
    showSearch()
    return searchPanel
  }
  func replacementTestStartRecording(_ document: EditorDocument) {
    recordingDocumentID = document.id
    recordedCommands = []
    recordedUnits = 0
  }
  var replacementTestCommands: [MacroCommand] { recordedCommands }
  var replacementTestReplayActive: Bool { replayCancellation != nil }
  var replacementTestHasProposal: Bool { nativeEditPreparation?.commit != nil }
  func replacementTestTransform(
    _ document: EditorDocument, source: EditorPane, expected: String, replacement: String,
    edit: TextEdit? = nil
  ) -> Bool {
    replaceDocumentText(
      document, source: source, expected: expected, replacement: replacement,
      action: "Synthetic Transform", edit: edit)
  }
  func replacementTestCommand(
    operation: @escaping @Sendable (String, NSRange) throws -> LineCommandResult,
    finished: @escaping () -> Void
  ) {
    NativeEditTestCompletion.finish = finished
    performDocumentCommand("Synthetic Async Transform", operation: operation)
  }
  func replacementTestLineEndings(
    _ document: EditorDocument, source: EditorPane, finished: @escaping () -> Void
  ) {
    NativeEditTestCompletion.finish = finished
    convertLineEndings(document, source: source, to: .crlf)
  }
  func replacementTestReplay(
    _ macro: EditorMacro, finished: @escaping () -> Void
  ) -> MacroCancellation? {
    NativeEditTestCompletion.finish = finished
    replay(macro, repeatCount: 1)
    return replayCancellation
  }
  func replacementTestJSON(_ replacement: String, finished: @escaping () -> Void) {
    formatJSON(operation: { _ in replacement }, onFinish: finished)
  }
  func replacementTestUtilities() -> TextUtilitiesController? {
    showTextUtilities()
    return textUtilities
  }
  func replacementTestCleanup() {
    textUtilities?.close()
    textUtilities = nil
    NativeEditTestCompletion.finish = nil
    searchPanel?.close()
    searchPanel = nil
    window?.orderOut(nil)
  }
}
// SEARCH-CONTROLLER-ACCESS-END

// SEARCH-PANEL-ACCESS-BEGIN
extension SearchPanelController {
  func replacementTestApply(expected: String, replacement: String) -> Bool {
    replace(expected, replacement)
  }
}
// SEARCH-PANEL-ACCESS-END

// SEARCH-UTILITY-ACCESS-BEGIN
extension TextUtilitiesController {
  func replacementTestApply(_ replacement: String) { onReplace(replacement) }
}
// SEARCH-UTILITY-ACCESS-END

@MainActor private final class ReentrantReplacementDelegate: NSObject, NSTextViewDelegate {
  var change: () -> Bool
  init(change: @escaping () -> Bool) { self.change = change }
  func textView(
    _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    change()
  }
}

@MainActor private final class ReplacementFixture {
  let controller: EditorWindowController
  let document: EditorDocument
  let pane: EditorPane
  let panel: SearchPanelController
  let original = "alpha\nomega"
  init() throws {
    _ = NSApplication.shared
    controller = EditorWindowController(
      restoreStartup: false, onError: { XCTFail("Unexpected native error: \($0)") },
      onSessionChange: {})
    document = controller.replacementTestDocument(original)
    pane = try XCTUnwrap(controller.visiblePanes.first)
    panel = try XCTUnwrap(controller.replacementTestPanel())
  }
  func apply(_ replacement: String = "replacement") -> Bool {
    panel.replacementTestApply(expected: original, replacement: replacement)
  }
  func close() { controller.replacementTestCleanup() }
}

@MainActor private final class ManagedReplacementFixture {
  let registry: ApplicationDocuments
  let recovery: RecoveryCoordinator
  let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let endpointID = UUID()
  let document = EditorDocument()
  var controller: EditorWindowController!
  var admission: (() -> Void)?
  init() async throws {
    _ = NSApplication.shared
    recovery = RecoveryCoordinator(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { handle in
          let model = handle as! EditorDocument
          return .init(
            documentID: model.id, ownershipGeneration: model.ownershipGeneration,
            authority: model.recoveryAuthority,
            highestIssuedRevision: model.highestIssuedRecoveryRevision)
        }))
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    document.storage.mutableString.setString("alpha\nomega")
    let ticket = try registry.registerPending(
      document, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: false), in: assignment, at: 0, select: true)
    let adoption = try await recovery.adoptManagedDocument(id: document.id)
    try document.installRecoveryAdoption(
      adoption, expectedOwnershipGeneration: document.ownershipGeneration)
    try registry.activateAdoption(ticket, receipt: adoption)
    let routing = EditorApplicationRouting(
      endpointID: endpointID, assignment: assignment, registry: registry,
      requireEndpointCurrent: {}, requireUserAdmission: { [weak self] in self?.admission?() },
      submit: { _ in throw EditorApplicationRoutingError.unsupportedSeed },
      wait: { _ in throw EditorApplicationRoutingError.unsupportedSeed },
      requestClose: { _ in throw EditorApplicationRoutingError.unsupportedSeed },
      requestReopen: { throw EditorApplicationRoutingError.unsupportedSeed },
      detachDocumentEndpoint: { _ in }, reattachDocumentEndpoint: { _, _, _ in },
      endpointClosed: { _ in }, requestCheckpoint: {})
    controller = try EditorWindowController(
      id: assignment.windowID, application: routing,
      onError: { XCTFail("Unexpected native error: \($0)") })
    try controller.applyRegistryProjection(
      registry.window(id: assignment.windowID)!, revision: registry.workspaceRevision,
      endpointID: endpointID)
  }
}

@MainActor final class SearchReplacementTests: XCTestCase {
  func testSameLengthDelegateEditRefusesStaleReplaceAll() throws {
    _ = NSApplication.shared
    let controller = EditorWindowController(
      restoreStartup: false, onError: { XCTFail("Unexpected native error: \($0)") },
      onSessionChange: {})
    defer { controller.replacementTestCleanup() }
    let original = "alpha\nomega"
    let changed = "bravo\ndelta"
    let document = controller.replacementTestDocument(original)
    let pane = try XCTUnwrap(controller.visiblePanes.first)
    let panel = try XCTUnwrap(controller.replacementTestPanel())
    var callbacks = 0
    let delegate = ReentrantReplacementDelegate {
      callbacks += 1
      document.storage.mutableString.setString(changed)
      return true
    }
    pane.editor.delegate = delegate
    let accepted = panel.replacementTestApply(expected: original, replacement: "replacement")
    XCTAssertEqual(callbacks, 1)
    XCTAssertFalse(accepted)
    XCTAssertEqual(document.storage.string, changed)
    XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    XCTAssertFalse(try XCTUnwrap(panel.window).isVisible)
  }

  func testDetachedDelegateTargetRefusesReplacement() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let delegate = ReentrantReplacementDelegate {
      f.pane.detach()
      return true
    }
    f.pane.editor.delegate = delegate
    XCTAssertFalse(f.apply())
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertFalse(f.pane.isAttached)
  }

  func testSavingDuringDelegateRefusesReplacement() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let delegate = ReentrantReplacementDelegate {
      f.document.saving = true
      return true
    }
    f.pane.editor.delegate = delegate
    XCTAssertFalse(f.apply())
    XCTAssertEqual(f.document.storage.string, f.original)
  }

  func testEditThenRestoreDuringDelegateStillRefusesOldRevision() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let delegate = ReentrantReplacementDelegate {
      f.document.storage.mutableString.setString("bravo\ndelta")
      f.document.storage.mutableString.setString(f.original)
      return true
    }
    f.pane.editor.delegate = delegate
    XCTAssertFalse(f.apply())
    XCTAssertEqual(f.document.storage.string, f.original)
  }

  func testDelegateRefusalPreservesTextAndExistingUndo() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    var originalUndo = 0
    f.document.undoManager.registerUndo(withTarget: f.document) { _ in originalUndo += 1 }
    let delegate = ReentrantReplacementDelegate { false }
    f.pane.editor.delegate = delegate
    XCTAssertFalse(f.apply())
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertTrue(f.document.undoManager.canUndo)
    f.document.undoManager.undo()
    XCTAssertEqual(originalUndo, 1)
  }

  func testRealDelegateReplaceAllPreservesSingleStepUnicodeUndoRedo() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let replacement = "😀\ne\u{301} Ω"
    XCTAssertTrue(f.pane.editor.delegate === f.controller)
    XCTAssertTrue(f.apply(replacement))
    XCTAssertEqual(f.document.storage.string, replacement)
    XCTAssertEqual(f.document.undoManager.undoActionName, "Replace All")
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, f.original)
    f.document.undoManager.redo()
    XCTAssertEqual(f.document.storage.string, replacement)
  }

  func testRealDelegateBookkeepingIsNotCommittedAfterUndoBoundaryReentry() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.controller.replacementTestStartRecording(f.document)
    var callbackCount = 0
    f.pane.editor.onTypingRunEnded = {
      guard callbackCount == 0 else { return }
      callbackCount += 1
      f.document.storage.mutableString.setString("bravo\ndelta")
    }
    XCTAssertFalse(f.apply())
    XCTAssertEqual(callbackCount, 1)
    XCTAssertEqual(f.document.storage.string, "bravo\ndelta")
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
  }

  func testPendingSameTextDelegateEditRefusesUnprocessedMutation() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let revision = f.document.editRevision
    var editing = false
    let delegate = ReentrantReplacementDelegate {
      f.document.storage.beginEditing()
      editing = true
      f.document.storage.replaceCharacters(
        in: NSRange(location: 0, length: f.original.utf16.count), with: f.original)
      return true
    }
    f.pane.editor.delegate = delegate
    defer { if editing { f.document.storage.endEditing() } }
    XCTAssertFalse(f.apply())
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.document.editRevision, revision)
    XCTAssertTrue(f.document.storage.editedMask.contains(.editedCharacters))
  }

  func testPostDelegateAuthorityCallbackPreservesOwnUndoAndMacroOnly() async throws {
    let f = try await ManagedReplacementFixture()
    defer { f.controller.replacementTestCleanup() }
    let pane = try XCTUnwrap(f.controller.visiblePanes.first)
    let panel = try XCTUnwrap(f.controller.replacementTestPanel())
    f.controller.replacementTestStartRecording(f.document)
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 6], in: "alpha\nomega")
    var callbackCount = 0
    let forwarding = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        pane.editor, shouldChangeTextIn: NSRange(location: 0, length: 11),
        replacementString: "replacement")
      // Install only after actual controller admission returned. The next owner check
      // is the outer search callback's post-shouldChange validation.
      f.admission = {
        f.admission = nil
        callbackCount += 1
        pane.editor.delegate = f.controller
        pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
      }
      return admitted
    }
    pane.editor.delegate = forwarding
    XCTAssertFalse(panel.replacementTestApply(expected: "alpha\nomega", replacement: "replacement"))
    XCTAssertEqual(callbackCount, 1)
    XCTAssertEqual(f.document.storage.string, "Xlpha\nomega")
    XCTAssertEqual(
      f.controller.replacementTestCommands, [.replace(location: 0, length: 1, text: "X")])
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, "alpha\nomega")
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(f.document.undoManager.canUndo, "No unapplied outer edit may remain in history")
  }

  func testNestedIdenticalDelegateCallKeepsItsOwnMacroAndUndo() async throws {
    let f = try await ManagedReplacementFixture()
    defer { f.controller.replacementTestCleanup() }
    let pane = try XCTUnwrap(f.controller.visiblePanes.first)
    let panel = try XCTUnwrap(f.controller.replacementTestPanel())
    f.controller.replacementTestStartRecording(f.document)
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 6], in: "alpha\nomega")
    var callbackCount = 0
    let forwarding = ReentrantReplacementDelegate {
      f.admission = {
        f.admission = nil
        callbackCount += 1
        pane.editor.delegate = f.controller
        pane.editor.insertText("replacement", replacementRange: NSRange(location: 0, length: 11))
      }
      return f.controller.textView(
        pane.editor, shouldChangeTextIn: NSRange(location: 0, length: 11),
        replacementString: "replacement")
    }
    pane.editor.delegate = forwarding
    XCTAssertFalse(panel.replacementTestApply(expected: "alpha\nomega", replacement: "replacement"))
    XCTAssertEqual(callbackCount, 1)
    XCTAssertEqual(f.document.storage.string, "replacement")
    XCTAssertEqual(
      f.controller.replacementTestCommands, [.replace(location: 0, length: 11, text: "replacement")]
    )
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, "alpha\nomega")
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(f.document.undoManager.canUndo)
  }

  func testSuccessfulReplacementCommitsBookmarksAndOneMacroWithUndo() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 6], in: f.original)
    f.controller.replacementTestStartRecording(f.document)
    XCTAssertTrue(f.apply())
    XCTAssertEqual(f.document.bookmarks.offsets, [])
    XCTAssertEqual(
      f.controller.replacementTestCommands, [.replace(location: 0, length: 11, text: "replacement")]
    )
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 6])
    f.document.undoManager.redo()
    XCTAssertEqual(f.document.storage.string, "replacement")
    XCTAssertEqual(f.document.bookmarks.offsets, [])
  }

  func testUndoGroupCallbackCannotPublishPreparedSearchBookkeeping() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.controller.replacementTestStartRecording(f.document)
    var callbackCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: .NSUndoManagerDidOpenUndoGroup, object: f.document.undoManager, queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        guard callbackCount == 0, f.controller.replacementTestHasProposal else { return }
        callbackCount += 1
        f.document.storage.mutableString.setString("bravo\ndelta")
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    XCTAssertFalse(f.apply())
    XCTAssertEqual(callbackCount, 1)
    XCTAssertEqual(f.document.storage.string, "bravo\ndelta")
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
  }

  func testJSONSuccessAllowsSelectionChangeAndRetainsSingleUndo() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "successful JSON completion")
    let replacement = "{\"x\":1}"
    f.controller.replacementTestStartRecording(f.document)
    let delegate = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        f.pane.editor, shouldChangeTextIn: NSRange(location: 0, length: 11),
        replacementString: replacement)
      f.pane.editor.setSelectedRange(NSRange(location: 2, length: 0))
      return admitted
    }
    f.pane.editor.delegate = delegate
    f.controller.replacementTestJSON(replacement) { finished.fulfill() }
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(f.document.storage.string, replacement)
    XCTAssertEqual(
      f.controller.replacementTestCommands,
      [.replace(location: 0, length: 11, text: replacement)])
    XCTAssertEqual(f.document.undoManager.undoActionName, "Format JSON")
    f.pane.editor.delegate = f.controller
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertFalse(f.document.undoManager.canUndo)
  }

  func testReplaySuccessRetainsActionBookmarksAndSingleUndo() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "successful actual replay finished")
    let macro = EditorMacro(
      name: "Synthetic Replay",
      commands: [
        .replace(location: 6, length: 5, text: "OMEGA")
      ])
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 6], in: f.original)
    var completions = 0
    let cancellation = f.controller.replacementTestReplay(macro) {
      completions += 1
      finished.fulfill()
    }
    XCTAssertNotNil(cancellation)
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(f.document.storage.string, "alpha\nOMEGA")
    XCTAssertEqual(f.document.bookmarks.offsets, [])
    XCTAssertEqual(f.document.undoManager.undoActionName, macro.name)
    XCTAssertNil(f.document.operationID)
    XCTAssertFalse(f.document.saving)
    XCTAssertFalse(f.controller.replacementTestReplayActive)
    XCTAssertFalse(try XCTUnwrap(cancellation).isCancelled)
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(f.document.undoManager.canUndo)
    f.document.undoManager.redo()
    XCTAssertEqual(f.document.storage.string, "alpha\nOMEGA")
    XCTAssertEqual(f.document.bookmarks.offsets, [])
  }

  func testReplayRefusesReentrantNativeDelegateTextChange() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "actual replay defer finished")
    let macro = EditorMacro(
      name: "Synthetic Replay",
      commands: [
        .replace(location: 6, length: 5, text: "OMEGA")
      ])
    var callbacks = 0
    let delegate = ReentrantReplacementDelegate {
      callbacks += 1
      f.document.storage.mutableString.setString("bravo\ndelta")
      return true
    }
    f.pane.editor.delegate = delegate
    XCTAssertNotNil(f.controller.replacementTestReplay(macro) { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(callbacks, 1)
    XCTAssertEqual(f.document.storage.string, "bravo\ndelta")
    XCTAssertNil(f.document.operationID)
  }

  func testReplayRefusesOriginalCancellationDuringNativeDelegate() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "cancelled replay defer finished")
    let macro = EditorMacro(
      name: "Synthetic Replay",
      commands: [
        .replace(location: 6, length: 5, text: "OMEGA")
      ])
    var cancellation: MacroCancellation?
    var callbacks = 0
    let delegate = ReentrantReplacementDelegate {
      callbacks += 1
      XCTAssertFalse(f.controller.replacementTestReplayActive)
      cancellation?.cancel()
      return true
    }
    f.pane.editor.delegate = delegate
    cancellation = f.controller.replacementTestReplay(macro) { finished.fulfill() }
    XCTAssertNotNil(cancellation)
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(callbacks, 1)
    XCTAssertTrue(try XCTUnwrap(cancellation).isCancelled)
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertNil(f.document.operationID)
  }

  func testReplayPreservesNewerOperationAfterAdmissionCallback() async throws {
    let f = try await ManagedReplacementFixture()
    defer { f.controller.replacementTestCleanup() }
    let original = f.document.storage.string
    let finished = expectation(description: "superseded replay defer finished")
    let macro = EditorMacro(
      name: "Synthetic Replay",
      commands: [
        .replace(location: 6, length: 5, text: "OMEGA")
      ])
    var newerOperation: UUID?
    f.admission = {
      guard f.document.operationID != nil, !f.document.saving, newerOperation == nil else { return }
      newerOperation = f.document.beginFileOperation()
    }
    XCTAssertNotNil(f.controller.replacementTestReplay(macro) { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertNotNil(newerOperation)
    XCTAssertEqual(f.document.operationID, newerOperation)
    XCTAssertEqual(f.document.storage.string, original)
    if let newerOperation { XCTAssertTrue(f.document.finishFileOperation(newerOperation)) }
  }

  func testTextUtilityUnicodePartialSuccessPreservesRangeBookmarksAndUndo() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let original = "pre\n😀old\npost"
    f.document.storage.mutableString.setString(original)
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 4, 10], in: original)
    f.pane.editor.setSelectedRange(NSRange(location: 6, length: 3))
    let utility = try XCTUnwrap(f.controller.replacementTestUtilities())
    f.controller.replacementTestStartRecording(f.document)
    utility.replacementTestApply("🌟new")
    XCTAssertEqual(f.document.storage.string, "pre\n😀🌟new\npost")
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 6, length: 5))
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 4, 12])
    XCTAssertEqual(
      f.controller.replacementTestCommands,
      [.replace(location: 6, length: 3, text: "🌟new")])
    XCTAssertEqual(f.document.undoManager.undoActionName, "Text Conversion")
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, original)
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 4, 10])
    XCTAssertFalse(f.document.undoManager.canUndo)
    f.document.undoManager.redo()
    XCTAssertEqual(f.document.storage.string, "pre\n😀🌟new\npost")
  }

  func testTextUtilityPartialNoOpRetainsExistingBookmarkBookkeepingSemantics() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 6], in: f.original)
    f.pane.editor.setSelectedRange(NSRange(location: 6, length: 5))
    let utility = try XCTUnwrap(f.controller.replacementTestUtilities())
    var noOpMarkers: [Bool] = []
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: f.document.storage, queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        guard f.document.storage.editedMask.contains(.editedCharacters) else { return }
        noOpMarkers.append(f.document.pendingBookmarksHaveUndo)
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    utility.replacementTestApply("omega")
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 6])
    XCTAssertEqual(noOpMarkers, [true])
    XCTAssertNil(f.document.pendingBookmarks)
    XCTAssertFalse(f.document.pendingBookmarksHaveUndo)
  }

  func testJSONActualCompletionRefusesReentrantDelegateTextChange() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "actual JSON completion finished")
    let replacement = "{\"x\":1}"
    f.controller.replacementTestStartRecording(f.document)
    var callbacks = 0
    var completions = 0
    let delegate = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        f.pane.editor, shouldChangeTextIn: NSRange(location: 0, length: 11),
        replacementString: replacement)
      callbacks += 1
      f.document.storage.mutableString.setString("bravo\ndelta")
      return admitted
    }
    f.pane.editor.delegate = delegate
    f.controller.replacementTestJSON(replacement) {
      completions += 1
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(callbacks, 1)
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(f.document.storage.string, "bravo\ndelta")
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
  }

  func testLineEndingSuccessRetainsMinimalMacroAndSingleUndo() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "successful line-ending defer finished")
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 6], in: f.original)
    f.controller.replacementTestStartRecording(f.document)
    f.controller.replacementTestLineEndings(f.document, source: f.pane) { finished.fulfill() }
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(f.document.storage.string, "alpha\r\nomega")
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 7])
    XCTAssertEqual(
      f.controller.replacementTestCommands,
      [.replace(location: 5, length: 0, text: "\r")])
    XCTAssertNil(f.document.operationID)
    XCTAssertEqual(f.document.undoManager.undoActionName, "Convert Line Endings")
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(f.document.undoManager.canUndo)
  }

  func testTextUtilityRefusesReentrantNativeTextChange() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.pane.editor.setSelectedRange(NSRange(location: 6, length: 5))
    let utility = try XCTUnwrap(f.controller.replacementTestUtilities())
    f.controller.replacementTestStartRecording(f.document)
    var calls = 0
    let delegate = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        f.pane.editor, shouldChangeTextIn: NSRange(location: 6, length: 5),
        replacementString: "OMEGA")
      calls += 1
      f.document.storage.mutableString.setString("bravo\ndelta")
      f.pane.editor.setSelectedRange(NSRange(location: 3, length: 0))
      return admitted
    }
    f.pane.editor.delegate = delegate
    utility.replacementTestApply("OMEGA")
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(f.document.storage.string, "bravo\ndelta")
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
    XCTAssertFalse(try XCTUnwrap(utility.window).isVisible)
  }

  func testTextUtilityRefusesSelectionChangeDuringNativeDelegate() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.pane.editor.setSelectedRange(NSRange(location: 6, length: 5))
    let utility = try XCTUnwrap(f.controller.replacementTestUtilities())
    f.controller.replacementTestStartRecording(f.document)
    let delegate = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        f.pane.editor, shouldChangeTextIn: NSRange(location: 6, length: 5),
        replacementString: "OMEGA")
      f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
      return admitted
    }
    f.pane.editor.delegate = delegate
    utility.replacementTestApply("OMEGA")
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 0, length: 0))
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
  }

  func testAsyncCommandSuccessRetainsSelectionMacroAndUndo() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "successful actual command finished")
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    f.controller.replacementTestStartRecording(f.document)
    f.controller.replacementTestCommand(
      operation: { _, _ in
        LineCommandResult(text: "alpha\nOMEGA", selection: NSRange(location: 8, length: 0))
      }, finished: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(f.document.storage.string, "alpha\nOMEGA")
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 8, length: 0))
    XCTAssertEqual(
      f.controller.replacementTestCommands,
      [.replace(location: 6, length: 5, text: "OMEGA")])
    XCTAssertNil(f.document.operationID)
    XCTAssertFalse(f.document.saving)
    XCTAssertEqual(f.document.undoManager.undoActionName, "Synthetic Async Transform")
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertFalse(f.document.undoManager.canUndo)
  }

  func testNoOpAsyncCommandSuccessStillInstallsResultSelection() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "successful no-op command finished")
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    f.controller.replacementTestCommand(
      operation: { text, _ in
        LineCommandResult(text: text, selection: NSRange(location: 2, length: 0))
      }, finished: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 2, length: 0))
    XCTAssertNil(f.document.operationID)
    XCTAssertFalse(f.document.undoManager.canUndo)
  }

  func testLineEndingConversionRefusesNewerOperationAfterAdmissionCallback() async throws {
    let f = try await ManagedReplacementFixture()
    defer { f.controller.replacementTestCleanup() }
    let pane = try XCTUnwrap(f.controller.visiblePanes.first)
    let original = f.document.storage.string
    let finished = expectation(description: "line-ending actual defer finished")
    var newerOperation: UUID?
    f.admission = {
      guard f.document.operationID != nil, !f.document.saving, newerOperation == nil else { return }
      newerOperation = f.document.beginFileOperation()
    }
    f.controller.replacementTestLineEndings(f.document, source: pane) { finished.fulfill() }
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertNotNil(newerOperation)
    XCTAssertEqual(f.document.operationID, newerOperation)
    XCTAssertEqual(f.document.storage.string, original)
    XCTAssertFalse(f.document.undoManager.canUndo)
    if let newerOperation { XCTAssertTrue(f.document.finishFileOperation(newerOperation)) }
  }

  func testAsyncCommandRefusesSelectionChangedDuringNativeDelegate() async throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let finished = expectation(description: "actual command defer finished")
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    f.controller.replacementTestStartRecording(f.document)
    var callbacks = 0
    let delegate = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        f.pane.editor, shouldChangeTextIn: NSRange(location: 6, length: 5),
        replacementString: "OMEGA")
      callbacks += 1
      f.pane.editor.setSelectedRange(NSRange(location: 3, length: 0))
      return admitted
    }
    f.pane.editor.delegate = delegate
    f.controller.replacementTestCommand(
      operation: { _, _ in
        LineCommandResult(text: "alpha\nOMEGA", selection: NSRange(location: 8, length: 0))
      }, finished: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(callbacks, 1)
    XCTAssertEqual(f.document.storage.string, f.original)
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
    XCTAssertNil(f.document.operationID)
  }

  func testNoOpAsyncCommandPreservesNewerOperationAndCaret() async throws {
    let f = try await ManagedReplacementFixture()
    defer { f.controller.replacementTestCleanup() }
    let pane = try XCTUnwrap(f.controller.visiblePanes.first)
    let original = f.document.storage.string
    pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    let finished = expectation(description: "no-op actual command defer finished")
    var newerOperation: UUID?
    f.admission = {
      guard f.document.operationID != nil, !f.document.saving, newerOperation == nil else { return }
      newerOperation = f.document.beginFileOperation()
    }
    f.controller.replacementTestCommand(
      operation: { text, _ in
        LineCommandResult(text: text, selection: NSRange(location: 2, length: 0))
      }, finished: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertNotNil(newerOperation)
    XCTAssertEqual(f.document.operationID, newerOperation)
    XCTAssertEqual(f.document.storage.string, original)
    XCTAssertEqual(pane.editor.selectedRange(), NSRange(location: 0, length: 0))
    if let newerOperation { XCTAssertTrue(f.document.finishFileOperation(newerOperation)) }
  }

  func testPartialUnicodeTransformPreservesMacroRangeBookmarksAndSingleUndo() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let original = "head\n😀one\ntail"
    let result = "head\n😀two\ntail"
    f.document.storage.mutableString.setString(original)
    f.document.bookmarks = try DocumentBookmarks(offsets: [0, 5, 11], in: original)
    f.controller.replacementTestStartRecording(f.document)
    XCTAssertTrue(
      f.controller.replacementTestTransform(
        f.document, source: f.pane, expected: original, replacement: result))
    XCTAssertEqual(f.document.storage.string, result)
    XCTAssertEqual(
      f.controller.replacementTestCommands,
      [.replace(location: 7, length: 3, text: "two")])
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 5, 11])
    XCTAssertEqual(f.document.undoManager.undoActionName, "Synthetic Transform")
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, original)
    XCTAssertEqual(f.document.bookmarks.offsets, [0, 5, 11])
    XCTAssertFalse(f.document.undoManager.canUndo)
    f.document.undoManager.redo()
    XCTAssertEqual(f.document.storage.string, result)
  }

  func testInvalidPartialRangesRefuseBeforeDelegateOrMacro() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let original = "A😀B"
    f.document.storage.mutableString.setString(original)
    f.controller.replacementTestStartRecording(f.document)
    var calls = 0
    let delegate = ReentrantReplacementDelegate {
      calls += 1
      return true
    }
    f.pane.editor.delegate = delegate
    for range in [
      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
      NSRange(location: Int.max, length: 1), NSRange(location: 1, length: Int.max),
      NSRange(location: 5, length: 0), NSRange(location: 2, length: 0),
      NSRange(location: 1, length: 1),
    ] {
      XCTAssertFalse(
        f.controller.replacementTestTransform(
          f.document, source: f.pane, expected: original, replacement: "changed",
          edit: TextEdit(range: range, replacement: "x")))
    }
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(f.document.storage.string, original)
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
  }

  func testScalarBoundaryInsideGraphemeRemainsEditableAndNoOpWrapperRefuses() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    let original = "ae\u{301}z"
    f.document.storage.mutableString.setString(original)
    f.controller.replacementTestStartRecording(f.document)
    XCTAssertFalse(
      f.controller.replacementTestTransform(
        f.document, source: f.pane, expected: original, replacement: original))
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
    XCTAssertTrue(
      f.controller.replacementTestTransform(
        f.document, source: f.pane, expected: original, replacement: "ae\u{300}z",
        edit: TextEdit(range: NSRange(location: 2, length: 1), replacement: "\u{300}")))
    XCTAssertEqual(f.document.storage.string, "ae\u{300}z")
    XCTAssertEqual(
      f.controller.replacementTestCommands,
      [.replace(location: 2, length: 1, text: "\u{300}")])
    f.document.undoManager.undo()
    XCTAssertEqual(f.document.storage.string, original)
  }

  func testDocumentTransformRefusesReentrantEditWithoutPublishingOuterMacro() throws {
    let f = try ReplacementFixture()
    defer { f.close() }
    f.controller.replacementTestStartRecording(f.document)
    var callbackCount = 0
    let delegate = ReentrantReplacementDelegate {
      let admitted = f.controller.textView(
        f.pane.editor, shouldChangeTextIn: NSRange(location: 6, length: 5),
        replacementString: "OMEGA")
      callbackCount += 1
      f.document.storage.mutableString.setString("bravo\ndelta")
      return admitted
    }
    f.pane.editor.delegate = delegate
    XCTAssertFalse(
      f.controller.replacementTestTransform(
        f.document, source: f.pane, expected: f.original, replacement: "alpha\nOMEGA"))
    XCTAssertEqual(callbackCount, 1)
    XCTAssertEqual(f.document.storage.string, "bravo\ndelta")
    XCTAssertTrue(f.controller.replacementTestCommands.isEmpty)
  }

}
