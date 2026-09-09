import AppKit
import PadCore

@main struct SessionIntegrationHarness {
  @MainActor static func main() async throws {
    let registry = try AppCommands.registry()
    precondition(registry.commands.contains { $0.id == "file.restoreSession" })
    _ = NSApplication.shared
    var budget = SessionStartupBudget()
    try budget.admit(utf16Count: 100_000_000, originalByteCount: 100_000_000)
    do {
      try budget.admit(utf16Count: 1, originalByteCount: 1)
      fatalError("Aggregate UTF16 limit must hold")
    } catch {}
    var byteBudget = SessionStartupBudget()
    try byteBudget.admit(utf16Count: 50_000_000, originalByteCount: 300_000_000)
    do {
      try byteBudget.admit(utf16Count: 1, originalByteCount: 0)
      fatalError("Retained estimate limit must hold")
    } catch {}

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("saved.txt")
    try Data("saved 🐱\nline".utf8).write(to: file)
    let saved = SessionTab(originalPath: file.path, pinned: true)
    let missing = SessionTab(originalPath: directory.appendingPathComponent("missing.txt").path)
    let scratch = SessionTab()
    let window = SessionWindow(tabs: [saved, missing, scratch], selectedTabID: scratch.id)
    let store = SessionStore(directory: directory.appendingPathComponent("Session"))
    let secondTab = SessionTab(originalPath: file.path)
    let secondWindow = SessionWindow(tabs: [secondTab], selectedTabID: secondTab.id)
    try store.save(EditorSession(windows: [window, secondWindow]))
    let recovery = RecoverySnapshot(
      id: scratch.id, text: "scratch", encoding: .utf8, hasBOM: false, originalPath: "/do/not/write"
    )
    var captured: [PreparedSessionWindow] = []
    var nativeWindows: [EditorWindowController] = []
    let coordinator = SessionCoordinator(
      loadSession: { try store.load() },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [recovery], quarantinedCount: 0) },
      saveSession: { try store.save($0) })
    await coordinator.restore { prepared in
      captured.append(prepared)
      let editor = EditorWindowController(id: prepared.id, restoreStartup: false)
      nativeWindows.append(editor)
      var errors: [UUID: String] = [:]
      for tab in prepared.tabs {
        do {
          try editor.restoreSessionTab(
            tab.metadata, decoded: tab.decoded, originalBytes: tab.originalBytes, url: tab.url,
            viewState: tab.viewState)
        } catch { errors[tab.metadata.id] = error.localizedDescription }
      }
      editor.selectSessionTab(prepared.selectedTabID)
      return errors
    }
    precondition(
      captured.count == 2 && captured[0].tabs.map { $0.metadata.id } == [saved.id, scratch.id])
    precondition(captured[0].tabs[0].originalBytes == Data("saved 🐱\nline".utf8))
    precondition(captured[0].tabs[1].url == nil && captured[0].tabs[1].originalBytes == nil)
    precondition(coordinator.unresolved.map { $0.metadata.id } == [missing.id])
    let live = SessionWindow(id: window.id, tabs: [saved, scratch], selectedTabID: scratch.id)
    precondition(nativeWindows.map { $0.sessionMetadata.id } == [window.id, secondWindow.id])
    try await coordinator.persist(windows: [live, nativeWindows[1].sessionMetadata])
    let reloaded = try store.load()!
    precondition(reloaded.windows[0].tabs.map { $0.id } == [saved.id, missing.id, scratch.id])
    precondition(nativeWindows[0].sessionMetadata.tabs.map(\.id) == [saved.id, scratch.id])
    precondition(nativeWindows[0].sessionMetadata.selectedTabID == scratch.id)
    precondition(nativeWindows[0].sessionMetadata.tabs[1].originalPath == nil)
    let bytes = try Data(contentsOf: directory.appendingPathComponent("Session/Session.json"))
    let failed = SessionCoordinator(
      loadSession: { throw SessionStoreError.unsupportedVersion(99) },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in fatalError("Corrupt session must not be overwritten") })
    await failed.restore { _ in fatalError("No valid window") }
    do {
      try await failed.persist(windows: [])
      fatalError("Expected blocked save")
    } catch {}
    let preservedBytes = try Data(
      contentsOf: directory.appendingPathComponent("Session/Session.json"))
    precondition(preservedBytes == bytes)
    let writeFailure = SessionCoordinator(
      loadSession: { nil },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in throw FileStoreError.injectedFailure })
    await writeFailure.restore { _ in [:] }
    do {
      try await writeFailure.persist(windows: [])
      fatalError("Expected quit veto")
    } catch {}
    var resume: CheckedContinuation<EditorSession?, Error>?
    let late = SessionCoordinator(
      loadSession: { try await withCheckedThrowingContinuation { resume = $0 } },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in })
    let task = Task {
      await late.restore { _ in fatalError("Canceled restore must not create windows") }
    }
    while resume == nil { await Task.yield() }
    late.cancelRestoration()
    resume!.resume(returning: EditorSession(windows: [window]))
    await task.value
    do {
      try await late.persist(windows: [])
      fatalError("Canceled restore must not trim session")
    } catch {}
    let dirtySnapshot = RecoverySnapshot(
      id: saved.id, text: "unsaved recovered text", encoding: .utf8, hasBOM: false,
      originalPath: file.path)
    let dirtyRetry = SessionCoordinator(
      loadSession: {
        EditorSession(windows: [SessionWindow(tabs: [saved], selectedTabID: saved.id)])
      },
      claimRecovery: {
        RecoveryCoordinator.Startup(snapshots: [dirtySnapshot], quarantinedCount: 0)
      }, saveSession: { _ in })
    await dirtyRetry.restore { prepared in
      Dictionary(
        uniqueKeysWithValues: prepared.tabs.map { ($0.metadata.id, "Synthetic import failure") })
    }
    let retriedRecovery = try await dirtyRetry.retry(dirtyRetry.unresolved[0])
    precondition(
      retriedRecovery.decoded.text == "unsaved recovered text" && retriedRecovery.url == nil
        && retriedRecovery.originalBytes == nil,
      "Retry must preserve recovered unsaved text as scratch instead of reading older disk bytes")
    let recoveryDirectory = directory.appendingPathComponent("Recovery")
    let recoveryStore = try RecoveryStore(directory: recoveryDirectory)
    try recoveryStore.save(recovery)
    let recoveryOwner = RecoveryCoordinator(directory: recoveryDirectory)
    let badMetadata = SessionCoordinator(
      loadSession: {
        EditorSession(windows: [window, window])
      }, claimRecovery: { try await recoveryOwner.claimStartup() },
      saveSession: { _ in fatalError("Invalid metadata must stay preserved") },
      removeRecovery: { id in try await recoveryOwner.close(id: id) })
    var orphanCount = 0
    await badMetadata.restore { value in
      orphanCount += value.tabs.count
      return Dictionary(
        uniqueKeysWithValues: value.tabs.map { ($0.metadata.id, "Synthetic closed target") })
    }
    precondition(orphanCount == 1 && badMetadata.unresolved.count == 1)
    try await badMetadata.remove(badMetadata.unresolved[0])
    precondition(badMetadata.unresolved.isEmpty)
    let afterRemoval = try recoveryStore.loadAll()
    precondition(
      afterRemoval.isEmpty,
      "Explicit removal must discard recovery so it cannot return as an orphan")
    let failedRemoval = SessionCoordinator(
      loadSession: { nil },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [recovery], quarantinedCount: 0) },
      saveSession: { _ in }, removeRecovery: { _ in throw FileStoreError.injectedFailure })
    await failedRemoval.restore { value in
      Dictionary(
        uniqueKeysWithValues: value.tabs.map { ($0.metadata.id, "Synthetic closed target") })
    }
    do {
      try await failedRemoval.remove(failedRemoval.unresolved[0])
      fatalError("Expected failed recovery cleanup")
    } catch {}
    precondition(failedRemoval.unresolved.count == 1)
    print(
      "PASS session orchestration: order, recovery scratch, unresolved retention, corrupt protection, quit failure and cancellation"
    )
  }
}
