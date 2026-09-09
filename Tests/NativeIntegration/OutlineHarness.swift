import AppKit
import PadCore

@main struct OutlineHarness {
  enum Failure: Error { case failed(String) }
  @MainActor final class State {
    var selections: [(NSRange, String)] = []
    var closed = false
  }
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
      do {
        try await exercise()
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("FAIL outline harness: \(error)\n".utf8))
        exit(1)
      }
    }
    app.run()
    fatalError("Application ended before harness finished")
  }
  @MainActor static func exercise() async throws {
    let snapshot = "let emoji = \"😀\"\r\nstruct Café {}\nfunc work() {}"
    let state = State()
    let controller = OutlineController(text: snapshot, language: .swift) {
      state.selections.append(($0, $1))
    }
    controller.onClose = { state.closed = true }
    controller.showWindow(nil)
    func find<T: NSView>(_ controller: NSWindowController, _ id: String, _ type: T.Type) throws -> T
    {
      func walk(_ view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        return view.subviews.lazy.compactMap { walk($0) }.first
      }
      guard let content = controller.window?.contentView, let found = walk(content) else {
        throw Failure.failed("Missing " + id)
      }
      return found
    }
    func wait(_ predicate: () -> Bool) async throws {
      for _ in 0..<250 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      throw Failure.failed("Timed out")
    }
    let table = try find(controller, "outline.symbols", NSTableView.self)
    let query = try find(controller, "outline.filter", NSSearchField.self)
    try await wait { table.numberOfRows == 2 }
    query.stringValue = "missing"
    query.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: query))
    query.stringValue = "WORK"
    query.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: query))
    try await wait { table.numberOfRows == 1 }
    if let action = query.action { _ = NSApp.sendAction(action, to: query.target, from: query) }
    guard state.selections.count == 1, state.selections[0].1.utf16.elementsEqual(snapshot.utf16),
      (snapshot as NSString).substring(with: state.selections[0].0) == "work"
    else {
      throw Failure.failed("Selection callback must carry exact captured snapshot and name range")
    }
    controller.close()
    if let action = query.action { _ = NSApp.sendAction(action, to: query.target, from: query) }
    guard state.closed, state.selections.count == 1 else {
      throw Failure.failed("Closed outline must reject callbacks")
    }
    let unavailable = OutlineController(text: "class Fake", language: .java) { _, _ in }
    unavailable.showWindow(nil)
    let status = try find(unavailable, "outline.status", NSTextField.self)
    try await wait { status.stringValue.contains("Outline unavailable") }
    unavailable.close()
    print(
      "PASS: native outline filtering, snapshot navigation, unavailable language and close guard")
  }
}
