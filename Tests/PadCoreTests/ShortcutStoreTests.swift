import Darwin
import Foundation
import XCTest

@testable import PadCore

final class ShortcutStoreTests: XCTestCase {
  func testReadPreservesExactExistingReceiptWithoutChangingBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Shortcuts.json")
    let bytes = Data("{\n  \"version\":1, \"overrides\":[]\n}\n".utf8)
    try bytes.write(to: file)
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    let result = try ShortcutStore(directory: directory).read()
    XCTAssertEqual(
      result.receipt.rawBytes, bytes,
      "Existing exact bytes must be retained as the expected-write receipt")
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
  func testUnsafeAndOversizedExistingLeavesAreRefusedWithoutReplacement() throws {
    for kind in ["symlink", "oversized", "public", "unreadable", "directory"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appendingPathComponent("Shortcuts.json")
      let target = directory.appendingPathComponent("target")
      try Data("retained".utf8).write(to: target)
      switch kind {
      case "symlink":
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
      case "directory":
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      case "oversized":
        try Data(repeating: 65, count: ShortcutProfile.maximumBytes + 1).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
      case "unreadable":
        try Data("retained".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o000), 0)
      default:
        try Data("retained".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
      }
      XCTAssertThrowsError(try ShortcutStore(directory: directory).read(), "Must refuse \(kind)")
      XCTAssertEqual(try Data(contentsOf: target), Data("retained".utf8))
      if kind == "unreadable" { XCTAssertEqual(chmod(file.path, 0o600), 0) }
    }
  }

  func testWriteCreatesExactPrivateRecordAndRejectsStaleReceipt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ShortcutStore(directory: directory)
    let missing = try store.read().receipt
    XCTAssertNil(missing.rawBytes)
    let receipt = try store.write(.defaults, matching: missing)
    let expected = try ShortcutProfile.defaults.encode()
    XCTAssertEqual(receipt.rawBytes, expected)
    let file = directory.appendingPathComponent("Shortcuts.json")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: file.path), "Confirmed write must publish the profile")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    XCTAssertEqual(try Data(contentsOf: file), expected)
    try Data("concurrent edit".utf8).write(to: file)
    XCTAssertThrowsError(try store.write(.defaults, matching: receipt))
    XCTAssertEqual(try Data(contentsOf: file), Data("concurrent edit".utf8))
  }

  func privateDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Preferences")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }
  func install(_ bytes: Data, in directory: URL) throws {
    let file = directory.appendingPathComponent("Shortcuts.json")
    try bytes.write(to: file)
    XCTAssertEqual(chmod(file.path, 0o600), 0)
  }
  func testMalformedAndFutureRecordsRemainRepairableOnlyWithTheirExactReceipt() throws {
    for text in ["{malformed", "{\"version\":999,\"overrides\":[]}"] {
      let directory = try privateDirectory()
      let bytes = Data(text.utf8)
      try install(bytes, in: directory)
      let store = ShortcutStore(directory: directory)
      let read = try store.read()
      XCTAssertEqual(read.receipt.rawBytes, bytes)
      XCTAssertThrowsError(try read.decoded.get())
      XCTAssertEqual(
        try Data(contentsOf: directory.appendingPathComponent("Shortcuts.json")), bytes)
      let receipt = try store.write(.defaults, matching: read.receipt)
      XCTAssertEqual(receipt.rawBytes, try ShortcutProfile.defaults.encode())
      XCTAssertEqual(try store.read().decoded.get(), .defaults)
    }
  }
  func testDirectoryRetargetWithSameBytesRejectsPriorReceipt() throws {
    let directory = try privateDirectory()
    let store = ShortcutStore(directory: directory)
    let receipt = try store.write(.defaults, matching: store.read().receipt)
    let old = directory.deletingLastPathComponent().appendingPathComponent("old")
    try FileManager.default.moveItem(at: directory, to: old)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try install(receipt.rawBytes!, in: directory)
    XCTAssertThrowsError(try store.write(.defaults, matching: receipt)) {
      XCTAssertEqual($0 as? ShortcutStoreError, .changed)
    }
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("Shortcuts.json")), receipt.rawBytes)
    XCTAssertEqual(
      try Data(contentsOf: old.appendingPathComponent("Shortcuts.json")), receipt.rawBytes)
  }
  func testReadDetectsParentAndLeafReplacementBeforeReturningReceipt() throws {
    for parentChange in [false, true] {
      let directory = try privateDirectory()
      let bytes = try ShortcutProfile.defaults.encode()
      try install(bytes, in: directory)
      var hooks = ShortcutStoreHooks()
      hooks.afterRead = {
        if parentChange {
          try FileManager.default.moveItem(
            at: directory, to: directory.deletingLastPathComponent().appendingPathComponent("old"))
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        }
        try bytes.write(to: directory.appendingPathComponent("Shortcuts.json"), options: .atomic)
        _ = chmod(directory.appendingPathComponent("Shortcuts.json").path, 0o600)
      }
      XCTAssertThrowsError(try ShortcutStore(directory: directory, hooks: hooks).read())
    }
  }
  func testPartialReadsAndEINTRReturnAllBytesAndEIOOrPrematureEOFRefuse() throws {
    let directory = try privateDirectory()
    let bytes = try ShortcutProfile.defaults.encode()
    try install(bytes, in: directory)
    let calls = StoreTestBox(0)
    var partial = ShortcutStoreHooks()
    partial.read = { fd, pointer, count, offset in
      let first = calls.update { value -> Bool in
        value += 1
        return value == 1
      }
      if first {
        errno = EINTR
        return -1
      }
      return pread(fd, pointer, min(count, 3), offset)
    }
    XCTAssertEqual(
      try ShortcutStore(directory: directory, hooks: partial).read().receipt.rawBytes, bytes)
    for failure in [true, false] {
      var broken = ShortcutStoreHooks()
      broken.read = { _, _, _, _ in
        if failure {
          errno = EIO
          return -1
        }
        return 0
      }
      XCTAssertThrowsError(try ShortcutStore(directory: directory, hooks: broken).read())
    }
  }
  func testWriteFaultsPreserveOldReceiptOrReportExactUncertainAttempt() throws {
    let directory = try privateDirectory()
    let store = ShortcutStore(directory: directory)
    let receipt = try store.write(.defaults, matching: store.read().receipt)
    let profile = try ShortcutProfile(records: [
      ShortcutOverride(commandID: "file.save", assignment: .disabled)
    ])
    let attempted = try profile.encode()
    for fault in [SaveFault.beforeWrite, .partialWrite, .fileSync, .beforeReplace] {
      var hooks = ShortcutStoreHooks()
      hooks.fault = fault
      XCTAssertThrowsError(
        try ShortcutStore(directory: directory, hooks: hooks).write(profile, matching: receipt))
      XCTAssertEqual(try store.read().receipt.rawBytes, receipt.rawBytes)
    }
    var uncertain = ShortcutStoreHooks()
    uncertain.fault = .directorySync
    do {
      _ = try ShortcutStore(directory: directory, hooks: uncertain).write(
        profile, matching: receipt)
      XCTFail("Directory durability failure must not return a confirmed receipt")
    } catch let failure as ShortcutPublicationUncertain {
      XCTAssertEqual(failure.attemptedBytes, attempted)
      XCTAssertEqual(
        failure.evidence.destination, directory.appendingPathComponent("Shortcuts.json"))
      try AtomicFileStore().validatePublication(failure.evidence, expected: attempted)
      XCTAssertEqual(try store.read().receipt.rawBytes, attempted)
      XCTAssertThrowsError(
        try store.write(profile, matching: receipt),
        "Readback cannot silently renew the old receipt")
    }
  }
  func testReadOnlyAndUnsafeDirectoryModesAreNotChanged() throws {
    let directory = try privateDirectory()
    let store = ShortcutStore(directory: directory)
    let receipt = try store.write(.defaults, matching: store.read().receipt)
    let file = directory.appendingPathComponent("Shortcuts.json")
    XCTAssertEqual(chmod(file.path, 0o400), 0)
    defer {
      _ = chmod(file.path, 0o600)
      _ = chmod(directory.path, 0o700)
    }
    XCTAssertEqual(try store.read().receipt.rawBytes, receipt.rawBytes)
    XCTAssertThrowsError(try store.write(.defaults, matching: receipt))
    var info = stat()
    XCTAssertEqual(lstat(file.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o400)
    XCTAssertEqual(chmod(directory.path, 0o755), 0)
    XCTAssertThrowsError(try store.read())
    XCTAssertThrowsError(try store.write(.defaults, matching: receipt))
    XCTAssertEqual(lstat(directory.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o755)
  }
  func testWrongDestinationAndUnexpectedTargetRejectMissingReceipt() throws {
    let directory = try privateDirectory()
    let other = try privateDirectory()
    let store = ShortcutStore(directory: directory)
    let missing = try store.read().receipt
    XCTAssertThrowsError(try ShortcutStore(directory: other).write(.defaults, matching: missing))
    let concurrent = Data("concurrent".utf8)
    try install(concurrent, in: directory)
    XCTAssertThrowsError(try store.write(.defaults, matching: missing))
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("Shortcuts.json")), concurrent)
  }
  func testImportExportOnlyDelegateStrictProfileWithoutFilesystemChanges() throws {
    let directory = try privateDirectory()
    let store = ShortcutStore(directory: directory)
    let profile = try ShortcutProfile(records: [
      ShortcutOverride(commandID: "file.save", assignment: .disabled)
    ])
    let data = try store.exportData(profile)
    XCTAssertEqual(try store.importData(data), profile)
    XCTAssertThrowsError(try store.importData(Data("{\"version\":999,\"overrides\":[]}".utf8)))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Shortcuts.json").path))
  }

  func testParentRetargetBetweenReceiptValidationAndPublicationDoesNotWriteEitherTarget() throws {
    let directory = try privateDirectory()
    let store = ShortcutStore(directory: directory)
    let receipt = try store.write(.defaults, matching: store.read().receipt)
    let moved = directory.deletingLastPathComponent().appendingPathComponent("moved")
    let original = receipt.rawBytes!
    var hooks = ShortcutStoreHooks()
    hooks.beforeWrite = {
      try FileManager.default.moveItem(at: directory, to: moved)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try original.write(to: directory.appendingPathComponent("Shortcuts.json"))
      _ = chmod(directory.appendingPathComponent("Shortcuts.json").path, 0o600)
    }
    let profile = try ShortcutProfile(records: [
      ShortcutOverride(commandID: "file.save", assignment: .disabled)
    ])
    XCTAssertThrowsError(
      try ShortcutStore(directory: directory, hooks: hooks).write(profile, matching: receipt))
    XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("Shortcuts.json")), original)
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("Shortcuts.json")), original)
  }
  func testPrivateCreationAndDirectorySymlinkRefusal() throws {
    let root = try privateDirectory()
    let directory = root.appendingPathComponent("new-private")
    let store = ShortcutStore(directory: directory)
    let missing = try store.read().receipt
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.path),
      "Reading absent state does not create it")
    let receipt = try store.write(.defaults, matching: missing)
    var info = stat()
    XCTAssertEqual(lstat(directory.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
    XCTAssertEqual(lstat(directory.appendingPathComponent("Shortcuts.json").path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    XCTAssertThrowsError(try ShortcutStore(directory: alias).read())
    XCTAssertThrowsError(try ShortcutStore(directory: alias).write(.defaults, matching: receipt))
    XCTAssertEqual(try store.read().receipt.rawBytes, receipt.rawBytes)
  }

}

private final class StoreTestBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T
  init(_ value: T) { self.value = value }
  func update<R>(_ body: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
