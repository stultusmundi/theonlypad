import AppKit
import PadCore

@MainActor private func views(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(views)
}
@main struct SessionRestorationHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    let entry = UnresolvedSessionEntry(
      windowID: UUID(), metadata: SessionTab(originalPath: "/synthetic/missing.txt"),
      errorMessage: "Missing file")
    var fail = true
    var reads = 0
    var resolved = 0
    var removed = 0
    var failCommit = false
    var failRemove = false
    var failLocate = true
    var continuation: CheckedContinuation<SessionResolvedFile, Error>?
    var delay = false
    let panel = SessionRestorationController(
      entries: [entry],
      onRetry: { _ in
        reads += 1
        if delay { return try await withCheckedThrowingContinuation { continuation = $0 } }
        if fail {
          throw NSError(
            domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Read failed"])
        }
        return SessionResolvedFile(
          url: URL(fileURLWithPath: "/synthetic/missing.txt"), originalBytes: Data("restored".utf8),
          decoded: try DocumentCodec.decode(Data("restored".utf8)))
      },
      onLocate: { _, url in
        if !failLocate {
          return SessionResolvedFile(
            url: url, originalBytes: Data("restored".utf8),
            decoded: try DocumentCodec.decode(Data("restored".utf8)))
        }
        throw NSError(
          domain: "Synthetic", code: 2, userInfo: [NSLocalizedDescriptionKey: "Located file failed"]
        )
      },
      onResolved: { original, file in
        precondition(original.metadata == entry.metadata && file.decoded.text == "restored")
        if failCommit {
          throw NSError(
            domain: "Synthetic", code: 3, userInfo: [NSLocalizedDescriptionKey: "Import failed"])
        }
        resolved += 1
      },
      onRemove: { original in
        precondition(original.metadata == entry.metadata)
        if failRemove {
          throw NSError(
            domain: "Synthetic", code: 4, userInfo: [NSLocalizedDescriptionKey: "Remove failed"])
        }
        removed += 1
      })
    panel.showWindow(nil)
    let content = views(panel.window!.contentView!)
    let table = content.compactMap { $0 as? NSTableView }.first!
    func button(_ id: String) -> NSButton {
      content.first { $0.identifier?.rawValue == id } as! NSButton
    }
    func select() { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    func wait(_ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(3)
      while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(condition(), "Asynchronous panel operation timed out")
    }
    select()
    button("session.retry").performClick(nil)
    wait { !panel.isBusy }
    precondition(
      reads == 1 && panel.entries.first?.metadata == entry.metadata
        && panel.entries.first?.errorMessage == "Read failed")
    fail = false
    button("session.retry").performClick(nil)
    wait { !panel.isBusy }
    precondition(resolved == 1 && panel.entries.isEmpty)
    panel.update(entries: [entry])
    select()
    button("session.locate").performClick(nil)
    wait { panel.window!.attachedSheet is NSOpenPanel }
    (panel.window!.attachedSheet as! NSOpenPanel).cancel(nil)
    wait { !panel.isBusy }
    precondition(panel.entries == [entry] && resolved == 1)
    panel.locateSelected(at: URL(fileURLWithPath: "/synthetic/replacement.txt"))
    wait { !panel.isBusy }
    precondition(
      panel.entries.first?.metadata == entry.metadata
        && panel.entries.first?.errorMessage == "Located file failed")
    failLocate = false
    failCommit = true
    panel.locateSelected(at: URL(fileURLWithPath: "/synthetic/replacement.txt"))
    wait { !panel.isBusy }
    precondition(
      panel.entries.first?.metadata == entry.metadata
        && panel.entries.first?.errorMessage == "Import failed")
    failCommit = false
    panel.locateSelected(at: URL(fileURLWithPath: "/synthetic/replacement.txt"))
    wait { !panel.isBusy }
    precondition(panel.entries.isEmpty && resolved == 2)
    panel.update(entries: [entry])
    select()
    for choice in ["Cancel", "Failed Remove", "Remove"] {
      failRemove = choice == "Failed Remove"
      button("session.remove").performClick(nil)
      wait { panel.window!.attachedSheet != nil }
      let sheet = panel.window!.attachedSheet!
      let target = views(sheet.contentView!).compactMap { $0 as? NSButton }.first {
        $0.title == (choice == "Failed Remove" ? "Remove" : choice)
      }!
      target.performClick(nil)
      wait { !panel.isBusy }
      precondition(removed == (choice == "Remove" ? 1 : 0))
      if failRemove {
        precondition(
          panel.entries.first?.metadata == entry.metadata
            && panel.entries.first?.errorMessage == "Remove failed")
      }
    }
    precondition(panel.entries.isEmpty)
    panel.update(entries: [entry])
    select()
    delay = true
    button("session.retry").performClick(nil)
    wait { continuation != nil }
    button("session.retry").performClick(nil)
    precondition(reads == 3)
    panel.update(entries: [entry])
    continuation!.resume(
      returning: SessionResolvedFile(
        url: URL(fileURLWithPath: "/synthetic/missing.txt"), originalBytes: Data("restored".utf8),
        decoded: try! DocumentCodec.decode(Data("restored".utf8))))
    continuation = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(panel.entries == [entry] && resolved == 2)
    select()
    button("session.retry").performClick(nil)
    wait { continuation != nil }
    panel.close()
    continuation!.resume(
      returning: SessionResolvedFile(
        url: URL(fileURLWithPath: "/synthetic/missing.txt"), originalBytes: Data("restored".utf8),
        decoded: try! DocumentCodec.decode(Data("restored".utf8))))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(panel.entries == [entry] && resolved == 2)
    var replacementReads = 0
    let recoveryEntry = UnresolvedSessionEntry(
      windowID: entry.windowID, metadata: entry.metadata,
      errorMessage: "Recovered text could not be imported", hasRecovery: true)
    let recoveryPanel = SessionRestorationController(
      entries: [recoveryEntry], onRetry: { _ in throw CancellationError() },
      onLocate: { _, url in
        replacementReads += 1
        return SessionResolvedFile(
          url: url, originalBytes: Data("replacement".utf8),
          decoded: try DocumentCodec.decode(Data("replacement".utf8)))
      }, onResolved: { _, _ in }, onRemove: { _ in })
    recoveryPanel.showWindow(nil)
    let recoveryTable = views(recoveryPanel.window!.contentView!).compactMap { $0 as? NSTableView }
      .first!
    recoveryTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    for choice in ["Cancel", "Replace Recovered Text"] {
      recoveryPanel.locateSelected(at: URL(fileURLWithPath: "/synthetic/replacement.txt"))
      wait { recoveryPanel.window!.attachedSheet != nil }
      precondition(replacementReads == 0, "Recovered text must not be replaced before confirmation")
      views(recoveryPanel.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first
      { $0.title == choice }!.performClick(nil)
      wait { !recoveryPanel.isBusy }
      if choice == "Cancel" { precondition(recoveryPanel.entries == [recoveryEntry]) }
    }
    precondition(replacementReads == 1 && recoveryPanel.entries.isEmpty)
    recoveryPanel.close()
    var finishRemoval: CheckedContinuation<Void, Never>?
    var committedRemoval = false
    let closingPanel = SessionRestorationController(
      entries: [entry], onRetry: { _ in throw CancellationError() },
      onLocate: { _, _ in throw CancellationError() }, onResolved: { _, _ in },
      onRemove: { _ in
        await withCheckedContinuation { finishRemoval = $0 }
        committedRemoval = true
      })
    closingPanel.showWindow(nil)
    let closingViews = views(closingPanel.window!.contentView!)
    let closingTable = closingViews.compactMap { $0 as? NSTableView }.first!
    closingTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    (closingViews.first { $0.identifier?.rawValue == "session.remove" } as! NSButton).performClick(
      nil)
    wait { closingPanel.window!.attachedSheet != nil }
    views(closingPanel.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first {
      $0.title == "Remove"
    }!.performClick(nil)
    wait { finishRemoval != nil }
    closingPanel.close()
    finishRemoval!.resume()
    wait { committedRemoval }
    precondition(
      closingPanel.entries == [entry],
      "Late removal may commit externally but must not update closed panel UI")
    print("PASS unresolved session panel: retry, locate, removal, reentrancy and stale completion")
  }
}
