import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting

private final class NativeCloseDeletionFault: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false
  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let result = armed
    armed = false
    return result
  }
}

private enum CloseFixtureFailure: Error { case unsupportedDependency, stale }
@MainActor private final class CloseGate {
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
@MainActor private final class CloseFixture {
  let directory: URL
  let session: SessionCoordinator
  let recovery: RecoveryCoordinator
  let deletionFault = NativeCloseDeletionFault()
  let registry: ApplicationDocuments
  let assignment: DocumentAssignment
  var endpointID = UUID()
  let endpointBindings = try! NativeDocumentEndpointBindings()
  var attached: [UUID: (EditorDocument, DocumentFileStateController, UUID)] = [:]
  var reopen: (() async throws -> DocumentIntakeID)?
  var projectionFailure = false
  var reattachCalls = 0
  var allowAttachedProof = true
  var controller: EditorWindowController!
  var closeOwner: NativeApplicationCloseCoordinator?
  var publisher: ApplicationSessionCheckpoints!
  var intake: ApplicationDocumentIntake!
  var nativeAdapter: NativeDocumentIntakeController?
  var lastIntake: DocumentIntakeID?
  var gate: CloseGate?
  var endpointLive = true
  var userAdmission = true
  var chooseSave: ((URL?, String) -> URL?)?
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
    let deletionFault = deletionFault
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      removeRecovery: { store, id in
        try store.removeChecked(id: id, fault: deletionFault.take() ? .afterRename : nil)
      },
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
        registry: registry,
        requireIntakeSettled: {
          if let adapter = self.nativeAdapter {
            try adapter.requireSettled()
          } else {
            try self.intake?.requireSettled()
          }
        },
        requireCloseSettled: { try self.closeOwner?.requireSettled() },
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
          if !self.endpointLive { throw CloseFixtureFailure.stale }
        },
        validateDestination: { request in
          guard let submission = self.submissions[request.documentID] else {
            throw CloseFixtureFailure.stale
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
        },
        project: { _ in
          if self.projectionFailure { throw CloseFixtureFailure.stale }
          try self.project()
        }))
    try makeEndpoint()
    try project()
    let a = try publisher.beginManagedActivation()
    try await publisher.drainManagedActivation(a)
    try publisher.finishManagedActivation(a)
  }
  func enableNativeAdapter() {
    nativeAdapter = NativeDocumentIntakeController(
      registry: registry, session: session, recovery: recovery,
      publication: .init(
        acquirePause: { try self.publisher.acquirePause() },
        drainPause: { try await self.publisher.drainPause($0) },
        releasePause: { try self.publisher.releasePause($0) },
        requestCheckpoint: { self.publisher.requestCheckpoint() }),
      destinations: .init(
        requireAdmission: { if !self.endpointLive { throw CloseFixtureFailure.stale } },
        validate: { endpoint, assignment in
          if !self.endpointLive || endpoint != self.endpointID || assignment != self.assignment {
            throw CloseFixtureFailure.stale
          }
        }, exists: { self.endpointLive && $0 == self.endpointID },
        resolveSelection: { _, _, intent in
          switch intent {
          case .select: return true
          case .preserve: return false
          case .selectIfStillSelected(let id, _):
            return self.controller.sessionMetadata.selectedTabID == id
          }
        }, drainLegacyWrites: { await self.gate?.wait() },
        project: { _, _ in
          if self.projectionFailure { throw CloseFixtureFailure.stale }
          try self.project()
        }))
  }
  func makeEndpoint(monitor: ApplicationFileMonitoring? = nil) throws {
    let incarnation = endpointID
    let routing = EditorApplicationRouting(
      endpointID: endpointID, assignment: assignment, registry: registry,
      requireEndpointCurrent: {
        if !self.endpointLive || self.endpointID != incarnation {
          throw CloseFixtureFailure.stale
        }
        try self.endpointCheck?()
      },
      requireUserAdmission: { if !self.userAdmission { throw CloseFixtureFailure.stale } },
      submit: { submission in
        self.submissions[submission.seed.id] = submission
        if let adapter = self.nativeAdapter {
          let id = try adapter.submit(submission)
          self.lastIntake = id
          return id
        }
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
      },
      wait: { id in
        if let adapter = self.nativeAdapter { return try await adapter.wait(for: id) }
        return try await self.intake.wait(for: id)
      },
      requestClose: { _ in throw CloseFixtureFailure.unsupportedDependency },
      requestReopen: {
        guard let reopen = self.reopen else { throw CloseFixtureFailure.unsupportedDependency }
        return try await reopen()
      },
      detachDocumentEndpoint: { model in
        try self.endpointBindings.detach(model)
        self.attached.removeValue(forKey: model.id)
      },
      reattachDocumentEndpoint: { model, context, changed in
        if self.allowAttachedProof, let active = self.attached[model.id], active.0 === model,
          active.1 === model.fileState,
          active.2 == incarnation
        {
          return
        }
        try self.endpointBindings.reattach(model, liveContext: context, onChange: changed)
        self.reattachCalls += 1
        self.attached[model.id] = (model, model.fileState!, incarnation)
      },
      endpointClosed: { id in if id == self.endpointID { self.endpointLive = false } },
      requestCheckpoint: { self.publisher.requestCheckpoint() })
    controller = try EditorWindowController(
      id: assignment.windowID, application: routing,
      chooseSaveDestination: { self.chooseSave?($0, $1) }, onError: { self.errors.append($0) })
    if let monitor { controller.configureFileMonitoring(monitor) }
  }
  func recreateEndpoint(monitor: ApplicationFileMonitoring? = nil) throws {
    endpointID = UUID()
    endpointLive = true
    try makeEndpoint(monitor: monitor)
  }
  func reconcileSubmission(_ id: UUID) throws {
    guard let old = submissions[id] else { throw CloseFixtureFailure.stale }
    let incarnation = endpointID
    submissions[id] = .init(
      endpointID: incarnation, assignment: assignment, seed: old.seed,
      provenance: old.provenance, selection: old.selection,
      requireDestinationCurrent: {
        if !self.endpointLive || self.endpointID != incarnation {
          throw CloseFixtureFailure.stale
        }
      }, insertionIndex: old.insertionIndex)
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
@MainActor final class NativeApplicationCloseTests: XCTestCase {
  private func owner(
    _ f: CloseFixture, response: NSApplication.ModalResponse = .alertSecondButtonReturn
  ) -> NativeApplicationCloseCoordinator {
    let close = NativeApplicationCloseCoordinator(
      registry: f.registry, recovery: f.recovery,
      publication: .init(
        requireApplicationAdmission: {
          if !f.userAdmission { throw CloseFixtureFailure.stale }
        }, acquirePause: { try f.publisher.acquirePause() },
        drainPause: { try await f.publisher.drainPause($0) },
        releasePause: { try f.publisher.releasePause($0) },
        requestCheckpoint: { f.publisher.requestCheckpoint() }),
      endpoint: { window in
        window == f.assignment.windowID && f.endpointLive ? (f.endpointID, f.controller!) : nil
      },
      reportError: { f.errors.append($0) }, decide: { _ in response })
    f.closeOwner = close
    return close
  }
  private func scratch(_ f: CloseFixture) async throws -> EditorDocument {
    f.controller.newDocument()
    let id = try XCTUnwrap(f.lastIntake)
    guard case .imported(let documentID) = try await f.intake.wait(for: id),
      let model = f.registry.handle(id: documentID) as? EditorDocument
    else { throw CloseFixtureFailure.stale }
    return model
  }
  func testNativeCleanClosePreservesHistoryAndProjectsEmptyWindow() async throws {
    let f = try CloseFixture()
    try await f.connect()
    let model = try await scratch(f)
    let close = owner(f)
    let state = try model.captureCloseState()
    let id = try close.start(documentIDs: [model.id], sourceWindowID: f.assignment.windowID)
    guard case .completed(let ids) = try await close.wait(for: id) else {
      return XCTFail("Real native close must complete")
    }
    XCTAssertEqual(ids, [model.id])
    XCTAssertNil(f.registry.handle(id: model.id))
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    try close.requireSettled()
    try await f.publisher.prepareQuit()
    try f.publisher.markNativeQuitPrepared()
    _ = try await f.publisher.commitFinal()
    XCTAssertTrue(
      try RecoveryStore(directory: f.directory.appendingPathComponent("recovery")).loadAll().isEmpty
    )
    await f.stop()
  }
  func testNativeDirtyCancelPreservesModelAndUndo() async throws {
    let f = try CloseFixture()
    try await f.connect()
    let model = try await scratch(f)
    model.editor.insertText("changed 😀", replacementRange: NSRange(location: 0, length: 0))
    let state = try model.captureCloseState()
    let text = model.storage.string
    let close = owner(f, response: .alertFirstButtonReturn)
    let id = try close.start(documentIDs: [model.id], sourceWindowID: f.assignment.windowID)
    guard case .cancelled = try await close.wait(for: id) else {
      return XCTFail("Dirty cancel required")
    }
    XCTAssertTrue(f.registry.handle(id: model.id) === model)
    XCTAssertEqual(model.storage.string, text)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 0)
    await f.stop()
  }
  func testNativeDirtyDiscardDeletesWithoutHistory() async throws {
    let f = try CloseFixture()
    try await f.connect()
    let model = try await scratch(f)
    model.editor.insertText(
      "discard synthetic 😀", replacementRange: NSRange(location: 0, length: 0))
    let close = owner(f)
    let id = try close.start(documentIDs: [model.id], sourceWindowID: f.assignment.windowID)
    guard case .completed = try await close.wait(for: id) else {
      return XCTFail("Confirmed discard must complete")
    }
    XCTAssertNil(f.registry.handle(id: model.id))
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 0)
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    await f.stop()
  }
  func testEndpointLossAfterDeletionRetainsUntilExactReprojection() async throws {
    let f = try CloseFixture()
    try await f.connect()
    let model = try await scratch(f)
    let close = owner(f)
    f.registry.onChange = { _ in
      if f.registry.handle(id: model.id) == nil {
        f.endpointLive = false
        close.endpointClosed(windowID: f.assignment.windowID)
      }
    }
    let id = try close.start(documentIDs: [model.id], sourceWindowID: f.assignment.windowID)
    guard case .retained = try await close.wait(for: id) else {
      return XCTFail("Lost projection endpoint must retain")
    }
    XCTAssertThrowsError(try close.requireSettled())
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
    f.registry.onChange = nil
    let previous = f.controller
    try f.recreateEndpoint()
    try close.retry(id)
    let result = try await close.wait(for: id)
    switch result {
    case .completed(let ids), .cancelled(let ids): XCTAssertEqual(ids, [model.id])
    case .retained: XCTFail("New exact endpoint projection must settle")
    }
    try close.requireSettled()
    XCTAssertTrue(f.controller.sessionMetadata.tabs.isEmpty)
    previous?.close()
    await f.stop()
  }

  func testRealActorDeletionFailureRepairsNativeModelAndReopensAdmission() async throws {
    let f = try CloseFixture()
    try await f.connect()
    let model = try await scratch(f)
    model.editor.insertText(
      "repair 👩🏽‍💻 e\u{301}\r\n", replacementRange: NSRange(location: 0, length: 0))
    let original = try model.captureAuthorizedRecovery()
    try await f.recovery.persistAuthorized(original)
    let state = try model.captureCloseState()
    let text = model.storage.string
    let authority = try XCTUnwrap(model.recoveryAuthority)
    let fence = model.highestIssuedRecoveryRevision
    let close = owner(f)
    f.deletionFault.arm()
    let id = try close.start(documentIDs: [model.id], sourceWindowID: f.assignment.windowID)
    guard case .retained = try await close.wait(for: id) else {
      return XCTFail("Actual after-rename deletion fault must retain the native model")
    }
    XCTAssertTrue(close.hasUnsettledTransactions)
    XCTAssertThrowsError(try close.requireSettled())
    XCTAssertEqual(model.recoveryAuthority, authority)
    XCTAssertEqual(model.highestIssuedRecoveryRevision, fence)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertFalse(f.registry.allows(.edit, documentID: model.id))
    model.editor.insertText("blocked", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(model.storage.string, text)
    try close.retry(id)
    _ = try await close.wait(for: id)
    try close.requireSettled()
    XCTAssertFalse(close.hasUnsettledTransactions)
    XCTAssertTrue(f.registry.handle(id: model.id) === model)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertEqual(model.storage.string, text)
    XCTAssertNotEqual(model.recoveryAuthority, authority)
    XCTAssertTrue(f.registry.allows(.edit, documentID: model.id))
    XCTAssertEqual(f.controller.sessionMetadata.tabs.map(\.id), [model.id])
    XCTAssertEqual(
      try RecoveryStore(directory: f.directory.appendingPathComponent("recovery")).loadAll().map(
        \.text), [text])
    do {
      try await f.recovery.persistAuthorized(original)
      XCTFail("A pre-close authority must never write after repair")
    } catch {}
    model.editor.insertText("accepted ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(model.storage.string, "accepted " + text)
    let repaired = try model.captureAuthorizedRecovery()
    XCTAssertEqual(repaired.authority, model.recoveryAuthority)
    XCTAssertNotEqual(repaired.authority, authority)
    try await f.recovery.persistAuthorized(repaired)
    XCTAssertEqual(
      try RecoveryStore(directory: f.directory.appendingPathComponent("recovery")).loadAll().map(
        \.text), ["accepted " + text])
    await f.stop()
  }

}
