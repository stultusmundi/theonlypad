import Foundation
import XCTest

@testable import DocumentRegistry

@MainActor private final class Handle: WorkspaceDocumentHandle {
  var stableID: UUID
  var readID: (() -> Void)?
  var id: UUID {
    readID?()
    return stableID
  }
  var ownershipGeneration = UUID()
  let workspaceKind: WorkspaceDocumentKind
  init(id: UUID = UUID(), kind: WorkspaceDocumentKind = .editable) {
    stableID = id
    workspaceKind = kind
  }
  func advanceOwnershipGeneration() { ownershipGeneration = UUID() }
}
@MainActor final class ApplicationDocumentsTests: XCTestCase {
  private func setup() throws -> (ApplicationDocuments, DocumentAssignment) {
    let registry = ApplicationDocuments()
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    return (registry, assignment)
  }
  func testRegisterPreservesIdentityMetadataAndExclusiveAssignment() throws {
    let (registry, assignment) = try setup()
    for kind in [WorkspaceDocumentKind.editable, .streaming] {
      let handle = Handle(kind: kind)
      try registry.registerDocument(
        handle, metadata: .init(pinned: true), in: assignment, at: 0, select: true)
      XCTAssertTrue(registry.handle(id: handle.id) === handle)
      XCTAssertEqual(registry.metadata(id: handle.id), .init(pinned: true))
      XCTAssertEqual(registry.assignment(of: handle.id), assignment)
      let before = try registry.captureWindows()
      XCTAssertThrowsError(
        try registry.registerDocument(
          handle, metadata: .init(pinned: false), in: assignment, at: 0, select: true))
      XCTAssertEqual(try registry.captureWindows(), before)
    }
  }
  func testWindowGroupFocusAndEmptyRemoval() throws {
    let (registry, assignment) = try setup()
    let second = UUID()
    try registry.createGroup(
      in: assignment.windowID, id: second, axis: .stacked,
      expectedRevision: registry.workspaceRevision)
    try registry.focusGroup(
      second, in: assignment.windowID, expectedRevision: registry.workspaceRevision)
    XCTAssertEqual(registry.window(id: assignment.windowID)?.focusedGroupID, second)
    XCTAssertEqual(registry.window(id: assignment.windowID)?.axis, .stacked)
    XCTAssertThrowsError(
      try registry.createGroup(
        in: assignment.windowID, id: UUID(), axis: .stacked,
        expectedRevision: registry.workspaceRevision))
    try registry.closeEmptyGroup(
      second, in: assignment.windowID, expectedRevision: registry.workspaceRevision)
    XCTAssertEqual(registry.window(id: assignment.windowID)?.focusedGroupID, assignment.groupID)
    XCTAssertThrowsError(
      try registry.closeEmptyGroup(
        assignment.groupID, in: assignment.windowID, expectedRevision: registry.workspaceRevision))
    try registry.unregisterEmptyWindow(
      assignment.windowID, expectedRevision: registry.workspaceRevision)
    XCTAssertNil(registry.window(id: assignment.windowID))
  }
  func testSelectionMembershipAndStaleRevisionLeaveStateUnchanged() throws {
    let (registry, assignment) = try setup()
    let h = Handle()
    let old = registry.workspaceRevision
    try registry.registerDocument(
      h, metadata: .init(pinned: false), in: assignment, at: 0, select: false)
    XCTAssertEqual(registry.window(id: assignment.windowID)?.groups[0].selectedDocumentID, h.id)
    let before = try registry.captureWindows()
    XCTAssertThrowsError(
      try registry.selectDocument(nil, in: assignment, expectedRevision: registry.workspaceRevision)
    )
    XCTAssertThrowsError(
      try registry.selectDocument(
        UUID(), in: assignment, expectedRevision: registry.workspaceRevision))
    XCTAssertThrowsError(try registry.selectDocument(h.id, in: assignment, expectedRevision: old))
    XCTAssertThrowsError(
      try registry.unregisterEmptyWindow(
        assignment.windowID, expectedRevision: registry.workspaceRevision))
    XCTAssertEqual(try registry.captureWindows(), before)
  }
  func testPinPartitionAndReorderUseOneAuthority() throws {
    let (registry, a) = try setup()
    let handles = (0..<3).map { _ in Handle() }
    for (index, h) in handles.enumerated() {
      try registry.registerDocument(
        h, metadata: .init(pinned: index == 1), in: a, at: index, select: true)
    }
    XCTAssertEqual(
      registry.window(id: a.windowID)?.groups[0].documentIDs,
      [handles[1].id, handles[0].id, handles[2].id])
    try registry.reorderDocument(handles[2].id, to: 0, expectedRevision: registry.workspaceRevision)
    XCTAssertEqual(
      registry.window(id: a.windowID)?.groups[0].documentIDs,
      [handles[1].id, handles[2].id, handles[0].id])
    try registry.setPinned(
      true, documentID: handles[0].id, expectedRevision: registry.workspaceRevision)
    XCTAssertEqual(
      registry.window(id: a.windowID)?.groups[0].documentIDs,
      [handles[1].id, handles[0].id, handles[2].id])
    XCTAssertEqual(registry.window(id: a.windowID)?.groups[0].selectedDocumentID, handles[2].id)
    XCTAssertEqual(registry.metadata(id: handles[0].id)?.pinned, true)
  }
  func testInvalidRegistrationHasNoEffectsOrNotifications() throws {
    let (registry, a) = try setup()
    var notifications = 0
    registry.onChange = { _ in notifications += 1 }
    let before = try registry.captureWindows()
    let revision = registry.workspaceRevision
    for index in [-1, 1, Int.max] {
      XCTAssertThrowsError(
        try registry.registerDocument(
          Handle(), metadata: .init(pinned: false), in: a, at: index, select: true))
    }
    XCTAssertThrowsError(try registry.registerWindow(id: a.windowID, initialGroupID: UUID()))
    XCTAssertThrowsError(try registry.registerWindow(id: UUID(), initialGroupID: a.groupID))
    XCTAssertThrowsError(
      try registry.registerDocument(
        Handle(id: a.groupID), metadata: .init(pinned: false), in: a, at: 0, select: true))
    XCTAssertEqual(try registry.captureWindows(), before)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertEqual(notifications, 0)
  }
  func testHandleGetterReentryRefusesMutationAndCapture() throws {
    let (registry, a) = try setup()
    let h = Handle()
    var attempts = 0
    h.readID = {
      attempts += 1
      do {
        try registry.registerWindow(id: UUID(), initialGroupID: UUID())
        XCTFail("Nested mutation admitted")
      } catch { XCTAssertEqual(error as? DocumentRegistryError, .busy) }
      do {
        _ = try registry.captureWindows()
        XCTFail("Transient capture admitted")
      } catch { XCTAssertEqual(error as? DocumentRegistryError, .busy) }
    }
    try registry.registerDocument(h, metadata: .init(pinned: false), in: a, at: 0, select: true)
    h.readID = nil
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(try registry.captureWindows().count, 1)
    XCTAssertTrue(registry.handle(id: h.id) === h)
  }
  func testStableNotificationAllowsReentryWithoutOldCleanup() throws {
    let registry = ApplicationDocuments()
    let first = UUID()
    let second = UUID()
    var revisions: [UUID] = []
    registry.onChange = { revision in
      revisions.append(revision)
      XCTAssertEqual(registry.workspaceRevision, revision)
      do {
        _ = try registry.captureWindows()
        if revisions.count == 1 { try registry.registerWindow(id: second, initialGroupID: UUID()) }
      } catch { XCTFail("Stable callback rejected: \(error)") }
    }
    try registry.registerWindow(id: first, initialGroupID: UUID())
    XCTAssertEqual(revisions.count, 2)
    XCTAssertNotEqual(revisions.first, revisions.last)
    XCTAssertEqual(registry.workspaceRevision, revisions.last)
    XCTAssertEqual(try registry.captureWindows().map(\.id), [first, second])
  }
  func testLiveCapacityAcrossWindowsAndReleasedEmptyIDs() throws {
    let (registry, a) = try setup()
    for _ in 1..<32 { try registry.registerWindow(id: UUID(), initialGroupID: UUID()) }
    XCTAssertThrowsError(try registry.registerWindow(id: UUID(), initialGroupID: UUID())) {
      XCTAssertEqual($0 as? DocumentRegistryError, .capacity)
    }
    let b = try registry.captureWindows()[1]
    let destination = DocumentAssignment(windowID: b.id, groupID: b.groups[0].id)
    for index in 0..<128 {
      let target = index < 64 ? a : destination
      try registry.registerDocument(
        Handle(), metadata: .init(pinned: false), in: target, at: 0, select: false)
    }
    let before = try registry.captureWindows()
    XCTAssertThrowsError(
      try registry.registerDocument(
        Handle(), metadata: .init(pinned: false), in: a, at: 0, select: true)
    ) {
      XCTAssertEqual($0 as? DocumentRegistryError, .capacity)
    }
    XCTAssertEqual(try registry.captureWindows(), before)
    let empty = before[2]
    try registry.unregisterEmptyWindow(empty.id, expectedRevision: registry.workspaceRevision)
    try registry.registerWindow(id: empty.id, initialGroupID: empty.groups[0].id)
    XCTAssertEqual(try registry.captureWindows().last?.id, empty.id)
  }
  func testNoOpMutationsDoNotPublishOrAdvanceRevision() throws {
    let (registry, a) = try setup()
    let h = Handle()
    try registry.registerDocument(h, metadata: .init(pinned: false), in: a, at: 0, select: true)
    let revision = registry.workspaceRevision
    var notices = 0
    registry.onChange = { _ in notices += 1 }
    try registry.selectDocument(h.id, in: a, expectedRevision: revision)
    try registry.focusGroup(a.groupID, in: a.windowID, expectedRevision: revision)
    try registry.setPinned(false, documentID: h.id, expectedRevision: revision)
    try registry.reorderDocument(h.id, to: 0, expectedRevision: revision)
    try registry.setGroupAxis(.sideBySide, windowID: a.windowID, expectedRevision: revision)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertEqual(notices, 0)
  }
  func testEveryRevisionMutatorRejectsStaleWithoutEffects() throws {
    let (registry, a) = try setup()
    let h = Handle()
    try registry.registerDocument(h, metadata: .init(pinned: false), in: a, at: 0, select: true)
    let old = UUID()
    let before = try registry.captureWindows()
    let revision = registry.workspaceRevision
    let actions: [() throws -> Void] = [
      { try registry.selectDocument(h.id, in: a, expectedRevision: old) },
      { try registry.focusGroup(a.groupID, in: a.windowID, expectedRevision: old) },
      { try registry.reorderDocument(h.id, to: 0, expectedRevision: old) },
      { try registry.setPinned(true, documentID: h.id, expectedRevision: old) },
      {
        try registry.createGroup(in: a.windowID, id: UUID(), axis: .stacked, expectedRevision: old)
      },
      { try registry.setGroupAxis(.stacked, windowID: a.windowID, expectedRevision: old) },
      { try registry.closeEmptyGroup(a.groupID, in: a.windowID, expectedRevision: old) },
      { try registry.unregisterEmptyWindow(a.windowID, expectedRevision: old) },
    ]
    for action in actions {
      XCTAssertThrowsError(try action()) {
        XCTAssertEqual($0 as? DocumentRegistryError, .staleRevision)
      }
      XCTAssertEqual(try registry.captureWindows(), before)
      XCTAssertEqual(registry.workspaceRevision, revision)
    }
  }
  func testUnknownTargetsBadReorderAndNonemptyGroupRefuse() throws {
    let (registry, a) = try setup()
    let h = Handle()
    let second = UUID()
    try registry.registerDocument(h, metadata: .init(pinned: false), in: a, at: 0, select: true)
    try registry.createGroup(
      in: a.windowID, id: second, axis: .stacked, expectedRevision: registry.workspaceRevision)
    let revision = registry.workspaceRevision
    let before = try registry.captureWindows()
    XCTAssertThrowsError(
      try registry.closeEmptyGroup(a.groupID, in: a.windowID, expectedRevision: revision)
    ) {
      XCTAssertEqual($0 as? DocumentRegistryError, .notEmpty)
    }
    XCTAssertThrowsError(try registry.reorderDocument(h.id, to: 1, expectedRevision: revision))
    XCTAssertThrowsError(
      try registry.setPinned(true, documentID: UUID(), expectedRevision: revision))
    XCTAssertThrowsError(
      try registry.focusGroup(UUID(), in: a.windowID, expectedRevision: revision))
    XCTAssertThrowsError(
      try registry.setGroupAxis(.stacked, windowID: UUID(), expectedRevision: revision))
    XCTAssertThrowsError(
      try registry.registerDocument(
        Handle(), metadata: .init(pinned: false),
        in: .init(windowID: UUID(), groupID: a.groupID), at: 0, select: true))
    XCTAssertEqual(try registry.captureWindows(), before)
    XCTAssertEqual(registry.workspaceRevision, revision)
    try registry.selectDocument(
      nil, in: .init(windowID: a.windowID, groupID: second), expectedRevision: revision)
    try registry.setGroupAxis(.sideBySide, windowID: a.windowID, expectedRevision: revision)
    XCTAssertEqual(registry.window(id: a.windowID)?.axis, .sideBySide)
  }
  func testRegistryRetainsHandlesWithoutDuplicatingOrChangingOwnershipGeneration() throws {
    let (registry, a) = try setup()
    weak var weakHandle: Handle?
    let id: UUID
    let generation: UUID
    do {
      let handle = Handle()
      id = handle.id
      generation = handle.ownershipGeneration
      weakHandle = handle
      try registry.registerDocument(
        handle, metadata: .init(pinned: false), in: a, at: 0, select: true)
    }
    XCTAssertNotNil(weakHandle)
    XCTAssertEqual(registry.handle(id: id)?.ownershipGeneration, generation)
    try registry.setPinned(true, documentID: id, expectedRevision: registry.workspaceRevision)
    XCTAssertEqual(registry.handle(id: id)?.ownershipGeneration, generation)
  }

  func testSameObjectCannotRegisterAgainUnderChangedID() throws {
    let (registry, a) = try setup()
    let b = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: b.windowID, initialGroupID: b.groupID)
    let h = Handle()
    let originalID = h.id
    try registry.registerDocument(h, metadata: .init(pinned: true), in: a, at: 0, select: true)
    h.stableID = UUID()
    let revision = registry.workspaceRevision
    let before = try registry.captureWindows()
    XCTAssertThrowsError(
      try registry.registerDocument(h, metadata: .init(pinned: false), in: b, at: 0, select: true)
    ) {
      XCTAssertEqual($0 as? DocumentRegistryError, .duplicateID)
    }
    XCTAssertEqual(try registry.captureWindows(), before)
    XCTAssertEqual(registry.workspaceRevision, revision)
    XCTAssertTrue(registry.handle(id: originalID) === h)
    XCTAssertEqual(registry.assignment(of: originalID), a)
    XCTAssertEqual(registry.metadata(id: originalID), .init(pinned: true))
    XCTAssertNil(registry.handle(id: h.id))
  }

}
