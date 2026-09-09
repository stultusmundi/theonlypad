import CryptoKit
import Foundation
import XCTest

@testable import PadCore

/// Independent legacy writer oracle, kept unchanged when testing optimized framing.
private struct LegacyEnvelope: Codable {
  let version: Int
  let snapshot: RecoverySnapshot
  let checksum: String
}
private func legacyEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return encoder
}
private func legacyBytes(_ snapshot: RecoverySnapshot) throws -> Data {
  let digest = SHA256.hash(data: try legacyEncoder().encode(snapshot))
    .map { String(format: "%02x", $0) }.joined()
  return try legacyEncoder().encode(
    LegacyEnvelope(version: 1, snapshot: snapshot, checksum: digest))
}

final class RecoveryEnvelopeCompatibilityTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func file(_ folder: URL, _ id: UUID) -> URL {
    folder.appendingPathComponent(id.uuidString + ".json")
  }
  private func assertCompatibility(_ snapshot: RecoverySnapshot) throws {
    let directory = try folder()
    let store = try RecoveryStore(directory: directory)
    let reference = try legacyBytes(snapshot)
    try store.save(snapshot)
    let actual = try Data(contentsOf: file(directory, snapshot.id))
    XCTAssertEqual(actual, reference, "Encoded envelope bytes changed")
    let decoded = try JSONDecoder().decode(LegacyEnvelope.self, from: actual)
    XCTAssertEqual(decoded.version, 1)
    XCTAssertEqual(Array(decoded.snapshot.text.utf8), Array(snapshot.text.utf8))
    XCTAssertEqual(
      decoded.snapshot.originalPath.map { Array($0.utf8) },
      snapshot.originalPath.map { Array($0.utf8) })
    let digest = SHA256.hash(data: try legacyEncoder().encode(decoded.snapshot))
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(decoded.checksum, digest)
    let loaded = try XCTUnwrap(store.loadAll().first)
    XCTAssertEqual(Array(loaded.text.utf16), Array(snapshot.text.utf16))
    XCTAssertEqual(loaded.encoding, snapshot.encoding)
    XCTAssertEqual(loaded.hasBOM, snapshot.hasBOM)
  }

  func testLegacyByteEqualityForEscapingUnicodeAndEveryEncoding() throws {
    let controls = String(String.UnicodeScalarView((0...31).map { UnicodeScalar($0)! }))
    let texts = [
      "", "ordinary ASCII\n", controls, "\"\\/ /path/ </script> {\"checksum\":\"fake\"}",
      "a\r\nb\rc\n", "\u{2028}\u{2029}\u{7F}", "e\u{301}é\u{301}\u{327}", "e\u{327}\u{301}",
      "👩🏽‍💻🇬🇷👨‍👩‍👧‍👦", "אבג אַ العربية \u{2067}RTL\u{2069}",
    ]
    let paths: [String?] = [nil, "", "/synthetic/quoted\"slash\\/😀\u{2028}.txt"]
    let id = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    for encoding in DocumentEncoding.allCases {
      for bom in [false, true] {
        for (index, text) in texts.enumerated() {
          try assertCompatibility(
            .init(
              id: id, text: text, encoding: encoding, hasBOM: bom,
              originalPath: paths[index % paths.count]))
        }
      }
    }
  }

  func testSeededMixedCharacterByteEquality() throws {
    let atoms = [
      "a", "/", "\\", "\"", "\0", "\n", "\r\n", "\t", "\u{1F}",
      "e\u{301}", "😀", "👩🏽‍💻", "\u{2028}", "א", "\u{2069}",
    ]
    var seed: UInt64 = 0x5245_434F_5645_5259
    for sample in 0..<64 {
      var text = ""
      for _ in 0..<(sample * 3 + 1) {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        text += atoms[Int(seed % UInt64(atoms.count))]
      }
      try assertCompatibility(
        .init(
          id: UUID(), text: text, encoding: .utf8, hasBOM: false,
          originalPath: sample.isMultiple(of: 2) ? nil : "/synthetic/" + String(text.prefix(80))))
    }
  }

  func testExistingLegacyRecordLoadsAndCanBeReplaced() throws {
    let directory = try folder()
    let store = try RecoveryStore(directory: directory)
    let old = RecoverySnapshot(
      id: UUID(), text: "legacy /\0e\u{301}\r\n", encoding: .utf16BE,
      hasBOM: true, originalPath: "/synthetic/old.txt")
    let path = file(directory, old.id)
    try legacyBytes(old).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    XCTAssertEqual(Array(try XCTUnwrap(store.loadAll().first).text.utf8), Array(old.text.utf8))
    var newer = old
    newer.text += "🧪"
    try store.save(newer)
    XCTAssertEqual(try Data(contentsOf: path), try legacyBytes(newer))
  }

  func testExactEnvelopeLimitAndOneByteRefusalPreservePreviousRecord() throws {
    let id = UUID()
    let old = RecoverySnapshot(id: id, text: "old", encoding: .utf8, hasBOM: false)
    let snapshot = RecoverySnapshot(
      id: id, text: String(repeating: "\u{1F}/😀", count: 32),
      encoding: .utf8, hasBOM: false)
    let count = try legacyBytes(snapshot).count
    for accepted in [true, false] {
      let directory = try folder()
      let limits = RecoveryLimits(
        maximumSnapshotUTF16: 1000,
        maximumEnvelopeBytes: count - (accepted ? 0 : 1), maximumSnapshots: 4,
        maximumDirectoryEntries: 8, maximumRestoredUTF16: 1000)
      let store = try RecoveryStore(directory: directory, limits: limits)
      try store.save(old)
      let previous = try Data(contentsOf: file(directory, id))
      if accepted {
        try store.save(snapshot)
        XCTAssertEqual(try Data(contentsOf: file(directory, id)), try legacyBytes(snapshot))
      } else {
        XCTAssertThrowsError(try store.save(snapshot)) {
          XCTAssertEqual($0 as? RecoveryError, .resourceLimit)
        }
        XCTAssertEqual(try Data(contentsOf: file(directory, id)), previous)
      }
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path),
        [id.uuidString + ".json"])
    }
  }

  func testFaultsAndUncertainReadbackUseIdenticalEnvelope() throws {
    let directory = try folder()
    let store = try RecoveryStore(directory: directory)
    let old = RecoverySnapshot(id: UUID(), text: "old", encoding: .utf8, hasBOM: false)
    var updated = old
    updated.text = "new /\\\"\0👩🏽‍💻\r\n"
    try store.save(old)
    let original = try Data(contentsOf: file(directory, old.id))
    for fault in [SaveFault.partialWrite, .fileSync, .beforeReplace] {
      XCTAssertThrowsError(try store.save(updated, fault: fault))
      XCTAssertEqual(try Data(contentsOf: file(directory, old.id)), original)
    }
    do {
      try store.save(updated, fault: .directorySync)
      XCTFail("Uncertain publication must still throw")
    } catch FileStoreError.publicationUncertain(let evidence) {
      XCTAssertEqual(try Data(contentsOf: file(directory, old.id)), try legacyBytes(updated))
      try store.validatePublication(evidence, snapshot: updated)
      XCTAssertThrowsError(try store.validatePublication(evidence, snapshot: old))
      try store.save(updated)
      XCTAssertThrowsError(try store.validatePublication(evidence, snapshot: updated))
    }
  }
}
