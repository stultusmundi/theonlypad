import AppKit

enum PaneAxis: Equatable { case sideBySide, stacked }
enum EditorPaneHostError: Error { case paneLimit, duplicatePane }

@MainActor private final class PaneSplitView: NSSplitView {
  var moveDivider: ((CGFloat) -> Void)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { subviews.count == 2 }
  override func keyDown(with event: NSEvent) {
    let backwards: UInt16 = isVertical ? 123 : 126
    let forwards: UInt16 = isVertical ? 124 : 125
    if subviews.count == 2, event.keyCode == backwards || event.keyCode == forwards {
      let step: CGFloat = event.modifierFlags.contains(.shift) ? 40 : 10
      moveDivider?(event.keyCode == backwards ? -step : step)
    } else {
      super.keyDown(with: event)
    }
  }
}

/// Arrangement only. The controller owns panes, attachment, model lifetime and focus policy.
/// This host retains existing views through the native hierarchy, never EditorPane/model objects.
@MainActor final class EditorPaneHost: NSView, NSSplitViewDelegate {
  private let split = PaneSplitView()
  private(set) var displayedIDs: [UUID] = []
  private var axis: PaneAxis = .sideBySide
  private var fraction: CGFloat = 0.5
  private var arranging = false
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    split.dividerStyle = .thin
    split.delegate = self
    split.autoresizingMask = [.width, .height]
    split.setAccessibilityIdentifier("editor.paneLayout")
    split.setAccessibilityLabel("Editor pane layout")
    split.moveDivider = { [weak self] delta in self?.moveDivider(by: delta) }
    addSubview(split)
    split.frame = bounds
    setAccessibilityIdentifier("editor.paneHost")
    setAccessibilityLabel("Editor panes")
  }
  required init?(coder: NSCoder) { nil }

  func present(panes: [EditorPane], axis: PaneAxis) throws {
    guard panes.count <= 2 else { throw EditorPaneHostError.paneLimit }
    guard Set(panes.map(\.id)).count == panes.count,
      Set(panes.map { ObjectIdentifier($0.scroll) }).count == panes.count
    else { throw EditorPaneHostError.duplicatePane }
    let nextIDs = panes.map(\.id)
    let oldFocus = window?.firstResponder as? NSView
    let focusInside =
      oldFocus.map { focus in
        split.subviews.contains { focus === $0 || focus.isDescendant(of: $0) }
      } ?? false
    let focusSurvives =
      oldFocus.map { focus in
        panes.contains { focus === $0.scroll || focus.isDescendant(of: $0.scroll) }
      } ?? false
    if nextIDs != displayedIDs {
      for view in split.subviews { view.removeFromSuperview() }
      for (index, pane) in panes.enumerated() {
        pane.scroll.setAccessibilityIdentifier("editor.pane.\(pane.id.uuidString)")
        pane.scroll.setAccessibilityLabel("Editor pane \(index + 1)")
        split.addSubview(pane.scroll)
      }
      displayedIDs = nextIDs
      fraction = 0.5
    }
    self.axis = axis
    split.isVertical = axis == .sideBySide
    split.frame = bounds
    arrange()
    if focusInside, !focusSurvives {
      window?.makeFirstResponder(panes.first?.editor)
    } else if window?.firstResponder === split, panes.count < 2 {
      window?.makeFirstResponder(panes.first?.editor)
    }
    needsLayout = true
  }
  override func layout() {
    super.layout()
    split.frame = bounds
    arrange()
  }
  private var availableExtent: CGFloat {
    max(
      0, (axis == .sideBySide ? split.bounds.width : split.bounds.height) - split.dividerThickness)
  }
  private func limitedPosition(_ proposed: CGFloat) -> CGFloat {
    let available = availableExtent
    let minimum = min(160, available / 2)
    return min(max(proposed, minimum), available - minimum)
  }
  private func arrange() {
    guard !arranging else { return }
    arranging = true
    defer { arranging = false }
    guard split.subviews.count == 2 else {
      split.subviews.first?.frame = split.bounds
      return
    }
    let available = availableExtent
    let first = limitedPosition(available * fraction)
    let thickness = min(
      split.dividerThickness, axis == .sideBySide ? split.bounds.width : split.bounds.height)
    if axis == .sideBySide {
      split.subviews[0].frame = NSRect(x: 0, y: 0, width: first, height: split.bounds.height)
      split.subviews[1].frame = NSRect(
        x: first + thickness, y: 0, width: max(0, available - first), height: split.bounds.height)
    } else {
      split.subviews[0].frame = NSRect(x: 0, y: 0, width: split.bounds.width, height: first)
      split.subviews[1].frame = NSRect(
        x: 0, y: first + thickness, width: split.bounds.width, height: max(0, available - first))
    }
  }
  private func moveDivider(by delta: CGFloat) {
    guard split.subviews.count == 2, availableExtent > 0 else { return }
    let current =
      axis == .sideBySide ? split.subviews[0].frame.width : split.subviews[0].frame.height
    fraction = limitedPosition(current + delta) / availableExtent
    arrange()
  }
  func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrange() }
  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard !arranging, split.subviews.count == 2, availableExtent > 0 else { return }
    let first = axis == .sideBySide ? split.subviews[0].frame.width : split.subviews[0].frame.height
    fraction = min(1, max(0, first / availableExtent))
  }
  func splitView(
    _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    min(160, availableExtent / 2)
  }
  func splitView(
    _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    availableExtent - min(160, availableExtent / 2)
  }
  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
