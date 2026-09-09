import AppKit

/// A logical-line gutter for the system text engine. Large documents omit it
/// until an incremental line index can keep viewport updates bounded.
@MainActor
final class LineNumberRuler: NSRulerView {
  private weak var textView: NSTextView?
  private var observers: [NSObjectProtocol] = []
  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 52
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
    setAccessibilityLabel("Line numbers")
  }
  required init(coder: NSCoder) { fatalError("Use init(scrollView:textView:)") }
  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
  override func drawHashMarksAndLabels(in rect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
    else { return }
    let text = textView.string as NSString
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
      let next = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
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
      let rulerY = y + textView.textContainerOrigin.y - visible.minY
      if rulerY > bounds.maxY { break }
      let label = String(number) as NSString
      label.draw(
        at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 8, y: rulerY),
        withAttributes: attributes)
      if offset == text.length { break }
      let next = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
      guard next > offset else { break }
      offset = next
      number += 1
    }
  }
}
