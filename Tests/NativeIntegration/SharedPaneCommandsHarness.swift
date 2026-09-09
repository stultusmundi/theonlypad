// The native test script appends this file to a temporary controller source copy.
// Same-file fixtures exercise private callbacks without widening the production API.
import AppKit
import PadCore

final class TransformGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var released = false
  private var entered = false
  var hasEntered: Bool {
    condition.lock()
    defer { condition.unlock() }
    return entered
  }
  func suspend() {
    condition.lock()
    entered = true
    condition.broadcast()
    while !released { condition.wait() }
    condition.unlock()
  }
  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

extension EditorWindowController {
  // This fixture is a same-file test helper, NOT a proposed production testing API.
  // Task2 installs both views in the existing hidden host, without requiring Task3 NSSplitView.
  @MainActor static func fixture(
    errors: @escaping (Error) -> Void, services: EditorSaveServices = EditorSaveServices(),
    destination: URL? = nil
  ) throws -> (EditorWindowController, EditorPane, EditorPane) {
    let controller = EditorWindowController(
      restoreStartup: false, saveServices: services,
      chooseSaveDestination: destination.map { value in { _, _ in value } },
      onError: errors, onSessionChange: {})
    controller.newDocument()
    let document = controller.documents[0]
    let left = document.panePool[0]
    let right = try document.makePane()
    // Proposed ordinary production helper called for every pane once:
    controller.installCallbacks(for: right)
    controller.host.addSubview(right.scroll)
    right.scroll.frame = NSRect(x: 450, y: 0, width: 450, height: 600)
    left.scroll.frame = NSRect(x: 0, y: 0, width: 450, height: 600)
    try controller.focusPane(id: left.id)
    return (controller, left, right)
  }

  func routingPanel(_ kind: String) -> NSWindowController? {
    if kind == "find" { return searchPanel }
    return outline
  }
  func runGatedEncoding(_ gate: TransformGate, finished: @escaping () -> Void) {
    guard let document = current else { return }
    convertEncoding(
      document, encoding: .utf16LE, bom: true,
      validate: { snapshot in
        gate.suspend()
        _ = try DocumentCodec.encode(snapshot)
      }, onFinish: finished)
  }
  func runGatedJSON(_ gate: TransformGate, finished: @escaping () -> Void) {
    formatJSON(
      operation: { text in
        gate.suspend()
        return try LanguageService.formatJSON(text)
      }, onFinish: finished)
  }
  func invokeTabClose(_ id: UUID) { tabBar.onClose?(id) }
  func runGatedTransform(_ gate: TransformGate) {
    performDocumentCommand("Synthetic gated transform") { text, selection in
      gate.suspend()
      return LineCommandResult(text: text + "MUST NOT APPLY", selection: selection)
    }
  }
}
@main struct SharedPaneCommandsHarness {
  @MainActor static func main() async throws {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: state) }
    setenv("THEONLYPAD_STATE_DIRECTORY", state.path, 1)
    _ = NSApplication.shared
    var errors: [Error] = []
    let (controller, left, right) = try EditorWindowController.fixture { errors.append($0) }
    let document = left.document
    let mode = CommandLine.arguments.dropFirst().first ?? "default"
    if mode == "noninteractive-navigation" {
      document.storage.mutableString.setString("first 😀\r\nsecond")
      left.editor.setSelectedRange(NSRange(location: 0, length: 0))
      controller.navigate(line: 2, column: 2, requireFocus: false)
      try controller.focusPane(id: right.id)
      right.editor.setSelectedRange(NSRange(location: 0, length: 0))
      let siblingCaret = right.editor.selectedRange()
      let target = NSRange(location: 11, length: 0)
      let limit = Date().addingTimeInterval(5)
      while left.editor.selectedRange() != target && Date() < limit {
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      precondition(left.editor.selectedRange() == target)
      precondition(
        controller.focusedPane === right && controller.window?.firstResponder === right.editor,
        "Noninteractive navigation must not steal sibling focus")
      precondition(right.editor.selectedRange() == siblingCaret)
      print("PASS noninteractive navigation preserves sibling focus and caret")
      return
    }

    if mode == "find-reactivate" || mode == "outline-reactivate" {
      func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
      let find = mode == "find-reactivate"
      document.storage.mutableString.setString(
        find ? "alpha beta alpha" : "func alpha() {}\nfunc beta() {}")
      document.language = .swift
      document.manualLanguage = true
      left.editor.setSelectedRange(NSRange(location: 3, length: 0))
      right.editor.setSelectedRange(NSRange(location: 6, length: 0))
      let otherCaret = right.editor.selectedRange()
      controller.execute(find ? "edit.find" : "tool.outline")
      let panel = controller.routingPanel(find ? "find" : "outline")!
      defer { panel.close() }
      let controls = allViews(panel.window!.contentView!)
      try controller.focusPane(id: right.id)
      if find {
        let query = controls.compactMap { $0 as? NSSearchField }.first!
        query.stringValue = "alpha"
        let findButton = controls.compactMap { $0 as? NSButton }.first { $0.title == "Find All" }!
        _ = findButton.target?.perform(findButton.action, with: findButton)
        let limit = Date().addingTimeInterval(5)
        while controller.focusedPane !== left && Date() < limit {
          try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(
          controller.focusedPane === left
            && left.editor.selectedRange() == NSRange(location: 0, length: 5))
        controller.newDocument()
        let next = controls.compactMap { $0 as? NSButton }.first { $0.title == "Next" }!
        _ = next.target?.perform(next.action, with: next)
        precondition(
          controller.focusedPane === left
            && left.editor.selectedRange() == NSRange(location: 11, length: 5))
        left.detach()
        _ = next.target?.perform(next.action, with: next)
      } else {
        let table = controls.compactMap { $0 as? NSTableView }.first!
        let limit = Date().addingTimeInterval(5)
        while table.numberOfRows != 2 && Date() < limit {
          try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(table.numberOfRows == 2)
        controller.newDocument()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        _ = table.target?.perform(table.doubleAction, with: table)
        precondition(controller.focusedPane === left)
        precondition(
          (document.storage.string as NSString).substring(with: left.editor.selectedRange())
            == "beta")
        left.detach()
        _ = table.target?.perform(table.doubleAction, with: table)
      }
      precondition(!errors.isEmpty && right.editor.selectedRange() == otherCaret)
      precondition(!left.isAttached)
      print("PASS explicit source-pane reactivation and detached refusal: \(mode)")
      return
    }
    if mode == "late-encoding" {
      document.storage.mutableString.setString("encoding 😀")
      document.undoManager.removeAllActions()
      let gate = TransformGate()
      var finished = false
      controller.runGatedEncoding(gate) { finished = true }
      let limit = Date().addingTimeInterval(5)
      while !gate.hasEntered && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(gate.hasEntered && document.saving)
      controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: controller.window))
      gate.release()
      while !finished && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(finished && !document.saving)
      precondition(
        document.encoding == .utf8 && !document.hasBOM,
        "Closed document must not adopt delayed encoding conversion")
      precondition(!document.undoManager.canUndo && errors.isEmpty)
      precondition(!left.editor.isEditable && !right.editor.isEditable)
      print("PASS delayed encoding conversion closes without metadata or undo mutation")
      return
    }
    if mode == "late-json" {
      document.storage.mutableString.setString("{\"x\":1}")
      let gate = TransformGate()
      var finished = false
      var sawModal = false
      controller.runGatedJSON(gate) { finished = true }
      let limit = Date().addingTimeInterval(5)
      while !gate.hasEntered && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(gate.hasEntered)
      controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: controller.window))
      let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated {
          if NSApp.modalWindow != nil {
            sawModal = true
            NSApp.abortModal()
          }
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      RunLoop.main.add(timer, forMode: .modalPanel)
      defer { timer.invalidate() }
      gate.release()
      while !finished && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(finished)
      precondition(
        !sawModal && errors.isEmpty, "Closed window must not show delayed formatter errors")
      precondition(document.storage.string == "{\"x\":1}")
      print("PASS delayed formatter closes without mutation or late alert")
      return
    }
    if mode == "save-freeze" {
      let gate = TransformGate()
      let destination = state.appendingPathComponent("synthetic-save.txt")
      var services = EditorSaveServices()
      services.write = { bytes, url, expected in
        gate.suspend()
        try AtomicFileStore().save(bytes, to: url, expected: expected)
      }
      let (savingController, first, second) = try EditorWindowController.fixture(
        errors: { errors.append($0) }, services: services, destination: destination)
      let model = first.document
      let text = "save 😀e\u{301}\r\nexact"
      model.storage.mutableString.setString(text)
      savingController.execute("file.save")
      let limit = Date().addingTimeInterval(5)
      while !gate.hasEntered && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(gate.hasEntered && !first.editor.isEditable && !second.editor.isEditable)
      precondition(model.url == nil)
      try savingController.focusPane(id: second.id)
      second.editor.insertText("FORBIDDEN", replacementRange: NSRange(location: 0, length: 0))
      precondition(model.storage.string.utf16.elementsEqual(text.utf16))
      gate.release()
      while model.saving && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(!model.saving && errors.isEmpty)
      precondition(first.editor.isEditable && second.editor.isEditable)
      precondition(model.url == destination && !model.dirty)
      let savedBytes = try Data(contentsOf: destination)
      precondition(savedBytes == Data(text.utf8))
      print("PASS all-pane save freeze and document-bound exact publication")
      return
    }
    if ["stale-selection", "stale-edit", "stale-detach", "stale-tab", "positive"].contains(mode) {
      document.storage.mutableString.setString("a😀\r\n")
      let initial = document.storage.string
      let gate = TransformGate()
      controller.runGatedTransform(gate)
      let limit = Date().addingTimeInterval(5)
      while !gate.hasEntered && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(gate.hasEntered)
      switch mode {
      case "stale-selection": left.editor.setSelectedRange(NSRange(location: 1, length: 0))
      case "stale-edit":
        document.storage.mutableString.append("temporary")
        document.storage.mutableString.setString(initial)
      case "stale-detach": left.detach()
      case "stale-tab": controller.newDocument()
      default: break
      }
      gate.release()
      while document.saving && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(!document.saving)
      if mode == "positive" {
        precondition(errors.isEmpty)
        precondition(
          document.storage.string.utf16.elementsEqual((initial + "MUST NOT APPLY").utf16))
        document.undoManager.undo()
        precondition(document.storage.string.utf16.elementsEqual(initial.utf16))
      } else {
        precondition(!errors.isEmpty)
        precondition(document.storage.string.utf16.elementsEqual(initial.utf16))
      }
      print("PASS transform context \(mode)")
      return
    }
    if mode == "orphan-callback" {
      var owner: EditorWindowController? = EditorWindowController(
        restoreStartup: false, onError: { errors.append($0) }, onSessionChange: {})
      owner!.newDocument()
      let orphan = owner!.focusedPane!
      weak var weakDocument: EditorDocument?
      weakDocument = orphan.document
      owner!.close()
      owner = nil
      let limit = Date().addingTimeInterval(3)
      while weakDocument != nil && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(weakDocument == nil)
      let text = orphan.editor.string
      orphan.editor.insertText("FORBIDDEN", replacementRange: NSRange(location: 0, length: 0))
      (orphan.scroll.verticalRulerView as? LineNumberRuler)?.onToggleBookmark?(0)
      precondition(orphan.editor.string.utf16.elementsEqual(text.utf16))
      print("PASS orphan pane callbacks refuse without dereferencing disposed document")
      return
    }
    if CommandLine.arguments.contains("late-close") {
      let gate = TransformGate()
      controller.runGatedTransform(gate)
      let limit = Date().addingTimeInterval(5)
      while !gate.hasEntered && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(gate.hasEntered)
      controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: controller.window))
      gate.release()
      while document.saving && Date() < limit { try await Task.sleep(nanoseconds: 1_000_000) }
      precondition(!document.saving)
      precondition(errors.isEmpty, "Closed window must not present late worker errors")
      print("PASS late closed-window worker suppression")
      return
    }
    if CommandLine.arguments.contains("close-composition") {
      document.storage.mutableString.setString("abc")
      left.editor.setMarkedText(
        "漢", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 1))
      precondition(left.editor.hasMarkedText())
      // Keep this close fixture clean so a missing guard does not open a modal discard prompt.
      document.savedText = document.storage.string
      controller.invokeTabClose(document.id)
      precondition(
        controller.sessionMetadata.tabs.contains { $0.id == document.id },
        "Tab close callback must reject teardown during composition")
      precondition(!errors.isEmpty)
      print("PASS composition tab-close callback rejection")
      return
    }
    let original = "a😀e\u{301}\r\nz\r"
    document.storage.mutableString.setString(original)
    left.editor.setSelectedRange(NSRange(location: 1, length: 0))
    right.editor.setSelectedRange(NSRange(location: 7, length: 0))
    document.undoManager.removeAllActions()
    document.undoManager.groupsByEvent = false
    let initialRevision = document.editRevision
    document.undoManager.beginUndoGrouping()
    left.editor.insertText("L", replacementRange: NSRange(location: 1, length: 0))
    document.undoManager.endUndoGrouping()
    precondition(document.editRevision == initialRevision + 1)
    let leftEdited = document.storage.string
    try controller.focusPane(id: right.id)
    document.undoManager.beginUndoGrouping()
    right.editor.insertText("R", replacementRange: right.editor.selectedRange())
    document.undoManager.endUndoGrouping()
    let bothEdited = document.storage.string
    right.editor.undoManager!.undo()
    precondition(document.storage.string.utf16.elementsEqual(leftEdited.utf16))
    left.editor.undoManager!.undo()
    precondition(document.storage.string.utf16.elementsEqual(original.utf16))
    left.editor.undoManager!.redo()
    right.editor.undoManager!.redo()
    precondition(document.storage.string.utf16.elementsEqual(bothEdited.utf16))
    let firstCapture = try controller.captureSessionCheckpoint()
    let secondCapture = try controller.captureSessionCheckpoint()
    precondition(firstCapture.liveTabIDs == [document.id] && firstCapture.recovery.count == 1)
    precondition(secondCapture.liveTabIDs == [document.id] && secondCapture.recovery.count == 1)
    precondition(secondCapture.recovery[0].revision > firstCapture.recovery[0].revision)

    try controller.focusPane(id: left.id)
    let before = document.storage.string
    let gate = TransformGate()
    // Existing real command worker closure; same-file access avoids a production-only test seam.
    controller.runGatedTransform(gate)
    let deadline = Date().addingTimeInterval(5)
    while !gate.hasEntered && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    precondition(gate.hasEntered)
    try controller.focusPane(id: right.id)
    gate.release()
    while document.saving && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    precondition(!document.saving && !errors.isEmpty)
    precondition(document.storage.string.utf16.elementsEqual(before.utf16))

    try controller.focusPane(id: left.id)
    document.undoManager.beginUndoGrouping()
    left.editor.setMarkedText(
      "漢", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 1))
    precondition(document.composingPaneID == left.id)
    let provisional = document.storage.string
    let markedRevision = document.editRevision
    right.editor.insertText("FORBIDDEN", replacementRange: NSRange(location: 0, length: 0))
    precondition(
      !right.editor.shouldChangeText(
        in: NSRange(location: 0, length: 0),
        replacementString: "FORBIDDEN"))
    precondition(document.storage.string.utf16.elementsEqual(provisional.utf16))
    precondition(document.editRevision == markedRevision)
    do {
      try controller.focusPane(id: right.id)
      preconditionFailure("composition focus escaped")
    } catch {}
    left.editor.unmarkText()
    document.undoManager.endUndoGrouping()
    precondition(document.composingPaneID == nil && right.editor.isEditable)
    document.undoManager.undo()
    precondition(document.storage.string.utf16.elementsEqual(before.utf16))
    right.editor.isSelectable = false
    let leftSelectable = left.editor.isSelectable
    let frozenText = document.storage.string
    let prepared = await controller.prepareToQuit(persistRecovery: false)
    precondition(prepared)
    precondition(!left.editor.isEditable && !right.editor.isEditable)
    precondition(!left.editor.isSelectable && !right.editor.isSelectable)
    right.editor.insertText("FORBIDDEN", replacementRange: NSRange(location: 0, length: 0))
    precondition(document.storage.string.utf16.elementsEqual(frozenText.utf16))
    controller.cancelPreparedQuit()
    precondition(left.editor.isSelectable == leftSelectable && !right.editor.isSelectable)
    controller.cancelPreparedQuit()
    precondition(left.editor.isSelectable == leftSelectable && !right.editor.isSelectable)
    print("PASS routing: shared undo, one recovery item, focus-stale worker, composition exclusion")
    // Additional cases in README: detached/edit-restore/quit stale completions,
    // pending-publication capture, explicit outline/find reactivation, bookmark cancel,
    // save/reload interactivity and per-pane quit-veto state restoration.
  }
}
