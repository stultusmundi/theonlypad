import Foundation
import PadCore
import XCTest

@testable import TransferProcess

@MainActor private final class TransferPublicationGate {
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
@MainActor private final class PublicationTransferHandle: WorkspaceDocumentHandle {
  let id = UUID()
  var ownershipGeneration = UUID()
  var mutation = UUID()
  var workspaceKind: WorkspaceDocumentKind { .editable }
  let text = "paired transfer 👩🏽‍💻 e\u{301}\r\n終わり\n"
  var authority: RecoveryWriteAuthority?
  var highest: UInt64 = 0
  func advanceOwnershipGeneration() {
    ownershipGeneration = UUID()
    mutation = UUID()
  }
  var state: DocumentTransferState {
    .init(
      documentID: id, kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: mutation, editRevision: 3, baselineRevision: 1, operationID: nil,
      pendingPublicationID: nil, isBusy: false, hasPendingTextEdits: false, isComposing: false,
      recoveryAuthority: authority, highestIssuedRevision: highest)
  }
}
@MainActor private final class PublicationTransferReceipt: ApplicationDocumentTransferReceipt {}
// Fixture-owned synthetic identity only; this is not native storage or a recording grant.
@MainActor private final class PublicationTransferStorageMarker {}
@MainActor private final class TransferPublicationFixture {
  let directory: URL
  let store: SessionStore
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  let handle = PublicationTransferHandle()
  let source = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let target = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let macroStorage = PublicationTransferStorageMarker()
  var macroBindingAssignment: DocumentAssignment?
  var macroBindingOwnership: UUID?
  var macroSuspension: MacroTransferSuspension?
  var macroRequest: DocumentTransferRequest?
  var macroFinishedToken: MacroTransferSuspension?
  var macroEvents: [String] = []
  var approvedRouteEvents: [String] = []
  var macroTerminalRepairs = 0
  var macroNilReceiptRepairs = 0
  let gate = TransferPublicationGate()
  let beforeCapture: Bool
  var gateUsed = false
  var preparationRefused = false
  var paused = false
  var nativeCaptures = 0
  var transferID: ApplicationDocumentTransferID?
  var captures: [SessionCheckpointCapture] = []
  var persistedSessions: [EditorSession] = []
  var receipts: [SessionCheckpointReceipt] = []
  init(beforeCapture: Bool) throws {
    self.beforeCapture = beforeCapture
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    self.store = store
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { handle in
          let h = handle as! PublicationTransferHandle
          return .init(
            documentID: h.id, ownershipGeneration: h.ownershipGeneration,
            authority: h.authority, highestIssuedRevision: h.highest)
        }),
      transferServices: .init(
        rotateOwnership: { handle in
          let h = handle as! PublicationTransferHandle
          let pair = DocumentTransferOwnership(
            ownershipGeneration: UUID(), mutationGeneration: UUID())
          h.ownershipGeneration = pair.ownershipGeneration
          h.mutation = pair.mutationGeneration
          return pair
        }, readState: { ($0 as! PublicationTransferHandle).state }))
  }
  func prepare() async throws {
    try registry.registerWindow(id: source.windowID, initialGroupID: source.groupID)
    try registry.registerWindow(id: target.windowID, initialGroupID: target.groupID)
    let lease = try registry.registerPending(
      handle, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: true), in: source, at: 0, select: true)
    let receipt = try await recovery.adoptManagedDocument(id: handle.id)
    handle.authority = receipt.authority
    handle.highest = receipt.nextRevision - 1
    try registry.activateAdoption(lease, receipt: receipt)
    macroBindingAssignment = source
    macroBindingOwnership = handle.ownershipGeneration
  }
  // These Foundation collaborators enforce process custody of the actual reserved
  // lease. They do not model a native macro grant or an AppKit binding.
  private func suspendFixtureMacroBinding(_ snapshot: DocumentTransferSnapshot) throws
    -> MacroTransferSuspension
  {
    let current = try registry.validateTransferSnapshot(snapshot.lease)
    guard current.phase == .reserved, !current.effectsStarted,
      !current.requiresReconciliation, current.request == snapshot.request,
      current.handle === snapshot.handle, current.handle === handle,
      current.request.documentID == handle.id,
      registry.handle(id: handle.id) === handle,
      registry.assignment(of: handle.id) == current.request.source,
      current.expectedState == handle.state
    else { throw DocumentTransferError.stale }
    let token = MacroTransferSuspension(
      lease: current.lease, documentID: handle.id,
      documentObjectID: ObjectIdentifier(handle), storageID: ObjectIdentifier(macroStorage))
    if let held = macroSuspension {
      guard held == token, macroRequest == current.request,
        macroBindingAssignment == nil, macroBindingOwnership == nil
      else { throw DocumentTransferError.stale }
      return held
    }
    guard macroBindingAssignment == current.request.source,
      macroBindingOwnership == current.expectedState.ownershipGeneration
    else { throw DocumentTransferError.stale }
    macroEvents.append("suspend")
    macroRequest = current.request
    macroSuspension = token
    macroBindingAssignment = nil
    macroBindingOwnership = nil
    return token
  }

  private func finishFixtureMacroBinding(
    _ token: MacroTransferSuspension, terminal: ApplicationDocumentTransferTerminalReceipt,
    receipt: (any ApplicationDocumentTransferReceipt)?
  ) throws {
    guard macroRequest == terminal.request, token.documentID == handle.id,
      terminal.request.documentID == handle.id,
      token.documentObjectID == ObjectIdentifier(handle),
      token.storageID == ObjectIdentifier(macroStorage),
      registry.handle(id: handle.id) === handle,
      !registry.hasActiveTransferLease(token.lease),
      registry.closeStatus(documentID: handle.id) == .open,
      registry.adoptionStatus(documentID: handle.id) == .active,
      receipt == nil || receipt is PublicationTransferReceipt,
      receipt != nil || !terminal.moved
    else { throw DocumentTransferError.stale }
    let placement = terminal.moved ? terminal.request.target : terminal.request.source
    let windows = try registry.captureWindows()
    guard registry.assignment(of: handle.id) == placement,
      windows.first(where: { $0.id == placement.windowID })?.groups
        .first(where: { $0.id == placement.groupID })?.documentIDs.contains(handle.id) == true
    else { throw DocumentTransferError.stale }
    // Unrelated settlement callbacks may change workspaceRevision. Read actual
    // placement afresh rather than reusing the consumed reservation or old revision.
    let ownership = handle.ownershipGeneration
    if macroSuspension == nil, macroFinishedToken == token {
      guard macroBindingAssignment == placement, macroBindingOwnership == ownership else {
        throw DocumentTransferError.stale
      }
      return
    }
    guard macroSuspension == token, macroBindingAssignment == nil,
      macroBindingOwnership == nil
    else { throw DocumentTransferError.stale }
    // No callbacks or throwing operations after the fixture's atomic repair begins.
    macroEvents.append("finish")
    macroTerminalRepairs += 1
    if receipt == nil { macroNilReceiptRepairs += 1 }
    macroBindingAssignment = placement
    macroBindingOwnership = ownership
    macroFinishedToken = token
    macroSuspension = nil
  }

  lazy var scheduler = SessionCheckpointCoordinator(
    capture: { [unowned self] generation in
      let windows = try self.registry.captureReadyWindows()
      let session = EditorSession(
        windows: windows.map { window in
          .init(
            id: window.id,
            tabs: window.groups[0].documentIDs.map {
              SessionTab(id: $0, pinned: self.registry.metadata(id: $0)!.pinned)
            }, selectedTabID: window.groups[0].selectedDocumentID)
        })
      self.handle.highest += 1
      let snapshot = RecoverySnapshot(
        id: self.handle.id, text: self.handle.text, encoding: .utf8, hasBOM: false)
      let value = SessionCheckpointCapture(
        generation: generation, liveTabIDs: [self.handle.id],
        recovery: [
          .init(
            id: self.handle.id, revision: self.handle.highest, snapshot: snapshot,
            authority: self.handle.authority)
        ], session: session)
      self.captures.append(value)
      return value
    },
    commit: { [unowned self] capture in
      if !self.beforeCapture && !self.gateUsed {
        self.gateUsed = true
        await self.gate.wait()
      }
      let receipt = try await self.recovery.commitAuthorizedSessionCheckpoint(capture)
      self.receipts.append(receipt)
      self.persistedSessions.append(try self.store.load()!)
      return receipt
    },
    prepareCapture: { [unowned self] in
      if self.beforeCapture && !self.gateUsed {
        self.gateUsed = true
        await self.gate.wait()
        do { _ = try self.registry.captureReadyWindows() } catch {
          self.preparationRefused = true
          throw error
        }
      }
    }, delay: { _ in await Task.yield() })
  private func completeFixtureApprovedRouting(
    _ token: MacroTransferSuspension, terminal: ApplicationDocumentTransferTerminalReceipt,
    receipt: (any ApplicationDocumentTransferReceipt)?
  ) throws {
    let placement = terminal.moved ? terminal.request.target : terminal.request.source
    guard macroFinishedToken == token, macroSuspension == nil, macroRequest == terminal.request,
      token.documentID == handle.id, token.documentObjectID == ObjectIdentifier(handle),
      token.storageID == ObjectIdentifier(macroStorage), registry.handle(id: handle.id) === handle,
      !registry.hasActiveTransferLease(token.lease),
      registry.assignment(of: handle.id) == placement, macroBindingAssignment == placement,
      macroBindingOwnership == handle.ownershipGeneration,
      registry.closeStatus(documentID: handle.id) == .open,
      registry.adoptionStatus(documentID: handle.id) == .active,
      receipt == nil || receipt is PublicationTransferReceipt, receipt != nil || !terminal.moved
    else {
      throw DocumentTransferError.stale
    }
    let windows = try registry.captureWindows()
    guard
      windows.first(where: { $0.id == placement.windowID })?.groups
        .first(where: { $0.id == placement.groupID })?.documentIDs.contains(handle.id) == true
    else {
      throw DocumentTransferError.stale
    }
    approvedRouteEvents.append("completeApprovedRouting")
  }

  lazy var transfer = ApplicationDocumentTransfer(
    registry: registry,
    publication: .init(
      requireAdmission: {},
      acquirePause: { [unowned self] in
        XCTAssertNotNil(self.macroSuspension, "Actual reserved quarantine must precede pause")
        XCTAssertNil(self.macroBindingAssignment)
        XCTAssertNil(self.macroBindingOwnership)
        let token = try self.scheduler.acquirePause()
        self.paused = true
        return token
      }, drainPause: { [unowned self] token in try await self.scheduler.drainPause(token) },
      releasePause: { [unowned self] token in
        try self.scheduler.releasePause(token)
        self.paused = false
      }, requestCheckpoint: { [unowned self] in self.scheduler.requestCheckpoint() }),
    native: .init(
      suspendMacroBinding: { [unowned self] snapshot in
        try self.suspendFixtureMacroBinding(snapshot)
      },
      finishMacroBinding: { [unowned self] token, terminal, receipt in
        try self.finishFixtureMacroBinding(token, terminal: terminal, receipt: receipt)
      },
      completeApprovedViewRouting: { [unowned self] token, terminal, receipt in
        try self.completeFixtureApprovedRouting(token, terminal: terminal, receipt: receipt)
      },
      capture: { [unowned self] _ in
        self.nativeCaptures += 1
        return PublicationTransferReceipt()
      }, validate: { _, _ in }, suspendMonitor: { _, _ in }, projectSource: { _, _ in },
      projectTarget: { _, _ in }, attachMonitor: { _, _ in }, refreshAdmission: { _ in },
      finishMonitor: { _, _ in }))
  func startTransfer() throws -> ApplicationDocumentTransferID {
    let id = try transfer.start(
      DocumentTransferRequest(
        documentID: handle.id, source: source, target: target, targetIndex: 0,
        workspaceRevision: registry.workspaceRevision,
        ownershipGeneration: handle.ownershipGeneration))
    transferID = id
    return id
  }
  // Fixture-owned callbacks borrow self; drain every owned task before releasing it.
  func drainForTeardown() async {
    gate.release()
    if let transferID { _ = try? await transfer.wait(for: transferID) }
    await scheduler.pauseAndDrain()
  }
  func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
  }
}
@MainActor final class ApplicationDocumentTransferPublisherTests: XCTestCase {
  private func exercise(beforeCapture: Bool) async throws {
    var fixture: TransferPublicationFixture? = try TransferPublicationFixture(
      beforeCapture: beforeCapture)
    weak let released = fixture
    let directory = fixture!.directory
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try await run(fixture!, beforeCapture: beforeCapture)
    } catch {
      await fixture!.drainForTeardown()
      throw error
    }
    await fixture!.drainForTeardown()
    fixture = nil
    XCTAssertNil(released, "Drained publisher fixture must not retain itself through callbacks")
  }
  private func run(_ f: TransferPublicationFixture, beforeCapture: Bool) async throws {
    try await f.prepare()
    let authority = f.handle.authority
    f.scheduler.startAfterRestoration()
    let entered = await f.eventually { f.gate.entered }
    XCTAssertTrue(entered)
    guard entered else { return }
    XCTAssertEqual(f.captures.count, beforeCapture ? 0 : 1)
    let id = try f.startTransfer()
    let paused = await f.eventually { f.paused }
    XCTAssertTrue(paused)
    guard paused else { return }
    let macroToken = try XCTUnwrap(f.macroSuspension)
    XCTAssertTrue(f.registry.hasActiveTransferLease(macroToken.lease))
    XCTAssertEqual(macroToken.documentID, f.handle.id)
    XCTAssertEqual(macroToken.documentObjectID, ObjectIdentifier(f.handle))
    XCTAssertEqual(macroToken.storageID, ObjectIdentifier(f.macroStorage))
    XCTAssertNil(f.macroBindingAssignment)
    XCTAssertNil(f.macroBindingOwnership)
    XCTAssertEqual(f.macroEvents, ["suspend"])
    XCTAssertEqual(f.macroTerminalRepairs, 0)
    XCTAssertEqual(
      f.nativeCaptures, 0, "Native transfer capture waits for existing publication drain")
    XCTAssertEqual(f.registry.assignment(of: f.handle.id), f.source)
    XCTAssertThrowsError(try f.registry.captureReadyWindows())
    f.gate.release()
    guard case .moved = try await f.transfer.wait(for: id) else {
      return XCTFail("Transfer must finish after held publisher is released")
    }
    try f.transfer.requireSettled()
    XCTAssertNil(f.macroSuspension)
    XCTAssertEqual(f.macroFinishedToken, macroToken)
    XCTAssertFalse(f.registry.hasActiveTransferLease(macroToken.lease))
    XCTAssertEqual(f.macroBindingAssignment, f.target)
    XCTAssertEqual(f.macroBindingOwnership, f.handle.ownershipGeneration)
    XCTAssertEqual(f.macroEvents, ["suspend", "finish"])
    XCTAssertEqual(f.macroTerminalRepairs, 1)
    XCTAssertEqual(f.macroNilReceiptRepairs, 0)
    XCTAssertEqual(f.nativeCaptures, 1)
    XCTAssertFalse(f.paused)
    XCTAssertEqual(f.handle.authority, authority)
    if beforeCapture {
      XCTAssertTrue(
        f.preparationRefused, "Pre-capture refusal must drain without waiting for transfer")
    } else {
      XCTAssertEqual(
        f.persistedSessions.first?.windows.first { $0.id == f.source.windowID }?.tabs.map(\.id),
        [f.handle.id])
      XCTAssertEqual(f.receipts.first?.recoveryAuthorities[f.handle.id], authority)
    }
    let final = try await f.scheduler.commitFinal()
    XCTAssertEqual(final.recoveryAuthorities[f.handle.id], authority)
    let session = try XCTUnwrap(f.store.load())
    XCTAssertEqual(session.windows.flatMap(\.tabs).map(\.id), [f.handle.id])
    XCTAssertEqual(session.windows.first { $0.id == f.source.windowID }?.tabs, [])
    XCTAssertEqual(
      session.windows.first { $0.id == f.target.windowID }?.tabs.map(\.id), [f.handle.id])
    XCTAssertEqual(session.windows.first { $0.id == f.target.windowID }?.tabs.first?.pinned, true)
    let restored = try RecoveryStore(directory: f.directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(restored.map(\.id), [f.handle.id])
    XCTAssertTrue(try XCTUnwrap(restored.first).text.utf16.elementsEqual(f.handle.text.utf16))
    XCTAssertTrue(f.registry.handle(id: f.handle.id) === f.handle)
  }
  func testHeldPreparationDrainsBeforeCaptureWithoutTransferCycle() async throws {
    try await exercise(beforeCapture: true)
  }
  func testHeldOldPlacementCommitFinishesBeforeMoveAndNewPairedCheckpoint() async throws {
    try await exercise(beforeCapture: false)
  }
}
