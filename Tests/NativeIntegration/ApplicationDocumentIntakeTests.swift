import Foundation
import PadCore
import XCTest

@testable import IntakeOwner

private enum IntakeFailure: Error { case injected }
@MainActor private final class IntakeHandle: WorkspaceDocumentHandle {
  let id: UUID
  private(set) var ownershipGeneration = UUID()
  var workspaceKind: WorkspaceDocumentKind { .editable }
  private(set) var authority: RecoveryWriteAuthority?
  private(set) var highest: UInt64 = 0
  var mutation = UUID()
  var closeState: DocumentCloseState {
    .init(
      kind: .editable, ownershipGeneration: ownershipGeneration, mutationGeneration: mutation,
      operationID: nil, isDirty: false, hasPendingPublication: false, hasPendingTextEdits: false,
      isComposing: false, canRetainCleanHistory: true)
  }
  let text = "synthetic 👩🏽‍💻e\u{301}\r\n"
  func capture() throws -> RecoveryCheckpointItem {
    guard let authority else { throw IntakeFailure.injected }
    highest += 1
    return .init(
      id: id, revision: highest,
      snapshot: .init(id: id, text: text, encoding: .utf16BE, hasBOM: true), authority: authority)
  }
  init(id: UUID = UUID()) { self.id = id }
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentAdoptionState {
    .init(
      documentID: id, ownershipGeneration: ownershipGeneration,
      authority: authority, highestIssuedRevision: highest)
  }
  func install(_ receipt: RecoveryAdoptionReceipt, generation: UUID) throws {
    guard generation == ownershipGeneration, receipt.authority.documentID == id,
      authority == nil, receipt.nextRevision > 0
    else { throw IntakeFailure.injected }
    authority = receipt.authority
    highest = receipt.nextRevision - 1
  }
}
@MainActor private final class IntakeGate {
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func open() {
    continuation?.resume()
    continuation = nil
  }
}
@MainActor private final class IntakeFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  let session: SessionCoordinator
  let assignment: DocumentAssignment
  let scheduler = SessionCheckpointCoordinator(
    capture: { _ in throw IntakeFailure.injected }, commit: { _ in throw IntakeFailure.injected })
  var acquired: [CheckpointPauseToken] = []
  var released: [CheckpointPauseToken] = []
  var factories = 0
  var installs: [RecoveryAdoptionReceipt] = []
  var projects = 0
  var rejectInstall = false
  var rejectProjection = false
  var rejectAdmission = false
  var gate: IntakeGate?
  var admissionCallback: (() -> Void)?
  var factoryCallback: (() throws -> Void)?
  init(session: SessionCoordinator, windowID: UUID = UUID()) throws {
    self.session = session
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    recovery = RecoveryCoordinator(directory: directory)
    registry = ApplicationDocuments(
      closeServices: .init { ($0 as! IntakeHandle).closeState },
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID, readState: { ($0 as! IntakeHandle).state }))
    assignment = .init(windowID: windowID, groupID: UUID())
    try registry.registerWindow(id: windowID, initialGroupID: assignment.groupID)
  }
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
  func owner() -> ApplicationDocumentIntake {
    ApplicationDocumentIntake(
      registry: registry, session: session, recovery: recovery,
      publication: .init(
        acquirePause: {
          let token = try self.scheduler.acquirePause()
          self.acquired.append(token)
          return token
        },
        drainPause: { token in
          if let gate = self.gate { await gate.wait() }
          try await self.scheduler.drainPause(token)
        },
        releasePause: { token in
          try self.scheduler.releasePause(token)
          self.released.append(token)
        }, requestCheckpoint: {}),
      native: .init(
        requireApplicationAdmission: {
          self.admissionCallback?()
          if self.rejectAdmission { throw IntakeFailure.injected }
        }, validateDestination: { _ in }, preflightResources: { _ in }, drainLegacyWrites: {},
        readState: { ($0 as! IntakeHandle).state },
        install: { handle, receipt, generation in
          self.installs.append(receipt)
          if self.rejectInstall { throw IntakeFailure.injected }
          try (handle as! IntakeHandle).install(receipt, generation: generation)
        },
        project: { _ in
          self.projects += 1
          if self.rejectProjection { throw IntakeFailure.injected }
        }))
  }
  func request(
    _ suppliedHandle: IntakeHandle? = nil, count: Int = 4,
    provenance: DocumentIntakeProvenance = .fresh
  ) -> DocumentIntakeRequest {
    let handle = suppliedHandle ?? IntakeHandle()
    return .init(
      documentID: handle.id, assignment: assignment, metadata: .init(pinned: false),
      index: 0, select: true, utf16Count: count, originalByteCount: 4,
      provenance: provenance,
      makeHandle: {
        self.factories += 1
        try self.factoryCallback?()
        return handle
      })
  }
}
@MainActor final class ApplicationDocumentIntakeTests: XCTestCase {
  private func session(tabs: [SessionTab] = [], windowID: UUID = UUID()) async -> SessionCoordinator
  {
    let value = SessionCoordinator(
      loadSession: {
        EditorSession(
          windows: tabs.isEmpty
            ? [] : [.init(id: windowID, tabs: tabs, selectedTabID: tabs.first?.id)])
      },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Intake cannot publish directly") })
    await value.restore { _ in [:] }
    return value
  }
  private func entered(_ gate: IntakeGate) async {
    for _ in 0..<1000 {
      if gate.entered { return }
      await Task.yield()
    }
    XCTFail("Owned drain must reach its barrier")
  }
  private func refuses(_ operation: () throws -> Void) {
    do {
      try operation()
      XCTFail("Expected refusal")
    } catch {}
  }
  private func imported(_ result: DocumentIntakeResult, _ id: UUID) {
    guard case .imported(let actual) = result else { return XCTFail("Expected imported result") }
    XCTAssertEqual(actual, id)
  }
  private func closeToHistory(_ f: IntakeFixture, _ source: IntakeHandle) async throws
    -> DocumentHistoryClaim
  {
    let intake = f.owner()
    imported(try await intake.wait(for: intake.start(f.request(source))), source.id)
    let ticket = try f.registry.beginClose(
      f.registry.requestClose(documentID: source.id), disposition: .retainCleanHistory)
    let lease = try await f.recovery.prepareClose(
      authority: XCTUnwrap(source.authority),
      minimumRevision: source.highest, registryTicketID: ticket.id)
    let receipt = try await f.recovery.finalizeClose(lease)
    guard case .closed = try f.registry.completeClose(ticket, result: .removed) else {
      throw IntakeFailure.injected
    }
    try await f.recovery.retireClose(receipt)
    return try XCTUnwrap(
      f.registry.peekHistory(windowID: f.assignment.windowID, replacementID: UUID()))
  }
  func testHistoryCloseReopenConsumesAfterRealActorActivation() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let source = IntakeHandle()
    let claim = try await closeToHistory(f, source)
    let replacement = IntakeHandle(id: claim.replacementID)
    let owner = f.owner()
    imported(
      try await owner.wait(for: owner.start(f.request(replacement, provenance: .history(claim)))),
      replacement.id)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 0)
    XCTAssertEqual(f.registry.adoptionStatus(documentID: replacement.id), .active)
    XCTAssertNotEqual(replacement.authority, source.authority)
  }
  func testHistoryMutationRefusesBeforeFactory() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let source = IntakeHandle()
    let claim = try await closeToHistory(f, source)
    source.mutation = UUID()
    let before = f.factories
    let owner = f.owner()
    let result = try await owner.wait(
      for: owner.start(
        f.request(IntakeHandle(id: claim.replacementID), provenance: .history(claim))))
    guard case .refused = result else { return XCTFail("Stale history must refuse") }
    XCTAssertEqual(f.factories, before)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
  }
  func testHistoryFailedInstallationDoesNotConsumeAndProjectionRetryConsumesOnce() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let claim = try await closeToHistory(f, IntakeHandle())
    f.rejectInstall = true
    let owner = f.owner()
    let replacement = IntakeHandle(id: claim.replacementID)
    let id = try owner.start(f.request(replacement, provenance: .history(claim)))
    guard case .retained = try await owner.wait(for: id) else {
      return XCTFail("Failed install retained")
    }
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
    f.rejectInstall = false
    f.rejectProjection = true
    try owner.retry(id)
    guard case .retained = try await owner.wait(for: id) else {
      return XCTFail("Failed projection retained")
    }
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 0)
    let installs = f.installs.count
    f.rejectProjection = false
    try owner.retry(id)
    imported(try await owner.wait(for: id), replacement.id)
    XCTAssertEqual(f.installs.count, installs)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 0)
  }
  func testHistoryReplacementIdentityMismatchRefusesFactory() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let claim = try await closeToHistory(f, IntakeHandle())
    let before = f.factories
    let owner = f.owner()
    let result = try await owner.wait(for: owner.start(f.request(provenance: .history(claim))))
    guard case .refused = result else { return XCTFail("Wrong replacement must refuse") }
    XCTAssertEqual(f.factories, before)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
  }
  func testEvictedHistoryRefusesBeforeFactory() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let claim = try await closeToHistory(f, IntakeHandle())
    for _ in 0..<10 { _ = try await closeToHistory(f, IntakeHandle()) }
    let before = f.factories
    let owner = f.owner()
    let result = try await owner.wait(
      for: owner.start(
        f.request(IntakeHandle(id: claim.replacementID), provenance: .history(claim))))
    guard case .refused = result else { return XCTFail("Evicted history must refuse") }
    XCTAssertEqual(f.factories, before)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 10)
  }
  func testHistoryUsesFreshAggregateCapacityNotUnresolvedReservation() async throws {
    let tabs = (0..<128).map { _ in SessionTab(originalPath: "/synthetic/missing.txt") }
    let f = try IntakeFixture(session: await session(tabs: tabs))
    defer { f.cleanup() }
    let source = IntakeHandle()
    try f.registry.registerDocument(
      source, metadata: .init(pinned: false), in: f.assignment, at: 0, select: true)
    let ticket = try f.registry.beginClose(
      f.registry.requestClose(documentID: source.id), disposition: .retainCleanHistory)
    guard case .closed = try f.registry.completeClose(ticket, result: .removed) else {
      return XCTFail("History close")
    }
    let claim = try XCTUnwrap(
      f.registry.peekHistory(windowID: f.assignment.windowID, replacementID: UUID()))
    let owner = f.owner()
    let result = try await owner.wait(
      for: owner.start(
        f.request(IntakeHandle(id: claim.replacementID), provenance: .history(claim))))
    guard case .refused = result else {
      return XCTFail("Aggregate capacity must refuse fresh replacement")
    }
    XCTAssertEqual(f.factories, 0)
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
  }
  func testHistoryChangedAtActivationRemainsRetainedBeforeProjection() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let source = IntakeHandle()
    let claim = try await closeToHistory(f, source)
    let beforeProjects = f.projects
    f.registry.onChange = { _ in
      if f.registry.adoptionStatus(documentID: claim.replacementID) == .active {
        source.mutation = UUID()
      }
    }
    let owner = f.owner()
    let result = try await owner.wait(
      for: owner.start(
        f.request(IntakeHandle(id: claim.replacementID), provenance: .history(claim))))
    guard case .retained = result else {
      return XCTFail("Changed source after adoption must retain exact transaction")
    }
    XCTAssertEqual(f.registry.closedHistoryCount(windowID: f.assignment.windowID), 1)
    XCTAssertEqual(f.projects, beforeProjects)
    XCTAssertTrue(owner.hasUnsettledTransactions)
    XCTAssertEqual(f.registry.adoptionStatus(documentID: claim.replacementID), .active)
  }
  func testInvalidScalarRefusesWithoutFactoryOrPause() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let owner = f.owner()
    XCTAssertThrowsError(try owner.start(f.request(count: -1)))
    XCTAssertEqual(f.factories, 0)
    XCTAssertTrue(f.acquired.isEmpty)
    XCTAssertFalse(owner.hasUnsettledTransactions)
  }
  func testSuccessfulImportUsesRealActorAuthorityAndPersistsExactSnapshot() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let owner = f.owner()
    let handle = IntakeHandle()
    let id = try owner.start(f.request(handle))
    imported(try await owner.wait(for: id), handle.id)
    XCTAssertTrue(f.registry.handle(id: handle.id) === handle)
    XCTAssertEqual(f.registry.adoptionStatus(documentID: handle.id), .active)
    XCTAssertEqual(f.installs.count, 1)
    XCTAssertEqual(f.acquired, f.released)
    try owner.requireSettled()
    let authority = try XCTUnwrap(handle.authority)
    let snapshot = RecoverySnapshot(
      id: handle.id, text: "synthetic 👩🏽‍💻\r\n", encoding: .utf16BE, hasBOM: true)
    try await f.recovery.persistAuthorized(
      .init(authority: authority, revision: 1, snapshot: snapshot))
    let loaded = try RecoveryStore(directory: f.directory).loadAll().first { $0.id == handle.id }
    XCTAssertEqual(loaded?.text, snapshot.text)
  }
  func testDrainPrecedesFactoryAndBusyAdmission() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let gate = IntakeGate()
    f.gate = gate
    let owner = f.owner()
    let request = f.request()
    let id = try owner.start(request)
    await entered(gate)
    XCTAssertEqual(f.factories, 0)
    self.refuses { _ = try owner.start(f.request()) }
    self.refuses { try owner.requireSettled() }
    gate.open()
    imported(try await owner.wait(for: id), request.documentID)
  }
  func testAdmissionAndRegistryCallbacksCannotReenterOrCancelTransferredOwnership() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let owner = f.owner()
    var admissions = 0
    var registrations = 0
    f.admissionCallback = {
      admissions += 1
      XCTAssertTrue(owner.hasUnsettledTransactions)
      self.refuses { try owner.requireSettled() }
      self.refuses { _ = try owner.start(f.request()) }
    }
    f.registry.onChange = { _ in
      registrations += 1
      self.refuses { try owner.requireSettled() }
      self.refuses { _ = try owner.start(f.request()) }
      if let status = owner.status {
        self.refuses { try owner.cancelBeforeRegistration(status.id) }
      }
    }
    let request = f.request()
    let id = try owner.start(request)
    imported(try await owner.wait(for: id), request.documentID)
    XCTAssertGreaterThan(admissions, 0)
    XCTAssertGreaterThan(registrations, 0)
  }
  func testFailedInstallRetainsActualReceiptAndRetryDoesNotReadopt() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    f.rejectInstall = true
    let owner = f.owner()
    let handle = IntakeHandle()
    let id = try owner.start(f.request(handle))
    guard case .retained(let retained, _) = try await owner.wait(for: id) else {
      return XCTFail("Must retain")
    }
    XCTAssertEqual(retained, handle.id)
    XCTAssertTrue(f.released.isEmpty)
    let first = try XCTUnwrap(f.installs.first)
    f.rejectInstall = false
    try owner.retry(id)
    imported(try await owner.wait(for: id), handle.id)
    XCTAssertEqual(f.factories, 1)
    XCTAssertEqual(f.installs.map(\.authority), [first.authority, first.authority])
    XCTAssertEqual(handle.authority, first.authority)
  }
  func testProjectionRetryDoesNotCreateInstallOrAdoptAgain() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    f.rejectProjection = true
    let owner = f.owner()
    let handle = IntakeHandle()
    let id = try owner.start(f.request(handle))
    guard case .retained = try await owner.wait(for: id) else {
      return XCTFail("Must retain projection")
    }
    let authority = handle.authority
    f.rejectProjection = false
    try owner.retry(id)
    imported(try await owner.wait(for: id), handle.id)
    XCTAssertEqual(handle.authority, authority)
    XCTAssertEqual(f.installs.count, 1)
    XCTAssertEqual(f.factories, 1)
    XCTAssertEqual(f.projects, 2)
  }
  func testCancelledWaiterDoesNotCancelOwnedImport() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let gate = IntakeGate()
    f.gate = gate
    let owner = f.owner()
    let request = f.request()
    let id = try owner.start(request)
    await entered(gate)
    let waiter = Task { try await owner.wait(for: id) }
    waiter.cancel()
    gate.open()
    _ = try? await waiter.value
    imported(try await owner.wait(for: id), request.documentID)
    XCTAssertEqual(f.acquired, f.released)
  }
  func testDrainingCancellationReleasesExactPauseWithoutFactory() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let gate = IntakeGate()
    f.gate = gate
    let owner = f.owner()
    let id = try owner.start(f.request())
    await entered(gate)
    try owner.cancelBeforeRegistration(id)
    XCTAssertTrue(f.released.isEmpty)
    gate.open()
    guard case .refused = try await owner.wait(for: id) else {
      return XCTFail("Cancelled pre-registration")
    }
    XCTAssertEqual(f.factories, 0)
    XCTAssertEqual(f.acquired, f.released)
    try owner.requireSettled()
  }
  func testOrdinaryClaimTransfersAndResolvesOnlyOriginalRecord() async throws {
    let window = UUID()
    let tab = SessionTab()
    let session = await session(tabs: [tab], windowID: window)
    let claim = try session.claimImport(XCTUnwrap(session.unresolved.first))
    let f = try IntakeFixture(session: session, windowID: window)
    defer { f.cleanup() }
    let owner = f.owner()
    let handle = IntakeHandle(id: tab.id)
    let id = try owner.start(f.request(handle, provenance: .session(claim)))
    imported(try await owner.wait(for: id), tab.id)
    XCTAssertTrue(session.unresolved.isEmpty)
    XCTAssertThrowsError(try session.validateImport(claim))
    XCTAssertEqual(f.registry.adoptionStatus(documentID: tab.id), .active)
  }
  func testRecoveryClaimUnderPreservedSessionErrorCanTransferWithoutPublishing() async throws {
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "retained recovery", encoding: .utf8, hasBOM: false)
    let session = SessionCoordinator(
      loadSession: { throw IntakeFailure.injected },
      claimRecovery: { .init(snapshots: [snapshot], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Cannot rewrite preserved metadata") })
    await session.restore { prepared in
      Dictionary(uniqueKeysWithValues: prepared.tabs.map { ($0.metadata.id, "Held for intake") })
    }
    let entry = try XCTUnwrap(session.unresolved.first)
    let claim = try session.claimRecoveryImport(entry)
    let f = try IntakeFixture(session: session, windowID: entry.windowID)
    defer { f.cleanup() }
    let owner = f.owner()
    let handle = IntakeHandle(id: snapshot.id)
    let id = try owner.start(f.request(handle, provenance: .recovery(claim)))
    imported(try await owner.wait(for: id), handle.id)
    XCTAssertTrue(session.unresolved.isEmpty)
    XCTAssertFalse(session.startupErrors.isEmpty)
    XCTAssertThrowsError(try session.captureSession(windows: []))
    XCTAssertEqual(f.installs.count, 1)
  }
  func testReservedCapacityRefusesFreshBeforeFactory() async throws {
    let window = UUID()
    let session = await session(tabs: (0..<128).map { _ in SessionTab() }, windowID: window)
    XCTAssertEqual(session.unresolved.count, 128)
    let f = try IntakeFixture(session: session, windowID: window)
    defer { f.cleanup() }
    let owner = f.owner()
    let id = try owner.start(f.request())
    guard case .refused = try await owner.wait(for: id) else {
      return XCTFail("Reserved capacity must refuse")
    }
    XCTAssertEqual(f.factories, 0)
    XCTAssertTrue(f.acquired.isEmpty)
    XCTAssertEqual(session.unresolved.count, 128)
  }
  func testFactoryCallbackRegistryChangeRefusesBeforeRegistration() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    f.factoryCallback = { try f.registry.registerWindow(id: UUID(), initialGroupID: UUID()) }
    let owner = f.owner()
    let request = f.request()
    let id = try owner.start(request)
    guard case .refused = try await owner.wait(for: id) else {
      return XCTFail("Changed registry must refuse")
    }
    XCTAssertNil(f.registry.handle(id: request.documentID))
    XCTAssertTrue(f.installs.isEmpty)
    XCTAssertEqual(f.factories, 1)
    XCTAssertEqual(f.acquired, f.released)
  }
  func testActivationCallbackOtherResolutionRenewsExactOriginalClaim() async throws {
    let window = UUID()
    let tabs = [SessionTab(), SessionTab()]
    let session = await session(tabs: tabs, windowID: window)
    let entries = session.unresolved
    let claim = try session.claimImport(entries[0])
    let f = try IntakeFixture(session: session, windowID: window)
    defer { f.cleanup() }
    var fired = false
    f.registry.onChange = { _ in
      if !fired, f.registry.adoptionStatus(documentID: tabs[0].id) == .active {
        fired = true
        session.resolved(entries[1])
      }
    }
    let owner = f.owner()
    let handle = IntakeHandle(id: tabs[0].id)
    let id = try owner.start(f.request(handle, provenance: .session(claim)))
    imported(try await owner.wait(for: id), handle.id)
    XCTAssertTrue(fired)
    XCTAssertTrue(session.unresolved.isEmpty)
  }
  func testActivationCallbackRemovingOriginalRetainsOwnedModel() async throws {
    let window = UUID()
    let tab = SessionTab()
    let session = await session(tabs: [tab], windowID: window)
    let entry = try XCTUnwrap(session.unresolved.first)
    let claim = try session.claimImport(entry)
    let f = try IntakeFixture(session: session, windowID: window)
    defer { f.cleanup() }
    f.registry.onChange = { _ in
      if f.registry.adoptionStatus(documentID: tab.id) == .active { session.resolved(entry) }
    }
    let owner = f.owner()
    let handle = IntakeHandle(id: tab.id)
    let id = try owner.start(f.request(handle, provenance: .session(claim)))
    guard case .retained(let retained, _) = try await owner.wait(for: id) else {
      return XCTFail("Missing source requires reconciliation")
    }
    XCTAssertEqual(retained, handle.id)
    XCTAssertTrue(f.registry.handle(id: handle.id) === handle)
    XCTAssertEqual(f.registry.adoptionStatus(documentID: handle.id), .active)
    XCTAssertTrue(f.released.isEmpty)
    XCTAssertEqual(f.projects, 0)
    self.refuses { try owner.requireSettled() }
  }
  func testFactoryFailureReleasesOnlyItsPause() async throws {
    let f = try IntakeFixture(session: await session())
    defer { f.cleanup() }
    let other = try f.scheduler.acquirePause()
    try await f.scheduler.drainPause(other)
    f.factoryCallback = { throw IntakeFailure.injected }
    let owner = f.owner()
    let id = try owner.start(f.request())
    guard case .refused = try await owner.wait(for: id) else { return XCTFail("Factory refusal") }
    XCTAssertEqual(f.factories, 1)
    XCTAssertEqual(f.acquired, f.released)
    XCTAssertFalse(f.released.contains(other))
    try f.scheduler.releasePause(other)
    XCTAssertTrue(f.installs.isEmpty)
    try owner.requireSettled()
  }

  func testStartupIntakeHoldFeedsActualManagedPairedPublisher() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionStore = SessionStore(directory: directory.appendingPathComponent("session"))
    let recoveryDirectory = directory.appendingPathComponent("recovery")
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try sessionStore.save($0) },
      readCheckpointSession: { try sessionStore.load() })
    let session = await session()
    let registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID, readState: { ($0 as! IntakeHandle).state }))
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    var intake: ApplicationDocumentIntake?
    let publisher = ApplicationSessionCheckpoints(
      session: session, recovery: recovery,
      managed: .init(
        registry: registry,
        requireIntakeSettled: { try intake?.requireSettled() }, requireCloseSettled: {},
        validateProjection: { _ in },
        captureWindow: { window in
          let group = window.groups[0]
          let handles = try group.documentIDs.map { id -> IntakeHandle in
            try XCTUnwrap(registry.handle(id: id) as? IntakeHandle)
          }
          return .init(
            window: .init(
              id: window.id,
              tabs: handles.map { .init(id: $0.id, encoding: .utf16BE) },
              selectedTabID: group.selectedDocumentID),
            liveTabIDs: Set(group.documentIDs), recovery: try handles.map { try $0.capture() })
        }, preflightResources: { _ in }, renderStatus: { _, _ in }))
    let activation = try publisher.beginManagedActivation()
    try await publisher.drainManagedActivation(activation)
    intake = ApplicationDocumentIntake(
      registry: registry, session: session, recovery: recovery,
      publication: .init(
        acquirePause: { try publisher.acquireActivationPause(activation) },
        drainPause: { try await publisher.drainPause($0) },
        releasePause: { try publisher.releasePause($0) },
        requestCheckpoint: { publisher.requestCheckpoint() }),
      native: .init(
        requireApplicationAdmission: {}, validateDestination: { _ in },
        preflightResources: { _ in }, drainLegacyWrites: {},
        readState: { ($0 as! IntakeHandle).state },
        install: { try ($0 as! IntakeHandle).install($1, generation: $2) }, project: { _ in }))
    let owner = try XCTUnwrap(intake)
    let handle = IntakeHandle()
    let id = try owner.start(
      .init(
        documentID: handle.id, assignment: assignment,
        metadata: .init(pinned: false), index: 0, select: true,
        utf16Count: handle.text.utf16.count, originalByteCount: 0, provenance: .fresh,
        makeHandle: { handle }))
    imported(try await owner.wait(for: id), handle.id)
    XCTAssertEqual(
      publisher.lastAcknowledgedGeneration, 0, "Outer activation still prevents publication")
    try publisher.finishManagedActivation(activation)
    try await publisher.prepareQuit()
    try publisher.markNativeQuitPrepared()
    let receipt = try await publisher.commitFinal()
    XCTAssertEqual(receipt.recoveryAuthorities, [handle.id: try XCTUnwrap(handle.authority)])
    XCTAssertEqual(Set(receipt.recoveryRevisions.keys), [handle.id])
    XCTAssertEqual(receipt.generation, publisher.lastAcknowledgedGeneration)
    let persisted = try XCTUnwrap(sessionStore.load())
    XCTAssertEqual(persisted.windows.flatMap { $0.tabs.map(\.id) }, [handle.id])
    let reloaded = try RecoveryStore(directory: recoveryDirectory).loadReport().snapshots
    let snapshot = try XCTUnwrap(reloaded.first)
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(Array(snapshot.text.utf16), Array(handle.text.utf16))
    XCTAssertEqual(snapshot.encoding, .utf16BE)
    XCTAssertTrue(snapshot.hasBOM)
  }

}
