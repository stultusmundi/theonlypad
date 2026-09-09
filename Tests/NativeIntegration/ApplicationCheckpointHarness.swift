import AppKit
import PadCore

@main struct ApplicationCheckpointHarness {
  @MainActor static func main() async throws {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: state) }
    setenv("THEONLYPAD_STATE_DIRECTORY", state.path, 1)
    _ = NSApplication.shared
    let session = SessionCoordinator()
    await session.restore { _ in [:] }
    var windows: [EditorWindowController] = []
    let checkpoints = ApplicationSessionCheckpoints(session: session, windows: { windows })
    session.onSessionChange = { checkpoints.requestCheckpoint() }
    let window = EditorWindowController(
      restoreStartup: false, onSessionChange: { checkpoints.requestCheckpoint() })
    windows.append(window)
    window.newDocument()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editor = descendants(window.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    func wait(_ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(20)
      while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
      precondition(condition(), "application checkpoint did not reach the expected state")
    }
    editor.insertText(
      "synthetic checkpoint 👩🏽‍💻\r\n", replacementRange: NSRange(location: 0, length: 0))
    checkpoints.startAfterRestoration()
    await wait { checkpoints.lastAcknowledgedGeneration > 0 && !checkpoints.hasPendingChanges }
    let first = try SessionStore().load()!
    precondition(first.windows.count == 1 && first.windows[0].tabs.count == 1)
    let id = window.selectedDocumentID!
    precondition(first.windows[0].tabs[0].id == id)
    precondition(
      try! RecoveryStore(directory: state).loadAll().first { $0.id == id }?.text == editor.string)
    let firstGeneration = checkpoints.lastAcknowledgedGeneration
    editor.setSelectedRange(NSRange(location: 0, length: 9))
    try session.recordRecentOpen(state.appendingPathComponent("synthetic-recent.txt"))
    await wait {
      checkpoints.lastAcknowledgedGeneration > firstGeneration && !checkpoints.hasPendingChanges
    }
    let changed = try SessionStore().load()!
    precondition(changed.windows[0].tabs[0].selection == NSRange(location: 0, length: 9))
    precondition(changed.recentPaths == [state.appendingPathComponent("synthetic-recent.txt").path])

    await checkpoints.pauseAndDrain()
    let prior = checkpoints.lastAcknowledgedGeneration
    let directory = state.appendingPathComponent("Session")
    let preserved = state.appendingPathComponent("preserved-session")
    try FileManager.default.moveItem(at: directory, to: preserved)
    try Data("synthetic obstruction".utf8).write(to: directory)
    editor.insertText("new", replacementRange: NSRange(location: 0, length: 9))
    checkpoints.resumeAfterVeto()
    await wait { checkpoints.lastError != nil }
    precondition(checkpoints.lastAcknowledgedGeneration == prior)
    precondition(try! Data(contentsOf: directory) == Data("synthetic obstruction".utf8))
    let retry = descendants(window.window!.contentView!).compactMap { $0 as? NSButton }.first {
      $0.accessibilityIdentifier() == "session.checkpoint.retry"
    }!
    precondition(!retry.isHidden && retry.isEnabled)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.moveItem(at: preserved, to: directory)
    _ = retry.target?.perform(retry.action, with: retry)
    await wait { checkpoints.lastError == nil && checkpoints.lastAcknowledgedGeneration > prior }
    precondition(retry.isHidden)
    precondition(
      try! RecoveryStore(directory: state).loadAll().first { $0.id == id }?.text == editor.string)

    await checkpoints.pauseAndDrain()
    let prepared = await window.prepareToQuit(persistRecovery: false)
    precondition(prepared)
    let receipt = try await checkpoints.commitFinal()
    precondition(receipt.generation == checkpoints.lastAcknowledgedGeneration)
    let final = try SessionStore().load()!
    precondition(final.windows == [window.sessionMetadata])
    try await Task.sleep(nanoseconds: 800_000_000)
    precondition(checkpoints.lastAcknowledgedGeneration == receipt.generation)
    window.cancelPreparedQuit()
    checkpoints.resumeAfterVeto()
    await wait { checkpoints.lastAcknowledgedGeneration > receipt.generation }
    await checkpoints.pauseAndDrain()
    print(
      "PASS application checkpoints: exact stores, metadata events, failure retry, final save and veto resume"
    )
  }
}
