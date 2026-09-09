import AppKit

@main struct BookmarkRulerHarness {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
    editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 8, height: 8)
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.documentView = editor
    scroll.hasVerticalScroller = true
    let ruler = LineNumberRuler(scrollView: scroll, textView: editor)
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    window.contentView!.addSubview(scroll)
    window.orderFront(nil)
    var toggles: [Int] = []
    ruler.onToggleBookmark = { toggles.append($0) }
    func layout(_ text: String) {
      editor.string = text
      editor.layoutManager!.ensureLayout(for: editor.textContainer!)
      editor.sizeToFit()
      window.contentView!.layoutSubtreeIfNeeded()
      ruler.needsDisplay = true
      ruler.displayIfNeeded()
    }
    func click(atUTF16 offset: Int) {
      let manager = editor.layoutManager!
      let fragment: NSRect
      if offset == editor.string.utf16.count {
        fragment = manager.extraLineFragmentRect
      } else {
        fragment = manager.lineFragmentRect(
          forGlyphAt: manager.glyphIndexForCharacter(at: offset), effectiveRange: nil)
      }
      let point = editor.convert(
        NSPoint(x: editor.textContainerOrigin.x, y: editor.textContainerOrigin.y + fragment.midY),
        to: nil)
      let gutterPoint = ruler.convert(NSPoint(x: 8, y: ruler.convert(point, from: nil).y), to: nil)
      let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: gutterPoint, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      ruler.mouseDown(with: event)
    }
    layout("😀\r\nsecond\rthird\n")
    func image(_ rect: NSRect) -> Data {
      let bitmap = ruler.bitmapImageRepForCachingDisplay(in: rect)!
      ruler.cacheDisplay(in: rect, to: bitmap)
      return bitmap.representation(using: .png, properties: [:])!
    }
    let numbersRect = NSRect(
      x: 20, y: 0, width: ruler.bounds.width - 20, height: ruler.bounds.height)
    let unmarked = image(ruler.bounds)
    let numbers = image(numbersRect)
    ruler.bookmarkOffsets = [0, 11]
    precondition(
      image(ruler.bounds) != unmarked, "Bookmarks must actually paint visible gutter pixels")
    precondition(
      image(numbersRect) == numbers, "Bookmark indicators must preserve rendered line numbers")
    precondition(ruler.accessibilityLabel()?.contains("2 bookmarks") == true)
    click(atUTF16: 4)
    click(atUTF16: 17)
    precondition(
      toggles == [4, 17], "Clicks must route UTF-16 logical offsets including final empty line")
    ruler.bookmarkOffsets = []
    precondition(ruler.accessibilityLabel()?.contains("0 bookmarks") == true)
    layout("first " + String(repeating: "wrapped ", count: 30) + "\nlast")
    let glyph = editor.layoutManager!.glyphIndexForCharacter(at: 80)
    let wrapped = editor.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    precondition(wrapped.minY > 0, "Fixture must actually wrap")
    click(atUTF16: 80)
    precondition(toggles.last == 0, "Wrapped continuation must toggle original logical line")
    layout(String(repeating: "😀\n", count: 100))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scroll.reflectScrolledClipView(scroll.contentView)
    click(atUTF16: 30)
    precondition(toggles.last == 30, "Scrolled gutter must account for viewport origin")
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    layout("")
    click(atUTF16: 0)
    precondition(toggles.last == 0)
    let beforeBlank = toggles.count
    let below = ruler.convert(NSPoint(x: 8, y: ruler.bounds.maxY - 5), to: nil)
    let blankEvent = NSEvent.mouseEvent(
      with: .leftMouseDown, location: below, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
    ruler.mouseDown(with: blankEvent)
    precondition(
      toggles.count == beforeBlank, "Blank space below text must not toggle nearest last line")
    editor.string = String(repeating: "x", count: 2_000_001)
    ruler.mouseDown(with: blankEvent)
    precondition(
      toggles.count == beforeBlank, "Existing ruler size limit must also guard hit testing")
    window.close()
    print(
      "PASS native gutter draw, bookmark count, UTF-16 click routing, wrapped continuation, scrolled viewport, empty/final line, blank-space and size guards"
    )
  }
}
