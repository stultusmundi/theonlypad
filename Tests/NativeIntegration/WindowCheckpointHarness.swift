import AppKit
import PadCore

@main struct WindowCheckpointHarness {
  @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.path, 1)
    var changes = 0
    let controller = EditorWindowController(
      restoreStartup: false, onSessionChange: { changes += 1 })
    controller.newDocument()
    precondition(changes > 0, "Document creation must notify shared scheduler")
    let native = views(controller.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    let beforeTyping = changes
    native.insertText("😀\r\nsecond", replacementRange: NSRange(location: 0, length: 0))
    precondition(changes > beforeTyping)
    precondition(controller.checkpointRecoveryUTF16Count == native.textStorage!.length)
    let beforeStorageEdit = changes
    native.textStorage!.append(NSAttributedString(string: "!"))
    precondition(changes > beforeStorageEdit, "Direct storage character edits must notify")
    let beforeSelection = changes
    native.setSelectedRange(NSRange(location: 4, length: 2))
    precondition(changes > beforeSelection)
    let beforeBookmark = changes
    controller.execute("bookmark.toggle")
    let bookmarkDeadline = Date().addingTimeInterval(5)
    while controller.sessionMetadata.tabs[0].bookmarks.isEmpty && Date() < bookmarkDeadline {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    precondition(changes > beforeBookmark)
    let capture = try controller.captureSessionCheckpoint()
    precondition(capture.recovery[0].snapshot!.text.utf16.elementsEqual(native.string.utf16))
    precondition(capture.window.tabs[0].selection == native.selectedRange())
    precondition(!capture.window.tabs[0].bookmarks.isEmpty)
    let language = views(controller.window!.contentView!).compactMap { $0 as? NSPopUpButton }
      .first { $0.accessibilityLabel() == "Document language" }!
    let beforeLanguage = changes
    language.selectItem(withTitle: DocumentLanguage.swift.rawValue)
    NSApp.sendAction(language.action!, to: language.target, from: language)
    precondition(
      changes > beforeLanguage && controller.sessionMetadata.tabs[0].manualLanguage == .swift)
    let beforeStatus = changes
    var retries = 0
    controller.updateSessionCheckpointStatus(
      message: "Synthetic checkpoint failure", retry: { retries += 1 })
    let all = views(controller.window!.contentView!)
    let status = all.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityIdentifier() == "session.checkpoint.status"
    }!
    let retry = all.compactMap { $0 as? NSButton }.first {
      $0.accessibilityIdentifier() == "session.checkpoint.retry"
    }!
    precondition(status.stringValue == "Synthetic checkpoint failure" && !retry.isHidden)
    precondition(changes == beforeStatus, "Status rendering must not create checkpoint recursion")
    retry.performClick(nil)
    precondition(retries == 1 && changes == beforeStatus)
    controller.updateSessionCheckpointStatus(message: "Saved")
    precondition(retry.isHidden && changes == beforeStatus)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let stored = try RecoveryStore(directory: directory).loadAll()
    precondition(stored.isEmpty, "Shared mode must not run the legacy debounced text producer")

    // A clean file closes without a discard dialog. An unsafe recovery leaf forces cleanup
    // failure; the throwing barrier must preserve it for a later explicit retry.
    let cleanFile = directory.appendingPathComponent("clean.txt")
    try Data("clean".utf8).write(to: cleanFile)
    let clean = EditorWindowController(restoreStartup: false, onSessionChange: { changes += 1 })
    var opened = false
    clean.open(cleanFile, onOpened: { opened = true })
    let deadline = Date().addingTimeInterval(5)
    while !opened && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    precondition(opened)
    precondition(clean.checkpointRecoveryUTF16Count == 0)
    let cleanText = views(clean.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    cleanText.string = "dirty!"
    precondition(clean.checkpointRecoveryUTF16Count == 6)
    cleanText.string = "clean"
    precondition(clean.checkpointRecoveryUTF16Count == 0)
    let cleanID = clean.sessionMetadata.tabs[0].id
    let unsafeLeaf = directory.appendingPathComponent(cleanID.uuidString + ".json")
    try FileManager.default.createDirectory(at: unsafeLeaf, withIntermediateDirectories: false)
    clean.execute("file.close")
    do {
      try EditorWindowController.assertNoPendingCloses()
      preconditionFailure("A close queued after an earlier drain must block synchronous capture")
    } catch {}
    do {
      _ = try controller.captureSessionCheckpoint()
      preconditionFailure("Window capture must reject pending cleanup from another window")
    } catch {}
    do {
      try await EditorWindowController.drainPendingCloses()
      preconditionFailure("Cleanup failure must propagate nonmodally")
    } catch RecoveryError.invalidSnapshot {}
    precondition(FileManager.default.fileExists(atPath: unsafeLeaf.path))
    do {
      try EditorWindowController.assertNoPendingCloses()
      preconditionFailure("Failed close entries must continue blocking capture")
    } catch {}
    do {
      _ = try controller.captureSessionCheckpoint()
      preconditionFailure("Failed cleanup cannot be omitted from a checkpoint")
    } catch {}
    try FileManager.default.removeItem(at: unsafeLeaf)
    try await EditorWindowController.drainPendingCloses()
    try await EditorWindowController.drainPendingCloses()
    try EditorWindowController.assertNoPendingCloses()
    _ = try controller.captureSessionCheckpoint()
    let frozen = EditorWindowController(restoreStartup: false, onSessionChange: {})
    frozen.newDocument()
    let firstFrozenText = views(frozen.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    firstFrozenText.isSelectable = false
    frozen.newDocument()
    let secondFrozenText = views(frozen.window!.contentView!).compactMap { $0 as? NSTextView }
      .first!
    secondFrozenText.string = "frozen text"
    secondFrozenText.setSelectedRange(NSRange(location: 1, length: 3))
    let beforeFrozen = frozen.sessionMetadata
    let freezeAllowed = await frozen.prepareToQuit(persistRecovery: false)
    precondition(freezeAllowed)
    precondition(!firstFrozenText.isSelectable && !secondFrozenText.isSelectable)
    let tabBar = views(frozen.window!.contentView!).compactMap { $0 as? DocumentTabBar }.first!
    let firstID = beforeFrozen.tabs[0].id
    tabBar.onSelect?(firstID)
    tabBar.onPin?(firstID)
    tabBar.onMove?(firstID, 1)
    let popup = views(frozen.window!.contentView!).compactMap { $0 as? NSPopUpButton }
      .first { $0.accessibilityLabel() == "Open documents" }!
    popup.selectItem(at: 0)
    NSApp.sendAction(popup.action!, to: popup.target, from: popup)
    precondition(
      frozen.sessionMetadata == beforeFrozen,
      "Frozen tab selection, pin and move callbacks cannot change final metadata")
    frozen.cancelPreparedQuit()
    precondition(!firstFrozenText.isSelectable && secondFrozenText.isSelectable)
    frozen.cancelPreparedQuit()
    precondition(!firstFrozenText.isSelectable && secondFrozenText.isSelectable)
    tabBar.onSelect?(firstID)
    precondition(frozen.sessionMetadata.selectedTabID == firstID)

    print(
      "PASS window checkpoint notifications, no legacy writes, paired capture, status/retry and cleanup barrier"
    )
    withExtendedLifetime([controller, clean, frozen]) {}
  }
}
