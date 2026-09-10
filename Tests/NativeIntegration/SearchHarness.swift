import AppKit
import PadCore

@main struct SearchHarness {
  private final class ScriptedSearch: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func run(
      _ query: SearchQuery, _ text: String, _ replacement: String, _ replacing: Bool
    ) throws -> ([NSRange], String?) {
      lock.lock()
      callCount += 1
      let call = callCount
      lock.unlock()
      if call == 1 { return ([NSRange(location: 0, length: 1)], nil) }
      throw SearchError.engineFailure
    }
  }

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

    var failureSelections = 0
    var failureReplacements = 0
    let scriptedSearch = ScriptedSearch()
    let failurePanel = SearchPanelController(
      snapshot: { "aa" },
      select: { _, _ in
        failureSelections += 1
        return true
      },
      replace: { _, _ in
        failureReplacements += 1
        return true
      },
      search: { query, text, replacement, replacing in
        try scriptedSearch.run(query, text, replacement, replacing)
      })
    let failureViews = descendants(failurePanel.window!.contentView!)
    let failureField = failureViews.compactMap { $0 as? NSSearchField }.first!
    let failureStatus = failureViews.compactMap { $0 as? NSTextField }.first {
      $0.stringValue == "Search the document that opened this panel."
    }!
    let failureButtons = failureViews.compactMap { $0 as? NSButton }
    failureField.stringValue = "a"
    let findAll = failureButtons.first { $0.title == "Find All" }!
    _ = findAll.target?.perform(findAll.action, with: findAll)
    let firstResultDeadline = Date().addingTimeInterval(3)
    while failureSelections == 0 && Date() < firstResultDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(failureSelections == 1, "Control search must publish its first result")
    let replaceAll = failureButtons.first { $0.title == "Replace All…" }!
    _ = replaceAll.target?.perform(replaceAll.action, with: replaceAll)
    let failureDeadline = Date().addingTimeInterval(3)
    while !failureStatus.stringValue.contains("The search engine could not finish")
      && Date() < failureDeadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(
      failureStatus.stringValue
        == "Search stopped: The search engine could not finish. Narrow the pattern and try again.")
    precondition(failureSelections == 1, "Failed search must not publish a result selection")
    precondition(failureReplacements == 0, "Failed replacement must not reach the document")
    let failureNext = failureButtons.first { $0.title == "Next" }!
    _ = failureNext.target?.perform(failureNext.action, with: failureNext)
    precondition(failureSelections == 1, "Failed search must clear earlier navigable matches")
    failurePanel.close()
    print(
      "PASS native search panel finds, wraps, rejects stale offsets, and reports engine failure")
  }
}
