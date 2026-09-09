import AppKit
import PadCore

private func utilityDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(utilityDescendants)
}

@main struct TextUtilitiesHarness {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var replacement: String?
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let controller = TextUtilitiesController(text: "hello", pasteboard: pasteboard) {
      replacement = $0
    }
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let views = utilityDescendants(content)
    let picker = views.compactMap { $0 as? NSPopUpButton }.first!
    let preview = views.compactMap { $0 as? NSTextView }.first!
    let copy = views.compactMap { $0 as? NSButton }.first { $0.title == "Copy Output" }!
    let replace = views.compactMap { $0 as? NSButton }.first { $0.title == "Replace" }!
    func wait(_ predicate: () -> Bool) {
      let deadline = Date().addingTimeInterval(5)
      while !predicate() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(predicate(), "Native conversion did not complete")
    }
    func choose(_ operation: TextUtilityOperation) {
      picker.selectItem(at: TextUtilityOperation.allCases.firstIndex(of: operation)!)
      _ = picker.target?.perform(picker.action, with: picker)
    }
    wait { copy.isEnabled }
    precondition(!preview.isEditable)
    precondition(preview.bounds.width > 0, "Preview must have a visible layout width")
    precondition(preview.string == "aGVsbG8=")
    copy.performClick(nil)
    precondition(
      pasteboard.string(forType: .string) == "aGVsbG8=",
      "Copy writes the successful preview to the requested pasteboard")
    precondition(replacement == nil, "Preview must never replace automatically")
    replace.performClick(nil)
    precondition(replacement == "aGVsbG8=")
    replacement = nil
    choose(.sha256)
    precondition(
      !copy.isEnabled && !replace.isEnabled, "Old output must be disabled while recomputing")
    wait { copy.isEnabled }
    precondition(
      preview.string == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    precondition(!replace.isEnabled)
    copy.performClick(nil)
    precondition(pasteboard.string(forType: .string) == preview.string)
    replace.performClick(nil)
    precondition(replacement == nil)
    choose(.base64Decode)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(!copy.isEnabled && !replace.isEnabled && preview.string.isEmpty)
    choose(.urlEncode)
    choose(.jsonEscape)
    wait { copy.isEnabled }
    precondition(
      preview.string == "\"hello\"", "Stale operations cannot override the latest selection")
    controller.window!.performClose(nil)
    precondition(
      !copy.isEnabled && !replace.isEnabled, "Native window close invalidates converted output")
    print(
      "PASS native immutable preview, explicit Replace, copy-only checksum, errors, latest-operation guard and close invalidation"
    )
  }
}
