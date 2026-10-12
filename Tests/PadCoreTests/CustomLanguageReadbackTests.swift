import Darwin
import Foundation
import XCTest

@testable import PadCore

private enum ReadbackControlFault: Error, Equatable {
  case sentinel, excessiveCallbacks
}

/// Test-only state; every mutable field is read/written under this lock.
private final class ReadbackBoundaryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var reads: [Data] = []
  private var prewrite = false
  private var overflow = false

  func noteRead(_ bytes: Data) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard reads.count < 2, bytes.count <= CustomLanguageStore.maximumBytes else {
      overflow = true
      throw ReadbackControlFault.excessiveCallbacks
    }
    reads.append(bytes)
    return reads.count
  }

  func noteBeforeWrite() throws {
    lock.lock()
    defer { lock.unlock() }
    guard reads.count == 1, !prewrite else {
      overflow = true
      throw ReadbackControlFault.excessiveCallbacks
    }
    prewrite = true
  }

  func snapshot() -> (reads: [Data], prewrite: Bool, overflow: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (reads, prewrite, overflow)
  }
}

final class CustomLanguageReadbackTests: XCTestCase {
  func testConfirmedWriteThenReadbackFaultReturnsTypedUnconfirmedAndRequiresFreshReceipt() throws {
    let directory = try catalogPrivateDirectory()
    let file = directory.appendingPathComponent("Profiles.json")
    try catalogInstall(CatalogTestFixture.originalBytes, in: directory)
    let plain = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(plain) else { return }
    XCTAssertEqual(old.snapshot.generation, 7)
    XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, 3)
    XCTAssertEqual(try Data(contentsOf: file), CatalogTestFixture.originalBytes)

    let probe = ReadbackBoundaryProbe()
    var hooks = CustomLanguageStoreHooks()
    hooks.beforeWrite = { try probe.noteBeforeWrite() }
    hooks.afterRead = {
      let call = try probe.noteRead(Data(contentsOf: file))
      if call == 2 { throw ReadbackControlFault.sentinel }
    }
    var returnedReceipt = false
    var unconfirmed: CustomLanguageReadbackUnconfirmed?
    do {
      _ = try CustomLanguageStore(directory: directory, hooks: hooks).save(
        CatalogTestFixture.draft(generation: 7, name: "Own write"), expected: old)
      returnedReceipt = true
    } catch let outcome as CustomLanguageReadbackUnconfirmed {
      unconfirmed = outcome
    } catch {
      XCTFail("Post-write read failure needs typed readback-unconfirmed outcome, got \(error)")
    }
    XCTAssertFalse(
      returnedReceipt, "A failed readback cannot return confirmed current read authority")
    let reached = probe.snapshot()
    XCTAssertEqual(
      reached.reads.count, 2, "Both genuine save-internal stable-read boundaries must execute")
    XCTAssertTrue(reached.prewrite, "The real prewrite callback must execute before readback")
    XCTAssertFalse(reached.overflow)
    XCTAssertEqual(reached.reads.first, CatalogTestFixture.originalBytes)
    let disk = try Data(contentsOf: file)
    XCTAssertNotEqual(disk, CatalogTestFixture.originalBytes)
    XCTAssertEqual(reached.reads.last, disk)
    guard let fresh = catalogLoad(plain) else { return }
    XCTAssertEqual(fresh.snapshot.generation, 8)
    XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 4)
    XCTAssertEqual(fresh.snapshot.definitions.first?.name, "Own write")
    XCTAssertEqual(old.snapshot.generation, 7)
    XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, 3)
    catalogRejects(
      {
        _ = try plain.save(CatalogTestFixture.draft(generation: 7, name: "Stale"), expected: old)
      }, "Post-publication failure never renews the old receipt")
    XCTAssertEqual(try Data(contentsOf: file), disk)
    XCTAssertNotNil(unconfirmed, "The dedicated sentinel must not escape as an unwrapped raw error")
    guard let unconfirmed else { return }
    XCTAssertEqual(unconfirmed.attemptedBytes, disk)
    XCTAssertEqual(unconfirmed.underlyingError as? ReadbackControlFault, .sentinel)
    XCTAssertFalse(unconfirmed.underlyingError is CustomLanguagePublicationUncertain)
  }

  func testReadbackReplacementPreservesCompetingBytesAndReturnsNoCurrentReceipt() throws {
    let directory = try catalogPrivateDirectory()
    let file = directory.appendingPathComponent("Profiles.json")
    try catalogInstall(CatalogTestFixture.originalBytes, in: directory)
    let plain = CustomLanguageStore(directory: directory)
    guard let old = catalogLoad(plain) else { return }
    XCTAssertEqual(old.snapshot.generation, 7)
    XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, 3)
    // Independent synthetic JSON; not encoded by the candidate or derived from its attempted bytes.
    let competingText = CatalogTestFixture.originalText
      .replacingOccurrences(of: #""generation":7"#, with: #""generation":9"#)
      .replacingOccurrences(of: #""revision":3"#, with: #""revision":5"#)
      .replacingOccurrences(of: #""name":"Demo""#, with: #""name":"Competing""#)
    let competing = Data(competingText.utf8)
    let validCompetitor = try LanguageCatalogCodec.decode(competing)
    XCTAssertEqual(validCompetitor.generation, 9)
    XCTAssertEqual(CatalogTestFixture.profile(validCompetitor).definitionRevision, 5)
    XCTAssertEqual(validCompetitor.definitions.first?.name, "Competing")

    let probe = ReadbackBoundaryProbe()
    var hooks = CustomLanguageStoreHooks()
    hooks.beforeWrite = { try probe.noteBeforeWrite() }
    hooks.afterRead = {
      let call = try probe.noteRead(Data(contentsOf: file))
      if call == 2 {
        var before = stat()
        guard lstat(file.path, &before) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try competing.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var after = stat()
        guard lstat(file.path, &after) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertNotEqual(
          before.st_ino, after.st_ino, "The actual competing leaf replacement must be reached")
        XCTAssertEqual(after.st_nlink, 1)
      }
    }
    var returnedReceipt = false
    var unconfirmed: CustomLanguageReadbackUnconfirmed?
    do {
      _ = try CustomLanguageStore(directory: directory, hooks: hooks).save(
        CatalogTestFixture.draft(generation: 7, name: "Own write"), expected: old)
      returnedReceipt = true
    } catch let outcome as CustomLanguageReadbackUnconfirmed {
      unconfirmed = outcome
    } catch {
      XCTFail("Readback leaf replacement needs typed unconfirmed outcome, got \(error)")
    }
    XCTAssertFalse(returnedReceipt, "A competing readback leaf cannot become this save's receipt")
    let reached = probe.snapshot()
    XCTAssertEqual(reached.reads.count, 2)
    XCTAssertTrue(reached.prewrite)
    XCTAssertFalse(reached.overflow)
    XCTAssertEqual(reached.reads.first, CatalogTestFixture.originalBytes)
    XCTAssertEqual(
      try Data(contentsOf: file), competing, "Readback failure cannot overwrite the competitor")
    guard let fresh = catalogLoad(plain) else { return }
    XCTAssertEqual(fresh.snapshot.generation, 9)
    XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 5)
    XCTAssertEqual(fresh.snapshot.definitions.first?.name, "Competing")
    XCTAssertEqual(old.snapshot.generation, 7)
    XCTAssertEqual(CatalogTestFixture.profile(old.snapshot).definitionRevision, 3)
    catalogRejects(
      {
        _ = try plain.save(CatalogTestFixture.draft(generation: 7, name: "Stale"), expected: old)
      }, "Both publication and competitor make the old receipt stale")
    XCTAssertEqual(try Data(contentsOf: file), competing)
    XCTAssertNotNil(unconfirmed)
    guard let unconfirmed else { return }
    XCTAssertEqual(unconfirmed.underlyingError as? CustomLanguageStoreError, .changed)
    XCTAssertEqual(unconfirmed.attemptedBytes, reached.reads.last)
    XCTAssertNotEqual(unconfirmed.attemptedBytes, competing)
    let attempted = try LanguageCatalogCodec.decode(unconfirmed.attemptedBytes)
    XCTAssertEqual(attempted.generation, 8)
    XCTAssertEqual(CatalogTestFixture.profile(attempted).definitionRevision, 4)
    XCTAssertEqual(attempted.definitions.first?.name, "Own write")
    XCTAssertFalse(unconfirmed.underlyingError is CustomLanguagePublicationUncertain)
  }
}
