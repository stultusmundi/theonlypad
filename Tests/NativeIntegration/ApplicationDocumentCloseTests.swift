import Foundation
import XCTest

@testable import DocumentRegistry

@MainActor private final class CloseHandle: WorkspaceDocumentHandle {
  var id = UUID()
  var ownershipGeneration = UUID()
  var workspaceKind: WorkspaceDocumentKind = .editable
  var mutation = UUID()
  var dirty = false
  var pending = false
  var editing = false
  var composing = false
  var operation: UUID?
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
  var state: DocumentCloseState {
    .init(
      kind: workspaceKind, ownershipGeneration: ownershipGeneration,
      mutationGeneration: mutation, operationID: operation, isDirty: dirty,
      hasPendingPublication: pending, hasPendingTextEdits: editing,
      isComposing: composing, canRetainCleanHistory: true)
  }
}
private enum CloseFailure: Error { case disk }
@MainActor final class ApplicationDocumentCloseTests: XCTestCase {
  private func setup() throws -> (ApplicationDocuments, CloseHandle, DocumentAssignment) {
    let registry = ApplicationDocuments(closeServices: .init { ($0 as! CloseHandle).state })
    let location = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: location.windowID, initialGroupID: location.groupID)
    let handle = CloseHandle()
    try registry.registerDocument(
      handle, metadata: .init(pinned: false), in: location, at: 0, select: true)
    return (registry, handle, location)
  }
  private func ticket(
    _ registry: ApplicationDocuments, _ handle: CloseHandle,
    disposition: DocumentCloseDisposition = .discardWithoutHistory
  ) throws -> DocumentCloseTicket {
    try registry.beginClose(registry.requestClose(documentID: handle.id), disposition: disposition)
  }
  private func receipt(_ attempt: DocumentRecoveryAttempt) -> DocumentRecoveryReceipt {
    .init(
      attemptID: attempt.id, repairID: attempt.repairID, documentID: attempt.documentID,
      mutationGeneration: attempt.state.mutationGeneration, publicationID: UUID())
  }
  func testUnavailableWithoutInventedState() throws {
    let registry = ApplicationDocuments()
    XCTAssertThrowsError(try registry.requestClose(documentID: UUID())) {
      XCTAssertEqual($0 as? DocumentRegistryError, .closeUnavailable)
    }
  }
  func testLeaseFreezesAdmissionAndAffectedGroupUntilFailure() throws {
    let (registry, handle, location) = try setup()
    let close = try ticket(registry, handle)
    for action in DocumentAdmission.allCases {
      XCTAssertFalse(registry.allows(action, documentID: handle.id))
    }
    XCTAssertTrue(registry.handle(id: handle.id) === handle)
    XCTAssertThrowsError(
      try registry.setPinned(
        true, documentID: handle.id, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(
      try registry.setGroupAxis(
        .stacked, windowID: location.windowID, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(
      try registry.reorderDocument(handle.id, to: 0, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(
      try registry.selectDocument(
        handle.id, in: location, expectedRevision: registry.workspaceRevision))
    XCTAssertEqual(try registry.captureWindows().first?.groups.first?.documentIDs, [handle.id])
    if case .retained(let error) = try registry.completeClose(
      close, result: .notRemoved(CloseFailure.disk))
    {
      XCTAssertTrue(error is CloseFailure)
    } else {
      XCTFail("Expected retained failure")
    }
    XCTAssertTrue(registry.allows(.edit, documentID: handle.id))
  }
  func testOldRequestCannotStartAnotherCycleAfterSafeFailure() throws {
    let (registry, handle, _) = try setup()
    let request = try registry.requestClose(documentID: handle.id)
    let close = try registry.beginClose(request, disposition: .discardWithoutHistory)
    _ = try registry.completeClose(close, result: .notRemoved(CloseFailure.disk))
    XCTAssertThrowsError(try registry.beginClose(request, disposition: .discardWithoutHistory))
    _ = try ticket(registry, handle)
  }
  func testRequestIsPureAndChangedConfirmationRejected() throws {
    let (registry, handle, _) = try setup()
    let revision = registry.workspaceRevision
    var notices = 0
    registry.onChange = { _ in notices += 1 }
    let request = try registry.requestClose(documentID: handle.id)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertEqual(notices, 0)
    handle.mutation = UUID()
    XCTAssertThrowsError(try registry.beginClose(request, disposition: .discardWithoutHistory))
    XCTAssertTrue(registry.allows(.edit, documentID: handle.id))
    XCTAssertEqual(notices, 0)
  }
  func testUnsafeStatesAndStreamingHistoryRefused() throws {
    let (registry, handle, _) = try setup()
    for index in 0..<4 {
      handle.operation = index == 0 ? UUID() : nil
      handle.composing = index == 1
      handle.editing = index == 2
      handle.pending = index == 3
      XCTAssertThrowsError(try registry.requestClose(documentID: handle.id))
    }
    handle.pending = false
    handle.workspaceKind = .streaming
    XCTAssertThrowsError(try ticket(registry, handle, disposition: .retainCleanHistory))
    handle.workspaceKind = .editable
    handle.dirty = true
    XCTAssertThrowsError(try ticket(registry, handle, disposition: .retainCleanHistory))
    _ = try ticket(registry, handle)
  }
  func testReadStateReentryAndFailureNeverAcquireLease() throws {
    var registry: ApplicationDocuments!
    var throwsState = false
    registry = ApplicationDocuments(
      closeServices: .init { handle in
        XCTAssertThrowsError(try registry.captureWindows())
        XCTAssertThrowsError(try registry.registerWindow(id: UUID(), initialGroupID: UUID()))
        if throwsState { throw CloseFailure.disk }
        return (handle as! CloseHandle).state
      })
    let location = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: location.windowID, initialGroupID: location.groupID)
    let handle = CloseHandle()
    try registry.registerDocument(
      handle, metadata: .init(pinned: false), in: location, at: 0, select: true)
    _ = try registry.requestClose(documentID: handle.id)
    throwsState = true
    let revision = registry.workspaceRevision
    XCTAssertThrowsError(try registry.requestClose(documentID: handle.id))
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertTrue(registry.allows(.edit, documentID: handle.id))
  }
  func testSuccessfulCloseRetiresUUIDAndRetainsHistoryObjectReservation() throws {
    let (registry, handle, location) = try setup()
    let retired = handle.id
    let close = try ticket(registry, handle, disposition: .retainCleanHistory)
    if case .closed = try registry.completeClose(close, result: .removed) {} else { XCTFail() }
    XCTAssertNil(registry.handle(id: retired))
    XCTAssertEqual(registry.closedHistoryCount(windowID: location.windowID), 1)
    let replacement = CloseHandle()
    replacement.id = retired
    XCTAssertThrowsError(
      try registry.registerDocument(
        replacement, metadata: .init(pinned: false), in: location, at: 0, select: true))
    handle.id = UUID()
    XCTAssertThrowsError(
      try registry.registerDocument(
        handle, metadata: .init(pinned: false), in: location, at: 0, select: true))
    XCTAssertThrowsError(try registry.completeClose(close, result: .removed))
    try registry.unregisterEmptyWindow(
      location.windowID, expectedRevision: registry.workspaceRevision)
    try registry.registerWindow(id: location.windowID, initialGroupID: location.groupID)
    XCTAssertThrowsError(
      try registry.registerDocument(
        replacement, metadata: .init(pinned: false), in: location, at: 0, select: true))
    XCTAssertEqual(registry.closedHistoryCount(windowID: location.windowID), 0)
  }
  func testHistoryEvictionBoundAndRetiredIDSurvives() throws {
    let (registry, first, location) = try setup()
    let firstID = first.id
    _ = try registry.completeClose(
      ticket(registry, first, disposition: .retainCleanHistory), result: .removed)
    for _ in 0..<10 {
      let handle = CloseHandle()
      try registry.registerDocument(
        handle, metadata: .init(pinned: true), in: location, at: 0, select: true)
      _ = try registry.completeClose(
        ticket(registry, handle, disposition: .retainCleanHistory), result: .removed)
    }
    XCTAssertEqual(registry.closedHistoryCount(windowID: location.windowID), 10)
    let replacement = CloseHandle()
    replacement.id = firstID
    XCTAssertThrowsError(
      try registry.registerDocument(
        replacement, metadata: .init(pinned: false), in: location, at: 0, select: true))
    first.id = UUID()
    try registry.registerDocument(
      first, metadata: .init(pinned: false), in: location, at: 0, select: true)
  }
  func testRemovedAfterBypassRetainsOwnerUntilFreshRepair() throws {
    let (registry, handle, location) = try setup()
    let close = try ticket(registry, handle)
    handle.mutation = UUID()
    handle.dirty = true
    if case .recoveryRequired = try registry.completeClose(close, result: .removed) {
    } else {
      XCTFail()
    }
    XCTAssertTrue(registry.handle(id: handle.id) === handle)
    XCTAssertEqual(registry.assignment(of: handle.id), location)
    XCTAssertFalse(registry.allows(.edit, documentID: handle.id))
    let attempt = try registry.beginRecoveryRepair(documentID: handle.id)
    XCTAssertThrowsError(try registry.beginRecoveryRepair(documentID: handle.id))
    XCTAssertFalse(
      try registry.completeRecoveryRepair(attempt, result: .failure(CloseFailure.disk)))
    let retry = try registry.beginRecoveryRepair(documentID: handle.id)
    XCTAssertThrowsError(
      try registry.completeRecoveryRepair(attempt, result: .success(receipt(attempt))))
    XCTAssertFalse(registry.allows(.edit, documentID: handle.id))
    XCTAssertTrue(try registry.completeRecoveryRepair(retry, result: .success(receipt(retry))))
    XCTAssertTrue(registry.allows(.edit, documentID: handle.id))
    XCTAssertTrue(registry.handle(id: handle.id) === handle)
  }
  func testUncertainAndWrongReceiptRemainRecoverable() throws {
    let (registry, handle, _) = try setup()
    _ = try registry.completeClose(ticket(registry, handle), result: .uncertain(CloseFailure.disk))
    let attempt = try registry.beginRecoveryRepair(documentID: handle.id)
    let wrong = DocumentRecoveryReceipt(
      attemptID: UUID(), repairID: attempt.repairID, documentID: handle.id,
      mutationGeneration: handle.mutation, publicationID: UUID())
    XCTAssertFalse(try registry.completeRecoveryRepair(attempt, result: .success(wrong)))
    let retry = try registry.beginRecoveryRepair(documentID: handle.id)
    handle.mutation = UUID()
    XCTAssertFalse(try registry.completeRecoveryRepair(retry, result: .success(receipt(retry))))
    XCTAssertFalse(registry.allows(.edit, documentID: handle.id))
    _ = try registry.beginRecoveryRepair(documentID: handle.id)
  }
  func testCloseReadFailureRetainsOwnerAndRepairReadFailureCanRetry() throws {
    var shouldThrow = false
    let registry = ApplicationDocuments(
      closeServices: .init {
        if shouldThrow { throw CloseFailure.disk }
        return ($0 as! CloseHandle).state
      })
    let location = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: location.windowID, initialGroupID: location.groupID)
    let handle = CloseHandle()
    try registry.registerDocument(
      handle, metadata: .init(pinned: false), in: location, at: 0, select: true)
    let close = try ticket(registry, handle)
    shouldThrow = true
    if case .recoveryRequired(let error) = try registry.completeClose(close, result: .removed) {
      XCTAssertTrue(error is CloseFailure)
    } else {
      XCTFail()
    }
    let status = registry.closeStatus(documentID: handle.id)
    XCTAssertThrowsError(try registry.beginRecoveryRepair(documentID: handle.id))
    XCTAssertEqual(registry.closeStatus(documentID: handle.id), status)
    shouldThrow = false
    let repair = try registry.beginRecoveryRepair(documentID: handle.id)
    shouldThrow = true
    XCTAssertFalse(try registry.completeRecoveryRepair(repair, result: .success(receipt(repair))))
    shouldThrow = false
    let retry = try registry.beginRecoveryRepair(documentID: handle.id)
    XCTAssertTrue(try registry.completeRecoveryRepair(retry, result: .success(receipt(retry))))
  }
  func testEveryRepairIdentityFieldAndOldConfirmationAreFenced() throws {
    let (registry, handle, _) = try setup()
    let old = try registry.requestClose(documentID: handle.id)
    let close = try registry.beginClose(old, disposition: .discardWithoutHistory)
    _ = try registry.completeClose(close, result: .uncertain(CloseFailure.disk))
    for invalid in 0..<4 {
      let attempt = try registry.beginRecoveryRepair(documentID: handle.id)
      let wrong = DocumentRecoveryReceipt(
        attemptID: invalid == 0 ? UUID() : attempt.id,
        repairID: invalid == 1 ? UUID() : attempt.repairID,
        documentID: invalid == 2 ? UUID() : attempt.documentID,
        mutationGeneration: invalid == 3 ? UUID() : attempt.state.mutationGeneration,
        publicationID: UUID())
      XCTAssertFalse(try registry.completeRecoveryRepair(attempt, result: .success(wrong)))
    }
    let repair = try registry.beginRecoveryRepair(documentID: handle.id)
    XCTAssertTrue(try registry.completeRecoveryRepair(repair, result: .success(receipt(repair))))
    XCTAssertThrowsError(try registry.beginClose(old, disposition: .discardWithoutHistory))
    let next = try ticket(registry, handle)
    XCTAssertThrowsError(try registry.completeClose(close, result: .removed))
    XCTAssertEqual(registry.closeStatus(documentID: handle.id), .closing(ticketID: next.id))
  }
  func testUnrelatedGroupWorksDuringLeaseAndFreshRequestSurvivesItsChanges() throws {
    let (registry, handle, location) = try setup()
    let other = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: other.windowID, initialGroupID: other.groupID)
    let otherHandle = CloseHandle()
    try registry.registerDocument(
      otherHandle, metadata: .init(pinned: false), in: other, at: 0, select: true)
    let request = try registry.requestClose(documentID: handle.id)
    try registry.setPinned(
      true, documentID: otherHandle.id, expectedRevision: registry.workspaceRevision)
    let close = try registry.beginClose(request, disposition: .discardWithoutHistory)
    try registry.setPinned(
      false, documentID: otherHandle.id, expectedRevision: registry.workspaceRevision)
    XCTAssertTrue(registry.allows(.edit, documentID: otherHandle.id))
    XCTAssertEqual(registry.assignment(of: handle.id), location)
    _ = try registry.completeClose(close, result: .notRemoved(CloseFailure.disk))
  }
  func testPinChangedAwayAndBackStillInvalidatesPriorConfirmation() throws {
    let (registry, handle, _) = try setup()
    let request = try registry.requestClose(documentID: handle.id)
    try registry.setPinned(
      true, documentID: handle.id, expectedRevision: registry.workspaceRevision)
    try registry.setPinned(
      false, documentID: handle.id, expectedRevision: registry.workspaceRevision)
    XCTAssertThrowsError(try registry.beginClose(request, disposition: .discardWithoutHistory))
  }
  func testGroupSelectionOrderAndAxisABACannotReuseConfirmation() throws {
    for operation in 0..<3 {
      let (registry, handle, location) = try setup()
      let other = CloseHandle()
      try registry.registerDocument(
        other, metadata: .init(pinned: false), in: location, at: 1, select: false)
      let request = try registry.requestClose(documentID: handle.id)
      switch operation {
      case 0:
        try registry.selectDocument(
          other.id, in: location, expectedRevision: registry.workspaceRevision)
        try registry.selectDocument(
          handle.id, in: location, expectedRevision: registry.workspaceRevision)
      case 1:
        try registry.reorderDocument(handle.id, to: 1, expectedRevision: registry.workspaceRevision)
        try registry.reorderDocument(handle.id, to: 0, expectedRevision: registry.workspaceRevision)
      default:
        try registry.setGroupAxis(
          .stacked, windowID: location.windowID, expectedRevision: registry.workspaceRevision)
        try registry.setGroupAxis(
          .sideBySide, windowID: location.windowID, expectedRevision: registry.workspaceRevision)
      }
      XCTAssertThrowsError(try registry.beginClose(request, disposition: .discardWithoutHistory))
    }
  }
  func testOwnMetadataAndOwnershipChangesInvalidateConfirmation() throws {
    let (registry, handle, _) = try setup()
    let request = try registry.requestClose(documentID: handle.id)
    try registry.setPinned(
      true, documentID: handle.id, expectedRevision: registry.workspaceRevision)
    XCTAssertThrowsError(try registry.beginClose(request, disposition: .discardWithoutHistory))
    let next = try registry.requestClose(documentID: handle.id)
    handle.advanceOwnershipGeneration()
    XCTAssertThrowsError(try registry.beginClose(next, disposition: .discardWithoutHistory))
  }
  func testCompletionSelectionAndNotificationReentryStayCommitted() throws {
    let (registry, first, location) = try setup()
    let second = CloseHandle()
    try registry.registerDocument(
      second, metadata: .init(pinned: false), in: location, at: 1, select: false)
    var began = false
    var closed = false
    registry.onChange = { _ in
      if registry.handle(id: first.id) == nil {
        closed = true
        XCTAssertTrue(registry.allows(.edit, documentID: second.id))
        try! registry.setPinned(
          true, documentID: second.id, expectedRevision: registry.workspaceRevision)
      } else {
        began = true
        XCTAssertFalse(registry.allows(.edit, documentID: first.id))
      }
    }
    let close = try ticket(registry, first)
    _ = try registry.completeClose(close, result: .removed)
    XCTAssertTrue(began)
    XCTAssertTrue(closed)
    XCTAssertEqual(
      registry.window(id: location.windowID)?.groups.first?.selectedDocumentID, second.id)
    XCTAssertEqual(registry.metadata(id: second.id)?.pinned, true)
  }
}
