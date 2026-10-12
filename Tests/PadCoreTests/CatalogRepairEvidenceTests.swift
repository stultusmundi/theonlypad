// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import XCTest

@testable import PadCore

enum CatalogCapabilityInjected: Error, Equatable { case readback }

struct CatalogCapabilityLeaf: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t
  let mode: mode_t
  let owner: uid_t
  let links: nlink_t
  let size: off_t
  let mtimeSeconds: Int
  let mtimeNanos: Int
  let ctimeSeconds: Int
  let ctimeNanos: Int
  init(_ url: URL) throws {
    var s = stat()
    guard lstat(url.path, &s) == 0 else { throw CatalogCapabilityFixtureFailure.noReach }
    device = s.st_dev
    inode = s.st_ino
    mode = s.st_mode
    size = s.st_size
    owner = s.st_uid
    links = s.st_nlink
    mtimeSeconds = s.st_mtimespec.tv_sec
    mtimeNanos = s.st_mtimespec.tv_nsec
    ctimeSeconds = s.st_ctimespec.tv_sec
    ctimeNanos = s.st_ctimespec.tv_nsec
  }
}

final class CatalogCapabilityBoundaryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  private var readbacks = 0
  private var overflow = false
  func beforeWrite() throws {
    lock.lock()
    defer { lock.unlock() }
    guard writes < 16 else {
      overflow = true
      throw CatalogCapabilityFixtureFailure.noReach
    }
    writes += 1
  }
  func throwAfterRealNewLeaf(file: URL, prior: CatalogCapabilityLeaf) throws {
    let now = try CatalogCapabilityLeaf(file)
    lock.lock()
    defer { lock.unlock() }
    if writes > 0 && (now.device != prior.device || now.inode != prior.inode) {
      guard readbacks == 0 else {
        overflow = true
        throw CatalogCapabilityFixtureFailure.noReach
      }
      readbacks = 1
      throw CatalogCapabilityInjected.readback
    }
  }
  func facts() -> (writes: Int, readbacks: Int, overflow: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (writes, readbacks, overflow)
  }
}

@MainActor extension CatalogCapabilityFixture {
  func operation<T: Sendable>(
    fault: SaveFault? = nil,
    beforeWrite: (@Sendable () throws -> Void)? = nil,
    afterRead: (@Sendable () throws -> Void)? = nil,
    _ body: @escaping @Sendable (CustomLanguageStore) throws -> T
  ) async throws -> T {
    let directory = directory
    let probe = probe
    var hooks = CustomLanguageStoreHooks()
    hooks.read = { probe.read($0, $1, $2, $3) }
    hooks.afterRead = {
      probe.afterRead()
      try afterRead?()
    }
    hooks.beforeWrite = {
      probe.beforeWrite()
      try beforeWrite?()
    }
    hooks.fault = fault
    let store = CustomLanguageStore(directory: directory, hooks: hooks)
    return try await Task.detached {
      try probe.begin()
      defer { probe.end() }
      return try body(store)
    }.value
  }
  func genuineCorruptInspection() async throws -> CustomLanguageRepairInspection {
    let before = probe.facts()
    let actual = try await io { try $0.inspect() }
    let after = probe.facts()
    XCTAssertGreaterThan(after.reads, before.reads, "NO_REACH: actual inspection primitive")
    XCTAssertGreaterThan(after.afterReads, before.afterReads)
    guard after.reads > before.reads, after.afterReads > before.afterReads,
      !after.overflow, after.mainCalls == 0
    else { throw CatalogCapabilityFixtureFailure.noReach }
    guard case .corrupt(let token) = actual else {
      XCTFail("NO_REACH: genuine known-corrupt inspection required before repair")
      throw CatalogCapabilityFixtureFailure.noReach
    }
    XCTAssertEqual(token.rawBytes, try Data(contentsOf: file))
    return token
  }
  func actualLoad() async throws -> LoadedLanguageCatalog {
    try await io { try $0.load() }
  }
  func replaceLeaf(with bytes: Data) async throws {
    let destination = file
    let replacement = directory.appendingPathComponent("Independent-" + UUID().uuidString)
    try await Task.detached {
      try AtomicFileStore().save(bytes, to: replacement, expected: nil)
      guard rename(replacement.path, destination.path) == 0 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
    }.value
  }
}

@MainActor func catalogCapabilityWithFixture(
  _ bytes: Data?,
  _ body: @MainActor (CatalogCapabilityFixture) async throws -> Void
) async throws {
  let fixture = try CatalogCapabilityFixture(bytes: bytes)
  var primary: Error?
  do { try await body(fixture) } catch { primary = error }
  do { try fixture.cleanup() } catch {
    XCTFail("Owned cleanup failed separately: \(error)")
    if let primary { throw primary }
    throw error
  }
  if let primary { throw primary }
}

@MainActor func catalogCapabilityReject(
  _ operation: @MainActor () async throws -> Void
) async throws -> any Error {
  do {
    try await operation()
    XCTFail("A stale/unsafe capability operation returned success")
    throw CatalogCapabilityFixtureFailure.noReach
  } catch {
    if error is CatalogCapabilityFixtureFailure { throw error }
    if error as? CustomLanguageStoreError == .unimplemented {
      throw CatalogCapabilityFixtureFailure.noReach
    }
    XCTAssertFalse(
      error is CustomLanguagePublicationUncertain,
      "Prepublication refusal cannot invent a new publication")
    XCTAssertFalse(
      error is CustomLanguageReadbackUnconfirmed,
      "Prepublication refusal cannot invent confirmed write/readback failure")
    return error
  }
}

@MainActor func catalogCapabilityWire(_ file: URL, equals expected: Data) throws {
  // Independent literal expected wire; NSDictionary comparison is semantic object equality.
  // It does not prove raw numeric spelling or exact wire bytes. Strict fresh loads and
  // separate exact attempted-byte/disk checks retain those distinct responsibilities.
  let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
  let wanted = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
  XCTAssertNotNil(wanted, "Independent expected fixture must be an object")
  XCTAssertNotNil(actual, "Actual catalog wire must be an object")
  XCTAssertEqual(actual, wanted)
}

@MainActor func catalogCapabilityReplacement() throws
  -> (definitions: [LiteralLanguageDefinition], overrides: [BuiltInLanguageOverride])
{
  // Validated arguments from an independently authored fixed wire, never an expected encoder.
  let value = try LanguageCatalogCodec.decode(CatalogCapabilityFixture.supported)
  return (value.definitions, value.overrides)
}

@MainActor func catalogCapabilityDraft(from old: LoadedLanguageCatalog) throws
  -> LanguageCatalogSnapshot
{
  let d = try LiteralLanguageDefinition(
    id: CatalogCapabilityFixture.id, name: "Changed",
    fileExtensions: ["capability"], keywords: ["IF"], lineComment: "//",
    blockComment: .init(opening: "/*", closing: "*/"),
    quotes: [LiteralQuoteRule(opening: "\"", closing: "\"", escape: "\\", multiline: false)],
    highlightDecimalNumbers: false, indentation: .spaces(width: 3))
  return try LanguageCatalogSnapshot(
    definitions: [d], overrides: old.snapshot.overrides,
    generation: old.snapshot.generation)
}

@MainActor func catalogCapabilityAttemptedBytes() throws -> Data {
  var b = try CatalogCapabilityFixture.changed(#""generation":7"#, to: #""generation":8"#)
  b = try CatalogCapabilityFixture.changed(#""revision":3"#, to: #""revision":4"#, in: b)
  return try CatalogCapabilityFixture.changed(#""name":"Seed""#, to: #""name":"Changed""#, in: b)
}

@MainActor func catalogCapabilityPending(_ fixture: CatalogCapabilityFixture) async throws
  -> CustomLanguagePublicationUncertain
{
  let old = try await fixture.actualLoad()
  XCTAssertEqual(old.snapshot.generation, 7)
  XCTAssertEqual(old.snapshot.definitions.first?.name, "Seed")
  guard old.snapshot.generation == 7, old.snapshot.definitions.first?.name == "Seed" else {
    throw CatalogCapabilityFixtureFailure.noReach
  }
  let draft = try catalogCapabilityDraft(from: old)
  let before = fixture.probe.facts().writes
  var pending: CustomLanguagePublicationUncertain?
  do {
    _ = try await fixture.operation(fault: .directorySync) { try $0.save(draft, expected: old) }
  } catch let actual as CustomLanguagePublicationUncertain { pending = actual } catch {
    throw error
  }
  XCTAssertEqual(fixture.probe.facts().writes, before + 1)
  XCTAssertNotNil(pending, "NO_REACH: genuine actual directory-sync uncertainty")
  guard let pending, fixture.probe.facts().writes == before + 1 else {
    throw CatalogCapabilityFixtureFailure.noReach
  }
  XCTAssertEqual(pending.evidence.destination.standardizedFileURL, fixture.file.standardizedFileURL)
  XCTAssertEqual(pending.attemptedBytes, try Data(contentsOf: fixture.file))
  try catalogCapabilityWire(fixture.file, equals: catalogCapabilityAttemptedBytes())
  let destination = fixture.file
  try await Task.detached {
    try AtomicFileStore().validatePublication(pending.evidence, expected: pending.attemptedBytes)
    XCTAssertEqual(
      pending.evidence.destination.standardizedFileURL, destination.standardizedFileURL)
  }.value
  return pending
}

@MainActor final class CustomLanguageCatalogRepairTests: XCTestCase {
  private func corrupt() throws -> Data {
    try CatalogCapabilityFixture.changed(#""name":"Seed""#, to: #""name":7"#)
  }

  func testExplicitRepairStartsLineageOneAndFreshReadAuthenticatesActualBytes() async throws {
    try await catalogCapabilityWithFixture(corrupt()) { f in
      let token = try await f.genuineCorruptInspection()
      let replacement = try catalogCapabilityReplacement()
      let before = f.probe.facts().writes
      let actual = try await f.operation {
        try $0.repair(
          definitions: replacement.definitions,
          overrides: replacement.overrides, matching: token)
      }
      XCTAssertEqual(f.probe.facts().writes, before + 1)
      XCTAssertEqual(actual.snapshot.generation, 1)
      XCTAssertEqual(
        actual.snapshot.resolve(
          selection: .manual(.custom(CatalogCapabilityFixture.id)),
          filename: "", builtinDetected: .plainText
        ).definitionRevision, 1)
      var expected = try CatalogCapabilityFixture.changed(
        #""generation":7"#, to: #""generation":1"#)
      expected = try CatalogCapabilityFixture.changed(
        #""revision":3"#, to: #""revision":1"#, in: expected)
      try catalogCapabilityWire(f.file, equals: expected)
      let fresh = try await f.actualLoad()
      XCTAssertEqual(fresh.snapshot.generation, 1)
      XCTAssertEqual(fresh.snapshot.definitions, replacement.definitions)
      XCTAssertEqual(fresh.snapshot.overrides, replacement.overrides)
      _ = try await catalogCapabilityReject {
        _ = try await f.operation {
          try $0.repair(
            definitions: replacement.definitions, overrides: replacement.overrides,
            matching: token)
        }
      }
      try catalogCapabilityWire(f.file, equals: expected)
    }
  }

  func testOldRepairTokenRefusesNewInodeDifferentBytesAndMeasuredMetadataABA() async throws {
    for change in 0..<3 {
      let original = try corrupt()
      try await catalogCapabilityWithFixture(original) { f in
        let token = try await f.genuineCorruptInspection()
        let before = try CatalogCapabilityLeaf(f.file)
        let replacement = try catalogCapabilityReplacement()
        var expected = original
        if change == 0 { try await f.replaceLeaf(with: original) }
        if change == 1 {
          expected = try CatalogCapabilityFixture.changed(
            #""generation":7"#,
            to: #""generation":9"#, in: original)
          try expected.write(to: f.file)
        }
        if change == 2 {
          guard chmod(f.file.path, 0o400) == 0, chmod(f.file.path, 0o600) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        }
        let changed = try CatalogCapabilityLeaf(f.file)
        XCTAssertNotEqual(changed, before, "NO_REACH: actual leaf identity/metadata changed")
        guard changed != before else { throw CatalogCapabilityFixtureFailure.noReach }
        if change == 0 {
          XCTAssertNotEqual(changed.inode, before.inode)
          guard changed.inode != before.inode else { throw CatalogCapabilityFixtureFailure.noReach }
        }
        let writes = f.probe.facts().writes
        _ = try await catalogCapabilityReject {
          _ = try await f.operation {
            try $0.repair(
              definitions: replacement.definitions, overrides: replacement.overrides,
              matching: token)
          }
        }
        XCTAssertEqual(f.probe.facts().writes, writes)
        XCTAssertEqual(try Data(contentsOf: f.file), expected)
        XCTAssertEqual(try CatalogCapabilityLeaf(f.file), changed)
      }
    }
  }

  func testRepairTokenCannotCrossStoreOrReplacedActualParent() async throws {
    let original = try corrupt()
    try await catalogCapabilityWithFixture(original) { source in
      let token = try await source.genuineCorruptInspection()
      let replacement = try catalogCapabilityReplacement()
      try await catalogCapabilityWithFixture(original) { other in
        _ = try await catalogCapabilityReject {
          _ = try await other.operation {
            try $0.repair(
              definitions: replacement.definitions, overrides: replacement.overrides,
              matching: token)
          }
        }
        XCTAssertEqual(other.probe.facts().writes, 0)
        XCTAssertEqual(try Data(contentsOf: other.file), original)
      }
      let archived = source.root.appendingPathComponent("Retained-original-parent")
      let parentBefore = try CatalogCapabilityLeaf(source.directory)
      guard rename(source.directory.path, archived.path) == 0 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      try FileManager.default.createDirectory(
        at: source.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try original.write(to: source.file)
      guard chmod(source.file.path, 0o600) == 0 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      let parentAfter = try CatalogCapabilityLeaf(source.directory)
      XCTAssertNotEqual(parentBefore.inode, parentAfter.inode)
      guard parentBefore.inode != parentAfter.inode else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      _ = try await catalogCapabilityReject {
        _ = try await source.operation {
          try $0.repair(
            definitions: replacement.definitions, overrides: replacement.overrides,
            matching: token)
        }
      }
      XCTAssertEqual(try Data(contentsOf: source.file), original)
      XCTAssertEqual(
        try Data(contentsOf: archived.appendingPathComponent("Profiles.json")), original)
      XCTAssertEqual(source.probe.facts().writes, 0)
    }
  }

  func testReadOnlyInspectionIsNotRepairAuthorityAndUnsafeOrBudgetEndpointsIssueNoToken()
    async throws
  {
    let original = try corrupt()
    try await catalogCapabilityWithFixture(original) { f in
      guard chmod(f.file.path, 0o400) == 0 else { throw CatalogCapabilityFixtureFailure.noReach }
      let token = try await f.genuineCorruptInspection()
      let replacement = try catalogCapabilityReplacement()
      let error = try await catalogCapabilityReject {
        _ = try await f.operation {
          try $0.repair(
            definitions: replacement.definitions, overrides: replacement.overrides,
            matching: token)
        }
      }
      guard let typed = error as? FileStoreError, case .readOnly = typed else {
        XCTFail("A safe read-only leaf must refuse explicitly as readOnly")
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(try CatalogCapabilityLeaf(f.file).mode & 0o777, 0o400)
      XCTAssertEqual(try Data(contentsOf: f.file), original)
      XCTAssertEqual(f.probe.facts().writes, 0)
    }
    for variant in 0..<7 {
      try await catalogCapabilityWithFixture(original) { f in
        if variant == 0 {
          guard chmod(f.file.path, 0o644) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        } else if variant == 1 {
          guard link(f.file.path, f.root.appendingPathComponent("Other-link").path) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        } else if variant == 2 {
          let real = f.root.appendingPathComponent("Real-leaf")
          guard rename(f.file.path, real.path) == 0, symlink(real.path, f.file.path) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        } else if variant == 3 {
          guard unlink(f.file.path) == 0, mkfifo(f.file.path, 0o600) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        } else {
          let bytes: Data
          if variant == 4 {
            bytes = Data(repeating: 32, count: CustomLanguageStore.maximumBytes + 1)
          } else if variant == 5 {
            bytes = Data(
              (String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)).utf8)
          } else {
            bytes = Data(
              ("[" + Array(repeating: "0", count: 100_001).joined(separator: ",") + "]").utf8)
          }
          try bytes.write(to: f.file)
        }
        let before = try CatalogCapabilityLeaf(f.file)
        _ = try await catalogCapabilityReject { _ = try await f.io { try $0.inspect() } }
        XCTAssertEqual(try CatalogCapabilityLeaf(f.file), before)
        XCTAssertEqual(f.probe.facts().writes, 0)
      }
    }
  }

  func testRepairPrepublicationFaultsAndRealCompetitorDoNotReturnAuthority() async throws {
    let original = try corrupt()
    let replacement = try catalogCapabilityReplacement()
    let faults: [SaveFault] = [.beforeReplace, .partialWrite, .fileSync]
    for fault in faults {
      try await catalogCapabilityWithFixture(original) { f in
        let token = try await f.genuineCorruptInspection()
        let before = try CatalogCapabilityLeaf(f.file)
        let boundary = CatalogCapabilityBoundaryProbe()
        let actualFault = try await catalogCapabilityReject {
          _ = try await f.operation(fault: fault, beforeWrite: { try boundary.beforeWrite() }) {
            try $0.repair(
              definitions: replacement.definitions, overrides: replacement.overrides,
              matching: token)
          }
        }
        switch fault {
        case .beforeReplace:
          let matches: Bool
          if let typed = actualFault as? FileStoreError, case .injectedFailure = typed {
            matches = true
          } else {
            matches = false
          }
          XCTAssertTrue(matches, "NO_REACH: actual beforeReplace injectedFailure signature")
          guard matches else { throw actualFault }
        case .partialWrite:
          let posix = actualFault as NSError
          XCTAssertEqual(posix.domain, NSPOSIXErrorDomain)
          XCTAssertEqual(posix.code, Int(ENOSPC))
          guard posix.domain == NSPOSIXErrorDomain, posix.code == Int(ENOSPC) else {
            throw actualFault
          }
        case .fileSync:
          let posix = actualFault as NSError
          XCTAssertEqual(posix.domain, NSPOSIXErrorDomain)
          XCTAssertEqual(posix.code, Int(EIO))
          guard posix.domain == NSPOSIXErrorDomain, posix.code == Int(EIO) else {
            throw actualFault
          }
        default:
          XCTFail("NO_REACH: this fixture only selects three declared Atomic faults")
          throw actualFault
        }
        XCTAssertEqual(boundary.facts().writes, 1, "NO_REACH: real prewrite")
        guard boundary.facts().writes == 1 else { throw CatalogCapabilityFixtureFailure.noReach }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        XCTAssertEqual(try CatalogCapabilityLeaf(f.file), before)
        XCTAssertFalse(
          try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
            .contains(where: { $0.hasPrefix(".theonlypad-") }))
      }
    }
    try await catalogCapabilityWithFixture(original) { f in
      let token = try await f.genuineCorruptInspection()
      let competitor = Data(#"{"version":1,"generation":99,"profiles":[],"overrides":[]}"#.utf8)
      let file = f.file
      let boundary = CatalogCapabilityBoundaryProbe()
      _ = try await catalogCapabilityReject {
        _ = try await f.operation(beforeWrite: {
          try boundary.beforeWrite()
          try AtomicFileStore().save(competitor, to: file, expected: original)
        }) {
          try $0.repair(
            definitions: replacement.definitions, overrides: replacement.overrides,
            matching: token)
        }
      }
      XCTAssertEqual(boundary.facts().writes, 1)
      guard boundary.facts().writes == 1 else { throw CatalogCapabilityFixtureFailure.noReach }
      XCTAssertEqual(try Data(contentsOf: f.file), competitor)
    }
  }

  func testRepairGenuineUncertaintyAndPostconfirmedReadFailureStayDistinct() async throws {
    let original = try corrupt()
    let replacement = try catalogCapabilityReplacement()
    try await catalogCapabilityWithFixture(original) { f in
      let token = try await f.genuineCorruptInspection()
      var pending: CustomLanguagePublicationUncertain?
      do {
        _ = try await f.operation(fault: .directorySync) {
          try $0.repair(
            definitions: replacement.definitions, overrides: replacement.overrides,
            matching: token)
        }
      } catch let actual as CustomLanguagePublicationUncertain { pending = actual } catch {
        throw error
      }
      XCTAssertNotNil(pending)
      guard let pending else { throw CatalogCapabilityFixtureFailure.noReach }
      XCTAssertEqual(f.probe.facts().writes, 1)
      XCTAssertEqual(pending.attemptedBytes, try Data(contentsOf: f.file))
      try await Task.detached {
        try AtomicFileStore().validatePublication(
          pending.evidence, expected: pending.attemptedBytes)
      }.value
      let fresh = try await f.actualLoad()
      XCTAssertEqual(fresh.snapshot.generation, 1)
      XCTAssertEqual(fresh.snapshot.definitions, replacement.definitions)
    }
    try await catalogCapabilityWithFixture(original) { f in
      let token = try await f.genuineCorruptInspection()
      let prior = try CatalogCapabilityLeaf(f.file)
      let file = f.file
      let boundary = CatalogCapabilityBoundaryProbe()
      var outcome: CustomLanguageReadbackUnconfirmed?
      do {
        _ = try await f.operation(
          beforeWrite: { try boundary.beforeWrite() },
          afterRead: { try boundary.throwAfterRealNewLeaf(file: file, prior: prior) }
        ) {
          try $0.repair(
            definitions: replacement.definitions, overrides: replacement.overrides,
            matching: token)
        }
      } catch let actual as CustomLanguageReadbackUnconfirmed { outcome = actual } catch {
        throw error
      }
      XCTAssertEqual(boundary.facts().readbacks, 1)
      XCTAssertNotNil(outcome)
      guard let outcome, boundary.facts().readbacks == 1 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(outcome.underlyingError as? CatalogCapabilityInjected, .readback)
      XCTAssertEqual(outcome.attemptedBytes, try Data(contentsOf: f.file))
      XCTAssertFalse(outcome.underlyingError is CustomLanguagePublicationUncertain)
      let fresh = try await f.actualLoad()
      XCTAssertEqual(fresh.snapshot.generation, 1)
    }
  }
}

@MainActor final class CustomLanguageCatalogEvidenceTests: XCTestCase {
  func testValidateOriginalUncertainPublicationNeverWritesOrAdvancesCatalog() async throws {
    try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { f in
      let pending = try await catalogCapabilityPending(f)
      let before = try CatalogCapabilityLeaf(f.file)
      let writes = f.probe.facts().writes
      let loaded = try await f.actualLoad()
      let readsBefore = f.probe.facts()
      try await f.operation { try $0.validatePendingPublication(pending) }
      let readsAfter = f.probe.facts()
      XCTAssertGreaterThan(readsAfter.reads, readsBefore.reads, "NO_REACH: real verification read")
      XCTAssertGreaterThan(readsAfter.afterReads, readsBefore.afterReads)
      guard readsAfter.reads > readsBefore.reads, readsAfter.afterReads > readsBefore.afterReads
      else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(f.probe.facts().writes, writes)
      XCTAssertEqual(try CatalogCapabilityLeaf(f.file), before)
      XCTAssertEqual(try Data(contentsOf: f.file), pending.attemptedBytes)
      XCTAssertEqual(loaded.snapshot.generation, 8)
      XCTAssertEqual(loaded.snapshot.definitions.first?.name, "Changed")
      // Void validation has no returned acknowledgement or writable loaded receipt.
    }
  }

  func testMeasuredSameByteNewInodeRefusesBothEvidenceMethodsDespiteFreshRead() async throws {
    try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { f in
      let pending = try await catalogCapabilityPending(f)
      let before = try CatalogCapabilityLeaf(f.file)
      try await f.replaceLeaf(with: pending.attemptedBytes)
      let now = try CatalogCapabilityLeaf(f.file)
      XCTAssertNotEqual(now.inode, before.inode)
      guard now.inode != before.inode else { throw CatalogCapabilityFixtureFailure.noReach }
      let fresh = try await f.actualLoad()
      XCTAssertEqual(fresh.snapshot.generation, 8)
      XCTAssertEqual(fresh.snapshot.definitions.first?.name, "Changed")
      let writes = f.probe.facts().writes
      _ = try await catalogCapabilityReject {
        try await f.operation { try $0.validatePendingPublication(pending) }
      }
      _ = try await catalogCapabilityReject {
        _ = try await f.operation { try $0.retryPendingPublication(pending) }
      }
      XCTAssertEqual(f.probe.facts().writes, writes)
      XCTAssertEqual(try CatalogCapabilityLeaf(f.file), now)
      XCTAssertEqual(try Data(contentsOf: f.file), pending.attemptedBytes)
    }
  }

  func testPublicationEvidenceCannotCrossExactStoreDestinationEvenForSameBytes() async throws {
    try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { source in
      let pending = try await catalogCapabilityPending(source)
      try await catalogCapabilityWithFixture(pending.attemptedBytes) { other in
        let old = try CatalogCapabilityLeaf(other.file)
        _ = try await catalogCapabilityReject {
          try await other.operation { try $0.validatePendingPublication(pending) }
        }
        _ = try await catalogCapabilityReject {
          _ = try await other.operation { try $0.retryPendingPublication(pending) }
        }
        XCTAssertEqual(other.probe.facts().writes, 0)
        XCTAssertEqual(try CatalogCapabilityLeaf(other.file), old)
        XCTAssertEqual(try Data(contentsOf: other.file), pending.attemptedBytes)
      }
      try await source.operation { try $0.validatePendingPublication(pending) }
    }
  }

  func testExactByteRetryPerformsNewRealPublicationWithoutRepeatingLogicalEdit() async throws {
    try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { f in
      let pending = try await catalogCapabilityPending(f)
      let prior = try CatalogCapabilityLeaf(f.file)
      let writes = f.probe.facts().writes
      let actual = try await f.operation { try $0.retryPendingPublication(pending) }
      let current = try CatalogCapabilityLeaf(f.file)
      XCTAssertEqual(f.probe.facts().writes, writes + 1)
      XCTAssertNotEqual(current.inode, prior.inode, "NO_REACH: genuine new Atomic publication")
      guard current.inode != prior.inode, f.probe.facts().writes == writes + 1 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(try Data(contentsOf: f.file), pending.attemptedBytes)
      try catalogCapabilityWire(f.file, equals: catalogCapabilityAttemptedBytes())
      XCTAssertEqual(actual.snapshot.generation, 8)
      XCTAssertEqual(
        actual.snapshot.resolve(
          selection: .manual(.custom(CatalogCapabilityFixture.id)),
          filename: "", builtinDetected: .plainText
        ).definitionRevision, 4)
      let fresh = try await f.actualLoad()
      XCTAssertEqual(fresh.snapshot.generation, 8)
      XCTAssertEqual(fresh.snapshot.definitions, actual.snapshot.definitions)
      _ = try await catalogCapabilityReject {
        try await f.operation { try $0.validatePendingPublication(pending) }
      }
    }
  }

  func testRetryPrepublicationFailureKeepsOldEvidenceButNewUncertaintyBindsNewLeaf() async throws {
    try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { f in
      let pending = try await catalogCapabilityPending(f)
      let prior = try CatalogCapabilityLeaf(f.file)
      let boundary = CatalogCapabilityBoundaryProbe()
      let actualFault = try await catalogCapabilityReject {
        _ = try await f.operation(
          fault: .beforeReplace,
          beforeWrite: { try boundary.beforeWrite() }
        ) { try $0.retryPendingPublication(pending) }
      }
      let injectedFailure: Bool
      if let typed = actualFault as? FileStoreError, case .injectedFailure = typed {
        injectedFailure = true
      } else {
        injectedFailure = false
      }
      XCTAssertTrue(
        injectedFailure, "NO_REACH: actual retry beforeReplace injectedFailure signature")
      guard injectedFailure else { throw actualFault }
      XCTAssertEqual(boundary.facts().writes, 1)
      guard boundary.facts().writes == 1 else { throw CatalogCapabilityFixtureFailure.noReach }
      XCTAssertEqual(try CatalogCapabilityLeaf(f.file), prior)
      try await f.operation { try $0.validatePendingPublication(pending) }
      var next: CustomLanguagePublicationUncertain?
      do {
        _ = try await f.operation(fault: .directorySync) { try $0.retryPendingPublication(pending) }
      } catch let actual as CustomLanguagePublicationUncertain { next = actual } catch {
        throw error
      }
      XCTAssertNotNil(next)
      guard let next else { throw CatalogCapabilityFixtureFailure.noReach }
      let now = try CatalogCapabilityLeaf(f.file)
      XCTAssertNotEqual(now.inode, prior.inode)
      guard now.inode != prior.inode else { throw CatalogCapabilityFixtureFailure.noReach }
      XCTAssertEqual(next.attemptedBytes, pending.attemptedBytes)
      XCTAssertEqual(next.attemptedBytes, try Data(contentsOf: f.file))
      try await Task.detached {
        try AtomicFileStore().validatePublication(next.evidence, expected: next.attemptedBytes)
      }.value
      _ = try await catalogCapabilityReject {
        try await f.operation { try $0.validatePendingPublication(pending) }
      }
    }
  }

  func testRetryReadbackUnconfirmedIsEvidenceFreeAndUnsafeOrCompetitorRefusalsPreserveLeaf()
    async throws
  {
    try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { f in
      let pending = try await catalogCapabilityPending(f)
      let prior = try CatalogCapabilityLeaf(f.file)
      let file = f.file
      let boundary = CatalogCapabilityBoundaryProbe()
      var outcome: CustomLanguageReadbackUnconfirmed?
      do {
        _ = try await f.operation(
          beforeWrite: { try boundary.beforeWrite() },
          afterRead: { try boundary.throwAfterRealNewLeaf(file: file, prior: prior) }
        ) {
          try $0.retryPendingPublication(pending)
        }
      } catch let actual as CustomLanguageReadbackUnconfirmed { outcome = actual } catch {
        throw error
      }
      XCTAssertEqual(boundary.facts().readbacks, 1)
      XCTAssertNotNil(outcome)
      guard let outcome, boundary.facts().readbacks == 1 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(outcome.underlyingError as? CatalogCapabilityInjected, .readback)
      XCTAssertEqual(outcome.attemptedBytes, pending.attemptedBytes)
      XCTAssertEqual(try Data(contentsOf: f.file), pending.attemptedBytes)
      XCTAssertFalse(outcome.underlyingError is CustomLanguagePublicationUncertain)
      let fresh = try await f.actualLoad()
      XCTAssertEqual(fresh.snapshot.generation, 8)
      _ = try await catalogCapabilityReject {
        try await f.operation { try $0.validatePendingPublication(pending) }
      }
    }
    for variant in 0..<3 {
      try await catalogCapabilityWithFixture(CatalogCapabilityFixture.supported) { f in
        let pending = try await catalogCapabilityPending(f)
        let competitor = Data(#"{"version":1,"generation":99,"profiles":[],"overrides":[]}"#.utf8)
        if variant == 0 {
          guard chmod(f.file.path, 0o644) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        } else if variant == 1 {
          let archived = f.root.appendingPathComponent("Original")
          guard rename(f.directory.path, archived.path) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
          try FileManager.default.createDirectory(
            at: f.directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          try pending.attemptedBytes.write(to: f.file)
          guard chmod(f.file.path, 0o600) == 0 else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
        }
        let boundary = CatalogCapabilityBoundaryProbe()
        let file = f.file
        _ = try await catalogCapabilityReject {
          _ = try await f.operation(beforeWrite: {
            try boundary.beforeWrite()
            if variant == 2 {
              try AtomicFileStore().save(competitor, to: file, expected: pending.attemptedBytes)
            }
          }) { try $0.retryPendingPublication(pending) }
        }
        XCTAssertEqual(
          try Data(contentsOf: f.file), variant == 2 ? competitor : pending.attemptedBytes)
        if variant == 2 {
          XCTAssertEqual(boundary.facts().writes, 1)
          guard boundary.facts().writes == 1 else { throw CatalogCapabilityFixtureFailure.noReach }
        } else {
          XCTAssertEqual(boundary.facts().writes, 0)
        }
      }
    }
  }
}
