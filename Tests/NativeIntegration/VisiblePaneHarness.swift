import AppKit
import PadCore

private actor ParserCalls {
  private var value = 0
  func increment() { value += 1 }
  func count() -> Int { value }
}
@main struct VisiblePaneHarness {
  @MainActor static func main() async throws {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: state) }
    setenv("THEONLYPAD_STATE_DIRECTORY", state.path, 1)
    _ = NSApplication.shared
    var errors: [Error] = []
    let controller = EditorWindowController(
      restoreStartup: false, onError: { errors.append($0) }, onSessionChange: {})
    controller.newDocument()
    let first = controller.focusedPane!
    first.document.storage.mutableString.setString("first 😀\r\nsecond e\u{301}\n")
    first.editor.setSelectedRange(NSRange(location: 6, length: 2))
    if CommandLine.arguments.contains("cache-settings") {
      var settings = EditorSettings.defaults
      settings.fontSize = 18
      settings.tabWidth = 8
      settings.wrap = false
      controller.applySettings(settings)
      let model = first.document
      model.storage.mutableString.setString("let value = 1\n")
      model.language = .swift
      model.manualLanguage = true
      model.undoManager.groupsByEvent = false
      model.undoManager.beginUndoGrouping()
      first.editor.insertText(
        " ", replacementRange: NSRange(location: model.storage.length, length: 0))
      model.undoManager.endUndoGrouping()
      let calls = ParserCalls()
      model.highlighter = NativeSyntaxHighlighter(
        storage: model.storage, debounceNanoseconds: 0,
        parser: { text, language, cancelled in
          await calls.increment()
          return try LanguageService.tokens(in: text, language: language, isCancelled: cancelled)
        })
      model.highlighter.update(language: .swift)
      let limit = Date().addingTimeInterval(5)
      while first.layoutManager.temporaryAttribute(
        .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil && Date() < limit
      {
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      precondition(
        first.layoutManager.temporaryAttribute(
          .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
      let revision = model.editRevision
      let caret = first.editor.selectedRange()
      let text = model.storage.string
      let undoName = model.undoManager.undoActionName
      precondition(model.undoManager.canUndo)
      controller.execute("view.splitVertical")
      precondition(controller.visiblePanes.count == 2)
      let added = controller.visiblePanes.first { $0 !== first }!
      precondition(
        added.layoutManager.temporaryAttribute(
          .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
      precondition(added.editor.font == first.editor.font && added.editor.font?.pointSize == 18)
      precondition(added.editor.isHorizontallyResizable && first.editor.isHorizontallyResizable)
      precondition(
        added.editor.defaultParagraphStyle?.defaultTabInterval
          == first.editor.defaultParagraphStyle?.defaultTabInterval)
      let parseCount = await calls.count()
      precondition(parseCount == 1 && model.editRevision == revision)
      precondition(
        first.editor.selectedRange() == caret
          && model.storage.string.utf16.elementsEqual(text.utf16))
      precondition(model.undoManager.canUndo && model.undoManager.undoActionName == undoName)
      precondition(
        (model.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
      controller.execute("view.closeSplit")
      let unchanged = model.storage.string
      model.language = .plainText
      model.highlighter.update(language: .plainText)
      controller.execute("view.splitHorizontal")
      precondition(model.storage.string.utf16.elementsEqual(unchanged.utf16))
      for pane in controller.visiblePanes {
        precondition(
          pane.layoutManager.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
          "Language-only plain-text change must clear colors when a pane reattaches")
      }
      controller.execute("view.closeSplit")
      model.language = .swift
      model.highlighter.update(language: .swift)
      let recolorLimit = Date().addingTimeInterval(5)
      while first.layoutManager.temporaryAttribute(
        .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil && Date() < recolorLimit
      {
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      controller.execute("view.splitHorizontal")
      precondition(
        added.layoutManager.temporaryAttribute(
          .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
      controller.execute("view.closeSplit")
      model.storage.mutableString.setString("plain text now\n")
      controller.execute("view.splitHorizontal")
      precondition(
        added.layoutManager.temporaryAttribute(
          .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
        "Reattached pane must not display colors from an invalidated detached cache")
      print("PASS automatic cache attachment, invalidation, font/tab/wrap consistency")
      return
    }
    if CommandLine.arguments.contains("refusals") {
      let model = first.document
      precondition(
        !controller.isCommandAvailable("view.closeSplit")
          && !controller.isCommandAvailable("view.focusOtherPane"))
      model.saving = true
      precondition(!controller.isCommandAvailable("view.splitVertical"))
      do {
        try controller.splitCurrent(.sideBySide)
        preconditionFailure("save admitted split")
      } catch {}
      model.saving = false
      first.editor.setMarkedText(
        "漢", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 1))
      do {
        try controller.splitCurrent(.stacked)
        preconditionFailure("composition admitted split")
      } catch {}
      precondition(!controller.isCommandAvailable("view.splitHorizontal"))
      first.editor.unmarkText()
      let prepared = await controller.prepareToQuit(persistRecovery: false)
      precondition(prepared)
      do {
        try controller.splitCurrent(.sideBySide)
        preconditionFailure("quit admitted split")
      } catch {}
      controller.cancelPreparedQuit()
      precondition(model.panePool.count == 1 && controller.isCommandAvailable("view.splitVertical"))
      let registry = try AppCommands.registry()
      for id in [
        "view.splitVertical", "view.splitHorizontal", "view.closeSplit", "view.focusOtherPane",
      ] {
        precondition(registry.commands.filter { $0.id == id }.count == 1)
      }
      print("PASS split registry, single-pane availability and save/composition/quit refusal")
      return
    }
    controller.execute("view.splitVertical")
    precondition(
      controller.visiblePanes.count == 2,
      "Split Side by Side must create two actual presentations of this document")
    // The initial behavioral gate above requires no new APIs and fails on unchanged Task2.
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func assertAxis(_ vertical: Bool) {
      controller.window!.contentView!.layoutSubtreeIfNeeded()
      let host = views(controller.window!.contentView!).compactMap { $0 as? EditorPaneHost }.first!
      host.layoutSubtreeIfNeeded()
      let split = host.subviews.compactMap { $0 as? NSSplitView }.first!
      precondition(split.isVertical == vertical && split.subviews.count == 2)
      let a = split.subviews[0].frame
      let b = split.subviews[1].frame
      precondition(a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0)
      precondition(a.intersection(b).isEmpty)
      precondition(controller.visiblePanes.allSatisfy { $0.scroll.superview === split })
    }
    controller.showWindow(nil)
    defer { controller.window?.orderOut(nil) }
    assertAxis(true)
    let second = controller.visiblePanes.first { $0 !== first }!
    let document = first.document
    let ids = Set(controller.visiblePanes.map(\.id))
    precondition(controller.focusedPane === first)
    precondition(second.editor.selectedRange() == first.editor.selectedRange())
    precondition(
      second.document === document && second.editor.textStorage === first.editor.textStorage)
    precondition(second.editor.undoManager === first.editor.undoManager)
    for pane in controller.visiblePanes {
      precondition(pane.editor.accessibilityIdentifier() == "editor.text.\(pane.id.uuidString)")
      precondition(pane.editor.accessibilityLabel() == "Document text")
      precondition(pane.scroll.accessibilityIdentifier() == "editor.pane.\(pane.id.uuidString)")
    }
    if CommandLine.arguments.contains("noninteractive-navigation") {
      controller.navigate(line: 2, column: 2, requireFocus: false)
      controller.execute("view.focusOtherPane")
      precondition(controller.focusedPane === second)
      second.editor.setSelectedRange(NSRange(location: 0, length: 0))
      let siblingCaret = second.editor.selectedRange()
      let target = NSRange(location: 11, length: 0)
      let deadline = Date().addingTimeInterval(5)
      while first.editor.selectedRange() != target && Date() < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      precondition(first.editor.selectedRange() == target)
      precondition(
        controller.focusedPane === second && controller.window?.firstResponder === second.editor,
        "Noninteractive source navigation must not steal focus from the sibling pane")
      precondition(second.editor.selectedRange() == siblingCaret)
      print("PASS noninteractive navigation preserves focused sibling pane")
      return
    }
    controller.execute("view.splitHorizontal")
    assertAxis(false)
    precondition(Set(controller.visiblePanes.map(\.id)) == ids)
    controller.execute("view.focusOtherPane")
    precondition(
      controller.focusedPane === second && controller.window?.firstResponder === second.editor)
    let original = document.storage.string
    document.undoManager.removeAllActions()
    document.undoManager.groupsByEvent = false
    document.undoManager.beginUndoGrouping()
    second.editor.insertText("R", replacementRange: NSRange(location: 0, length: 0))
    document.undoManager.endUndoGrouping()
    let edited = document.storage.string
    controller.execute("view.focusOtherPane")
    let retainedCaret = first.editor.selectedRange()
    controller.execute("view.closeSplit")
    precondition(controller.visiblePanes.count == 1 && controller.focusedPane === first)
    precondition(!second.isAttached && document.panePool.count == 2)
    precondition(first.editor.selectedRange() == retainedCaret)
    first.editor.undoManager!.undo()
    precondition(
      document.storage.string.utf16.elementsEqual(original.utf16),
      "Undo must retain detached-origin native history")
    first.editor.undoManager!.redo()
    precondition(document.storage.string.utf16.elementsEqual(edited.utf16))
    for _ in 0..<100 {
      controller.execute("view.splitVertical")
      precondition(Set(controller.visiblePanes.map(\.id)) == ids)
      controller.execute("view.closeSplit")
      precondition(document.panePool.count == 2 && document.storage.layoutManagers.count == 1)
    }
    controller.execute("view.splitHorizontal")
    controller.newDocument()
    controller.execute("view.splitVertical")
    assertAxis(true)
    controller.execute("file.previousTab")
    precondition(controller.focusedPane?.document === document)
    assertAxis(false)
    let capture = try controller.captureSessionCheckpoint()
    precondition(capture.liveTabIDs.count == 2 && capture.recovery.count == 2)
    controller.newDocument()
    let large = controller.focusedPane!.document
    large.storage.mutableString.setString(String(repeating: "x\n", count: 1_000_001))
    precondition(!controller.isCommandAvailable("view.splitVertical"))
    let beforeError = errors.count
    controller.execute("view.splitVertical")
    precondition(large.panePool.count == 1 && errors.count == beforeError + 1)
    precondition(
      views(controller.window!.contentView!).compactMap { $0 as? NSTextField }
        .contains { $0.stringValue.hasPrefix("Split unavailable") },
      "Large documents need visible split-limit status")
    print(
      "PASS visible controller panes: axes, identifiers, focus, detached undo, reuse, tab memory and limit"
    )
  }
}
