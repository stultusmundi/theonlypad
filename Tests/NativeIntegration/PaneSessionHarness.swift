import AppKit
import PadCore

@main struct PaneSessionHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var failures = 0
    func check(_ value: Bool, _ label: String) {
      print("\(value ? "PASS" : "FAIL") \(label)")
      if !value { failures += 1 }
    }
    let mode = CommandLine.arguments.dropFirst().first ?? "roundtrip"
    if mode == "compatibility" {
      let controller = EditorWindowController(
        restoreStartup: false, onError: { _ in }, onSessionChange: {})
      guard let originalCloseWindow = controller.window else {
        check(false, "missing original window for injected component close")
        exit(1)
      }
      let text = "hello"
      let value = SessionPresentation(
        axis: .stacked,
        panes: [.init(selection: .init(location: 0, length: 0), scrollOrigin: .init(x: 0, y: 50))],
        focusedPaneIndex: 0)
      do {
        try controller.restoreSessionTab(
          SessionTab(presentation: value),
          decoded: .init(text: text, encoding: .utf8, hasBOM: false), originalBytes: nil, url: nil,
          viewState: RestoredViewState.resolve(
            selection: .init(location: 0, length: 0), bookmarks: [], in: text))
        check(false, "nonlegacy single presentation requires resolved payload")
      } catch { check(true, "nonlegacy single presentation requires resolved payload") }
      controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
      exit(failures == 0 ? 0 : 1)
    }
    if mode == "authority-single" {
      let controller = EditorWindowController(
        restoreStartup: false, onError: { _ in }, onSessionChange: {})
      guard let originalCloseWindow = controller.window else {
        check(false, "missing original window for injected component close")
        exit(1)
      }
      let text = "before text"
      let value = SessionPresentation.single(selection: .init(location: 2, length: 0))
      let resolved = try RestoredPresentationState.resolve(value, bookmarks: [], in: text)
      let metadata = SessionTab(presentation: value)
      try controller.restoreSessionTab(
        metadata, decoded: .init(text: text, encoding: .utf8, hasBOM: false),
        originalBytes: nil, url: nil, viewState: resolved.focusedViewState,
        resolvedPresentation: resolved, activate: false)
      let document = controller.fixturePaneDocument(metadata.id)!
      document.storage.replaceCharacters(in: .init(location: 0, length: 1), with: "B")
      controller.selectSessionTab(metadata.id)
      check(
        document.panePresentation.pending == nil,
        "changed inactive single pane resolves synchronously")
      let live = controller.focusedPane!
      live.editor.setSelectedRange(.init(location: 4, length: 0))
      await Task.yield()
      check(
        controller.visiblePanes.count == 1 && live.editor.selectedRange().location == 4,
        "completed single-pane restore never replays over later selection")
      controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
      exit(failures == 0 ? 0 : 1)
    }
    let text = "first 😀\r\nsecond e\u{301}\n" + String(repeating: "line\n", count: 200)
    let one = NSRange(location: 6, length: 2)
    let two = NSRange(location: 10, length: 3)
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: one, scrollOrigin: .init(x: 0, y: 12)),
        .init(selection: two, scrollOrigin: .init(x: 0, y: 36)),
      ], focusedPaneIndex: 1)
    var changes = 0
    let controller = EditorWindowController(
      restoreStartup: false, onError: { _ in },
      onSessionChange: { changes += 1 })
    guard let originalCloseWindow = controller.window else {
      check(false, "missing original window for injected component close")
      exit(1)
    }
    let input =
      mode == "deferred" || mode == "native-edit" || mode.hasPrefix("reentry-")
        || mode == "prelayout" || mode == "discard" || mode.hasPrefix("authority")
      ? String(repeating: "x", count: 2_000_001) : text
    let resolved = try await Task.detached {
      try RestoredPresentationState.resolve(presentation, bookmarks: [], in: input)
    }.value
    let metadata = SessionTab(presentation: presentation)
    try controller.restoreSessionTab(
      metadata,
      decoded: .init(text: input, encoding: .utf8, hasBOM: false), originalBytes: nil, url: nil,
      viewState: resolved.focusedViewState, resolvedPresentation: resolved, activate: false)
    let document = controller.fixturePaneDocument(metadata.id)!
    check(document.storage.layoutManagers.count == 1, "inactive restoration allocates one layout")
    check(
      controller.sessionMetadata.tabs[0].presentation == presentation,
      "inactive capture retains complete presentation")
    check(document.undoManager.canUndo == false, "import adds no undo action")
    if mode == "refused-install" { document.saving = true }
    controller.selectSessionTab(metadata.id)
    if mode == "refused-install" {
      document.saving = false
      controller.focusedPane!.editor.setSelectedRange(.init(location: 3, length: 0))
      let saved = controller.sessionMetadata.tabs[0].presentation
      check(
        saved.panes[1].selection.location == 3,
        "refused first install still captures current live slot")
      check(saved.panes[0] == presentation.panes[0], "refused first install preserves dormant slot")
      controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
      exit(failures == 0 ? 0 : 1)
    }
    if mode == "deferred" || mode == "native-edit" || mode.hasPrefix("reentry-")
      || mode == "prelayout" || mode == "discard" || mode.hasPrefix("authority")
    {
      check(controller.visiblePanes.count == 1, "above-limit split remains one pane")
      let live = controller.focusedPane!
      live.editor.setSelectedRange(NSRange(location: 20, length: 0))
      let merged = controller.sessionMetadata.tabs[0].presentation
      check(
        merged.panes[1].selection.location == 20 && merged.panes[0] == presentation.panes[0],
        "deferred capture merges saved focused slot and retains dormant slot")
      check(
        merged.focusedPaneIndex == 1 && merged.axis == .stacked,
        "deferred preference and axis retained")
      if mode == "discard" {
        controller.fixtureDiscardSavedPanes()
        let single = controller.sessionMetadata.tabs[0].presentation
        check(
          single.panes.count == 1 && single.focusedPaneIndex == 0
            && single.panes[0].selection == live.editor.selectedRange(),
          "explicit discard retains live selection as single slot")
        check(
          document.storage.length == 2_000_001 && document.panePresentation.pending == nil,
          "discard changes layout metadata only")
        controller.windowWillClose(
          Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
        exit(failures == 0 ? 0 : 1)
      }
      if mode == "native-edit" {
        document.undoManager.groupsByEvent = false
        document.undoManager.beginUndoGrouping()
        live.editor.insertText(
          text, replacementRange: .init(location: 0, length: input.utf16.count))
        document.undoManager.endUndoGrouping()
      } else {
        document.storage.mutableString.setString(text)
      }
      if mode == "prelayout" { controller.fixtureQueuePaneStatusHeight(120) }
      var operation: UUID?
      switch mode {
      case "authority-selection": live.editor.setSelectedRange(.init(location: 1, length: 0))
      case "authority-composition":
        live.editor.setMarkedText(
          "z", selectedRange: .init(location: 1, length: 0),
          replacementRange: .init(location: 0, length: 0))
      case "authority-edit":
        document.storage.replaceCharacters(in: .init(location: 0, length: 1), with: "Z")
      case "authority-close":
        controller.windowWillClose(
          Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
      case "authority-saving": document.saving = true
      case "authority-operation": operation = document.beginFileOperation()
      case "authority-tab": controller.newDocument()
      case "authority-scroll": live.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1))
      case "authority-quit":
        check(
          await controller.prepareToQuit(persistRecovery: false),
          "quit prepares without native resolver")
        let frozen = controller.sessionMetadata.tabs[0].presentation
        live.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1))
        check(
          controller.sessionMetadata.tabs[0].presentation == frozen,
          "quit capture uses frozen origins")
      default: break
      }
      if mode == "authority-operation" {
        controller.fixtureRenderPaneStatus()
        check(
          !controller.fixtureRestoreEnabled && !controller.fixtureDiscardEnabled,
          "operation-owned document disables restore and discard controls")
      }
      let selectionBefore = live.editor.selectedRange()
      if mode == "reentry-command" {
        let directory = URL(
          fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!)
        let file = directory.appendingPathComponent("reentrant-save.txt")
        try Data(text.utf8).write(to: file)
        document.url = file
        document.originalBytes = Data(text.utf8)
      }
      var reentered = false
      var observer: NSObjectProtocol?
      if mode.hasPrefix("reentry-") {
        observer = NotificationCenter.default.addObserver(
          forName:
            mode == "reentry-secondary-selection"
            ? NSView.boundsDidChangeNotification : NSTextView.didChangeSelectionNotification,
          object: nil, queue: nil
        ) { note in
          MainActor.assumeIsolated {
            if mode == "reentry-secondary-selection" {
              guard !reentered, let clip = note.object as? NSClipView,
                let second = document.panePool.first(where: {
                  $0 !== live && $0.scroll.contentView === clip
                }),
                second.isAttached, second.editor.selectedRange() == one
              else { return }
              reentered = true
              second.editor.setSelectedRange(.init(location: 9, length: 0))
              return
            }
            guard !reentered, let view = note.object as? NSTextView,
              view.textStorage === document.storage, view !== live.editor
            else { return }
            reentered = true
            switch mode {
            case "reentry-detach": document.panePool.first(where: { $0.editor === view })?.detach()
            case "reentry-command": controller.execute("file.save")
            case "reentry-close":
              controller.windowWillClose(
                Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
            case "reentry-edit":
              document.storage.replaceCharacters(in: .init(location: 0, length: 1), with: "Q")
            case "reentry-operation":
              let id = document.beginFileOperation()
              _ = document.finishFileOperation(id)
            default: controller.fixtureRestoreSavedPanes()
            }
          }
        }
      }
      controller.fixtureRestoreSavedPanes()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      let refuses = [
        "authority-close", "authority-saving", "authority-operation", "authority-tab",
        "authority-composition", "authority-quit", "reentry-close", "reentry-edit",
        "reentry-operation", "reentry-detach", "reentry-secondary-selection",
      ].contains(mode)
      if mode == "reentry-command" {
        check(
          !document.saving && document.operationID == nil,
          "reentrant save command is not admitted during pane installation")
      }
      if mode.hasPrefix("reentry-") {
        check(reentered, "actual native notification reenters installation")
      }
      if mode == "reentry-secondary-selection" {
        check(
          document.panePool.first(where: { $0 !== live })?.editor.selectedRange().location == 9,
          "rollback preserves reentrant secondary selection instead of overwriting it")
      }
      if refuses {
        check(
          document.storage.layoutManagers.count == 1 && document.panePresentation.pending != nil,
          "refused restore retains deferred metadata without an extra attached layout")
      } else {
        check(
          document.storage.layoutManagers.count == 2 && document.panePresentation.pending == nil,
          "explicit eligible restore consumes deferred metadata")
        check(
          controller.focusedPane === live && live.editor.selectedRange() == selectionBefore,
          "synchronous restore preserves latest live selection")
        live.editor.setSelectedRange(.init(location: 3, length: 0))
        live.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 2))
        // No resolver callback exists: a later turn must not reinstall saved selections.
        await Task.yield()
        check(
          live.editor.selectedRange().location == 3 && document.panePresentation.pending == nil,
          "completed restore never replays saved selection after later interaction")
      }
      if mode == "native-edit" {
        let other = document.panePool.first(where: { $0 !== live })!
        other.editor.undoManager!.undo()
        check(
          document.storage.string.utf16.elementsEqual(input.utf16),
          "other restored pane undo returns exact original over-limit buffer")
        live.editor.undoManager!.redo()
        check(
          document.storage.string.utf16.elementsEqual(text.utf16),
          "live restored pane redo returns exact Unicode replacement")
        check(
          document.storage.layoutManagers.count == 2 && document.panePresentation.pending == nil,
          "undo and redo do not replay deferred layout metadata")
        let paired = try controller.captureSessionCheckpoint()
        check(
          paired.recovery.count == 1 && paired.window.tabs.count == 1,
          "restored native edit history keeps one checkpoint identity")
      }
      if let operation { _ = document.finishFileOperation(operation) }
      if mode == "authority-saving" { document.saving = false }
      if mode == "authority-composition" { live.editor.unmarkText() }
      if mode == "authority-quit" { controller.cancelPreparedQuit() }
    } else {
      check(controller.visiblePanes.count == 2, "restoration retains two panes")
      check(document.splitAxis == .stacked, "restoration retains stacked axis")
      check(
        controller.visiblePanes.map { $0.editor.selectedRange() } == [one, two],
        "independent selections retain visual slot order")
      check(
        controller.focusedPane === controller.visiblePanes[1],
        "saved focused slot maps to second runtime view")
      check(
        controller.visiblePanes.allSatisfy { $0.editor.undoManager === document.undoManager },
        "both views share document undo")
      check(document.storage.string.utf16.elementsEqual(text.utf16), "exact Unicode text preserved")
      let beforeCapture = changes
      let capture = try controller.captureSessionCheckpoint()
      check(changes == beforeCapture, "capture does not notify or schedule itself")
      check(
        capture.recovery.count == 1 && capture.window.tabs.count == 1,
        "two panes have one recovery and metadata identity")
      let undo = document.undoManager
      undo.groupsByEvent = false
      undo.beginUndoGrouping()
      controller.focusedPane!.editor.insertText(
        "!", replacementRange: .init(location: 0, length: 0))
      undo.endUndoGrouping()
      undo.undo()
      check(
        document.storage.string.utf16.elementsEqual(text.utf16),
        "native undo restores exact shared text")
      try controller.collapseToFocusedPane()
      let single = controller.sessionMetadata.tabs[0].presentation
      check(
        single.panes.count == 1 && single.focusedPaneIndex == 0,
        "collapsed runtime slot one persists single slot zero")
      document.panePresentation.warning = "Document or view changed. Use Restore Saved Split again."
      try controller.splitCurrent(.sideBySide)
      check(
        document.panePresentation.warning == nil,
        "successful explicit layout clears obsolete warning")
      document.panePresentation.warning = "Document or view changed. Use Restore Saved Split again."
      try controller.collapseToFocusedPane()
      check(document.panePresentation.warning == nil, "successful collapse clears obsolete warning")
      let pane = controller.focusedPane!
      pane.scroll.frame = .init(x: 0, y: 0, width: 300, height: 150)
      pane.editor.setFrameSize(.init(width: 300, height: 2000))
      let expectedOrigin = pane.scroll.contentView.constrainBoundsRect(
        NSRect(origin: NSPoint(x: 0, y: 200), size: pane.scroll.contentView.bounds.size)
      ).origin
      print("GEOMETRY before clip=\(pane.scroll.contentView.bounds) editor=\(pane.editor.frame)")
      check(
        DocumentPanePresentation.applyOrigin(.init(x: 0, y: 200), to: pane),
        "positive native geometry permits one-shot origin")
      print("GEOMETRY after clip=\(pane.scroll.contentView.bounds) editor=\(pane.editor.frame)")
      check(
        pane.scroll.contentView.bounds.origin == expectedOrigin,
        "one-shot origin matches measured native constraint")
      pane.scroll.frame = .zero
      check(
        !DocumentPanePresentation.applyOrigin(.init(x: 0, y: 500), to: pane),
        "unavailable geometry refuses origin without retry")
    }
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: originalCloseWindow))
    exit(failures == 0 ? 0 : 1)
  }
}
