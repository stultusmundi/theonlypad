import AppKit
import PadCore

@main struct LaunchHarness {
  @MainActor static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    let first = directory.appendingPathComponent("unicode space é #?.txt")
    let second = directory.appendingPathComponent("second.txt")
    let firstText = "a👩🏽‍💻e\u{301}\r\nאב\r終\n"
    let secondText = "second\n👨‍👩‍👧‍👦x\n"
    try Data(firstText.utf8).write(to: first)
    try Data(secondText.utf8).write(to: second)

    // Exercise the real application URL delegate and asynchronous file loading.
    delegate.application(
      app, open: [try LaunchRequest(url: first, line: 1, column: 3).protocolURL()])
    waitForSelection(text: firstText, offset: 8)
    delegate.application(
      app, open: [try LaunchRequest(url: second, line: 2, column: 2).protocolURL()])
    waitForSelection(text: secondText, offset: 18)
    // Reopening an existing tab must apply its new position, including column clamping.
    delegate.application(
      app, open: [try LaunchRequest(url: first, line: 2, column: 99).protocolURL()])
    waitForSelection(text: firstText, offset: 14)
    // A batch must retain independent positions even when the active tab changes.
    delegate.application(
      app,
      open: [
        try LaunchRequest(url: first, line: 3, column: 1).protocolURL(),
        try LaunchRequest(url: second, line: 1, column: 4).protocolURL(),
      ])
    waitForSelection(text: secondText, offset: 3)
    let controller = app.windows.compactMap { $0.windowController as? EditorWindowController }
      .first!
    controller.open(first)
    waitForSelection(text: firstText, offset: 15)
    precondition(app.windows.filter { $0.windowController is EditorWindowController }.count == 1)
    print(
      "PASS native launch routing: literal Unicode path, grapheme positions, mixed endings, clamping, existing tabs and per-file batch positions"
    )
    withExtendedLifetime(delegate) {}
  }

  @MainActor static func waitForSelection(text: String, offset: Int) {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      let editors = NSApp.windows.compactMap(\.contentView).flatMap(descendants)
        .compactMap { $0 as? NSTextView }
        .filter { $0.accessibilityLabel() == "Document text" }
      if editors.contains(where: {
        $0.string.utf16.elementsEqual(text.utf16)
          && $0.selectedRange() == NSRange(location: offset, length: 0)
      }) {
        return
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    preconditionFailure(
      "Native protocol route did not select expected synthetic UTF16 offset \(offset)")
  }

  @MainActor static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
