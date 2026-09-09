import AppKit
import PadCore

/// Value-only deferred layout state. Text, history, recovery and file authority remain on the document.
@MainActor final class DocumentPanePresentation {
  struct Pending {
    var presentation: SessionPresentation
    let livePaneID: UUID
    let liveSlot: Int
    let resolvedAtRevision: UInt64
    var presented = false
  }
  var pending: Pending?
  var interaction = UUID()
  var installing: UUID?
  var warning: String?
  var frozenCapture: SessionPresentation?
  var suppression = 0
  func invalidate(force: Bool = false) {
    guard force || suppression == 0 else { return }
    interaction = UUID()
  }
  func capture(panes: [EditorPane], preferred: EditorPane, axis: PaneAxis) -> SessionPresentation {
    if let frozenCapture { return frozenCapture }
    if let pending {
      guard pending.presented,
        let live = panes.first(where: { $0.id == pending.livePaneID })
      else {
        return pending.presentation
      }
      var values = pending.presentation.panes
      values[pending.liveSlot] = Self.state(live)
      return SessionPresentation(
        axis: pending.presentation.axis, panes: values,
        focusedPaneIndex: pending.presentation.focusedPaneIndex)
    }
    return SessionPresentation(
      axis: axis == .stacked ? .stacked : .sideBySide,
      panes: panes.map(Self.state),
      focusedPaneIndex: panes.firstIndex(where: { $0 === preferred }) ?? 0)
  }
  static func state(_ pane: EditorPane) -> SessionPaneState {
    let origin = pane.scroll.contentView.bounds.origin
    // AppKit can expose elastic negative origins. Persist bounded document coordinates.
    func bounded(_ value: CGFloat) -> Double {
      value.isFinite ? min(1_000_000_000, max(0, Double(value))) : 0
    }
    return SessionPaneState(
      selection: pane.editor.selectedRange(),
      scrollOrigin: SessionScrollOrigin(x: bounded(origin.x), y: bounded(origin.y)))
  }
  /// Exactly one attempt. Later geometry changes never replay a saved origin.
  static func applyOrigin(_ origin: SessionScrollOrigin, to pane: EditorPane) -> Bool {
    let clip = pane.scroll.contentView
    guard clip.bounds.width.isFinite, clip.bounds.height.isFinite,
      clip.bounds.width > 0, clip.bounds.height > 0,
      pane.editor.bounds.width.isFinite, pane.editor.bounds.height.isFinite,
      pane.editor.bounds.width > 0, pane.editor.bounds.height > 0
    else { return false }
    var proposed = clip.bounds
    proposed.origin = NSPoint(x: origin.x, y: origin.y)
    let constrained = clip.constrainBoundsRect(proposed)
    clip.scroll(to: constrained.origin)
    pane.scroll.reflectScrolledClipView(clip)
    return true
  }
}
