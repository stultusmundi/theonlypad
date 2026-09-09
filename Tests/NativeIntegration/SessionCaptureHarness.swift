import AppKit
import PadCore

@MainActor private func captureViews(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(captureViews)
}
private final class CaptureWriteGate: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  let fault: SaveFault?
  init(fault: SaveFault? = nil) { self.fault = fault }
  private let lock = NSLock()
  private var entered = false
  var isEntered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entered
  }
  func write(_ bytes: Data, to url: URL, expected: Data?) throws {
    lock.lock()
    entered = true
    lock.unlock()
    precondition(release.wait(timeout: .now() + 5) == .success)
    try AtomicFileStore().save(bytes, to: url, expected: expected, fault: fault)
  }
}
@main struct SessionCaptureHarness {
  @MainActor static func until(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    preconditionFailure("native capture boundary not reached")
  }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.path, 1)
    let editor = EditorWindowController(restoreStartup: false)
    let exact = "😀\r\nsecond\rthird\n👩🏽‍💻"
    let snapshot = DecodedDocument(text: exact, encoding: .utf16BE, hasBOM: true)
    let tab = SessionTab(
      pinned: true, selection: NSRange(location: 4, length: 6), bookmarks: [0, 4, 11, 17])
    let state = try RestoredViewState.resolve(
      selection: tab.selection, bookmarks: tab.bookmarks, in: exact)
    try editor.restoreSessionTab(
      tab, decoded: snapshot, originalBytes: nil, url: nil, viewState: state)
    let first = try editor.captureSessionCheckpoint()
    precondition(first.liveTabIDs == [tab.id] && first.window.tabs.count == 1)
    let firstItem = first.recovery[0]
    precondition(firstItem.snapshot!.text.utf16.elementsEqual(exact.utf16))
    precondition(firstItem.snapshot!.encoding == .utf16BE && firstItem.snapshot!.hasBOM)
    precondition(
      first.window.tabs[0].selection == tab.selection
        && first.window.tabs[0].bookmarks == tab.bookmarks)
    let native = captureViews(editor.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    native.setSelectedRange(NSRange(location: 0, length: 2))
    native.insertText("🧪", replacementRange: NSRange(location: 0, length: 2))
    let second = try editor.captureSessionCheckpoint()
    precondition(second.recovery[0].revision > firstItem.revision)
    precondition(
      firstItem.snapshot!.text.utf16.elementsEqual(exact.utf16),
      "capture must remain immutable after later edits")
    precondition(second.recovery[0].snapshot!.text.utf16.elementsEqual(native.string.utf16))
    precondition(second.window.tabs[0].selection == native.selectedRange())
    let clean = DecodedDocument(text: "saved\r\n", encoding: .utf8, hasBOM: false)
    let url = directory.appendingPathComponent("saved.txt")
    let bytes = try DocumentCodec.encode(clean)
    try bytes.write(to: url)
    let cleanTab = SessionTab(originalPath: url.path)
    try editor.restoreSessionTab(
      cleanTab, decoded: clean, originalBytes: bytes, url: url,
      viewState: try RestoredViewState.resolve(
        selection: .init(location: 0, length: 0), bookmarks: [], in: clean.text))
    let paired = try editor.captureSessionCheckpoint()
    precondition(paired.liveTabIDs == [tab.id, cleanTab.id])
    precondition(paired.recovery.first { $0.id == cleanTab.id }!.snapshot == nil)
    precondition(paired.recovery.first { $0.id == tab.id }!.snapshot != nil)
    let saveGate = CaptureWriteGate()
    let saving = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(
        write: { try saveGate.write($0, to: $1, expected: $2) }, backup: { _, _, _ in }),
      onError: { _ in preconditionFailure("synthetic save failed") })
    try saving.restoreSessionTab(
      cleanTab, decoded: clean, originalBytes: bytes, url: url,
      viewState: try RestoredViewState.resolve(
        selection: .init(location: 0, length: 0), bookmarks: [], in: clean.text))
    let savingText = captureViews(saving.window!.contentView!).compactMap { $0 as? NSTextView }
      .first!
    savingText.insertText("dirty 🧪", replacementRange: .init(location: 0, length: 0))
    saving.execute("file.save")
    await until { saveGate.isEntered }
    let duringSave = try saving.captureSessionCheckpoint()
    precondition(
      duringSave.recovery[0].snapshot != nil, "an in-flight save must retain recoverable text")
    precondition(duringSave.recovery[0].snapshot!.text.utf16.elementsEqual(savingText.string.utf16))
    saveGate.release.signal()
    await until { !saving.currentDocumentIsDirty }
    let savedCapture = try saving.captureSessionCheckpoint()
    precondition(savedCapture.recovery[0].snapshot == nil)
    let originalURL = directory.appendingPathComponent("save-as-original.txt")
    let destinationURL = directory.appendingPathComponent("save-as-attempt.txt")
    try bytes.write(to: originalURL)
    let uncertainGate = CaptureWriteGate(fault: .directorySync)
    var saveAsErrors: [Error] = []
    let saveAs = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(
        write: { try uncertainGate.write($0, to: $1, expected: $2) }, backup: { _, _, _ in }),
      chooseSaveDestination: { _, _ in destinationURL }, onError: { saveAsErrors.append($0) })
    let originalTab = SessionTab(originalPath: originalURL.path)
    try saveAs.restoreSessionTab(
      originalTab, decoded: clean, originalBytes: bytes, url: originalURL,
      viewState: try RestoredViewState.resolve(
        selection: .init(location: 0, length: 0), bookmarks: [], in: clean.text))
    let saveAsText = captureViews(saveAs.window!.contentView!).compactMap { $0 as? NSTextView }
      .first!
    let changedSaveAs = "pending Save As 🧪\r\n"
    saveAsText.insertText(
      changedSaveAs, replacementRange: .init(location: 0, length: saveAsText.string.utf16.count))
    saveAs.execute("file.saveAs")
    await until { uncertainGate.isEntered }
    let duringSaveAs = try saveAs.captureSessionCheckpoint()
    precondition(
      duringSaveAs.window.tabs[0].originalPath == originalURL.path,
      "Pending Save As must retain the original metadata URL until publication succeeds")
    precondition(duringSaveAs.recovery[0].snapshot!.originalPath == originalURL.path)
    precondition(duringSaveAs.recovery[0].snapshot!.text.utf16.elementsEqual(changedSaveAs.utf16))
    uncertainGate.release.signal()
    await until { saveAsErrors.count == 1 && saveAsText.isEditable }
    precondition(saveAs.currentSaveIsUncertain)
    saveAsText.insertText(
      clean.text, replacementRange: .init(location: 0, length: saveAsText.string.utf16.count))
    let uncertainBaseline = try saveAs.captureSessionCheckpoint()
    precondition(
      saveAs.currentDocumentIsDirty && uncertainBaseline.recovery[0].snapshot != nil,
      "Returning to the saved baseline must not clear recovery for an uncertain publication")
    precondition(uncertainBaseline.recovery[0].snapshot!.text.utf16.elementsEqual(clean.text.utf16))
    precondition(uncertainBaseline.window.tabs[0].originalPath == originalURL.path)
    precondition(uncertainBaseline.recovery[0].snapshot!.originalPath == originalURL.path)
    precondition(uncertainBaseline.window.tabs[0].selection == saveAsText.selectedRange())
    precondition(try! Data(contentsOf: originalURL) == bytes)
    precondition(try! Data(contentsOf: destinationURL) == Data(changedSaveAs.utf8))
    saveAs.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    saving.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    editor.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    do {
      _ = try editor.captureSessionCheckpoint()
      preconditionFailure("closed window cannot be captured")
    } catch {}
    print(
      "PASS coherent native capture: exact text, immutable pairs, selection/bookmarks, scratch/clean dispositions"
    )
  }
}
