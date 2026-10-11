import XCTest

@testable import PadCore

final class ExtensionCatalogTests: XCTestCase {
  private func fixture() throws -> (ExtensionCatalog, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let manifest = ExtensionManifest(
      id: "example.cleanup", name: "Cleanup", version: "1.0.0",
      commands: [
        ExtensionCommand(
          id: "trim", title: "Trim trailing whitespace", transform: .trimTrailingWhitespace)
      ])
    let file = root.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: file)
    return (ExtensionCatalog(directory: root.appendingPathComponent("Extensions")), file)
  }

  func testInstallStartsDisabledThenEnabledCommandRunsAndCanBeRemoved() throws {
    let (catalog, file) = try fixture()
    let installed = try catalog.install(from: file)
    XCTAssertFalse(installed.enabled)
    XCTAssertEqual(try catalog.enabledCommands(), [])
    try catalog.setEnabled(id: installed.manifest.id, enabled: true)
    let command = try XCTUnwrap(catalog.enabledCommands().first)
    XCTAssertEqual(command.transform.apply(to: "hello  \nworld\t"), "hello\nworld")
    XCTAssertEqual(command.extensionID, "example.cleanup")
    try catalog.setEnabled(id: installed.manifest.id, enabled: false)
    XCTAssertEqual(try catalog.enabledCommands(), [])
    try catalog.uninstall(id: installed.manifest.id)
    XCTAssertEqual(try catalog.load(), [])
  }

  func testDuplicateInstallDoesNotOverwriteEnabledExtension() throws {
    let (catalog, file) = try fixture()
    let installed = try catalog.install(from: file)
    try catalog.setEnabled(id: installed.manifest.id, enabled: true)
    XCTAssertThrowsError(try catalog.install(from: file))
    XCTAssertEqual(try catalog.enabledCommands().count, 1)
  }

  func testUnsupportedCapabilitiesExecutableFieldsAndBadVersionAreRejected() throws {
    let (catalog, file) = try fixture()
    let original = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    for (key, value) in [
      ("capabilities", ["process.execute"] as Any), ("script", "/bin/sh" as Any),
      ("apiVersion", 2 as Any), ("id", "../../outside" as Any), ("version", "latest" as Any),
    ] {
      var object = original
      object[key] = value
      try JSONSerialization.data(withJSONObject: object).write(to: file)
      XCTAssertThrowsError(try catalog.install(from: file), key)
      XCTAssertEqual(try catalog.load(), [])
    }
  }

  func testSourceAndInstalledCatalogSymlinksAreRefused() throws {
    let (catalog, file) = try fixture()
    let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try catalog.install(from: link))
    _ = try catalog.install(from: file)
    let state = catalog.directory.appendingPathComponent("Catalog.json")
    let original = catalog.directory.appendingPathComponent("Original.json")
    try FileManager.default.moveItem(at: state, to: original)
    try FileManager.default.createSymbolicLink(at: state, withDestinationURL: original)
    XCTAssertThrowsError(try catalog.load())
    XCTAssertThrowsError(try catalog.uninstall(id: "example.cleanup"))
  }

  func testCorruptUnknownVersionAndUnknownFieldsAreNotOverwritten() throws {
    let (catalog, file) = try fixture()
    _ = try catalog.install(from: file)
    let state = catalog.directory.appendingPathComponent("Catalog.json")
    for json in [
      "broken", #"{"version":77,"extensions":[]}"#,
      #"{"version":1,"extensions":[],"future":"preserve"}"#,
    ] {
      let bytes = Data(json.utf8)
      try bytes.write(to: state)
      XCTAssertThrowsError(try catalog.load())
      XCTAssertThrowsError(try catalog.install(from: file))
      XCTAssertThrowsError(try catalog.setEnabled(id: "example.cleanup", enabled: false))
      XCTAssertEqual(try Data(contentsOf: state), bytes)
    }
  }

  func testManifestSizeAndCommandLimitsAreEnforcedAndStorageIsPrivate() throws {
    let (catalog, file) = try fixture()
    _ = try catalog.install(from: file)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: catalog.directory.path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(
        atPath: catalog.directory.appendingPathComponent("Catalog.json").path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)
    try Data(repeating: 32, count: 65_537).write(to: file)
    XCTAssertThrowsError(try catalog.inspect(url: file))
    let oversized = ExtensionManifest(
      id: "example.overflow", name: "Overflow", version: "1.0.0",
      commands: (0..<33).map {
        ExtensionCommand(id: "command\($0)", title: "Command", transform: .uppercase)
      })
    try JSONEncoder().encode(oversized).write(to: file)
    XCTAssertThrowsError(try catalog.inspect(url: file))
  }

  func testBundledExampleInstallsAndExposesItsActualCommands() throws {
    let (catalog, _) = try fixture()
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sample = repository.appendingPathComponent("Examples/CleanupExtension/manifest.json")
    let installed = try catalog.install(from: sample)
    try catalog.setEnabled(id: installed.id, enabled: true)
    let commands = try catalog.enabledCommands()
    XCTAssertEqual(commands.count, 3)
    let trim = try XCTUnwrap(commands.first { $0.commandID == "trim" })
    XCTAssertEqual(trim.transform.apply(to: "hello  \nworld\t"), "hello\nworld")
  }

  func testApprovedManifestInstallationDoesNotRereadChangedSource() throws {
    let (catalog, file) = try fixture()
    let approved = try catalog.inspect(url: file)
    try Data("changed after disclosure".utf8).write(to: file)
    let installed = try catalog.install(approved)
    XCTAssertEqual(installed.manifest, approved)
    XCTAssertFalse(installed.enabled)
  }

  func testIdentifiersRejectTrailingNewline() throws {
    let (catalog, file) = try fixture()
    for manifest in [
      ExtensionManifest(
        id: "example.cleanup\n", name: "Invalid", version: "1.0.0",
        commands: [ExtensionCommand(id: "trim", title: "Trim", transform: .trimTrailingWhitespace)]),
      ExtensionManifest(
        id: "example.cleanup", name: "Invalid", version: "1.0.0",
        commands: [
          ExtensionCommand(id: "trim\n", title: "Trim", transform: .trimTrailingWhitespace)
        ]),
    ] {
      try JSONEncoder().encode(manifest).write(to: file)
      XCTAssertThrowsError(try catalog.inspect(url: file))
    }
  }
}

// SPDX-License-Identifier: MIT
// Synthetic input only; this regression never loads or executes binary code.
extension ExtensionCatalogTests {
  func testWindowsPluginBinaryFeedbackPreservesCatalogAfterEachRefusal() throws {
    let (catalog, file) = try fixture()
    let installed = try catalog.install(from: file)
    try catalog.setEnabled(id: installed.id, enabled: true)
    let state = catalog.directory.appendingPathComponent("Catalog.json")
    let before = try Data(contentsOf: state)
    let entries = try catalog.load()
    let commands = try catalog.enabledCommands()
    for name in ["synthetic.dll", "synthetic.DLL", "renamed.json"] {
      let binary = file.deletingLastPathComponent().appendingPathComponent(name)
      try Data([0x4d, 0x5a, 0, 1, 2, 3]).write(to: binary)
      for inspectOnly in [true, false] {
        XCTAssertThrowsError(
          try {
            if inspectOnly {
              _ = try catalog.inspect(url: binary)
            } else {
              _ = try catalog.install(from: binary)
            }
          }()
        ) { error in
          XCTAssertTrue(error is ExtensionCatalogError)
          XCTAssertTrue(
            error.localizedDescription.contains("Windows Notepad++"),
            "Rejected binary should explain the Windows plugin incompatibility")
          XCTAssertTrue(
            error.localizedDescription.contains("JSON"),
            "Rejected binary should identify the accepted manifest format")
        }
        XCTAssertEqual(try Data(contentsOf: state), before)
        XCTAssertEqual(try catalog.load(), entries)
        XCTAssertEqual(try catalog.enabledCommands(), commands)
      }
    }
  }

  func testDeclarativeJSONWithDLLFilenameRetainsPublicAPICompatibility() throws {
    let (catalog, file) = try fixture()
    let manifest = try catalog.inspect(url: file)
    let renamed = file.deletingLastPathComponent().appendingPathComponent("declarative.dll")
    try Data(contentsOf: file).write(to: renamed)
    XCTAssertEqual(try catalog.inspect(url: renamed), manifest)
    let installed = try catalog.install(from: renamed)
    XCTAssertEqual(installed.manifest, manifest)
    XCTAssertFalse(installed.enabled)
  }

  func testTruncatedSignatureAndCorruptJSONKeepInvalidManifestRefusal() throws {
    let (catalog, file) = try fixture()
    for bytes in [Data([0x4d]), Data("not JSON".utf8)] {
      try bytes.write(to: file)
      XCTAssertThrowsError(try catalog.inspect(url: file)) { error in
        guard let failure = error as? ExtensionCatalogError else {
          XCTFail("Expected catalog error")
          return
        }
        guard case .invalidManifest = failure else {
          XCTFail("Incomplete signature and corrupt JSON must remain invalid manifests")
          return
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.directory.path))
    }
  }

  func testBinaryFeedbackPreservesSymlinkAndManifestLimitPriority() throws {
    let (catalog, file) = try fixture()
    let installed = try catalog.install(from: file)
    try catalog.setEnabled(id: installed.id, enabled: true)
    let state = catalog.directory.appendingPathComponent("Catalog.json")
    let before = try Data(contentsOf: state)
    let commands = try catalog.enabledCommands()
    let binary = file.deletingLastPathComponent().appendingPathComponent("target.dll")
    try Data([0x4d, 0x5a]).write(to: binary)
    let link = file.deletingLastPathComponent().appendingPathComponent("symlink.dll")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    XCTAssertThrowsError(try catalog.install(from: link)) { error in
      guard let failure = error as? ExtensionCatalogError, case .unsafeLocation = failure else {
        XCTFail("Symlink safety must precede binary classification")
        return
      }
    }
    XCTAssertEqual(try Data(contentsOf: state), before)
    XCTAssertEqual(try catalog.enabledCommands(), commands)
    var oversized = Data(repeating: 32, count: 65_537)
    oversized[0] = 0x4d
    oversized[1] = 0x5a
    try oversized.write(to: binary)
    XCTAssertThrowsError(try catalog.install(from: binary)) { error in
      guard let failure = error as? ExtensionCatalogError, case .limit = failure else {
        XCTFail("Manifest limit must precede binary classification")
        return
      }
    }
    XCTAssertEqual(try Data(contentsOf: state), before)
    XCTAssertEqual(try catalog.enabledCommands(), commands)
  }
}
