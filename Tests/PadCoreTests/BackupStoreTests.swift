import Darwin
import Foundation
import XCTest

@testable import PadCore

final class BackupStoreTests: XCTestCase {
  func fixture(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url.appendingPathComponent("Backups"))
  }
  func testCaptureReadListRemovePreservesBinaryAndPrivatePermissions() throws {
    try fixture { directory in
      let store = BackupStore(directory: directory)
      XCTAssertTrue(try store.list().isEmpty)
      let original = directory.deletingLastPathComponent().appendingPathComponent(
        "private-name.txt")
      let bytes = Data([0, 255, 13, 10, 0xEF, 0xBB, 0xBF])
      let record = try store.capture(data: bytes, originalURL: original)
      XCTAssertEqual(record.originalPath, original.standardizedFileURL.path)
      XCTAssertEqual(record.byteCount, bytes.count)
      XCTAssertLessThan(abs(record.createdAt.timeIntervalSinceNow), 10)
      XCTAssertEqual(try store.read(id: record.id), bytes)
      XCTAssertEqual(try store.list(), [record])
      let mode =
        try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
        as? NSNumber
      XCTAssertEqual(mode?.intValue, 0o700)
      let file = directory.appendingPathComponent(record.id.uuidString + ".json")
      let fileMode =
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
      XCTAssertEqual(fileMode?.intValue, 0o600)
      XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
      try store.remove(id: record.id)
      XCTAssertTrue(try store.list().isEmpty)
      XCTAssertThrowsError(try store.read(id: record.id))
    }
  }
  func testLegacyEncodingAndBytesTravelTogetherInSnapshot() throws {
    try fixture { directory in
      let store = BackupStore(directory: directory)
      let record = try store.capture(
        data: Data([0x80, 0xE9]), originalURL: URL(fileURLWithPath: "/synthetic/legacy"),
        encoding: .windows1252)
      let snapshot = try store.snapshot(id: record.id)
      XCTAssertEqual(snapshot.record.encoding, .windows1252)
      XCTAssertEqual(snapshot.data, Data([0x80, 0xE9]))
      XCTAssertEqual(
        try DocumentCodec.decode(snapshot.data, encoding: snapshot.record.encoding).text, "€é")
    }
  }
  func testSlashHeavyBase64AtConfiguredRecordLimitRemainsReadable() throws {
    try fixture { directory in
      let data = Data(repeating: 0xFF, count: 100_000)
      let store = BackupStore(directory: directory, limits: .init(maxRecordBytes: data.count))
      let record = try store.capture(
        data: data, originalURL: URL(fileURLWithPath: "/synthetic/slash-heavy"), encoding: .latin1)
      XCTAssertEqual(try store.read(id: record.id), data)
      XCTAssertEqual(try store.list(), [record])
      XCTAssertEqual(try store.snapshot(id: record.id).data, data)
    }
  }
  func testCapacityFailureKeepsEarlierRecordAndCreatesNoPendingFile() throws {
    try fixture { directory in
      let store = BackupStore(
        directory: directory, limits: .init(maxRecords: 1, maxRecordBytes: 4, maxTotalBytes: 4))
      let first = try store.capture(
        data: Data([1, 2, 3, 4]), originalURL: URL(fileURLWithPath: "/synthetic/source"))
      XCTAssertThrowsError(
        try store.capture(data: Data([5]), originalURL: URL(fileURLWithPath: "/synthetic/second")))
      XCTAssertEqual(try store.read(id: first.id), Data([1, 2, 3, 4]))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path),
        [first.id.uuidString + ".json"])
    }
  }
  func testCorruptHashUnknownFieldsAndTruncatedRecordAreNeverIgnored() throws {
    for alteration in 0..<3 {
      try fixture { directory in
        let store = BackupStore(directory: directory)
        let record = try store.capture(
          data: Data("original".utf8), originalURL: URL(fileURLWithPath: "/synthetic/source"))
        let file = directory.appendingPathComponent(record.id.uuidString + ".json")
        var object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        if alteration == 0 { object["sha256"] = String(repeating: "0", count: 64) }
        if alteration == 1 { object["unexpected"] = true }
        let bytes =
          alteration == 2
          ? Data("{\"version\":1".utf8)
          : try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.read(id: record.id))
        XCTAssertThrowsError(
          try store.capture(data: Data(), originalURL: URL(fileURLWithPath: "/synthetic/new")))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try store.remove(id: record.id)
        XCTAssertTrue(try store.list().isEmpty)
      }
    }
  }
  func testPendingRecordRequiresExplicitRemovalAndUnexpectedFileRemains() throws {
    try fixture { directory in
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let id = UUID()
      let pending = directory.appendingPathComponent(UUID().uuidString)
      let record = directory.appendingPathComponent(id.uuidString + ".pending")
      try Data("partial".utf8).write(to: record)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
      let store = BackupStore(directory: directory)
      XCTAssertThrowsError(try store.list())
      try store.remove(id: id)
      XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
      try Data("unrelated".utf8).write(to: pending)
      XCTAssertThrowsError(try store.list())
      XCTAssertEqual(try Data(contentsOf: pending), Data("unrelated".utf8))
    }
  }
  func testOversizedRecordIdentifiesUUIDForManualCleanup() throws {
    try fixture { directory in
      let store = BackupStore(directory: directory, limits: .init(maxRecordBytes: 4))
      let record = try store.capture(
        data: Data([1]), originalURL: URL(fileURLWithPath: "/synthetic/source"))
      let file = directory.appendingPathComponent(record.id.uuidString + ".json")
      try Data(repeating: 0, count: 40_000).write(to: file)
      XCTAssertThrowsError(try store.list()) { error in
        guard case BackupStoreError.corrupt(let id) = error else {
          return XCTFail("Oversized record must identify the removable UUID")
        }
        XCTAssertEqual(id, record.id)
      }
      try store.remove(id: record.id)
      XCTAssertTrue(try store.list().isEmpty)
    }
  }
  func testRecordSymlinkAndInsecurePermissionsCannotBeReadOrDeleted() throws {
    try fixture { directory in
      let store = BackupStore(directory: directory)
      let record = try store.capture(
        data: Data([1]), originalURL: URL(fileURLWithPath: "/synthetic/source"))
      let file = directory.appendingPathComponent(record.id.uuidString + ".json")
      let preserved = try Data(contentsOf: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      XCTAssertThrowsError(try store.read(id: record.id))
      XCTAssertThrowsError(try store.remove(id: record.id))
      try FileManager.default.removeItem(at: file)
      let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-record")
      try preserved.write(to: outside)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
      XCTAssertThrowsError(try store.list())
      XCTAssertThrowsError(try store.read(id: record.id))
      XCTAssertThrowsError(try store.remove(id: record.id))
      XCTAssertEqual(try Data(contentsOf: outside), preserved)
    }
  }
  func testCanonicalEnvelopeRejectsDuplicateKeysAndEncodingMismatch() throws {
    try fixture { directory in
      let store = BackupStore(directory: directory)
      let record = try store.capture(
        data: Data([1]), originalURL: URL(fileURLWithPath: "/synthetic/source"))
      let file = directory.appendingPathComponent(record.id.uuidString + ".json")
      let original = try Data(contentsOf: file)
      var duplicate = Data("{\"version\":1,".utf8)
      duplicate.append(original.dropFirst())
      try duplicate.write(to: file)
      XCTAssertThrowsError(try store.list())
      try original.write(to: file)
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      object["encoding"] = "unsupported"
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
      XCTAssertThrowsError(try store.snapshot(id: record.id))
    }
  }
  func testSymlinkAndInsecureLocationsFailWithoutLeakingPrivatePaths() throws {
    try fixture { directory in
      let target = directory.deletingLastPathComponent().appendingPathComponent(
        "private-sensitive-target")
      try FileManager.default.createDirectory(
        at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
      do {
        _ = try BackupStore(directory: directory).list()
        XCTFail("Symlink accepted")
      } catch {
        XCTAssertFalse(error.localizedDescription.contains("private-sensitive-target"))
        XCTAssertFalse(error.localizedDescription.contains(directory.path))
      }
      try FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
      XCTAssertThrowsError(try BackupStore(directory: directory).list())
    }
  }
}
