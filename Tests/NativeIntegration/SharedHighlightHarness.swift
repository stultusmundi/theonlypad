import AppKit
import PadCore

@main struct SharedHighlightHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let original = "let value = \"synthetic\" // comment\n"
    let storage = NSTextStorage(string: original)
    func view() -> NSTextView {
      let layout = NSLayoutManager()
      let container = NSTextContainer(size: NSSize(width: 600, height: 600))
      storage.addLayoutManager(layout)
      layout.addTextContainer(container)
      return NSTextView(frame: .zero, textContainer: container)
    }
    let left = view()
    let right = view()
    left.setSelectedRange(NSRange(location: 1, length: 0))
    right.setSelectedRange(NSRange(location: 5, length: 2))
    let highlighter = NativeSyntaxHighlighter(editor: left)
    highlighter.update(language: .swift)
    let deadline = Date().addingTimeInterval(5)
    while left.layoutManager!.temporaryAttribute(
      .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil, Date() < deadline
    {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    for editor in [left, right] {
      precondition(
        editor.layoutManager!.temporaryAttribute(
          .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor == .systemPurple,
        "Every presentation must receive shared syntax colors")
    }
    precondition(storage.string.utf16.elementsEqual(original.utf16))
    precondition(left.selectedRange() == NSRange(location: 1, length: 0))
    precondition(right.selectedRange() == NSRange(location: 5, length: 2))
    highlighter.update(language: .plainText)
    for editor in [left, right] {
      precondition(
        editor.layoutManager!.temporaryAttribute(
          .foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
    }
    print(
      "PASS shared syntax: both layout managers colored/cleared with exact text and independent selection"
    )
    withExtendedLifetime([left, right, highlighter] as [AnyObject]) {}
  }
}
