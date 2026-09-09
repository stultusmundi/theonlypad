import AppKit
import PadCore

/// Exercises the real document owner. Timing assertions belong in separate benchmarks.
@main struct DirtyStateHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theonlypad-dirty-state-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let controller = EditorWindowController()
    controller.showWindow(nil)
    var fixtureIndex = 0

    func expect(_ value: Bool, _ message: String) {
      precondition(controller.currentDocumentIsDirty == value, message)
    }
    func open(_ text: String) -> (NSTextView, URL) {
      fixtureIndex += 1
      let url = directory.appendingPathComponent("synthetic-\(fixtureIndex).txt")
      try! Data(text.utf8).write(to: url)
      var opened = false
      controller.open(url, onOpened: { opened = true })
      wait("open synthetic document") { opened }
      let editor = descendants(controller.window!.contentView!).compactMap { $0 as? NSTextView }
        .first { $0.accessibilityLabel() == "Document text" }!
      precondition(editor.string.utf16.elementsEqual(text.utf16))
      expect(false, "opened bytes establish the saved baseline")
      return (editor, url)
    }
    func save(_ editor: NSTextView, url: URL) {
      controller.execute("file.save")
      wait("save synthetic document") { editor.isEditable }
      let decoded = try! DocumentCodec.decode(Data(contentsOf: url))
      precondition(decoded.text.utf16.elementsEqual(editor.string.utf16))
      expect(false, "successful save must establish a new clean baseline")
    }
    func convert(_ editor: NSTextView, title: String, bom: Bool) {
      controller.execute("document.encoding")
      let sheet = controller.window!.attachedSheet!
      let controls = descendants(sheet.contentView!)
      let choice = controls.compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityLabel() == "Text encoding" }!
      choice.selectItem(withTitle: title)
      if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
      let checkbox = controls.compactMap { $0 as? NSButton }
        .first { $0.accessibilityLabel() == "Include byte-order mark" }!
      precondition(checkbox.isEnabled)
      checkbox.state = bom ? .on : .off
      controls.compactMap { $0 as? NSButton }.first { $0.title == "Convert Encoding" }!
        .performClick(nil)
      wait("convert encoding") { editor.isEditable && controller.window!.attachedSheet == nil }
    }

    let (direct, directURL) = open("abc")
    direct.string = "axc"
    expect(true, "direct same-length .string assignment invalidates a cached clean result")
    direct.string = "abc"
    expect(false, "direct restoration invalidates a cached dirty result")
    direct.textStorage!.replaceCharacters(in: NSRange(location: 1, length: 1), with: "z")
    expect(true, "direct storage mutation must not depend on textDidChange")
    save(direct, url: directURL)
    direct.string = "abc"
    expect(true, "old text is dirty after saved baseline changes")
    direct.string = "azc"
    expect(false, "new saved text restores clean state")
    direct.textStorage!.addAttribute(
      .foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
    expect(false, "attribute-only changes do not change document text")

    let (normalization, _) = open("e\u{301}")
    normalization.string = "é"
    expect(true, "normalization-only changes remain dirty")
    normalization.string = "e\u{301}"
    expect(false, "exact decomposed baseline restores clean state")
    let originalOrder = "a\u{301}\u{323}"
    let reordered = "a\u{323}\u{301}"
    precondition(originalOrder == reordered && originalOrder.utf16.count == reordered.utf16.count)
    let (equalLength, _) = open(originalOrder)
    equalLength.string = reordered
    expect(true, "equal-length canonically equivalent text must still compare exact UTF-16")
    equalLength.string = originalOrder
    expect(false, "exact combining-mark order restores clean state")

    for (original, changed) in [
      ("\0a", "\0b"), ("a\r\nb", "a\n\rb"),
      ("\u{202A}abc\u{202C}", "\u{202B}abc\u{202C}"),
      ("👩🏽‍💻", "👩🏼‍💻"),
    ] {
      precondition(original.utf16.count == changed.utf16.count)
      let (exact, _) = open(original)
      exact.string = changed
      expect(true, "same-length control, ending, bidi and emoji changes remain dirty")
      exact.string = original
      expect(false, "exact original code units restore clean state")
    }

    let (batch, _) = open("abc")
    batch.textStorage!.beginEditing()
    batch.textStorage!.replaceCharacters(in: NSRange(location: 1, length: 1), with: "z")
    expect(true, "query during unfinished storage batch must not use the previous cache")
    batch.textStorage!.replaceCharacters(in: NSRange(location: 1, length: 1), with: "b")
    expect(false, "restoration during unfinished batch must also be immediately visible")
    batch.textStorage!.endEditing()
    expect(false, "batch completion preserves the exact clean result")

    let (native, _) = open("abc")
    let undo = native.undoManager!
    undo.removeAllActions()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    native.insertText("Z", replacementRange: NSRange(location: 1, length: 1))
    native.breakUndoCoalescing()
    undo.endUndoGrouping()
    expect(true, "native insertion changes dirty state")
    undo.undo()
    expect(false, "native undo restores the saved baseline")
    undo.redo()
    expect(true, "native redo restores dirty state")
    undo.undo()
    expect(false, "second undo remains exact")
    undo.beginUndoGrouping()
    native.setMarkedText(
      "漢", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 1, length: 1))
    expect(true, "provisional marked text invalidates without a fabricated textDidChange callback")
    native.unmarkText()
    undo.endUndoGrouping()
    expect(true, "committed marked text remains dirty")
    native.string = "abc"
    expect(false, "direct restoration after composition remains clean")

    let (metadata, metadataURL) = open("metadata")
    convert(metadata, title: "UTF-16 Little Endian", bom: false)
    expect(true, "encoding-only conversion must not reuse a clean text result as full dirty state")
    metadata.undoManager!.undo()
    expect(false, "undo restores original encoding metadata")
    convert(metadata, title: "UTF-8", bom: true)
    expect(true, "BOM-only conversion changes dirty state")
    metadata.undoManager!.undo()
    expect(false, "undo restores original BOM metadata")
    convert(metadata, title: "UTF-8", bom: true)
    save(metadata, url: metadataURL)
    let saved = try DocumentCodec.decode(Data(contentsOf: metadataURL))
    precondition(saved.encoding == .utf8 && saved.hasBOM)
    metadata.undoManager!.undo()
    expect(true, "undo to old BOM metadata is dirty after the new metadata was saved")

    controller.window!.orderOut(nil)
    print(
      "PASS native dirty state: saved baseline, direct text/storage, exact normalization, batches, undo/redo, marked-text APIs, encoding and BOM"
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
