import AppKit
import PadCore

@main struct NativeLifetimeHarness {
  @MainActor private final class References {
    weak var controller: EditorWindowController?
    weak var editor: NSTextView?
    weak var window: NSWindow?
  }

  @MainActor static func main() throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theonlypad-lifetime-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: state) }
    setenv("THEONLYPAD_STATE_DIRECTORY", state.path, 1)
    var failures: [String] = []
    for mode in [
      "plain", "native-text-undo", "bookmark-undo", "bookmark-typing", "bookmark-composition",
      "encoding-undo",
    ] {
      let references = References()
      autoreleasepool {
        var controller: EditorWindowController? = EditorWindowController()
        references.controller = controller
        references.window = controller!.window
        controller!.showWindow(nil)
        if mode.hasPrefix("bookmark") {
          let url = state.appendingPathComponent(mode + ".txt")
          try! Data("a\nmarked\n".utf8).write(to: url)
          var opened = false
          controller!.open(url, onOpened: { opened = true })
          wait("open bookmark lifetime fixture") { opened }
        }
        let editor = descendants(controller!.window!.contentView!).compactMap { $0 as? NSTextView }
          .first { $0.accessibilityLabel() == "Document text" }!
        references.editor = editor
        let originalText = editor.string
        switch mode {
        case "native-text-undo":
          editor.insertText("synthetic", replacementRange: NSRange(location: 0, length: 0))
          RunLoop.main.run(until: Date().addingTimeInterval(0.02))
          editor.undoManager!.undo()
          precondition(editor.string.isEmpty && editor.undoManager!.canRedo)
        case "bookmark-undo", "bookmark-typing", "bookmark-composition":
          editor.setSelectedRange(NSRange(location: 2, length: 0))
          controller!.execute("bookmark.toggle")
          wait("bookmark toggle") { editor.isEditable }
          precondition(editor.undoManager!.canUndo)
          if mode != "bookmark-undo" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            editor.undoManager!.removeAllActions()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            if mode == "bookmark-typing" {
              editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
              editor.setMarkedText(
                "漢", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: 0, length: 0))
              editor.unmarkText()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            editor.undoManager!.undo()
            precondition(editor.string.utf16.elementsEqual(originalText.utf16))
          }
        case "encoding-undo":
          controller!.execute("document.encoding")
          let sheet = controller!.window!.attachedSheet!
          let controls = descendants(sheet.contentView!)
          controls.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Include byte-order mark" }!.state = .on
          controls.compactMap { $0 as? NSButton }.first { $0.title == "Convert Encoding" }!
            .performClick(nil)
          wait("encoding conversion") {
            editor.isEditable && controller!.window!.attachedSheet == nil
          }
          editor.undoManager!.undo()
        default: break
        }
        precondition(
          !controller!.currentDocumentIsDirty, "Close fixture must never prompt to discard")
        controller!.close()
        controller = nil
      }
      let deadline = Date().addingTimeInterval(3)
      while (references.controller != nil || references.editor != nil || references.window != nil)
        && Date() < deadline
      {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      let released =
        references.controller == nil && references.editor == nil && references.window == nil
      print(
        "LIFETIME \(mode) controllerReleased=\(references.controller == nil) editorReleased=\(references.editor == nil) windowReleased=\(references.window == nil)"
      )
      if !released { failures.append(mode) }
    }
    precondition(
      failures.isEmpty, "Closed editor resources retained: \(failures.joined(separator: ", "))")
    print(
      "PASS native lifetime: clean window, native undo, bookmark typing/composition undo and encoding undo release after close"
    )
  }

  @MainActor private static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  @MainActor private static func wait(_ operation: String, until predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    precondition(predicate(), "Timed out while attempting to \(operation)")
  }
}
