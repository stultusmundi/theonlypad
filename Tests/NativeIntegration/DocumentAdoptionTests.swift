import Foundation
import PadCore
import XCTest

@testable import DocumentRegistry

@MainActor private final class AdoptionHandle: WorkspaceDocumentHandle {
  var id = UUID()
  var ownershipGeneration = UUID()
  var workspaceKind: WorkspaceDocumentKind = .editable
  var authority: RecoveryWriteAuthority?
  var highest: UInt64 = 0
  var read: (() -> Void)?
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentAdoptionState {
    read?()
    return .init(
      documentID: id, ownershipGeneration: ownershipGeneration,
      authority: authority, highestIssuedRevision: highest)
  }
  var closeState: DocumentCloseState {
    .init(
      kind: workspaceKind, ownershipGeneration: ownershipGeneration,
      mutationGeneration: ownershipGeneration, operationID: nil, isDirty: false,
      hasPendingPublication: false, hasPendingTextEdits: false, isComposing: false,
      canRetainCleanHistory: true)
  }
}
@MainActor final class DocumentAdoptionTests: XCTestCase {
  private func refuses(_ operation: () throws -> Void) {
    do {
      try operation()
      XCTFail("Expected refusal")
    } catch {}
  }
  private func setup(_ coordinatorID: UUID = UUID()) throws -> (
    ApplicationDocuments, DocumentAssignment
  ) {
    let registry = ApplicationDocuments(
      closeServices: .init { ($0 as! AdoptionHandle).closeState },
      adoptionServices: .init(
        coordinatorID: coordinatorID, readState: { ($0 as! AdoptionHandle).state }))
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    return (registry, assignment)
  }
  private func insert(
    _ registry: ApplicationDocuments, _ assignment: DocumentAssignment,
    _ handle: AdoptionHandle, request: UUID = UUID()
  ) throws -> DocumentAdoptionLease {
    try registry.registerPending(
      handle, requestID: request, expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: true), in: assignment, at: 0, select: true)
  }
  private func receipt(_ handle: AdoptionHandle, _ coordinator: UUID, next: UInt64 = 1)
    -> RecoveryAdoptionReceipt
  {
    .init(
      authority: .init(coordinatorID: coordinator, documentID: handle.id, epoch: UUID()),
      nextRevision: next)
  }
  private func install(_ receipt: RecoveryAdoptionReceipt, on handle: AdoptionHandle) {
    handle.authority = receipt.authority
    handle.highest = receipt.nextRevision - 1
  }
  func testPendingPublishedBeforeCallbacksAndStronglyRetained() throws {
    let (registry, assignment) = try setup()
    var handle: AdoptionHandle? = AdoptionHandle()
    weak var weakHandle = handle
    let id = handle!.id
    var notified = false
    registry.onChange = { _ in
      notified = true
      XCTAssertTrue(registry.handle(id: id) === handle)
      guard case .pending = registry.adoptionStatus(documentID: id) else {
        return XCTFail("pending before notification")
      }
      for action in DocumentAdmission.allCases {
        XCTAssertFalse(registry.allows(action, documentID: id))
      }
      self.refuses { _ = try registry.requestClose(documentID: id) }
      self.refuses { _ = try registry.captureReadyWindows() }
      XCTAssertEqual(try? registry.captureWindows().first?.groups.first?.documentIDs, [id])
    }
    let lease = try insert(registry, assignment, handle!)
    XCTAssertTrue(notified)
    XCTAssertEqual(lease.assignment, assignment)
    registry.onChange = nil
    handle = nil
    XCTAssertNotNil(weakHandle)
  }
  func testSiblingMetadataBlockedButIndependentWindowRemainsOpen() throws {
    let (registry, assignment) = try setup()
    let sibling = AdoptionHandle()
    try registry.registerDocument(
      sibling, metadata: .init(pinned: false), in: assignment, at: 0, select: true)
    let pending = AdoptionHandle()
    _ = try insert(registry, assignment, pending)
    let before = try registry.captureWindows()
    XCTAssertFalse(registry.allows(.select, documentID: sibling.id))
    XCTAssertThrowsError(
      try registry.selectDocument(
        sibling.id, in: assignment, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(
      try registry.setPinned(
        true, documentID: sibling.id, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(
      try registry.reorderDocument(sibling.id, to: 0, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(
      try registry.registerDocument(
        AdoptionHandle(), metadata: .init(pinned: false), in: assignment, at: 0, select: false))
    XCTAssertThrowsError(
      try registry.setGroupAxis(
        .stacked, windowID: assignment.windowID, expectedRevision: registry.workspaceRevision))
    XCTAssertEqual(try registry.captureWindows(), before)
    let other = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: other.windowID, initialGroupID: other.groupID)
    let live = AdoptionHandle()
    try registry.registerDocument(
      live, metadata: .init(pinned: false), in: other, at: 0, select: true)
    XCTAssertTrue(registry.allows(.edit, documentID: live.id))
    try registry.setPinned(true, documentID: live.id, expectedRevision: registry.workspaceRevision)
  }
  func testFailureRetryExactAttemptAndReceiptRetained() throws {
    let coordinator = UUID()
    let (registry, assignment) = try setup(coordinator)
    let handle = AdoptionHandle()
    let first = try insert(registry, assignment, handle)
    let adopted = receipt(handle, coordinator, next: 9)
    install(adopted, on: handle)
    try registry.failAdoption(first)
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .failed(first))
    XCTAssertThrowsError(try registry.captureReadyWindows())
    let retry = try registry.retryAdoption(first)
    XCTAssertNotEqual(first.attemptID, retry.attemptID)
    XCTAssertEqual(retry.requestID, first.requestID)
    XCTAssertThrowsError(try registry.failAdoption(first))
    XCTAssertThrowsError(try registry.retryAdoption(first))
    XCTAssertThrowsError(try registry.activateAdoption(first, receipt: adopted))
    try registry.activateAdoption(retry, receipt: adopted)
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .active)
    XCTAssertEqual(handle.highest, 8)
    XCTAssertEqual(handle.authority, adopted.authority)
    XCTAssertThrowsError(try registry.activateAdoption(retry, receipt: adopted))
    XCTAssertThrowsError(try registry.failAdoption(retry))
    XCTAssertNoThrow(try registry.captureReadyWindows())
  }
  func testActivationRejectsForeignUninstalledAndPrematurelyIssuedAuthority() throws {
    let coordinator = UUID()
    let (registry, assignment) = try setup(coordinator)
    let handle = AdoptionHandle()
    let lease = try insert(registry, assignment, handle)
    let good = receipt(handle, coordinator)
    XCTAssertThrowsError(try registry.activateAdoption(lease, receipt: good))
    let foreign = receipt(handle, UUID())
    install(foreign, on: handle)
    XCTAssertThrowsError(try registry.activateAdoption(lease, receipt: foreign))
    install(good, on: handle)
    XCTAssertThrowsError(
      try registry.activateAdoption(
        lease, receipt: .init(authority: good.authority, nextRevision: 0)))
    handle.highest = 1
    XCTAssertThrowsError(try registry.activateAdoption(lease, receipt: good))
    handle.highest = 0
    let otherDoc = RecoveryAdoptionReceipt(
      authority: .init(coordinatorID: coordinator, documentID: UUID(), epoch: UUID()),
      nextRevision: 1)
    handle.authority = otherDoc.authority
    XCTAssertThrowsError(try registry.activateAdoption(lease, receipt: otherDoc))
    install(good, on: handle)
    try registry.activateAdoption(lease, receipt: good)
  }
  func testWrongRegistryOwnershipAndRequestReplayRefused() throws {
    let coordinator = UUID()
    let (registry, assignment) = try setup(coordinator)
    let (other, _) = try setup(coordinator)
    let handle = AdoptionHandle()
    let request = UUID()
    let lease = try insert(registry, assignment, handle, request: request)
    let adopted = receipt(handle, coordinator)
    install(adopted, on: handle)
    XCTAssertThrowsError(try other.activateAdoption(lease, receipt: adopted))
    handle.advanceOwnershipGeneration()
    XCTAssertThrowsError(try registry.activateAdoption(lease, receipt: adopted))
    XCTAssertThrowsError(try registry.retryAdoption(lease))
    XCTAssertTrue(registry.handle(id: handle.id) === handle)
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .pending(lease))
    let second = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: second.windowID, initialGroupID: second.groupID)
    XCTAssertThrowsError(try insert(registry, second, AdoptionHandle(), request: request))
    XCTAssertTrue(registry.window(id: second.windowID)!.groups[0].documentIDs.isEmpty)
  }
  func testReadStateReentryAndOwnershipChangeRefuseBeforeInsertion() throws {
    let (registry, assignment) = try setup()
    let handle = AdoptionHandle()
    handle.read = {
      self.refuses { try registry.registerWindow(id: UUID(), initialGroupID: UUID()) }
      handle.advanceOwnershipGeneration()
    }
    XCTAssertThrowsError(try insert(registry, assignment, handle))
    XCTAssertNil(registry.handle(id: handle.id))
    XCTAssertTrue(try registry.captureWindows()[0].groups[0].documentIDs.isEmpty)
    handle.read = nil
    _ = try insert(registry, assignment, handle)
  }
  func testActivationReadStateMutationAndReentrantNotificationPreserveNewState() throws {
    let coordinator = UUID()
    let (registry, assignment) = try setup(coordinator)
    let handle = AdoptionHandle()
    let lease = try insert(registry, assignment, handle)
    let adopted = receipt(handle, coordinator)
    install(adopted, on: handle)
    let original = handle.ownershipGeneration
    handle.read = { handle.advanceOwnershipGeneration() }
    XCTAssertThrowsError(try registry.activateAdoption(lease, receipt: adopted))
    handle.ownershipGeneration = original
    handle.read = nil
    registry.onChange = { _ in
      registry.onChange = nil
      do {
        let ticket = try registry.beginClose(
          registry.requestClose(documentID: handle.id), disposition: .discardWithoutHistory)
        XCTAssertEqual(registry.closeStatus(documentID: handle.id), .closing(ticketID: ticket.id))
      } catch { XCTFail("activation callback must see ready record: \(error)") }
    }
    try registry.activateAdoption(lease, receipt: adopted)
    XCTAssertFalse(registry.allows(.edit, documentID: handle.id))
    XCTAssertThrowsError(try registry.captureReadyWindows())
  }
  func testUnmanagedCompatibilityAndInvalidRegistrationHaveNoSideEffects() throws {
    let (registry, assignment) = try setup()
    let handle = AdoptionHandle()
    handle.workspaceKind = .streaming
    XCTAssertThrowsError(try insert(registry, assignment, handle))
    XCTAssertNil(registry.handle(id: handle.id))
    try registry.registerDocument(
      handle, metadata: .init(pinned: false), in: assignment, at: 0, select: true)
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .unmanaged)
    XCTAssertNoThrow(try registry.captureReadyWindows())
    XCTAssertTrue(registry.allows(.edit, documentID: handle.id))
    let missing = ApplicationDocuments()
    let location = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try missing.registerWindow(id: location.windowID, initialGroupID: location.groupID)
    XCTAssertThrowsError(try insert(missing, location, AdoptionHandle()))
    XCTAssertTrue(try missing.captureWindows()[0].groups[0].documentIDs.isEmpty)
  }
  func testFailureNotificationCanRetryWithoutOuterCleanupOverwritingAttempt() throws {
    let coordinator = UUID()
    let (registry, assignment) = try setup(coordinator)
    let handle = AdoptionHandle()
    let lease = try insert(registry, assignment, handle)
    var retry: DocumentAdoptionLease?
    registry.onChange = { _ in
      registry.onChange = nil
      guard case .failed(let notified) = registry.adoptionStatus(documentID: handle.id) else {
        return XCTFail("failure must be published before callback")
      }
      do { retry = try registry.retryAdoption(notified) } catch { XCTFail("\(error)") }
    }
    try registry.failAdoption(lease)
    let newer = try XCTUnwrap(retry)
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .pending(newer))
    XCTAssertThrowsError(try registry.failAdoption(lease))
    let adopted = receipt(handle, coordinator)
    install(adopted, on: handle)
    try registry.activateAdoption(newer, receipt: adopted)
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .active)
  }
  func testCapacityAndStaleRegistrationRefuseBeforeStateCallback() throws {
    let (registry, assignment) = try setup()
    let handle = AdoptionHandle()
    var reads = 0
    handle.read = { reads += 1 }
    XCTAssertThrowsError(
      try registry.registerPending(
        handle, requestID: UUID(), expectedRevision: UUID(),
        metadata: .init(pinned: false), in: assignment, at: 0, select: true))
    XCTAssertEqual(reads, 0)
    for index in 0..<128 {
      try registry.registerDocument(
        AdoptionHandle(), metadata: .init(pinned: false),
        in: assignment, at: index, select: false)
    }
    let before = try registry.captureWindows()
    XCTAssertThrowsError(try insert(registry, assignment, handle))
    XCTAssertEqual(reads, 0)
    XCTAssertNil(registry.handle(id: handle.id))
    XCTAssertEqual(try registry.captureWindows(), before)
  }
  func testRealActorIdentityAndReceiptActivateWithoutCachedEpoch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let actor = RecoveryCoordinator(directory: directory)
    let expected = actor.coordinatorID
    let (registry, assignment) = try setup(expected)
    let handle = AdoptionHandle()
    let lease = try insert(registry, assignment, handle)
    let adopted = try await actor.adoptManagedDocument(id: handle.id)
    XCTAssertEqual(adopted.authority.coordinatorID, expected)
    install(adopted, on: handle)
    try registry.activateAdoption(lease, receipt: adopted)
    // Readiness is not a cached writer token. A later repair may replace the model epoch.
    handle.authority = .init(coordinatorID: expected, documentID: handle.id, epoch: UUID())
    XCTAssertEqual(registry.adoptionStatus(documentID: handle.id), .active)
    XCTAssertNoThrow(try registry.captureReadyWindows())
  }
}
