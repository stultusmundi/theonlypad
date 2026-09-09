import AppKit
import PadCore

@main struct MarkdownHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    let controller = MarkdownPreviewController(
      text:
        "# Heading\n- **bold** and *italic* with `code`\n```\nlet x = 1\n```\n<script>inert</script>\n![alt](https://invalid.test/image)\n[link](https://invalid.test)"
    )
    let views = descendants(controller.window!.contentView!)
    let editor = views.compactMap { $0 as? NSTextView }.first!
    wait { editor.string.contains("Heading") }
    precondition(!editor.isEditable && editor.isSelectable)
    let storage = editor.textStorage!
    func font(_ text: String) -> NSFont {
      let range = (editor.string as NSString).range(of: text)
      precondition(range.location != NSNotFound)
      return storage.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont
    }
    precondition(font("Heading").pointSize > font("bold").pointSize)
    precondition(NSFontManager.shared.traits(of: font("bold")).contains(.boldFontMask))
    precondition(NSFontManager.shared.traits(of: font("italic")).contains(.italicFontMask))
    precondition(font("code").isFixedPitch && font("let x").isFixedPitch)
    precondition(editor.string.contains("• bold"))
    precondition(editor.string.contains("<script>inert</script>"))
    precondition(editor.string.contains("![alt](https://invalid.test/image)"))
    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
      attributes, _, _ in
      precondition(attributes[.link] == nil && attributes[.attachment] == nil)
    }
    let rejected = MarkdownPreviewController(text: String(repeating: "x", count: 2_000_001))
    wait {
      descendants(rejected.window!.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("exceeds")
      }
    }
    let cancelled = MarkdownPreviewController(
      text: String(repeating: "**synthetic** text\n", count: 15_000))
    let cancelledEditor = descendants(cancelled.window!.contentView!).compactMap {
      $0 as? NSTextView
    }.first!
    var closeCalled = false
    cancelled.onClose = { closeCalled = true }
    cancelled.close()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    precondition(closeCalled && cancelledEditor.string.isEmpty)
    print(
      "PASS native Markdown preview: heading/list/emphasis/code fonts, inert markup with no links/attachments, input limit and close cancellation"
    )
  }
  @MainActor static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  @MainActor static func wait(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !predicate() && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(predicate())
  }
}
