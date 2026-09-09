import AppKit
import PadCore

/// Structural navigation checks; this is not a long-file performance benchmark.
@main struct ScrollExtentHarness {
  @MainActor static func main() throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theonlypad-scroll-extent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let controller = EditorWindowController()
    controller.showWindow(nil)
    controller.window!.setContentSize(NSSize(width: 900, height: 650))
    let line = "synthetic line\n"
    let fixtures = [
      (
        "multiline", String(repeating: line, count: 399) + "synthetic line",
        [(400, 1, 399 * line.utf16.count), (200, 1, 199 * line.utf16.count), (1, 1, 0)]
      ),
      (
        "longline", String(repeating: "x", count: 100_000),
        [(1, 100_000, 99_999), (1, 50_000, 49_999), (1, 1, 0)]
      ),
    ]
    for wrap in [true, false] {
      var settings = EditorSettings.defaults
      settings.wrap = wrap
      controller.applySettings(settings)
      for (name, text, positions) in fixtures {
        let url = directory.appendingPathComponent("\(name)-\(wrap).txt")
        try Data(text.utf8).write(to: url)
        var opened = false
        controller.open(url, onOpened: { opened = true })
        wait("open scroll fixture") { opened }
        let editor = descendants(controller.window!.contentView!).compactMap { $0 as? NSTextView }
          .first { $0.accessibilityLabel() == "Document text" }!
        for (lineNumber, column, offset) in positions {
          controller.navigate(line: lineNumber, column: column)
          wait("navigate to synthetic text") { editor.selectedRange().location == offset }
          controller.window!.displayIfNeeded()
          let layout = editor.layoutManager!
          let glyphs = layout.glyphRange(
            forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
          let glyphBounds = layout.boundingRect(forGlyphRange: glyphs, in: editor.textContainer!)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
          let visible = !glyphBounds.isEmpty && editor.visibleRect.intersects(glyphBounds)
          print("EXTENT \(name) wrap=\(wrap) offset=\(offset) visible=\(visible)")
          precondition(
            visible, "Navigation must expose the target glyph, not only move its selection")
          precondition(editor.string.utf16.elementsEqual(text.utf16))
          precondition(!controller.currentDocumentIsDirty)
        }
      }
    }
    controller.window!.orderOut(nil)
    print(
      "PASS native scroll extent: start/middle/end visible in wrapped/unwrapped multiline and long-line text"
    )
    withExtendedLifetime(controller) {}
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
