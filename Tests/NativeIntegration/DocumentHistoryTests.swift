import Foundation
import PadCore
import XCTest

@testable import DocumentRegistry

@MainActor private final class HistoryHandle: WorkspaceDocumentHandle {
  var id = UUID()
  var ownershipGeneration = UUID()
  var mutation = UUID()
  var workspaceKind: WorkspaceDocumentKind { .editable }
  var authority: RecoveryWriteAuthority?
  var highest: UInt64 = 0
  var dirty = false
  var onRead: (() -> Void)?
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentCloseState {
    onRead?()
    return .init(
      kind: .editable, ownershipGeneration: ownershipGeneration,
      mutationGeneration: mutation, operationID: nil, isDirty: dirty,
      hasPendingPublication: false, hasPendingTextEdits: false, isComposing: false,
      canRetainCleanHistory: true)
  }
  var adoption: DocumentAdoptionState {
    .init(
      documentID: id, ownershipGeneration: ownershipGeneration, authority: authority,
      highestIssuedRevision: highest)
  }
}
@MainActor final class DocumentHistoryTests: XCTestCase {
  private func fixture(_ coordinator: UUID = UUID()) throws -> (
    ApplicationDocuments, DocumentAssignment
  ) {
    let registry = ApplicationDocuments(
      closeServices: .init { ($0 as! HistoryHandle).state },
      adoptionServices: .init(
        coordinatorID: coordinator, readState: { ($0 as! HistoryHandle).adoption }))
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    return (registry, assignment)
  }
  private func close(
    _ registry: ApplicationDocuments, _ assignment: DocumentAssignment,
    supplied: HistoryHandle? = nil
  ) throws -> HistoryHandle {
    let handle = supplied ?? HistoryHandle()
    try registry.registerDocument(
      handle, metadata: .init(pinned: false), in: assignment,
      at: 0, select: true)
    let ticket = try registry.beginClose(
      registry.requestClose(documentID: handle.id),
      disposition: .retainCleanHistory)
    guard case .closed = try registry.completeClose(ticket, result: .removed) else {
      XCTFail("Real registry close must produce history")
      return handle
    }
    return handle
  }
  private func refuses(_ block: () throws -> Void) {
    do {
      try block()
      XCTFail("Expected refusal")
    } catch {}
  }
  func testRealCloseClaimSurvivesUnrelatedHistoryAndReadDoesNotNotify() throws {
    let (registry, assignment) = try fixture()
    let first = try close(registry, assignment)
    let replacementID = UUID()
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: replacementID))
    XCTAssertEqual(claim.sourceDocumentID, first.id)
    XCTAssertEqual(claim.replacementID, replacementID)
    _ = try close(registry, assignment)
    var notices = 0
    registry.onChange = { _ in notices += 1 }
    let revision = registry.workspaceRevision
    try registry.validateHistory(claim)
    let same = try registry.withHistorySource(claim) { $0 === first }
    XCTAssertTrue(same)
    XCTAssertEqual(notices, 0)
    XCTAssertEqual(registry.workspaceRevision, revision)
  }
  func testMutationBeforePeekAndAfterClaimRefusesEvenIfCleanAgain() throws {
    let (registry, assignment) = try fixture()
    let first = try close(registry, assignment)
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    first.mutation = UUID()
    XCTAssertThrowsError(try registry.validateHistory(claim))
    XCTAssertThrowsError(
      try registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    XCTAssertEqual(registry.closedHistoryCount(windowID: assignment.windowID), 1)
  }
  func testPeekAndReadBlockRegistryReentryAndRejectCallbackMutation() throws {
    let (registry, assignment) = try fixture()
    let first = try close(registry, assignment)
    first.onRead = {
      self.refuses { try registry.registerWindow(id: UUID(), initialGroupID: UUID()) }
    }
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    first.onRead = nil
    XCTAssertThrowsError(
      try registry.withHistorySource(claim) { source in
        self.refuses { try registry.registerWindow(id: UUID(), initialGroupID: UUID()) }
        (source as! HistoryHandle).mutation = UUID()
        return 1
      })
    XCTAssertEqual(registry.closedHistoryCount(windowID: assignment.windowID), 1)
  }
  func testForeignEvictedAndWindowRemovedClaimsRefuse() throws {
    let (registry, assignment) = try fixture()
    _ = try close(registry, assignment)
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    let (foreign, _) = try fixture()
    XCTAssertThrowsError(try foreign.validateHistory(claim))
    for _ in 0..<10 { _ = try close(registry, assignment) }
    XCTAssertEqual(registry.closedHistoryCount(windowID: assignment.windowID), 10)
    XCTAssertThrowsError(try registry.validateHistory(claim))
    let latest = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    try registry.unregisterEmptyWindow(
      assignment.windowID, expectedRevision: registry.workspaceRevision)
    XCTAssertThrowsError(try registry.validateHistory(latest))
    XCTAssertTrue(registry.containsReservedID(claim.sourceDocumentID))
  }
  func testConsumeRequiresActualActiveFreshReplacementAndIsExactlyOnce() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let actor = RecoveryCoordinator(directory: directory)
    let (registry, assignment) = try fixture(actor.coordinatorID)
    let source = try close(registry, assignment)
    let replacement = HistoryHandle()
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: replacement.id))
    XCTAssertThrowsError(try registry.consumeHistory(claim, replacementID: replacement.id))
    let lease = try registry.registerPending(
      replacement, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: claim.metadata, in: assignment, at: 0, select: true)
    XCTAssertThrowsError(try registry.consumeHistory(claim, replacementID: replacement.id))
    let receipt = try await actor.adoptManagedDocument(id: replacement.id)
    replacement.authority = receipt.authority
    replacement.highest = receipt.nextRevision - 1
    try registry.activateAdoption(lease, receipt: receipt)
    XCTAssertThrowsError(try registry.consumeHistory(claim, replacementID: UUID()))
    var notifications = 0
    registry.onChange = { _ in
      notifications += 1
      self.refuses { try registry.validateHistory(claim) }
      XCTAssertEqual(registry.closedHistoryCount(windowID: assignment.windowID), 0)
    }
    try registry.consumeHistory(claim, replacementID: replacement.id)
    XCTAssertEqual(notifications, 1)
    XCTAssertThrowsError(try registry.consumeHistory(claim, replacementID: replacement.id))
    XCTAssertTrue(registry.containsReservedID(source.id))
    XCTAssertTrue(registry.handle(id: replacement.id) === replacement)
    XCTAssertThrowsError(
      try registry.registerDocument(
        source, metadata: .init(pinned: false), in: assignment, at: 0, select: false))
  }
  func testChangedSourceUUIDBeforeFirstPeekCannotAcquireNewHistoryIdentity() throws {
    let (registry, assignment) = try fixture()
    let source = try close(registry, assignment)
    let original = source.id
    source.id = UUID()
    XCTAssertThrowsError(
      try registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    XCTAssertTrue(registry.containsReservedID(original))
    XCTAssertEqual(registry.closedHistoryCount(windowID: assignment.windowID), 1)
  }

  func testClaimRetainsSourceAfterEvictionButDoesNotAuthorizeIt() throws {
    let (registry, assignment) = try fixture()
    var source: HistoryHandle? = try close(registry, assignment)
    weak var weakSource = source
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: UUID()))
    source = nil
    for _ in 0..<10 { _ = try close(registry, assignment) }
    XCTAssertNotNil(weakSource)
    XCTAssertThrowsError(
      try registry.withHistorySource(claim) { _ in XCTFail("Evicted source cannot be read") })
  }
  func testReservedReplacementAndActiveReplacementInOtherWindowRefuse() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let actor = RecoveryCoordinator(directory: directory)
    let (registry, assignment) = try fixture(actor.coordinatorID)
    let source = try close(registry, assignment)
    XCTAssertThrowsError(
      try registry.peekHistory(windowID: assignment.windowID, replacementID: source.id))
    XCTAssertThrowsError(
      try registry.peekHistory(windowID: assignment.windowID, replacementID: assignment.windowID))
    let replacement = HistoryHandle()
    let claim = try XCTUnwrap(
      registry.peekHistory(windowID: assignment.windowID, replacementID: replacement.id))
    let other = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: other.windowID, initialGroupID: other.groupID)
    let lease = try registry.registerPending(
      replacement, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: false), in: other, at: 0, select: true)
    let receipt = try await actor.adoptManagedDocument(id: replacement.id)
    replacement.authority = receipt.authority
    replacement.highest = receipt.nextRevision - 1
    try registry.activateAdoption(lease, receipt: receipt)
    XCTAssertThrowsError(try registry.consumeHistory(claim, replacementID: replacement.id))
    XCTAssertEqual(registry.closedHistoryCount(windowID: assignment.windowID), 1)
    try registry.validateHistory(claim)
  }

}
