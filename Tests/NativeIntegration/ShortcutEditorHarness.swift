import AppKit
import PadCore

@MainActor final class ShortcutEditorGate {
  var continuation: CheckedContinuation<Void, Never>?
  var entered = false
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
@main struct ShortcutEditorHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var failures = 0
    func check(_ value: Bool, _ label: String) {
      print("\(value ? "PASS":"FAIL") \(label)")
      if !value { failures += 1 }
    }
    let catalog = [
      CommandDescriptor(id: "a", title: "Alpha", shortcut: "cmd+1"),
      CommandDescriptor(id: "b", title: "Beta", shortcut: "cmd+2"),
      CommandDescriptor(id: "edit.copy", title: "Copy", shortcut: "cmd+c"),
    ]
    let snapshot = ShortcutEditorSnapshot(
      catalog: catalog, profile: .defaults, catalogRevision: UUID(), profileRevision: UUID())
    var applied = 0
    let actions = ShortcutEditorActions(apply: { profile, cat, rev in
      applied += 1
      return ShortcutEditorSnapshot(
        catalog: catalog, profile: profile, catalogRevision: cat, profileRevision: UUID())
    })
    let c = KeyboardShortcutController(snapshot: snapshot, actions: actions)
    check(
      (c.window?.initialFirstResponder as? NSView)?.accessibilityIdentifier() == "shortcuts.search",
      "shortcut window declares command search as initial keyboard focus")
    c.setAssignment(.disabled, for: "a")
    check(c.draft.records.first?.assignment == .disabled, "disable changes draft only")
    c.cancelDraft(nil)
    for _ in 0..<10 { await Task.yield() }
    check(applied == 0, "Cancel never applies")
    let d = KeyboardShortcutController(snapshot: snapshot, actions: actions)
    d.setAssignment(.disabled, for: "a")
    d.applyDraft(nil)
    d.applyDraft(nil)
    for _ in 0..<20 { await Task.yield() }
    check(applied == 1, "Apply exactly once")
    d.cancelDraft(nil)
    let editor = KeyboardShortcutController(snapshot: snapshot, actions: actions)
    check(editor.fixtureRecorderHidden, "recorder cannot self-start outside selected Record action")
    editor.fixtureSelect("a")
    check(editor.fixtureSelected == "a", "actual table selection remains stable through rendering")
    editor.fixtureClick("disable")
    check(
      editor.draft.records.first?.assignment == .disabled,
      "actual Disable button edits selected row")
    editor.fixtureClick("inherit")
    check(editor.draft.records.isEmpty, "Use Default removes override")
    editor.fixtureSelect("edit.copy")
    check(
      !editor.fixtureEnabled("record") && !editor.fixtureEnabled("disable")
        && !editor.fixtureEnabled("inherit"), "protected row controls disabled")
    editor.setAssignment(.disabled, for: "edit.copy")
    check(editor.draft.records.isEmpty, "protected mutation refused")
    editor.fixtureSearch("Alpha")
    check(editor.fixtureRows == ["a"], "search filters human command titles")
    editor.fixtureSearch("")
    editor.setAssignment(.assigned(try KeyboardShortcut(canonicalString: "cmd+2")), for: "a")
    check(
      editor.fixtureStatus.contains("Alpha") && editor.fixtureStatus.contains("Beta")
        && !editor.fixtureEnabled("apply"), "collision names both human titles and blocks Apply")
    editor.setAssignment(.assigned(try KeyboardShortcut(canonicalString: "cmd+1")), for: "b")
    check(editor.fixtureEnabled("apply"), "batch swap validates atomically")
    editor.cancelDraft(nil)
    let unknown = try ShortcutProfile(records: [
      ShortcutOverride(
        commandID: "extension.missing.command",
        assignment: .assigned(try KeyboardShortcut(canonicalString: "cmd+9")))
    ])
    var unknownSnapshot = snapshot
    unknownSnapshot = ShortcutEditorSnapshot(
      catalog: catalog, profile: unknown, catalogRevision: UUID(), profileRevision: UUID(),
      status: "Stored customizations are unavailable.", canApply: false)
    let u = KeyboardShortcutController(snapshot: unknownSnapshot, actions: actions)
    u.setAssignment(.disabled, for: "a")
    check(
      u.draft.records.contains { $0.commandID == "extension.missing.command" }
        && u.fixtureRows.contains("extension.missing.command"),
      "unavailable override retained and displayed")
    check(
      u.fixtureStatus.contains("Stored customizations are unavailable.")
        && !u.fixtureEnabled("apply"), "persistent owner error remains during draft editing")
    u.update(
      ShortcutEditorSnapshot(
        catalog: catalog, profile: .defaults, catalogRevision: UUID(), profileRevision: UUID()))
    check(
      u.draft.records.count == 2 && !u.fixtureEnabled("apply")
        && u.fixtureStatus.contains("changed elsewhere"),
      "external profile update preserves dirty draft and blocks Apply")
    u.fixtureClick("reload")
    check(u.draft.records.isEmpty, "explicit Reload Current adopts external profile")
    u.cancelDraft(nil)
    let gate = ShortcutEditorGate()
    var commits = 0
    var closes = 0
    let asyncActions = ShortcutEditorActions(apply: { profile, cat, rev in
      await gate.wait()
      commits += 1
      return ShortcutEditorSnapshot(
        catalog: catalog, profile: profile, catalogRevision: cat, profileRevision: UUID())
    })
    let busy = KeyboardShortcutController(snapshot: snapshot, actions: asyncActions)
    busy.onClose = { closes += 1 }
    busy.setAssignment(.disabled, for: "a")
    busy.applyDraft(nil)
    for _ in 0..<20 { await Task.yield() }
    check(gate.entered && busy.isBusy, "apply asynchronous work started")
    busy.update(snapshot)
    check(busy.isBusy && !busy.fixtureEnabled("apply"), "snapshot update cannot clear local busy")
    busy.setAssignment(.disabled, for: "b")
    check(busy.draft.records.count == 1, "busy mutation refused")
    busy.cancelDraft(nil)
    busy.cancelDraft(nil)
    gate.release()
    for _ in 0..<30 { await Task.yield() }
    check(
      commits == 1 && closes == 1,
      "close does not cancel authorized apply or duplicate close callback")
    check(
      busy.draft.records.count == 1 && !busy.fixtureStatus.contains("Shortcuts applied"),
      "late success does not update closed UI")
    var recoverCalls = 0
    var recoverySnapshot = snapshot
    recoverySnapshot.status = "Save durability is uncertain."
    recoverySnapshot.canApply = false
    recoverySnapshot.recoveryTitle = "Verify and Retry Save"
    var recoveryActions = actions
    recoveryActions.recover = {
      recoverCalls += 1
      return ShortcutEditorSnapshot(
        catalog: catalog, profile: .defaults, catalogRevision: UUID(), profileRevision: UUID())
    }
    let recovery = KeyboardShortcutController(snapshot: recoverySnapshot, actions: recoveryActions)
    recovery.setAssignment(.disabled, for: "a")
    check(recoverCalls == 0, "recovery is never automatic")
    check(recovery.fixtureMinimumLayout, "all actions fit minimum window width without clipping")
    recovery.fixtureClick("recovery")
    for _ in 0..<20 { await Task.yield() }
    check(
      recoverCalls == 1 && recovery.draft.records.count == 1 && !recovery.fixtureEnabled("apply"),
      "explicit recovery preserves dirty draft and requires reload on new profile")
    recovery.cancelDraft(nil)
    var exportSeen: ShortcutProfile?
    var ioActions = actions
    ioActions.importProfile = { unknown }
    ioActions.exportProfile = { profile in
      exportSeen = profile
      return true
    }
    let io = KeyboardShortcutController(snapshot: snapshot, actions: ioActions)
    io.fixtureClick("import")
    for _ in 0..<20 { await Task.yield() }
    check(io.draft == unknown && applied == 1, "Import changes only draft with unavailable record")
    io.fixtureClick("export")
    for _ in 0..<20 { await Task.yield() }
    check(
      exportSeen == unknown && io.draft == unknown,
      "Export receives complete draft without changing it")
    io.fixtureClick("reset")
    check(io.draft.records.isEmpty && applied == 1, "Restore Defaults remains draft only")
    io.cancelDraft(nil)
    let importGate = ShortcutEditorGate()
    var staleImportActions = actions
    staleImportActions.importProfile = {
      await importGate.wait()
      return unknown
    }
    let late = KeyboardShortcutController(snapshot: snapshot, actions: staleImportActions)
    late.fixtureClick("import")
    for _ in 0..<20 { await Task.yield() }
    late.update(
      ShortcutEditorSnapshot(
        catalog: catalog, profile: .defaults, catalogRevision: UUID(), profileRevision: UUID(),
        status: "Newer catalog"))
    importGate.release()
    for _ in 0..<20 { await Task.yield() }
    check(
      late.draft.records.isEmpty && late.fixtureStatus.contains("Newer catalog"),
      "late import cannot overwrite newer snapshot")
    late.cancelDraft(nil)
    var failingActions = actions
    failingActions.importProfile = { throw ShortcutError.invalidProfile }
    let failed = KeyboardShortcutController(snapshot: snapshot, actions: failingActions)
    failed.setAssignment(.disabled, for: "a")
    let prior = failed.draft
    failed.fixtureClick("import")
    for _ in 0..<20 { await Task.yield() }
    check(failed.draft == prior && !failed.isBusy, "failed import preserves draft and clears busy")
    failed.cancelDraft(nil)
    weak var notifying: KeyboardShortcutController?
    let notifyingActions = ShortcutEditorActions(apply: { profile, cat, rev in
      var beginning = snapshot
      beginning.canApply = false
      notifying?.update(beginning)
      let completed = ShortcutEditorSnapshot(
        catalog: catalog, profile: profile, catalogRevision: cat, profileRevision: UUID())
      notifying?.update(completed)
      return completed
    })
    let acknowledged = KeyboardShortcutController(snapshot: snapshot, actions: notifyingActions)
    notifying = acknowledged
    acknowledged.setAssignment(.disabled, for: "a")
    acknowledged.applyDraft(nil)
    for _ in 0..<30 { await Task.yield() }
    check(
      acknowledged.fixtureStatus.contains("Shortcut settings saved.")
        && !acknowledged.fixtureStatus.contains("changed elsewhere")
        && !acknowledged.fixtureEnabled("reload"),
      "owner begin and final notifications acknowledge own Apply")
    acknowledged.cancelDraft(nil)
    weak var exporting: KeyboardShortcutController?
    var notifyingExport = actions
    notifyingExport.exportProfile = { _ in
      var changed = snapshot
      changed = ShortcutEditorSnapshot(
        catalog: catalog, profile: .defaults, catalogRevision: UUID(),
        profileRevision: snapshot.profileRevision, status: "New catalog remains current")
      exporting?.update(changed)
      throw NSError(
        domain: "SyntheticShortcutExport", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "EXPORT UNCERTAINTY MUST REMAIN VISIBLE"])
    }
    let exportFailure = KeyboardShortcutController(snapshot: snapshot, actions: notifyingExport)
    exporting = exportFailure
    exportFailure.fixtureClick("export")
    for _ in 0..<30 { await Task.yield() }
    check(
      exportFailure.fixtureStatus.contains("EXPORT UNCERTAINTY MUST REMAIN VISIBLE")
        && exportFailure.fixtureStatus.contains("New catalog remains current"),
      "catalog updates cannot hide authorized export error")
    exportFailure.cancelDraft(nil)
    let manyCatalog = (0..<40).map {
      CommandDescriptor(id: "many.\($0)", title: "Long human command title number \($0)")
    }
    let manyRecords = try (0..<40).map {
      try ShortcutOverride(
        commandID: "many.\($0)",
        assignment: .assigned(
          KeyboardShortcut(canonicalString: "cmd+\(Array("1234567890abcdefghij")[$0/2])")))
    }
    let many = KeyboardShortcutController(
      snapshot: ShortcutEditorSnapshot(
        catalog: manyCatalog, profile: try ShortcutProfile(records: manyRecords),
        catalogRevision: UUID(), profileRevision: UUID(), status: "Persistent owner error"),
      actions: actions)
    check(many.fixtureColumnsReachable, "Assignment column remains reachable at declared minimum")
    check(many.fixtureDeclaredContentMinimum, "declared native minimum matches tested content size")
    check(many.fixtureMinimumHeightLayout, "many conflicts keep actions visible at minimum height")
    check(
      many.fixtureStatusEndReachable,
      "last conflict text remains reachable inside bounded status viewport")
    many.cancelDraft(nil)
    weak var newerEditor: KeyboardShortcutController?
    let newerActions = ShortcutEditorActions(apply: { profile, cat, rev in
      let own = ShortcutEditorSnapshot(
        catalog: catalog, profile: profile, catalogRevision: cat, profileRevision: UUID())
      newerEditor?.update(own)
      let external = try ShortcutProfile(records: [
        ShortcutOverride(commandID: "b", assignment: .disabled)
      ])
      newerEditor?.update(
        ShortcutEditorSnapshot(
          catalog: catalog, profile: external, catalogRevision: UUID(), profileRevision: UUID(),
          status: "GENUINELY NEWER OWNER STATE"))
      return own
    })
    let superseded = KeyboardShortcutController(snapshot: snapshot, actions: newerActions)
    newerEditor = superseded
    superseded.setAssignment(.disabled, for: "a")
    superseded.applyDraft(nil)
    for _ in 0..<30 { await Task.yield() }
    check(
      superseded.fixtureStatus.contains("GENUINELY NEWER OWNER STATE")
        && !superseded.fixtureStatus.contains("Shortcut settings saved.")
        && !superseded.fixtureEnabled("apply"),
      "older own receipt cannot overwrite newer profile or catalog")
    superseded.cancelDraft(nil)
    weak var flagsEditor: KeyboardShortcutController?
    let flagsActions = ShortcutEditorActions(apply: { profile, cat, rev in
      let own = ShortcutEditorSnapshot(
        catalog: catalog, profile: profile, catalogRevision: cat, profileRevision: UUID())
      flagsEditor?.update(own)
      var current = own
      current.canApply = false
      current.status = "NEW OWNER BUSY STATE"
      flagsEditor?.update(current)
      return own
    })
    let latestFlags = KeyboardShortcutController(snapshot: snapshot, actions: flagsActions)
    flagsEditor = latestFlags
    latestFlags.setAssignment(.disabled, for: "a")
    latestFlags.applyDraft(nil)
    for _ in 0..<30 { await Task.yield() }
    check(
      latestFlags.fixtureStatus.contains("NEW OWNER BUSY STATE")
        && latestFlags.fixtureStatus.contains("Shortcut settings saved."),
      "matching own receipt preserves newest owner status flags")
    latestFlags.cancelDraft(nil)
    weak var ordinaryImport: KeyboardShortcutController?
    var importNotifications = actions
    importNotifications.importProfile = {
      var beginning = snapshot
      beginning.canApply = false
      beginning.status = "Owner importing"
      ordinaryImport?.update(beginning)
      var completed = snapshot
      completed.status = "Owner import finished"
      ordinaryImport?.update(completed)
      return unknown
    }
    let importedNormally = KeyboardShortcutController(
      snapshot: snapshot, actions: importNotifications)
    ordinaryImport = importedNormally
    importedNormally.fixtureClick("import")
    for _ in 0..<30 { await Task.yield() }
    check(
      importedNormally.draft == unknown
        && importedNormally.fixtureStatus.contains("Owner import finished"),
      "ordinary import survives ancillary owner begin/end notifications")
    importedNormally.cancelDraft(nil)
    exit(failures == 0 ? 0 : 1)
  }
}
