import Foundation
import XCTest

@testable import PadCore

final class ShortcutTransferTests: XCTestCase {
  private func fixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
  func testImportStrictProfilePreservesOriginalBytes() throws {
    let url = try fixture().appendingPathComponent("import.json")
    let bytes = Data(
      "{\"version\":1,\"overrides\":[{\"commandID\":\"file.new\",\"assignment\":{\"kind\":\"disabled\"}}]}"
        .utf8)
    try bytes.write(to: url)
    XCTAssertEqual(
      try ShortcutTransfer().importProfile(from: url), try ShortcutProfile.decode(bytes))
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }
  func testExportCreatesNewFileAndNeverOverwritesExisting() throws {
    let url = try fixture().appendingPathComponent("export.json")
    try ShortcutTransfer().export(.defaults, to: url)
    XCTAssertEqual(try Data(contentsOf: url), try ShortcutProfile.defaults.encode())
    XCTAssertThrowsError(try ShortcutTransfer().export(.defaults, to: url))
    XCTAssertEqual(try Data(contentsOf: url), try ShortcutProfile.defaults.encode())
  }
  func testMalformedFutureOversizeAndUnsafeImportsDoNotChangeFiles() throws {
    let directory = try fixture()
    for (name, bytes) in [
      ("malformed", Data("{".utf8)), ("future", Data("{\"version\":2,\"overrides\":[]}".utf8)),
      ("oversized", Data(repeating: 65, count: ShortcutProfile.maximumBytes + 1)),
    ] {
      let url = directory.appendingPathComponent(name)
      try bytes.write(to: url)
      var hooks = ShortcutTransferHooks()
      if name == "oversized" {
        hooks.beforeRead = {
          XCTFail("Oversized import must be refused before matching content read")
        }
      }
      XCTAssertThrowsError(try ShortcutTransfer(hooks: hooks).importProfile(from: url))
      XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    let target = directory.appendingPathComponent("target")
    let bytes = try ShortcutProfile.defaults.encode()
    try bytes.write(to: target)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    for url in [
      link, directory, directory.appendingPathComponent("missing"),
      URL(string: "https://invalid.example/profile")!,
    ] {
      XCTAssertThrowsError(try ShortcutTransfer().importProfile(from: url))
    }
    XCTAssertEqual(try Data(contentsOf: target), bytes)
  }
  func testRetargetAndGrowthAfterObservationCannotSupplyDifferentContent() throws {
    for replacement in [
      Data("{\"version\":1,\"overrides\":[]}".utf8),
      Data(repeating: 65, count: ShortcutProfile.maximumBytes + 1),
    ] {
      let url = try fixture().appendingPathComponent("profile")
      try ShortcutProfile.defaults.encode().write(to: url)
      var hooks = ShortcutTransferHooks()
      hooks.afterObservation = { try replacement.write(to: url, options: .atomic) }
      XCTAssertThrowsError(try ShortcutTransfer(hooks: hooks).importProfile(from: url)) { error in
        XCTAssertEqual(error as? ExternalFileProbeError, .observationChanged)
      }
      XCTAssertEqual(try Data(contentsOf: url), replacement)
    }
  }
  func testCancellationBeforeIOAndAfterObservationRefusesRead() throws {
    XCTAssertThrowsError(
      try ShortcutTransfer().importProfile(
        from: URL(fileURLWithPath: "/unused-synthetic-shortcut"), isCancelled: { true })
    ) { XCTAssertTrue($0 is CancellationError) }
    let url = try fixture().appendingPathComponent("profile")
    try ShortcutProfile.defaults.encode().write(to: url)
    let cancelled = CancellationFlag()
    var hooks = ShortcutTransferHooks()
    hooks.afterObservation = { cancelled.set() }
    hooks.beforeRead = { XCTFail("Cancelled import must not start matching read") }
    XCTAssertThrowsError(
      try ShortcutTransfer(hooks: hooks).importProfile(from: url, isCancelled: { cancelled.value })
    ) { XCTAssertTrue($0 is CancellationError) }
  }
  func testProbePolicyFailuresPropagateWithoutContentRead() throws {
    var probeHooks = ProbeHooks()
    probeHooks.observeGuard = { _ in throw FileMaterializationError.disable(1) }
    probeHooks.boundary = { _ in
      XCTFail("Denied materialization policy must prevent filesystem access")
    }
    var hooks = ShortcutTransferHooks()
    hooks.probe = ExternalFileProbe(hooks: probeHooks)
    hooks.beforeRead = { XCTFail("Policy failure must not start matching read") }
    XCTAssertThrowsError(
      try ShortcutTransfer(hooks: hooks).importProfile(
        from: URL(fileURLWithPath: "/unused-synthetic-shortcut"))
    ) { error in
      guard case FileMaterializationError.disable(1) = error else {
        return XCTFail("Preserve typed policy failure")
      }
    }
  }
  func testExportFaultsPreserveCreateOnlyPolicyAndUncertainty() throws {
    for fault in [SaveFault.beforeWrite, .partialWrite, .fileSync, .beforeReplace, .directorySync] {
      let url = try fixture().appendingPathComponent("export")
      var hooks = ShortcutTransferHooks()
      hooks.fault = fault
      do {
        try ShortcutTransfer(hooks: hooks).export(.defaults, to: url)
        XCTFail("Injected export failure must not return success")
      } catch let error as ShortcutPublicationUncertain {
        XCTAssertEqual(error.attemptedBytes, try ShortcutProfile.defaults.encode())
        XCTAssertEqual(error.evidence.destination, url)
        XCTAssertEqual(try Data(contentsOf: url), error.attemptedBytes)
        XCTAssertThrowsError(try ShortcutTransfer().export(.defaults, to: url))
      } catch {
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
      }
      if case .directorySync = fault {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      }
    }
  }
}
private final class CancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func set() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
