import AppKit
import PadCore

@main
struct ViewerHarness {
  enum Failure: Error { case failed(String) }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("synthetic-large.bin")
    var bytes = Data([255])
    bytes.append(Data(repeating: 97, count: 69_999))
    bytes.append(Data("tail-marker".utf8))
    try bytes.write(to: url)
    let controller = LargeFileWindowController(url: url)
    func find<T: NSView>(_ id: String, as type: T.Type) throws -> T {
      func descend(_ view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        for child in view.subviews { if let found = descend(child) { return found } }
        return nil
      }
      guard let content = controller.window?.contentView, let view = descend(content) else {
        throw Failure.failed("Missing accessible control: \(id)")
      }
      return view
    }
    func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
      guard condition() else { throw Failure.failed(description) }
    }
    func wait(_ predicate: () -> Bool) async throws {
      for _ in 0..<250 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      throw Failure.failed("Timed out waiting for controller state")
    }
    let text = try find("large.text", as: NSTextView.self)
    let status = try find("large.status", as: NSTextField.self)
    let offset = try find("large.offset", as: NSTextField.self)
    let next = try find("large.next", as: NSButton.self)
    let go = try find("large.go", as: NSButton.self)
    let query = try find("large.query", as: NSTextField.self)
    let search = try find("large.search", as: NSButton.self)
    let cancel = try find("large.cancel", as: NSButton.self)
    let results = try find("large.matches", as: NSPopUpButton.self)
    let searchStatus = try find("large.searchStatus", as: NSTextField.self)
    try await wait { next.isEnabled }
    try require(!text.isEditable && text.isSelectable, "Viewer must be selectable and read-only")
    try require(
      text.string.utf16.count == 65_536 && text.string.hasPrefix("�"),
      "Bounded first page must render invalid bytes explicitly")
    next.performClick(nil)
    try await wait { offset.stringValue == "65536" && go.isEnabled }
    try require(text.string.hasSuffix("tail-marker"), "Next page must contain tail")
    offset.stringValue = "-1"
    go.performClick(nil)
    try require(
      status.stringValue.contains("Invalid byte offset"), "Invalid offset must be actionable")
    query.stringValue = "tail-marker"
    search.performClick(nil)
    try await wait { results.numberOfItems == 1 }
    try require(results.itemTitle(at: 0).contains("70000"), "Result must use source byte offset")
    if let action = results.action {
      _ = NSApp.sendAction(action, to: results.target, from: results)
    }
    try await wait { offset.stringValue == "70000" && go.isEnabled }
    try require(text.string == "tail-marker", "Selecting result must navigate")
    query.stringValue = "not present"
    search.performClick(nil)
    cancel.performClick(nil)
    try await wait { searchStatus.stringValue == "Search cancelled." }
    try Data("changed".utf8).write(to: url, options: .atomic)
    offset.stringValue = "0"
    go.performClick(nil)
    try await wait { status.stringValue.contains("File changed") }
    try require(
      text.string.isEmpty && !go.isEnabled,
      "Changed file must clear stale view and disable navigation")
    let preserved = try Data(contentsOf: url)
    try require(preserved == Data("changed".utf8), "Viewer must not rewrite original")
    controller.close()
    print(
      "PASS: bounded native viewer controls, read-only bytes, navigation, search, cancellation and mutation rejection"
    )
  }
}
