import AppKit
import PadCore

@main struct SearchHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    var source = "alpha beta alpha"
    var selected: [NSRange] = []
    let panel = SearchPanelController(
      snapshot: { source },
      select: { range, expected in
        guard source.utf16.elementsEqual(expected.utf16) else { return false }
        selected.append(range)
        return true
      }, replace: { _, _ in fatalError("Find must not replace") })
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(panel.window!.contentView!)
    let field = views.compactMap { $0 as? NSSearchField }.first!
    let buttons = views.compactMap { $0 as? NSButton }
    func click(_ title: String) {
      let button = buttons.first { $0.title == title }!
      _ = button.target?.perform(button.action, with: button)
    }
    field.stringValue = "alpha"
    click("Find All")
    let deadline = Date().addingTimeInterval(3)
    while selected.isEmpty && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(selected == [NSRange(location: 0, length: 5)])
    click("Next")
    precondition(selected.last == NSRange(location: 11, length: 5))
    click("Next")
    precondition(selected.last == NSRange(location: 0, length: 5))
    source = "changed"
    click("Next")
    precondition(selected.count == 3, "Stale search must not select new text offsets")
    panel.close()
    print("PASS native search panel finds, wraps, and rejects stale offsets")
  }
}
