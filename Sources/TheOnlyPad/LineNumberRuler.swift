import AppKit

/// A logical-line gutter for the system text engine. Large documents omit it
/// until an incremental line index can keep viewport updates bounded.
@MainActor
final class LineNumberRuler: NSRulerView {
  var bookmarkOffsets: Set<Int> = [] {
    didSet {
      setAccessibilityLabel("Line numbers and bookmarks — \(bookmarkOffsets.count) bookmarks")
      needsDisplay = true
    }
  }
  var onToggleBookmark: ((Int) -> Void)?
  private weak var textView: NSTextView?
  private var observers: [NSObjectProtocol] = []
  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 68
    scrollView.contentView.postsBoundsChangedNotifications = true
    for (name, object) in [
      (NSView.boundsDidChangeNotification, scrollView.contentView as AnyObject),
      (NSText.didChangeNotification, textView as AnyObject),
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
          [weak self] _ in
          self?.needsDisplay = true
        })
    }
    setAccessibilityElement(true)
    setAccessibilityLabel("Line numbers and bookmarks — 0 bookmarks")
    setAccessibilityHelp("Click a visible logical line to toggle its bookmark.")
  }
  required init(coder: NSCoder) { fatalError("Use init(scrollView:textView:)") }
  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
  override func drawHashMarksAndLabels(in rect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
    else { return }
    let text: NSString = textView.textStorage?.mutableString ?? (textView.string as NSString)
    guard text.length <= 2_000_000 else { return }
    let visible = textView.visibleRect
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let first =
      glyphs.location < layout.numberOfGlyphs
      ? layout.characterIndexForGlyph(at: glyphs.location) : 0
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: NSColor.secondaryLabelColor,
    ]
    var offset = 0
    var number = 1
    while offset < first {
      let next = logicalLineEnd(from: offset, in: text)
      if next > first { break }
      guard next > offset else { break }
      offset = next
      number += 1
    }
    while offset <= text.length {
      if offset == text.length, text.length > 0 {
        let last = text.character(at: text.length - 1)
        if last != 10 && last != 13 { break }
      }
      let y: CGFloat
      if offset < text.length {
        let glyph = layout.glyphIndexForCharacter(at: offset)
        y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
      } else {
        y = layout.extraLineFragmentRect.minY
      }
      let rulerY = convert(NSPoint(x: 0, y: y + textView.textContainerOrigin.y), from: textView).y
      if bookmarkOffsets.contains(offset), rulerY >= bounds.minY - 16 {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: rulerY + 3, width: 9, height: 9)).fill()
      }
      if rulerY > bounds.maxY { break }
      let label = String(number) as NSString
      label.draw(
        at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 8, y: rulerY),
        withAttributes: attributes)
      if offset == text.length { break }
      let next = logicalLineEnd(from: offset, in: text)
      guard next > offset else { break }
      offset = next
      number += 1
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard let onToggleBookmark, let textView, let layout = textView.layoutManager,
      let container = textView.textContainer
    else { return }
    let local = convert(event.locationInWindow, from: nil)
    guard bounds.contains(local) else { return }
    let text: NSString = textView.textStorage?.mutableString ?? (textView.string as NSString)
    guard text.length <= 2_000_000 else { return }
    let point = convert(local, to: textView)
    let containerPoint = NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y)
    guard containerPoint.y >= 0 else { return }
    let extra = layout.extraLineFragmentRect
    let hasFinalEmptyLine =
      text.length == 0 || text.character(at: text.length - 1) == 10
      || text.character(at: text.length - 1) == 13
    if hasFinalEmptyLine, extra.height > 0, containerPoint.y >= extra.minY,
      containerPoint.y < extra.maxY
    {
      onToggleBookmark(text.length)
      return
    }
    guard layout.numberOfGlyphs > 0 else { return }
    let glyph = layout.glyphIndex(for: containerPoint, in: container)
    guard glyph < layout.numberOfGlyphs else { return }
    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    guard containerPoint.y >= fragment.minY, containerPoint.y < fragment.maxY else { return }
    let character = layout.characterIndexForGlyph(at: glyph)
    var start = character
    if start > 0, start < text.length, text.character(at: start) == 10,
      text.character(at: start - 1) == 13
    {
      start -= 1
    }
    while start > 0 {
      let previous = text.character(at: start - 1)
      if previous == 10 || previous == 13 { break }
      start -= 1
    }
    onToggleBookmark(start)
  }
  private func logicalLineEnd(from offset: Int, in text: NSString) -> Int {
    var cursor = offset
    while cursor < text.length {
      let unit = text.character(at: cursor)
      cursor += 1
      if unit == 13 || unit == 10 {
        if unit == 13, cursor < text.length, text.character(at: cursor) == 10 { cursor += 1 }
        break
      }
    }
    return cursor
  }

}
