import AppKit
import PadCore
import XCTest

@testable import NativeRouting

/// Hidden real-controller checks. No windows are shown and no keyboard events are posted.
/// Breaks caught: omitted unassigned commands, stale default chords, regex matching,
/// incorrect UTF-16 selections, missing query reset/wrapping, and selection without scrolling.
@MainActor final class HelpReferenceTests: XCTestCase {
  func testSearchableGuideAndEffectiveShortcutReference() throws {
    _ = NSApplication.shared
    func check(_ value: Bool, _ label: String) {
      XCTAssertTrue(value, label)
    }
    var catalog = try AppCommands.registry().commands
    catalog += [
      .init(id: "help.fixture.override", title: "Reference Needle Alpha", shortcut: "cmd+9"),
      .init(id: "help.fixture.disabled", title: "Reference Needle Beta", shortcut: "cmd+8"),
      .init(id: "help.fixture.unassigned", title: "Unassigned Reference Command"),
      .init(id: "extension.synthetic.reference", title: "Synthetic 🧪 Ωmega Extension"),
      .init(id: "help.fixture.literal", title: "Literal [a+b]. Reference Command"),
    ]
    let profile = try ShortcutProfile(records: [
      .init(
        commandID: "help.fixture.override",
        assignment: .assigned(try KeyboardShortcut(canonicalString: "cmd+ctrl+shift+9"))),
      .init(commandID: "help.fixture.disabled", assignment: .disabled),
    ])
    let composition = try ShortcutComposer.build(
      catalog: catalog, profile: profile, catalogRevision: UUID())
    check(
      composition.conflicts.isEmpty && !composition.usesDefaults, "real custom shortcuts compose")
    let commands = composition.registry.commands
    check(
      commands.first { $0.id == "help.fixture.override" }?.shortcut == "cmd+ctrl+shift+9",
      "override fixture has effective canonical Control chord")
    check(
      commands.first { $0.id == "help.fixture.disabled" }?.shortcut == nil,
      "disabled fixture has no effective shortcut")
    let controller = HelpController(commands: commands)
    defer { withExtendedLifetime(controller) {} }
    guard let window = controller.window, let content = window.contentView else {
      check(false, "real help window and content exist")
      return
    }
    check(!window.isVisible, "help checks keep the window hidden")
    let views = descendants(content)
    func identified(_ id: String) -> [NSView] {
      views.filter { $0.accessibilityIdentifier() == id }
    }
    let textViews = identified("help.text")
    check(
      textViews.count == 1 && (textViews.first as? NSTextView) != nil,
      "help.text identifies the actual guide text view")
    // Keep inspecting the old guide when its new identifier/controls are missing.
    // This fallback cannot make the missing identifier assertion pass.
    guard
      let text = (textViews.first as? NSTextView)
        ?? views.compactMap({ $0 as? NSTextView }).first
    else {
      check(false, "actual help text view is available for reference checks")
      return
    }
    let searchViews = identified("help.search")
    let nextViews = identified("help.next")
    let previousViews = identified("help.previous")
    let statusViews = identified("help.matchStatus")
    let search = searchViews.first as? NSSearchField
    let next = nextViews.first as? NSButton
    let previous = previousViews.first as? NSButton
    let status = statusViews.first as? NSTextField
    check(searchViews.count == 1 && search != nil, "help.search is a native search field")
    check(nextViews.count == 1 && next != nil, "help.next is a native button")
    check(previousViews.count == 1 && previous != nil, "help.previous is a native button")
    check(statusViews.count == 1 && status != nil, "help.matchStatus is a native status label")
    check(!text.isEditable && text.isSelectable, "guide remains read-only and selectable")
    let original = text.string
    let originalUTF16 = Array(original.utf16)
    let lines = Set(
      original.components(separatedBy: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    for command in commands {
      let expected = command.title + " — " + (command.shortcut ?? "No shortcut")
      check(lines.contains(expected), "complete effective reference: \(command.id)")
    }
    for expected in [
      "Reference Needle Alpha — cmd+ctrl+shift+9",
      "Reference Needle Beta — No shortcut",
      "Unassigned Reference Command — No shortcut",
      "Synthetic 🧪 Ωmega Extension — No shortcut",
      "Literal [a+b]. Reference Command — No shortcut",
    ] {
      check(lines.contains(expected), "literal custom reference: \(expected)")
    }
    check(!lines.contains("Reference Needle Alpha — cmd+9"), "override replaces the default chord")
    check(!lines.contains("Reference Needle Beta — cmd+8"), "disabled default is not advertised")
    check(original.contains("ctrl = Control"), "shortcut legend explains Control")
    for heading in ["Documents and recovery", "Finding text", "Split views", "Keyboard shortcuts"] {
      check(original.contains(heading), "full existing guide retains \(heading)")
    }
    guard let search, let next, let previous, let status else {
      print("UNAVAILABLE search interaction checks: required controls are missing")
      return
    }
    // Delayed per-keystroke target actions must not advance the newly selected first match.
    check(
      search.sendsWholeSearchString,
      "native search waits for the whole search string before sending an advance action")
    check(search.stringValue.isEmpty, "initial search query is empty")
    check(status.stringValue.isEmpty, "initial match status is empty")
    check(!next.isEnabled && !previous.isEnabled, "empty initial query disables navigation")
    window.setContentSize(NSSize(width: 700, height: 600))
    content.layoutSubtreeIfNeeded()
    if let layout = text.layoutManager, let container = text.textContainer {
      layout.ensureLayout(for: container)
    }
    check(
      text.visibleRect.width > 100 && text.visibleRect.height > 100,
      "hidden help layout preserves a usable guide viewport")

    func unchanged(_ label: String) {
      check(text.string.utf16.elementsEqual(originalUTF16), "guide unchanged after \(label)")
    }
    func changeQuery(_ value: String) {
      search.stringValue = value
      let notification = Notification(name: NSControl.textDidChangeNotification, object: search)
      if let delegate = search.delegate,
        delegate.responds(to: NSSelectorFromString("controlTextDidChange:"))
      {
        delegate.controlTextDidChange?(notification)
      } else if let action = search.action, let target = search.target {
        check(
          NSApplication.shared.sendAction(action, to: target, from: search),
          "native search change action is delivered")
      } else {
        check(false, "search has a native text-change delegate or action")
      }
      unchanged("query \(value)")
    }
    func expectedRange(_ literal: String) -> NSRange {
      (original as NSString).range(of: literal)
    }
    let alphaTitle = expectedRange("Reference Needle Alpha")
    let betaTitle = expectedRange("Reference Needle Beta")
    let needleLength = "Reference Needle".utf16.count
    let alpha = NSRange(location: alphaTitle.location, length: needleLength)
    let beta = NSRange(location: betaTitle.location, length: needleLength)
    check(
      alphaTitle.location != NSNotFound && betaTitle.location != NSNotFound,
      "two distinct synthetic titles supply independent literal match locations")
    func selected(
      _ expected: NSRange, substring: String, status expectedStatus: String, label: String
    ) {
      let actual = text.selectedRange()
      check(actual == expected && expected.location != NSNotFound, "\(label): exact UTF-16 range")
      let source = text.string as NSString
      if actual.location >= 0 && actual.length >= 0 && actual.location <= source.length
        && actual.length <= source.length - actual.location
      {
        check(source.substring(with: actual) == substring, "\(label): exact source substring")
      } else {
        check(false, "\(label): selection stays inside the actual guide")
      }
      check(status.stringValue == expectedStatus, "\(label): exact match status")
      check(next.isEnabled && previous.isEnabled, "\(label): navigation enabled")
      if actual.length > 0, actual.location >= 0, actual.location <= source.length,
        actual.length <= source.length - actual.location,
        let layout = text.layoutManager, let container = text.textContainer
      {
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: actual, actualCharacterRange: nil)
        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
          .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        check(
          !bounds.isEmpty && text.visibleRect.intersects(bounds),
          "\(label): controller scrolls the selected match into view")
      } else {
        check(false, "\(label): selected match has actual layout geometry")
      }
      unchanged(label)
    }
    func click(_ button: NSButton, label: String) {
      check(
        button.target != nil && button.action != nil, "\(label): native help action is configured")
      if button.target != nil && button.action != nil { button.performClick(nil) }
    }
    changeQuery("rEfErEnCe NeEdLe")
    selected(alpha, substring: "Reference Needle", status: "1 of 2 matches", label: "first match")
    click(next, label: "Next")
    selected(beta, substring: "Reference Needle", status: "2 of 2 matches", label: "Next")
    click(next, label: "Next wraps")
    selected(alpha, substring: "Reference Needle", status: "1 of 2 matches", label: "Next wraps")
    click(previous, label: "Previous wraps")
    selected(beta, substring: "Reference Needle", status: "2 of 2 matches", label: "Previous wraps")
    click(previous, label: "Previous")
    selected(alpha, substring: "Reference Needle", status: "1 of 2 matches", label: "Previous")
    // Invoke the field's native Return action/delegate, never a posted key event.
    if let action = search.action, let target = search.target {
      check(
        NSApplication.shared.sendAction(action, to: target, from: search),
        "native search Return action is delivered")
    } else if let handled = search.delegate?.control?(
      search, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    {
      check(handled, "native search delegate handles Return")
    } else {
      check(false, "search exposes a native Return action or delegate")
    }
    selected(
      beta, substring: "Reference Needle", status: "2 of 2 matches", label: "Return advances")

    changeQuery("dOcUmEnTs AnD rEcOvErY")
    selected(
      expectedRange("Documents and recovery"), substring: "Documents and recovery",
      status: "1 of 1 matches", label: "search includes full guide prose")
    changeQuery("Reference Needle")
    selected(
      alpha, substring: "Reference Needle", status: "1 of 2 matches", label: "new query resets")
    changeQuery("[a+b].")
    selected(
      expectedRange("[a+b]."), substring: "[a+b].", status: "1 of 1 matches",
      label: "regex punctuation is literal")
    changeQuery("🧪 ΩMEGA")
    selected(
      expectedRange("🧪 Ωmega"), substring: "🧪 Ωmega", status: "1 of 1 matches",
      label: "supplementary Unicode selection")
    check(text.selectedRange().length == 8, "supplementary scalar counts as two UTF-16 units")
    changeQuery("synthetic-no-such-help-needle-7")
    check(status.stringValue == "No matches", "not-found query reports No matches")
    check(!next.isEnabled && !previous.isEnabled, "not-found query disables both directions")
    unchanged("not-found navigation state")
    changeQuery("")
    check(status.stringValue.isEmpty, "clearing query clears status")
    check(!next.isEnabled && !previous.isEnabled, "clearing query disables both directions")
    unchanged("empty query")
    check(!text.isEditable && text.isSelectable, "search preserves read-only selectable guide")
    check(!window.isVisible, "native actions never show the help window")
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
