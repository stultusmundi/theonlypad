import AppKit
import PadCore
import XCTest

@testable import NativeRouting

// SEARCH-CONTROLLER-ACCESS-BEGIN
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
  var replacementTestHasProposal: Bool { searchReplacementPreparation?.commit != nil }
  func replacementTestCleanup() {
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

}
