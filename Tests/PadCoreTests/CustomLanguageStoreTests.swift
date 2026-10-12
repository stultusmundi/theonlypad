import Darwin
import Foundation
import XCTest

@testable import PadCore

final class CustomLanguageStoreTests: XCTestCase {
  private func file(_ directory: URL) -> URL {
    directory.appendingPathComponent("Profiles.json")
  }
  private func installed() throws -> URL {
    let directory = try catalogPrivateDirectory()
    try catalogInstall(CatalogTestFixture.originalBytes, in: directory)
    return directory
  }

  func testAbsentLoadDoesNotCreateStateAndFirstSavePublishesPrivateCatalog() throws {
    let root = try catalogPrivateRoot()
    let directory = root.appendingPathComponent("Languages")
    let store = CustomLanguageStore(directory: directory)
    guard let missing = catalogLoad(store) else { return }
    XCTAssertEqual(missing.snapshot.generation, 0)
    XCTAssertTrue(missing.snapshot.definitions.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    let written: LoadedLanguageCatalog
    do {
      written = try store.save(CatalogTestFixture.draft(generation: 0), expected: missing)
    } catch { return XCTFail("First valid private publication refused: \(error)") }
    XCTAssertEqual(written.snapshot.generation, 1)
    XCTAssertEqual(CatalogTestFixture.profile(written.snapshot).definitionRevision, 1)
    XCTAssertEqual(written.snapshot.definitions.first?.id, CatalogTestFixture.id)
    let exists = FileManager.default.fileExists(atPath: file(directory).path)
    XCTAssertTrue(exists, "Confirmed result must have a real published file")
    guard exists else { return }
    var info = stat()
    XCTAssertEqual(lstat(directory.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
    XCTAssertEqual(lstat(file(directory).path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(info.st_nlink, 1)
    guard let fresh = catalogLoad(CustomLanguageStore(directory: directory)) else { return }
    XCTAssertEqual(fresh.snapshot.generation, 1)
    XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 1)
    XCTAssertEqual(fresh.snapshot.definitions.first?.id, CatalogTestFixture.id)
  }

  func testActualStoredCatalogRenameAdvancesRevisionAndUnchangedDefinitionRetainsIt() throws {
    let directory = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    XCTAssertEqual(old.snapshot.generation, 7)
    XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, 3)
    XCTAssertEqual(try Data(contentsOf: file(directory)), CatalogTestFixture.originalBytes)
    let renamed: LoadedLanguageCatalog
    do {
      renamed = try store.save(
        CatalogTestFixture.draft(generation: 7, name: "Renamed"), expected: old)
    } catch { return XCTFail("Valid renamed catalog refused: \(error)") }
    XCTAssertEqual(renamed.snapshot.generation, 8)
    XCTAssertEqual(CatalogTestFixture.profile(renamed.snapshot).definitionRevision, 4)
    XCTAssertEqual(renamed.snapshot.definitions.first?.id, CatalogTestFixture.id)
    XCTAssertEqual(renamed.snapshot.definitions.first?.name, "Renamed")
    XCTAssertNotEqual(try Data(contentsOf: file(directory)), CatalogTestFixture.originalBytes)
    guard let fresh = catalogLoad(CustomLanguageStore(directory: directory)) else { return }
    XCTAssertEqual(fresh.snapshot.generation, 8)
    XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 4)
    let again: LoadedLanguageCatalog
    do {
      again = try store.save(
        CatalogTestFixture.draft(generation: 8, name: "Renamed"), expected: fresh)
    } catch { return XCTFail("Valid unchanged-definition publication refused: \(error)") }
    XCTAssertEqual(again.snapshot.generation, 9)
    XCTAssertEqual(CatalogTestFixture.profile(again.snapshot).definitionRevision, 4)
  }

  func testStaleExactBytesWrongDestinationAndWrongGenerationNeverReplaceDisk() throws {
    let directory = try installed()
    let other = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    let newer = CatalogTestFixture.changed(#""generation":7"#, #""generation":8"#)
    try catalogInstall(newer, in: directory)
    catalogRejects(
      {
        _ = try store.save(
          CatalogTestFixture.draft(generation: 7, name: "Lost writer"), expected: old)
      }, "Exact previous bytes changed")
    XCTAssertEqual(try Data(contentsOf: file(directory)), newer)
    catalogRejects(
      {
        _ = try CustomLanguageStore(directory: other).save(
          CatalogTestFixture.draft(generation: 7), expected: old)
      }, "Receipt destination differs")
    XCTAssertEqual(try Data(contentsOf: file(other)), CatalogTestFixture.originalBytes)
    guard let current = catalogLoad(store) else { return }
    catalogRejects(
      {
        _ = try store.save(CatalogTestFixture.draft(generation: 7), expected: current)
      }, "Candidate generation must match authenticated current load")
    XCTAssertEqual(try Data(contentsOf: file(directory)), newer)
  }

  func testCorruptUnknownAndDuplicateCatalogsCannotBeLoadedOrRoutineOverwritten() throws {
    let values = [
      Data("{malformed".utf8),
      CatalogTestFixture.changed(#""version":1"#, #""version":2"#),
      CatalogTestFixture.changed(#""generation":7"#, #""generation":7,"generation":7"#),
    ]
    for bytes in values {
      let directory = try catalogPrivateDirectory()
      let store = CustomLanguageStore(directory: directory)
      guard let missing = catalogLoad(store) else { return }
      try catalogInstall(bytes, in: directory)
      catalogRejects({ _ = try store.load() }, "Invalid stored data is not default state")
      XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
      catalogRejects(
        {
          _ = try store.save(CatalogTestFixture.draft(generation: 0), expected: missing)
        }, "Routine save cannot repair unknown/corrupt state using stale absence")
      XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
    }
  }

  func testSymlinkHardlinkWrongModesAndOversizeLeavesAreUnchanged() throws {
    for kind in ["symlink", "hardlink", "public", "unreadable", "directory", "oversize"] {
      let directory = try catalogPrivateDirectory()
      let target = directory.appendingPathComponent("Retained.json")
      try catalogInstall(CatalogTestFixture.originalBytes, in: directory)
      try CatalogTestFixture.originalBytes.write(to: target)
      XCTAssertEqual(chmod(target.path, 0o600), 0)
      switch kind {
      case "symlink":
        try FileManager.default.removeItem(at: file(directory))
        try FileManager.default.createSymbolicLink(at: file(directory), withDestinationURL: target)
      case "hardlink":
        try FileManager.default.removeItem(at: file(directory))
        XCTAssertEqual(link(target.path, file(directory).path), 0)
        var info = stat()
        XCTAssertEqual(lstat(file(directory).path, &info), 0)
        XCTAssertEqual(info.st_nlink, 2)
      case "public": XCTAssertEqual(chmod(file(directory).path, 0o644), 0)
      case "unreadable": XCTAssertEqual(chmod(file(directory).path, 0o000), 0)
      case "directory":
        try FileManager.default.removeItem(at: file(directory))
        try FileManager.default.createDirectory(
          at: file(directory), withIntermediateDirectories: false)
      default:
        try catalogInstall(
          Data(repeating: 32, count: CustomLanguageStore.maximumBytes + 1), in: directory)
      }
      catalogRejects({ _ = try CustomLanguageStore(directory: directory).load() }, kind)
      XCTAssertEqual(try Data(contentsOf: target), CatalogTestFixture.originalBytes)
      if kind == "unreadable" { XCTAssertEqual(chmod(file(directory).path, 0o600), 0) }
      if kind != "directory" {
        let expected =
          kind == "oversize"
          ? Data(repeating: 32, count: CustomLanguageStore.maximumBytes + 1)
          : CatalogTestFixture.originalBytes
        XCTAssertEqual(try Data(contentsOf: file(directory)), expected)
      } else {
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(directory).path))
      }
    }
  }

  func testDirectorySymlinkUnsafeModeAndReceiptRetargetRefuse() throws {
    let directory = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    let root = directory.deletingLastPathComponent()
    let alias = root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    catalogRejects({ _ = try CustomLanguageStore(directory: alias).load() }, "Directory symlink")
    XCTAssertEqual(chmod(directory.path, 0o755), 0)
    catalogRejects({ _ = try store.load() }, "Public directory")
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    let moved = root.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: directory, to: moved)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try catalogInstall(CatalogTestFixture.originalBytes, in: directory)
    catalogRejects(
      {
        _ = try store.save(CatalogTestFixture.draft(generation: 7, name: "Retarget"), expected: old)
      }, "Same bytes under replacement directory cannot renew old receipt")
    XCTAssertEqual(try Data(contentsOf: file(directory)), CatalogTestFixture.originalBytes)
    XCTAssertEqual(try Data(contentsOf: file(moved)), CatalogTestFixture.originalBytes)
  }

  func testReadLeafReplacementAndPrewriteParentReplacementRefuse() throws {
    let directory = try installed()
    let path = file(directory)
    var before = stat()
    XCTAssertEqual(lstat(path.path, &before), 0)
    var hooks = CustomLanguageStoreHooks()
    hooks.afterRead = {
      try CatalogTestFixture.originalBytes.write(to: path, options: .atomic)
      _ = chmod(path.path, 0o600)
    }
    catalogRejects(
      {
        _ = try CustomLanguageStore(directory: directory, hooks: hooks).load()
      }, "Read receipt cannot ignore replacement of opened leaf")
    XCTAssertEqual(try Data(contentsOf: path), CatalogTestFixture.originalBytes)
    var after = stat()
    XCTAssertEqual(lstat(path.path, &after), 0)
    XCTAssertNotEqual(
      before.st_ino, after.st_ino, "The actual afterRead replacement must be reached")
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    let moved = directory.deletingLastPathComponent().appendingPathComponent("Moved")
    var changed = CustomLanguageStoreHooks()
    changed.beforeWrite = {
      try FileManager.default.moveItem(at: directory, to: moved)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try CatalogTestFixture.originalBytes.write(to: path)
      _ = chmod(path.path, 0o600)
    }
    catalogRejects(
      {
        _ = try CustomLanguageStore(directory: directory, hooks: changed).save(
          CatalogTestFixture.draft(generation: 7, name: "Retarget"), expected: old)
      }, "Prewrite directory FD/path identity changed")
    XCTAssertEqual(try Data(contentsOf: path), CatalogTestFixture.originalBytes)
    // Require callback reach before crediting this second preservation oracle.
    let callbackRan = FileManager.default.fileExists(atPath: moved.path)
    XCTAssertTrue(callbackRan, "Actual selected beforeWrite boundary must execute")
    if callbackRan {
      XCTAssertEqual(
        try Data(contentsOf: moved.appendingPathComponent("Profiles.json")),
        CatalogTestFixture.originalBytes)
    }
  }

  func testOverrideOnlyPublicationKeepsProfileRevisionAndCanonicalDistinctRenameAdvances() throws {
    let directory = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    let withoutOverride: LoadedLanguageCatalog
    do {
      withoutOverride = try store.save(CatalogTestFixture.draft(generation: 7), expected: old)
    } catch { return XCTFail("Valid override-only publication refused: \(error)") }
    XCTAssertEqual(withoutOverride.snapshot.generation, 8)
    XCTAssertTrue(withoutOverride.snapshot.overrides.isEmpty)
    XCTAssertEqual(CatalogTestFixture.profile(withoutOverride.snapshot).definitionRevision, 3)
    let composed: LoadedLanguageCatalog
    do {
      composed = try store.save(
        CatalogTestFixture.draft(generation: 8, name: "Café"), expected: withoutOverride)
    } catch { return XCTFail("Valid raw name update refused: \(error)") }
    XCTAssertEqual(composed.snapshot.generation, 9)
    XCTAssertEqual(CatalogTestFixture.profile(composed.snapshot).definitionRevision, 4)
    let decomposed: LoadedLanguageCatalog
    do {
      decomposed = try store.save(
        CatalogTestFixture.draft(generation: 9, name: "Cafe\u{301}"), expected: composed)
    } catch { return XCTFail("Valid normalization-distinct update refused: \(error)") }
    XCTAssertEqual(decomposed.snapshot.generation, 10)
    XCTAssertEqual(CatalogTestFixture.profile(decomposed.snapshot).definitionRevision, 5)
    XCTAssertEqual(
      decomposed.snapshot.definitions.first?.name.utf16.map { $0 },
      [
        67, 97, 102, 101, 769,
      ])
  }

  func testPrewriteConcurrentLeafBytesCannotBeOverwritten() throws {
    let directory = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    let path = file(directory)
    let concurrent = CatalogTestFixture.changed(#""generation":7"#, #""generation":8"#)
    var hooks = CustomLanguageStoreHooks()
    hooks.beforeWrite = {
      try concurrent.write(to: path)
      _ = chmod(path.path, 0o600)
    }
    catalogRejects(
      {
        _ = try CustomLanguageStore(directory: directory, hooks: hooks).save(
          CatalogTestFixture.draft(generation: 7, name: "Lost"), expected: old)
      }, "Real beforeWrite competing bytes must fail final CAS")
    XCTAssertEqual(
      try Data(contentsOf: path), concurrent, "The real hook must run and its bytes survive")
    XCTAssertEqual(old.snapshot.generation, 7)
  }

  func testAtomicWriteFailuresPreserveOldBytesAndCurrentLoadedValue() throws {
    let directory = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    for fault in [
      SaveFault.beforeWrite, .diskFull, .partialWrite, .afterWrite, .fileSync, .beforeReplace,
    ] {
      var hooks = CustomLanguageStoreHooks()
      hooks.fault = fault
      catalogRejects(
        {
          _ = try CustomLanguageStore(directory: directory, hooks: hooks).save(
            CatalogTestFixture.draft(generation: 7, name: "Interrupted"), expected: old)
        }, "Injected atomic prepublication failure")
      XCTAssertEqual(try Data(contentsOf: file(directory)), CatalogTestFixture.originalBytes)
      XCTAssertEqual(old.snapshot.generation, 7)
      XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, 3)
    }
  }

  func testDirectorySyncUncertaintyIsTypedAndReadbackDoesNotRenewStaleReceipt() throws {
    let directory = try installed()
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    var hooks = CustomLanguageStoreHooks()
    hooks.fault = .directorySync
    do {
      _ = try CustomLanguageStore(directory: directory, hooks: hooks).save(
        CatalogTestFixture.draft(generation: 7, name: "Uncertain"), expected: old)
      XCTFail("Directory sync failure cannot return confirmed publication")
    } catch let outcome as CustomLanguagePublicationUncertain {
      XCTAssertEqual(outcome.evidence.destination, file(directory))
      XCTAssertEqual(try Data(contentsOf: file(directory)), outcome.attemptedBytes)
      try AtomicFileStore().validatePublication(outcome.evidence, expected: outcome.attemptedBytes)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: outcome.attemptedBytes) as? [String: Any])
      XCTAssertEqual(object["generation"] as? Int, 8)
      guard let fresh = catalogLoad(store) else { return }
      XCTAssertEqual(fresh.snapshot.generation, 8)
      XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 4)
      XCTAssertEqual(fresh.snapshot.definitions.first?.name, "Uncertain")
      catalogRejects(
        {
          _ = try store.save(CatalogTestFixture.draft(generation: 7), expected: old)
        }, "Exact old expected bytes remain stale after uncertain publication")
      XCTAssertEqual(try Data(contentsOf: file(directory)), outcome.attemptedBytes)
      let renewed = try store.save(
        CatalogTestFixture.draft(generation: 8, name: "Uncertain"), expected: fresh)
      XCTAssertEqual(renewed.snapshot.generation, 9)
      XCTAssertEqual(CatalogTestFixture.profile(renewed.snapshot).definitionRevision, 4)
    } catch {
      XCTFail("Actual postpublication durability failure must be typed uncertainty, got \(error)")
    }
    XCTAssertEqual(old.snapshot.generation, 7, "Uncertainty cannot mutate caller's old live value")
  }

  func testReadOnlyCatalogLoadsButCannotBeReplacedAndModeIsPreserved() throws {
    let directory = try installed()
    let path = file(directory)
    XCTAssertEqual(chmod(path.path, 0o400), 0)
    defer { _ = chmod(path.path, 0o600) }
    let store = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(store) else { return }
    XCTAssertEqual(old.snapshot.generation, 7)
    catalogRejects(
      {
        _ = try store.save(
          CatalogTestFixture.draft(generation: 7, name: "Read-only"), expected: old)
      }, "Read-only catalog must not be replaced")
    XCTAssertEqual(try Data(contentsOf: path), CatalogTestFixture.originalBytes)
    var info = stat()
    XCTAssertEqual(lstat(path.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o400)
  }

  func testPartialReadsLoadExactCatalogAndEIOOrPrematureEOFRefuse() throws {
    let directory = try installed()
    var partial = CustomLanguageStoreHooks()
    partial.read = { fd, pointer, amount, offset in
      pread(fd, pointer, min(amount, 3), offset)
    }
    guard let loaded = catalogLoad(CustomLanguageStore(directory: directory, hooks: partial)) else {
      return
    }
    XCTAssertEqual(loaded.snapshot.generation, 7)
    XCTAssertEqual(CatalogTestFixture.profile(loaded.snapshot).definitionRevision, 3)
    for ioError in [false, true] {
      var hooks = CustomLanguageStoreHooks()
      hooks.read = { _, _, _, _ in
        if ioError {
          errno = EIO
          return -1
        }
        return 0
      }
      catalogRejects(
        {
          _ = try CustomLanguageStore(directory: directory, hooks: hooks).load()
        }, "Opened file size cannot be acknowledged after failed/short read")
      XCTAssertEqual(try Data(contentsOf: file(directory)), CatalogTestFixture.originalBytes)
    }
  }

  func testGenerationAndChangedProfileRevisionExhaustionNeverWriteOrReset() throws {
    let variants = [
      CatalogTestFixture.changed(#""generation":7"#, #""generation":18446744073709551615"#),
      CatalogTestFixture.changed(#""revision":3"#, #""revision":18446744073709551615"#),
    ]
    for bytes in variants {
      let directory = try catalogPrivateDirectory()
      try catalogInstall(bytes, in: directory)
      let store = CustomLanguageStore(directory: directory)
      guard let old = catalogLoad(store) else { return }
      let generation: UInt64 = bytes == variants[0] ? UInt64.max : 7
      XCTAssertEqual(old.snapshot.generation, generation)
      if generation == 7 {
        XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, UInt64.max)
      }
      catalogRejects(
        {
          _ = try store.save(
            CatalogTestFixture.draft(generation: generation, name: "Changed"), expected: old)
        }, "Monotonic generation/revision exhausts without reset")
      XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
      XCTAssertEqual(old.snapshot.generation, generation)
    }
  }
}
