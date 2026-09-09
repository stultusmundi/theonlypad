import AppKit
import Darwin
import PadCore

struct ExpectedCheckpoint: Codable {
  let documentID: UUID
  let generation: UInt64
  let selection: NSRange
}
@main struct CheckpointEditProbe {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    precondition(CommandLine.arguments.count == 4)
    let mode = CommandLine.arguments[1]
    let state = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let file = URL(fileURLWithPath: CommandLine.arguments[3])
    setenv("THEONLYPAD_STATE_DIRECTORY", state.path, 1)
    let app = NSApplication.shared
    let evidence = state.deletingLastPathComponent().appendingPathComponent(
      "evidence", isDirectory: true)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let marker = evidence.appendingPathComponent("expected.json")
    var rows: [[String: Any]] = []
    var phase = "setup"
    var pendingOperation: Int?
    func preservePartial() throws {
      guard mode == "write" else { return }
      var partial: [String: Any] = [
        "phase": phase, "edits": rows,
        "recordedAt": ProcessInfo.processInfo.systemUptime,
      ]
      if let error = CheckpointTrace.lastError { partial["checkpointError"] = error }
      if let pendingOperation { partial["pendingOperation"] = pendingOperation }
      try JSONSerialization.data(withJSONObject: partial, options: [.sortedKeys])
        .write(to: evidence.appendingPathComponent("partial-edits.json"), options: .atomic)
      try JSONEncoder().encode(CheckpointTrace.events)
        .write(
          to: evidence.appendingPathComponent("partial-checkpoint-events.json"), options: .atomic)
      try JSONEncoder().encode(DiskTrace.shared.snapshot())
        .write(to: evidence.appendingPathComponent("partial-disk-events.json"), options: .atomic)
    }
    func wait(_ reason: String, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(20)
      phase = "waiting: " + reason
      var nextEvidence = Date.distantPast
      while !condition() && Date() < deadline {
        if Date() >= nextEvidence {
          try preservePartial()
          nextEvidence = Date().addingTimeInterval(0.5)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      try preservePartial()
      precondition(condition(), reason)
    }
    if mode == "restore" {
      let expected = try JSONDecoder().decode(
        ExpectedCheckpoint.self, from: Data(contentsOf: marker))
      let session = SessionCoordinator()
      var restored: EditorWindowController?
      await session.restore { prepared in
        let controller = EditorWindowController(
          id: prepared.id, restoreStartup: false, onSessionChange: {})
        var failures: [UUID: String] = [:]
        for tab in prepared.tabs {
          do {
            try controller.restoreSessionTab(
              tab.metadata, decoded: tab.decoded,
              originalBytes: tab.originalBytes, url: tab.url, viewState: tab.viewState)
          } catch { failures[tab.metadata.id] = error.localizedDescription }
        }
        controller.selectSessionTab(prepared.selectedTabID)
        restored = controller
        return failures
      }
      precondition(session.restorationComplete && session.unresolved.isEmpty)
      let pane = restored!.focusedPane!
      precondition(pane.document.id == expected.documentID && pane.document.url == nil)
      let original = try DocumentCodec.decode(Data(contentsOf: file)).text as NSString
      let wanted = NSMutableString(string: original as String)
      wanted.replaceCharacters(in: NSRange(location: wanted.length - 1, length: 1), with: "Z")
      precondition(pane.document.storage.string.utf16.elementsEqual((wanted as String).utf16))
      precondition(pane.editor.selectedRange() == expected.selection)
      print("PASS separate-process real session/recovery restoration exact100MB text and selection")
      return
    }
    precondition(mode == "write")
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let session = SessionCoordinator()
    await session.restore { _ in preconditionFailure("fresh state required") }
    var windows: [EditorWindowController] = []
    let checkpoints = ApplicationSessionCheckpoints(session: session, windows: { windows })
    session.onSessionChange = { checkpoints.requestCheckpoint() }
    let controller = EditorWindowController(
      restoreStartup: false,
      onSessionChange: { checkpoints.requestCheckpoint() })
    windows.append(controller)
    controller.showWindow(nil)
    controller.window!.setContentSize(NSSize(width: 900, height: 650))
    controller.window!.center()
    var opened = false
    controller.open(file, onOpened: { opened = true })
    try await wait("open failed") { opened }
    let pane = controller.focusedPane!
    let document = pane.document
    let storage = document.storage
    let editor = pane.editor
    precondition(storage.length == 100_000_000 && !document.dirty)
    let originalBytes = document.originalBytes!
    let saved = document.savedText as NSString
    let last = NSRange(location: storage.length - 1, length: 1)
    precondition(saved.substring(with: last) != "Z")
    document.undoManager.groupsByEvent = false
    func settleActivation() {
      let deadline = Date(timeIntervalSinceNow: 5)
      var stableSince: Date?
      var nextRequest = Date.distantPast
      while Date() < deadline {
        let now = Date()
        if app.isActive && controller.window!.isKeyWindow {
          if stableSince == nil { stableSince = now }
          if now.timeIntervalSince(stableSince!) >= 0.2 { return }
        } else {
          stableSince = nil
          if now >= nextRequest {
            controller.window!.makeKeyAndOrderFront(nil)
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
    }
    // Every operation that may lay out or scroll is called INSIDE its respective timer.
    func prepareVisible(_ target: NSRange) -> (NSRect, NSRect, NSRange) {
      let selection = editor.selectedRange()
      pane.layoutManager.ensureLayout(forCharacterRange: target)
      editor.sizeToFit()
      editor.scrollRangeToVisible(NSUnionRange(target, selection))
      controller.window!.contentView!.layoutSubtreeIfNeeded()
      controller.window!.displayIfNeeded()
      _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
      let caret = editor.firstRect(forCharacterRange: selection, actualRange: nil)
      let unit = editor.firstRect(forCharacterRange: target, actualRange: nil)
      let bounds = editor.visibleRect.offsetBy(
        dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
      let glyphs = pane.layoutManager.glyphRange(forBoundingRect: bounds, in: pane.textContainer)
      let chars = pane.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      controller.window!.displayIfNeeded()
      if editor.selectedRange() != selection {
        FileHandle.standardError.write(
          Data("VISIBILITY FAILURE: display changed native selection\n".utf8))
        preconditionFailure("Strict selection preservation failed")
      }
      return (caret, unit, chars)
    }
    // No text geometry request, scroll, layout, display or focus repair after timing.
    func assertVisible(_ target: NSRange, selection: NSRange, captured: (NSRect, NSRect, NSRange)) {
      let window = controller.window!
      func require(_ condition: Bool, _ reason: String) {
        guard condition else {
          FileHandle.standardError.write(Data(("VISIBILITY FAILURE: " + reason + "\n").utf8))
          preconditionFailure("Strict visibility admission failed")
        }
      }
      require(app.isActive, "application inactive")
      require(window.isKeyWindow, "window not key")
      require(window.isVisible, "window not visible")
      require(!window.isMiniaturized, "window miniaturized")
      require(window.occlusionState.contains(.visible), "window occluded")
      require(window.firstResponder === editor && controller.focusedPane === pane, "focus changed")
      require(
        editor.window === window && !editor.isHiddenOrHasHiddenAncestor, "editor detached or hidden"
      )
      require(editor.selectedRange() == selection, "native selection changed after display")
      require(
        selection.location >= 0 && selection.location <= storage.length && selection.length >= 0
          && selection.length <= storage.length - selection.location,
        "native selection out of bounds")
      require(NSIntersectionRange(captured.2, target).length > 0, "target text must be visible")
      for rectangle in [captured.0, captured.1] {
        require(
          rectangle.origin.x.isFinite && rectangle.origin.y.isFinite && rectangle.width.isFinite
            && rectangle.height.isFinite && rectangle.height > 0, "invalid target rectangle")
        var screen = rectangle
        screen.size.width = max(1, screen.width)
        let local = editor.convert(window.convertFromScreen(screen), from: nil)
        require(
          editor.visibleRect.insetBy(dx: -1, dy: -1).contains(local), "target clipped by viewport")
        require(
          NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(screen) },
          "target off screen")
      }
    }
    _ = controller.window!.makeFirstResponder(editor)
    settleActivation()
    editor.setSelectedRange(NSRange(location: storage.length, length: 0))
    let initialSelection = editor.selectedRange()
    phase = "initial visibility admission after bounded activation settle"
    try preservePartial()
    let initialGeometry = prepareVisible(last)
    assertVisible(last, selection: initialSelection, captured: initialGeometry)
    checkpoints.startAfterRestoration()
    try await wait("initial metadata not acknowledged") {
      checkpoints.lastAcknowledgedGeneration > 0 && !checkpoints.hasPendingChanges
        && checkpoints.lastError == nil
    }
    let initialAck = checkpoints.lastAcknowledgedGeneration
    editor.breakUndoCoalescing()
    document.undoManager.beginUndoGrouping()
    editor.insertText("Z", replacementRange: last)
    document.undoManager.endUndoGrouping()
    try await wait("real recovery write never started") { DiskTrace.shared.recoveryWriteIsActive() }
    for operation in 0..<8 {
      // No artificial writer gates/delays; overlap admission is observed, never assumed.
      settleActivation()
      phase = "operation"
      pendingOperation = operation
      try preservePartial()
      let expectedDirty = !operation.isMultiple(of: 2)
      let writeActive = DiskTrace.shared.recoveryWriteIsActive()
      let began = ProcessInfo.processInfo.systemUptime
      if operation.isMultiple(of: 2) {
        document.undoManager.undo()
      } else {
        document.undoManager.redo()
      }
      let selection = editor.selectedRange()
      let geometry = prepareVisible(last)
      let dirty = document.dirty
      let ended = ProcessInfo.processInfo.systemUptime
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      rows.append([
        "peakRSSBytes": usage.ru_maxrss, "operation": operation,
        "kind": expectedDirty ? "redo" : "undo",
        "start": began, "end": ended, "milliseconds": (ended - began) * 1000,
        "recoveryWriteActiveAtStart": writeActive,
        "acknowledgedGeneration": checkpoints.lastAcknowledgedGeneration, "validated": false,
      ])
      // Preserve the measured row before any assertion can terminate the child.
      try preservePartial()
      assertVisible(last, selection: selection, captured: geometry)
      precondition(storage.length == 100_000_000)
      precondition(dirty == expectedDirty)
      precondition(dirty == !storage.string.utf16.elementsEqual(document.savedText.utf16))
      precondition(
        storage.mutableString.substring(with: last)
          == (expectedDirty ? "Z" : saved.substring(with: last)))
      rows[rows.count - 1]["validated"] = true
      pendingOperation = nil
      try preservePartial()
      try await Task.sleep(nanoseconds: 150_000_000)
    }
    precondition(document.dirty && storage.mutableString.substring(with: last) == "Z")
    try await wait("latest periodic checkpoint not acknowledged") {
      checkpoints.lastAcknowledgedGeneration > initialAck && !checkpoints.hasPendingChanges
        && checkpoints.lastError == nil
    }
    await checkpoints.pauseAndDrain()
    let acknowledged = checkpoints.lastAcknowledgedGeneration
    let metadata = try await Task.detached { try SessionStore().load()! }.value
    let recovered = try await Task.detached { try RecoveryStore(directory: state).loadAll() }.value
    precondition(metadata.windows.count == 1 && metadata.windows[0].tabs.count == 1)
    precondition(metadata.windows[0].tabs[0].id == document.id)
    precondition(metadata.windows[0].tabs[0].selection == editor.selectedRange())
    let snapshot = recovered.first { $0.id == document.id }!
    precondition(snapshot.text.utf16.elementsEqual(storage.string.utf16))
    let diskOriginal = try Data(contentsOf: file)
    precondition(diskOriginal == originalBytes)
    let diskEvents = DiskTrace.shared.snapshot()
    let starts = diskEvents.filter { $0.kind == "recoveryWriteStart" }
    let ends = diskEvents.filter { $0.kind == "recoveryWriteEnd" }
    precondition(!starts.isEmpty && starts.count == ends.count)
    var overlaps = 0
    for row in rows {
      let start = row["start"] as! Double
      let end = row["end"] as! Double
      if zip(starts, ends).contains(where: { start < $0.1.seconds && end > $0.0.seconds }) {
        overlaps += 1
      }
    }
    precondition(
      overlaps > 0, "No observed edit/write overlap; do not admit a concurrency measurement")
    phase = "validated on-disk recovery and overlap"
    try preservePartial()
    let expected = ExpectedCheckpoint(
      documentID: document.id, generation: acknowledged, selection: editor.selectedRange())
    try JSONEncoder().encode(expected).write(to: marker, options: .atomic)
    try JSONEncoder().encode(CheckpointTrace.events).write(
      to: evidence.appendingPathComponent("checkpoint-events.json"))
    try JSONEncoder().encode(diskEvents).write(
      to: evidence.appendingPathComponent("disk-events.json"))
    let data = try JSONSerialization.data(
      withJSONObject: [
        "edits": rows, "overlapCount": overlaps,
        "acknowledgedGeneration": acknowledged,
      ], options: [.sortedKeys])
    try data.write(to: evidence.appendingPathComponent("edit-results.json"))
    print(String(decoding: data, as: UTF8.self))
    print(
      "PASS real periodic checkpoint writes/acknowledgement/exact stored recovery; restore child still required"
    )
    // No final save/quit checkpoint and no document-close cleanup changes the measured publication.
    withExtendedLifetime([controller, checkpoints] as [AnyObject]) { exit(0) }
  }
}
