import AppKit
import PadCore

@main struct FolderSearchHarness {
  enum Failure: Error { case failed(String) }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0xEF, 0xBB, 0xBF] + Array("first needle second".utf8)).write(
      to: root.appendingPathComponent("a.txt"))
    var opened: [(URL, NSRange, String)] = []
    let controller = FolderSearchController(root: root) { opened.append(($0, $1, $2)) }
    guard let content = controller.window?.contentView else {
      throw Failure.failed("Missing window")
    }
    func find<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
      func walk(_ view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        return view.subviews.lazy.compactMap { walk($0) }.first
      }
      guard let result = walk(content) else { throw Failure.failed("Missing control " + id) }
      return result
    }
    func wait(_ predicate: () -> Bool) async throws {
      for _ in 0..<250 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      throw Failure.failed("Timed out")
    }
    let query = try find("folder.query", NSSearchField.self)
    let run = try find("folder.run", NSButton.self)
    let table = try find("folder.results", NSTableView.self)
    let status = try find("folder.status", NSTextField.self)
    query.stringValue = "needle"
    run.performClick(nil)
    try await wait { table.numberOfRows == 1 }
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    if let action = table.doubleAction {
      _ = NSApp.sendAction(action, to: table.target, from: table)
    }
    try await wait { opened.count == 1 }
    guard opened.count == 1, opened[0].1 == NSRange(location: 6, length: 6),
      opened[0].2 == "first needle second"
    else { throw Failure.failed("Incorrect result snapshot") }
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    controller.setRoot(other)
    guard table.numberOfRows == 0, table.selectedRow == -1 else {
      throw Failure.failed("Changing root must discard old results and selection")
    }
    controller.setRoot(root)
    run.performClick(nil)
    try await wait { table.numberOfRows == 1 }
    let file = root.appendingPathComponent("a.txt")
    try FileManager.default.removeItem(at: file)
    try Data("first needle second".utf8).write(to: other.appendingPathComponent("outside.txt"))
    try FileManager.default.createSymbolicLink(
      at: file, withDestinationURL: other.appendingPathComponent("outside.txt"))
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    if let action = table.doubleAction {
      _ = NSApp.sendAction(action, to: table.target, from: table)
    }
    try await wait { status.stringValue.contains("Cannot open") || opened.count > 1 }
    guard opened.count == 1 else { throw Failure.failed("Substituted symlink must not open") }
    run.performClick(nil)
    try find("folder.cancel", NSButton.self).performClick(nil)
    try await wait { status.stringValue.contains("cancelled") }
    controller.close()
    print("PASS: native folder search result, snapshot callback and cancellation")
  }
}
