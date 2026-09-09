import AppKit
import PadCore

private func comparisonViews(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(comparisonViews)
}

@main struct ComparisonHarness {
  @MainActor static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for text in [
      String(repeating: "x", count: 16_001), String(repeating: "\u{1}", count: 4_000),
      String(repeating: String(repeating: "\u{1}", count: 1_000) + "\n", count: 400),
    ] {
      let large = try TextComparison.compare(left: text, right: "")
      var rejected = false
      do { _ = try ComparisonController.displayRows(large, left: true) } catch { rejected = true }
      precondition(rejected, "Expanded/long comparison display must reject before native layout")
    }
    let left = (0..<100).map { "line \($0)\r\n" }.joined()
    let controller = ComparisonController(leftText: left, leftName: "Synthetic left")
    controller.showWindow(nil)
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let views = comparisonViews(content)
    let texts = views.compactMap { $0 as? NSTextView }
    let scrolls = views.compactMap { $0 as? NSScrollView }
    let next = views.compactMap { $0 as? NSButton }.first { $0.title == "Next Difference" }!
    let previous = views.compactMap { $0 as? NSButton }.first { $0.title == "Previous Difference" }!
    func wait(_ predicate: () -> Bool) {
      let deadline = Date().addingTimeInterval(10)
      while !predicate(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(predicate(), "Comparison did not reach expected state")
    }
    precondition(texts.count == 2 && scrolls.count == 2)
    precondition(texts.allSatisfy { !$0.isEditable })
    controller.compare(rightText: "inserted\n" + left, rightName: "Synthetic right")
    wait { next.isEnabled }
    precondition(texts[0].string.hasPrefix("   ∅"))
    precondition(texts[1].string.contains("inserted ⏎LF"))
    precondition(texts[0].string.contains("line 0 ⏎CRLF"))
    precondition(scrolls.allSatisfy { $0.bounds.width > 200 && $0.bounds.height > 150 })
    precondition(
      texts[0].string.filter { $0 == "\n" }.count == texts[1].string.filter { $0 == "\n" }.count)
    next.performClick(nil)
    precondition(texts[0].selectedRange().location == 0 && texts[0].selectedRange().length > 0)
    previous.performClick(nil)
    precondition(texts[1].selectedRange().location == 0)
    scrolls[0].contentView.scroll(to: NSPoint(x: 0, y: 200))
    NotificationCenter.default.post(
      name: NSView.boundsDidChangeNotification, object: scrolls[0].contentView)
    precondition(
      abs(scrolls[0].contentView.bounds.origin.y - scrolls[1].contentView.bounds.origin.y) < 1)
    controller.compare(rightText: String(repeating: "x\n", count: 1900), rightName: "Old request")
    precondition(!next.isEnabled && texts[0].string.isEmpty)
    controller.compare(rightText: left, rightName: "Latest request")
    wait { !texts[0].string.isEmpty }
    precondition(!next.isEnabled && !previous.isEnabled)
    precondition(texts[0].string == texts[1].string)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("right.txt")
    try DocumentCodec.encode(DecodedDocument(text: left, encoding: .utf16BE, hasBOM: true)).write(
      to: file)
    let original = try Data(contentsOf: file)
    controller.openRightFile(file)
    wait { !texts[0].string.isEmpty }
    precondition(!next.isEnabled && texts[0].string == texts[1].string)
    let after = try Data(contentsOf: file)
    precondition(after == original)
    controller.compare(
      rightText: String(repeating: "x", count: 16_001), rightName: "Long-line rejection")
    wait { views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("16,000") } }
    precondition(!next.isEnabled && texts.allSatisfy { $0.string.isEmpty })
    controller.compare(rightText: "changed", rightName: "Closing request")
    controller.window!.performClose(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    precondition(!next.isEnabled && texts[0].string.isEmpty)
    print(
      "PASS native read-only comparison alignment, ending markers, navigation, synchronized scrolling, latest-request guard, UTF-16 file loading, unchanged source and close cancellation"
    )
  }
}
