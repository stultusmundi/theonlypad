import Foundation
import PadCore
import XCTest

@testable import ManagedPublisher

@MainActor private final class PublisherGate {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func open() {
    continuation?.resume()
    continuation = nil
  }
}
private final class PublisherWriteFault: @unchecked Sendable {
  private let lock = NSLock()
  private var fails = false
  func set(_ value: Bool) {
    lock.lock()
    fails = value
    lock.unlock()
  }
  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if fails { throw PublisherFailure.injected }
  }
}
private enum PublisherFailure: Error { case injected }
@MainActor private final class PublisherHandle: WorkspaceDocumentHandle {
  let id: UUID
  init(id: UUID = UUID()) { self.id = id }
  var ownershipGeneration = UUID()
  var workspaceKind: WorkspaceDocumentKind { .editable }
  var authority: RecoveryWriteAuthority?
  var revision: UInt64 = 0
  var text = "synthetic 👩🏽‍💻\r\ne\u{301}\u{0}\r"
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentCloseState {
    .init(
      kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: ownershipGeneration, operationID: nil, isDirty: true,
      hasPendingPublication: false, hasPendingTextEdits: false, isComposing: false,
      canRetainCleanHistory: false)
  }
  var adoption: DocumentAdoptionState {
    .init(
      documentID: id, ownershipGeneration: ownershipGeneration, authority: authority,
      highestIssuedRevision: revision)
  }
}
@MainActor private final class PublisherFixture {
  let directory: URL
  let store: SessionStore
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  let session: SessionCoordinator
  let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
  var handles: [UUID: PublisherHandle] = [:]
  var intakeBusy = false
  var closeBusy = false
  var malformed = false
  var captureCalls = 0
  var projection: (() throws -> Void)?
  var render: (() -> Void)?
  var offeredRetry: (() -> Void)?
  let writeFault = PublisherWriteFault()
  var rejectImports = false
  init(
    initial: EditorSession? = nil, removal: PublisherGate? = nil,
    recoverySnapshots: [RecoverySnapshot] = [], loadFailure: Bool = false
  ) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = SessionStore(directory: directory.appendingPathComponent("session"))
    let store = store
    let fault = writeFault
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: {
        try fault.check()
        try store.save($0)
      }, readCheckpointSession: { try store.load() })
    registry = ApplicationDocuments(
      closeServices: .init { ($0 as! PublisherHandle).state },
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID, readState: { ($0 as! PublisherHandle).adoption }))
    session = SessionCoordinator(
      loadSession: {
        if loadFailure { throw PublisherFailure.injected }
        return initial
      }, claimRecovery: { .init(snapshots: recoverySnapshots, quarantinedCount: 0) },
      removeRecovery: { _ in await removal?.wait() },
      readFile: { _, _ in throw PublisherFailure.injected })
  }
  func readySession() async {
    await session.restore { prepared in
      self.rejectImports
        ? Dictionary(
          uniqueKeysWithValues: prepared.tabs.map { ($0.metadata.id, "synthetic retained failure") }
        ) : [:]
    }
  }
  func add(managed: Bool = true, id: UUID = UUID()) async throws -> PublisherHandle {
    if registry.window(id: assignment.windowID) == nil {
      try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    }
    let h = PublisherHandle(id: id)
    handles[h.id] = h
    let index = registry.window(id: assignment.windowID)!.groups[0].documentIDs.count
    if managed {
      let lease = try registry.registerPending(
        h, requestID: UUID(), expectedRevision: registry.workspaceRevision,
        metadata: .init(pinned: false), in: assignment, at: index, select: true)
      let receipt = try await recovery.adoptManagedDocument(id: h.id)
      h.authority = receipt.authority
      try registry.activateAdoption(lease, receipt: receipt)
    } else {
      try registry.registerDocument(
        h, metadata: .init(pinned: false), in: assignment, at: index, select: true)
    }
    return h
  }
  func publisher() -> ApplicationSessionCheckpoints {
    ApplicationSessionCheckpoints(
      session: session, recovery: recovery,
      managed: .init(
        registry: registry,
        requireIntakeSettled: { if self.intakeBusy { throw PublisherFailure.injected } },
        requireCloseSettled: { if self.closeBusy { throw PublisherFailure.injected } },
        validateProjection: { _ in try self.projection?() },
        captureWindow: { window in
          self.captureCalls += 1
          let ids = window.groups[0].documentIDs
          let tabs = ids.map {
            SessionTab(
              id: $0, originalPath: nil, pinned: false, encoding: .utf16BE, manualLanguage: nil,
              selection: .init(location: 0, length: 0), bookmarks: [])
          }
          let items = ids.map { id -> RecoveryCheckpointItem in
            let h = self.handles[id]!
            h.revision += 1
            return .init(
              id: id, revision: h.revision,
              snapshot: .init(id: id, text: h.text, encoding: .utf16BE, hasBOM: true),
              authority: self.malformed ? nil : h.authority)
          }
          return .init(
            window: .init(
              id: window.id, tabs: tabs, selectedTabID: window.groups[0].selectedDocumentID),
            liveTabIDs: Set(ids), recovery: items)
        }, preflightResources: { _ in },
        renderStatus: { _, retry in
          self.offeredRetry = retry
          self.render?()
        }),
      delay: { _ in await Task.yield() })
  }
  func activate(_ p: ApplicationSessionCheckpoints) async throws {
    let token = try p.beginManagedActivation()
    try await p.drainManagedActivation(token)
    try p.finishManagedActivation(token)
  }
  func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return predicate()
  }
}
@MainActor final class ApplicationSessionCheckpointsTests: XCTestCase {
  func testActivationPublishesActualManagedReceiptAndExactRecovery() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let h = try await f.add()
    let p = f.publisher()
    p.startAfterRestoration()
    p.requestCheckpoint()
    await Task.yield()
    XCTAssertNil(try f.store.load())
    try await f.activate(p)
    let acknowledged = await f.wait { p.lastAcknowledgedGeneration > 0 }
    XCTAssertTrue(acknowledged)
    let token = try p.acquirePause()
    try await p.drainPause(token)
    XCTAssertEqual(try f.store.load()?.windows.first?.tabs.map(\.id), [h.id])
    let restored = try await RecoveryCoordinator(
      directory: f.directory.appendingPathComponent("recovery")
    ).claimStartup()
    XCTAssertEqual(restored.snapshots.first?.text.utf16.map { $0 }, h.text.utf16.map { $0 })
    XCTAssertEqual(restored.snapshots.first?.encoding, .utf16BE)
    XCTAssertEqual(restored.snapshots.first?.hasBOM, true)
  }
  func testActivationFailureRetainsTokenAndCanRetrySameActivation() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add()
    let p = f.publisher()
    let token = try p.beginManagedActivation()
    try await p.drainManagedActivation(token)
    f.intakeBusy = true
    XCTAssertThrowsError(try p.finishManagedActivation(token))
    try p.failManagedActivation(token, error: PublisherFailure.injected)
    XCTAssertThrowsError(try p.beginManagedActivation())
    XCTAssertNil(try f.store.load())
    f.intakeBusy = false
    try p.finishManagedActivation(token)
    let done = await f.wait { p.lastAcknowledgedGeneration > 0 }
    XCTAssertTrue(done)
    let pause = try p.acquirePause()
    try await p.drainPause(pause)
  }
  func testUnmanagedRecordCannotActivate() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add(managed: false)
    let p = f.publisher()
    let token = try p.beginManagedActivation()
    try await p.drainManagedActivation(token)
    XCTAssertThrowsError(try p.finishManagedActivation(token))
    XCTAssertNil(try f.store.load())
  }
  func testZeroDocumentsStillRequiresCloseAdmissionAndUsesRealFinal() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    let a = try p.beginManagedActivation()
    try await p.drainManagedActivation(a)
    f.closeBusy = true
    XCTAssertThrowsError(try p.finishManagedActivation(a))
    f.closeBusy = false
    try p.finishManagedActivation(a)
    try await p.prepareQuit()
    try p.markNativeQuitPrepared()
    let receipt = try await p.commitFinal()
    XCTAssertTrue(receipt.recoveryAuthorities.isEmpty)
    XCTAssertEqual(try f.store.load()?.windows, [])
  }
  func testFinalRequiresNativeFreezeAndPauseAdmissionIsClosed() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add()
    let p = f.publisher()
    try await f.activate(p)
    try await p.prepareQuit()
    XCTAssertThrowsError(try p.acquirePause())
    do {
      _ = try await p.commitFinal()
      XCTFail("final before native freeze")
    } catch {}
    try p.markNativeQuitPrepared()
    XCTAssertThrowsError(try p.acquirePause())
    _ = try await p.commitFinal()
    XCTAssertNotNil(try f.store.load())
  }
  func testMalformedAuthorityNeverPublishesSession() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add()
    f.malformed = true
    let p = f.publisher()
    try await f.activate(p)
    let failed = await f.wait { p.lastError != nil }
    XCTAssertTrue(failed)
    let token = try p.acquirePause()
    try await p.drainPause(token)
    XCTAssertEqual(p.lastAcknowledgedGeneration, 0)
    XCTAssertNil(try f.store.load())
  }
  func testQuitPreparationCannotBeAcknowledgedReentrantlyBeforeDrain() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    try await f.activate(p)
    var attempted = false
    f.projection = {
      if case .preparingQuit = p.phase, !attempted {
        attempted = true
        XCTAssertThrowsError(try p.markNativeQuitPrepared())
      }
    }
    try await p.prepareQuit()
    XCTAssertTrue(attempted)
    try p.markNativeQuitPrepared()
    _ = try await p.commitFinal()
  }
  func testProjectionReentryCannotFinishAnotherActivationOrPublishChangedPlacement() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add()
    let p = f.publisher()
    let a = try p.beginManagedActivation()
    try await p.drainManagedActivation(a)
    f.projection = {
      XCTAssertThrowsError(try p.finishManagedActivation(a))
      XCTAssertThrowsError(try p.failManagedActivation(a, error: PublisherFailure.injected))
      try f.registry.setPinned(
        true, documentID: f.handles.keys.first!, expectedRevision: f.registry.workspaceRevision)
    }
    XCTAssertThrowsError(try p.finishManagedActivation(a))
    XCTAssertNil(try f.store.load())
    f.projection = nil
    try p.finishManagedActivation(a)
    let failed = await f.wait { p.lastError != nil }
    XCTAssertTrue(failed)  // Native capture's old pin is refused.
    let pause = try p.acquirePause()
    try await p.drainPause(pause)
    XCTAssertNil(try f.store.load())
  }
  func testFinalFailureRetainsSessionAndExplicitVetoResumes() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add()
    let p = f.publisher()
    try await f.activate(p)
    let initial = await f.wait { p.lastAcknowledgedGeneration > 0 }
    XCTAssertTrue(initial)
    let bytes = try Data(contentsOf: f.store.directory.appendingPathComponent("Session.json"))
    try await p.prepareQuit()
    try p.markNativeQuitPrepared()
    f.writeFault.set(true)
    do {
      _ = try await p.commitFinal()
      XCTFail("write must fail")
    } catch {}
    XCTAssertEqual(
      try Data(contentsOf: f.store.directory.appendingPathComponent("Session.json")), bytes)
    XCTAssertThrowsError(try p.acquirePause())
    f.writeFault.set(false)
    p.cancelPreparedQuit()
    XCTAssertEqual(p.phase, .managed)
    let before = p.lastAcknowledgedGeneration
    p.requestCheckpoint()
    let retried = await f.wait { p.lastAcknowledgedGeneration > before }
    XCTAssertTrue(retried)
    let pause = try p.acquirePause()
    try await p.drainPause(pause)
  }
  func testUnrelatedPauseSurvivesResumeAndQuitRefusesIt() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    try await f.activate(p)
    let pause = try p.acquirePause()
    try await p.drainPause(pause)
    let before = p.lastAcknowledgedGeneration
    p.resumeAfterVeto()
    p.requestCheckpoint()
    await Task.yield()
    XCTAssertEqual(p.lastAcknowledgedGeneration, before)
    do {
      try await p.prepareQuit()
      XCTFail("owned pause")
    } catch {}
    try p.releasePause(pause)
    let done = await f.wait { p.lastAcknowledgedGeneration > before }
    XCTAssertTrue(done)
    let stop = try p.acquirePause()
    try await p.drainPause(stop)
  }
  func testHeldUnresolvedRemovalDrainsBeforeRealCloseAndPostClosePublication() async throws {
    let missing = SessionTab(
      id: UUID(), originalPath: "/synthetic-missing", pinned: false, encoding: .utf8,
      manualLanguage: nil, selection: .init(location: 0, length: 0), bookmarks: [])
    let prior = EditorSession(windows: [
      .init(id: UUID(), tabs: [missing], selectedTabID: missing.id)
    ])
    let gate = PublisherGate()
    let f = try PublisherFixture(
      initial: prior, removal: gate,
      recoverySnapshots: [.init(id: missing.id, text: "retained", encoding: .utf8, hasBOM: false)])
    f.rejectImports = true
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let h = try await f.add()
    let survivor = try await f.add()
    let p = f.publisher()
    try await f.activate(p)
    let initial = await f.wait { p.lastAcknowledgedGeneration > 0 }
    XCTAssertTrue(initial)
    XCTAssertTrue(try f.store.load()!.windows.flatMap(\.tabs).contains { $0.id == missing.id })
    let removing = Task { try await f.session.remove(f.session.unresolved[0]) }
    let held = await f.wait { gate.entered }
    XCTAssertTrue(held)
    p.requestCheckpoint()
    await Task.yield()
    let pause = try p.acquirePause()
    f.closeBusy = true
    let draining = Task { try await p.drainPause(pause) }
    gate.open()
    try await removing.value
    try await draining.value
    let request = try f.registry.requestClose(documentID: h.id)
    let ticket = try f.registry.beginClose(request, disposition: .discardWithoutHistory)
    let lease = try await f.recovery.prepareClose(
      authority: h.authority!, minimumRevision: h.revision, registryTicketID: ticket.id)
    let receipt = try await f.recovery.finalizeClose(lease)
    _ = try f.registry.completeClose(ticket, result: .removed)
    try await f.recovery.retireClose(receipt)
    f.closeBusy = false
    let before = p.lastAcknowledgedGeneration
    try p.releasePause(pause)
    let updated = await f.wait { p.lastAcknowledgedGeneration > before }
    XCTAssertTrue(updated)
    let stop = try p.acquirePause()
    try await p.drainPause(stop)
    XCTAssertEqual(try f.store.load()!.windows.flatMap(\.tabs).map(\.id), [survivor.id])
    let restored = try await RecoveryCoordinator(
      directory: f.directory.appendingPathComponent("recovery")
    ).claimStartup()
    XCTAssertEqual(restored.snapshots.map(\.id), [survivor.id])
    XCTAssertEqual(restored.snapshots.first?.text.utf16.map { $0 }, survivor.text.utf16.map { $0 })
  }

  func testFailedMetadataAllowsAdoptedRecoveryButNeverPublication() async throws {
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "valid scratch recovery", encoding: .utf8, hasBOM: false)
    let f = try PublisherFixture(recoverySnapshots: [snapshot], loadFailure: true)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.rejectImports = true
    try FileManager.default.createDirectory(
      at: f.store.directory, withIntermediateDirectories: true)
    let url = f.store.directory.appendingPathComponent("Session.json")
    let original = Data("synthetic unsupported session".utf8)
    try original.write(to: url)
    await f.readySession()
    let claim = try f.session.claimRecoveryImport(f.session.unresolved[0])
    let imported = try await f.add(id: claim.documentID)
    imported.text = claim.snapshot.text
    try f.session.resolveRecoveryImport(claim)
    let p = f.publisher()
    try await f.activate(p)
    XCTAssertEqual(p.phase, .managed)
    let failed = await f.wait { p.lastError != nil }
    XCTAssertTrue(failed)
    let pause = try p.acquirePause()
    try await p.drainPause(pause)
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertEqual(p.lastAcknowledgedGeneration, 0)
    XCTAssertTrue(f.registry.handle(id: snapshot.id) === imported)
    XCTAssertEqual(imported.text, snapshot.text)
  }
  func testUnrepresentableSecondGroupRefusesActivation() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    _ = try await f.add()
    try f.registry.createGroup(
      in: f.assignment.windowID, id: UUID(), axis: .stacked,
      expectedRevision: f.registry.workspaceRevision)
    let p = f.publisher()
    let a = try p.beginManagedActivation()
    try await p.drainManagedActivation(a)
    XCTAssertThrowsError(try p.finishManagedActivation(a))
    XCTAssertEqual(f.captureCalls, 0)
  }
  func testActivationPauseCannotBeReleasedThroughClosePauseAPI() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    let a = try p.beginManagedActivation()
    try await p.drainManagedActivation(a)
    XCTAssertThrowsError(try p.releasePause(a.pause))
    let other = f.publisher()
    XCTAssertThrowsError(try other.finishManagedActivation(a))
    try p.finishManagedActivation(a)
    let stop = try p.acquirePause()
    try await p.drainPause(stop)
  }
  func testLegacyServicesStillUseActualLegacyPairedWriter() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let id = UUID()
    let window = UUID()
    var prepared = 0
    let p = ApplicationSessionCheckpoints(
      session: f.session, recovery: f.recovery,
      legacy: .init(
        capture: {
          [
            .init(
              window: .init(
                id: window,
                tabs: [
                  .init(
                    id: id, originalPath: nil, pinned: false, encoding: .utf8, manualLanguage: nil,
                    selection: .init(location: 0, length: 0), bookmarks: [])
                ], selectedTabID: id), liveTabIDs: [id],
              recovery: [
                .init(
                  id: id, revision: 1,
                  snapshot: .init(id: id, text: "legacy exact\r\n", encoding: .utf8, hasBOM: false))
              ])
          ]
        }, prepare: { prepared += 1 }, renderStatus: { _, _ in }), onRetry: nil)
    p.startAfterRestoration()
    let receipt = try await p.commitFinal()
    XCTAssertEqual(prepared, 1)
    XCTAssertEqual(receipt.recoveryRevisions, [id: 1])
    XCTAssertTrue(receipt.recoveryAuthorities.isEmpty)
    XCTAssertEqual(try f.store.load()?.windows.first?.tabs.first?.id, id)
  }

  func testManagedCompatibilityPauseResumePairRestartsPublisher() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    try await f.activate(p)
    await p.pauseAndDrain()
    let previous = p.lastAcknowledgedGeneration
    p.resumeAfterVeto()
    p.requestCheckpoint()
    let resumed = await f.wait { p.lastAcknowledgedGeneration > previous }
    XCTAssertTrue(resumed)
    let stop = try p.acquirePause()
    try await p.drainPause(stop)
  }
  func testActivationFailureDoesNotOfferIneffectiveCheckpointRetry() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    let a = try p.beginManagedActivation()
    try await p.drainManagedActivation(a)
    try p.failManagedActivation(a, error: PublisherFailure.injected)
    XCTAssertNotNil(p.lastError)
    XCTAssertNil(f.offeredRetry)
    XCTAssertEqual(p.phase, .failedActivation(a.request))
  }

  func testStartupIntakeOwnsIndependentPauseUnderExactActivation() async throws {
    let f = try PublisherFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.readySession()
    let p = f.publisher()
    let a = try p.beginManagedActivation()
    try await p.drainManagedActivation(a)
    let intakePause = try p.acquireActivationPause(a)
    try await p.drainPause(intakePause)
    XCTAssertThrowsError(try p.finishManagedActivation(a))
    XCTAssertThrowsError(try p.acquirePause())
    let other = f.publisher()
    XCTAssertThrowsError(try other.acquireActivationPause(a))
    try p.releasePause(intakePause)
    XCTAssertNil(try f.store.load())
    try p.finishManagedActivation(a)
    XCTAssertThrowsError(try p.acquireActivationPause(a))
    let stop = try p.acquirePause()
    try await p.drainPause(stop)
  }

}
