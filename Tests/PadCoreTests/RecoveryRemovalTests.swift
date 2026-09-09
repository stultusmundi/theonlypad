import Darwin
import Foundation
import XCTest

@testable import PadCore

final class RecoveryRemovalTests: XCTestCase {
  private func fixture() throws -> (URL, RecoveryStore, UUID, Data) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try RecoveryStore(directory: directory)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    try store.save(.init(id: id, text: "snapshot 👩🏽‍💻\r\n", encoding: .utf8, hasBOM: true))
    return (
      directory, store, id,
      try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json"))
    )
  }
  func testConfirmedRemovalAndAlreadyAbsent() throws {
    let (directory, store, id, _) = try fixture()
    let receipt = try store.removeChecked(id: id)
    XCTAssertEqual(receipt.evidence.documentID, id)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(id.uuidString + ".json").path))
    _ = try store.removeChecked(id: id)
  }
  func testBeforeRenameFailurePreservesExactBytes() throws {
    let (directory, store, id, bytes) = try fixture()
    XCTAssertThrowsError(try store.removeChecked(id: id, fault: .beforeRename))
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json")), bytes)
  }
  func testAfterRenameUncertaintyRetainsOwnedBytesAndCanFinish() throws {
    let (directory, store, id, bytes) = try fixture()
    do {
      _ = try store.removeChecked(id: id, fault: .afterRename)
      XCTFail()
    } catch RecoveryRemovalError.uncertain(let evidence) {
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      XCTAssertEqual(files.count, 1)
      XCTAssertEqual(try Data(contentsOf: files[0]), bytes)
      _ = try store.finishCheckedRemoval(evidence)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }
  func testSyncFailureIsUncertainNotConfirmedRemoval() throws {
    let (_, store, id, _) = try fixture()
    do {
      _ = try store.removeChecked(id: id, fault: .directorySync)
      XCTFail()
    } catch RecoveryRemovalError.uncertain(let evidence) {
      _ = try store.finishCheckedRemoval(evidence)
    }
  }
  func testReplacementBeforeRenameIsPreserved() throws {
    let (directory, store, id, _) = try fixture()
    let target = directory.appendingPathComponent(id.uuidString + ".json")
    let replacement = Data("unrelated private file".utf8)
    do {
      _ = try store.removeChecked(
        id: id,
        boundaryHook: { boundary in
          if case .beforeRename = boundary {
            try FileManager.default.removeItem(at: target)
            try replacement.write(to: target)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: target.path)
          }
        })
      XCTFail()
    } catch RecoveryRemovalError.uncertain(let evidence) {
      XCTAssertThrowsError(try store.finishCheckedRemoval(evidence))
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      XCTAssertTrue(try files.contains { try Data(contentsOf: $0) == replacement })
    }
  }
  func testParentRetargetBeforeRenamePreservesBothTrees() throws {
    let (directory, store, id, bytes) = try fixture()
    let moved = directory.appendingPathExtension("original")
    addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
    XCTAssertThrowsError(
      try store.removeChecked(
        id: id,
        boundaryHook: { boundary in
          if case .beforeRename = boundary {
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.createDirectory(
              at: directory, withIntermediateDirectories: false,
              attributes: [.posixPermissions: 0o700])
          }
        }))
    XCTAssertEqual(
      try Data(contentsOf: moved.appendingPathComponent(id.uuidString + ".json")), bytes)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }
  func testRecreatedCanonicalAndQuarantineBothPreservedAndInventoryBlocked() throws {
    let (directory, store, id, bytes) = try fixture()
    let canonical = directory.appendingPathComponent(id.uuidString + ".json")
    let replacement = Data("replacement".utf8)
    do {
      _ = try store.removeChecked(
        id: id,
        boundaryHook: { boundary in
          if case .afterRename = boundary {
            try replacement.write(to: canonical)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: canonical.path)
          }
        })
      XCTFail()
    } catch RecoveryRemovalError.uncertain(let evidence) {
      XCTAssertThrowsError(try store.finishCheckedRemoval(evidence))
      XCTAssertEqual(try Data(contentsOf: canonical), replacement)
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      XCTAssertTrue(try files.contains { try Data(contentsOf: $0) == bytes })
      XCTAssertThrowsError(try store.loadReport())
      XCTAssertThrowsError(
        try store.save(.init(id: UUID(), text: "new", encoding: .utf8, hasBOM: false)))
    }
  }
  func testOldRemovalEvidenceCannotDeleteFreshSnapshot() throws {
    let (directory, store, id, _) = try fixture()
    let receipt = try store.removeChecked(id: id)
    try store.save(.init(id: id, text: "new", encoding: .utf8, hasBOM: false))
    let fresh = try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json"))
    XCTAssertThrowsError(try store.finishCheckedRemoval(receipt.evidence))
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json")), fresh)
  }
  func testParentRetargetAfterRenameRetainsArtifactAndRejectsRetry() throws {
    let (directory, store, id, bytes) = try fixture()
    let moved = directory.appendingPathExtension("old")
    addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
    do {
      _ = try store.removeChecked(
        id: id,
        boundaryHook: { boundary in
          if case .afterRename = boundary {
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.createDirectory(
              at: directory, withIntermediateDirectories: false,
              attributes: [.posixPermissions: 0o700])
          }
        })
      XCTFail()
    } catch RecoveryRemovalError.uncertain(let evidence) {
      XCTAssertThrowsError(try store.finishCheckedRemoval(evidence))
      let retained = try FileManager.default.contentsOfDirectory(
        at: moved, includingPropertiesForKeys: nil)
      XCTAssertEqual(retained.count, 1)
      XCTAssertEqual(try Data(contentsOf: retained[0]), bytes)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }
  func testReadOnlyCapacityInventoryDoesNotQuarantineCorruption() throws {
    let (directory, store, _, _) = try fixture()
    let invalid = directory.appendingPathComponent(UUID().uuidString + ".json")
    let bytes = Data("invalid snapshot".utf8)
    try bytes.write(to: invalid)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalid.path)
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    XCTAssertThrowsError(try store.loadReport(quarantineInvalid: false))
    XCTAssertEqual(try Data(contentsOf: invalid), bytes)
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), before)
  }
  func testPreflightEncodingLimitHasNoRecordSideEffects() throws {
    let (directory, _, id, bytes) = try fixture()
    let store = try RecoveryStore(directory: directory, limits: .init(maximumEnvelopeBytes: 400))
    XCTAssertThrowsError(
      try store.preflightSave(
        .init(id: id, text: String(repeating: "\u{0}", count: 100), encoding: .utf8, hasBOM: false))
    )
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json")), bytes)
  }
  func testSymbolicLinkIsRefusedAndTargetPreserved() throws {
    let (directory, store, id, bytes) = try fixture()
    let original = directory.appendingPathComponent(id.uuidString + ".json")
    let target = directory.appendingPathComponent("target")
    try FileManager.default.moveItem(at: original, to: target)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
    XCTAssertThrowsError(try store.removeChecked(id: id))
    XCTAssertEqual(try Data(contentsOf: target), bytes)
  }
}
