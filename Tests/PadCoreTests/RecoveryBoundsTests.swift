import Foundation
import XCTest

@testable import PadCore

final class RecoveryBoundsTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func small(count: Int = 8, entries: Int = 32, restored: Int = 100) -> RecoveryLimits {
    RecoveryLimits(
      maximumSnapshotUTF16: 100, maximumEnvelopeBytes: 1_024,
      maximumSnapshots: count, maximumDirectoryEntries: entries, maximumRestoredUTF16: restored)
  }
  func testOversizedEnvelopeIsPreservedAndNotQuarantined() throws {
    let root = try directory()
    let store = try RecoveryStore(directory: root, limits: small())
    let file = root.appendingPathComponent(UUID().uuidString + ".json")
    FileManager.default.createFile(
      atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 64 * 1_024 * 1_024)
    try handle.close()
    XCTAssertThrowsError(try store.loadAll()) {
      XCTAssertEqual($0 as? RecoveryError, .resourceLimit)
    }
    XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 64 * 1_024 * 1_024)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
  }
  func testValidOversizedTextAndSaveFailureKeepOriginalBytes() throws {
    let root = try directory()
    let generous = try RecoveryStore(directory: root)
    var snapshot = RecoverySnapshot(
      id: UUID(), text: String(repeating: "x", count: 101), encoding: .utf8, hasBOM: false)
    try generous.save(snapshot)
    let file = root.appendingPathComponent(snapshot.id.uuidString + ".json")
    let original = try Data(contentsOf: file)
    let limited = try RecoveryStore(directory: root, limits: small())
    XCTAssertThrowsError(try limited.loadAll()) {
      XCTAssertEqual($0 as? RecoveryError, .resourceLimit)
    }
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertThrowsError(try limited.save(snapshot))
    XCTAssertEqual(try Data(contentsOf: file), original)
    snapshot.text = "small"
    try limited.save(snapshot)
    XCTAssertEqual(try limited.loadAll(), [snapshot])
  }
  func testAggregateAndInventoryLimitsDoNotLoseLaterSnapshots() throws {
    let root = try directory()
    let generous = try RecoveryStore(directory: root)
    let snapshots = (0..<3).map { _ in
      RecoverySnapshot(
        id: UUID(), text: String(repeating: "x", count: 40), encoding: .utf8, hasBOM: false)
    }
    for snapshot in snapshots { try generous.save(snapshot) }
    XCTAssertThrowsError(try RecoveryStore(directory: root, limits: small(count: 2)).loadAll())
    XCTAssertThrowsError(try RecoveryStore(directory: root, limits: small(restored: 100)).loadAll())
    XCTAssertThrowsError(try RecoveryStore(directory: root, limits: small(entries: 2)).loadAll())
    XCTAssertEqual(Set(try generous.loadAll().map(\.id)), Set(snapshots.map(\.id)))
  }
  func testCorruptionReportIsNewOnlyAndRemovalDoesNotReadOversize() throws {
    let root = try directory()
    let store = try RecoveryStore(directory: root, limits: small())
    let snapshot = RecoverySnapshot(id: UUID(), text: "e\u{301}😀", encoding: .utf8, hasBOM: false)
    try store.save(snapshot)
    let badID = UUID()
    let bad = root.appendingPathComponent(badID.uuidString + ".json")
    FileManager.default.createFile(
      atPath: bad.path, contents: Data("invalid".utf8), attributes: [.posixPermissions: 0o600])
    let report = try store.loadReport()
    XCTAssertEqual(report.snapshots, [snapshot])
    XCTAssertEqual(report.quarantinedCount, 1)
    XCTAssertEqual(try store.loadReport().quarantinedCount, 0)
    FileManager.default.createFile(
      atPath: bad.path, contents: Data(repeating: 1, count: 2_048),
      attributes: [.posixPermissions: 0o600])
    try store.remove(id: badID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
  }
  func testCumulativeEnvelopeReadBudgetPreservesAllOriginals() throws {
    let root = try directory()
    let generous = try RecoveryStore(directory: root)
    for _ in 0..<3 {
      try generous.save(
        RecoverySnapshot(
          id: UUID(), text: "short", encoding: .utf8, hasBOM: false,
          originalPath: String(repeating: "p", count: 300)))
    }
    XCTAssertThrowsError(try RecoveryStore(directory: root, limits: small()).loadAll()) {
      XCTAssertEqual($0 as? RecoveryError, .resourceLimit)
    }
    XCTAssertEqual(try generous.loadAll().count, 3)
  }
}
