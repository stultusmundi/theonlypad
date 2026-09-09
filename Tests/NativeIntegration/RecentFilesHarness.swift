import AppKit
import PadCore

@MainActor private func recentViews(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(recentViews)
}
@main struct RecentFilesHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let good = directory.appendingPathComponent("good 🐱.txt")
    let missing = directory.appendingPathComponent("missing.txt")
    try Data("synthetic recent text".utf8).write(to: good)
    var historyDone = false
    var historyError: Error?
    Task {
      do { try await checkHistory(directory: directory, good: good) } catch { historyError = error }
      historyDone = true
    }
    func wait(_ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(4)
      while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(condition(), "Recent-files operation timed out")
    }
    wait { historyDone }
    if let historyError { throw historyError }
    var opened: [String] = []
    var removed: [String] = []
    var clears = 0
    var resume: CheckedContinuation<Void, Never>?
    var delayed = false
    var notifyOpened: ((URL) -> Void)?
    let panel = RecentFilesController(
      paths: [missing.path, good.path],
      onOpen: { url, isCurrent in
        if delayed { await withCheckedContinuation { resume = $0 } }
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        guard isCurrent() else { throw CancellationError() }
        opened.append(try DocumentCodec.decode(data).text)
        notifyOpened?(url)
      }, onRemove: { removed.append($0) }, onClear: { clears += 1 })
    notifyOpened = { [weak panel] url in
      guard let panel else { return }
      panel.update(paths: [url.path] + panel.paths.filter { $0 != url.path }, openedPath: url.path)
    }
    panel.showWindow(nil)
    let content = recentViews(panel.window!.contentView!)
    let table = content.compactMap { $0 as? NSTableView }.first!
    func button(_ id: String) -> NSButton {
      content.first { $0.identifier?.rawValue == id } as! NSButton
    }
    let controls = content.filter { $0.identifier?.rawValue.hasPrefix("recents.") == true }
    precondition(controls.count == 5)
    for control in controls {
      precondition(control.accessibilityIdentifier() == control.identifier?.rawValue)
    }
    panel.setSuspended(true)
    button("recents.open").performClick(nil)
    button("recents.remove").performClick(nil)
    button("recents.clear").performClick(nil)
    precondition(
      !button("recents.open").isEnabled && !button("recents.remove").isEnabled
        && !button("recents.clear").isEnabled)
    precondition(
      opened.isEmpty && removed.isEmpty && clears == 0 && panel.paths == [missing.path, good.path],
      "Quit freeze must prevent visible or authoritative MRU mutation")
    panel.setSuspended(false)
    precondition(
      button("recents.open").isEnabled && button("recents.clear").isEnabled,
      "Quit veto must restore recent-file controls")
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    button("recents.open").performClick(nil)
    wait { !panel.isBusy }
    precondition(
      panel.paths == [missing.path, good.path] && opened.isEmpty && !panel.statusMessage.isEmpty,
      "Missing files must retain their recent entry with an error")
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let returnKey = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: panel.window!.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    precondition(
      panel.window!.performKeyEquivalent(with: returnKey),
      "Return must activate Open for the selected row")
    wait { !panel.isBusy }
    precondition(opened == ["synthetic recent text"])
    precondition(
      panel.statusMessage.contains(good.lastPathComponent),
      "Successful MRU refresh must retain an explicit opened-file status")
    button("recents.remove").performClick(nil)
    precondition(
      removed == [good.path] && panel.paths == [missing.path]
        && FileManager.default.fileExists(atPath: good.path),
      "Removing history must not delete the file")
    button("recents.clear").performClick(nil)
    precondition(clears == 1 && panel.paths.isEmpty)
    delayed = true
    panel.update(paths: [good.path, missing.path])
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    button("recents.open").performClick(nil)
    wait { resume != nil }
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    resume!.resume()
    resume = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(opened.count == 1, "Selection change must invalidate a pending open")
    panel.update(paths: [good.path])
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    button("recents.open").performClick(nil)
    wait { resume != nil }
    panel.update(paths: [missing.path])
    resume!.resume()
    resume = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(opened.count == 1, "List replacement must invalidate a pending open")
    panel.update(paths: [good.path])
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    button("recents.open").performClick(nil)
    wait { resume != nil }
    panel.setSuspended(true)
    resume!.resume()
    resume = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(opened.count == 1, "Quit freeze must invalidate an in-flight open")
    panel.setSuspended(false)
    panel.update(paths: [good.path])
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    button("recents.open").performClick(nil)
    wait { resume != nil }
    button("recents.open").performClick(nil)
    panel.close()
    resume!.resume()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(opened.count == 1, "Closed panel must invalidate a late open callback")
    print(
      "PASS recent files: persisted MRU history, failed-open retention, native actions and stale-open guard"
    )
  }
  @MainActor static func checkHistory(directory: URL, good: URL) async throws {
    let store = SessionStore(directory: directory.appendingPathComponent("Session"))
    let older = directory.appendingPathComponent("older.txt").path
    try store.save(EditorSession(windows: [], recentPaths: [older]))
    let coordinator = SessionCoordinator(
      loadSession: { try store.load() },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { try store.save($0) })
    try coordinator.recordRecentOpen(good)
    await coordinator.restore { _ in [:] }
    precondition(
      coordinator.recentPaths == [good.path, older],
      "Early successful opens must survive delayed session history load")
    try coordinator.recordRecentOpen(URL(fileURLWithPath: older))
    precondition(coordinator.recentPaths == [older, good.path])
    try coordinator.recordRecentOpen(good)
    precondition(coordinator.recentPaths == [good.path, older])
    for index in 0..<52 {
      try coordinator.recordRecentOpen(directory.appendingPathComponent("file-\(index).txt"))
    }
    precondition(
      coordinator.recentPaths.count == 50 && coordinator.recentPaths.first!.hasSuffix("file-51.txt")
    )
    let removed = coordinator.recentPaths[1]
    coordinator.removeRecent(removed)
    try await coordinator.persist(windows: [])
    let persisted = try store.load()!
    precondition(
      persisted.recentPaths == coordinator.recentPaths && !persisted.recentPaths.contains(removed))
    coordinator.clearRecent()
    try await coordinator.persist(windows: [])
    let empty = try store.load()!
    precondition(empty.recentPaths.isEmpty)
    do {
      try coordinator.recordRecentOpen(URL(string: "https://example.invalid/file")!)
      fatalError("Only local paths may enter recent files")
    } catch {}
  }
}
