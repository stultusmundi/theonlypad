import AppKit
import Foundation
import XCTest

@testable import PadCore
@testable import ShortcutApplication

@MainActor final class ShortcutApplicationTests: XCTestCase {
  func setupOwner() async throws -> (ApplicationShortcuts, ShortcutStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ShortcutApplication-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = ShortcutStore(directory: directory)
    let owner = ApplicationShortcuts(
      services: ShortcutServices(store: store), catalog: try AppCommands.registry().commands)
    try await owner.load()
    return (owner, store)
  }
  func draft() throws -> ShortcutProfile {
    try ShortcutProfile(records: [
      ShortcutOverride(
        commandID: "file.new", assignment: .assigned(KeyboardShortcut(canonicalString: "alt+cmd+n"))
      )
    ])
  }
  func testSuccessfulApplyReturnsInteractiveCurrentSnapshot() async throws {
    let (owner, store) = try await setupOwner()
    let controller = ApplicationShortcutController(
      owner: owner, isPreparingQuit: { false }, publish: { _ in })
    let snapshot = controller.snapshot()
    let updated = try await controller.apply(
      draft(), catalog: snapshot.catalogRevision, revision: snapshot.profileRevision)
    XCTAssertTrue(updated.canApply, "An idle completed Apply must return an interactive snapshot")
    XCTAssertEqual(updated.profile, try draft())
    XCTAssertEqual(try store.read().decoded.get(), try draft())
    XCTAssertTrue(controller.canQuit)
  }
  func testRepairCancelPreservesMalformedBytes() async throws {
    let (owner, store) = try await setupOwner()
    let file = store.directory.appendingPathComponent("Shortcuts.json")
    let raw = Data("{\"version\":999}".utf8)
    try raw.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try await owner.reload()
    var dialogs = ShortcutDialogs()
    dialogs.confirmRepair = { false }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, isPreparingQuit: { false }, publish: { _ in })
    let snapshot = controller.snapshot()
    do {
      _ = try await controller.apply(
        draft(), catalog: snapshot.catalogRevision, revision: snapshot.profileRevision)
      XCTFail("cancel")
    } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: file), raw)
    XCTAssertTrue(controller.needsAttention)
  }
  func testRepairDialogCatalogChangeRefusesWrite() async throws {
    let (owner, store) = try await setupOwner()
    let file = store.directory.appendingPathComponent("Shortcuts.json")
    let raw = Data("bad".utf8)
    try raw.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try await owner.reload()
    var dialogs = ShortcutDialogs()
    dialogs.confirmRepair = {
      owner.updateCatalog(owner.state.catalog)
      return true
    }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, isPreparingQuit: { false }, publish: { _ in })
    let snapshot = controller.snapshot()
    do {
      _ = try await controller.apply(
        draft(), catalog: snapshot.catalogRevision, revision: snapshot.profileRevision)
      XCTFail("stale dialog")
    } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: file), raw)
  }
  func testImportCancelAndChooserQuitDoNotRead() async throws {
    let (owner, _) = try await setupOwner()
    var quit = false
    var dialogs = ShortcutDialogs()
    dialogs.chooseImport = {
      quit = true
      return URL(fileURLWithPath: "/synthetic/not-read")
    }
    var transfer = ShortcutTransferServices()
    transfer.read = { _ in
      XCTFail("stale chooser read")
      return .defaults
    }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, transfer: transfer, isPreparingQuit: { quit },
      publish: { _ in })
    do {
      _ = try await controller.importProfile(window: controller.testWindowGeneration)
      XCTFail("quit admission")
    } catch is CancellationError {}
    XCTAssertTrue(controller.canQuit)
  }
  func testUncertainExportPreservesErrorAndOffersNoSuccess() async throws {
    let (owner, store) = try await setupOwner()
    let output = store.directory.appendingPathComponent("export.json")
    var dialogs = ShortcutDialogs()
    dialogs.chooseExport = { output }
    var hooks = ShortcutTransferHooks()
    hooks.fault = .directorySync
    let exporter = ShortcutTransfer(hooks: hooks)
    var transfer = ShortcutTransferServices()
    transfer.write = { try exporter.export($0, to: $1) }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, transfer: transfer, isPreparingQuit: { false },
      publish: { _ in })
    let editor = try XCTUnwrap(controller.prepareEditor())
    defer { editor.close() }
    do {
      _ = try await controller.exportProfile(draft(), window: controller.testWindowGeneration)
      XCTFail("uncertain export success")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("could not be confirmed"))
      XCTAssertNotNil((error as NSError).userInfo[NSUnderlyingErrorKey])
    }
    XCTAssertNotNil(controller.lastTransferError)
    XCTAssertTrue(controller.needsAttention)
    XCTAssertNil(
      controller.snapshot().recoveryTitle,
      "Export failure must not offer unrelated stored-profile recovery")
    editor.close()
    XCTAssertNotNil(
      controller.lastTransferError, "Closing the editor preserves actionable export uncertainty")
    XCTAssertEqual(try ShortcutProfile.decode(Data(contentsOf: output)), try draft())
    XCTAssertEqual(owner.state.profile, .defaults)
  }
  func testExplicitRestoreDefaultsRecoversUnreadableSettings() async throws {
    let (owner, store) = try await setupOwner()
    let file = store.directory.appendingPathComponent("Shortcuts.json")
    try Data("bad".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try await owner.reload()
    var dialogs = ShortcutDialogs()
    dialogs.chooseRecovery = { pending, invalid in
      XCTAssertFalse(pending)
      XCTAssertTrue(invalid)
      return .restoreDefaults
    }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, isPreparingQuit: { false }, publish: { _ in })
    let updated = try await controller.recover()
    XCTAssertTrue(updated.canApply)
    XCTAssertFalse(controller.needsAttention)
    XCTAssertEqual(try store.read().decoded.get(), .defaults)
  }
  func testActualMenusWithdrawEquivalentsDuringCatalogReconciliation() async throws {
    _ = NSApplication.shared
    let (owner, _) = try await setupOwner()
    let delegate = AppDelegate()
    try delegate.installShortcutsForTesting(owner)
    func items(_ menu: NSMenu) -> [NSMenuItem] {
      menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
    XCTAssertTrue(delegate.shortcutReadyForTesting)
    let before = try XCTUnwrap(NSApp.mainMenu)
    let newTab = try XCTUnwrap(
      items(before).first { $0.representedObject as? String == "file.new" })
    XCTAssertEqual(newTab.keyEquivalent, "n")
    owner.updateCatalog(owner.state.catalog)
    XCTAssertFalse(delegate.shortcutReadyForTesting)
    let withdrawn = try XCTUnwrap(NSApp.mainMenu)
    XCTAssertTrue(
      items(withdrawn).filter { $0.representedObject is String }.allSatisfy {
        $0.keyEquivalent.isEmpty
      })
    let quit = try XCTUnwrap(
      items(withdrawn).first { $0.action == #selector(NSApplication.terminate(_:)) })
    XCTAssertEqual(
      quit.keyEquivalent, "q", "Native Quit remains available independently of registry repair")
    for item in items(withdrawn) {
      if let id = item.representedObject as? String {
        XCTAssertEqual(delegate.validateMenuItem(item), id == "app.shortcuts")
      }
    }
    let deadline = Date().addingTimeInterval(5)
    while owner.state.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(delegate.shortcutReadyForTesting)
    try await owner.apply(draft())
    let updated = try XCTUnwrap(NSApp.mainMenu)
    let changed = try XCTUnwrap(
      items(updated).first { $0.representedObject as? String == "file.new" })
    XCTAssertEqual(changed.keyEquivalent, "n")
    XCTAssertEqual(changed.keyEquivalentModifierMask, [.option, .command])
    XCTAssertEqual(
      delegate.shortcutRegistryForTesting.commands, owner.state.composition?.registry.commands)
  }

  func testActualImportButtonKeepsDraftAcrossOwnerAncillaryUpdates() async throws {
    _ = NSApplication.shared
    let (owner, store) = try await setupOwner()
    let input = store.directory.appendingPathComponent("import.json")
    let imported = try draft()
    try imported.encode().write(to: input)
    var dialogs = ShortcutDialogs()
    dialogs.chooseImport = { input }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, isPreparingQuit: { false }, publish: { _ in })
    let editor = try XCTUnwrap(controller.prepareEditor())
    defer { editor.close() }
    func find(_ view: NSView, _ id: String) -> NSButton? {
      if let button = view as? NSButton, button.accessibilityIdentifier() == id { return button }
      for child in view.subviews { if let result = find(child, id) { return result } }
      return nil
    }
    let content = try XCTUnwrap(editor.window?.contentView)
    let button = try XCTUnwrap(find(content, "shortcuts.import"))
    XCTAssertTrue(button.isEnabled)
    button.performClick(nil)
    let deadline = Date().addingTimeInterval(5)
    while editor.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(editor.draft, imported)
    XCTAssertEqual(owner.state.profile, .defaults, "Import is draft-only until Apply")
    let apply = try XCTUnwrap(find(content, "shortcuts.apply"))
    XCTAssertTrue(apply.isEnabled)
    apply.performClick(nil)
    while editor.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(owner.state.profile, imported)
    XCTAssertEqual(try store.read().decoded.get(), imported)
    XCTAssertEqual(editor.draft, imported)
    XCTAssertFalse(
      apply.isEnabled, "Matching successful Apply becomes the baseline, not a stale dirty draft")
  }

  func testPreferencesShortcutAttentionLinkFitsSeparateRow() async throws {
    _ = NSApplication.shared
    let (_, store) = try await setupOwner()
    let preferences = PreferencesController(
      store: SettingsStore(directory: store.directory), onApply: { _ in })
    defer { preferences.close() }
    preferences.updateShortcutAttention(true)
    let content = try XCTUnwrap(preferences.window?.contentView)
    content.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.accessibilityIdentifier() == "preferences.shortcuts"
      {
        return button
      }
      for child in view.subviews { if let result = find(child) { return result } }
      return nil
    }
    let button = try XCTUnwrap(find(content))
    let parent = try XCTUnwrap(button.superview)
    XCTAssertFalse(
      parent.subviews.contains { ($0 as? NSButton)?.title == "Import…" },
      "Shortcut link gets its own row instead of widening import/export footer")
    XCTAssertGreaterThanOrEqual(button.frame.width + 1, button.fittingSize.width)
    XCTAssertTrue(
      content.bounds.insetBy(dx: -1, dy: -1).contains(button.convert(button.bounds, to: content)))
  }

  func testPendingRecoveryOffersExplicitVerifyAndDiscardChoices() async throws {
    for verify in [true, false] {
      let (_, store) = try await setupOwner()
      var hooks = ShortcutStoreHooks()
      hooks.fault = .directorySync
      let faulty = ShortcutStore(directory: store.directory, hooks: hooks)
      let calls = ShortcutWriteCount()
      var services = ShortcutServices(store: store)
      services.write = { profile, receipt in
        if calls.next() == 1 { return try faulty.write(profile, matching: receipt) }
        return try store.write(profile, matching: receipt)
      }
      let owner = ApplicationShortcuts(
        services: services, catalog: try AppCommands.registry().commands)
      try await owner.load()
      do {
        try await owner.apply(draft())
        XCTFail("expected uncertainty")
      } catch {}
      var dialogs = ShortcutDialogs()
      dialogs.chooseRecovery = { pending, invalid in
        XCTAssertTrue(pending)
        XCTAssertFalse(invalid)
        return verify ? .verifyAndRetry : .reloadDiscard
      }
      let controller = ApplicationShortcutController(
        owner: owner, dialogs: dialogs, isPreparingQuit: { false }, publish: { _ in })
      XCTAssertFalse(controller.canQuit)
      XCTAssertNotNil(controller.snapshot().recoveryTitle)
      _ = try await controller.recover()
      XCTAssertTrue(controller.canQuit)
      XCTAssertFalse(owner.state.hasPendingPublication)
      XCTAssertEqual(owner.state.profile, try draft())
      XCTAssertEqual(calls.value, verify ? 2 : 1)
    }
  }

  func testClosingEditorDuringImportChooserRefusesReadAdmission() async throws {
    _ = NSApplication.shared
    let (owner, _) = try await setupOwner()
    var editor: KeyboardShortcutController?
    var dialogs = ShortcutDialogs()
    dialogs.chooseImport = {
      editor?.close()
      return URL(fileURLWithPath: "/synthetic/not-read")
    }
    var transfer = ShortcutTransferServices()
    transfer.read = { _ in
      XCTFail("Closing the chooser owner must refuse a new read")
      return .defaults
    }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, transfer: transfer, isPreparingQuit: { false },
      publish: { _ in })
    editor = try XCTUnwrap(controller.prepareEditor())
    let generation = controller.testWindowGeneration
    do {
      _ = try await controller.importProfile(window: generation)
      XCTFail("closed import")
    } catch is CancellationError {}
  }

  func testMalformedImportHasActionableErrorAndPreservesRuntime() async throws {
    let (owner, store) = try await setupOwner()
    let file = store.directory.appendingPathComponent("invalid-import.json")
    try Data("not a shortcut profile".utf8).write(to: file)
    var dialogs = ShortcutDialogs()
    dialogs.chooseImport = { file }
    let controller = ApplicationShortcutController(
      owner: owner, dialogs: dialogs, isPreparingQuit: { false }, publish: { _ in })
    do {
      _ = try await controller.importProfile(window: controller.testWindowGeneration)
      XCTFail("malformed import")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("could not be imported"))
      XCTAssertNotNil((error as NSError).userInfo[NSUnderlyingErrorKey])
    }
    XCTAssertEqual(owner.state.profile, .defaults)
    XCTAssertNil(try store.read().receipt.rawBytes)
  }

}

private final class ShortcutWriteCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
