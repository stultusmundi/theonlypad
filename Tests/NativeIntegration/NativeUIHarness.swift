import AppKit
import PadCore

func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
@main struct NativeUIHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    let mode = CommandLine.arguments.dropFirst().first ?? "checks"
    if mode == "crash" || mode == "restore" {
      let recoveryController = EditorWindowController()
      func restoredEditor() -> NSTextView {
        descendants(recoveryController.window!.contentView!).compactMap { $0 as? NSTextView }.first!
      }
      if mode == "crash" {
        restoredEditor().insertText(
          "force termination synthetic 👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let directory = URL(
          fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!)
        precondition(
          (try! RecoveryStore(directory: directory).loadAll()).contains {
            $0.text == "force termination synthetic 👩🏽‍💻"
          })
        kill(getpid(), SIGKILL)
        fatalError("SIGKILL did not terminate child")
      } else {
        let deadline = Date().addingTimeInterval(5)
        while restoredEditor().string.isEmpty && Date() < deadline {
          RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(restoredEditor().string == "force termination synthetic 👩🏽‍💻")
        precondition(
          recoveryController.window!.representedURL == nil, "recovered text must remain scratch")
        print("PASS process restart restores committed recovery as scratch")
        return
      }
    }
    let controller = EditorWindowController()
    let printInfo = NSPrintInfo()
    let printed = DocumentPrinting.view(
      text: "Synthetic print 👩🏽‍💻\nsecond line",
      font: .monospacedSystemFont(ofSize: 12, weight: .regular), printInfo: printInfo)
    precondition(printed.string == "Synthetic print 👩🏽‍💻\nsecond line")
    precondition(printed.frame.height > 10)
    let pdf = printed.dataWithPDF(inside: printed.bounds)
    precondition(pdf.starts(with: Data("%PDF".utf8)), "actual AppKit print view must produce PDF")
    let content = controller.window!.contentView!
    func editor() -> NSTextView { descendants(content).compactMap { $0 as? NSTextView }.first! }
    func waitForTransform() {
      let deadline = Date().addingTimeInterval(5)
      while !editor().isEditable && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(editor().isEditable)
    }
    precondition(editor().string.isEmpty)
    editor().string = "beta\nalpha\n"
    controller.execute("edit.sorted")
    precondition(!editor().isEditable, "line analysis must leave the UI thread")
    waitForTransform()
    precondition(editor().string == "alpha\nbeta\n", "line sort must change actual text view")
    if let renderPath = ProcessInfo.processInfo.environment["THEONLYPAD_RENDER_PATH"] {
      controller.showWindow(nil)
      content.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(
          to: URL(fileURLWithPath: renderPath))
      }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(editor().string == "beta\nalpha\n", "native undo must reverse transform")
    controller.execute("file.duplicate")
    precondition(editor().string == "beta\nalpha\n", "duplicate preserves text")
    controller.execute("view.wrap")
    precondition(editor().isHorizontallyResizable)
    controller.execute("view.wrap")
    precondition(!editor().isHorizontallyResizable)
    controller.newDocument()
    precondition(editor().string.isEmpty)
    let popup = descendants(content).compactMap { $0 as? NSPopUpButton }.first!
    precondition(popup.numberOfItems == 3)
    popup.selectItem(at: 0)
    _ = popup.target?.perform(popup.action, with: popup)
    precondition(editor().string == "beta\nalpha\n", "tab selection preserves document")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theonlypad-ui-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("synthetic.txt")
    let bytes = try! DocumentCodec.encode(
      DecodedDocument(text: "hello\r\nworld\r\n", encoding: .utf16LE, hasBOM: true))
    try! bytes.write(to: url)
    controller.open(url)
    let loadDeadline = Date().addingTimeInterval(5)
    while popup.numberOfItems != 4 && Date() < loadDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(editor().string == "hello\r\nworld\r\n", "async open must load text")
    controller.execute("edit.uppercase")
    waitForTransform()
    precondition(controller.window!.isDocumentEdited)
    controller.execute("file.save")
    precondition(!editor().isEditable, "save must lock editing")
    let saveDeadline = Date().addingTimeInterval(5)
    while !editor().isEditable && Date() < saveDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(editor().isEditable)
    let saved = try! DocumentCodec.decode(Data(contentsOf: url))
    precondition(
      saved == DecodedDocument(text: "HELLO\r\nWORLD\r\n", encoding: .utf16LE, hasBOM: true))
    precondition(!controller.window!.isDocumentEdited)
    let backups = try! BackupStore(directory: BackupStore.defaultDirectory).list()
    let savedBackup = backups.first { $0.originalPath == url.path }
    precondition(savedBackup != nil, "normal save must preserve the previous file")
    precondition(savedBackup!.encoding == .utf16LE)
    precondition(
      try! BackupStore(directory: BackupStore.defaultDirectory).read(id: savedBackup!.id) == bytes)
    let backupRestore = EditorWindowController()
    var restoredBackup = false
    Task {
      try! await backupRestore.restoreBackup(savedBackup!, data: bytes)
      restoredBackup = true
    }
    let restoreBackupDeadline = Date().addingTimeInterval(5)
    while !restoredBackup && Date() < restoreBackupDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(restoredBackup)
    let backupEditor = descendants(backupRestore.window!.contentView!).compactMap {
      $0 as? NSTextView
    }.first!
    precondition(backupEditor.string == "hello\r\nworld\r\n")
    precondition(
      backupRestore.window!.representedURL == nil, "backup restore must be a scratch document")
    precondition(
      try! Data(contentsOf: url) == DocumentCodec.encode(saved), "restore must not change original")
    let unexpectedBackup = BackupStore.defaultDirectory.appendingPathComponent("unexpected.txt")
    try! Data("synthetic obstruction".utf8).write(to: unexpectedBackup)
    editor().insertText("unsaved", replacementRange: NSRange(location: 0, length: 0))
    var sawBackupFailure = false
    let dismissBackupFailure = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) {
      timer in
      if let modal = NSApp.modalWindow {
        sawBackupFailure = true
        descendants(modal.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }?
          .performClick(nil)
        timer.invalidate()
      }
    }
    RunLoop.main.add(dismissBackupFailure, forMode: .modalPanel)
    controller.execute("file.save")
    let backupFailureDeadline = Date().addingTimeInterval(5)
    while !sawBackupFailure && Date() < backupFailureDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    dismissBackupFailure.invalidate()
    precondition(sawBackupFailure && editor().isEditable && controller.window!.isDocumentEdited)
    precondition(
      try! Data(contentsOf: url) == DocumentCodec.encode(saved),
      "backup failure must leave original unchanged")
    try! FileManager.default.removeItem(at: unexpectedBackup)
    let normalizationURL = directory.appendingPathComponent("normalization.txt")
    try! Data("e\u{301}".utf8).write(to: normalizationURL)
    controller.open(normalizationURL)
    let normalizationDeadline = Date().addingTimeInterval(5)
    while popup.numberOfItems != 5 && Date() < normalizationDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    editor().insertText("é", replacementRange: NSRange(location: 0, length: 2))
    precondition(controller.window!.isDocumentEdited, "normalization-only edits must remain dirty")
    controller.newDocument()
    editor().insertText("{\"b\":2,\"a\":1}", replacementRange: NSRange(location: 0, length: 0))
    controller.execute("tool.formatJSON")
    let jsonDeadline = Date().addingTimeInterval(5)
    while !editor().string.contains("\n") && Date() < jsonDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(editor().string.contains("\n"), "JSON command must pretty print")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(editor().string == "{\"b\":2,\"a\":1}", "one native undo reverses JSON formatting")
    controller.newDocument()
    editor().insertText("let answer = 42", replacementRange: NSRange(location: 0, length: 0))
    let language = descendants(content).compactMap { $0 as? NSPopUpButton }[1]
    language.selectItem(withTitle: "swift")
    _ = language.target?.perform(language.action, with: language)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    precondition(
      editor().layoutManager?.temporaryAttribute(
        .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil,
      "manual Swift language must apply native display tokens")
    precondition(editor().string == "let answer = 42")
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.execute("edit.commentLine")
    let commentDeadline = Date().addingTimeInterval(5)
    while !editor().isEditable && Date() < commentDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(
      editor().string == "// let answer = 42", "language comment command must edit native buffer")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(editor().string == "let answer = 42", "one undo must reverse comment")
    language.selectItem(withTitle: "plainText")
    _ = language.target?.perform(language.action, with: language)
    precondition(
      editor().layoutManager?.temporaryAttribute(
        .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
      "plain text mode must clear display highlighting")
    controller.newDocument()
    controller.applySettings(EditorSettings(fontSize: 18, wrap: false, tabWidth: 6))
    precondition(editor().font?.pointSize == 18)
    precondition(editor().isHorizontallyResizable)
    let tabInterval = editor().defaultParagraphStyle!.defaultTabInterval
    precondition(tabInterval > 0)
    controller.newDocument()
    precondition(editor().font?.pointSize == 18, "new documents inherit font settings")
    precondition(editor().isHorizontallyResizable, "new documents inherit wrap settings")
    precondition(editor().defaultParagraphStyle!.defaultTabInterval == tabInterval)
    controller.execute("macro.start")
    editor().insertText("hello😀", replacementRange: NSRange(location: 0, length: 0))
    controller.execute("edit.uppercase")
    waitForTransform()
    let recorded = controller.recordingSnapshot(named: "Synthetic macro")!
    precondition(
      try! MacroPlayer.replay(recorded, on: "") == "HELLO😀",
      "recording must capture real native text commands")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if let modal = NSApp.modalWindow {
        descendants(modal.contentView!).compactMap { $0 as? NSButton }.first {
          $0.title == "Cancel"
        }?.performClick(nil)
      }
    }
    controller.execute("macro.stop")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if let modal = NSApp.modalWindow {
        descendants(modal.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }?
          .performClick(nil)
      }
    }
    controller.execute("macro.start")
    precondition(
      controller.recordingSnapshot(named: "Synthetic macro")?.commands == recorded.commands,
      "starting again must not erase an unsaved recording after cancelling Save")
    controller.execute("macro.discard")
    controller.newDocument()
    controller.replay(recorded, repeatCount: 1)
    let replayDeadline = Date().addingTimeInterval(5)
    while !editor().isEditable && Date() < replayDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(editor().string == "HELLO😀", "native macro replay must apply result")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(editor().string.isEmpty, "one undo must reverse complete macro replay")
    editor().insertText("hello", replacementRange: NSRange(location: 0, length: 0))
    controller.execute("tool.textUtilities")
    let utilitiesWindow = NSApp.windows.first { $0.windowController is TextUtilitiesController }!
    let utilityReplace = descendants(utilitiesWindow.contentView!).compactMap { $0 as? NSButton }
      .first { $0.title == "Replace" }!
    let utilityDeadline = Date().addingTimeInterval(5)
    while !utilityReplace.isEnabled && Date() < utilityDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(utilityReplace.isEnabled)
    utilityReplace.performClick(nil)
    precondition(editor().string == "aGVsbG8=", "conversion must reach the real editor")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(editor().string == "hello", "one native undo reverses conversion")
    utilitiesWindow.close()
    controller.newDocument()
    editor().string = "😀a\r\ne\u{301}b"
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.navigate(line: 2, column: 2)
    let navigationDeadline = Date().addingTimeInterval(5)
    while editor().selectedRange().location != 7 && Date() < navigationDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(
      editor().selectedRange() == NSRange(location: 7, length: 0),
      "navigation must respect CRLF and grapheme columns")
    controller.newDocument()
    editor().string = "a\r\n"
    func waitForEdit() {
      let deadline = Date().addingTimeInterval(5)
      while !editor().isEditable && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(editor().isEditable, "background line command must finish")
    }
    editor().setSelectedRange(NSRange(location: 3, length: 0))
    controller.execute("edit.line.duplicate")
    waitForEdit()
    precondition(editor().string == "a\r\n\r\n" && editor().selectedRange().location == 5)
    editor().undoManager?.undo()
    precondition(editor().string == "a\r\n", "one undo restores EOF line duplication")
    editor().setSelectedRange(NSRange(location: 3, length: 0))
    controller.execute("edit.line.delete")
    waitForEdit()
    precondition(editor().string == "a" && editor().selectedRange().location == 1)
    editor().undoManager?.undo()
    precondition(editor().string == "a\r\n", "one undo restores deletion of the empty final line")
    editor().string = "a\r\nb\nc\rd"
    editor().setSelectedRange(NSRange(location: 3, length: 2))
    controller.execute("macro.start")
    controller.execute("edit.line.moveDown")
    waitForEdit()
    precondition(editor().string == "a\r\nc\nb\rd")
    precondition(editor().selectedRange() == NSRange(location: 5, length: 2))
    let lineMacro = controller.recordingSnapshot(named: "Line movement")!
    precondition(try! MacroPlayer.replay(lineMacro, on: "a\r\nb\nc\rd") == editor().string)
    controller.execute("macro.discard")
    editor().undoManager?.undo()
    precondition(editor().string == "a\r\nb\nc\rd")
    let beforeStaleCommand = editor().string
    editor().setSelectedRange(NSRange(location: 3, length: 0))
    let dismissStaleAlert = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
      if let modal = NSApp.modalWindow,
        let button = descendants(modal.contentView!).compactMap({ $0 as? NSButton }).first(where: {
          $0.title == "OK"
        })
      {
        button.performClick(nil)
        timer.invalidate()
      }
    }
    RunLoop.main.add(dismissStaleAlert, forMode: .modalPanel)
    controller.execute("edit.line.delete")
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    waitForEdit()
    dismissStaleAlert.invalidate()
    precondition(
      editor().string == beforeStaleCommand, "cursor-only changes must cancel late line commands")
    var sawStatistics = false
    let inspectStatistics = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
      if let modal = NSApp.modalWindow {
        let views = descendants(modal.contentView!)
        let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        precondition(
          labels.contains("UTF-8 bytes without BOM: 8"),
          "statistics dialog must display the actual computed snapshot")
        sawStatistics = true
        views.compactMap { $0 as? NSButton }.first { $0.title == "OK" }?.performClick(nil)
        timer.invalidate()
      }
    }
    RunLoop.main.add(inspectStatistics, forMode: .modalPanel)
    controller.execute("tool.statistics")
    let statisticsDeadline = Date().addingTimeInterval(5)
    while !sawStatistics && Date() < statisticsDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    inspectStatistics.invalidate()
    precondition(sawStatistics)
    controller.newDocument()
    editor().insertText("a\nb\nc", replacementRange: NSRange(location: 0, length: 0))
    editor().setSelectedRange(NSRange(location: 2, length: 0))
    controller.execute("bookmark.toggle")
    waitForTransform()
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.execute("bookmark.next")
    waitForTransform()
    precondition(
      editor().selectedRange().location == 2, "bookmark navigation must select marked line")
    editor().insertText("prefix\n", replacementRange: NSRange(location: 0, length: 0))
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.execute("bookmark.next")
    waitForTransform()
    precondition(editor().selectedRange().location == 9, "bookmarks must follow inserted lines")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().breakUndoCoalescing()
    editor().insertText("", replacementRange: NSRange(location: 9, length: 2))
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(editor().string == "prefix\na\nb\nc")
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.execute("bookmark.next")
    waitForTransform()
    precondition(
      editor().selectedRange().location == 9, "native undo must restore deleted bookmark metadata")
    editor().undoManager?.redo()
    precondition(editor().string == "prefix\na\nc")
    let bookmarkRuler = editor().enclosingScrollView!.verticalRulerView as! LineNumberRuler
    precondition(
      bookmarkRuler.accessibilityLabel()?.contains("0 bookmarks") == true,
      "redo must remove the restored bookmark")
    editor().undoManager?.undo()
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.execute("edit.line.duplicate")
    waitForTransform()
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    controller.execute("bookmark.next")
    waitForTransform()
    precondition(
      editor().selectedRange().location == 16,
      "line command must retain an unrelated later bookmark")
    // Exercise NSTextInputClient composition APIs; this is not physical IME acceptance.
    controller.newDocument()
    editor().insertText("a\nmarked\nend", replacementRange: NSRange(location: 0, length: 0))
    editor().setSelectedRange(NSRange(location: 2, length: 0))
    controller.execute("bookmark.toggle")
    waitForTransform()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().undoManager!.removeAllActions()
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    editor().setMarkedText(
      "漢", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    let compositionRuler = editor().enclosingScrollView!.verticalRulerView as! LineNumberRuler
    precondition(
      compositionRuler.bookmarkOffsets == [3],
      "Provisional marked text must remap bookmarks before the next input callback")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().setMarkedText(
      "漢字", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    precondition(
      compositionRuler.bookmarkOffsets == [4], "Repeated marked updates must use current anchors")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
    precondition(editor().string == "漢字a\nmarked\nend")
    precondition(compositionRuler.bookmarkOffsets == [4])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    controller.window!.makeFirstResponder(editor())
    precondition(
      editor().tryToPerform(NSSelectorFromString("undo:"), with: nil),
      "Undo must route through the actual responder chain")
    precondition(
      editor().string == "a\nmarked\nend", "One native undo must revert the committed composition")
    precondition(
      compositionRuler.bookmarkOffsets == [2], "Composition undo must restore original bookmarks")
    precondition(
      editor().tryToPerform(NSSelectorFromString("redo:"), with: nil),
      "Redo must route through the actual responder chain")
    precondition(editor().string == "漢字a\nmarked\nend" && compositionRuler.bookmarkOffsets == [4])
    editor().undoManager!.removeAllActions()
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    editor().setMarkedText(
      "仮", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    precondition(compositionRuler.bookmarkOffsets == [5])
    editor().setMarkedText(
      "", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor().markedRange())
    editor().unmarkText()
    precondition(
      editor().string == "漢字a\nmarked\nend" && compositionRuler.bookmarkOffsets == [4],
      "Removing provisional text must restore anchor positions")
    // Restore a replaced bookmarked line by canceling its provisional replacement.
    editor().setMarkedText(
      "仮", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 4, length: 7))
    precondition(compositionRuler.bookmarkOffsets.isEmpty)
    editor().setMarkedText(
      "marked\n", selectedRange: NSRange(location: 7, length: 0),
      replacementRange: editor().markedRange())
    editor().unmarkText()
    precondition(
      editor().string == "漢字a\nmarked\nend" && compositionRuler.bookmarkOffsets == [4],
      "Cancel restoring original marked line must restore its deleted bookmark")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().undoManager!.undo()
    precondition(
      editor().string == "漢字a\nmarked\nend" && compositionRuler.bookmarkOffsets == [4],
      "Undo of restored composition must preserve original text and bookmarks")
    editor().undoManager!.redo()
    precondition(
      editor().string == "漢字a\nmarked\nend" && compositionRuler.bookmarkOffsets == [4],
      "Redo of restored composition must preserve original text and bookmarks")
    let nativeBaseline = NSTextView()
    nativeBaseline.string = "漢字a\nmarked\nend"
    nativeBaseline.setMarkedText(
      "仮", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 4, length: 7))
    nativeBaseline.setMarkedText(
      "marked\n", selectedRange: NSRange(location: 7, length: 0),
      replacementRange: nativeBaseline.markedRange())
    nativeBaseline.unmarkText()
    precondition(
      nativeBaseline.string == editor().string,
      "Restoring original marked text then unmarking must match plain NSTextView behavior")
    editor().undoManager!.removeAllActions()
    editor().insertText("漢", replacementRange: NSRange(location: 0, length: 1))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().undoManager!.undo()
    precondition(
      editor().string == "漢字a\nmarked\nend" && compositionRuler.bookmarkOffsets == [4],
      "No-op edit and undo must retain bookmark metadata")
    controller.newDocument()
    editor().insertText("a\nmarked\nend", replacementRange: NSRange(location: 0, length: 0))
    editor().setSelectedRange(NSRange(location: 2, length: 0))
    controller.execute("bookmark.toggle")
    waitForTransform()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().undoManager!.removeAllActions()
    editor().setSelectedRange(NSRange(location: 0, length: 0))
    let typingRuler = editor().enclosingScrollView!.verticalRulerView as! LineNumberRuler
    for character in ["x", "y", "z"] {
      editor().insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    precondition(typingRuler.bookmarkOffsets == [5])
    editor().undoManager!.undo()
    precondition(
      editor().string == "a\nmarked\nend" && typingRuler.bookmarkOffsets == [2],
      "Contiguous native typing must retain one coalesced undo with exact bookmarks")
    editor().undoManager!.redo()
    precondition(editor().string == "xyza\nmarked\nend" && typingRuler.bookmarkOffsets == [5])
    editor().insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().undoManager!.removeAllActions()
    editor().insertText("w", replacementRange: NSRange(location: NSNotFound, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    editor().undoManager!.undo()
    precondition(
      editor().string == "xyzqa\nmarked\nend" && typingRuler.bookmarkOffsets == [6],
      "Clearing undo history must reset the bookmark typing run")
    let beforeRejectedText = editor().string
    let beforeRejectedBookmarks = typingRuler.bookmarkOffsets
    let beforeRejectedCanUndo = editor().undoManager!.canUndo
    let dismissRejectedEdit = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
      if let modal = NSApp.modalWindow,
        let button = descendants(modal.contentView!).compactMap({ $0 as? NSButton }).first(where: {
          $0.title == "OK"
        })
      {
        button.performClick(nil)
        timer.invalidate()
      }
    }
    RunLoop.main.add(dismissRejectedEdit, forMode: .modalPanel)
    let acceptedInvalidEdit = controller.textView(
      editor(), shouldChangeTextIn: NSRange(location: editor().string.utf16.count + 1, length: 0),
      replacementString: "invalid")
    dismissRejectedEdit.invalidate()
    precondition(
      !acceptedInvalidEdit && editor().string == beforeRejectedText
        && typingRuler.bookmarkOffsets == beforeRejectedBookmarks
        && editor().undoManager!.canUndo == beforeRejectedCanUndo,
      "Rejected edits must not mutate text, bookmarks, or undo availability")
    let workspaceFilter = descendants(controller.window!.contentView!).compactMap {
      $0 as? NSSearchField
    }.first!
    controller.execute("view.workspace")
    workspaceFilter.isEnabled = true
    controller.window!.makeFirstResponder(workspaceFilter)
    let fieldEditor = controller.window!.firstResponder as! NSTextView
    precondition(fieldEditor.isFieldEditor)
    let documentBeforeFilterUndo = editor().string
    fieldEditor.insertText("filter", replacementRange: NSRange(location: NSNotFound, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(fieldEditor.tryToPerform(Selector(("undo:")), with: nil))
    precondition(
      fieldEditor.string.isEmpty && editor().string == documentBeforeFilterUndo,
      "Field editor Undo must affect its input without undoing document text")
    controller.window!.makeFirstResponder(editor())
    controller.newDocument()
    let outlineText = "func outlineTarget() {}"
    editor().insertText(outlineText, replacementRange: NSRange(location: 0, length: 0))
    language.selectItem(withTitle: "swift")
    _ = language.target?.perform(language.action, with: language)
    controller.execute("tool.outline")
    let outlineWindow = NSApp.windows.first { $0.windowController is OutlineController }!
    let outlineViews = descendants(outlineWindow.contentView!)
    let outlineTable = outlineViews.compactMap { $0 as? NSTableView }.first!
    let outlineQuery = outlineViews.compactMap { $0 as? NSSearchField }.first!
    let outlineDeadline = Date().addingTimeInterval(5)
    while outlineTable.numberOfRows != 1 && Date() < outlineDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(outlineTable.numberOfRows == 1)
    controller.newDocument()
    _ = NSApp.sendAction(outlineQuery.action!, to: outlineQuery.target, from: outlineQuery)
    precondition(
      editor().string == outlineText, "outline navigation must return to its captured document")
    precondition(
      (editor().string as NSString).substring(with: editor().selectedRange()) == "outlineTarget")
    outlineWindow.close()
    controller.newDocument()
    controller.window!.orderFront(nil)
    controller.execute("document.encoding")
    let encodingSheet = controller.window!.attachedSheet!
    let encodingViews = descendants(encodingSheet.contentView!)
    let encodingChoice = encodingViews.compactMap { $0 as? NSPopUpButton }.first!
    encodingChoice.selectItem(at: 1)
    let convertEncoding = encodingViews.compactMap { $0 as? NSButton }.first {
      $0.title == "Convert Encoding"
    }!
    convertEncoding.performClick(nil)
    let conversionDeadline = Date().addingTimeInterval(5)
    while !editor().isEditable && Date() < conversionDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(
      controller.window!.isDocumentEdited, "encoding-only changes must mark scratch dirty")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    editor().undoManager?.undo()
    precondition(
      !controller.window!.isDocumentEdited, "encoding conversion must undo to original metadata")
    controller.window!.orderOut(nil)
    backupEditor.insertText(
      "second-window-final", replacementRange: NSRange(location: 0, length: 0))
    var prepared: Bool? = nil
    Task {
      guard await controller.prepareToQuit(persistRecovery: false),
        await backupRestore.prepareToQuit(persistRecovery: false)
      else {
        prepared = false
        return
      }
      precondition(
        !editor().isEditable && !backupEditor.isEditable,
        "all windows freeze before global recovery persistence")
      try! await EditorWindowController.persistPreparedRecovery([controller, backupRestore])
      prepared = true
    }
    let quitDeadline = Date().addingTimeInterval(5)
    while prepared == nil && Date() < quitDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(prepared == true)
    let stateURL = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!)
    let snapshots = try! RecoveryStore(directory: stateURL).loadAll()
    precondition(
      snapshots.contains { $0.text.hasPrefix("second-window-final") },
      "global quit flush must include other windows")
    precondition(
      snapshots.contains {
        $0.text.utf16.elementsEqual("é".utf16) && $0.originalPath == normalizationURL.path
      })
    controller.cancelPreparedQuit()
    backupRestore.cancelPreparedQuit()
    let beforeClose = try! RecoveryStore(directory: stateURL).loadAll().count
    controller.execute("file.close")
    var closed: Bool? = nil
    Task { closed = await EditorWindowController.finishPendingCloses() }
    let closeDeadline = Date().addingTimeInterval(5)
    while closed == nil && Date() < closeDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(closed == true)
    precondition(
      try! RecoveryStore(directory: stateURL).loadAll().count == beforeClose - 1,
      "closing a snapshotted clean scratch must remove its recovery before quit")
    print(
      "PASS native adapter: undo, documents, encoding, normalization dirty, JSON, language, recovery flush and close cleanup"
    )

  }

}
