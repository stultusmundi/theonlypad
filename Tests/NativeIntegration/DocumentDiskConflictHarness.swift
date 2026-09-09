import AppKit
import Darwin

@main struct DocumentDiskConflictHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    var checks = 0
    var failures = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      if !value {
        failures += 1
        print("FAIL \(message)")
      }
    }
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func buttons(_ owner: DocumentDiskConflictController) -> [NSButton] {
      owner.window?.contentView.map { descendants($0).compactMap { $0 as? NSButton } } ?? []
    }
    var calls: [String] = []
    var closedBeforeHandler = false
    var closeCount = 0
    let owner = DocumentDiskConflictController(
      documentName: "Synthetic.txt", explanation: "Changed on disk and read-only.",
      actions: [
        .init(
          title: "Keep Buffer", accessibilityID: "document.keepBuffer",
          handler: {
            closedBeforeHandler = closeCount == 1
            calls.append("keep")
          }),
        .init(
          title: "Open Disk Copy", accessibilityID: "document.openDiskCopy",
          handler: { calls.append("copy") }),
      ])
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: owner.window, queue: nil
    ) { _ in MainActor.assumeIsolated { closeCount += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    check(
      owner.window is NSPanel && owner.window?.title == "Resolve File Change", "native panel title")
    check(owner.window?.isVisible == false && calls.isEmpty, "construction never shows or invokes")
    let labels =
      owner.window?.contentView.map { descendants($0).compactMap { $0 as? NSTextField } } ?? []
    check(labels.contains { $0.stringValue == "Synthetic.txt" }, "document name label")
    check(
      labels.contains {
        $0.stringValue == "Changed on disk and read-only."
          && $0.accessibilityLabel() == $0.stringValue
      }, "accessible explanation")
    let keep = buttons(owner).first { $0.accessibilityIdentifier() == "document.keepBuffer" }
    let copy = buttons(owner).first { $0.accessibilityIdentifier() == "document.openDiskCopy" }
    let close = buttons(owner).first {
      $0.accessibilityIdentifier() == "document.closeDiskConflict"
    }
    check(
      keep?.title == "Keep Buffer" && keep?.accessibilityLabel() == "Keep Buffer",
      "action title and AX label")
    check(
      close?.title == "Close" && close?.keyEquivalent == "\u{1b}",
      "Close is native Escape key equivalent")
    keep?.performClick(nil)
    check(calls == ["keep"] && closedBeforeHandler, "native close precedes selected handler")
    keep?.performClick(nil)
    copy?.performClick(nil)
    close?.performClick(nil)
    check(calls == ["keep"] && closeCount == 1, "retained panel buttons cannot repeat actions")
    check(buttons(owner).allSatisfy { !$0.isEnabled }, "consumed panel disables all buttons")
    var cancelCalls = 0
    let cancelled = DocumentDiskConflictController(
      documentName: "Cancel.txt", explanation: "Synthetic",
      actions: [
        .init(
          title: "Action", accessibilityID: "document.syntheticAction",
          handler: { cancelCalls += 1 })
      ])
    cancelled.window?.cancelOperation(nil)
    buttons(cancelled).first?.performClick(nil)
    check(
      cancelCalls == 0 && !buttons(cancelled).isEmpty
        && buttons(cancelled).allSatisfy { !$0.isEnabled },
      "native cancel consumes panel without handler")
    let closed = DocumentDiskConflictController(
      documentName: "Close.txt", explanation: "Synthetic",
      actions: [
        .init(
          title: "Action", accessibilityID: "document.syntheticAction",
          handler: { cancelCalls += 1 })
      ])
    buttons(closed).first { $0.title == "Close" }?.performClick(nil)
    buttons(closed).first?.performClick(nil)
    check(
      cancelCalls == 0 && !buttons(closed).isEmpty && buttons(closed).allSatisfy { !$0.isEnabled },
      "Close button invokes no action")
    let direct = DocumentDiskConflictController(
      documentName: "Window close", explanation: "Synthetic",
      actions: [
        .init(
          title: "Action", accessibilityID: "document.syntheticAction",
          handler: { cancelCalls += 1 })
      ])
    direct.window?.close()
    buttons(direct).first?.performClick(nil)
    check(
      cancelCalls == 0 && !buttons(direct).isEmpty && buttons(direct).allSatisfy { !$0.isEnabled },
      "native window close prevents late button action")
    let empty = DocumentDiskConflictController(
      documentName: "No actions", explanation: "Synthetic", actions: [])
    check(
      buttons(empty).count == 1 && buttons(empty).first?.title == "Close",
      "empty action list still has real Close")
    empty.close()
    print("DISK CONFLICT CHECKS \(checks) FAILURES \(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
