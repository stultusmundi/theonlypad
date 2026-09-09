import XCTest

@testable import PadCore

final class SettingsTests: XCTestCase {
  private func store() throws -> SettingsStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("Preferences")
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
    return SettingsStore(directory: directory)
  }

  func testAbsentSettingsUseDefaultsAndSavedSettingsSurviveReload() throws {
    let store = try store()
    XCTAssertEqual(try store.load(), .defaults)
    var settings = EditorSettings.defaults
    settings.theme = .dark
    settings.fontSize = 19
    settings.fontName = "Menlo"
    settings.wrap = false
    settings.tabWidth = 2
    try store.save(settings)
    XCTAssertEqual(try store.load(), settings)
  }

  func testVersionZeroMigrationPreservesLegacyFields() throws {
    let store = try store()
    let settings = try store.importData(Data(#"{"version":0,"fontSize":17,"wordWrap":false}"#.utf8))
    XCTAssertEqual(settings.fontSize, 17)
    XCTAssertFalse(settings.wrap)
    XCTAssertEqual(settings.theme, .system)
    XCTAssertEqual(settings.tabWidth, 4)
    let exported = try XCTUnwrap(
      JSONSerialization.jsonObject(with: store.exportData(settings)) as? [String: Any])
    XCTAssertEqual(exported["version"] as? Int, 1)
  }

  func testUnknownVersionUnknownFieldsAndInvalidFieldsAreRejected() throws {
    let store = try store()
    let invalid = [
      #"{"version":2,"settings":{}}"#,
      #"{"version":0,"fontSize":100,"wordWrap":true}"#,
      #"{"version":0,"fontSize":13,"wordWrap":"false"}"#,
      #"{"version":0,"fontSize":13,"wordWrap":true,"unknown":"preserve me"}"#,
      #"{"version":1,"settings":{"theme":"solarized","fontSize":13,"fontName":"Menlo","wrap":true,"tabWidth":4}}"#,
      #"{"version":1,"settings":{"theme":"dark","fontSize":13,"fontName":"","wrap":true,"tabWidth":4}}"#,
      #"{"version":1,"settings":{"theme":"dark","fontSize":13,"fontName":"Menlo","wrap":true,"tabWidth":9}}"#,
    ]
    for json in invalid { XCTAssertThrowsError(try store.importData(Data(json.utf8)), json) }
  }

  func testFailedSaveAndImportLeaveExistingPreferencesUntouched() throws {
    let store = try store()
    try store.save(.defaults)
    var invalid = EditorSettings.defaults
    invalid.fontSize = .nan
    XCTAssertThrowsError(try store.save(invalid))
    XCTAssertThrowsError(try store.importData(Data("broken".utf8)))
    XCTAssertEqual(try store.load(), .defaults)
  }

  func testExportRoundTripAndReset() throws {
    let store = try store()
    var settings = EditorSettings.defaults
    settings.theme = .light
    settings.fontSize = 36
    try store.save(settings)
    XCTAssertEqual(try store.importData(store.exportData(settings)), settings)
    XCTAssertEqual(try store.reset(), .defaults)
    XCTAssertEqual(try store.load(), .defaults)
  }

  func testCorruptExistingFileDoesNotSilentlyReturnDefaults() throws {
    let store = try store()
    try store.save(.defaults)
    let file = store.directory.appendingPathComponent("Settings.json")
    try Data("invalid JSON".utf8).write(to: file)
    XCTAssertThrowsError(try store.load())
  }

  func testSettingsStorageUsesPrivateDirectoryAndRefusesSymlinkFile() throws {
    let store = try store()
    try store.save(.defaults)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o700)
    let file = store.directory.appendingPathComponent("Settings.json")
    let target = store.directory.appendingPathComponent("original.json")
    try FileManager.default.moveItem(at: file, to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.save(.defaults))
    XCTAssertEqual(try store.importData(Data(contentsOf: target)), .defaults)
  }

  func testOversizedImportsAndMissingFieldsAreRejected() throws {
    let store = try store()
    XCTAssertThrowsError(try store.importData(Data(repeating: 32, count: 1_048_577)))
    XCTAssertThrowsError(
      try store.importData(Data(#"{"version":1,"settings":{"theme":"system"}}"#.utf8)))
  }
}
