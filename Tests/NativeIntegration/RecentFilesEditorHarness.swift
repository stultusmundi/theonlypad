import AppKit
import PadCore

@MainActor private func editorViews(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(editorViews)
}
@main struct RecentFilesEditorHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let good = directory.appendingPathComponent("good.txt")
    let other = directory.appendingPathComponent("other.txt")
    try Data("saved".utf8).write(to: good)
    try Data("other".utf8).write(to: other)
    let history = SessionCoordinator()
    let target = EditorWindowController(restoreStartup: false)
    var successes = 0
    var failures = 0
    var callbacks = 0
    target.onOpenedURL = { url in
      callbacks += 1
      try! history.recordRecentOpen(url)
    }
    func wait(_ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(4)
      while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(condition(), "Recent editor open timed out")
    }
    target.open(good, onFailure: { _ in failures += 1 }, onOpened: { successes += 1 })
    wait { successes == 1 || failures != 0 }
    precondition(failures == 0 && history.recentPaths == [good.path] && callbacks == 1)
    let text = editorViews(target.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    text.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
    try FileManager.default.removeItem(at: good)
    target.open(good, onFailure: { _ in failures += 1 }, onOpened: { successes += 1 })
    precondition(
      successes == 2 && failures == 0 && callbacks == 2 && text.string == "unsaved saved",
      "Recent open must select an existing dirty buffer even if its file disappeared")
    let missing = directory.appendingPathComponent("missing.txt")
    target.open(missing, onFailure: { _ in failures += 1 }, onOpened: { successes += 1 })
    wait { failures == 1 }
    precondition(successes == 2 && callbacks == 2 && history.recentPaths == [good.path])
    target.open(
      good, shouldAccept: { false }, onFailure: { _ in failures += 1 }, onOpened: { successes += 1 }
    )
    precondition(failures == 2 && successes == 2 && callbacks == 2)
    var current = true
    target.open(
      other, shouldAccept: { current }, onFailure: { _ in failures += 1 },
      onOpened: { successes += 1 })
    current = false
    wait { failures == 3 }
    precondition(
      target.sessionMetadata.tabs.count == 1 && callbacks == 2,
      "Stale panel request must not append a tab or record history")
    let metadata = SessionTab(originalPath: other.path)
    try target.restoreSessionTab(
      metadata, decoded: try DocumentCodec.decode(Data("other".utf8)),
      originalBytes: Data("other".utf8), url: other,
      viewState: try RestoredViewState.resolve(
        selection: NSRange(location: 0, length: 0), bookmarks: [], in: "other"))
    precondition(
      callbacks == 2 && history.recentPaths == [good.path],
      "Session restoration must not reorder recent history")
    let closing = EditorWindowController(restoreStartup: false)
    var closedSuccess = 0
    var closedFailure = 0
    closing.open(other, onFailure: { _ in closedFailure += 1 }, onOpened: { closedSuccess += 1 })
    closing.close()
    wait { closedFailure == 1 || closedSuccess == 1 }
    precondition(closedFailure == 1 && closedSuccess == 0 && closing.sessionMetadata.tabs.isEmpty)
    let racing = EditorWindowController(restoreStartup: false)
    var raceSuccess = 0
    var raceFailure = 0
    let raceOpened: () -> Void = {
      raceSuccess += 1
      if raceSuccess == 1 {
        let view = editorViews(racing.window!.contentView!).compactMap { $0 as? NSTextView }.first!
        view.insertText("dirty ", replacementRange: NSRange(location: 0, length: 0))
      }
    }
    racing.open(other, onFailure: { _ in raceFailure += 1 }, onOpened: raceOpened)
    racing.open(other, onFailure: { _ in raceFailure += 1 }, onOpened: raceOpened)
    wait { raceSuccess == 2 || raceFailure > 0 }
    precondition(raceFailure == 0 && racing.sessionMetadata.tabs.count == 1)
    precondition(
      editorViews(racing.window!.contentView!).compactMap { $0 as? NSTextView }.first!.string
        == "dirty other",
      "Overlapping opens must not replace edits made after the first read completed")
    let frozen = EditorWindowController(restoreStartup: false)
    var prepared = false
    Task { prepared = await frozen.prepareToQuit(persistRecovery: false) }
    wait { prepared }
    var frozenFailure = 0
    frozen.open(
      other, onFailure: { _ in frozenFailure += 1 },
      onOpened: { fatalError("Frozen window accepted an open") })
    precondition(frozenFailure == 1 && frozen.sessionMetadata.tabs.isEmpty)
    frozen.cancelPreparedQuit()
    let large = directory.appendingPathComponent("large.txt")
    FileManager.default.createFile(atPath: large.path, contents: Data())
    let largeHandle = try FileHandle(forWritingTo: large)
    try largeHandle.truncate(atOffset: 100_000_001)
    try largeHandle.close()
    var largeFailure = 0
    var viewerRequests = 0
    frozen.onOpenLargeFile = { _ in viewerRequests += 1 }
    frozen.onOpenedURL = { _ in
      fatalError("Byte viewer construction must not claim successful text open")
    }
    frozen.open(
      large, onFailure: { _ in largeFailure += 1 },
      onOpened: { fatalError("Oversized file claimed text completion") })
    wait { largeFailure == 1 }
    precondition(viewerRequests == 0)
    frozen.open(large)
    wait { viewerRequests == 1 }
    let encoded = directory.appendingPathComponent("encoded.txt")
    try Data([0xE9]).write(to: encoded)
    let reloadTarget = EditorWindowController(restoreStartup: false)
    var reloadSuccess = 0
    var reloadFailure = 0
    var reloadHistory = 0
    reloadTarget.onOpenedURL = { _ in reloadHistory += 1 }
    reloadTarget.open(
      encoded, encoding: .windows1252, onFailure: { _ in reloadFailure += 1 },
      onOpened: { reloadSuccess += 1 })
    wait { reloadSuccess == 1 || reloadFailure > 0 }
    let reloadText = editorViews(reloadTarget.window!.contentView!).compactMap { $0 as? NSTextView }
      .first!
    precondition(reloadText.string == "é" && reloadHistory == 1)
    reloadTarget.open(
      encoded, encoding: .utf8, onFailure: { _ in reloadFailure += 1 },
      onOpened: { reloadSuccess += 1 })
    wait { reloadFailure == 1 }
    precondition(
      reloadText.string == "é" && reloadText.isEditable && reloadHistory == 1 && reloadSuccess == 1,
      "Failed encoding reload must retain text and complete once")
    try Data("new encoding".utf8).write(to: encoded)
    var reloadCurrent = true
    reloadTarget.open(
      encoded, encoding: .utf8, shouldAccept: { reloadCurrent },
      onFailure: { _ in reloadFailure += 1 }, onOpened: { reloadSuccess += 1 })
    reloadCurrent = false
    wait { reloadFailure == 2 }
    precondition(reloadText.string == "é" && reloadText.isEditable && reloadHistory == 1)
    reloadTarget.open(
      encoded, encoding: .utf8, onFailure: { _ in reloadFailure += 1 },
      onOpened: { reloadSuccess += 1 })
    wait { reloadSuccess == 2 }
    precondition(reloadText.string == "new encoding" && reloadHistory == 2 && reloadFailure == 2)
    let secondMetadata = SessionTab(originalPath: other.path)
    try reloadTarget.restoreSessionTab(
      secondMetadata, decoded: try DocumentCodec.decode(Data("other".utf8)),
      originalBytes: Data("other".utf8), url: other,
      viewState: try RestoredViewState.resolve(
        selection: NSRange(location: 0, length: 0), bookmarks: [], in: "other"))
    let encodedID = reloadTarget.sessionMetadata.tabs.first { $0.originalPath == encoded.path }!.id
    var switchedReloadDone = false
    reloadTarget.open(
      encoded, encoding: .utf8, onFailure: { _ in fatalError("Switch reload failed") },
      onOpened: {
        precondition(
          reloadTarget.sessionMetadata.selectedTabID == encodedID,
          "Encoding-open completion must select its captured document after a tab switch")
        switchedReloadDone = true
      })
    reloadTarget.selectSessionTab(secondMetadata.id)
    wait { switchedReloadDone }
    reloadHistory -= 1  // Keep the subsequent cancellation assertions relative to their baseline.
    if !CommandLine.arguments.contains("--headless") {
      reloadText.insertText("dirty ", replacementRange: NSRange(location: 0, length: 0))
      let beforeCanceledReload = reloadText.string
      let cancelDiscard = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
        MainActor.assumeIsolated {
          if let modal = NSApp.modalWindow,
            let button = editorViews(modal.contentView!).compactMap({ $0 as? NSButton }).first(
              where: { $0.title == "Cancel" })
          {
            button.performClick(nil)
            timer.invalidate()
          }
        }
      }
      RunLoop.main.add(cancelDiscard, forMode: .modalPanel)
      reloadTarget.open(
        encoded, encoding: .utf8, onFailure: { _ in reloadFailure += 1 },
        onOpened: { reloadSuccess += 1 })
      cancelDiscard.invalidate()
      precondition(
        reloadFailure == 3 && reloadSuccess == 2 && reloadHistory == 2
          && reloadText.string == beforeCanceledReload && reloadText.isEditable,
        "Canceling discard must complete as failure without replacing dirty text")
    }
    print(
      "PASS recent editor integration: successful-open history, dirty-buffer reuse, failed/stale/closed opens and restoration isolation"
    )
  }
}
