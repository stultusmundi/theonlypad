// SPDX-License-Identifier: MIT
// New API clients only; no LanguageProfileTransfer implementation is supplied here.
import Darwin
import Foundation
import XCTest

@testable import PadCore

private enum ProfileTransferFixtureError: Error { case noReach, overflow, cleanup }
private enum ProfileTransferWire {
  static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000092")!
  static let imported = Data(
    ###"{"version":1,"id":"00000000-0000-4000-8000-000000000092","name":"Transfer","fileExtensions":["xfer"],"keywords":["café","cafe\u0301"],"lineComment":"//","blockComment":{"opening":"(*","closing":"*)"},"quotes":[],"highlightDecimalNumbers":true,"indentation":{"kind":"spaces","width":2}}"###
      .utf8)
  // Independently written canonical export, never computed with the candidate encoder.
  static let exported = Data(
    ###"{"blockComment":{"closing":"*)","opening":"(*"},"fileExtensions":["xfer"],"highlightDecimalNumbers":true,"id":"00000000-0000-4000-8000-000000000092","indentation":{"kind":"spaces","width":2},"keywords":["café","café"],"lineComment":"//","name":"Transfer","quotes":[],"version":1}"###
      .utf8)
  static let competitor = Data("owned synthetic competitor".utf8)
}
private struct ProfileTransferLeaf: Equatable, Sendable {
  let device: dev_t, inode: ino_t, mode: mode_t, owner: uid_t, links: nlink_t, size: off_t
  let mtimeSeconds: Int, mtimeNanos: Int, ctimeSeconds: Int, ctimeNanos: Int
  init(_ url: URL) throws {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw ProfileTransferFixtureError.noReach }
    device = value.st_dev
    inode = value.st_ino
    mode = value.st_mode
    owner = value.st_uid
    links = value.st_nlink
    size = value.st_size
    mtimeSeconds = value.st_mtimespec.tv_sec
    mtimeNanos = value.st_mtimespec.tv_nsec
    ctimeSeconds = value.st_ctimespec.tv_sec
    ctimeNanos = value.st_ctimespec.tv_nsec
  }
  func sameIdentity(as other: Self) -> Bool { device == other.device && inode == other.inode }
}
private final class ProfileTransferProbe: @unchecked Sendable {
  struct Facts {
    let reads: Int, bytesRead: Int, observed: Int, beforeRead: Int, mutations: Int
    let saves: Int, saveReturns: Int, afterInitial: Int, afterFinal: Int, afterReplace: Int
    let mainCalls: Int, overflow: Bool, cancelled: Bool, atomicError: Error?
  }
  private let lock = NSLock()
  private var reads = 0, bytesRead = 0, observed = 0, beforeRead = 0, mutations = 0
  private var saves = 0, saveReturns = 0, afterInitial = 0, afterFinal = 0, afterReplace = 0
  private var mainCalls = 0, overflow = false, cancelled = false
  private var atomicError: Error?
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  private func increment(_ key: ReferenceWritableKeyPath<ProfileTransferProbe, Int>) {
    lock.lock()
    defer { lock.unlock() }
    if Thread.isMainThread { mainCalls += 1 }
    if self[keyPath: key] < 64 { self[keyPath: key] += 1 } else { overflow = true }
  }
  func observation() { increment(\ProfileTransferProbe.observed) }
  func matchingRead() { increment(\ProfileTransferProbe.beforeRead) }
  func mutation() { increment(\ProfileTransferProbe.mutations) }
  func read(
    _ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, cancelAfterRead: Bool = false
  ) -> Int {
    let actual = Darwin.read(fd, buffer, count)
    increment(\ProfileTransferProbe.reads)
    lock.lock()
    if actual > 0 { bytesRead += actual }
    lock.unlock()
    if cancelAfterRead, actual > 0 { cancel() }
    return actual
  }
  func boundary(_ boundary: SaveBoundary) {
    switch boundary {
    case .afterInitialCheck: increment(\ProfileTransferProbe.afterInitial)
    case .afterFinalCheck: increment(\ProfileTransferProbe.afterFinal)
    case .afterReplace: increment(\ProfileTransferProbe.afterReplace)
    case .beforeReplace: break
    }
  }
  // Wraps only the actual create-only primitive; never returns fabricated evidence or error.
  func save(
    _ bytes: Data, to url: URL, fault: SaveFault? = nil,
    boundary: (@Sendable (SaveBoundary) throws -> Void)? = nil
  ) throws {
    increment(\ProfileTransferProbe.saves)
    do {
      try AtomicFileStore().save(
        bytes, to: url, expected: nil, fault: fault,
        boundaryHook: { point in
          self.boundary(point)
          try boundary?(point)
        })
      increment(\ProfileTransferProbe.saveReturns)
    } catch {
      lock.lock()
      atomicError = error
      lock.unlock()
      throw error
    }
  }
  func facts() -> Facts {
    lock.lock()
    defer { lock.unlock() }
    return Facts(
      reads: reads, bytesRead: bytesRead, observed: observed, beforeRead: beforeRead,
      mutations: mutations, saves: saves, saveReturns: saveReturns, afterInitial: afterInitial,
      afterFinal: afterFinal, afterReplace: afterReplace, mainCalls: mainCalls,
      overflow: overflow, cancelled: cancelled, atomicError: atomicError)
  }
}

@MainActor final class LanguageProfileTransferTests: XCTestCase {
  private func withDirectory(_ body: @MainActor (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProfileTransfer-" + UUID().uuidString)
    guard mkdir(root.path, 0o700) == 0 else { throw ProfileTransferFixtureError.cleanup }
    var primary: Error?
    do { try await body(root) } catch { primary = error }
    var cleanup: Error?
    do { try FileManager.default.removeItem(at: root) } catch {
      cleanup = error
      XCTFail("Owned profile transfer cleanup failed separately: \(error)")
    }
    if let primary { throw primary }
    if let cleanup { throw cleanup }
  }
  private func file(
    _ root: URL, bytes: Data = ProfileTransferWire.imported, name: String = "profile.json"
  ) throws -> URL {
    let url = root.appendingPathComponent(name)
    try bytes.write(to: url)
    guard chmod(url.path, 0o600) == 0 else { throw ProfileTransferFixtureError.cleanup }
    return url
  }
  private func definition() throws -> LiteralLanguageDefinition {
    try LiteralLanguageDefinition(
      id: ProfileTransferWire.id, name: "Transfer", fileExtensions: ["xfer"],
      keywords: ["café", "cafe\u{301}"], lineComment: "//",
      blockComment: .init(opening: "(*", closing: "*)"), quotes: [],
      highlightDecimalNumbers: true, indentation: .spaces(width: 2))
  }
  private func watched(_ probe: ProfileTransferProbe, cancelAfterRead: Bool = false)
    -> LanguageProfileTransferHooks
  {
    var hooks = LanguageProfileTransferHooks()
    var actualProbe = ProbeHooks()
    actualProbe.read = { probe.read($0, $1, $2, cancelAfterRead: cancelAfterRead) }
    hooks.probe = ExternalFileProbe(hooks: actualProbe)
    hooks.afterObservation = { probe.observation() }
    hooks.beforeRead = { probe.matchingRead() }
    hooks.saveNewFile = { try probe.save($0, to: $1) }
    return hooks
  }
  private func sound(_ probe: ProfileTransferProbe) throws {
    let facts = probe.facts()
    XCTAssertEqual(facts.mainCalls, 0)
    XCTAssertFalse(facts.overflow)
    guard facts.mainCalls == 0, !facts.overflow else { throw ProfileTransferFixtureError.noReach }
  }
  private func refused(_ action: @Sendable @escaping () throws -> Void) async -> Error? {
    do {
      try await Task.detached { try action() }.value
      XCTFail("Refused transfer returned success")
      return nil
    } catch { return error }
  }
  private func sameFile(_ url: URL, bytes: Data, leaf: ProfileTransferLeaf) throws {
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    XCTAssertEqual(try ProfileTransferLeaf(url), leaf)
  }

  func testRealImportPreservesStableUUIDRawUTF16AndFile() async throws {
    try await withDirectory { root in
      let url = try self.file(root)
      let leaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
      let probe = ProfileTransferProbe()
      let hooks = self.watched(probe)
      let value = try await Task.detached {
        try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
      }.value
      XCTAssertEqual(value.id, ProfileTransferWire.id)
      XCTAssertEqual(value.name, "Transfer")
      XCTAssertEqual(
        value.keywords.map { Array($0.utf16) }, [[99, 97, 102, 233], [99, 97, 102, 101, 769]])
      XCTAssertEqual(value.lineComment.map { Array($0.utf16) }, [47, 47])
      XCTAssertEqual(value.blockComment?.opening.utf16.map { $0 }, [40, 42])
      XCTAssertEqual(value.blockComment?.closing.utf16.map { $0 }, [42, 41])
      XCTAssertEqual(value.indentation, .spaces(width: 2))
      XCTAssertTrue(value.highlightDecimalNumbers)
      XCTAssertGreaterThan(probe.facts().reads, 0)
      XCTAssertGreaterThan(probe.facts().bytesRead, 0)
      try self.sound(probe)
      try self.sameFile(url, bytes: ProfileTransferWire.imported, leaf: leaf)
    }
  }
  func testDefinition65536BoundaryAnd65537RefusalBeforeMatchingRead() async throws {
    for size in [65536, 65537] {
      try await withDirectory { root in
        let bytes =
          ProfileTransferWire.imported
          + Data(repeating: 32, count: size - ProfileTransferWire.imported.count)
        let url = try self.file(root, bytes: bytes)
        let leaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
        let probe = ProfileTransferProbe()
        var configured = self.watched(probe)
        configured.beforeRead = {
          probe.matchingRead()
          XCTAssertEqual(
            probe.facts().reads, 0, "Metadata first must not compare a nonempty payload")
        }
        let hooks = configured
        if size == 65536 {
          let value = try await Task.detached {
            try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
          }.value
          XCTAssertEqual(value.id, ProfileTransferWire.id)
          XCTAssertGreaterThan(probe.facts().reads, 0)
        } else {
          let error = await self.refused {
            _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
          }
          XCTAssertEqual(error as? LanguageProfileTransferError, .tooLarge)
          XCTAssertEqual(probe.facts().reads, 0)
          XCTAssertEqual(probe.facts().beforeRead, 0)
        }
        try self.sound(probe)
        try self.sameFile(url, bytes: bytes, leaf: leaf)
      }
    }
  }
  func testStrictStandaloneInvalidInputsRefuseWithoutFileMutation() async throws {
    let literal = String(decoding: ProfileTransferWire.imported, as: UTF8.self)
    XCTAssertTrue(literal.contains(#""version":1"#))
    XCTAssertTrue(literal.contains(#""width":2"#))
    guard literal.contains(#""version":1"#), literal.contains(#""width":2"#) else {
      throw ProfileTransferFixtureError.noReach
    }
    let invalid = [
      literal.replacingOccurrences(of: #""version":1"#, with: #""version":2"#),
      literal.replacingOccurrences(of: #""version":1"#, with: #""version":1,"future":true"#),
      literal.replacingOccurrences(of: #""version":1"#, with: #""version":1,"version":1"#),
      literal.replacingOccurrences(of: #""width":2"#, with: #""width":2.0"#), "{", #""\uD800""#,
      String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17),
      "[" + Array(repeating: "0", count: 8193).joined(separator: ",") + "]",
    ]
    for wire in invalid {
      try await withDirectory { root in
        let bytes = Data(wire.utf8)
        let url = try self.file(root, bytes: Data(wire.utf8))
        let leaf = try ProfileTransferLeaf(url)
        let probe = ProfileTransferProbe()
        let hooks = self.watched(probe)
        let error = await self.refused {
          _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
        }
        XCTAssertNotNil(error)
        XCTAssertNotEqual(error as? LanguageProfileError, .unimplemented)
        XCTAssertGreaterThan(probe.facts().reads, 0)
        try self.sound(probe)
        try self.sameFile(url, bytes: bytes, leaf: leaf)
      }
    }
  }
  func testUnsafeLeafAndActualMaterializationPolicyRefuseWithoutPayloadRead() async throws {
    try await withDirectory { root in
      let target = try self.file(root)
      let leaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
      let link = root.appendingPathComponent("link.json")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      for (url, problem) in [
        (link, DiskLocationProblem.symbolicLink), (root, .nonregular),
        (root.appendingPathComponent("missing"), .missing),
        (URL(string: "https://invalid.example/profile.json")!, .nonregular),
      ] {
        let probe = ProfileTransferProbe()
        let hooks = self.watched(probe)
        let refusal = await self.refused {
          _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
        }
        XCTAssertEqual(refusal as? LanguageProfileTransferError, .unavailable(problem))
        XCTAssertEqual(probe.facts().reads, 0)
        try self.sound(probe)
      }
      let probe = ProfileTransferProbe()
      var ph = ProbeHooks()
      ph.observeGuard = { _ in throw FileMaterializationError.disable(71) }
      ph.read = { probe.read($0, $1, $2) }
      var configured = self.watched(probe)
      configured.probe = ExternalFileProbe(hooks: ph)
      let hooks = configured
      let error = await self.refused {
        _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(from: target)
      }
      if let typed = error as? FileMaterializationError, case .disable(71) = typed {
      } else {
        XCTFail("Actual policy error must propagate")
      }
      XCTAssertEqual(probe.facts().reads, 0)
      try self.sound(probe)
      try self.sameFile(target, bytes: ProfileTransferWire.imported, leaf: leaf)
    }
  }
  func testObservedLeafReplacementGrowthAndShrinkRejectMatchingRead() async throws {
    for mode in 0..<3 {
      try await withDirectory { root in
        let url = try self.file(root)
        let oldLeaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
        let changed =
          mode == 0
          ? ProfileTransferWire.imported
          : (mode == 1 ? ProfileTransferWire.imported + Data([32]) : Data("{}".utf8))
        let probe = ProfileTransferProbe()
        var configured = self.watched(probe)
        configured.afterObservation = {
          probe.observation()
          try AtomicFileStore().save(changed, to: url, expected: ProfileTransferWire.imported)
          let newLeaf = try ProfileTransferLeaf(url)
          XCTAssertFalse(newLeaf.sameIdentity(as: oldLeaf))
          guard !newLeaf.sameIdentity(as: oldLeaf) else {
            throw ProfileTransferFixtureError.noReach
          }
          probe.mutation()
        }
        let hooks = configured
        let error = await self.refused {
          _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
        }
        XCTAssertEqual(probe.facts().mutations, 1)
        guard probe.facts().mutations == 1 else { throw ProfileTransferFixtureError.noReach }
        XCTAssertEqual(error as? ExternalFileProbeError, .observationChanged)
        XCTAssertEqual(probe.facts().reads, 0)
        XCTAssertEqual(try Data(contentsOf: url), changed)
        try self.sound(probe)
      }
    }
  }
  func testObservedParentReplacementRejectsNewSameByteChild() async throws {
    try await withDirectory { root in
      let parent = root.appendingPathComponent("parent")
      let moved = root.appendingPathComponent("old-parent")
      guard mkdir(parent.path, 0o700) == 0 else { throw ProfileTransferFixtureError.cleanup }
      let url = try self.file(parent)
      let oldParent = try ProfileTransferLeaf(parent)
      let probe = ProfileTransferProbe()
      var configured = self.watched(probe)
      configured.afterObservation = {
        probe.observation()
        try FileManager.default.moveItem(at: parent, to: moved)
        guard mkdir(parent.path, 0o700) == 0 else { throw ProfileTransferFixtureError.cleanup }
        try ProfileTransferWire.imported.write(to: url)
        XCTAssertFalse(try ProfileTransferLeaf(parent).sameIdentity(as: oldParent))
        guard try !ProfileTransferLeaf(parent).sameIdentity(as: oldParent) else {
          throw ProfileTransferFixtureError.noReach
        }
        probe.mutation()
      }
      let hooks = configured
      let error = await self.refused {
        _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(from: url)
      }
      XCTAssertEqual(probe.facts().mutations, 1)
      guard probe.facts().mutations == 1 else { throw ProfileTransferFixtureError.noReach }
      XCTAssertEqual(error as? ExternalFileProbeError, .observationChanged)
      XCTAssertEqual(probe.facts().reads, 0)
      XCTAssertEqual(try Data(contentsOf: url), ProfileTransferWire.imported)
      XCTAssertEqual(
        try Data(contentsOf: moved.appendingPathComponent("profile.json")),
        ProfileTransferWire.imported)
      try self.sound(probe)
    }
  }
  func testCancellationBeforeObservationAndBetweenObservationAndRead() async throws {
    for phase in 0..<3 {
      try await withDirectory { root in
        let url = try self.file(root)
        let leaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
        let probe = ProfileTransferProbe()
        var configured = self.watched(probe)
        if phase == 0 { probe.cancel() }
        if phase == 1 {
          configured.afterObservation = {
            probe.observation()
            probe.cancel()
          }
        }
        if phase == 2 {
          configured.beforeRead = {
            probe.matchingRead()
            probe.cancel()
          }
        }
        let hooks = configured
        let error = await self.refused {
          _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(
            from: url, isCancelled: { probe.isCancelled })
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(probe.facts().reads, 0)
        if phase == 0 { XCTAssertEqual(probe.facts().observed, 0) }
        if phase == 1 {
          XCTAssertEqual(probe.facts().observed, 1)
          XCTAssertEqual(probe.facts().beforeRead, 0)
        }
        if phase == 2 { XCTAssertEqual(probe.facts().beforeRead, 1) }
        try self.sound(probe)
        try self.sameFile(url, bytes: ProfileTransferWire.imported, leaf: leaf)
      }
    }
  }
  func testCancellationFromActualReadPreservesFileAndJoinsWorker() async throws {
    try await withDirectory { root in
      let url = try self.file(root)
      let leaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
      let probe = ProfileTransferProbe()
      let hooks = self.watched(probe, cancelAfterRead: true)
      let error = await self.refused {
        _ = try LanguageProfileTransfer(hooks: hooks).importDefinition(
          from: url, isCancelled: { probe.isCancelled })
      }
      let facts = probe.facts()
      XCTAssertGreaterThan(facts.reads, 0)
      XCTAssertGreaterThan(facts.bytesRead, 0)
      XCTAssertTrue(facts.cancelled)
      guard facts.reads > 0, facts.bytesRead > 0, facts.cancelled else {
        throw ProfileTransferFixtureError.noReach
      }
      XCTAssertTrue(error is CancellationError)
      try self.sound(probe)
      try self.sameFile(url, bytes: ProfileTransferWire.imported, leaf: leaf)
    }
  }
  func testDefaultExportExactStandaloneBytesAndExistingFileRefusal() async throws {
    try await withDirectory { root in
      let url = root.appendingPathComponent("export.json")
      let value = try self.definition()
      try await Task.detached { try LanguageProfileTransfer().exportDefinition(value, to: url) }
        .value
      XCTAssertEqual(try Data(contentsOf: url), ProfileTransferWire.exported)
      let leaf = try ProfileTransferLeaf(url)
      let error = await self.refused {
        try LanguageProfileTransfer().exportDefinition(value, to: url)
      }
      if let typed = error as? FileStoreError, case .externalChange = typed {
      } else {
        XCTFail("Existing file must refuse replacement")
      }
      try self.sameFile(url, bytes: ProfileTransferWire.exported, leaf: leaf)
    }
  }
  func testUnsafeExportLeavesSymlinkTargetAndDirectoryUntouched() async throws {
    try await withDirectory { root in
      let target = try self.file(root)
      let leaf = try ProfileTransferLeaf(root.appendingPathComponent("profile.json"))
      let link = root.appendingPathComponent("link.json")
      let value = try self.definition()
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      for url in [link, root] {
        let error = await self.refused {
          try LanguageProfileTransfer().exportDefinition(value, to: url)
        }
        if let typed = error as? FileStoreError, case .unsafeTarget = typed {
        } else {
          XCTFail("Unsafe export must retain typed refusal")
        }
      }
      try self.sameFile(target, bytes: ProfileTransferWire.imported, leaf: leaf)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
  }
  func testRealCompetitorAfterFinalCheckCannotBeOverwritten() async throws {
    try await withDirectory { root in
      let url = root.appendingPathComponent("export.json")
      let value = try self.definition()
      let probe = ProfileTransferProbe()
      var configured = self.watched(probe)
      configured.saveNewFile = { bytes, file in
        try probe.save(
          bytes, to: file,
          boundary: { point in
            if case .afterFinalCheck = point {
              try ProfileTransferWire.competitor.write(to: file)
              probe.mutation()
            }
          })
      }
      let hooks = configured
      let error = await self.refused {
        try LanguageProfileTransfer(hooks: hooks).exportDefinition(value, to: url)
      }
      let facts = probe.facts()
      XCTAssertEqual(facts.mutations, 1)
      XCTAssertEqual(facts.afterFinal, 1)
      guard facts.mutations == 1, facts.afterFinal == 1 else {
        throw ProfileTransferFixtureError.noReach
      }
      let posix = error.map { $0 as NSError }
      XCTAssertEqual(posix?.domain, NSPOSIXErrorDomain)
      XCTAssertEqual(posix?.code, Int(EEXIST))
      XCTAssertEqual(try Data(contentsOf: url), ProfileTransferWire.competitor)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: root.path), ["export.json"])
      try self.sound(probe)
    }
  }
  func testActualPrepublicationExportFaultsLeaveNoDestinationOrAuxiliaryFile() async throws {
    for fault in [SaveFault.beforeWrite, .partialWrite, .fileSync, .beforeReplace] {
      try await withDirectory { root in
        let url = root.appendingPathComponent("export.json")
        let value = try self.definition()
        let probe = ProfileTransferProbe()
        var configured = self.watched(probe)
        configured.saveNewFile = { try probe.save($0, to: $1, fault: fault) }
        let hooks = configured
        let error = await self.refused {
          try LanguageProfileTransfer(hooks: hooks).exportDefinition(value, to: url)
        }
        let facts = probe.facts()
        XCTAssertEqual(facts.saves, 1)
        XCTAssertEqual(facts.afterInitial, 1)
        XCTAssertNotNil(facts.atomicError)
        guard facts.saves == 1, facts.afterInitial == 1, facts.atomicError != nil else {
          throw ProfileTransferFixtureError.noReach
        }
        switch fault {
        case .beforeWrite, .beforeReplace:
          let originalInjected: Bool
          if let actual = facts.atomicError as? FileStoreError, case .injectedFailure = actual {
            originalInjected = true
          } else {
            originalInjected = false
          }
          XCTAssertTrue(originalInjected)
          guard originalInjected else { throw ProfileTransferFixtureError.noReach }
          if let actual = error as? FileStoreError, case .injectedFailure = actual {
          } else {
            XCTFail("Preserve original injected error")
          }
        case .partialWrite, .fileSync:
          let expectedCode: Int
          switch fault {
          case .partialWrite: expectedCode = Int(ENOSPC)
          case .fileSync: expectedCode = Int(EIO)
          default: throw ProfileTransferFixtureError.noReach
          }
          let original = facts.atomicError.map { $0 as NSError }
          XCTAssertEqual(original?.domain, NSPOSIXErrorDomain)
          XCTAssertEqual(original?.code, expectedCode)
          guard original?.domain == NSPOSIXErrorDomain, original?.code == expectedCode else {
            throw ProfileTransferFixtureError.noReach
          }
          let forwarded = error.map { $0 as NSError }
          XCTAssertEqual(forwarded?.domain, original?.domain)
          XCTAssertEqual(forwarded?.code, original?.code)
        default: throw ProfileTransferFixtureError.noReach
        }
        XCTAssertNotNil(error)
        XCTAssertFalse(error is LanguageProfileExportUncertain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        try self.sound(probe)
      }
    }
  }
  func testExportCancellationBeforeStartAndLateSuccessfulPublicationOutcome() async throws {
    for late in [false, true] {
      try await withDirectory { root in
        let url = root.appendingPathComponent("export.json")
        let value = try self.definition()
        let probe = ProfileTransferProbe()
        var configured = self.watched(probe)
        configured.saveNewFile = { bytes, file in
          try probe.save(
            bytes, to: file,
            boundary: { point in
              if case .afterReplace = point, late { probe.cancel() }
            })
        }
        if !late { probe.cancel() }
        let hooks = configured
        var error: Error?
        do {
          try await Task.detached {
            try LanguageProfileTransfer(hooks: hooks).exportDefinition(
              value, to: url, isCancelled: { probe.isCancelled })
          }.value
        } catch let caught { error = caught }
        let facts = probe.facts()
        if late {
          XCTAssertEqual(facts.afterReplace, 1)
          XCTAssertEqual(facts.saveReturns, 1)
          XCTAssertTrue(facts.cancelled)
          guard facts.afterReplace == 1, facts.saveReturns == 1, facts.cancelled else {
            throw ProfileTransferFixtureError.noReach
          }
          XCTAssertEqual(try Data(contentsOf: url), ProfileTransferWire.exported)
          XCTAssertNil(error, "Late cancellation cannot erase an actual successful publication")
        } else {
          XCTAssertTrue(error is CancellationError)
          XCTAssertEqual(facts.saves, 0)
          XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        try self.sound(probe)
      }
    }
  }
  func testActualDirectorySyncUncertaintySurvivesLateCancellationWithoutAcknowledgement()
    async throws
  {
    try await withDirectory { root in
      let url = root.appendingPathComponent("export.json")
      let value = try self.definition()
      let probe = ProfileTransferProbe()
      var configured = self.watched(probe)
      configured.saveNewFile = { bytes, file in
        try probe.save(
          bytes, to: file, fault: .directorySync,
          boundary: { point in
            if case .afterReplace = point { probe.cancel() }
          })
      }
      let hooks = configured
      var forwarded: Error?
      do {
        try await Task.detached {
          try LanguageProfileTransfer(hooks: hooks).exportDefinition(
            value, to: url, isCancelled: { probe.isCancelled })
        }.value
      } catch { forwarded = error }
      let facts = probe.facts()
      XCTAssertEqual(facts.afterReplace, 1)
      XCTAssertEqual(facts.saveReturns, 0)
      XCTAssertTrue(facts.cancelled)
      guard let original = facts.atomicError as? FileStoreError,
        case .publicationUncertain(let evidence) = original,
        facts.afterReplace == 1, facts.saveReturns == 0, facts.cancelled
      else { throw ProfileTransferFixtureError.noReach }
      XCTAssertEqual(try Data(contentsOf: url), ProfileTransferWire.exported)
      try await Task.detached {
        try AtomicFileStore().validatePublication(evidence, expected: ProfileTransferWire.exported)
      }.value
      XCTAssertTrue(
        forwarded is LanguageProfileExportUncertain,
        "Original actual uncertainty cannot be replaced by late cancellation")
      if let actual = forwarded as? LanguageProfileExportUncertain {
        XCTAssertEqual(actual.attemptedBytes, ProfileTransferWire.exported)
        XCTAssertEqual(actual.evidence.destination.standardizedFileURL, url.standardizedFileURL)
        try await Task.detached {
          try AtomicFileStore().validatePublication(
            actual.evidence, expected: ProfileTransferWire.exported)
        }.value
      }  // Guarded deeper evidence only credited when the desired original outcome was forwarded.
      let repeatedExport = await self.refused {
        try LanguageProfileTransfer().exportDefinition(value, to: url)
      }
      XCTAssertNotNil(repeatedExport)
      XCTAssertEqual(try Data(contentsOf: url), ProfileTransferWire.exported)
      try self.sound(probe)
    }
  }
}
