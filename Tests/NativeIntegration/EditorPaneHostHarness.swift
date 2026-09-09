import AppKit
import PadCore

@main struct EditorPaneHostHarness {
  @MainActor static func near(_ lhs: CGFloat, _ rhs: CGFloat) {
    precondition(abs(lhs - rhs) < 0.01)
  }
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let host = EditorPaneHost(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let window = NSWindow(
      contentRect: host.bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    let document = EditorDocument()
    document.storage.mutableString.setString("synthetic shared panes\n")
    let first = document.panePool[0]
    let second = try document.makePane()
    let layouts = document.storage.layoutManagers.map(ObjectIdentifier.init)
    try host.present(panes: [], axis: .sideBySide)
    precondition(host.displayedIDs.isEmpty)
    try host.present(panes: [first], axis: .sideBySide)
    host.layoutSubtreeIfNeeded()
    precondition(first.scroll.frame == host.bounds)
    try host.present(panes: [first, second], axis: .sideBySide)
    host.layoutSubtreeIfNeeded()
    let split = first.scroll.superview as! NSSplitView
    near(
      first.scroll.frame.width + second.scroll.frame.width + split.dividerThickness,
      host.bounds.width)
    near(first.scroll.frame.height, host.bounds.height)
    near(first.scroll.frame.maxX + split.dividerThickness, second.scroll.frame.minX)
    precondition(first.editor.accessibilityLabel() == "Document text")
    precondition(second.editor.accessibilityLabel() == "Document text")
    precondition(first.scroll.accessibilityIdentifier() == "editor.pane.\(first.id.uuidString)")
    precondition(second.scroll.accessibilityIdentifier() == "editor.pane.\(second.id.uuidString)")
    precondition(window.makeFirstResponder(split))
    let before = first.scroll.frame.width
    let right = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
    split.keyDown(with: right)
    near(first.scroll.frame.width, before + 10)
    try host.present(panes: [first, second], axis: .stacked)
    host.layoutSubtreeIfNeeded()
    near(first.scroll.frame.width, host.bounds.width)
    near(first.scroll.frame.maxY + split.dividerThickness, second.scroll.frame.minY)
    near(
      first.scroll.frame.height + second.scroll.frame.height + split.dividerThickness,
      host.bounds.height)
    host.setFrameSize(NSSize(width: 900, height: 700))
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    near(first.scroll.frame.height + second.scroll.frame.height + split.dividerThickness, 700)
    near(second.scroll.frame.width, 900)
    host.setFrameSize(NSSize(width: 120, height: 100))
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    precondition(
      host.displayedIDs == [first.id, second.id], "Resize never silently collapses panes")
    precondition(
      host.bounds.contains(first.scroll.frame) && host.bounds.contains(second.scroll.frame))
    let beforeInvalid = host.displayedIDs
    do {
      try host.present(panes: [first, first], axis: .stacked)
      preconditionFailure("duplicate accepted")
    } catch EditorPaneHostError.duplicatePane {}
    precondition(host.displayedIDs == beforeInvalid)
    do {
      try host.present(panes: [first, second, first], axis: .stacked)
      preconditionFailure("third pane accepted")
    } catch EditorPaneHostError.paneLimit {}
    precondition(host.displayedIDs == beforeInvalid)
    precondition(window.makeFirstResponder(second.editor))
    try host.present(panes: [first], axis: .sideBySide)
    host.layoutSubtreeIfNeeded()
    precondition(window.firstResponder === first.editor)
    precondition(second.scroll.superview == nil && second.isAttached)
    precondition(
      document.storage.layoutManagers.map(ObjectIdentifier.init) == layouts,
      "Host must not allocate/detach text storage or layout managers")
    weak var oldDocument: EditorDocument?
    weak var oldPane: EditorPane?
    weak var oldScroll: NSScrollView?
    try autoreleasepool {
      let temporary = EditorDocument()
      oldDocument = temporary
      oldPane = temporary.panePool[0]
      oldScroll = temporary.panePool[0].scroll
      try host.present(panes: [temporary.panePool[0]], axis: .sideBySide)
    }
    precondition(oldDocument == nil && oldPane == nil, "Host must not retain model or pane objects")
    try autoreleasepool {
      try host.present(panes: [], axis: .sideBySide)
      host.layoutSubtreeIfNeeded()
    }
    precondition(oldScroll == nil, "Replaced scroll view must leave host ownership")
    precondition(host.displayedIDs.isEmpty)
    print(
      "PASS pane host: axes, geometry, resize, keyboard divider, focus, labels, replacement and ownership"
    )
  }
}
