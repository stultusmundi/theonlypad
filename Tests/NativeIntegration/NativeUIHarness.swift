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
    precondition(editor().string.isEmpty)
    editor().string = "beta\nalpha\n"
    controller.execute("edit.sorted")
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
    var prepared: Bool? = nil
    Task { prepared = await controller.prepareToQuit() }
    let quitDeadline = Date().addingTimeInterval(5)
    while prepared == nil && Date() < quitDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(prepared == true)
    let stateURL = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!)
    let snapshots = try! RecoveryStore(directory: stateURL).loadAll()
    precondition(
      snapshots.contains {
        $0.text.utf16.elementsEqual("é".utf16) && $0.originalPath == normalizationURL.path
      })
    controller.cancelPreparedQuit()
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
