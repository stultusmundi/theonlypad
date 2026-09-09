import Foundation
import XCTest

@testable import PadCore

final class ShortcutTests: XCTestCase {
  func key(_ value: String) throws -> KeyboardShortcut {
    try KeyboardShortcut(canonicalString: value)
  }
  func record(_ id: String, _ value: String?) throws -> ShortcutOverride {
    ShortcutOverride(
      commandID: id, assignment: try value.map { .assigned(try key($0)) } ?? .disabled)
  }
  func compose(_ records: [ShortcutOverride], catalog: [CommandDescriptor]? = nil) throws
    -> ShortcutComposition
  {
    try ShortcutComposer.build(
      catalog: catalog ?? AppCommands.registry().commands,
      profile: ShortcutProfile(records: records), catalogRevision: UUID())
  }
  func testTypedCanonicalAndUppercase() throws {
    XCTAssertEqual(try key("shift+cmd+a"), try key("cmd+shift+a"))
    XCTAssertEqual(try KeyboardShortcut(key: "A", modifiers: .command), try key("cmd+shift+a"))
    XCTAssertEqual(try key("cmd+alt+up").canonicalString, "alt+cmd+up")
    XCTAssertNotEqual(try key("cmd+a"), try key("cmd+shift+a"))
  }
  func testUnsupportedAndDuplicateModifiers() {
    for value in [
      "cmd+cmd+a", "hyper+cmd+a", "a", "shift+a", "cmd+", "cmd++", "cmd+😀", "cmd+é", "cmd+f1",
      "cmd+space", "cmd+left", "cmd+a+b", "cmd+CTRL+a", "cmd+ a",
    ] { XCTAssertThrowsError(try key(value), value) }
    XCTAssertThrowsError(try KeyboardShortcut(key: "a", modifiers: .init(rawValue: 255)))
  }
  func testEveryExistingDefaultTyped() throws {
    for command in try AppCommands.registry().commands {
      if let value = command.shortcut { XCTAssertEqual(try key(value).canonicalString, value) }
    }
  }
  func testDisabledVersusInheritedAndSwap() throws {
    let unchanged = try compose([])
    XCTAssertEqual(unchanged.registry.commands, try AppCommands.registry().commands)
    let changed = try compose([record("file.save", nil), record("file.open", "cmd+s")])
    XCTAssertFalse(changed.usesDefaults)
    XCTAssertNil(changed.registry.commands.first { $0.id == "file.save" }?.shortcut)
    XCTAssertEqual(changed.registry.commands.first { $0.id == "file.open" }?.shortcut, "cmd+s")
    let swap = try compose([record("file.save", "cmd+o"), record("file.open", "cmd+s")])
    XCTAssertFalse(swap.usesDefaults)
    XCTAssertEqual(swap.registry.commands.first { $0.id == "file.save" }?.shortcut, "cmd+o")
  }
  func testInheritedCollisionFallsBackWholeRegistry() throws {
    let result = try compose([record("file.open", "cmd+s"), record("file.print", nil)])
    XCTAssertTrue(result.usesDefaults)
    XCTAssertEqual(result.conflicts.first?.reason, .collision)
    XCTAssertEqual(Set(result.conflicts.first?.commandIDs ?? []), ["file.open", "file.save"])
    XCTAssertEqual(result.registry.commands, try AppCommands.registry().commands)
  }
  func testReservedAndProtected() throws {
    for chord in [
      "cmd+h", "cmd+q", "cmd+m", "cmd+ctrl+q", "cmd+shift+3", "cmd+shift+4", "cmd+shift+5",
      "cmd+shift+ctrl+4",
    ] {
      XCTAssertTrue(
        try compose([record("file.open", chord)]).conflicts.contains { $0.reason == .reserved },
        chord)
    }
    for id in [
      "edit.undo", "edit.redo", "edit.cut", "edit.copy", "edit.paste", "edit.selectAll",
      "file.close",
    ] {
      XCTAssertTrue(
        try compose([record(id, nil)]).conflicts.contains { $0.reason == .protectedCommand }, id)
    }
    XCTAssertTrue(try compose([record("file.open", "cmd+z")]).usesDefaults)
  }
  func testUnavailableRetainedAndReactivated() throws {
    let item = try record("extension.synthetic.run", "cmd+ctrl+r")
    let profile = try ShortcutProfile(records: [item])
    let first = try compose(profile.records)
    XCTAssertEqual(first.unavailableCommandIDs, [item.commandID])
    XCTAssertFalse(first.usesDefaults)
    XCTAssertFalse(first.registry.commands.contains { $0.id == item.commandID })
    let catalog =
      try AppCommands.registry().commands + [
        CommandDescriptor(id: item.commandID, title: "Synthetic")
      ]
    let result = try compose(profile.records, catalog: catalog)
    XCTAssertEqual(result.registry.commands.last?.shortcut, "cmd+ctrl+r")
    XCTAssertTrue(result.unavailableCommandIDs.isEmpty)
    XCTAssertEqual(profile.records, [item])
  }
  func testUnavailableAssignmentCollidesWithOtherOverrides() throws {
    let result = try compose([
      record("extension.absent.one", "cmd+ctrl+r"), record("file.open", "cmd+ctrl+r"),
    ])
    XCTAssertTrue(result.usesDefaults)
    XCTAssertEqual(result.conflicts.first?.reason, .collision)
  }
  func testNewDefaultConflictRetainsProfileAndDefaults() throws {
    let records = [try record("file.open", "cmd+ctrl+r")]
    let catalog =
      try AppCommands.registry().commands + [
        CommandDescriptor(id: "tool.new", title: "New", shortcut: "cmd+ctrl+r")
      ]
    let result = try compose(records, catalog: catalog)
    XCTAssertTrue(result.usesDefaults)
    XCTAssertEqual(result.registry.commands, catalog)
  }
  func testDuplicateAndMalformedCatalogRejected() throws {
    XCTAssertThrowsError(
      try compose([], catalog: [.init(id: "a", title: "A"), .init(id: "a", title: "B")]))
    XCTAssertThrowsError(
      try compose([], catalog: [.init(id: "a", title: "A", shortcut: "cmd+unsupported")]))
  }
  func testStrictProfileRoundtrip() throws {
    let profile = try ShortcutProfile(records: [
      record("file.save", nil), record("extension.absent.run", "cmd+ctrl+r"),
    ])
    let bytes = try profile.encode()
    XCTAssertEqual(try ShortcutProfile.decode(bytes), profile)
    XCTAssertEqual(
      try ShortcutProfile.decode(Data("{\"version\":1,\"overrides\":[]}".utf8)), .defaults)
  }
  func testStrictJSONRejectsDuplicatesIncludingEscapes() {
    let values = [
      #"{"version":1,"version":1,"overrides":[]}"#,
      #"{"version":1,"\u0076ersion":1,"overrides":[]}"#,
      #"{"version":1,"overrides":[{"commandID":"file.save","commandID":"file.open","assignment":{"kind":"disabled"}}]}"#,
      #"{"version":1,"overrides":[{"commandID":"file.save","assignment":{"kind":"assigned","key":"s","key":"o","modifiers":["cmd"]}}]}"#,
    ]
    for value in values {
      XCTAssertThrowsError(try ShortcutProfile.decode(Data(value.utf8)), value)
    }
  }
  func testStrictJSONRejectsUnknownFieldsVersionsAndTypes() {
    let values = [
      #"{"version":2,"overrides":[]}"#, #"{"version":true,"overrides":[]}"#,
      #"{"version":1.0,"overrides":[]}"#, #"{"version":1,"overrides":[],"other":0}"#,
      #"{"version":1,"overrides":null}"#,
      #"{"version":1,"overrides":[{"commandID":"a","assignment":{"kind":"disabled","key":"a"}}]}"#,
      #"{"version":1,"overrides":[{"commandID":"a","assignment":{"kind":"assigned","key":"a","modifiers":["cmd","cmd"]}}]}"#,
      #"{"version":1,"overrides":[{"commandID":"a","assignment":{"kind":"inherit"}}]}"#,
    ]
    for value in values {
      XCTAssertThrowsError(try ShortcutProfile.decode(Data(value.utf8)), value)
    }
  }
  func testProfileLimitsIDsAndDuplicates() throws {
    XCTAssertThrowsError(try ShortcutProfile(records: [record("a", nil), record("a", nil)]))
    for id in ["", "a b", "😀", String(repeating: "a", count: 257)] {
      XCTAssertThrowsError(try ShortcutProfile(records: [record(id, nil)]))
    }
    XCTAssertThrowsError(
      try ShortcutProfile(
        records: (0...1024).map { .init(commandID: "a.\($0)", assignment: .disabled) }))
    XCTAssertThrowsError(
      try ShortcutProfile.decode(Data(repeating: 32, count: ShortcutProfile.maximumBytes + 1)))
    XCTAssertThrowsError(
      try ShortcutProfile.decode(
        Data((String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)).utf8)))
  }
  func testCatalogRevisionAndTitlesPreserved() throws {
    let revision = UUID()
    let commands = [
      CommandDescriptor(id: "a", title: "Same"), CommandDescriptor(id: "b", title: "Same"),
    ]
    let result = try ShortcutComposer.build(
      catalog: commands, profile: ShortcutProfile(records: [record("a", "cmd+r")]),
      catalogRevision: revision)
    XCTAssertEqual(result.catalogRevision, revision)
    XCTAssertEqual(result.registry.commands.map(\.title), ["Same", "Same"])
    XCTAssertNil(result.registry.commands[1].shortcut)
  }

  func testMalformedJSONAndUnicodeKeysNeverSilentlyAccepted() {
    let values = [
      "", "[]", "null", #"{"version":1,"overrides":[],}"#, #"{"version":1,"overrides":[,]}"#,
      #"{"version":01,"overrides":[]}"#, #"{"version":1,"overrides":[]} true"#,
      #"{"version":1,"overrides":[{"commandID":"a","assignment":{"kind":"disabled"},"extra":1}]}"#,
      #"{"version":1,"overrides":[{"commandID":"a","assignment":{"kind":"assigned","key":"a","modifiers":[true]}}]}"#,
      #"{"version":1,"overrides":[{"commandID":"\uD800","assignment":{"kind":"disabled"}}]}"#,
    ]
    for value in values {
      XCTAssertThrowsError(try ShortcutProfile.decode(Data(value.utf8)), value)
    }
    XCTAssertThrowsError(try ShortcutProfile.decode(Data([255, 254, 123, 125])))
  }
  func testMaximumRecordsAndExplicitDisabledRoundTrip() throws {
    let profile = try ShortcutProfile(
      records: (0..<ShortcutProfile.maximumRecords).map {
        .init(commandID: "extension.absent.\($0)", assignment: .disabled)
      })
    XCTAssertEqual(try ShortcutProfile.decode(profile.encode()), profile)
    let first = try record("extension.one.run", "cmd+ctrl+r")
    let second = try record("extension.two.run", "cmd+ctrl+r")
    let conflicted = try ShortcutProfile(records: [first, second])
    XCTAssertEqual(try ShortcutProfile.decode(conflicted.encode()), conflicted)
    XCTAssertTrue(try compose(conflicted.records).usesDefaults)
  }
  func testSupportedCharacterAndModifierRoundTrips() throws {
    for character in Array("abcdefghijklmnopqrstuvwxyz0123456789[]/,=").map(String.init) + [
      "up", "down",
    ] {
      for raw in stride(from: UInt8(1), through: UInt8(15), by: 2) {
        let shortcut = try KeyboardShortcut(key: character, modifiers: .init(rawValue: raw))
        XCTAssertEqual(try key(shortcut.canonicalString), shortcut)
        let profile = try ShortcutProfile(records: [
          .init(commandID: "a", assignment: .assigned(shortcut))
        ])
        XCTAssertEqual(try ShortcutProfile.decode(profile.encode()), profile)
      }
    }
  }
  func testUnsupportedReservedNativeKeysCannotEnterProfiles() {
    for value in ["cmd+tab", "cmd+`", "cmd+alt+escape", "cmd+return", "cmd+ctrl+space"] {
      XCTAssertThrowsError(try key(value))
    }
  }
  func testNativeProvenEqualsBaseKeyPreservesShift() throws {
    XCTAssertEqual(
      try KeyboardShortcut(key: "=", modifiers: [.command, .shift]).canonicalString, "cmd+shift+=")
    XCTAssertEqual(
      try key("cmd+shift+="), try KeyboardShortcut(key: "=", modifiers: [.command, .shift]))
  }

}
