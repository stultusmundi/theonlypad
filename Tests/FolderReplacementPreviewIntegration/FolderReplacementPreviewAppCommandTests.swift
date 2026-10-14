// SPDX-License-Identifier: MIT
import AppKit
import Darwin
import Foundation
import PadCore
import XCTest

@testable import FolderReplacementPreviewComponent

// Calls a private helper through a declaring-file seam. No window becomes key,
// no application startup/admission is simulated, and native sendAction is injected.
@MainActor
final class FolderReplacementPreviewAppCommandTests: XCTestCase {
  func testPreviewFileCloseTargetsCapturedToolOnly() throws {
    try withFixture { rig in
      try assertOriginalAdmissionUntouched(rig)
      try assertNonPreviewAndMismatchRefusal(rig)
      let captured = try XCTUnwrap(rig.previewA.window)
      let other = try XCTUnwrap(rig.previewB.window)
      let parent = try XCTUnwrap(rig.parent.window)
      XCTAssertTrue(captured.windowController === rig.previewA)
      XCTAssertFalse(captured.isVisible)
      XCTAssertFalse(rig.previewA.isClosed)
      XCTAssertEqual(
        rig.delegate.previewCommandTestAvailability("file.close", window: captured), true)
      let handled = rig.delegate.previewCommandTestDispatch(
        "file.close", window: captured, sendNativeAction: rig.actions.send)
      XCTAssertTrue(handled, "Matching preview must claim close before an editor fallback")
      XCTAssertTrue(rig.previewA.isClosed, "Actual preview close path must run")
      XCTAssertEqual(rig.probe.closeA, 1)
      XCTAssertFalse(rig.previewB.isClosed)
      XCTAssertTrue(rig.previewB.window === other)
      XCTAssertTrue(rig.parent.window === parent)
      XCTAssertEqual(rig.probe.parentClose, 0)
      XCTAssertEqual(rig.actions.names, [])
      try assertOriginalAdmissionUntouched(rig)
      try rig.assertPreservedFiles()
      // Later closed-window behavior is reached only after real close was observed.
      guard rig.previewA.isClosed else { throw FixtureFailure.requiredCloseNotReached }
      XCTAssertTrue(
        rig.delegate.previewCommandTestDispatch(
          "file.close", window: captured, sendNativeAction: rig.actions.send))
      XCTAssertEqual(rig.probe.closeA, 1, "Repeated close must be idempotent")
      XCTAssertFalse(rig.previewB.isClosed)
      XCTAssertEqual(rig.actions.names, [])
    }
  }

  func testPreviewRegisteredSaveAndEditorCommandRefusalMatchesAvailability() throws {
    try withFixture { rig in
      try assertOriginalAdmissionUntouched(rig)
      try assertNonPreviewAndMismatchRefusal(rig)
      let window = try XCTUnwrap(rig.previewA.window)
      let ids = [
        "file.save", "file.saveAs", "file.saveAll", "edit.uppercase", "edit.line.delete",
        "macro.start", "macro.manage", "tool.extensions", "tool.externalCommand",
        "file.moveToWindow", "file.recent", "file.retrySession", "file.restoreSession",
        "document.encoding",
      ]
      let registered = Set(try AppCommands.registry().commands.map(\.id))
      for id in ids {
        XCTAssertTrue(registered.contains(id), "Contract must use an actual registered ID: \(id)")
        XCTAssertEqual(rig.delegate.previewCommandTestAvailability(id, window: window), false, id)
        XCTAssertTrue(
          rig.delegate.previewCommandTestDispatch(
            id, window: window, sendNativeAction: rig.actions.send),
          "Refused preview command still claims scope to stop fallback: \(id)")
        XCTAssertFalse(rig.previewA.isClosed, id)
        XCTAssertFalse(rig.previewB.isClosed, id)
        XCTAssertFalse(rig.previewA.hasActiveRequest, id)
        XCTAssertFalse(rig.previewB.hasActiveRequest, id)
        XCTAssertEqual(rig.previewA.patternView.string, Fixture.pattern, id)
        XCTAssertEqual(rig.previewA.replacementView.string, Fixture.replacement, id)
        XCTAssertEqual(rig.actions.names, [], id)
      }
      XCTAssertEqual(rig.probe.closeA, 0)
      XCTAssertEqual(rig.probe.closeB, 0)
      XCTAssertEqual(rig.probe.parentClose, 0)
      try assertOriginalAdmissionUntouched(rig)
      try rig.assertPreservedFiles()
    }
  }

  func testPreviewNativeEditingUsesExistingSelectors() throws {
    try withFixture { rig in
      try assertOriginalAdmissionUntouched(rig)
      try assertNonPreviewAndMismatchRefusal(rig)
      let window = try XCTUnwrap(rig.previewA.window)
      let pairs = [
        ("edit.undo", "undo:"), ("edit.redo", "redo:"), ("edit.cut", "cut:"),
        ("edit.copy", "copy:"), ("edit.paste", "paste:"), ("edit.selectAll", "selectAll:"),
      ]
      let registered = Set(try AppCommands.registry().commands.map(\.id))
      for (id, expected) in pairs {
        XCTAssertTrue(registered.contains(id), id)
        XCTAssertEqual(rig.delegate.previewCommandTestAvailability(id, window: window), true, id)
        let before = rig.actions.names.count
        let handled = rig.delegate.previewCommandTestDispatch(
          id, window: window, sendNativeAction: rig.actions.send)
        XCTAssertTrue(handled, "Native callback false must not permit editor fallback: \(id)")
        XCTAssertEqual(rig.actions.names.count, before + 1, id)
        XCTAssertEqual(rig.actions.names.last, expected, id)
        XCTAssertFalse(rig.previewA.isClosed, id)
        XCTAssertFalse(rig.previewA.hasActiveRequest, id)
      }
      XCTAssertEqual(rig.actions.names, pairs.map { $0.1 })
      XCTAssertEqual(rig.actions.senderWasDelegate, Array(repeating: true, count: 6))
      XCTAssertEqual(rig.previewA.patternView.string, Fixture.pattern)
      XCTAssertEqual(rig.previewA.replacementView.string, Fixture.replacement)
      XCTAssertFalse(rig.previewB.isClosed)
      XCTAssertEqual(rig.probe.closeA, 0)
      XCTAssertEqual(rig.probe.parentClose, 0)
      try assertOriginalAdmissionUntouched(rig)
      try rig.assertPreservedFiles()
      // These are injected selector-route facts, not native responder/key-window facts.
    }
  }

  private func assertOriginalAdmissionUntouched(_ rig: Fixture) throws {
    let facts = rig.delegate.previewCommandTestGuardFacts
    XCTAssertFalse(facts.registryReady)
    XCTAssertFalse(facts.preparingQuit)
    XCTAssertFalse(facts.hasDocumentOwner)
    XCTAssertFalse(facts.hasStartupTask)
    XCTAssertEqual(facts.editorCount, 0)
    XCTAssertEqual(facts.registeredCount, 0)
    XCTAssertEqual(rig.probe.applicationCallbacks, 0)
    for id in ["file.close", "file.save", "edit.undo"] {
      let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
      item.representedObject = id
      XCTAssertFalse(
        rig.delegate.validateMenuItem(item), "Original registry admission remains closed")
    }
    try rig.assertPreservedFiles()
  }

  private func assertNonPreviewAndMismatchRefusal(_ rig: Fixture) throws {
    let captured = try XCTUnwrap(rig.previewA.window)
    let parent = try XCTUnwrap(rig.parent.window)
    XCTAssertTrue(captured.windowController === rig.previewA)
    XCTAssertTrue(rig.plain.windowController === rig.plainController)
    // Negative fault only: real SDK association disagrees with the controller's owned window.
    rig.mismatch.windowController = rig.previewA
    defer { rig.mismatch.windowController = nil }
    XCTAssertTrue(rig.mismatch.windowController === rig.previewA)
    XCTAssertFalse(rig.previewA.window === rig.mismatch)
    for candidate in [nil, parent, rig.plain, rig.mismatch] as [NSWindow?] {
      for id in ["file.close", "file.save", "edit.undo"] {
        XCTAssertNil(rig.delegate.previewCommandTestAvailability(id, window: candidate))
        XCTAssertFalse(
          rig.delegate.previewCommandTestDispatch(
            id, window: candidate, sendNativeAction: rig.actions.send))
      }
    }
    XCTAssertFalse(rig.previewA.isClosed)
    XCTAssertFalse(rig.previewB.isClosed)
    XCTAssertEqual(rig.actions.names, [])
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let rig = try Fixture()
    var primary: Error?
    do { try body(rig) } catch { primary = error }
    do { try rig.cleanup() } catch {
      XCTFail("Fixture cleanup failed; exact resources and synthetic directory retained: \(error)")
      Fixture.retainUnsettled(rig)
      if primary == nil { primary = error }
    }
    if let primary { throw primary }
  }
}

private enum FixtureFailure: Error {
  case missingOwnedState, unexpectedIO, requiredCloseNotReached, unsettledNativeWork
}

@MainActor
private final class Probe {
  var applicationCallbacks = 0
  var closeA = 0
  var closeB = 0
  var parentClose = 0
}

@MainActor
private final class SelectorRecorder {
  weak var expectedSender: AppDelegate?
  private(set) var names: [String] = []
  private(set) var senderWasDelegate: [Bool] = []
  func send(_ selector: Selector, _ sender: Any?) -> Bool {
    guard names.count < 6 else {
      XCTFail("Selector collaborator exceeded bounded six-action budget")
      return false
    }
    names.append(NSStringFromSelector(selector))
    senderWasDelegate.append((sender as? AppDelegate) === expectedSender)
    return false
  }
}

@MainActor
private final class Fixture {
  static let pattern = "synthetic e\u{301} 😀 pattern"
  static let replacement = "literal $1 \\ replacement"
  private static var retained: [Fixture] = []
  static func retainUnsettled(_ rig: Fixture) {
    guard retained.count < 3 else {
      XCTFail("Exceeded three-fixture unresolved custody budget")
      return
    }
    retained.append(rig)
  }
  let directory: URL
  let sentinel: URL
  let sentinelBytes = Data("preview-routing-synthetic\n".utf8)
  let probe: Probe
  let actions: SelectorRecorder
  let delegate: AppDelegate
  let previewA: FolderReplacementPreviewController
  let previewB: FolderReplacementPreviewController
  let parent: FolderSearchController
  let plain: NSPanel
  let plainController: NSWindowController
  let mismatch: NSPanel

  init() throws {
    guard let raw = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      raw.hasPrefix("/"), !raw.utf8.contains(0)
    else { throw FixtureFailure.missingOwnedState }
    let base = URL(fileURLWithPath: raw, isDirectory: true)
    var metadata = stat()
    guard lstat(raw, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
    else { throw FixtureFailure.missingOwnedState }
    let ownedDirectory = base.appendingPathComponent(
      "preview-command-" + UUID().uuidString, isDirectory: true)
    let ownedSentinel = ownedDirectory.appendingPathComponent("sentinel.txt")
    try FileManager.default.createDirectory(
      at: ownedDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    do {
      try Data("preview-routing-synthetic\n".utf8).write(
        to: ownedSentinel, options: .withoutOverwriting)
    } catch {
      try? FileManager.default.removeItem(at: ownedDirectory)
      throw error
    }
    directory = ownedDirectory
    sentinel = ownedSentinel
    _ = NSApplication.shared
    let p = Probe()
    probe = p
    actions = SelectorRecorder()
    let session = SessionCoordinator(
      loadSession: { throw FixtureFailure.unexpectedIO },
      claimRecovery: { throw FixtureFailure.unexpectedIO },
      saveSession: { _ in throw FixtureFailure.unexpectedIO },
      removeRecovery: { _ in throw FixtureFailure.unexpectedIO },
      readFile: { _, _ in throw FixtureFailure.unexpectedIO })
    let recovery = RecoveryCoordinator(
      directory: ownedDirectory.appendingPathComponent("recovery", isDirectory: true),
      saveCheckpointSession: { _ in throw FixtureFailure.unexpectedIO },
      readCheckpointSession: { throw FixtureFailure.unexpectedIO })
    delegate = AppDelegate(
      session: session, recovery: recovery,
      presentEditorWindow: { _ in p.applicationCallbacks += 1 },
      reportDocumentError: { _ in p.applicationCallbacks += 1 },
      presentMoveDestination: { _ in p.applicationCallbacks += 1 },
      replyToTermination: { _ in p.applicationCallbacks += 1 },
      presentSessionAdjustment: { p.applicationCallbacks += 1 })
    actions.expectedSender = delegate
    previewA = FolderReplacementPreviewController(root: nil)
    previewB = FolderReplacementPreviewController(root: nil)
    parent = FolderSearchController(root: nil, onOpen: { _ in p.applicationCallbacks += 1 })
    plain = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    plain.isReleasedWhenClosed = false
    plainController = NSWindowController(window: plain)
    mismatch = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    mismatch.isReleasedWhenClosed = false
    previewA.patternView.string = Self.pattern
    previewA.replacementView.string = Self.replacement
    previewB.patternView.string = "other synthetic preview"
    previewA.onClose = { [weak a = previewA] in
      XCTAssertTrue(a?.isClosed == true)
      p.closeA += 1
    }
    previewB.onClose = { [weak b = previewB] in
      XCTAssertTrue(b?.isClosed == true)
      p.closeB += 1
    }
    parent.onClose = { p.parentClose += 1 }
  }

  func assertPreservedFiles() throws {
    XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), ["sentinel.txt"])
  }

  func cleanup() throws {
    // No work is admitted by these contracts. Refuse teardown if actual source says otherwise.
    guard !previewA.hasActiveRequest, !previewB.hasActiveRequest else {
      throw FixtureFailure.unsettledNativeWork
    }
    mismatch.windowController = nil
    previewA.close()
    previewB.close()
    parent.close()
    plainController.close()
    mismatch.close()
    XCTAssertTrue(previewA.isClosed)
    XCTAssertTrue(previewB.isClosed)
    XCTAssertFalse(previewA.hasActiveRequest)
    XCTAssertFalse(previewB.hasActiveRequest)
    XCTAssertEqual(probe.closeA, 1)
    XCTAssertEqual(probe.closeB, 1)
    guard previewA.isClosed, previewB.isClosed,
      !previewA.hasActiveRequest, !previewB.hasActiveRequest
    else {
      throw FixtureFailure.unsettledNativeWork
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    guard entries == ["sentinel.txt"], try Data(contentsOf: sentinel) == sentinelBytes else {
      throw FixtureFailure.unexpectedIO
    }
    try FileManager.default.removeItem(at: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
}
