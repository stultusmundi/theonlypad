import AppKit
import PadCore

@main struct FolderSearchHarness {
  enum Failure: Error { case failed(String) }
  private final class ScriptedFolderSearch: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func run(
      _ root: URL, _ query: SearchQuery, _ includes: [String], _ excludes: [String]
    ) throws -> FolderSearchReport {
      lock.lock()
      callCount += 1
      let call = callCount
      lock.unlock()
      if call == 1 {
        return try FolderSearch.search(
          root: root, query: query, includes: includes, excludes: excludes)
      }
      throw SearchError.engineFailure
    }
  }

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

    let failureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: failureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: failureRoot) }
    try Data("a".utf8).write(to: failureRoot.appendingPathComponent("a.txt"))
    var failureOpened = 0
    let scriptedSearch = ScriptedFolderSearch()
    let failureController = FolderSearchController(
      root: failureRoot, onOpen: { _, _, _ in failureOpened += 1 },
      search: { root, query, includes, excludes in
        try scriptedSearch.run(root, query, includes, excludes)
      })
    guard let failureContent = failureController.window?.contentView else {
      throw Failure.failed("Missing failure window")
    }
    func findFailure<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
      func walk(_ view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        return view.subviews.lazy.compactMap { walk($0) }.first
      }
      guard let result = walk(failureContent) else {
        throw Failure.failed("Missing failure control " + id)
      }
      return result
    }
    let failureQuery = try findFailure("folder.query", NSSearchField.self)
    let failureRun = try findFailure("folder.run", NSButton.self)
    let failureCancel = try findFailure("folder.cancel", NSButton.self)
    let failureTable = try findFailure("folder.results", NSTableView.self)
    let failureStatus = try findFailure("folder.status", NSTextField.self)
    failureQuery.stringValue = "a"
    failureRun.performClick(nil)
    try await wait { failureTable.numberOfRows == 1 }
    guard failureTable.numberOfRows == 1 else {
      throw Failure.failed("Control search did not publish its result")
    }
    failureRun.performClick(nil)
    try await wait { failureStatus.stringValue.contains("The search engine could not finish") }
    guard
      failureStatus.stringValue
        == "Search failed; no complete results. The search engine could not finish. Narrow the pattern and try again.",
      failureTable.numberOfRows == 0, failureOpened == 0, failureRun.isEnabled,
      !failureCancel.isEnabled
    else { throw Failure.failed("Engine failure published results or left the controller busy") }
    failureController.close()
    print("PASS: native folder search result, cancellation, and engine failure state reset")
  }
}
