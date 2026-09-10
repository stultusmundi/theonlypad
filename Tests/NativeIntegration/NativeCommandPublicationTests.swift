import AppKit
import XCTest

@testable import PadCore
@testable import ShortcutApplication

@MainActor final class NativeCommandPublicationTests: XCTestCase {
  private func owner() async throws -> ApplicationShortcuts {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CommandPublication-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let value = ApplicationShortcuts(
      services: ShortcutServices(store: ShortcutStore(directory: directory)),
      catalog: try AppCommands.registry().commands)
    try await value.load()
    return value
  }
  private func items(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
  }
  private func assertPublished(
    _ delegate: AppDelegate, file: StaticString = #filePath, line: UInt = #line
  )
    throws -> [String: PublishedCommandKey]
  {
    let menu = try XCTUnwrap(NSApp.mainMenu, file: file, line: line)
    let registryItems = items(menu).filter { $0.representedObject is String }
    let records = delegate.publishedCommandKeysForTesting
    XCTAssertEqual(
      Set(records.keys), Set(registryItems.compactMap { $0.representedObject as? String }),
      "All actual registry menu items must have authoritative snapshots", file: file, line: line)
    for item in registryItems {
      let id = try XCTUnwrap(item.representedObject as? String, file: file, line: line)
      let record = try XCTUnwrap(records[id], file: file, line: line)
      XCTAssertTrue(record.item === item, file: file, line: line)
      XCTAssertEqual(record.id, id, file: file, line: line)
      XCTAssertEqual(
        record.publication, delegate.commandKeyPublicationForTesting, file: file, line: line)
      XCTAssertEqual(record.configuredKey, item.keyEquivalent, file: file, line: line)
      XCTAssertEqual(record.configuredMask, item.keyEquivalentModifierMask, file: file, line: line)
    }
    let quit = try XCTUnwrap(
      items(menu).first { $0.action == #selector(NSApplication.terminate(_:)) },
      file: file, line: line)
    XCTAssertNil(quit.representedObject, file: file, line: line)
    XCTAssertFalse(records.values.contains { $0.item === quit }, file: file, line: line)
    XCTAssertEqual(quit.keyEquivalent, "q", file: file, line: line)
    XCTAssertEqual(quit.keyEquivalentModifierMask, [.command], file: file, line: line)
    return records
  }
  func testActualPublicationReplacesDefaultCustomDisabledAndResetSnapshots() async throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = previousMenu }
    let owner = try await owner()
    let delegate = AppDelegate()
    try delegate.installShortcutsForTesting(owner)
    let initial = try assertPublished(delegate)
    let first = try XCTUnwrap(initial["file.new"])
    XCTAssertEqual(first.shortcut?.canonicalString, "cmd+n")
    let extraOption = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .option],
      timestamp: 1, windowNumber: 0, context: nil, characters: "~",
      charactersIgnoringModifiers: "n",
      isARepeat: true, keyCode: 0)!
    XCTAssertTrue(
      NativeCommandKeyAdmission.shouldReject(
        sender: first.item, snapshot: first,
        publication: first.publication, scopedEvent: extraOption, currentEvent: extraOption))

    try await owner.apply(
      ShortcutProfile(records: [
        ShortcutOverride(
          commandID: "file.new",
          assignment: .assigned(try KeyboardShortcut(canonicalString: "alt+cmd+n")))
      ]))
    let custom = try XCTUnwrap(try assertPublished(delegate)["file.new"])
    XCTAssertGreaterThan(custom.publication, first.publication)
    XCTAssertFalse(custom.item === first.item)
    XCTAssertEqual(custom.shortcut?.canonicalString, "alt+cmd+n")
    XCTAssertEqual(custom.configuredMask, [.option, .command])
    XCTAssertFalse(
      NativeCommandKeyAdmission.shouldReject(
        sender: custom.item, snapshot: custom,
        publication: custom.publication, scopedEvent: extraOption, currentEvent: extraOption))
    XCTAssertFalse(
      NativeCommandKeyAdmission.shouldReject(
        sender: first.item, snapshot: custom,
        publication: custom.publication, scopedEvent: extraOption, currentEvent: extraOption))

    try await owner.apply(
      ShortcutProfile(records: [ShortcutOverride(commandID: "file.new", assignment: .disabled)]))
    let disabled = try XCTUnwrap(try assertPublished(delegate)["file.new"])
    XCTAssertGreaterThan(disabled.publication, custom.publication)
    XCTAssertFalse(disabled.item === custom.item)
    XCTAssertNil(disabled.shortcut)
    XCTAssertTrue(disabled.configuredKey.isEmpty)
    XCTAssertEqual(disabled.configuredMask, [])
    XCTAssertFalse(
      NativeCommandKeyAdmission.shouldReject(
        sender: disabled.item, snapshot: disabled,
        publication: disabled.publication, scopedEvent: extraOption, currentEvent: extraOption))

    try await owner.apply(.defaults)
    let reset = try XCTUnwrap(try assertPublished(delegate)["file.new"])
    XCTAssertGreaterThan(reset.publication, disabled.publication)
    XCTAssertFalse(reset.item === disabled.item)
    XCTAssertEqual(reset.shortcut?.canonicalString, "cmd+n")
    XCTAssertTrue(
      NativeCommandKeyAdmission.shouldReject(
        sender: reset.item, snapshot: reset,
        publication: reset.publication, scopedEvent: extraOption, currentEvent: extraOption))
  }
  func testCatalogWithdrawalPublishesDisabledRecordsWithoutAffectingNativeQuit() async throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = previousMenu }
    let owner = try await owner()
    let delegate = AppDelegate()
    try delegate.installShortcutsForTesting(owner)
    let before = try assertPublished(delegate)
    owner.updateCatalog(owner.state.catalog)
    XCTAssertFalse(delegate.shortcutReadyForTesting)
    let withdrawn = try assertPublished(delegate)
    XCTAssertFalse(withdrawn.isEmpty)
    for (id, record) in withdrawn {
      XCTAssertNil(record.shortcut)
      XCTAssertTrue(record.configuredKey.isEmpty)
      XCTAssertEqual(record.configuredMask, [])
      XCTAssertFalse(record.item === before[id]?.item)
    }
  }
}
