import AppKit
import PadCore

@main struct SessionWindowHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.path, 1)
    let windowID = UUID()
    let controller = EditorWindowController(id: windowID, restoreStartup: false)
    precondition(controller.sessionMetadata.tabs.isEmpty)
    let saved = DecodedDocument(text: "a\r\n😀", encoding: .utf16BE, hasBOM: true)
    let url = directory.appendingPathComponent("synthetic.txt")
    let bytes = try DocumentCodec.encode(saved)
    try bytes.write(to: url)
    let first = SessionTab(
      originalPath: url.path, pinned: true, encoding: .utf16BE, manualLanguage: .json,
      selection: NSRange(location: 3, length: 2), bookmarks: [0, 3])
    let state = try RestoredViewState.resolve(
      selection: first.selection, bookmarks: first.bookmarks, in: saved.text)
    try controller.restoreSessionTab(
      first, decoded: saved, originalBytes: bytes, url: url, viewState: state)
    precondition(!controller.currentDocumentIsDirty)
    precondition(controller.sessionMetadata.id == windowID)
    precondition(controller.sessionMetadata.tabs == [first])
    precondition(controller.sessionResourceUsage.utf16Count == saved.text.utf16.count)
    precondition(controller.sessionResourceUsage.originalByteCount == bytes.count)
    let recovered = DecodedDocument(text: "scratch 🧪", encoding: .utf8, hasBOM: false)
    let second = SessionTab(originalPath: url.path, selection: NSRange(location: 10, length: 0))
    let recoveredState = try RestoredViewState.resolve(
      selection: second.selection, bookmarks: [], in: recovered.text)
    try controller.restoreSessionTab(
      second, decoded: recovered, originalBytes: nil, url: nil, viewState: recoveredState)
    precondition(controller.currentDocumentIsDirty)
    let metadata = controller.sessionMetadata
    precondition(metadata.tabs.map(\.id) == [first.id, second.id])
    precondition(
      metadata.tabs[1].originalPath == nil,
      "recovered original path must never become a save target")
    precondition(metadata.selectedTabID == second.id)
    precondition(
      controller.sessionResourceUsage.utf16Count == saved.text.utf16.count
        + recovered.text.utf16.count)
    precondition(controller.sessionResourceUsage.originalByteCount == bytes.count)
    controller.selectSessionTab(first.id)
    precondition(controller.sessionMetadata.selectedTabID == first.id)
    precondition(controller.window!.representedURL == url)
    do {
      try controller.restoreSessionTab(
        first, decoded: saved, originalBytes: bytes, url: url, viewState: state)
      preconditionFailure("duplicate restoration ID accepted")
    } catch {}
    precondition(controller.sessionMetadata.tabs.count == 2)
    let repaired = SessionTab()
    try controller.restoreSessionTab(
      repaired, decoded: recovered, originalBytes: nil, url: nil, viewState: recoveredState,
      insertionIndex: 1)
    precondition(controller.sessionMetadata.tabs.map(\.id) == [first.id, repaired.id, second.id])
    do {
      try controller.restoreSessionTab(
        SessionTab(), decoded: recovered, originalBytes: nil, url: nil, viewState: recoveredState,
        insertionIndex: -1)
      preconditionFailure("invalid insertion position accepted")
    } catch {}
    precondition(controller.sessionMetadata.tabs.count == 3)
    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    do {
      try controller.restoreSessionTab(
        SessionTab(), decoded: recovered, originalBytes: nil, url: nil, viewState: recoveredState)
      preconditionFailure("late restore into closed window accepted")
    } catch {}
    print(
      "PASS native session window: stable IDs, order, pin, language, selection, bookmarks, saved bytes, scratch safety and stale import refusal"
    )
  }
}
