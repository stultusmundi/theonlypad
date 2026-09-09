import AppKit
import PadCore

enum NativeMonitorLocateScenarios {
  @MainActor static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  @MainActor static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    precondition(predicate(), "Locate lifecycle condition did not complete")
  }
  @MainActor static func acceptedMissing(_ bridge: DocumentFileStateController) async throws {
    let prior = bridge.state.token
    bridge.checkAgain()
    try await until {
      bridge.state.token != prior
        && bridge.state.token == bridge.monitorHarnessReceipt?.currentToken
        && bridge.state.observation?.locationProblem == .missing
    }
  }
  @MainActor static func run() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let originalURL = directory.appendingPathComponent("missing.txt")
    let baseline = try DocumentCodec.encode(
      DecodedDocument(text: "original😀\r\nline", encoding: .utf16BE, hasBOM: true))
    try baseline.write(to: originalURL)
    let owner = ApplicationFileMonitoring()
    defer { owner.stop() }
    var errors = 0
    var sessionChanges = 0
    var recentNotifications: [URL] = []
    let controller = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(write: { bytes, url, expected in
        try AtomicFileStore().save(bytes, to: url, expected: expected, fault: .directorySync)
      }), onError: { _ in errors += 1 }, onSessionChange: { sessionChanges += 1 })
    controller.configureFileMonitoring(owner)
    controller.onOpenedURL = { recentNotifications.append($0) }
    owner.onStateChange = { [weak controller] in controller?.reconcileFileMonitoring() }
    controller.newDocument()
    let unrelated = controller.monitorHarnessCurrent!
    var opened = false
    controller.open(
      originalURL, onFailure: { fatalError("Synthetic open failed: \($0)") },
      onOpened: { opened = true })
    try await until { opened }
    let document = controller.monitorHarnessCurrent!
    let bridge = document.fileState!
    try await until { bridge.state.observation?.content == .matchesBaseline }
    try FileManager.default.removeItem(at: originalURL)
    let previous = bridge.state.token
    bridge.checkAgain()
    try await until {
      bridge.state.token != previous && bridge.state.observation?.locationProblem == .missing
        && bridge.state.token == bridge.monitorHarnessReceipt?.currentToken
    }
    guard let panel = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Missing-source panel unavailable")
    }
    precondition(panel.window?.isVisible == false)
    let buttons = descendants(panel.window!.contentView!).compactMap { $0 as? NSButton }
      .filter { $0.accessibilityIdentifier() == "document.locateFile" }
    precondition(
      buttons.count == 1 && buttons[0].isEnabled,
      "Actual missing-source conflict panel must expose admitted Locate File action")
    panel.close()
    precondition(errors == 0 && controller.window?.isVisible == false)
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    document.encoding = .utf8
    document.hasBOM = false
    document.bookmarks = try DocumentBookmarks(offsets: [0], in: document.storage.string)
    try controller.splitCurrent(.sideBySide)
    let panes = document.panePool.filter(\.isAttached)
    panes[0].editor.setSelectedRange(NSRange(location: 1, length: 0))
    panes[1].editor.setSelectedRange(NSRange(location: 3, length: 0))
    let paneIDs = panes.map(\.id)
    let selections = panes.map { $0.editor.selectedRange() }
    let localText = document.storage.string
    let savedText = document.savedText
    let bookmarks = document.bookmarks
    let revision = document.baselineRevision
    let target = directory.appendingPathComponent("located.txt")
    let different = directory.appendingPathComponent("different.txt")
    try baseline.write(to: target)
    try Data("different saved bytes".utf8).write(to: different)
    var chosen: URL?
    var chooserCalls = 0
    var actionSessionBaseline = 0
    var actionRecentBaseline = 0
    controller.chooseDiskLocation = { suggested in
      chooserCalls += 1
      precondition(
        suggested == originalURL,
        "Missing-file chooser starts from original source when no rename hint exists")
      controller.monitorHarnessDisplay(unrelated)
      // The chooser intentionally switches tabs; exclude that legitimate session notification.
      // Any subsequent notification belongs to Locate adoption or its completion/render path.
      actionSessionBaseline = sessionChanges
      return chosen
    }
    func clickLocate() {
      guard let conflict = controller.monitorHarnessDiskConflict(document) else {
        fatalError("Locate factory missing")
      }
      precondition(conflict.window?.isVisible == false)
      let actions = descendants(conflict.window!.contentView!).compactMap { $0 as? NSButton }
        .filter { $0.accessibilityIdentifier() == "document.locateFile" }
      precondition(actions.count == 1 && actions[0].isEnabled)
      actionSessionBaseline = sessionChanges
      actionRecentBaseline = recentNotifications.count
      actions[0].performClick(nil)
      precondition(conflict.window?.isVisible == false)
    }
    func assertPreserved() {
      precondition(document.storage.string == localText && document.savedText == savedText)
      precondition(
        document.originalBytes == baseline && document.dirty && document.undoManager.canUndo)
      precondition(document.encoding == .utf8 && !document.hasBOM)
      precondition(document.savedEncoding == .utf16BE && document.savedHasBOM)
      precondition(document.bookmarks == bookmarks)
      precondition(document.panePool.filter(\.isAttached).map(\.id) == paneIDs)
      precondition(panes.map { $0.editor.selectedRange() } == selections)
      precondition(
        document.splitAxis == .sideBySide && controller.monitorHarnessCurrent === unrelated)
    }
    try await acceptedMissing(document.fileState!)
    clickLocate()
    precondition(
      chooserCalls == 1 && document.url == originalURL && !document.saving && errors == 0)
    precondition(document.baselineRevision == revision)
    precondition(
      sessionChanges == actionSessionBaseline && recentNotifications.count == actionRecentBaseline,
      "Cancelled Locate must not publish a session or recent-file adoption")
    assertPreserved()
    chosen = different
    try await acceptedMissing(document.fileState!)
    clickLocate()
    try await until { !document.saving && errors == 1 }
    precondition(
      chooserCalls == 2 && document.url == originalURL && document.baselineRevision == revision)
    precondition(
      sessionChanges == actionSessionBaseline && recentNotifications.count == actionRecentBaseline,
      "Different-byte refusal must not publish a session or recent-file adoption")
    assertPreserved()
    chosen = target
    try await acceptedMissing(document.fileState!)
    let previousHandle = bridge.monitorHarnessHandle!
    let previousReceipt = previousHandle.snapshot
    clickLocate()
    try await until { !document.saving && document.url == target }
    precondition(chooserCalls == 3 && errors == 1 && document.baselineRevision == revision + 1)
    precondition(
      sessionChanges == actionSessionBaseline + 1,
      "Actual Locate URL adoption must publish exactly one controller session notification")
    precondition(
      recentNotifications.count == actionRecentBaseline + 1 && recentNotifications.last == target,
      "Actual Locate URL adoption must publish exactly one recent-file notification for its target")
    assertPreserved()
    let targetBytes = try Data(contentsOf: target)
    precondition(
      targetBytes == baseline && !FileManager.default.fileExists(atPath: originalURL.path))
    precondition(
      previousHandle.snapshot.cancelled, "Locate must cancel prior path-binding authority")
    let rebound = document.fileState!
    try await until { rebound.state.observation?.content == .matchesBaseline }
    precondition(
      sessionChanges == actionSessionBaseline + 1
        && recentNotifications.count == actionRecentBaseline + 1,
      "Monitor reconciliation after Locate must not duplicate adoption notifications")
    let receipt = rebound.monitorHarnessReceipt!
    precondition(
      receipt.epoch > previousReceipt.epoch && receipt.baselineRevision == document.baselineRevision
    )
    let validated = try ExternalFileProbe().observe(
      target, expected: baseline, boundIdentity: nil,
      forceContents: true, previous: nil, isCancelled: { false })
    precondition(
      receipt.boundIdentity == validated.metadata?.identity && receipt.boundIdentity != nil,
      "Fresh registration must retain validated candidate identity")
    // Real publication uncertainty must remove Locate admission even when source later disappears.
    controller.monitorHarnessSave(document)
    try await until { !document.saving && document.pendingPublication != nil }
    let pending = document.pendingPublication!.id
    try FileManager.default.removeItem(at: target)
    let beforeMissing = rebound.state.token
    rebound.checkAgain()
    try await until {
      rebound.state.token != beforeMissing && rebound.state.observation?.locationProblem == .missing
    }
    guard let uncertain = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Uncertain missing panel missing")
    }
    let uncertainIDs = descendants(uncertain.window!.contentView!).compactMap {
      ($0 as? NSButton)?.accessibilityIdentifier()
    }
    precondition(
      !uncertainIDs.contains("document.locateFile"),
      "Retained publication evidence must exclude Locate")
    precondition(document.pendingPublication?.id == pending)
    uncertain.close()
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: controller.window))
    precondition(controller.window?.isVisible == false)
    print(
      "Native Locate passed: missing action, chooser Cancel, different-byte refusal, captured target/focus, exact-byte metadata/undo/pane preservation, pending-publication exclusion"
    )
  }
}
