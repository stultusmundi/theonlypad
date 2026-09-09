import AppKit
import PadCore

@main struct NativeMonitorLifecycleHarness {
  @MainActor static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  @MainActor static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    precondition(predicate(), "Lifecycle condition did not complete")
  }
  @MainActor static func suspendedAdoption(_ scenario: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let url = directory.appendingPathComponent("suspended.txt")
    let bytes = Data("acknowledged".utf8)
    try bytes.write(to: url)
    let owner = ApplicationFileMonitoring()
    defer { owner.stop() }
    let controller = EditorWindowController(restoreStartup: false, onSessionChange: {})
    controller.configureFileMonitoring(owner)
    owner.onStateChange = { [weak controller] in controller?.reconcileFileMonitoring() }
    controller.newDocument()
    if scenario == "suspended-open" { owner.suspend() }
    var opened = false
    controller.open(
      url, onFailure: { fatalError("Synthetic open failed: \($0)") }, onOpened: { opened = true })
    try await until { opened }
    guard let document = controller.monitorHarnessCurrent else {
      fatalError("Loaded document missing")
    }
    if scenario == "suspended-save" {
      try await until { document.fileState?.state.observation?.content == .matchesBaseline }
      owner.suspend()
      let oldRevision = document.baselineRevision
      controller.monitorHarnessSave(document)
      try await until { !document.saving && document.baselineRevision > oldRevision }
    }
    precondition(owner.isSuspended && document.originalBytes == bytes && !document.dirty)
    let expectedRevision = document.baselineRevision
    // The AppDelegate suspends first, awaits startup/operations, then may veto quit.
    let prepared = await controller.prepareToQuit(persistRecovery: false)
    precondition(prepared)
    controller.cancelPreparedQuit()
    owner.resume()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let bridge = document.fileState,
        bridge.monitorHarnessReceipt?.baselineRevision == expectedRevision,
        bridge.state.observation?.content == .matchesBaseline
      {
        break
      }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
    precondition(
      document.fileState?.monitorHarnessReceipt?.baselineRevision == expectedRevision,
      "Suspended \(scenario) acknowledgement must register latest baseline after veto/resume")
    precondition(
      document.fileState?.state.observation?.content == .matchesBaseline,
      "Suspended acknowledgement must receive a current baseline observation after resume")
    let epoch = document.fileState!.monitorHarnessReceipt!.epoch
    controller.reconcileFileMonitoring()
    controller.reconcileFileMonitoring()
    precondition(
      document.fileState!.monitorHarnessReceipt!.epoch == epoch,
      "Ordinary reconciliation must not reset an already adopted binding")
    precondition(
      document.originalBytes == bytes && document.storage.string == "acknowledged"
        && !document.dirty)
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: controller.window))
    precondition(controller.window?.isVisible == false)
    print("Native suspended adoption passed: \(scenario)")
  }
  @MainActor static func conflictActions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let url = directory.appendingPathComponent("source.txt")
    let destination = directory.appendingPathComponent("saved-copy.txt")
    let bytes = Data("baseline".utf8)
    try bytes.write(to: url)
    var chooserCalls = 0
    var errors = 0
    var sessionChanges = 0
    let controller = EditorWindowController(
      restoreStartup: false,
      chooseSaveDestination: { _, _ in
        chooserCalls += 1
        return destination
      },
      onError: { _ in errors += 1 }, onSessionChange: { sessionChanges += 1 })
    let owner = ApplicationFileMonitoring()
    defer { owner.stop() }
    controller.configureFileMonitoring(owner)
    owner.onStateChange = { [weak controller] in controller?.reconcileFileMonitoring() }
    controller.newDocument()
    let scratch = controller.monitorHarnessCurrent!
    var opened = false
    controller.open(
      url, onFailure: { fatalError("Synthetic open failed: \($0)") }, onOpened: { opened = true })
    try await until { opened }
    let document = controller.monitorHarnessCurrent!
    let bridge = document.fileState!
    try await until { bridge.state.observation?.content == .matchesBaseline }
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    let edited = document.storage.string
    let external = Data("external".utf8)
    try external.write(to: url, options: .atomic)
    bridge.checkAgain()
    try await until { bridge.state.observation?.content == .differsFromBaseline }
    let revision = document.baselineRevision
    let notifications = sessionChanges
    controller.monitorHarnessRenderDiskStatus()
    precondition(sessionChanges == notifications, "Controller rendering cannot checkpoint")
    func click(_ panel: DocumentDiskConflictController, _ id: String) {
      precondition(panel.window?.isVisible == false, "Conflict factory must not show a panel")
      let buttons = descendants(panel.window!.contentView!).compactMap { $0 as? NSButton }
        .filter { $0.accessibilityIdentifier() == id }
      precondition(
        buttons.count == 1 && buttons[0].isEnabled, "Expected one admitted actual conflict button")
      buttons[0].performClick(nil)
      precondition(panel.window?.isVisible == false)
    }
    guard let check = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Conflict factory missing")
    }
    let actionIDs = Set(
      descendants(check.window!.contentView!).compactMap {
        ($0 as? NSButton)?.accessibilityIdentifier()
      })
    precondition(
      actionIDs.contains("document.diskReload") && actionIDs.contains("document.diskCopy"),
      "Actual conflict panel must expose admitted Reload and Open Disk Copy actions; got \(actionIDs.sorted())"
    )
    let sequence = bridge.monitorHarnessReceipt!.currentToken!.sequence
    click(check, "document.checkDisk")
    try await until {
      (bridge.monitorHarnessReceipt?.currentToken?.sequence ?? 0) > sequence
        && bridge.state.observation?.content == .differsFromBaseline
    }
    precondition(document.originalBytes == bytes && document.baselineRevision == revision)
    precondition(
      document.storage.string == edited && document.dirty && document.undoManager.canUndo)
    guard let keep = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Keep Buffer panel missing")
    }
    let beforeKeep = sessionChanges
    click(keep, "document.keepBuffer")
    precondition(!bridge.state.noticeIsProminent && sessionChanges == beforeKeep)
    precondition(document.originalBytes == bytes && document.baselineRevision == revision)
    precondition(
      document.storage.string == edited && document.dirty && document.undoManager.canUndo)
    guard let stale = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Stale-action panel missing")
    }
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "?", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    click(stale, "document.diskSaveAs")
    precondition(
      errors == 1 && chooserCalls == 0, "Stale Save As must refuse before destination selection")
    precondition(!FileManager.default.fileExists(atPath: destination.path))
    guard let save = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Save As panel missing")
    }
    let saveText = document.storage.string
    controller.monitorHarnessDisplay(scratch)
    click(save, "document.diskSaveAs")
    try await until { !document.saving && document.url == destination }
    precondition(chooserCalls == 1 && errors == 1)
    precondition(
      controller.monitorHarnessCurrent === scratch,
      "Save As must not redirect focus to its captured tab")
    precondition(scratch.url == nil && scratch.storage.length == 0)
    let savedCopy = try Data(contentsOf: destination)
    let originalOnDisk = try Data(contentsOf: url)
    precondition(savedCopy == Data(saveText.utf8))
    precondition(
      originalOnDisk == external, "Save As cannot overwrite the externally changed source")
    precondition(document.undoManager.canUndo && !document.dirty)
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: controller.window))
    precondition(controller.window?.isVisible == false)
    print(
      "Native disk actions passed: controller render, Check, Keep Buffer, stale Save As refusal, captured-target Save As"
    )
  }
  @MainActor static func clickHiddenAction(_ panel: DocumentDiskConflictController, _ id: String) {
    precondition(panel.window?.isVisible == false)
    let buttons = descendants(panel.window!.contentView!).compactMap { $0 as? NSButton }
      .filter { $0.accessibilityIdentifier() == id }
    precondition(buttons.count == 1 && buttons[0].isEnabled, "Missing admitted action: \(id)")
    buttons[0].performClick(nil)
    precondition(panel.window?.isVisible == false)
  }

  @MainActor static func checkChanged(_ bridge: DocumentFileStateController) async throws {
    let previous = bridge.state.token
    bridge.checkAgain()
    try await until {
      bridge.state.token != previous
        && bridge.state.token == bridge.monitorHarnessReceipt?.currentToken
        && bridge.state.observation?.content == .differsFromBaseline
    }
  }

  @MainActor static func reloadCopyActions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let url = directory.appendingPathComponent("reload.txt")
    let baseline = Data("baseline".utf8)
    try baseline.write(to: url)
    var errors = 0
    var confirmations = 0
    var confirmMode = "cancel"
    let controller = EditorWindowController(
      restoreStartup: false,
      onError: { _ in errors += 1 }, onSessionChange: {})
    let owner = ApplicationFileMonitoring()
    defer { owner.stop() }
    controller.configureFileMonitoring(owner)
    owner.onStateChange = { [weak controller] in controller?.reconcileFileMonitoring() }
    controller.newDocument()
    let unrelated = controller.monitorHarnessCurrent!
    var opened = false
    controller.open(
      url, onFailure: { fatalError("Synthetic open failed: \($0)") }, onOpened: { opened = true })
    try await until { opened }
    let document = controller.monitorHarnessCurrent!
    let bridge = controller.monitorHarnessCurrent!.fileState!
    try await until { bridge.state.observation?.content == .matchesBaseline }
    controller.confirmDiskReload = { target in
      precondition(target === document, "Confirmation must target captured document")
      confirmations += 1
      if confirmMode == "change" {
        do { try Data("changed during confirmation".utf8).write(to: url, options: .atomic) } catch {
          fatalError("Synthetic confirmation mutation failed: \(error)")
        }
        return true
      }
      if confirmMode == "close" {
        controller.windowWillClose(
          Notification(name: NSWindow.willCloseNotification, object: controller.window))
        return true
      }
      return confirmMode == "accept"
    }
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    let local = document.storage.string
    let revision = document.baselineRevision
    let diskText = "Disk 😀\r\nsecond"
    let diskBytes = try DocumentCodec.encode(
      DecodedDocument(text: diskText, encoding: .utf16BE, hasBOM: true))
    try diskBytes.write(to: url, options: .atomic)
    try await checkChanged(bridge)
    guard let copy = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Copy panel missing")
    }
    let oldIDs = Set(controller.monitorHarnessDocuments.map(\.id))
    controller.monitorHarnessDisplay(unrelated)
    clickHiddenAction(copy, "document.diskCopy")
    try await until {
      controller.monitorHarnessDocuments.contains { !oldIDs.contains($0.id) } && !document.saving
    }
    let copies = controller.monitorHarnessDocuments.filter { !oldIDs.contains($0.id) }
    precondition(copies.count == 1)
    let copied = copies[0]
    precondition(
      copied.url == nil && copied.storage.string == diskText && copied.encoding == .utf16BE
        && copied.hasBOM)
    precondition(copied.fileState == nil)
    precondition(
      controller.monitorHarnessCurrent === unrelated,
      "Copy cannot steal unrelated current tab focus")
    precondition(document.storage.string == local && document.dirty && document.undoManager.canUndo)
    precondition(
      document.originalBytes == baseline && document.baselineRevision == revision
        && document.url == url)
    precondition(confirmations == 0 && errors == 0)
    controller.monitorHarnessDisplay(document)
    document.undoManager.undo()
    precondition(!document.dirty && document.undoManager.canRedo)
    try controller.splitCurrent(.sideBySide)
    let panes = document.panePool.filter(\.isAttached)
    let paneIDs = panes.map(\.id)
    panes[0].editor.setSelectedRange(NSRange(location: 1, length: 0))
    panes[1].editor.setSelectedRange(NSRange(location: 4, length: 0))
    guard let reload = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Reload panel missing")
    }
    controller.monitorHarnessDisplay(unrelated)
    clickHiddenAction(reload, "document.diskReload")
    try await until { document.baselineRevision > revision && !document.saving }
    precondition(document.storage.string == diskText && document.originalBytes == diskBytes)
    precondition(
      document.encoding == .utf16BE && document.savedEncoding == .utf16BE && document.hasBOM
        && document.savedHasBOM)
    precondition(!document.dirty && !document.undoManager.canUndo && !document.undoManager.canRedo)
    precondition(document.panePool.filter(\.isAttached).map(\.id) == paneIDs)
    precondition(panes[0].editor.selectedRange() == NSRange(location: 1, length: 0))
    precondition(panes[1].editor.selectedRange() == NSRange(location: 4, length: 0))
    precondition(
      controller.monitorHarnessCurrent === unrelated && confirmations == 0 && errors == 0)
    // Each native view must start fresh undo grouping after whole-document reload.
    for (index, pane) in panes.enumerated() {
      controller.monitorHarnessDisplay(document)
      document.undoManager.beginUndoGrouping()
      pane.editor.insertText(
        String(index), replacementRange: NSRange(location: document.storage.length, length: 0))
      document.undoManager.endUndoGrouping()
      let typed = diskText + String(index)
      precondition(document.storage.string == typed && document.undoManager.canUndo)
      document.undoManager.undo()
      precondition(document.storage.string == diskText && document.undoManager.canRedo)
      document.undoManager.redo()
      precondition(document.storage.string == typed)
      document.undoManager.undo()
      precondition(document.storage.string == diskText && !document.dirty)
    }

    controller.monitorHarnessDisplay(document)
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    let dirtyText = document.storage.string
    let dirtyRevision = document.baselineRevision
    try DocumentCodec.encode(DecodedDocument(text: "new disk", encoding: .utf16BE, hasBOM: true))
      .write(to: url, options: .atomic)
    try await checkChanged(bridge)
    guard let cancel = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Cancel reload panel missing")
    }
    clickHiddenAction(cancel, "document.diskReload")
    try await until { confirmations == 1 && !document.saving }
    precondition(
      errors == 0 && document.storage.string == dirtyText && document.dirty
        && document.undoManager.canUndo)
    precondition(document.originalBytes == diskBytes && document.baselineRevision == dirtyRevision)
    // Keep valid UTF16 fixtures so this tests confirmation, not decoder refusal.
    let newerBytes = try DocumentCodec.encode(
      DecodedDocument(text: "newer disk", encoding: .utf16BE, hasBOM: true))
    try newerBytes.write(to: url, options: .atomic)
    try await checkChanged(bridge)
    confirmMode = "change"
    guard let change = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Revalidation panel missing")
    }
    clickHiddenAction(change, "document.diskReload")
    try await until { confirmations == 2 && !document.saving && errors == 1 }
    precondition(
      document.storage.string == dirtyText && document.originalBytes == diskBytes
        && document.baselineRevision == dirtyRevision)
    precondition(document.dirty && document.undoManager.canUndo)
    // Fresh stable observation before capturing a stale panel.
    try newerBytes.write(to: url, options: .atomic)
    try await checkChanged(bridge)
    guard let stale = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Stale reload panel missing")
    }
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "?", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    clickHiddenAction(stale, "document.diskReload")
    precondition(errors == 2 && confirmations == 2 && !document.saving)
    confirmMode = "close"
    guard let close = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Close reload panel missing")
    }
    let beforeClose = document.storage.string
    clickHiddenAction(close, "document.diskReload")
    try await until { confirmations == 3 && !document.saving }
    precondition(
      document.storage.string == beforeClose && document.originalBytes == diskBytes
        && document.baselineRevision == dirtyRevision)
    precondition(
      document.dirty && document.undoManager.canUndo && document.operationID == nil && errors == 2)
    precondition(controller.window?.isVisible == false)
    print(
      "Native reload/copy actions passed: captured target, scratch copy, exact BOM reload, all-pane state, cancel, disk-change refusal, stale panel, late close"
    )
  }
  @MainActor static func uncertainReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let url = directory.appendingPathComponent("uncertain.txt")
    let original = Data("original".utf8)
    try original.write(to: url)
    var errors = 0
    var confirmations = 0
    var changeDuringConfirmation = false
    let controller = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(write: { bytes, url, expected in
        try AtomicFileStore().save(bytes, to: url, expected: expected, fault: .directorySync)
      }), onError: { _ in errors += 1 }, onSessionChange: {})
    let owner = ApplicationFileMonitoring()
    defer { owner.stop() }
    controller.configureFileMonitoring(owner)
    owner.onStateChange = { [weak controller] in controller?.reconcileFileMonitoring() }
    controller.newDocument()
    var opened = false
    controller.open(
      url, onFailure: { fatalError("Synthetic open failed: \($0)") }, onOpened: { opened = true })
    try await until { opened }
    let document = controller.monitorHarnessCurrent!
    let bridge = controller.monitorHarnessCurrent!.fileState!
    try await until { bridge.state.observation?.content == .matchesBaseline }
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    controller.monitorHarnessSave(document)
    try await until { !document.saving && document.pendingPublication != nil }
    let pending = document.pendingPublication!
    let text = document.storage.string
    let revision = document.baselineRevision
    let published = try Data(contentsOf: url)
    precondition(
      published == pending.bytes && document.originalBytes == original,
      "Real directory-sync failure must retain published bytes and old acknowledged baseline")
    let warning = EditorWindowController.diskReloadConfirmationText(document).lowercased()
    precondition(
      warning.contains("may already") && warning.contains("disk") && warning.contains("retry")
        && warning.contains("discard"),
      "Uncertain reload warning must explain possible prior disk publication and discard of retained retry state: \(warning)"
    )
    controller.confirmDiskReload = { target in
      confirmations += 1
      precondition(
        target === document && target.pendingPublication?.id == pending.id,
        "Confirmation must see original retained publication evidence")
      if changeDuringConfirmation {
        do {
          try Data("changed during uncertain confirmation".utf8).write(to: url, options: .atomic)
        } catch { fatalError("Synthetic mutation failed: \(error)") }
      }
      return changeDuringConfirmation
    }
    try await checkChanged(bridge)
    guard let cancel = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Uncertain reload panel missing")
    }
    clickHiddenAction(cancel, "document.diskReload")
    try await until { confirmations == 1 && !document.saving }
    precondition(
      document.pendingPublication?.id == pending.id
        && document.pendingPublication?.bytes == pending.bytes)
    precondition(
      document.originalBytes == original && document.baselineRevision == revision
        && document.storage.string == text)
    precondition(document.dirty && document.undoManager.canUndo)
    changeDuringConfirmation = true
    try await checkChanged(bridge)
    let errorsBefore = errors
    guard let changed = controller.monitorHarnessDiskConflict(document) else {
      fatalError("Uncertain retry panel missing")
    }
    clickHiddenAction(changed, "document.diskReload")
    try await until { confirmations == 2 && !document.saving && errors > errorsBefore }
    precondition(
      document.pendingPublication?.id == pending.id
        && document.pendingPublication?.bytes == pending.bytes)
    precondition(
      document.originalBytes == original && document.baselineRevision == revision
        && document.storage.string == text)
    precondition(document.dirty && document.undoManager.canUndo)
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: controller.window))
    precondition(controller.window?.isVisible == false)
    print(
      "Native uncertain reload passed: explicit publication warning, Cancel and changed-file refusal preserve retry identity"
    )
  }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    if let scenario = ProcessInfo.processInfo.environment["THEONLYPAD_MONITOR_LIFECYCLE_CASE"],
      ["suspended-open", "suspended-save"].contains(scenario)
    {
      try await suspendedAdoption(scenario)
      return
    }
    try await suspendedAdoption("suspended-open")
    try await suspendedAdoption("suspended-save")
    try await conflictActions()
    try await reloadCopyActions()
    try await uncertainReload()
    try await NativeMonitorLocateScenarios.run()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("state").path, 1)
    let url = directory.appendingPathComponent("document.txt")
    let bytes = Data("saved text".utf8)
    try bytes.write(to: url)
    let owner = ApplicationFileMonitoring()
    defer { owner.stop() }
    var sessionChanges = 0
    let controller = EditorWindowController(
      restoreStartup: false, onSessionChange: { sessionChanges += 1 })
    controller.configureFileMonitoring(owner)
    guard let content = controller.window?.contentView else {
      fatalError("Hidden window content missing")
    }
    let rows = descendants(content).compactMap { $0 as? DocumentDiskStatusView }
    precondition(rows.count == 1, "Configured editor must contain one real disk-status row")
    let diskStatus = rows[0]
    precondition(diskStatus.accessibilityIdentifier() == "document.diskStatus")
    owner.onStateChange = { [weak controller] in controller?.reconcileFileMonitoring() }
    controller.newDocument()
    precondition(controller.monitorHarnessDocuments.count == 1)
    let scratch = controller.monitorHarnessDocuments[0]
    precondition(scratch.fileState == nil, "Scratch must not register a file")
    var opened = false
    controller.open(
      url, onFailure: { fatalError("Synthetic open failed: \($0)") }, onOpened: { opened = true })
    try await until { opened }
    guard let document = controller.monitorHarnessCurrent else {
      fatalError("Loaded current document missing")
    }
    precondition(document.url == url && document.originalBytes == bytes)
    guard let bridge = document.fileState else {
      fatalError("Loaded file must own its monitoring bridge")
    }
    try await until { bridge.state.observation?.content == .matchesBaseline }
    guard let initial = bridge.monitorHarnessReceipt else {
      fatalError("Loaded file must register exactly one live handle")
    }
    precondition(!initial.cancelled && initial.documentID == document.id)
    precondition(initial.baselineRevision == document.baselineRevision)
    // Hidden native split; no window activation or visibility claim.
    try controller.splitCurrent(.sideBySide)
    precondition(document.panePool.filter(\.isAttached).count == 2)
    controller.monitorHarnessDisplay(scratch)
    controller.monitorHarnessDisplay(document)
    controller.reconcileFileMonitoring()
    precondition(document.fileState === bridge)
    precondition(
      bridge.monitorHarnessReceipt?.epoch == initial.epoch,
      "Split and tab focus must retain the same document registration")
    let beforeSave = document.baselineRevision
    controller.monitorHarnessSave(document)
    try await until { !document.saving && document.baselineRevision > beforeSave }
    try await until { bridge.state.observation?.content == .matchesBaseline }
    precondition(document.originalBytes == bytes && !document.dirty)
    precondition(bridge.monitorHarnessReceipt!.epoch > initial.epoch)
    precondition(bridge.monitorHarnessReceipt!.baselineRevision == document.baselineRevision)
    // Local undo survives external-change presentation.
    document.undoManager.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: NSRange(location: document.storage.length, length: 0))
    document.undoManager.endUndoGrouping()
    precondition(document.dirty && document.undoManager.canUndo)
    let edited = document.storage.string
    try Data("external!!".utf8).write(to: url, options: .atomic)
    bridge.checkAgain()
    try await until { bridge.state.observation?.content == .differsFromBaseline }
    precondition(!diskStatus.isHidden, "External change must make the actual status row visible")
    precondition(
      diskStatus.accessibilityLabel()?.contains("changed on disk") == true,
      "Actual row must expose the changed-file reason to accessibility")
    let beforeStatusRender = sessionChanges
    diskStatus.render(
      state: bridge.state, manualNotice: bridge.manualNotice, failure: bridge.lastFailure,
      hasSource: true, enabled: true)
    precondition(
      sessionChanges == beforeStatusRender,
      "Status presentation must not enqueue session checkpoints")
    precondition(document.storage.string.utf16.elementsEqual(edited.utf16))
    precondition(document.dirty && document.undoManager.canUndo && document.originalBytes == bytes)
    document.undoManager.undo()
    precondition(document.storage.string.utf16.elementsEqual("saved text".utf16) && !document.dirty)
    let priorGeneration = owner.deliveryGeneration
    owner.suspend()
    precondition(owner.isSuspended && owner.deliveryGeneration != priorGeneration)
    let prepared = await controller.prepareToQuit(persistRecovery: false)
    precondition(prepared)
    controller.cancelPreparedQuit()
    owner.resume()
    precondition(!owner.isSuspended && owner.deliveryGeneration != priorGeneration)
    bridge.checkAgain()
    try await until { bridge.state.observation?.content == .differsFromBaseline }
    // Clean retained tab closes without a confirmation dialog despite external change.
    controller.monitorHarnessClose(document)
    precondition(
      bridge.monitorHarnessInvalidated, "Closed retained documents must cancel their bridge")
    precondition(!controller.monitorHarnessDocuments.contains { $0 === document })
    controller.monitorHarnessReopen()
    guard let reopened = controller.monitorHarnessCurrent else {
      fatalError("Reopened tab missing")
    }
    precondition(reopened.id != document.id && reopened.fileState !== bridge)
    guard let reopenedBridge = reopened.fileState else {
      fatalError("Reopened file needs a fresh bridge")
    }
    try await until { reopenedBridge.state.observation != nil }
    precondition(reopenedBridge.monitorHarnessReceipt?.documentID == reopened.id)
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: controller.window))
    precondition(reopenedBridge.monitorHarnessInvalidated)
    try Data("late bytes".utf8).write(to: url, options: .atomic)
    reopenedBridge.checkAgain()
    try await Task.sleep(nanoseconds: 50_000_000)
    precondition(reopenedBridge.monitorHarnessInvalidated)
    precondition(controller.window?.isVisible == false, "Harness must not show its hidden window")
    print(
      "Native monitor lifecycle passed: registration, scratch, split/tab identity, save rebind, conflict preservation, undo, suspend/veto, retained close/reopen, late close"
    )
  }
}
