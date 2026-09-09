import AppKit
import PadCore

@main struct TabAccessibilityHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    let bar = DocumentTabBar()
    let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let items = [
      TabItem(id: first, title: "First", dirty: false, pinned: false),
      TabItem(id: second, title: "Second", dirty: true, pinned: true),
    ]
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    func assertIDs(_ ids: [UUID]) {
      let controls = buttons(bar)
      let expected = Set(
        ids.flatMap { ["tab.select." + $0.uuidString, "tab.close." + $0.uuidString] })
      precondition(
        Set(controls.compactMap { $0.identifier?.rawValue }) == expected, "Routing IDs changed")
      precondition(
        Set(controls.map { $0.accessibilityIdentifier() }) == expected,
        "Accessibility IDs missing or stale")
      precondition(controls.count == expected.count, "Duplicate tab controls")
    }
    bar.update(items: items, selectedID: first)
    assertIDs([first, second])
    bar.update(items: items, selectedID: second)
    assertIDs([first, second])
    bar.update(
      items: [TabItem(id: second, title: "Renamed", dirty: false, pinned: false)],
      selectedID: second)
    assertIDs([second])
    var selected: UUID?
    var closed: UUID?
    bar.onSelect = { selected = $0 }
    bar.onClose = { closed = $0 }
    let controls = buttons(bar)
    controls.first { $0.accessibilityIdentifier() == "tab.select." + second.uuidString }!
      .performClick(nil)
    controls.first { $0.accessibilityIdentifier() == "tab.close." + second.uuidString }!
      .performClick(nil)
    precondition(selected == second && closed == second, "Existing UUID routing broke")
    print(
      "PASS tab accessibility IDs: initial, selection, rename, removal and UUID callback routing")
  }
}
