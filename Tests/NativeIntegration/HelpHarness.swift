import AppKit
import PadCore

/// Real help viewport and scroll coverage; no physical keyboard or VoiceOver claim.
@main struct HelpHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let controller = HelpController(commands: try AppCommands.registry().commands)
    controller.showWindow(nil)
    let window = controller.window!
    defer { window.orderOut(nil) }
    for size: NSSize? in [nil, NSSize(width: 700, height: 600), NSSize(width: 440, height: 360)] {
      if let size { window.setContentSize(size) }
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      window.contentView!.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      // Focusing Help search adds a native field editor. Select the guide explicitly.
      let guides = descendants(window.contentView!).compactMap { $0 as? NSTextView }.filter {
        $0.accessibilityIdentifier() == "help.text"
      }
      precondition(guides.count == 1, "Help must expose exactly one guide text view")
      let text = guides[0]
      precondition(
        !text.isFieldEditor && text.enclosingScrollView != nil,
        "Help viewport checks must target the scrollable guide, not a field editor")
      precondition(
        text.visibleRect.width > 100 && text.visibleRect.height > 100,
        "Help must provide a usable visible text viewport")
      let original = text.string
      precondition(original.contains("Documents and recovery"))
      let layout = text.layoutManager!
      let container = text.textContainer!
      layout.ensureLayout(for: container)
      for offset in [0, original.utf16.count - 2] {
        text.setSelectedRange(NSRange(location: offset, length: 1))
        text.scrollRangeToVisible(text.selectedRange())
        window.displayIfNeeded()
        let glyphs = layout.glyphRange(
          forCharacterRange: text.selectedRange(), actualCharacterRange: nil)
        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
          .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        precondition(
          !bounds.isEmpty && text.visibleRect.intersects(bounds),
          "Help start and end glyphs must be reachable after resizing")
        precondition(text.string.utf16.elementsEqual(original.utf16))
      }
    }
    print("PASS Help usable viewport and start/end scrolling at two window sizes")
    withExtendedLifetime(controller) {}
  }
  @MainActor private static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
