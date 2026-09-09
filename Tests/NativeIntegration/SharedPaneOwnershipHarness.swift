import AppKit
import PadCore

@main struct SharedPaneOwnershipHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let document = EditorDocument()
    let left = document.panePool[0]
    let right = try document.makePane()
    right.attach()
    precondition(document.storage.layoutManagers.count == 2)
    precondition(left.editor.undoManager === right.editor.undoManager)
    let original = "a😀e\u{301}\r\nz\rfinal\n"
    document.storage.mutableString.setString(original)
    document.savedText = original
    precondition(!document.dirty)
    left.editor.setSelectedRange(NSRange(location: 1, length: 0))
    right.editor.setSelectedRange(NSRange(location: 7, length: 0))
    precondition(left.editor.selectedRange() != right.editor.selectedRange())
    var notifications = 0
    document.onCharactersChanged = { notifications += 1 }
    let revision = document.editRevision
    let captureRevision = document.recoveryRevision
    document.undoManager.beginUndoGrouping()
    left.editor.insertText("X", replacementRange: NSRange(location: 1, length: 0))
    document.undoManager.endUndoGrouping()
    precondition(document.editRevision == revision + 1)
    precondition(notifications == 1, "one observer per logical document")
    precondition(document.recoveryRevision == captureRevision)
    let edited = document.storage.string
    precondition(document.dirty)
    right.editor.undoManager!.undo()
    precondition(document.storage.string.utf16.elementsEqual(original.utf16))
    precondition(!document.dirty)
    right.editor.undoManager!.redo()
    precondition(document.storage.string.utf16.elementsEqual(edited.utf16))
    left.detach()
    precondition(document.storage.layoutManagers.count == 1)
    right.editor.undoManager!.undo()
    precondition(document.storage.string.utf16.elementsEqual(original.utf16))
    right.editor.undoManager!.redo()
    precondition(document.storage.string.utf16.elementsEqual(edited.utf16))
    left.attach()
    for _ in 0..<100 {
      right.detach()
      let reused = try document.makePane()
      precondition(reused === right)
      right.attach()
    }
    precondition(document.panePool.count == 2)
    do {
      _ = try document.makePane()
      preconditionFailure("third pane admitted")
    } catch {}
    document.storage.mutableString.setString("e\u{301}")
    document.savedText = "é"
    precondition(document.dirty, "normalization-only difference must remain dirty")
    document.savedText = document.storage.string
    precondition(!document.dirty)
    document.hasBOM = true
    precondition(document.dirty)
    document.hasBOM = false
    precondition(!document.dirty)
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let attempted = Data("attempted bytes".utf8)
    let previousURL = fixture.appendingPathComponent("previous.txt")
    document.url = previousURL
    do {
      try AtomicFileStore().save(
        attempted, to: fixture.appendingPathComponent("new.txt"),
        expected: nil, fault: .directorySync)
      preconditionFailure("expected publication uncertainty")
    } catch FileStoreError.publicationUncertain(let evidence) {
      document.pendingPublication = PendingDocumentPublication(evidence: evidence, bytes: attempted)
    }
    precondition(document.dirty, "uncertain publication must stay recoverable at saved text")
    precondition(document.url == previousURL, "uncertain Save As retains old logical URL")
    document.pendingPublication = nil
    precondition(!document.dirty)
    weak var weakDocument: EditorDocument?
    weak var weakEditor: DocumentTextView?
    autoreleasepool {
      let temporary = EditorDocument()
      weakDocument = temporary
      weakEditor = temporary.editor
      temporary.undoManager.beginUndoGrouping()
      temporary.editor.insertText("😀", replacementRange: NSRange(location: 0, length: 0))
      temporary.undoManager.endUndoGrouping()
    }
    let deadline = Date().addingTimeInterval(3)
    while (weakDocument != nil || weakEditor != nil) && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(weakDocument == nil, "document leaked")
    precondition(weakEditor == nil, "native undo retained editor after document disposal")
    print(
      "PASS shared storage/undo, exact Unicode, revisions, selections, bounded detach/reattach, lifetime"
    )
  }
}
