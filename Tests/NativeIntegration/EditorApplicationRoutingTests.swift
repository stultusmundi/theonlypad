import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting

private enum RoutingFixtureFailure: Error { case unsupportedDependency, stale }
@MainActor private final class RoutingGate {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
@MainActor private final class RoutingFixture {
  let directory: URL
  let session: SessionCoordinator
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  let assignment: DocumentAssignment
  let endpointID = UUID()
  var controller: EditorWindowController!
  var publisher: ApplicationSessionCheckpoints!
  var intake: ApplicationDocumentIntake!
  var lastIntake: DocumentIntakeID?
  var gate: RoutingGate?
  var endpointLive = true
  var submissions: [UUID: EditorPreparedSubmission] = [:]
  var errors: [Error] = []
  var characterEvents = 0
  var endpointCheck: (() throws -> Void)?
  let initialSession: EditorSession?
  init(
    initialSession: EditorSession? = nil,
    assignment: DocumentAssignment = .init(windowID: UUID(), groupID: UUID())
  ) throws {
    self.initialSession = initialSession
    self.assignment = assignment
    _ = NSApplication.shared
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    session = SessionCoordinator(
      loadSession: { initialSession }, claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { handle in
          let model = handle as! EditorDocument
          return .init(
            documentID: model.id, ownershipGeneration: model.ownershipGeneration,
            authority: model.recoveryAuthority,
            highestIssuedRevision: model.highestIssuedRecoveryRevision)
        }))
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
  }
  func connect() async throws {
    await session.restore { prepared in
      self.initialSession == nil
        ? [:]
        : Dictionary(
          uniqueKeysWithValues: prepared.tabs.map {
            ($0.metadata.id, "synthetic initial import held")
          })
    }
    publisher = ApplicationSessionCheckpoints(
      session: session, recovery: recovery,
      managed: .init(
        registry: registry, requireIntakeSettled: { try self.intake?.requireSettled() },
        requireCloseSettled: {},
        validateProjection: { windows in
          for w in windows {
            try self.controller.validateRegistryProjection(
              w, revision: self.registry.workspaceRevision, endpointID: self.endpointID)
          }
        }, captureWindow: { try self.controller.captureManagedSessionCheckpoint(expected: $0) },
        preflightResources: { _ in }, renderStatus: { _, _ in }), delay: { _ in await Task.yield() }
    )
    intake = ApplicationDocumentIntake(
      registry: registry, session: session, recovery: recovery,
      publication: .init(
        acquirePause: { try self.publisher.acquirePause() },
        drainPause: { try await self.publisher.drainPause($0) },
        releasePause: { try self.publisher.releasePause($0) },
        requestCheckpoint: { self.publisher.requestCheckpoint() }),
      native: .init(
        requireApplicationAdmission: {
          if !self.endpointLive { throw RoutingFixtureFailure.stale }
        },
        validateDestination: { request in
          guard let submission = self.submissions[request.documentID] else {
            throw RoutingFixtureFailure.stale
          }
          try submission.requireDestinationCurrent()
        }, preflightResources: { _ in }, drainLegacyWrites: { await self.gate?.wait() },
        readState: { handle in
          let model = handle as! EditorDocument
          return .init(
            documentID: model.id, ownershipGeneration: model.ownershipGeneration,
            authority: model.recoveryAuthority,
            highestIssuedRevision: model.highestIssuedRecoveryRevision)
        },
        install: { handle, receipt, generation in
          let model = handle as! EditorDocument
          try model.installRecoveryAdoption(receipt, expectedOwnershipGeneration: generation)
          model.onCharactersChanged = { [weak self] in
            self?.characterEvents += 1
            self?.publisher.requestCheckpoint()
          }
        }, project: { _ in try self.project() }))
    let routing = EditorApplicationRouting(
      endpointID: endpointID, assignment: assignment, registry: registry,
      requireEndpointCurrent: {
        if !self.endpointLive { throw RoutingFixtureFailure.stale }
        try self.endpointCheck?()
      },
      submit: { submission in
        self.submissions[submission.seed.id] = submission
        let selected: Bool
        switch submission.selection {
        case .select: selected = true
        case .preserve: selected = false
        case .selectIfStillSelected(let id, _):
          selected = self.controller.sessionMetadata.selectedTabID == id
        }
        let id = try self.intake.start(
          .init(
            documentID: submission.seed.id, assignment: submission.assignment,
            metadata: .init(pinned: submission.seed.pinned),
            index: self.registry.window(id: self.assignment.windowID)!.groups[0].documentIDs.count,
            select: selected, utf16Count: submission.seed.textUTF16Count,
            originalByteCount: submission.seed.originalByteCount, provenance: submission.provenance,
            makeHandle: { try EditorDocumentFactory.make(submission.seed) }))
        self.lastIntake = id
        return id
      }, wait: { try await self.intake.wait(for: $0) },
      requestClose: { _ in throw RoutingFixtureFailure.unsupportedDependency },
      requestReopen: { throw RoutingFixtureFailure.unsupportedDependency },
      endpointClosed: { _ in self.endpointLive = false },
      requestCheckpoint: { self.publisher.requestCheckpoint() })
    controller = try EditorWindowController(
      id: assignment.windowID, application: routing, onError: { self.errors.append($0) })
    try project()
    let a = try publisher.beginManagedActivation()
    try await publisher.drainManagedActivation(a)
    try publisher.finishManagedActivation(a)
  }
  func project() throws {
    try controller.applyRegistryProjection(
      registry.window(id: assignment.windowID)!, revision: registry.workspaceRevision,
      endpointID: endpointID)
  }
  func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return predicate()
  }
  func stop() async {
    if let token = try? publisher?.acquirePause() { try? await publisher.drainPause(token) }
    endpointLive = false
    controller?.close()
  }
}
@MainActor final class EditorApplicationRoutingTests: XCTestCase {
  func testScratchUsesRealIntakeRegistryAndPublisher() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let gate = RoutingGate()
    f.gate = gate
    f.controller.newDocument()
    let entered = await f.wait { gate.entered }
    XCTAssertTrue(entered)
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    gate.release()
    f.gate = nil
    if let id = f.lastIntake {
      guard case .imported(let documentID) = try await f.intake.wait(for: id) else {
        return XCTFail("intake did not import")
      }
      XCTAssertEqual(f.controller.sessionMetadata.tabs.map(\.id), [documentID])
      let model = f.registry.handle(id: documentID) as! EditorDocument
      XCTAssertNotNil(model.recoveryAuthority)
      XCTAssertTrue(f.controller.focusedPane?.document === model)
      let saved = await f.wait {
        f.publisher.lastAcknowledgedGeneration > 0 && !f.publisher.hasPendingChanges
      }
      XCTAssertTrue(saved)
      let loaded = try SessionStore(directory: f.directory.appendingPathComponent("session")).load()
      XCTAssertEqual(loaded?.windows.flatMap(\.tabs).map(\.id), [documentID])
      let previous = f.characterEvents
      model.storage.mutableString.append("synthetic")
      XCTAssertGreaterThan(f.characterEvents, previous)
    } else {
      XCTFail("controller bypassed process intake")
    }
    await f.stop()
  }
  func testOpenCompletionWaitsForActualIntakeProjection() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let url = f.directory.appendingPathComponent("synthetic.swift")
    let bytes = Data("let emoji = \"😀\"\r\n".utf8)
    try bytes.write(to: url)
    let gate = RoutingGate()
    f.gate = gate
    var opened = 0
    var recent = 0
    var failed = 0
    f.controller.onOpenedURL = { _ in recent += 1 }
    f.controller.open(url, onFailure: { _ in failed += 1 }, onOpened: { opened += 1 })
    let entered = await f.wait { gate.entered }
    XCTAssertTrue(entered)
    XCTAssertEqual(opened, 0)
    XCTAssertEqual(recent, 0)
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    gate.release()
    f.gate = nil
    let done = await f.wait { opened == 1 }
    XCTAssertTrue(done)
    XCTAssertEqual(failed, 0)
    XCTAssertEqual(recent, 1)
    if let id = f.controller.sessionMetadata.selectedTabID,
      let model = f.registry.handle(id: id) as? EditorDocument
    {
      XCTAssertEqual(model.originalBytes, bytes)
      XCTAssertEqual(model.storage.string, String(decoding: bytes, as: UTF8.self))
    } else {
      XCTFail("missing projected document")
    }
    await f.stop()
  }
  func testDuplicateBackupAndExistingMissingURLUseOwnedModels() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let url = f.directory.appendingPathComponent("source.txt")
    let bytes = Data("original 😀\r\n".utf8)
    try bytes.write(to: url)
    var opened = 0
    f.controller.open(url, onFailure: { _ in XCTFail("open failed") }, onOpened: { opened += 1 })
    let ready = await f.wait { opened == 1 }
    XCTAssertTrue(ready)
    let source = try XCTUnwrap(f.controller.focusedPane?.document)
    source.storage.mutableString.append("unsaved")
    try FileManager.default.removeItem(at: url)
    f.controller.open(
      url, onFailure: { _ in XCTFail("existing buffer should avoid I/O") },
      onOpened: { opened += 1 })
    XCTAssertEqual(opened, 2)
    XCTAssertTrue(f.controller.focusedPane?.document === source)
    let oldRequest = f.lastIntake
    f.controller.execute("file.duplicate")
    let submitted = await f.wait { f.lastIntake != oldRequest }
    XCTAssertTrue(submitted)
    let result = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    guard case .imported(let id) = result, let copy = f.registry.handle(id: id) as? EditorDocument
    else { return XCTFail("duplicate refused") }
    XCTAssertFalse(copy === source)
    XCTAssertFalse(copy.storage === source.storage)
    XCTAssertEqual(copy.storage.string.utf16.map { $0 }, source.storage.string.utf16.map { $0 })
    XCTAssertNil(copy.url)
    let backup = try BackupStore(directory: f.directory.appendingPathComponent("backups")).capture(
      data: bytes, originalURL: url, encoding: .utf8)
    try await f.controller.restoreBackup(backup, data: bytes)
    let recovered = try XCTUnwrap(f.controller.focusedPane?.document)
    XCTAssertNil(recovered.url)
    XCTAssertEqual(recovered.storage.string, String(decoding: bytes, as: UTF8.self))
    XCTAssertTrue(recovered.name.hasPrefix("Backup"))
    XCTAssertNotNil(recovered.recoveryAuthority)
    await f.stop()
  }
  func testNoOpProjectionPreservesCaretUndoStorageAndProcessObserver() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    f.controller.newDocument()
    let submitted = await f.wait { f.lastIntake != nil }
    XCTAssertTrue(submitted)
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let pane = try XCTUnwrap(f.controller.focusedPane)
    let model = pane.document
    pane.editor.insertText("😀text", replacementRange: NSRange(location: 0, length: 0))
    let text = model.storage.string
    let selection = pane.editor.selectedRange()
    let undo = model.undoManager
    XCTAssertTrue(undo.canUndo)
    let count = f.characterEvents
    try f.project()
    try f.project()
    XCTAssertTrue(f.controller.focusedPane === pane)
    XCTAssertTrue(model.undoManager === undo)
    XCTAssertEqual(pane.editor.selectedRange(), selection)
    XCTAssertEqual(model.storage.string, text)
    XCTAssertEqual(f.characterEvents, count)
    undo.undo()
    XCTAssertEqual(model.storage.string, "")
    XCTAssertGreaterThan(f.characterEvents, count)
    await f.stop()
  }
  func testStaleEndpointBeforeIntakeRegistrationFailsOpenExactlyOnce() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let url = f.directory.appendingPathComponent("late.txt")
    try Data("late synthetic".utf8).write(to: url)
    let gate = RoutingGate()
    f.gate = gate
    var successes = 0
    var failures = 0
    f.controller.open(url, onFailure: { _ in failures += 1 }, onOpened: { successes += 1 })
    let held = await f.wait { gate.entered }
    XCTAssertTrue(held)
    f.endpointLive = false
    gate.release()
    f.gate = nil
    let failed = await f.wait { failures == 1 }
    XCTAssertTrue(failed)
    XCTAssertEqual(successes, 0)
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    XCTAssertTrue(try f.registry.captureWindows().flatMap(\.groups).flatMap(\.documentIDs).isEmpty)
    await f.stop()
  }
  func testProjectionRefusesStaleWrongEndpointAndInactiveOwnership() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let expected = try XCTUnwrap(f.registry.window(id: f.assignment.windowID))
    XCTAssertThrowsError(
      try f.controller.applyRegistryProjection(expected, revision: UUID(), endpointID: f.endpointID)
    )
    XCTAssertThrowsError(
      try f.controller.applyRegistryProjection(
        expected, revision: f.registry.workspaceRevision, endpointID: UUID()))
    let unowned = try EditorDocumentFactory.make(.scratch())
    try f.registry.registerDocument(
      unowned, metadata: .init(pinned: false), in: f.assignment, at: 0, select: true)
    XCTAssertThrowsError(try f.project())
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    XCTAssertThrowsError(
      try f.controller.captureManagedSessionCheckpoint(
        expected: f.registry.window(id: f.assignment.windowID)!))
    await f.stop()
  }
  func testPreparedSessionSeedUsesActualClaimAndExactPresentation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("restored.txt")
    let text = "a😀\r\nlast\r"
    let bytes = Data(text.utf8)
    try bytes.write(to: file)
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    let metadata = SessionTab(
      id: UUID(), originalPath: file.path, pinned: true, encoding: .utf8, manualLanguage: nil,
      selection: NSRange(location: 1, length: 2), bookmarks: [0, 5])
    let f = try RoutingFixture(
      initialSession: .init(windows: [
        .init(id: assignment.windowID, tabs: [metadata], selectedTabID: metadata.id)
      ]), assignment: assignment)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let claim = try f.session.claimImport(XCTUnwrap(f.session.unresolved.first))
    let seed = try await Task.detached {
      try NativeDocumentSeed.restored(metadata, url: file, originalBytes: bytes)
    }.value
    let id = try f.controller.acceptPreparedSessionSeed(
      seed, provenance: .session(claim), selection: .select)
    guard case .imported = try await f.intake.wait(for: id) else {
      return XCTFail("restoration did not import")
    }
    let model = try XCTUnwrap(f.registry.handle(id: metadata.id) as? EditorDocument)
    XCTAssertEqual(model.storage.string.utf16.map { $0 }, text.utf16.map { $0 })
    XCTAssertEqual(model.originalBytes, bytes)
    XCTAssertEqual(model.url, file)
    XCTAssertTrue(model.pinned)
    XCTAssertEqual(model.bookmarks.offsets, [0, 5])
    XCTAssertEqual(f.controller.focusedPane?.editor.selectedRange(), metadata.selection)
    XCTAssertTrue(f.session.unresolved.isEmpty)
    XCTAssertThrowsError(try f.controller.captureSessionCheckpoint())
    let capture = try f.controller.captureManagedSessionCheckpoint(
      expected: f.registry.window(id: assignment.windowID)!)
    XCTAssertEqual(capture.recovery.first?.authority, model.recoveryAuthority)
    XCTAssertNil(capture.recovery.first?.snapshot)
    await f.stop()
  }

  func testRealPreparedDiskCopyTransfersBeforeOperationFinishes() async throws {
    let f = try RoutingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.connect()
    let monitor = ApplicationFileMonitoring()
    defer { monitor.stop() }
    f.controller.configureFileMonitoring(monitor)
    monitor.onStateChange = { [weak controller = f.controller] in
      controller?.reconcileFileMonitoring()
    }
    let url = f.directory.appendingPathComponent("copy-source.txt")
    try Data("baseline".utf8).write(to: url)
    var opened = false
    f.controller.open(url, onFailure: { _ in XCTFail("open") }, onOpened: { opened = true })
    let loaded = await f.wait { opened }
    XCTAssertTrue(loaded)
    let source = try XCTUnwrap(f.controller.focusedPane?.document)
    let bridge = try XCTUnwrap(source.fileState)
    let observed = await f.wait { bridge.state.observation?.content == .matchesBaseline }
    XCTAssertTrue(observed)
    source.storage.mutableString.append(" unsaved")
    let local = source.storage.string
    let disk = "disk 😀\r\ncopy"
    let diskBytes = try DocumentCodec.encode(.init(text: disk, encoding: .utf16BE, hasBOM: true))
    try diskBytes.write(to: url, options: .atomic)
    bridge.checkAgain()
    let changed = await f.wait { bridge.state.observation?.content == .differsFromBaseline }
    XCTAssertTrue(changed)
    let conflict = try XCTUnwrap(f.controller.monitorHarnessDiskConflict(source))
    func button(_ view: NSView) -> NSButton? {
      if let value = view as? NSButton, value.accessibilityIdentifier() == "document.diskCopy" {
        return value
      }
      return view.subviews.lazy.compactMap { button($0) }.first
    }
    let action = try XCTUnwrap(button(XCTUnwrap(conflict.window?.contentView)))
    let old = f.lastIntake
    let gate = RoutingGate()
    f.gate = gate
    action.performClick(nil)
    let handoff = await f.wait { f.lastIntake != old && gate.entered && source.operationID == nil }
    XCTAssertTrue(handoff)
    XCTAssertEqual(f.controller.sessionMetadata.tabs.count, 1)
    XCTAssertEqual(source.storage.string, local)
    gate.release()
    f.gate = nil
    let imported = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    guard case .imported(let id) = imported, let copy = f.registry.handle(id: id) as? EditorDocument
    else { return XCTFail("copy import") }
    XCTAssertEqual(copy.storage.string.utf16.map { $0 }, disk.utf16.map { $0 })
    XCTAssertEqual(copy.encoding, .utf16BE)
    XCTAssertTrue(copy.hasBOM)
    XCTAssertNil(copy.url)
    XCTAssertTrue(f.controller.focusedPane?.document === copy)
    XCTAssertEqual(source.storage.string, local)
    XCTAssertTrue(source.fileState === bridge)
    try f.project()
    XCTAssertTrue(source.fileState === bridge)
    await f.stop()
  }

}
