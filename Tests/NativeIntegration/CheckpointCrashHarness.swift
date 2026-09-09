import AppKit
import Darwin
import PadCore

/// Two owned child processes, never a packaged desktop or physical power-loss assertion.
/// Usage: checkpoint-crash-test write STATE_DIRECTORY (expected SIGKILL), then restore same directory.
@main struct CheckpointCrashHarness {
  private struct ExpectedTab: Codable {
    let id: UUID
    let text: String
    let pinned: Bool
    let selectionLocation: Int
    let selectionLength: Int
  }
  private struct Expected: Codable {
    let windowID: UUID
    let selectedTabID: UUID
    let tabs: [ExpectedTab]
    let recentPaths: [String]
    let generation: UInt64
  }

  @MainActor private static func views(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(views)
  }
  @MainActor private static func editor(_ controller: EditorWindowController) -> NSTextView {
    views(controller.window!.contentView!).compactMap { $0 as? NSTextView }.first {
      $0.accessibilityLabel() == "Document text"
    }!
  }
  @MainActor private static func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(predicate(), "Checkpoint did not reach its acknowledged boundary")
  }

  @MainActor static func main() async throws {
    precondition(
      CommandLine.arguments.count == 3, "Supply write|restore and a synthetic state directory")
    let mode = CommandLine.arguments[1]
    precondition(mode == "write" || mode == "restore")
    let state = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    setenv("THEONLYPAD_STATE_DIRECTORY", state.path, 1)
    _ = NSApplication.shared
    setbuf(stdout, nil)
    let marker = state.appendingPathComponent("Checkpoint.expected")
    if mode == "write" {
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      precondition(
        !FileManager.default.fileExists(atPath: marker.path), "Use a fresh synthetic fixture")
      let session = SessionCoordinator()
      await session.restore { _ in preconditionFailure("Writer fixture must start empty") }
      precondition(session.restorationComplete && session.unresolved.isEmpty)
      var windows: [EditorWindowController] = []
      let checkpoints = ApplicationSessionCheckpoints(session: session, windows: { windows })
      session.onSessionChange = { checkpoints.requestCheckpoint() }
      let window = EditorWindowController(
        restoreStartup: false, onSessionChange: { checkpoints.requestCheckpoint() })
      windows.append(window)
      let fixtures: [(String, NSRange)] = [
        ("alpha 😀\r\nsecond", NSRange(location: 6, length: 2)),
        ("beta e\u{301}\rthird", NSRange(location: 5, length: 2)),
        ("gamma 👩🏽‍💻\nlast", NSRange(location: 0, length: 5)),
      ]
      var texts: [UUID: String] = [:]
      var selections: [UUID: NSRange] = [:]
      var ids: [UUID] = []
      for (text, selection) in fixtures {
        window.newDocument()
        let view = editor(window)
        view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        view.setSelectedRange(selection)
        let id = window.selectedDocumentID!
        texts[id] = text
        selections[id] = selection
        ids.append(id)
      }
      let tabBar = views(window.window!.contentView!).compactMap { $0 as? DocumentTabBar }.first!
      tabBar.onMove?(ids[2], 0)
      tabBar.onPin?(ids[1])
      tabBar.onSelect?(ids[0])
      let firstRecent = state.appendingPathComponent("synthetic-recent-one.txt")
      let secondRecent = state.appendingPathComponent("synthetic-recent-two.txt")
      try Data("unchanged one".utf8).write(to: firstRecent)
      try Data("unchanged two".utf8).write(to: secondRecent)
      try session.recordRecentOpen(firstRecent)
      try session.recordRecentOpen(secondRecent)
      let metadata = window.sessionMetadata
      precondition(metadata.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
      precondition(metadata.tabs.map(\.pinned) == [true, false, false])
      precondition(metadata.selectedTabID == ids[0])
      precondition(metadata.tabs.allSatisfy { $0.selection == selections[$0.id] })
      let recentPaths = [secondRecent.path, firstRecent.path]
      precondition(session.recentPaths == recentPaths)
      checkpoints.startAfterRestoration()
      try await wait {
        checkpoints.lastAcknowledgedGeneration > 0 && !checkpoints.hasPendingChanges
          && checkpoints.lastError == nil
      }
      let expected = Expected(
        windowID: metadata.id, selectedTabID: ids[0],
        tabs: metadata.tabs.map {
          ExpectedTab(
            id: $0.id, text: texts[$0.id]!, pinned: $0.pinned,
            selectionLocation: selections[$0.id]!.location,
            selectionLength: selections[$0.id]!.length)
        }, recentPaths: recentPaths, generation: checkpoints.lastAcknowledgedGeneration)
      // Marker is test expectation only; restore below must read the real session/recovery stores.
      try JSONEncoder().encode(expected).write(to: marker, options: .atomic)
      precondition(!checkpoints.hasPendingChanges)
      print("ACKNOWLEDGED_CHECKPOINT generation=\(expected.generation) tabs=\(expected.tabs.count)")
      // No prepareToQuit, final checkpoint, normal application termination, or close cleanup.
      withExtendedLifetime([window, checkpoints] as [AnyObject]) {
        _ = kill(getpid(), SIGKILL)
      }
      preconditionFailure("Owned writer process must terminate via SIGKILL")
    }

    let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: marker))
    precondition(expected.generation > 0 && expected.tabs.count >= 2)
    let session = SessionCoordinator()
    var windows: [EditorWindowController] = []
    var restoredTexts: [UUID: String] = [:]
    await session.restore { prepared in
      let window = EditorWindowController(
        id: prepared.id, restoreStartup: false, onSessionChange: {})
      windows.append(window)
      var failures: [UUID: String] = [:]
      for tab in prepared.tabs {
        do {
          precondition(
            tab.url == nil && tab.originalBytes == nil, "Scratch recovery must remain scratch")
          try window.restoreSessionTab(
            tab.metadata, decoded: tab.decoded,
            originalBytes: tab.originalBytes, url: tab.url, viewState: tab.viewState)
          restoredTexts[tab.metadata.id] = editor(window).string
        } catch { failures[tab.metadata.id] = error.localizedDescription }
      }
      window.selectSessionTab(prepared.selectedTabID)
      return failures
    }
    precondition(session.restorationComplete && session.unresolved.isEmpty)
    precondition(windows.count == 1)
    let metadata = windows[0].sessionMetadata
    precondition(
      metadata.id == expected.windowID && metadata.selectedTabID == expected.selectedTabID)
    precondition(metadata.tabs.map(\.id) == expected.tabs.map(\.id))
    for (actual, wanted) in zip(metadata.tabs, expected.tabs) {
      precondition(actual.pinned == wanted.pinned && actual.originalPath == nil)
      precondition(
        actual.selection
          == NSRange(location: wanted.selectionLocation, length: wanted.selectionLength))
      precondition(
        restoredTexts[wanted.id]!.utf16.elementsEqual(wanted.text.utf16),
        "Restored native text must exactly match acknowledged Unicode and line endings")
    }
    precondition(session.recentPaths == expected.recentPaths)
    precondition(
      try! Data(contentsOf: state.appendingPathComponent("synthetic-recent-one.txt"))
        == Data("unchanged one".utf8))
    precondition(
      try! Data(contentsOf: state.appendingPathComponent("synthetic-recent-two.txt"))
        == Data("unchanged two".utf8))
    print("PASS native process-kill checkpoint restoration: exact text/order/pin/selection/history")
    withExtendedLifetime(windows) {}
  }
}
