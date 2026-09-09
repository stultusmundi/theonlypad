import AppKit
import PadCore

private final class PreferenceWriter: @unchecked Sendable {
  let store: SettingsStore
  let file: URL
  private let lock = NSLock()
  private var fault: SaveFault? = .directorySync
  private var corruptReadback = false
  init(_ directory: URL) {
    store = SettingsStore(directory: directory)
    file = directory.appendingPathComponent("Settings.json")
  }
  func setFault(_ value: SaveFault?) { lock.withLock { fault = value } }
  func setCorruptReadback() { lock.withLock { corruptReadback = true } }
  func save(_ settings: EditorSettings) throws {
    do {
      try AtomicFileStore().save(
        store.exportData(settings), to: file, expected: Data(contentsOf: file),
        fault: lock.withLock { fault })
    } catch {
      if lock.withLock({ corruptReadback }) {
        try Data("invalid synthetic settings".utf8).write(to: file)
      }
      throw error
    }
  }
}

@main struct PreferencesFailureHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = PreferenceWriter(directory)
    try writer.store.save(.defaults)
    var applied: [EditorSettings] = []
    let controller = PreferencesController(
      store: writer.store, saveSettings: { try writer.save($0) }, onApply: { applied.append($0) })
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(controller.window!.contentView!)
    let theme = views.compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Appearance"
    }!
    let status = views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "Preferences status"
    }!
    func wait(_ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(5)
      while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
      precondition(condition())
    }
    await wait { theme.isEnabled }
    theme.selectItem(at: 2)
    _ = theme.target?.perform(theme.action, with: theme)
    await wait { theme.isEnabled }
    precondition(try! writer.store.load().theme == .dark)
    precondition(theme.indexOfSelectedItem == 2 && applied.last?.theme == .dark)
    precondition(status.stringValue.contains("not confirmed"))
    precondition(!status.stringValue.contains("not changed"))
    writer.setFault(nil)
    theme.selectItem(at: 1)
    _ = theme.target?.perform(theme.action, with: theme)
    await wait { theme.isEnabled }
    precondition(try! writer.store.load().theme == .light)
    precondition(status.stringValue == "Preferences saved." && applied.last?.theme == .light)
    writer.setFault(.beforeReplace)
    theme.selectItem(at: 2)
    _ = theme.target?.perform(theme.action, with: theme)
    await wait { theme.isEnabled }
    precondition(try! writer.store.load().theme == .light)
    precondition(theme.indexOfSelectedItem == 1 && applied.last?.theme == .light)
    precondition(status.stringValue == "Preferences were not changed.")
    writer.setFault(.directorySync)
    writer.setCorruptReadback()
    theme.selectItem(at: 2)
    _ = theme.target?.perform(theme.action, with: theme)
    await wait { status.stringValue.contains("stored preferences could not be read") }
    precondition(!theme.isEnabled && applied.last?.theme == .light)
    precondition(views.compactMap { $0 as? NSButton }.first { $0.title == "Reset…" }!.isEnabled)
    precondition(!status.stringValue.contains("not changed"))
    print(
      "PASS native preference uncertainty readback, truthful status, fresh save and prewrite failure"
    )
  }
}
