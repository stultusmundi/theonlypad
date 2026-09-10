import AppKit
import PadCore
import XCTest

@testable import NativeRouting

private enum NativeIntakeTestError: Error { case stale }
@MainActor private final class NativeIntakeFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
  var endpoint = UUID()
  var live = Set<UUID>()
  var projected = Set<UUID>()
  var failProjection = false
  var afterProject: (() -> Void)?
  var onValidate: ((UUID) -> Void)?
  let session: SessionCoordinator
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  var publisher: ApplicationSessionCheckpoints!
  var adapter: NativeDocumentIntakeController!
  init() throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    session = SessionCoordinator(
      loadSession: { nil }, claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
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
    live.insert(endpoint)
  }
  func connect() async throws {
    await session.restore { _ in [:] }
    publisher = ApplicationSessionCheckpoints(
      session: session, recovery: recovery,
      managed: .init(
        registry: registry, requireIntakeSettled: { try self.adapter?.requireSettled() },
        requireCloseSettled: {},
        validateProjection: { windows in
          guard Set(windows.flatMap { $0.groups.flatMap(\.documentIDs) }) == self.projected else {
            throw NativeIntakeTestError.stale
          }
        },
        captureWindow: { window in
          let models = window.groups.flatMap(\.documentIDs).map {
            self.registry.handle(id: $0) as! EditorDocument
          }
          let items = try models.map { model -> RecoveryCheckpointItem in
            let value = try model.captureAuthorizedRecovery()
            return .init(
              id: model.id, revision: value.revision, snapshot: value.snapshot,
              authority: value.authority)
          }
          return .init(
            window: .init(
              id: window.id, tabs: models.map { .init(id: $0.id, encoding: $0.encoding) },
              selectedTabID: window.groups.first?.selectedDocumentID),
            liveTabIDs: Set(models.map(\.id)), recovery: items)
        }, preflightResources: { _ in }, renderStatus: { _, _ in }))
    adapter = NativeDocumentIntakeController(
      registry: registry, session: session, recovery: recovery,
      publication: .init(
        acquirePause: { try self.publisher.acquirePause() },
        drainPause: { try await self.publisher.drainPause($0) },
        releasePause: { try self.publisher.releasePause($0) },
        requestCheckpoint: { self.publisher.requestCheckpoint() }),
      destinations: .init(
        requireAdmission: {},
        validate: { id, assignment in
          self.onValidate?(id)
          guard self.live.contains(id), assignment == self.assignment else {
            throw NativeIntakeTestError.stale
          }
        }, exists: { self.live.contains($0) },
        resolveSelection: { _, _, selection in
          if case .preserve = selection { return false }
          return true
        }, drainLegacyWrites: {},
        project: { id, _ in
          guard self.live.contains(id), !self.failProjection else {
            throw NativeIntakeTestError.stale
          }
          self.projected = Set(
            try self.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) })
          self.afterProject?()
        }))
    let activation = try publisher.beginManagedActivation()
    try await publisher.drainManagedActivation(activation)
    try publisher.finishManagedActivation(activation)
  }
  func submission(_ seed: NativeDocumentSeed) -> EditorPreparedSubmission {
    let original = endpoint
    return .init(
      endpointID: original, assignment: assignment, seed: seed, provenance: .fresh,
      selection: .select,
      requireDestinationCurrent: {
        guard self.live.contains(original) else { throw NativeIntakeTestError.stale }
      })
  }
  func cleanup() async {
    if let token = try? publisher.acquirePause() { try? await publisher.drainPause(token) }
    try? FileManager.default.removeItem(at: directory)
  }
}
@MainActor final class NativeDocumentIntakeTests: XCTestCase {
  func testNativeSeedCreatesManagedModelAndPairedRecovery() async throws {
    let f = try NativeIntakeFixture()
    try await f.connect()
    let seed = try NativeDocumentSeed.diskCopy(
      sourceName: "sample.py",
      decoded: .init(text: "print('😀')\r\n", encoding: .utf16BE, hasBOM: true))
    let id = try f.adapter.submit(f.submission(seed))
    guard case .imported(let modelID) = try await f.adapter.wait(for: id) else {
      return XCTFail("Import required")
    }
    let model = try XCTUnwrap(f.registry.handle(id: modelID) as? EditorDocument)
    XCTAssertEqual(model.storage.string, seed.text)
    XCTAssertNil(model.url)
    XCTAssertNotNil(model.recoveryAuthority)
    try f.adapter.requireSettled()
    try await f.publisher.prepareQuit()
    try f.publisher.markNativeQuitPrepared()
    _ = try await f.publisher.commitFinal()
    let recovered = try RecoveryStore(directory: f.directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(recovered.first?.text, seed.text)
    XCTAssertEqual(recovered.first?.encoding, .utf16BE)
    await f.cleanup()
  }
  func testLostEndpointReconcilesSameModelAndAuthority() async throws {
    let f = try NativeIntakeFixture()
    try await f.connect()
    let seed = try NativeDocumentSeed.scratch()
    f.registry.onChange = { _ in
      if f.registry.adoptionStatus(documentID: seed.id) == .active { f.live.remove(f.endpoint) }
    }
    let id = try f.adapter.submit(f.submission(seed))
    guard case .retained = try await f.adapter.wait(for: id) else {
      return XCTFail("Loss must retain")
    }
    let model = try XCTUnwrap(f.registry.handle(id: seed.id) as? EditorDocument)
    let authority = model.recoveryAuthority
    f.registry.onChange = nil
    let replacement = UUID()
    f.live.insert(replacement)
    try f.adapter.reconcileDestination(id, endpointID: replacement)
    try f.adapter.retry(id)
    guard case .imported = try await f.adapter.wait(for: id) else {
      return XCTFail("Retry required")
    }
    XCTAssertTrue(f.registry.handle(id: seed.id) === model)
    XCTAssertEqual(model.recoveryAuthority, authority)
    await f.cleanup()
  }
  func testProjectionEndpointLossRetainsInsteadOfReportingImported() async throws {
    let f = try NativeIntakeFixture()
    try await f.connect()
    f.afterProject = { f.live.remove(f.endpoint) }
    let seed = try NativeDocumentSeed.scratch()
    let id = try f.adapter.submit(f.submission(seed))
    guard case .retained = try await f.adapter.wait(for: id) else {
      return XCTFail("Projection loss must retain")
    }
    XCTAssertNotNil(f.registry.handle(id: seed.id))
    XCTAssertThrowsError(try f.adapter.requireSettled())
    await f.cleanup()
  }
  func testReconciliationRejectsRecreatedOldEndpointAndChangedOwnership() async throws {
    let f = try NativeIntakeFixture()
    try await f.connect()
    f.failProjection = true
    let seed = try NativeDocumentSeed.scratch()
    let id = try f.adapter.submit(f.submission(seed))
    guard case .retained = try await f.adapter.wait(for: id) else {
      return XCTFail("Projection held")
    }
    let replacement = UUID()
    f.live.insert(replacement)
    XCTAssertThrowsError(try f.adapter.reconcileDestination(id, endpointID: replacement))
    f.live.remove(f.endpoint)
    f.onValidate = { _ in f.live.insert(f.endpoint) }
    XCTAssertThrowsError(try f.adapter.reconcileDestination(id, endpointID: replacement))
    f.live.remove(f.endpoint)
    let model = try XCTUnwrap(f.registry.handle(id: seed.id) as? EditorDocument)
    f.onValidate = { _ in model.advanceOwnershipGeneration() }
    XCTAssertThrowsError(try f.adapter.reconcileDestination(id, endpointID: replacement))
    await f.cleanup()
  }
  func testPreparedInsertionIndexPreservesRequestedTabOrder() async throws {
    let f = try NativeIntakeFixture()
    try await f.connect()
    let first = try NativeDocumentSeed.scratch()
    let last = try NativeDocumentSeed.scratch()
    let middle = try NativeDocumentSeed.scratch()
    for seed in [first, last] {
      let id = try f.adapter.submit(f.submission(seed))
      guard case .imported = try await f.adapter.wait(for: id) else {
        return XCTFail("Initial imports required")
      }
    }
    var submission = f.submission(middle)
    submission.insertionIndex = 1
    let id = try f.adapter.submit(submission)
    guard case .imported = try await f.adapter.wait(for: id) else {
      return XCTFail("Middle import required")
    }
    XCTAssertEqual(
      f.registry.window(id: f.assignment.windowID)?.groups.first?.documentIDs,
      [first.id, middle.id, last.id])
    await f.cleanup()
  }
  func testMissingEndpointRefusesBeforeNativeFactory() async throws {
    let f = try NativeIntakeFixture()
    try await f.connect()
    let seed = try NativeDocumentSeed.scratch()
    f.live.removeAll()
    XCTAssertThrowsError(try f.adapter.submit(f.submission(seed)))
    XCTAssertNil(f.registry.handle(id: seed.id))
    await f.cleanup()
  }
}
