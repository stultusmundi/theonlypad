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
  var userAdmission = true
  var chooseSave: ((URL?, String) -> URL?)?
  var detached: [UUID: (EditorDocument, DocumentFileStateController, FileStateEndpointDetachment)] =
    [:]
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
      closeServices: .init(readState: { try ($0 as! EditorDocument).captureCloseState() }),
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
      requireUserAdmission: { if !self.userAdmission { throw RoutingFixtureFailure.stale } },
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
            index: submission.insertionIndex
              ?? self.registry.window(id: self.assignment.windowID)!.groups[0].documentIDs.count,
            select: selected, utf16Count: submission.seed.textUTF16Count,
            originalByteCount: submission.seed.originalByteCount, provenance: submission.provenance,
            makeHandle: { try EditorDocumentFactory.make(submission.seed) }))
        self.lastIntake = id
        return id
      }, wait: { try await self.intake.wait(for: $0) },
      requestClose: { _ in throw RoutingFixtureFailure.unsupportedDependency },
      requestReopen: { throw RoutingFixtureFailure.unsupportedDependency },
      detachDocumentEndpoint: { model in
        guard let bridge = model.fileState else { return }
        if let retained = self.detached[model.id] {
          guard retained.0 === model, retained.1 === bridge else {
            throw RoutingFixtureFailure.stale
          }
          return
        }
        self.detached[model.id] = (model, bridge, try bridge.detachEndpoint())
      },
      endpointClosed: { _ in self.endpointLive = false },
      requestCheckpoint: { self.publisher.requestCheckpoint() })
    controller = try EditorWindowController(
      id: assignment.windowID, application: routing,
      chooseSaveDestination: { self.chooseSave?($0, $1) }, onError: { self.errors.append($0) })
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

  func testRegistryCloseLeaseRefusesPaneAndCommandMutation() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let request = try f.registry.requestClose(documentID: model.id)
    let ticket = try f.registry.beginClose(request, disposition: .retainCleanHistory)
    let state = try model.captureCloseState()
    let geometry = model.captureCloseGeometry()
    XCTAssertFalse(f.controller.isCommandAvailable("file.save"))
    XCTAssertFalse(f.controller.isCommandAvailable("view.splitVertical"))
    XCTAssertThrowsError(try f.controller.splitCurrent(.sideBySide))
    XCTAssertEqual(model.captureCloseGeometry(), geometry)
    XCTAssertEqual(try model.captureCloseState(), state)
    _ = try f.registry.completeClose(ticket, result: .notRemoved(RoutingFixtureFailure.stale))
    await f.stop()
  }
  func testUserGateDoesNotBlockProjectionOrFrozenCapture() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let before = f.controller.sessionMetadata.tabs.map(\.id)
    f.userAdmission = false
    XCTAssertFalse(f.controller.isCommandAvailable("file.save"))
    f.controller.newDocument()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(f.controller.sessionMetadata.tabs.map(\.id), before)
    try f.project()
    let frozen = await f.controller.prepareToQuit(persistRecovery: false)
    XCTAssertTrue(frozen)
    let capture = try f.controller.captureManagedSessionCheckpoint(
      expected: XCTUnwrap(f.registry.window(id: f.assignment.windowID)))
    XCTAssertEqual(capture.liveTabIDs, Set(before))
    f.controller.cancelPreparedQuit()
    await f.stop()
  }

  func testCloseAdmissionPreservesSemanticStateAndCleanHistory() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let request = try f.registry.requestClose(documentID: model.id)
    let disposition = try await f.controller.confirmManagedClose(
      request, endpointID: f.endpointID,
      decide: { _ in
        XCTFail("clean close must not ask")
        return .alertFirstButtonReturn
      })
    XCTAssertEqual(disposition, .retainCleanHistory)
    let ticket = try f.registry.beginClose(request, disposition: .retainCleanHistory)
    let state = try model.captureCloseState()
    let geometry = model.captureCloseGeometry()
    try f.controller.applyManagedAdmission(to: model, endpointID: f.endpointID)
    XCTAssertFalse(model.panePool[0].editor.isEditable)
    XCTAssertFalse(model.panePool[0].editor.isSelectable)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertEqual(model.captureCloseGeometry(), geometry)
    guard case .closed = try f.registry.completeClose(ticket, result: .removed) else {
      return XCTFail("registry fixture close")
    }
    // This projection fixture tests registry settlement only; it does not claim a real actor deletion receipt.
    try f.project()
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertEqual(model.captureCloseGeometry(), geometry)
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    _ = try f.registry.peekHistory(windowID: f.assignment.windowID, replacementID: UUID())
    await f.stop()
  }

  func testSaveChooserReentryCannotWriteAfterCloseLease() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let target = f.directory.appendingPathComponent("must-not-exist.txt")
    var ticket: DocumentCloseTicket?
    f.chooseSave = { _, _ in
      ticket = try! f.registry.beginClose(
        f.registry.requestClose(documentID: model.id), disposition: .retainCleanHistory)
      return target
    }
    f.controller.execute("file.saveAs")
    for _ in 0..<30 { await Task.yield() }
    XCTAssertNotNil(ticket)
    XCTAssertNil(model.operationID)
    XCTAssertNil(model.url)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    _ = try f.registry.completeClose(
      XCTUnwrap(ticket), result: .notRemoved(RoutingFixtureFailure.stale))
    await f.stop()
  }
  func testDirtyCloseCancelAndStaleConfirmationKeepBuffer() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    model.panePool[0].editor.insertText(
      "unsaved😀", replacementRange: NSRange(location: 0, length: 0))
    let request = try f.registry.requestClose(documentID: model.id)
    let result = try await f.controller.confirmManagedClose(
      request, endpointID: f.endpointID,
      decide: { alert in
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Discard Changes"])
        return .alertFirstButtonReturn
      })
    XCTAssertNil(result)
    XCTAssertEqual(model.storage.string, "unsaved😀")
    do {
      _ = try await f.controller.confirmManagedClose(
        request, endpointID: f.endpointID,
        decide: { _ in
          model.panePool[0].editor.insertText(
            "new", replacementRange: NSRange(location: 0, length: 0))
          return .alertSecondButtonReturn
        })
      XCTFail("stale affirmative response accepted")
    } catch {}
    XCTAssertTrue(f.registry.handle(id: model.id) === model)
    XCTAssertEqual(model.storage.string, "newunsaved😀")
    await f.stop()
  }

  func testActualNativeSelectionAndUndoStayFrozenUnderLease() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let editor = try XCTUnwrap(f.controller.focusedPane?.editor)
    model.undoManager.beginUndoGrouping()
    editor.insertText("abc😀", replacementRange: NSRange(location: 0, length: 0))
    editor.breakUndoCoalescing()
    model.undoManager.endUndoGrouping()
    let request = try f.registry.requestClose(documentID: model.id)
    let ticket = try f.registry.beginClose(request, disposition: .discardWithoutHistory)
    let before = model.storage.string
    let selection = editor.selectedRange()
    try f.controller.applyManagedAdmission(to: model, endpointID: f.endpointID)
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    editor.insertText("blocked", replacementRange: NSRange(location: 0, length: 0))
    model.undoManager.undo()
    XCTAssertEqual(editor.selectedRange(), selection)
    XCTAssertEqual(model.storage.string, before)
    XCTAssertTrue(model.undoManager.canUndo)
    _ = try f.registry.completeClose(ticket, result: .notRemoved(RoutingFixtureFailure.stale))
    try f.controller.applyManagedAdmission(to: model, endpointID: f.endpointID)
    XCTAssertTrue(editor.isEditable)
    XCTAssertTrue(editor.isSelectable)
    model.undoManager.undo()
    XCTAssertEqual(model.storage.string, "")
    let clean = try f.registry.beginClose(
      f.registry.requestClose(documentID: model.id), disposition: .retainCleanHistory)
    model.undoManager.redo()
    XCTAssertEqual(model.storage.string, "")
    _ = try f.registry.completeClose(clean, result: .notRemoved(RoutingFixtureFailure.stale))
    await f.stop()
  }
  func testHistoryProjectionToSurvivingTabPreservesRetiredPresentation() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    for _ in 0..<2 {
      f.controller.newDocument()
      _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    }
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let state = try model.captureCloseState()
    let geometry = model.captureCloseGeometry()
    let interaction = model.panePresentation.interaction
    let ticket = try f.registry.beginClose(
      f.registry.requestClose(documentID: model.id), disposition: .retainCleanHistory)
    _ = try f.registry.completeClose(ticket, result: .removed)
    try f.project()
    XCTAssertTrue(f.controller.isCommandAvailable("file.reopenClosed"))
    XCTAssertEqual(f.controller.sessionMetadata.tabs.count, 1)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertEqual(model.captureCloseGeometry(), geometry)
    XCTAssertEqual(model.panePresentation.interaction, interaction)
    XCTAssertNotNil(
      try f.registry.peekHistory(windowID: f.assignment.windowID, replacementID: UUID()))
    await f.stop()
  }
  func testEmptyWindowPermitClosesOnlyEmptyExactEndpoint() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    XCTAssertThrowsError(try f.controller.closeEmptyManagedWindow(endpointID: f.endpointID))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let ticket = try f.registry.beginClose(
      f.registry.requestClose(documentID: model.id), disposition: .retainCleanHistory)
    _ = try f.registry.completeClose(ticket, result: .removed)
    try f.project()
    f.userAdmission = false
    try f.controller.closeEmptyManagedWindow(endpointID: f.endpointID)
    XCTAssertFalse(f.endpointLive)
    XCTAssertThrowsError(try f.controller.closeEmptyManagedWindow(endpointID: f.endpointID))
    await f.stop()
  }

  func testUnconfirmedPublicationCannotCloseEvenAtSavedText() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let bytes = Data("attempted save".utf8)
    let target = f.directory.appendingPathComponent("uncertain.txt")
    do {
      try AtomicFileStore().save(bytes, to: target, expected: nil, fault: .directorySync)
      XCTFail("fault missing")
    } catch FileStoreError.publicationUncertain(let evidence) {
      model.pendingPublication = .init(evidence: evidence, bytes: bytes)
    }
    XCTAssertEqual(model.storage.string, model.savedText)
    let pending = try XCTUnwrap(model.pendingPublication)
    XCTAssertThrowsError(try f.registry.requestClose(documentID: model.id))
    XCTAssertEqual(model.pendingPublication?.id, pending.id)
    XCTAssertEqual(model.pendingPublication?.bytes, bytes)
    XCTAssertTrue(f.registry.handle(id: model.id) === model)
    XCTAssertTrue(f.controller.isCommandAvailable("file.saveAs"))
    await f.stop()
  }
  func testNativeResourceValidationAndLegacyDrainDoNotCaptureOrWrite() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let token = try f.publisher.acquirePause()
    try await f.publisher.drainPause(token)
    let model = try XCTUnwrap(f.controller.focusedPane?.document)
    let revision = model.highestIssuedRecoveryRevision
    let state = try model.captureCloseState()
    try f.controller.validateManagedResources(
      expected: XCTUnwrap(f.registry.window(id: f.assignment.windowID)))
    try await f.controller.drainLegacyRecoveryWrites(endpointID: f.endpointID)
    XCTAssertEqual(model.highestIssuedRecoveryRevision, revision)
    XCTAssertEqual(try model.captureCloseState(), state)
    await f.stop()
  }

  func testProjectionCannotGrantUserEditAdmissionDuringCallback() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    let editor = try XCTUnwrap(f.controller.focusedPane?.editor)
    f.userAdmission = false
    var attempting = false
    f.endpointCheck = {
      guard !attempting else { return }
      attempting = true
      editor.insertText("must refuse", replacementRange: NSRange(location: 0, length: 0))
      attempting = false
    }
    try f.project()
    XCTAssertEqual(editor.string, "")
    f.endpointCheck = nil
    await f.stop()
  }
  func testEmptyClosePermitRejectsRevisionChangeDuringEndpointCheck() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    var checks = 0
    f.endpointCheck = {
      checks += 1
      if checks == 3 {
        try f.registry.setGroupAxis(
          .stacked, windowID: f.assignment.windowID, expectedRevision: f.registry.workspaceRevision)
      }
    }
    try f.controller.closeEmptyManagedWindow(endpointID: f.endpointID)
    XCTAssertEqual(checks, 3)
    XCTAssertTrue(f.endpointLive)
    f.endpointCheck = nil
    await f.stop()
  }

  func testProjectionCallbackCannotFocusUnrelatedPaneWithUserGateClosed() async throws {
    let f = try RoutingFixture()
    try await f.connect()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.controller.newDocument()
    _ = try await f.intake.wait(for: XCTUnwrap(f.lastIntake))
    try f.controller.splitCurrent(.sideBySide)
    let current = try XCTUnwrap(f.controller.focusedPane)
    let other = try XCTUnwrap(current.document.panePool.first { $0 !== current })
    XCTAssertTrue(f.controller.window?.firstResponder === current.editor)
    XCTAssertTrue(f.controller.window?.makeFirstResponder(other.editor) == true)
    XCTAssertTrue(f.controller.window?.firstResponder === other.editor)
    XCTAssertTrue(f.controller.window?.makeFirstResponder(current.editor) == true)
    f.userAdmission = false
    var attempting = false
    f.endpointCheck = {
      guard !attempting else { return }
      attempting = true
      _ = f.controller.window?.makeFirstResponder(other.editor)
      attempting = false
    }
    try f.project()
    XCTAssertTrue(f.controller.window?.firstResponder === current.editor)
    XCTAssertEqual(current.document.preferredPaneID, current.id)
    f.endpointCheck = nil
    await f.stop()
  }

}
