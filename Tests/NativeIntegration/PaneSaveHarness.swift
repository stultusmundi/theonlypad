import AppKit
import PadCore

@main struct CompletedSaveHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var checks = 0
    func check(_ condition: Bool, _ label: String) {
      checks += 1
      guard condition else {
        print("FAIL \(label)")
        exit(1)
      }
      print("PASS \(label)")
    }
    func wait(_ label: String, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
      check(condition(), label)
    }
    let state = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!)
    let file = state.appendingPathComponent("synthetic-existing.txt")
    let original = String(repeating: "x", count: 2_000_001)
    try Data(original.utf8).write(to: file)
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: .init(location: 1, length: 0), scrollOrigin: .init(x: 0, y: 0)),
        .init(selection: .init(location: 2, length: 0), scrollOrigin: .init(x: 0, y: 0)),
      ], focusedPaneIndex: 1)
    let resolved = try RestoredPresentationState.resolve(presentation, bookmarks: [], in: original)
    var errors: [Error] = []
    let controller = EditorWindowController(
      restoreStartup: false, onError: { errors.append($0) }, onSessionChange: {})
    let metadata = SessionTab(originalPath: file.path, presentation: presentation)
    try controller.restoreSessionTab(
      metadata, decoded: .init(text: original, encoding: .utf8, hasBOM: false),
      originalBytes: Data(original.utf8), url: file,
      viewState: resolved.focusedViewState, resolvedPresentation: resolved)
    let document = controller.fixtureDocument(metadata.id)!
    let live = controller.focusedPane!
    check(
      controller.visiblePanes.count == 1 && document.panePresentation.pending != nil,
      "saved over-limit file retains deferred split")
    let replacement = "new exact 😀 e\u{301}\r\ncontent\n"
    document.undoManager.groupsByEvent = false
    document.undoManager.beginUndoGrouping()
    live.editor.insertText(
      replacement, replacementRange: .init(location: 0, length: original.utf16.count))
    document.undoManager.endUndoGrouping()
    check(
      document.dirty && document.undoManager.canUndo, "actual editor mutation is dirty with undo")
    controller.fixtureRestore()
    check(
      document.storage.layoutManagers.count == 2 && document.panePresentation.pending == nil,
      "immediate native edit then restore installs saved split")
    let oldBaseline = document.baselineRevision
    let selection = live.editor.selectedRange()
    let dirtyCapture = try controller.captureSessionCheckpoint()
    check(
      dirtyCapture.recovery.count == 1 && dirtyCapture.recovery[0].id == metadata.id,
      "restored dirty document has one recovery identity")
    check(
      dirtyCapture.recovery[0].snapshot?.text == replacement,
      "recovery captures actual changed buffer")
    controller.execute("file.save")
    check(document.saving && document.operationID != nil, "real save command admitted")
    try await wait("actual asynchronous save completes") {
      !document.saving && document.operationID == nil
    }
    check(errors.isEmpty, "default save services report no failure")
    check(
      try Data(contentsOf: file) == Data(replacement.utf8),
      "AtomicFileStore published exact new disk bytes")
    check(
      document.originalBytes == Data(replacement.utf8)
        && document.savedText.utf16.elementsEqual(replacement.utf16),
      "completed save acknowledges exact byte and text baseline")
    check(
      document.baselineRevision > oldBaseline && !document.dirty,
      "baseline advances and document becomes clean")
    let afterSave = try controller.captureSessionCheckpoint()
    check(
      afterSave.recovery.count == 1 && afterSave.recovery[0].id == metadata.id
        && afterSave.recovery[0].snapshot == nil,
      "clean acknowledgement retains one identity with recovery removal disposition")
    check(
      document.storage.layoutManagers.count == 2 && document.panePresentation.pending == nil,
      "completed save retains restored split")
    check(
      controller.focusedPane === live && live.editor.selectedRange() == selection,
      "current live pane and selection remain unchanged")
    check(
      document.storage.string.utf16.elementsEqual(replacement.utf16)
        && document.undoManager.canUndo,
      "save preserves exact current buffer and undo")
    check(
      try Data(contentsOf: file) == Data(replacement.utf8),
      "completed restoration does not alter saved file")
    // Restore refusal while a real asynchronous save owns the document, followed by explicit retry.
    try controller.collapseToFocusedPane()
    document.panePresentation.pending = .init(
      presentation: presentation,
      livePaneID: live.id, liveSlot: 1, resolvedAtRevision: document.editRevision, presented: true)
    document.undoManager.beginUndoGrouping()
    live.editor.insertText(
      "!", replacementRange: .init(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    controller.execute("file.save")
    check(
      document.saving && document.operationID != nil, "second real save admitted before restore")
    controller.fixtureRestore()
    check(
      document.storage.layoutManagers.count == 1 && document.panePresentation.pending != nil,
      "save-active restore refuses without consuming saved layout")
    try await wait("second actual save completes") {
      !document.saving && document.operationID == nil
    }
    check(
      try Data(contentsOf: file) == Data((replacement + "!").utf8),
      "second save publishes exact bytes")
    check(
      document.panePool.first?.isAttached == false && document.panePool.last === live,
      "collapsed focused slot one reuses a preceding detached pane")
    controller.fixtureRestore()
    check(
      document.storage.layoutManagers.count == 2 && document.panePresentation.pending == nil,
      "explicit restore after completed save succeeds")
    check(
      !document.dirty && document.undoManager.canUndo,
      "restore preserves saved dirty baseline and undo history")
    print(
      "UNDO before level=\(document.undoManager.groupingLevel) length=\(document.storage.length)")
    document.undoManager.undo()
    print(
      "UNDO after level=\(document.undoManager.groupingLevel) length=\(document.storage.length) dirty=\(document.dirty)"
    )
    check(
      document.dirty && document.storage.string.utf16.elementsEqual(replacement.utf16),
      "native undo after save and restoration restores prior exact buffer")
    check(
      try Data(contentsOf: file) == Data((replacement + "!").utf8),
      "undo never rewrites saved disk bytes")
    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    print("PASS completed-save integration \(checks) assertions")
  }
}
