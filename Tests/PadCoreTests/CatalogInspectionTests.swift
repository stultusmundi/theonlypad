// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import XCTest

@testable import PadCore

enum CatalogCapabilityFixtureFailure: Error { case noReach, cleanup, wrongThread }
enum CatalogInspectionExpectation { case loaded, corrupt, unsupported }

final class CatalogCapabilityReadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  private var bytesRead = 0
  private var afterReads = 0
  private var beforeWrites = 0
  private var active = 0
  private var mainCalls = 0
  private var overflow = false
  func begin() throws {
    lock.lock()
    defer { lock.unlock() }
    if Thread.isMainThread {
      mainCalls += 1
      throw CatalogCapabilityFixtureFailure.wrongThread
    }
    active += 1
  }
  func end() {
    lock.lock()
    active -= 1
    lock.unlock()
  }
  func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: off_t) -> Int {
    let actual = pread(fd, buffer, count, offset)
    lock.lock()
    defer { lock.unlock() }
    guard reads < 512 else {
      overflow = true
      return actual
    }
    reads += 1
    if actual > 0 { bytesRead += actual }
    return actual
  }
  func afterRead() {
    lock.lock()
    afterReads += 1
    if afterReads > 128 { overflow = true }
    lock.unlock()
  }
  func beforeWrite() {
    lock.lock()
    beforeWrites += 1
    if beforeWrites > 128 { overflow = true }
    lock.unlock()
  }
  func facts() -> (
    reads: Int, bytes: Int, afterReads: Int, writes: Int,
    active: Int, mainCalls: Int, overflow: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (reads, bytesRead, afterReads, beforeWrites, active, mainCalls, overflow)
  }
}

@MainActor final class CatalogCapabilityFixture {
  static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
  // Literal supported wire, independently authored; no candidate encoder builds expectations.
  static let supported = Data(
    ##"{"version":1,"generation":7,"profiles":[{"revision":3,"definition":{"version":1,"id":"00000000-0000-4000-8000-000000000099","name":"Seed","fileExtensions":["capability"],"keywords":["IF"],"lineComment":"//","blockComment":{"opening":"/*","closing":"*/"},"quotes":[{"opening":"\"","closing":"\"","escape":"\\","multiline":false}],"highlightDecimalNumbers":false,"indentation":{"kind":"spaces","width":3}}}],"overrides":[{"language":"swift","lineComment":{"kind":"literal","value":"#"},"blockComment":{"kind":"literal","value":{"opening":"/*","closing":"*/"}},"indentation":{"kind":"tabs","width":3}}]}"##
      .utf8)
  let root: URL
  let directory: URL
  let probe = CatalogCapabilityReadProbe()
  var file: URL { directory.appendingPathComponent("Profiles.json") }
  init(bytes: Data?) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CatalogCapability-" + UUID().uuidString)
    let directory = root.appendingPathComponent("Languages")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      if let bytes {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("Profiles.json")
        try bytes.write(to: file)
        guard chmod(file.path, 0o600) == 0 else { throw CatalogCapabilityFixtureFailure.cleanup }
      }
    } catch {
      try FileManager.default.removeItem(at: root)
      throw error
    }
    self.root = root
    self.directory = directory
  }
  func io<T: Sendable>(_ body: @escaping @Sendable (CustomLanguageStore) throws -> T)
    async throws -> T
  {
    let directory = directory
    let probe = probe
    var hooks = CustomLanguageStoreHooks()
    hooks.read = { probe.read($0, $1, $2, $3) }
    hooks.afterRead = { probe.afterRead() }
    hooks.beforeWrite = { probe.beforeWrite() }
    let store = CustomLanguageStore(directory: directory, hooks: hooks)
    return try await Task.detached {
      try probe.begin()
      defer { probe.end() }
      return try body(store)
    }.value
  }
  func cleanup() throws {
    let facts = probe.facts()
    guard facts.active == 0, !facts.overflow else { throw CatalogCapabilityFixtureFailure.cleanup }
    try FileManager.default.removeItem(at: root)
  }
  static func changed(_ old: String, to new: String, in bytes: Data? = nil) throws -> Data {
    let text = String(decoding: bytes ?? supported, as: UTF8.self)
    guard text.components(separatedBy: old).count == 2 else {
      throw CatalogCapabilityFixtureFailure.noReach
    }
    return Data(text.replacingOccurrences(of: old, with: new).utf8)
  }
}

@MainActor final class CustomLanguageCatalogInspectionTests: XCTestCase {
  private func withFixture(
    _ bytes: Data?,
    _ body: @MainActor (CatalogCapabilityFixture) async throws -> Void
  ) async throws {
    let fixture = try CatalogCapabilityFixture(bytes: bytes)
    var primary: Error?
    do { try await body(fixture) } catch { primary = error }
    do { try fixture.cleanup() } catch {
      XCTFail("Owned fixture cleanup failed separately: \(error)")
      if let primary { throw primary }
      throw error
    }
    if let primary { throw primary }
  }
  private func classify(_ bytes: Data, as expected: CatalogInspectionExpectation) async throws {
    try await withFixture(bytes) { fixture in
      let before = try Data(contentsOf: fixture.file)
      var metadata = stat()
      guard lstat(fixture.file.path, &metadata) == 0 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      var directoryBefore = stat()
      guard lstat(fixture.directory.path, &directoryBefore) == 0,
        directoryBefore.st_mode & S_IFMT == S_IFDIR
      else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      let childrenBefore = try FileManager.default.contentsOfDirectory(
        atPath: fixture.directory.path
      ).sorted()
      let actual: LanguageCatalogInspection
      do { actual = try await fixture.io { try $0.inspect() } } catch {
        // No invented result/token, no normalization of unimplemented or unexpected errors.
        if error as? CustomLanguageStoreError == .unimplemented {
          throw CatalogCapabilityFixtureFailure.noReach
        }
        // Observe the genuine failed call without replacing its error or classification.
        let failureFacts = fixture.probe.facts()
        XCTAssertGreaterThan(failureFacts.reads, 0, "NO_REACH: failed-call actual primitive read")
        XCTAssertGreaterThanOrEqual(failureFacts.bytes, bytes.count)
        XCTAssertGreaterThan(
          failureFacts.afterReads, 0, "NO_REACH: failed-call stable-read boundary")
        XCTAssertEqual(failureFacts.mainCalls, 0)
        XCTAssertFalse(failureFacts.overflow)
        XCTAssertEqual(failureFacts.active, 0, "The failed detached operation must have settled")
        XCTAssertEqual(failureFacts.writes, 0)
        let diagnostic =
          "CATALOG_INSPECTION_THROW reads=\(failureFacts.reads) bytes=\(failureFacts.bytes) stable=\(failureFacts.afterReads) main=\(failureFacts.mainCalls) active=\(failureFacts.active) writes=\(failureFacts.writes) overflow=\(failureFacts.overflow ? 1 : 0)"
        if diagnostic.utf8.count <= 256 && diagnostic.utf8.allSatisfy({ $0 < 128 }) {
          print(diagnostic)
        } else {
          XCTFail("Failed-call scalar diagnostic exceeded its fixed ASCII bound")
          print("CATALOG_INSPECTION_THROW unavailable=1")
        }
        do {
          XCTAssertEqual(try Data(contentsOf: fixture.file), before)
          var failedLeaf = stat()
          var failedDirectory = stat()
          guard lstat(fixture.file.path, &failedLeaf) == 0,
            lstat(fixture.directory.path, &failedDirectory) == 0
          else {
            throw CatalogCapabilityFixtureFailure.noReach
          }
          XCTAssertEqual(failedLeaf.st_dev, metadata.st_dev)
          XCTAssertEqual(failedLeaf.st_ino, metadata.st_ino)
          XCTAssertEqual(failedLeaf.st_uid, metadata.st_uid)
          XCTAssertEqual(failedLeaf.st_mode, metadata.st_mode)
          XCTAssertEqual(failedLeaf.st_nlink, metadata.st_nlink)
          XCTAssertEqual(failedLeaf.st_size, metadata.st_size)
          XCTAssertEqual(failedLeaf.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_sec)
          XCTAssertEqual(failedLeaf.st_mtimespec.tv_nsec, metadata.st_mtimespec.tv_nsec)
          XCTAssertEqual(failedLeaf.st_ctimespec.tv_sec, metadata.st_ctimespec.tv_sec)
          XCTAssertEqual(failedLeaf.st_ctimespec.tv_nsec, metadata.st_ctimespec.tv_nsec)
          XCTAssertEqual(failedDirectory.st_dev, directoryBefore.st_dev)
          XCTAssertEqual(failedDirectory.st_ino, directoryBefore.st_ino)
          XCTAssertEqual(failedDirectory.st_uid, directoryBefore.st_uid)
          XCTAssertEqual(failedDirectory.st_mode, directoryBefore.st_mode)
          XCTAssertEqual(failedDirectory.st_nlink, directoryBefore.st_nlink)
          XCTAssertEqual(failedDirectory.st_mtimespec.tv_sec, directoryBefore.st_mtimespec.tv_sec)
          XCTAssertEqual(failedDirectory.st_mtimespec.tv_nsec, directoryBefore.st_mtimespec.tv_nsec)
          XCTAssertEqual(failedDirectory.st_ctimespec.tv_sec, directoryBefore.st_ctimespec.tv_sec)
          XCTAssertEqual(failedDirectory.st_ctimespec.tv_nsec, directoryBefore.st_ctimespec.tv_nsec)
          XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(),
            childrenBefore)
        } catch {
          // Observation failure is reported separately; the original inspect error still wins.
          XCTFail("Failed-call preservation observation could not complete")
        }
        throw error
      }
      let facts = fixture.probe.facts()
      XCTAssertGreaterThan(facts.reads, 0, "NO_REACH: actual owned primitive read")
      XCTAssertGreaterThanOrEqual(facts.bytes, bytes.count)
      XCTAssertGreaterThan(facts.afterReads, 0, "NO_REACH: real stable-read boundary")
      XCTAssertEqual(facts.mainCalls, 0)
      XCTAssertFalse(facts.overflow)
      guard facts.reads > 0, facts.bytes >= bytes.count, facts.afterReads > 0,
        facts.mainCalls == 0, !facts.overflow
      else { throw CatalogCapabilityFixtureFailure.noReach }
      switch (expected, actual) {
      case (.loaded, .loaded(let loaded)):
        XCTAssertEqual(loaded.snapshot.generation, 7)
        XCTAssertEqual(
          loaded.snapshot.resolve(
            selection: .manual(.custom(CatalogCapabilityFixture.id)),
            filename: "", builtinDetected: .plainText
          ).definitionRevision, 3)
      case (.corrupt, .corrupt(let inspection)):
        XCTAssertEqual(inspection.rawBytes, bytes)
      case (.unsupported, .unsupported(let inspection)):
        XCTAssertEqual(inspection.rawBytes, bytes)
      default:
        XCTFail("Real inspection returned the wrong classification")
      }
      XCTAssertEqual(facts.writes, 0)
      XCTAssertEqual(try Data(contentsOf: fixture.file), before)
      var after = stat()
      guard lstat(fixture.file.path, &after) == 0 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      var directoryAfter = stat()
      guard lstat(fixture.directory.path, &directoryAfter) == 0 else {
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(directoryAfter.st_dev, directoryBefore.st_dev)
      XCTAssertEqual(directoryAfter.st_ino, directoryBefore.st_ino)
      XCTAssertEqual(directoryAfter.st_uid, directoryBefore.st_uid)
      XCTAssertEqual(directoryAfter.st_mode, directoryBefore.st_mode)
      XCTAssertEqual(directoryAfter.st_nlink, directoryBefore.st_nlink)
      XCTAssertEqual(directoryAfter.st_mtimespec.tv_sec, directoryBefore.st_mtimespec.tv_sec)
      XCTAssertEqual(directoryAfter.st_mtimespec.tv_nsec, directoryBefore.st_mtimespec.tv_nsec)
      XCTAssertEqual(directoryAfter.st_ctimespec.tv_sec, directoryBefore.st_ctimespec.tv_sec)
      XCTAssertEqual(directoryAfter.st_ctimespec.tv_nsec, directoryBefore.st_ctimespec.tv_nsec)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(),
        childrenBefore)
      XCTAssertEqual(after.st_dev, metadata.st_dev)
      XCTAssertEqual(after.st_ino, metadata.st_ino)
      XCTAssertEqual(after.st_mode, metadata.st_mode)
      XCTAssertEqual(after.st_uid, metadata.st_uid)
      XCTAssertEqual(after.st_nlink, metadata.st_nlink)
      XCTAssertEqual(after.st_size, metadata.st_size)
      XCTAssertEqual(after.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_sec)
      XCTAssertEqual(after.st_mtimespec.tv_nsec, metadata.st_mtimespec.tv_nsec)
      XCTAssertEqual(after.st_ctimespec.tv_sec, metadata.st_ctimespec.tv_sec)
      XCTAssertEqual(after.st_ctimespec.tv_nsec, metadata.st_ctimespec.tv_nsec)
    }
  }

  // Stage inspection1: genuine loaded controls and known-shape corruption, no fabricated token.
  func testKnownSchemaInvalidAndMissingOrSupportedInspectionRemainDistinct() async throws {
    try await classify(CatalogCapabilityFixture.supported, as: .loaded)
    let badName = try CatalogCapabilityFixture.changed(#""name":"Seed""#, to: #""name":7"#)
    try await classify(badName, as: .corrupt)
    for bytes in [Data("broken".utf8), Data(#"{"version":1,"version":1}"#.utf8)] {
      try await classify(bytes, as: .unsupported)
    }
    try await withFixture(nil) { fixture in
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
      let result = try await fixture.io { try $0.inspect() }
      guard case .loaded(let loaded) = result else {
        XCTFail("Real missing-store read must yield genuine loaded empty0")
        throw CatalogCapabilityFixtureFailure.noReach
      }
      XCTAssertEqual(loaded.snapshot.generation, 0)
      XCTAssertTrue(loaded.snapshot.definitions.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
      XCTAssertEqual(fixture.probe.facts().writes, 0)
    }
  }

  func testRootAndNestedFutureOrNoncanonicalVersionsAreNeverRepairCapabilities() async throws {
    for version in ["2", "1e0", "1.0", #""1""#] {
      let root = try CatalogCapabilityFixture.changed(
        #"{"version":1,"generation":7"#,
        to: #"{"version":"# + version + #","generation":7"#)
      try await classify(root, as: .unsupported)
      let nested = try CatalogCapabilityFixture.changed(
        #""definition":{"version":1,"id""#,
        to: #""definition":{"version":"# + version + #","id""#)
      try await classify(nested, as: .unsupported)
    }
  }

  func testUnknownRootOrRecordFieldsDominateInvalidEarlierCounters() async throws {
    for bytes in [
      try CatalogCapabilityFixture.changed(
        #""generation":7"#, to: #""generation":-1,"future":{"keep":true}"#),
      try CatalogCapabilityFixture.changed(
        #""revision":3,"definition""#,
        to: #""revision":-1,"future":{"keep":true},"definition""#),
    ] { try await classify(bytes, as: .unsupported) }
    try await classify(
      CatalogCapabilityFixture.changed(
        #""generation":7"#,
        to: #""generation":-1"#), as: .corrupt)
  }

  func testUnknownDefinitionQuoteBlockOrIndentationFieldsPreserveFutureMetadata() async throws {
    let cases = [
      try CatalogCapabilityFixture.changed(#""name":"Seed""#, to: #""name":7,"futureRule":true"#),
      try CatalogCapabilityFixture.changed(
        #""multiline":false"#, to: #""multiline":false,"futureQuote":true"#),
      try CatalogCapabilityFixture.changed(
        #""blockComment":{"opening":"/*","closing":"*/"}"#,
        to: #""blockComment":{"opening":"/*","closing":"*/","futureBlock":true}"#),
      try CatalogCapabilityFixture.changed(
        #""kind":"spaces","width":3"#,
        to: #""kind":"spaces","width":-1,"futureIndent":true"#),
      try CatalogCapabilityFixture.changed(
        #""kind":"spaces","width":3"#,
        to: #""kind":"futureIndent","width":3"#),
      try CatalogCapabilityFixture.changed(#""name":"Seed""#, to: #""name":{"futureName":"keep"}"#),
    ]
    for bytes in cases { try await classify(bytes, as: .unsupported) }
    try await classify(
      CatalogCapabilityFixture.changed(
        #""name":"Seed""#,
        to: #""name":7"#), as: .corrupt)
  }

  func testUnknownOverridePolicyDiscriminatorsFieldsAndLanguageAreUnsupported() async throws {
    let cases = [
      try CatalogCapabilityFixture.changed(
        #""language":"swift""#, to: #""language":"futureLanguage""#),
      try CatalogCapabilityFixture.changed(
        #""language":"swift""#,
        to: #""language":"swift","futureOverride":true"#),
      try CatalogCapabilityFixture.changed(
        ##""lineComment":{"kind":"literal","value":"#"}"##,
        to: ##""lineComment":{"kind":"futureLine","value":"#"}"##),
      try CatalogCapabilityFixture.changed(
        ##""lineComment":{"kind":"literal","value":"#"}"##,
        to: ##""lineComment":{"kind":"literal","value":"#","futureLine":true}"##),
      try CatalogCapabilityFixture.changed(
        #""blockComment":{"kind":"literal","value":{"opening":"/*","closing":"*/"}}"#,
        to: #""blockComment":{"kind":"futureBlock","value":{"opening":"/*","closing":"*/"}}"#),
      try CatalogCapabilityFixture.changed(
        #""blockComment":{"kind":"literal","value":{"opening":"/*","closing":"*/"}}"#,
        to:
          #""blockComment":{"kind":"literal","value":{"opening":"/*","closing":"*/","futurePair":true}}"#
      ),
      try CatalogCapabilityFixture.changed(
        #""kind":"tabs","width":3"#, to: #""kind":"futurePolicy","width":3"#),
      try CatalogCapabilityFixture.changed(
        #""kind":"tabs","width":3"#,
        to: #""kind":"tabs","width":0,"futurePolicy":true"#),
      try CatalogCapabilityFixture.changed(
        ##""lineComment":{"kind":"literal","value":"#"}"##,
        to: ##""lineComment":{"kind":"inherit","value":"#"}"##),
    ]
    for bytes in cases { try await classify(bytes, as: .unsupported) }
    for width in ["0", "3e0", "3.0", #""3""#] {
      let bytes = try CatalogCapabilityFixture.changed(
        #""kind":"tabs","width":3"#,
        to: #""kind":"tabs","width":"# + width)
      try await classify(bytes, as: .corrupt)
    }
  }
}
