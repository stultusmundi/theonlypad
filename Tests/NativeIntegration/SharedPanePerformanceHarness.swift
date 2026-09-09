import AppKit
import Darwin
import PadCore

@MainActor private final class WindowDelegate: NSObject, NSWindowDelegate {
  let undo: UndoManager
  init(_ undo: UndoManager) { self.undo = undo }
  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
}
@main struct SharedPanePerformanceHarness {
  struct Sample: Codable {
    let index: Int
    let focusedPane: Int
    let editSeconds: Double
    let undoSeconds: Double
    let resizeSeconds: Double
    let wrapToggleSeconds: Double
    let peakRSSBytes: Int64
    let endCaretVisible: Bool
  }
  struct Report: Codable {
    let bytes: Int
    let fixture: String
    let layouts: Int
    let axis: String
    let repeats: Int
    let scope: String
    let operatingSystem: String
    let hardware: String
    let processor: String
    let physicalMemory: UInt64
    let toolchain: String
    let samples: [Sample]
    let limitations: [String]
  }
  static func machine(_ key: String) -> String {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return "unavailable" }
    return String(cString: value)
  }
  @MainActor static func displayEnd(_ panes: [EditorPane], host: EditorPaneHost) {
    host.layoutSubtreeIfNeeded()
    for pane in panes {
      let end = pane.document.storage.length
      pane.layoutManager.ensureLayout(
        forCharacterRange: NSRange(location: max(0, end - 1), length: min(1, end)))
      pane.editor.sizeToFit()
      pane.editor.scrollRangeToVisible(NSRange(location: end, length: 0))
      pane.scroll.layoutSubtreeIfNeeded()
      pane.scroll.displayIfNeeded()
    }
    // Bounded native event/display drain is part of each measured operation.
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
  }
  @MainActor static func settleActivation(window: NSWindow) {
    let app = NSApplication.shared
    let deadline = Date(timeIntervalSinceNow: 5)
    var stableSince: Date?
    var nextRequest = Date.distantPast
    while Date() < deadline {
      let now = Date()
      if app.isActive && window.isKeyWindow {
        if stableSince == nil { stableSince = now }
        if now.timeIntervalSince(stableSince!) >= 0.2 { return }
      } else {
        stableSince = nil
        if now >= nextRequest {
          window.makeKeyAndOrderFront(nil)
          app.activate(ignoringOtherApps: true)
          _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
          nextRequest = now.addingTimeInterval(0.25)
        }
      }
      if let event = app.nextEvent(
        matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true)
      {
        app.sendEvent(event)
      }
      app.updateWindows()
    }
    // The unchanged strict admission gate reports any unsuccessful activation afterward.
  }
  @MainActor static func requireVisible(
    _ panes: [EditorPane], focused: EditorPane, window: NSWindow, stage: String
  ) {
    func require(_ condition: Bool, _ reason: String) {
      if !condition {
        FileHandle.standardError.write(
          Data("VISIBILITY FAILURE stage=\(stage) reason=\(reason)\n".utf8))
        preconditionFailure("Benchmark visibility admission failed")
      }
    }
    require(NSApplication.shared.isActive, "application inactive")
    require(
      window.isVisible && window.isKeyWindow && !window.isMiniaturized, "window not visible/key")
    require(window.occlusionState.contains(.visible), "window occluded")
    require(window.firstResponder === focused.editor, "wrong focused editor")
    require(
      focused.editor.selectedRange()
        == NSRange(location: focused.document.storage.length, length: 0),
      "caret not at document end")
    for pane in panes {
      require(
        pane.editor.window === window && !pane.editor.isHiddenOrHasHiddenAncestor,
        "pane not displayed")
      let screen = pane.editor.firstRect(
        forCharacterRange: NSRange(location: pane.document.storage.length, length: 0),
        actualRange: nil)
      require(
        screen.origin.x.isFinite && screen.origin.y.isFinite && screen.width.isFinite
          && screen.height.isFinite && screen.height > 0, "invalid end geometry")
      // NSTextInputClient can report a zero-width insertion rectangle; normalize only its width.
      var caretScreen = screen
      caretScreen.size.width = max(1, caretScreen.width)
      let local = pane.editor.convert(window.convertFromScreen(caretScreen), from: nil)
      require(
        pane.editor.visibleRect.insetBy(dx: -1, dy: -1).contains(local),
        "end rectangle clipped by viewport")
      require(
        NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(caretScreen) },
        "end rectangle off screen")
    }
    // Only focused has an active caret; the other pane checks prove end geometry visibility.
  }
  @MainActor static func wrap(_ enabled: Bool, panes: [EditorPane]) {
    for pane in panes {
      pane.editor.isHorizontallyResizable = !enabled
      pane.editor.autoresizingMask = enabled ? [.width] : []
      pane.scroll.hasHorizontalScroller = !enabled
      pane.textContainer.widthTracksTextView = enabled
      pane.textContainer.containerSize = NSSize(
        width: enabled ? pane.scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)
      if enabled {
        pane.editor.setFrameSize(
          NSSize(width: pane.scroll.contentSize.width, height: pane.editor.frame.height))
      }
    }
  }
  @MainActor static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 7, let bytes = Int(args[1]),
      [1_000_000, 10_000_000, 100_000_000].contains(bytes),
      ["multiline", "longline"].contains(args[2]), let count = Int(args[3]),
      [1, 2].contains(count),
      ["sideBySide", "stacked"].contains(args[4]), let repeats = Int(args[5]), repeats >= 20,
      repeats <= 100
    else { fatalError("Expected size fixture pane-count axis repeats toolchain-file") }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let unit = args[2] == "multiline" ? "0123456789abcdef\n" : "0123456789abcdef"
    let baseline =
      String(repeating: unit, count: bytes / unit.utf8.count)
      + String(unit.prefix(bytes % unit.utf8.count))
    let document = EditorDocument()
    document.storage.mutableString.setString(baseline)
    var panes = [document.panePool[0]]
    if count == 2 { panes.append(try document.makePane()) }
    precondition(document.storage.layoutManagers.count == count)
    let host = EditorPaneHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    let window = NSWindow(
      contentRect: host.bounds, styleMask: [.titled, .resizable, .closable], backing: .buffered,
      defer: false)
    let delegate = WindowDelegate(document.undoManager)
    window.delegate = delegate
    window.contentView = host
    window.title = "Synthetic shared-pane adapter benchmark"
    try host.present(panes: panes, axis: args[4] == "stacked" ? .stacked : .sideBySide)
    app.finishLaunching()
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    defer { window.orderOut(nil) }
    document.undoManager.groupsByEvent = false
    wrap(false, panes: panes)
    displayEnd(panes, host: host)
    var samples: [Sample] = []
    for index in 0..<repeats {
      let pane = panes[index % count]
      precondition(window.makeFirstResponder(pane.editor))
      pane.editor.setSelectedRange(NSRange(location: bytes, length: 0))
      displayEnd(panes, host: host)
      settleActivation(window: window)
      requireVisible(panes, focused: pane, window: window, stage: "before-edit")
      let editStart = ProcessInfo.processInfo.systemUptime
      document.undoManager.beginUndoGrouping()
      pane.editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      pane.editor.breakUndoCoalescing()
      document.undoManager.endUndoGrouping()
      displayEnd(panes, host: host)
      let edit = ProcessInfo.processInfo.systemUptime - editStart
      requireVisible(panes, focused: pane, window: window, stage: "after-edit")
      precondition(document.storage.string.utf16.elementsEqual((baseline + "X").utf16))
      let undoStart = ProcessInfo.processInfo.systemUptime
      document.undoManager.undo()
      displayEnd(panes, host: host)
      let undo = ProcessInfo.processInfo.systemUptime - undoStart
      requireVisible(panes, focused: pane, window: window, stage: "after-undo")
      precondition(document.storage.string.utf16.elementsEqual(baseline.utf16))
      document.undoManager.removeAllActions()
      let resizeStart = ProcessInfo.processInfo.systemUptime
      window.setContentSize(
        NSSize(width: index % 2 == 0 ? 980 : 1100, height: index % 2 == 0 ? 680 : 760))
      displayEnd(panes, host: host)
      let resize = ProcessInfo.processInfo.systemUptime - resizeStart
      requireVisible(panes, focused: pane, window: window, stage: "after-resize")
      let wrapStart = ProcessInfo.processInfo.systemUptime
      wrap(true, panes: panes)
      displayEnd(panes, host: host)
      let wrapped = ProcessInfo.processInfo.systemUptime - wrapStart
      requireVisible(panes, focused: pane, window: window, stage: "after-wrap-enabled")
      let unwrapStart = ProcessInfo.processInfo.systemUptime
      wrap(false, panes: panes)
      displayEnd(panes, host: host)
      let wrapTime = wrapped + (ProcessInfo.processInfo.systemUptime - unwrapStart)
      requireVisible(panes, focused: pane, window: window, stage: "after-wrap-disabled")
      let caretVisible = true
      precondition(document.storage.string.utf16.elementsEqual(baseline.utf16))
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      let sample = Sample(
        index: index + 1, focusedPane: index % count, editSeconds: edit, undoSeconds: undo,
        resizeSeconds: resize, wrapToggleSeconds: wrapTime, peakRSSBytes: Int64(usage.ru_maxrss),
        endCaretVisible: caretVisible)
      samples.append(sample)
      let progress = try JSONEncoder().encode(sample)
      FileHandle.standardError.write(progress + Data([10]))
    }
    let report = Report(
      bytes: bytes, fixture: args[2], layouts: count, axis: args[4], repeats: repeats,
      scope:
        "Adapter stress using actual EditorDocument/EditorPane/EditorPaneHost. Two-layout inputs above 2M UTF16 bypass the app guard for measurement only.",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      hardware: machine("hw.model"), processor: machine("machdep.cpu.brand_string"),
      physicalMemory: ProcessInfo.processInfo.physicalMemory,
      toolchain: try String(contentsOfFile: args[6], encoding: .utf8), samples: samples,
      limitations: [
        "Synthetic ASCII; bytes equal UTF16 units.",
        "Visible window and native display drain, not physical input-to-photon latency.",
        "Adapter harness excludes controller dirty/recovery/highlighting and command routing overhead.",
        "Warm repeated operations; initial allocation/layout excluded from sample durations but watchdog includes them.",
        "Visibility and undo/text validation outside operation timing; wrap duration sums two intervals excluding the intermediate visibility gate. Allocations/native caches affect subsequent samples and peak RSS.",
        "Visibility gates require active/key non-occluded window, focused end caret and full screen/viewport containment after every state. They are geometry/window-state evidence, not physical pixel capture or proof against partial occlusion.",
        "Twenty observations permit descriptive empirical order statistics, not population percentile confidence or target acceptance.",
        "Window server contention and hardware/power state uncontrolled.",
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    withExtendedLifetime(delegate) {}
  }
}
