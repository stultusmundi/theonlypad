import AppKit
import PadCore

@main struct BackupHarness {
  enum Failure: Error { case failed(String) }
  @MainActor final class RestoreState {
    var restored: [(BackupRecord, Data)] = []
    var refuseRestore = true
  }
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
      do {
        try await exercise()
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("FAIL: backup native harness \(error)\n".utf8))
        exit(1)
      }
    }
    app.run()
    fatalError("Application loop ended before harness completion")
  }
  @MainActor static func exercise() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = BackupStore(directory: temporary.appendingPathComponent("Backups"))
    let record = try store.capture(
      data: Data([0x80, 0xE9]), originalURL: temporary.appendingPathComponent("synthetic-legacy"),
      encoding: .windows1252)
    let state = RestoreState()
    let controller = BackupManagerController(directory: store.directory) { record, data in
      if state.refuseRestore {
        throw NSError(
          domain: "SyntheticBackupHarness", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Synthetic restore refusal"])
      }
      state.restored.append((record, data))
    }
    controller.showWindow(nil)
    guard let content = controller.window?.contentView else {
      throw Failure.failed("Missing window")
    }
    func find<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
      func walk(_ view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        return view.subviews.lazy.compactMap { walk($0) }.first
      }
      guard let view = walk(content) else { throw Failure.failed("Missing control " + id) }
      return view
    }
    func wait(_ predicate: () -> Bool) async throws {
      for _ in 0..<250 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      throw Failure.failed("Timed out waiting for backup UI")
    }
    let table = try find("backups.records", NSTableView.self)
    let status = try find("backups.status", NSTextField.self)
    try await wait { table.numberOfRows == 1 }
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    try find("backups.restore", NSButton.self).performClick(nil)
    try await wait {
      status.stringValue.contains("refusal") || status.stringValue.contains("sent to a new tab")
    }
    guard status.stringValue.contains("refusal"), state.restored.isEmpty else {
      throw Failure.failed("Restore callback error must not report success")
    }
    state.refuseRestore = false
    try find("backups.restore", NSButton.self).performClick(nil)
    try await wait { state.restored.count == 1 }
    guard state.restored[0].0.encoding == .windows1252, state.restored[0].1 == Data([0x80, 0xE9])
    else { throw Failure.failed("Restore lost bytes or encoding") }
    let file = store.directory.appendingPathComponent(record.id.uuidString + ".json")
    try Data("torn".utf8).write(to: file)
    try find("backups.reload", NSButton.self).performClick(nil)
    try await wait { status.stringValue.contains("corrupt") }
    guard try find("backups.id", NSTextField.self).stringValue == record.id.uuidString,
      FileManager.default.fileExists(atPath: file.path)
    else { throw Failure.failed("Bad record must remain available for explicit removal") }
    try find("backups.delete", NSButton.self).performClick(nil)
    try await wait { controller.window?.attachedSheet != nil }
    guard let sheet = controller.window?.attachedSheet else {
      throw Failure.failed("Delete confirmation missing")
    }
    func confirm(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == "Delete Backup" { return button }
      return view.subviews.lazy.compactMap { confirm($0) }.first
    }
    guard let button = sheet.contentView.flatMap({ confirm($0) }) else {
      throw Failure.failed("Confirmation button missing")
    }
    button.performClick(nil)
    try await wait {
      !FileManager.default.fileExists(atPath: file.path) && status.stringValue == "No backups."
    }
    print("PASS: native backup list, encoding-aware restore, corrupt UUID and confirmed deletion")
    fflush(stdout)
    controller.close()
  }
}
