import AppKit
import PadCore

@main struct WorkspaceHarness {
  enum Failure: Error { case failed(String) }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("swift".utf8).write(to: root.appendingPathComponent("b.swift"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    var opened: [URL] = []
    var changedRoot: URL?
    let sidebar = WorkspaceSidebar(onOpen: { opened.append($0) })
    sidebar.onRootChanged = { changedRoot = $0 }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = sidebar
    func require(_ test: @autoclosure () -> Bool, _ message: String) throws {
      guard test() else { throw Failure.failed(message) }
    }
    func find<T: NSView>(_ id: String, as type: T.Type) throws -> T {
      func descend(_ view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        for child in view.subviews { if let found = descend(child) { return found } }
        return nil
      }
      guard let result = descend(sidebar) else {
        throw Failure.failed("Missing workspace control: \(id)")
      }
      return result
    }
    func wait(_ test: () -> Bool) async throws {
      for _ in 0..<250 {
        if test() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      throw Failure.failed("Timed out waiting for workspace state")
    }
    let table = try find("workspace.files", as: NSTableView.self)
    let query = try find("workspace.filter", as: NSSearchField.self)
    let status = try find("workspace.status", as: NSTextField.self)
    let cancel = try find("workspace.cancel", as: NSButton.self)
    sidebar.openFolder(root)
    try await wait { table.numberOfRows == 2 && query.isEnabled }
    try require(
      changedRoot == root.resolvingSymlinksInPath() && sidebar.rootURL == changedRoot,
      "Root callback must reflect indexed root")
    query.stringValue = "SWIFT"
    query.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: query))
    try await wait { table.numberOfRows == 1 }
    if let action = query.action { _ = NSApp.sendAction(action, to: query.target, from: query) }
    try await wait { opened.count == 1 }
    try require(opened[0].lastPathComponent == "b.swift", "Return must open filtered URL")
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    if let action = table.doubleAction {
      _ = NSApp.sendAction(action, to: table.target, from: table)
    }
    try await wait { opened.count == 2 }
    try FileManager.default.removeItem(at: root.appendingPathComponent("b.swift"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("b.swift"),
      withDestinationURL: root.appendingPathComponent("a.txt"))
    if let action = query.action { _ = NSApp.sendAction(action, to: query.target, from: query) }
    try await wait { status.stringValue.contains("Cannot open") }
    try require(opened.count == 2, "Substituted symlink must not reach open callback")
    sidebar.openFolder(root)
    cancel.performClick(nil)
    try require(status.stringValue.contains("cancelled"), "Cancellation must be explicit")
    window.close()
    print(
      "PASS: native workspace list, filtering, Return/double action, root callback, cancellation and open revalidation"
    )
  }
}
