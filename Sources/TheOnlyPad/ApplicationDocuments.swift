import Foundation

/// View-free ownership and group metadata. Close, transfer, and native adapters are later stages.
@MainActor final class ApplicationDocuments {
  private struct Record {
    let handle: any WorkspaceDocumentHandle
    let assignment: DocumentAssignment
    var metadata: WorkspaceDocumentMetadata
  }
  private var records: [UUID: Record] = [:]
  private var windows: [UUID: DocumentWindowSnapshot] = [:]
  private var windowOrder: [UUID] = []
  private var allIDs = Set<UUID>()
  private var handleIdentities = Set<ObjectIdentifier>()
  private var mutating = false
  private(set) var workspaceRevision = UUID()
  var onChange: ((UUID) -> Void)?
  init() {}

  func handle(id: UUID) -> (any WorkspaceDocumentHandle)? { records[id]?.handle }
  func assignment(of documentID: UUID) -> DocumentAssignment? { records[documentID]?.assignment }
  func metadata(id: UUID) -> WorkspaceDocumentMetadata? { records[id]?.metadata }
  func window(id: UUID) -> DocumentWindowSnapshot? { windows[id] }
  func captureWindows() throws -> [DocumentWindowSnapshot] {
    guard !mutating else { throw DocumentRegistryError.busy }
    return windowOrder.compactMap { windows[$0] }
  }

  /// Calls no user code until admission is held. Notifications see stable state and may reenter.
  private func mutate(expected: UUID? = nil, _ body: () throws -> Bool) throws {
    guard !mutating else { throw DocumentRegistryError.busy }
    mutating = true
    let changed: Bool
    do {
      if let expected, expected != workspaceRevision { throw DocumentRegistryError.staleRevision }
      changed = try body()
    } catch {
      mutating = false
      throw error
    }
    if changed { workspaceRevision = UUID() }
    let publishedRevision = workspaceRevision
    mutating = false
    if changed { onChange?(publishedRevision) }
    // No state cleanup after notification: a callback may have completed a newer operation.
  }
  private func group(_ assignment: DocumentAssignment) throws -> (DocumentWindowSnapshot, Int) {
    guard let window = windows[assignment.windowID] else {
      throw DocumentRegistryError.unknownWindow
    }
    guard let index = window.groups.firstIndex(where: { $0.id == assignment.groupID }) else {
      throw DocumentRegistryError.unknownGroup
    }
    return (window, index)
  }
  private func replacing(
    _ window: DocumentWindowSnapshot, groupAt index: Int,
    with group: DocumentGroupSnapshot
  ) -> DocumentWindowSnapshot {
    var groups = window.groups
    groups[index] = group
    return DocumentWindowSnapshot(
      id: window.id, groups: groups,
      focusedGroupID: window.focusedGroupID, axis: window.axis)
  }
  private func pinnedFirst(_ ids: [UUID]) -> [UUID] {
    ids.filter { records[$0]?.metadata.pinned == true }
      + ids.filter { records[$0]?.metadata.pinned != true }
  }

  func registerWindow(id: UUID, initialGroupID: UUID) throws {
    try mutate {
      guard windows.count < 32 else { throw DocumentRegistryError.capacity }
      guard id != initialGroupID, !allIDs.contains(id), !allIDs.contains(initialGroupID) else {
        throw DocumentRegistryError.duplicateID
      }
      windows[id] = DocumentWindowSnapshot(
        id: id,
        groups: [
          DocumentGroupSnapshot(id: initialGroupID, documentIDs: [], selectedDocumentID: nil)
        ],
        focusedGroupID: initialGroupID, axis: .sideBySide)
      windowOrder.append(id)
      allIDs.formUnion([id, initialGroupID])
      return true
    }
  }
  func registerDocument(
    _ handle: any WorkspaceDocumentHandle, metadata: WorkspaceDocumentMetadata,
    in assignment: DocumentAssignment, at index: Int, select: Bool
  ) throws {
    try mutate {
      let (window, groupIndex) = try group(assignment)
      let group = window.groups[groupIndex]
      guard index >= 0, index <= group.documentIDs.count else {
        throw DocumentRegistryError.invalidIndex
      }
      guard records.count < 128 else { throw DocumentRegistryError.capacity }
      let identity = ObjectIdentifier(handle)
      guard !handleIdentities.contains(identity) else { throw DocumentRegistryError.duplicateID }
      // Protocol getters may execute arbitrary caller code; read once under the admission fence.
      let id = handle.id
      guard !allIDs.contains(id) else { throw DocumentRegistryError.duplicateID }
      var ids = group.documentIDs
      ids.insert(id, at: index)
      records[id] = Record(handle: handle, assignment: assignment, metadata: metadata)
      allIDs.insert(id)
      handleIdentities.insert(identity)
      windows[window.id] = replacing(
        window, groupAt: groupIndex,
        with: DocumentGroupSnapshot(
          id: group.id, documentIDs: pinnedFirst(ids),
          selectedDocumentID: select ? id : group.selectedDocumentID ?? id))
      return true
    }
  }
  func selectDocument(
    _ documentID: UUID?, in assignment: DocumentAssignment, expectedRevision: UUID
  ) throws {
    try mutate(expected: expectedRevision) {
      let (window, index) = try group(assignment)
      let group = window.groups[index]
      guard
        group.documentIDs.isEmpty
          ? documentID == nil : documentID.map(group.documentIDs.contains) == true
      else {
        throw DocumentRegistryError.invalidSelection
      }
      guard group.selectedDocumentID != documentID else { return false }
      windows[window.id] = replacing(
        window, groupAt: index,
        with: DocumentGroupSnapshot(
          id: group.id, documentIDs: group.documentIDs, selectedDocumentID: documentID))
      return true
    }
  }
  func focusGroup(_ groupID: UUID, in windowID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      let (window, _) = try group(DocumentAssignment(windowID: windowID, groupID: groupID))
      guard window.focusedGroupID != groupID else { return false }
      windows[windowID] = DocumentWindowSnapshot(
        id: windowID, groups: window.groups,
        focusedGroupID: groupID, axis: window.axis)
      return true
    }
  }
  func reorderDocument(_ documentID: UUID, to index: Int, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      guard let record = records[documentID] else { throw DocumentRegistryError.unknownDocument }
      let (window, groupIndex) = try group(record.assignment)
      let group = window.groups[groupIndex]
      guard group.documentIDs.indices.contains(index) else {
        throw DocumentRegistryError.invalidIndex
      }
      var ids = group.documentIDs.filter { $0 != documentID }
      ids.insert(documentID, at: index)
      ids = pinnedFirst(ids)
      guard ids != group.documentIDs else { return false }
      windows[window.id] = replacing(
        window, groupAt: groupIndex,
        with: DocumentGroupSnapshot(
          id: group.id, documentIDs: ids, selectedDocumentID: group.selectedDocumentID))
      return true
    }
  }
  func setPinned(_ pinned: Bool, documentID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      guard var record = records[documentID] else { throw DocumentRegistryError.unknownDocument }
      guard record.metadata.pinned != pinned else { return false }
      let (window, index) = try group(record.assignment)
      let group = window.groups[index]
      record.metadata = WorkspaceDocumentMetadata(pinned: pinned)
      records[documentID] = record
      windows[window.id] = replacing(
        window, groupAt: index,
        with: DocumentGroupSnapshot(
          id: group.id, documentIDs: pinnedFirst(group.documentIDs),
          selectedDocumentID: group.selectedDocumentID))
      return true
    }
  }
  func createGroup(in windowID: UUID, id: UUID, axis: WorkspaceGroupAxis, expectedRevision: UUID)
    throws
  {
    try mutate(expected: expectedRevision) {
      guard let window = windows[windowID] else { throw DocumentRegistryError.unknownWindow }
      guard window.groups.count < 2 else { throw DocumentRegistryError.capacity }
      guard !allIDs.contains(id) else { throw DocumentRegistryError.duplicateID }
      windows[windowID] = DocumentWindowSnapshot(
        id: windowID,
        groups: window.groups + [
          DocumentGroupSnapshot(id: id, documentIDs: [], selectedDocumentID: nil)
        ],
        focusedGroupID: window.focusedGroupID, axis: axis)
      allIDs.insert(id)
      return true
    }
  }
  func setGroupAxis(_ axis: WorkspaceGroupAxis, windowID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      guard let window = windows[windowID] else { throw DocumentRegistryError.unknownWindow }
      guard window.axis != axis else { return false }
      windows[windowID] = DocumentWindowSnapshot(
        id: windowID, groups: window.groups,
        focusedGroupID: window.focusedGroupID, axis: axis)
      return true
    }
  }
  func closeEmptyGroup(_ groupID: UUID, in windowID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      let (window, index) = try group(DocumentAssignment(windowID: windowID, groupID: groupID))
      guard window.groups[index].documentIDs.isEmpty else { throw DocumentRegistryError.notEmpty }
      guard window.groups.count > 1 else { throw DocumentRegistryError.lastGroup }
      let groups = window.groups.filter { $0.id != groupID }
      windows[windowID] = DocumentWindowSnapshot(
        id: windowID, groups: groups,
        focusedGroupID: window.focusedGroupID == groupID ? groups[0].id : window.focusedGroupID,
        axis: window.axis)
      allIDs.remove(groupID)
      return true
    }
  }
  func unregisterEmptyWindow(_ windowID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      guard let window = windows[windowID] else { throw DocumentRegistryError.unknownWindow }
      guard window.groups.allSatisfy({ $0.documentIDs.isEmpty }) else {
        throw DocumentRegistryError.notEmpty
      }
      windows[windowID] = nil
      windowOrder.removeAll { $0 == windowID }
      allIDs.remove(windowID)
      for group in window.groups { allIDs.remove(group.id) }
      return true
    }
  }
}
