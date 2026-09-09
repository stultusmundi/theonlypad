import AppKit
import PadCore

@main struct NativeAdmissionHooksHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    var failures = 0
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      if !value { failures += 1 }
      print("\(value ? "PASS" : "FAIL") \(message)")
    }
    func refuses(_ message: String, _ action: () throws -> Void) {
      do {
        try action()
        check(false, message)
      } catch { check(true, message) }
    }
    let document = EditorDocument()
    document.storage.mutableString.setString("alpha\nbeta\n")
    let view = document.editor
    view.setSelectedRange(NSRange(location: 2, length: 1))
    let range = view.selectedRange()
    let origin = document.scroll.contentView.bounds.origin
    var ended = 0
    view.onTypingRunEnded = { ended += 1 }
    view.canChangeSelection = { false }
    view.setSelectedRange(NSRange(location: 0, length: 0))
    check(view.selectedRange() == range, "direct single selection refuses")
    view.setSelectedRange(
      NSRange(location: 4, length: 0), affinity: .downstream, stillSelecting: false)
    check(view.selectedRange() == range, "affinity selection refuses")
    view.setSelectedRanges(
      [NSValue(range: NSRange(location: 5, length: 0))], affinity: .upstream, stillSelecting: false)
    check(view.selectedRange() == range, "multi selection refuses")
    view.selectedRanges = [NSValue(range: NSRange(location: 6, length: 0))]
    check(view.selectedRange() == range, "selectedRanges property assignment refuses")
    check(ended == 0, "refusal preserves typing history callbacks")
    check(document.scroll.contentView.bounds.origin == origin, "refusal preserves scroll geometry")
    refuses("unauthorized owner scope refuses") {
      try view.withSelectionInstallation(
        authorizedBy: { false },
        {
          view.setSelectedRange(NSRange(location: 0, length: 0))
        })
    }
    try view.withSelectionInstallation(
      authorizedBy: { true },
      {
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(
          view.selectedRange() == NSRange(location: 3, length: 0),
          "authorized owner selection installs")
        refuses("nested installation refuses") {
          try view.withSelectionInstallation(authorizedBy: { true }, {})
        }
      })
    let installed = view.selectedRange()
    view.setSelectedRange(NSRange(location: 0, length: 0))
    check(view.selectedRange() == installed, "scope exit restores rejection")
    var permit = true
    try view.withSelectionInstallation(
      authorizedBy: { permit },
      {
        permit = false
        view.setSelectedRange(NSRange(location: 0, length: 0))
        check(view.selectedRange() == installed, "each setter rechecks authorization")
      })
    var recursive = false
    try view.withSelectionInstallation(
      authorizedBy: {
        if !recursive {
          recursive = true
          refuses("predicate reentry cannot install nested bypass") {
            try view.withSelectionInstallation(authorizedBy: { true }) {}
          }
        }
        return true
      }, {})
    view.canChangeSelection = { true }
    view.onTypingRunEnded = { view.canChangeSelection = { false } }
    let beforeCallback = view.selectedRange()
    view.setSelectedRanges(
      [NSValue(range: NSRange(location: 1, length: 0))], affinity: .downstream,
      stillSelecting: false)
    check(
      view.selectedRange() == beforeCallback,
      "typing callback revocation prevents selection mutation")
    view.onTypingRunEnded = nil
    let manager = document.undoManager
    manager.groupsByEvent = false
    var replay = 0
    func setValue(_ value: String) {
      let previous = document.storage.string
      manager.registerUndo(withTarget: document) { _ in
        replay += 1
        check(manager.isUndoing || manager.isRedoing, "real undo callback is active")
        refuses("close state rejects in-flight undo or redo") {
          _ = try document.captureCloseState()
        }
        setValue(previous)
      }
      document.storage.mutableString.setString(value)
      document.bookmarks =
        (try? DocumentBookmarks(offsets: value.isEmpty ? [] : [0], in: value))
        ?? DocumentBookmarks()
    }
    manager.beginUndoGrouping()
    setValue("changed\n")
    manager.endUndoGrouping()
    let text = document.storage.string
    let marks = document.bookmarks
    document.canUndoRedo = { false }
    manager.undo()
    check(
      replay == 0 && document.storage.string == text && document.bookmarks == marks,
      "actual undo refuses text and bookmark actions")
    check(manager.canUndo && !manager.canRedo, "denied undo retains history")
    if replay != 0 {
      print("Refusal seam failed before subsequent undo checks")
      exit(1)
    }
    manager.undoNestedGroup()
    check(replay == 0 && document.storage.string == text, "direct undoNestedGroup refuses")
    document.canUndoRedo = { true }
    manager.undo()
    check(replay == 1 && manager.canRedo, "reopened admission permits original undo")
    let undone = document.storage.string
    let undoneMarks = document.bookmarks
    document.canUndoRedo = { false }
    manager.redo()
    check(
      replay == 1 && document.storage.string == undone && document.bookmarks == undoneMarks,
      "actual redo refuses without dropping history")
    check(manager.canRedo, "denied redo retains history")
    document.canUndoRedo = nil
    manager.redo()
    check(replay == 2 && document.storage.string == text, "legacy nil admission permits redo")
    let grouped = EditorDocument()
    grouped.storage.mutableString.setString("original\n")
    let registry = ApplicationDocuments(
      closeServices: .init { try ($0 as! EditorDocument).captureCloseState() })
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    try registry.registerDocument(
      grouped, metadata: .init(pinned: false), in: assignment, at: 0, select: true)
    grouped.canUndoRedo = { registry.allows(.undoRedo, documentID: grouped.id) }
    let groupedUndo = grouped.undoManager
    groupedUndo.groupsByEvent = false
    var actionOrder: [String] = []
    func groupedValue(_ text: String, marker: String) {
      let old = grouped.storage.string
      let oldBookmarks = grouped.bookmarks
      groupedUndo.registerUndo(withTarget: grouped) { _ in
        actionOrder.append(marker)
        refuses("real registry close refuses between grouped actions") {
          _ = try registry.requestClose(documentID: grouped.id)
        }
        groupedValue(old, marker: marker)
        grouped.bookmarks = oldBookmarks
      }
      grouped.storage.mutableString.setString(text)
      grouped.bookmarks = try! DocumentBookmarks(offsets: [0], in: text)
    }
    groupedUndo.beginUndoGrouping()
    groupedValue("intermediate\n", marker: "first")
    groupedValue("final 😀\n", marker: "second")
    groupedUndo.endUndoGrouping()
    let finalText = grouped.storage.string
    let finalBookmarks = grouped.bookmarks
    groupedUndo.undo()
    check(actionOrder == ["second", "first"], "both actions undo in reverse order")
    check(
      grouped.storage.string == "original\n" && grouped.bookmarks.offsets.isEmpty,
      "group undo restores exact original text and bookmarks")
    check(groupedUndo.canRedo, "group redo remains available")
    groupedUndo.redo()
    check(
      actionOrder == ["second", "first", "first", "second"], "both actions redo in original order")
    check(
      grouped.storage.string.utf16.elementsEqual(finalText.utf16)
        && grouped.bookmarks == finalBookmarks, "group redo restores exact final text and bookmarks"
    )
    check(
      registry.closeStatus(documentID: grouped.id) == .open, "reentrant close never acquires lease")
    print("Native admission checks: \(checks), failures: \(failures)")
    if failures != 0 { exit(1) }
  }
}
