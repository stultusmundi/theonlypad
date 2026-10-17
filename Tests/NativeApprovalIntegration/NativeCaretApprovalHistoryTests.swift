// SPDX-License-Identifier: MIT
// Actual ordinary-caret refusal/history controls; no production API or phase hooks.
private enum CaretHistoryProbeError: Error { case incomplete }
@MainActor private enum CaretHistoryRetained {
  static var probes: [CaretHistoryCustody] = []
}
@MainActor private final class CaretHistoryDelegate: NSObject, NSTextViewDelegate {
  let controller: EditorWindowController
  let editor: DocumentTextView
  var afterRealApproval: (() -> Void)?
  var calls = 0
  var forwardedTrue = false
  var exactRequest = false
  init(controller: EditorWindowController, editor: DocumentTextView) {
    self.controller = controller
    self.editor = editor
  }
  func textView(
    _ textView: NSTextView, shouldChangeTextIn range: NSRange,
    replacementString: String?
  ) -> Bool {
    guard calls < 2 else {
      XCTFail("Finite caret permission count")
      return false
    }
    calls += 1
    exactRequest =
      textView === editor && range == NSRange(location: 1, length: 0)
      && replacementString?.utf16.elementsEqual("T".utf16) == true
    let actual = controller.textView(
      textView, shouldChangeTextIn: range,
      replacementString: replacementString)
    forwardedTrue = actual
    if actual { afterRealApproval?() }
    return actual
  }
}
@MainActor private final class CaretHistoryCustody {
  let fixture: NestedStringFixture
  var delegate: CaretHistoryDelegate?
  var operation: UUID?
  var retained = false
  init(_ fixture: NestedStringFixture) { self.fixture = fixture }
  func unavailable(file: StaticString = #filePath, line: UInt = #line) throws -> Never {
    if !retained {
      retained = true
      CaretHistoryRetained.probes.append(self)
    }
    // Retain exact delegate/token as well as the existing complete fixture latch.
    try fixture.retainIncomplete(file: file, line: line)
  }
}
@MainActor private func caretHistoryProtocol(_ f: NestedStringFixture) -> Bool {
  nestedStringProtocolIsSettled(f.base)
}
@MainActor private func caretHistoryRun(seedRedo: Bool) async throws {
  guard CaretHistoryRetained.probes.isEmpty else {
    XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE")
    throw CaretHistoryProbeError.incomplete
  }
  let f = try await nestedStringFixture()
  let custody = CaretHistoryCustody(f)
  defer { if !custody.retained { f.close() } }
  let controller = f.base.controller!
  let document = f.base.document
  let editor = f.pane.editor
  let manager = document.undoManager
  let storage = document.storage
  let window = try XCTUnwrap(controller.window)
  let ownership = document.ownershipGeneration
  let assignment = f.base.registry.assignment(of: document.id)
  let epoch = controller.nestedStringTestState().epoch
  let original = f.original
  let seeded = "Salpha\nomega"
  let forward: MacroCommand = .replace(location: 0, length: 0, text: "S")
  let inverse: MacroCommand = .replace(location: 0, length: 1, text: "")
  XCTAssertNotNil(epoch)
  XCTAssertTrue(editor.controlledStringOwner === controller)
  XCTAssertTrue(editor.documentUndo === manager && editor.undoManager === manager)
  XCTAssertTrue(editor.delegate === controller)
  XCTAssertTrue(manager.groupsByEvent)
  XCTAssertEqual(manager.runLoopModes, [.default])
  XCTAssertEqual(manager.groupingLevel, 0)
  XCTAssertFalse(manager.canUndo)
  XCTAssertFalse(manager.canRedo)
  guard epoch != nil, editor.controlledStringOwner === controller,
    editor.documentUndo === manager, editor.undoManager === manager,
    editor.delegate === controller, manager.groupsByEvent,
    manager.runLoopModes == [.default], manager.groupingLevel == 0,
    !manager.canUndo, !manager.canRedo, caretHistoryProtocol(f)
  else { try custody.unavailable() }
  let revision = document.editRevision
  editor.setSelectedRange(NSRange(location: 0, length: 0))
  // Genuine production caret route: String + NSNotFound, active actual recorder.
  editor.insertText("S", replacementRange: NSRange(location: NSNotFound, length: 0))
  XCTAssertEqual(document.storage.string, seeded)
  XCTAssertEqual(document.bookmarks.offsets, [0, 7])
  XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
  XCTAssertGreaterThan(document.editRevision, revision)
  XCTAssertEqual(controller.replacementTestCommands, [forward])
  XCTAssertTrue(
    controller.nestedStringTestState().active && controller.nestedStringTestState().complete)
  XCTAssertEqual(controller.nestedStringTestState().epoch, epoch)
  try nestedStringSettled(f)
  XCTAssertTrue(manager.canUndo)
  guard document.storage.string == seeded, document.bookmarks.offsets == [0, 7],
    editor.selectedRange() == NSRange(location: 1, length: 0),
    document.editRevision > revision, controller.replacementTestCommands == [forward],
    controller.nestedStringTestState().active && controller.nestedStringTestState().complete,
    controller.nestedStringTestState().epoch == epoch, manager.canUndo
  else { try custody.unavailable() }  // Seed failure cannot grant the refusal-history premise.
  var commands = [forward]
  if seedRedo {
    manager.undo()
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    XCTAssertEqual(document.storage.string, original)
    XCTAssertEqual(document.bookmarks.offsets, [0, 6])
    commands.append(inverse)
    XCTAssertEqual(controller.replacementTestCommands, commands)
    XCTAssertFalse(manager.canUndo)
    try nestedStringSettled(f)
    XCTAssertTrue(manager.canRedo)
    guard document.storage.string == original, document.bookmarks.offsets == [0, 6],
      controller.replacementTestCommands == commands, !manager.canUndo, manager.canRedo
    else { try custody.unavailable() }  // Genuine native redo must exist before the probe.
  }
  editor.setSelectedRange(NSRange(location: 1, length: 0))
  let expectedText = seedRedo ? original : seeded
  let expectedBookmarks = seedRedo ? [0, 6] : [0, 7]
  let beforeRevision = document.editRevision
  let beforeSelection = editor.selectedRange()
  let delegate = CaretHistoryDelegate(controller: controller, editor: editor)
  custody.delegate = delegate
  var callbacks = 0
  var nestedText: String?
  delegate.afterRealApproval = {
    f.base.admission = {
      f.base.admission = nil
      callbacks += 1
      guard callbacks == 1 else {
        XCTFail("One real caret owner callback")
        return
      }
      // Existing occupied-preparation refusal: no nested window or inherited fallback.
      editor.insertText("N", replacementRange: NSRange(location: NSNotFound, length: 0))
      nestedText = document.storage.string
      custody.operation = document.beginFileOperation()
    }
  }
  editor.delegate = delegate
  guard editor.delegate === delegate, caretHistoryProtocol(f) else { try custody.unavailable() }
  editor.insertText("T", replacementRange: NSRange(location: NSNotFound, length: 0))
  XCTAssertEqual(delegate.calls, 1)
  XCTAssertTrue(delegate.forwardedTrue, "The genuine original preparation returned true")
  XCTAssertTrue(delegate.exactRequest)
  XCTAssertEqual(callbacks, 1)
  XCTAssertEqual(nestedText, expectedText)
  XCTAssertEqual(document.storage.string, expectedText)
  XCTAssertEqual(document.bookmarks.offsets, expectedBookmarks)
  XCTAssertEqual(document.editRevision, beforeRevision)
  XCTAssertEqual(editor.selectedRange(), beforeSelection)
  XCTAssertEqual(controller.replacementTestCommands, commands)
  let state = controller.nestedStringTestState()
  XCTAssertEqual(state.epoch, epoch)
  XCTAssertTrue(state.active && state.complete)
  XCTAssertFalse(state.hasPreparation || state.hasExplicitFrame)
  XCTAssertEqual(document.ownershipGeneration, ownership)
  XCTAssertTrue(f.base.registry.handle(id: document.id) === document)
  XCTAssertEqual(f.base.registry.assignment(of: document.id), assignment)
  XCTAssertTrue(document.storage === storage && editor.textStorage === storage)
  XCTAssertTrue(f.pane.document === document && f.pane.isAttached)
  XCTAssertTrue(controller.window === window && editor.window === window)
  // Match the real returned token and exact Test delegate before any cleanup mutation.
  guard callbacks == 1, delegate.calls == 1, delegate.forwardedTrue, delegate.exactRequest,
    caretHistoryProtocol(f), f.base.admission == nil,
    editor.delegate === delegate, let token = custody.operation,
    document.operationID == token
  else { try custody.unavailable() }
  guard document.finishFileOperation(token), document.operationID == nil,
    caretHistoryProtocol(f), editor.delegate === delegate
  else { try custody.unavailable() }
  custody.operation = nil
  editor.delegate = controller
  guard editor.delegate === controller, caretHistoryProtocol(f) else { try custody.unavailable() }
  custody.delegate = nil
  delegate.afterRealApproval = nil
  try nestedStringSettled(f)  // Actual automatic1 -> event witness -> strict0, never manual close.
  if seedRedo {
    let available = manager.canRedo
    XCTAssertTrue(available, "Refused caret must preserve the genuine seeded redo")
    XCTAssertFalse(manager.canUndo, "Refusal must not add a ghost undo action")
    // Failed assertion remains ordinary; unavailable redo is unentered.
    guard available else { return }
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    manager.redo()
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    commands.append(forward)
    XCTAssertEqual(document.storage.string, seeded)
    XCTAssertEqual(document.bookmarks.offsets, [0, 7])
    XCTAssertEqual(controller.replacementTestCommands, commands)
    XCTAssertTrue(manager.canUndo)
    XCTAssertFalse(manager.canRedo)
  } else {
    let available = manager.canUndo
    XCTAssertTrue(available, "Refused caret must preserve the genuine seeded undo")
    // Failed assertion remains ordinary; unavailable undo is unentered.
    guard available else { return }
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    manager.undo()
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    commands.append(inverse)
    XCTAssertEqual(document.storage.string, original)
    XCTAssertEqual(document.bookmarks.offsets, [0, 6])
    XCTAssertEqual(controller.replacementTestCommands, commands)
    XCTAssertFalse(manager.canUndo, "Only the seed action existed before refused caret")
    try nestedStringSettled(f)
    let redoAvailable = manager.canRedo
    XCTAssertTrue(redoAvailable)
    guard redoAvailable else { return }
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    manager.redo()
    guard caretHistoryProtocol(f), editor.delegate === controller else { try custody.unavailable() }
    commands.append(forward)
    XCTAssertEqual(document.storage.string, seeded)
    XCTAssertEqual(document.bookmarks.offsets, [0, 7])
    XCTAssertEqual(controller.replacementTestCommands, commands)
    XCTAssertTrue(manager.canUndo)
    XCTAssertFalse(manager.canRedo)
  }
  try nestedStringSettled(f)
  XCTAssertEqual(controller.nestedStringTestState().epoch, epoch)
  XCTAssertTrue(controller.nestedStringTestState().complete)
  XCTAssertEqual(document.ownershipGeneration, ownership)
  try nestedStringReplay(controller.replacementTestCommands, from: original, to: seeded)
  withExtendedLifetime(delegate) {}
}
@MainActor final class NativeCaretApprovalHistoryTests: XCTestCase {
  func testOwnerReentryRefusesCaretWithoutAddingGhostToSeededUndo() async throws {
    try await caretHistoryRun(seedRedo: false)
  }
  func testOwnerReentryRefusesCaretWithoutDestroyingSeededRedo() async throws {
    try await caretHistoryRun(seedRedo: true)
  }
}
