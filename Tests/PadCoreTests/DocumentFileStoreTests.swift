import XCTest

@testable import PadCore

final class DocumentFileStoreTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testAtomicSaveRefusesExternalChangesAndExistingNewFile() throws {
    let file = try directory().appendingPathComponent("sample.txt")
    let store = AtomicFileStore()
    try store.save(Data("first".utf8), to: file, expected: nil)
    XCTAssertThrowsError(try store.save(Data("lost".utf8), to: file, expected: nil))
    XCTAssertThrowsError(try store.save(Data("lost".utf8), to: file, expected: Data("stale".utf8)))
    XCTAssertEqual(try Data(contentsOf: file), Data("first".utf8))
    try store.save(Data("second".utf8), to: file, expected: Data("first".utf8))
    XCTAssertEqual(try Data(contentsOf: file), Data("second".utf8))
  }

  func testInjectedFailuresLeaveOriginalAndCleanTemporaryFiles() throws {
    let folder = try directory()
    let file = folder.appendingPathComponent("sample.txt")
    try Data("original".utf8).write(to: file)
    for fault in [SaveFault.beforeWrite, .afterWrite, .beforeReplace, .diskFull] {
      XCTAssertThrowsError(
        try AtomicFileStore().save(
          Data("edit".utf8), to: file, expected: Data("original".utf8), fault: fault))
      XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: folder.path), ["sample.txt"])
    }
  }

  func testExternallyGrownSparseFileIsRejectedWithoutReplacement() throws {
    let file = try directory().appendingPathComponent("grown.txt")
    try Data("original".utf8).write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 1_000_000_000)
    try handle.close()
    XCTAssertThrowsError(
      try AtomicFileStore().save(Data("edit".utf8), to: file, expected: Data("original".utf8)))
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value,
      1_000_000_000)
    let reader = try FileHandle(forReadingFrom: file)
    defer { try? reader.close() }
    XCTAssertEqual(try reader.read(upToCount: 8), Data("original".utf8))
  }

  func testExistingEmptyFileCanBeSavedAndPermissionsArePreserved() throws {
    let file = try directory().appendingPathComponent("empty.txt")
    try Data().write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    try AtomicFileStore().save(Data("content".utf8), to: file, expected: Data())
    XCTAssertEqual(try Data(contentsOf: file), Data("content".utf8))
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o640)
  }

  func testRecoveryRejectsSymlinkDirectory() throws {
    let folder = try directory()
    let link = folder.appendingPathComponent("link")
    let target = folder.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertThrowsError(try RecoveryStore(directory: link))
  }

  func testSymlinkAndReadOnlyTargetsAreRefused() throws {
    let folder = try directory()
    let file = folder.appendingPathComponent("original.txt")
    let link = folder.appendingPathComponent("link.txt")
    try Data("original".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(
      try AtomicFileStore().save(Data(), to: link, expected: Data("original".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    XCTAssertThrowsError(
      try AtomicFileStore().save(Data(), to: file, expected: Data("original".utf8)))
    XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
  }

  func testRecoveryRoundTripPrivatePermissionsAndRemoval() throws {
    let folder = try directory().appendingPathComponent("recovery")
    let store = try RecoveryStore(directory: folder)
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "private synthetic 👩🏽‍💻", encoding: .utf16LE, hasBOM: true)
    try store.save(snapshot)
    XCTAssertEqual(try store.loadAll(), [snapshot])
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o700)
    let file = folder.appendingPathComponent(snapshot.id.uuidString + ".json")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o600)
    try store.remove(id: snapshot.id)
    XCTAssertEqual(try store.loadAll(), [])
  }

  func testCorruptRecoveryIsQuarantinedWhileValidSnapshotSurvives() throws {
    let folder = try directory()
    let store = try RecoveryStore(directory: folder)
    let valid = RecoverySnapshot(id: UUID(), text: "valid", encoding: .utf8, hasBOM: false)
    let damaged = RecoverySnapshot(id: UUID(), text: "damaged", encoding: .utf8, hasBOM: false)
    try store.save(valid)
    try store.save(damaged)
    let file = folder.appendingPathComponent(damaged.id.uuidString + ".json")
    var json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    json = json.replacingOccurrences(of: "damaged", with: "changed")
    try Data(json.utf8).write(to: file)
    XCTAssertEqual(try store.loadAll(), [valid])
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).contains {
        $0.hasSuffix(".corrupt")
      })
  }
}
