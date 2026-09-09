import Foundation
import PadCore

struct DocumentAdoptionLease: Equatable {
  let registryID: UUID
  let requestID: UUID
  let attemptID: UUID
  let documentID: UUID
  let assignment: DocumentAssignment
  let ownershipGeneration: UUID
  fileprivate init(
    registryID: UUID, requestID: UUID, attemptID: UUID, documentID: UUID,
    assignment: DocumentAssignment, ownershipGeneration: UUID
  ) {
    self.registryID = registryID
    self.requestID = requestID
    self.attemptID = attemptID
    self.documentID = documentID
    self.assignment = assignment
    self.ownershipGeneration = ownershipGeneration
  }
}

enum DocumentAdoptionStatus: Equatable {
  case unmanaged
  case pending(DocumentAdoptionLease)
  case failed(DocumentAdoptionLease)
  case active
  var blocksAdmission: Bool {
    switch self {
    case .pending, .failed: return true
    case .unmanaged, .active: return false
    }
  }
}
struct DocumentAdoptionState: Equatable {
  let documentID: UUID
  let ownershipGeneration: UUID
  let authority: RecoveryWriteAuthority?
  let highestIssuedRevision: UInt64
}
@MainActor struct DocumentAdoptionServices {
  let coordinatorID: UUID
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentAdoptionState
}

/// View-free ownership and group metadata. Close leases are view-free; transfer and native adapters are later stages.
@MainActor final class ApplicationDocuments {
  private struct Record {
    let handle: any WorkspaceDocumentHandle
    let assignment: DocumentAssignment
    var metadata: WorkspaceDocumentMetadata
    var adoption: DocumentAdoptionStatus = .unmanaged
  }
  private var records: [UUID: Record] = [:]
  private var windows: [UUID: DocumentWindowSnapshot] = [:]
  private var windowOrder: [UUID] = []
  private var allIDs = Set<UUID>()
  private var handleIdentities = Set<ObjectIdentifier>()
  private var mutating = false
  private(set) var workspaceRevision = UUID()
  var onChange: ((UUID) -> Void)?
  private let closeServices: DocumentCloseServices?
  private enum CloseLease {
    case closing(DocumentCloseTicket)
    case recovery(UUID)
    case repairing(DocumentRecoveryAttempt)
  }
  private var leases: [UUID: CloseLease] = [:]
  private var admissionGenerations: [UUID: UUID] = [:]
  private var history: [UUID: [Record]] = [:]
  private let registryID = UUID()
  private var adoptionRequests = Set<UUID>()
  private let adoptionServices: DocumentAdoptionServices?
  init(
    closeServices: DocumentCloseServices? = nil, adoptionServices: DocumentAdoptionServices? = nil
  ) {
    self.closeServices = closeServices
    self.adoptionServices = adoptionServices
  }

  func registerPending(
    _ handle: any WorkspaceDocumentHandle, requestID: UUID, expectedRevision: UUID,
    metadata: WorkspaceDocumentMetadata, in assignment: DocumentAssignment, at index: Int,
    select: Bool
  ) throws -> DocumentAdoptionLease {
    guard let adoptionServices else { throw DocumentRegistryError.adoptionUnavailable }
    var result: DocumentAdoptionLease!
    try mutate(expected: expectedRevision) {
      let (window, groupIndex) = try group(assignment)
      let target = window.groups[groupIndex]
      try ensureGroupOpen(target)
      guard index >= 0, index <= target.documentIDs.count else {
        throw DocumentRegistryError.invalidIndex
      }
      guard records.count < 128 else { throw DocumentRegistryError.capacity }
      let identity = ObjectIdentifier(handle)
      guard !handleIdentities.contains(identity), !adoptionRequests.contains(requestID) else {
        throw DocumentRegistryError.duplicateID
      }
      let id = handle.id
      let generation = handle.ownershipGeneration
      guard !allIDs.contains(id) else { throw DocumentRegistryError.duplicateID }
      guard handle.workspaceKind == .editable else {
        throw DocumentRegistryError.adoptionUnavailable
      }
      let state = try adoptionServices.readState(handle)
      guard state.documentID == id, state.ownershipGeneration == generation,
        state.authority == nil, state.highestIssuedRevision == 0,
        handle.id == id, handle.ownershipGeneration == generation,
        handle.workspaceKind == .editable
      else { throw DocumentRegistryError.staleAdoption }
      result = DocumentAdoptionLease(
        registryID: registryID, requestID: requestID, attemptID: UUID(), documentID: id,
        assignment: assignment, ownershipGeneration: generation)
      var ids = target.documentIDs
      ids.insert(id, at: index)
      records[id] = Record(
        handle: handle, assignment: assignment, metadata: metadata,
        adoption: .pending(result))
      allIDs.insert(id)
      handleIdentities.insert(identity)
      adoptionRequests.insert(requestID)
      admissionGenerations[id] = UUID()
      windows[window.id] = replacingAndInvalidatingGroup(
        window, groupAt: groupIndex,
        with: DocumentGroupSnapshot(
          id: target.id, documentIDs: pinnedFirst(ids),
          selectedDocumentID: select ? id : target.selectedDocumentID ?? id))
      return true
    }
    return result
  }

  func adoptionStatus(documentID: UUID) -> DocumentAdoptionStatus? { records[documentID]?.adoption }

  private func adoptionRecord(_ lease: DocumentAdoptionLease, failed: Bool = false) throws -> Record
  {
    guard lease.registryID == registryID, let record = records[lease.documentID],
      record.assignment == lease.assignment,
      record.adoption == (failed ? .failed(lease) : .pending(lease)),
      record.handle.id == lease.documentID,
      record.handle.ownershipGeneration == lease.ownershipGeneration
    else { throw DocumentRegistryError.staleAdoption }
    return record
  }

  func failAdoption(_ lease: DocumentAdoptionLease) throws {
    try mutate {
      var record = try adoptionRecord(lease)
      record.adoption = .failed(lease)
      records[lease.documentID] = record
      admissionGenerations[lease.documentID] = UUID()
      return true
    }
  }

  func retryAdoption(_ lease: DocumentAdoptionLease) throws -> DocumentAdoptionLease {
    var result: DocumentAdoptionLease!
    try mutate {
      var record = try adoptionRecord(lease, failed: true)
      result = DocumentAdoptionLease(
        registryID: registryID, requestID: lease.requestID, attemptID: UUID(),
        documentID: lease.documentID, assignment: lease.assignment,
        ownershipGeneration: lease.ownershipGeneration)
      record.adoption = .pending(result)
      records[lease.documentID] = record
      admissionGenerations[lease.documentID] = UUID()
      return true
    }
    return result
  }

  func activateAdoption(_ lease: DocumentAdoptionLease, receipt: RecoveryAdoptionReceipt) throws {
    guard let adoptionServices else { throw DocumentRegistryError.adoptionUnavailable }
    try mutate {
      var record = try adoptionRecord(lease)
      guard receipt.authority.coordinatorID == adoptionServices.coordinatorID,
        receipt.authority.documentID == lease.documentID, receipt.nextRevision > 0
      else { throw DocumentRegistryError.invalidAdoptionReceipt }
      let state = try adoptionServices.readState(record.handle)
      guard state.documentID == lease.documentID,
        state.ownershipGeneration == lease.ownershipGeneration,
        state.authority == receipt.authority,
        state.highestIssuedRevision == receipt.nextRevision - 1,
        record.handle.workspaceKind == .editable
      else { throw DocumentRegistryError.invalidAdoptionReceipt }
      // Service/protocol callbacks may reenter or mutate their own model. Registry
      // mutation remains fenced; revalidate owner identity after the callbacks.
      _ = try adoptionRecord(lease)
      record.adoption = .active
      records[lease.documentID] = record
      admissionGenerations[lease.documentID] = UUID()
      return true
    }
  }

  func captureReadyWindows() throws -> [DocumentWindowSnapshot] {
    guard !mutating else { throw DocumentRegistryError.busy }
    guard !records.values.contains(where: { $0.adoption.blocksAdmission }) else {
      throw DocumentRegistryError.adoptionBlocked
    }
    guard leases.isEmpty else { throw DocumentRegistryError.closeBlocked }
    return try captureWindows()
  }

  func allows(_ action: DocumentAdmission, documentID: UUID) -> Bool {
    guard !mutating, let record = records[documentID], leases[documentID] == nil,
      !record.adoption.blocksAdmission
    else { return false }
    if action == .select {
      guard let (window, index) = try? group(record.assignment),
        (try? ensureGroupOpen(window.groups[index])) != nil
      else { return false }
    }
    return true
  }
  func closeStatus(documentID: UUID) -> DocumentCloseStatus? {
    guard records[documentID] != nil else { return nil }
    switch leases[documentID] {
    case .none: return .open
    case .closing(let ticket): return .closing(ticketID: ticket.id)
    case .recovery(let id): return .recoveryRequired(repairID: id)
    case .repairing(let attempt):
      return .repairing(repairID: attempt.repairID, attemptID: attempt.id)
    }
  }
  func closedHistoryCount(windowID: UUID) -> Int { history[windowID]?.count ?? 0 }
  private func ensureGroupOpen(_ group: DocumentGroupSnapshot) throws {
    guard group.documentIDs.allSatisfy({ records[$0]?.adoption.blocksAdmission == false }) else {
      throw DocumentRegistryError.adoptionBlocked
    }
    guard group.documentIDs.allSatisfy({ leases[$0] == nil }) else {
      throw DocumentRegistryError.closeBlocked
    }
  }
  private func ensureWindowOpen(_ window: DocumentWindowSnapshot) throws {
    for group in window.groups { try ensureGroupOpen(group) }
  }
  private func state(of record: Record, id: UUID) throws -> DocumentCloseState {
    guard let closeServices else { throw DocumentRegistryError.closeUnavailable }
    let state = try closeServices.readState(record.handle)
    guard record.handle.id == id,
      record.handle.workspaceKind == state.kind,
      record.handle.ownershipGeneration == state.ownershipGeneration
    else { throw DocumentRegistryError.staleClose }
    return state
  }
  private func requireSafeClose(_ state: DocumentCloseState) throws {
    guard state.operationID == nil, !state.isComposing, !state.hasPendingTextEdits,
      !state.hasPendingPublication
    else { throw DocumentRegistryError.closeBlocked }
  }
  func requestClose(documentID: UUID) throws -> DocumentCloseRequest {
    guard closeServices != nil else { throw DocumentRegistryError.closeUnavailable }
    var result: DocumentCloseRequest!
    try mutate {
      guard let record = records[documentID] else { throw DocumentRegistryError.unknownDocument }
      guard !record.adoption.blocksAdmission else { throw DocumentRegistryError.adoptionBlocked }
      guard leases[documentID] == nil else { throw DocumentRegistryError.closeBlocked }
      let state = try state(of: record, id: documentID)
      try requireSafeClose(state)
      result = DocumentCloseRequest(
        admissionGeneration: admissionGenerations[documentID]!, id: UUID(),
        documentID: documentID, assignment: record.assignment, state: state,
        metadata: record.metadata)
      return false
    }
    return result
  }
  func beginClose(_ request: DocumentCloseRequest, disposition: DocumentCloseDisposition) throws
    -> DocumentCloseTicket
  {
    guard closeServices != nil else { throw DocumentRegistryError.closeUnavailable }
    var result: DocumentCloseTicket!
    try mutate {
      guard let record = records[request.documentID], !record.adoption.blocksAdmission,
        leases[request.documentID] == nil,
        admissionGenerations[request.documentID] == request.admissionGeneration,
        record.assignment == request.assignment, record.metadata == request.metadata
      else { throw DocumentRegistryError.staleClose }
      let current = try state(of: record, id: request.documentID)
      guard current == request.state else { throw DocumentRegistryError.staleClose }
      try requireSafeClose(current)
      if disposition == .retainCleanHistory {
        guard current.kind == .editable, !current.isDirty, current.canRetainCleanHistory else {
          throw DocumentRegistryError.invalidDisposition
        }
      }
      result = DocumentCloseTicket(id: UUID(), request: request, disposition: disposition)
      leases[request.documentID] = .closing(result)
      admissionGenerations[request.documentID] = UUID()
      return true
    }
    return result
  }
  func completeClose(_ ticket: DocumentCloseTicket, result: DocumentCleanupResult) throws
    -> DocumentCloseCompletion
  {
    var completion: DocumentCloseCompletion!
    try mutate {
      let id = ticket.request.documentID
      guard case .closing(let active) = leases[id], active == ticket,
        let record = records[id], record.assignment == ticket.request.assignment
      else {
        throw DocumentRegistryError.staleClose
      }
      switch result {
      case .notRemoved(let error):
        leases[id] = nil
        completion = .retained(error)
      case .uncertain(let error):
        leases[id] = .recovery(UUID())
        completion = .recoveryRequired(error)
      case .removed:
        do {
          let current = try state(of: record, id: id)
          guard current == ticket.request.state, record.metadata == ticket.request.metadata else {
            throw DocumentRegistryError.staleClose
          }
        } catch {
          leases[id] = .recovery(UUID())
          admissionGenerations[id] = UUID()
          completion = .recoveryRequired(error)
          return true
        }
        let (window, groupIndex) = try group(record.assignment)
        let old = window.groups[groupIndex]
        let removedIndex = old.documentIDs.firstIndex(of: id)!
        let remaining = old.documentIDs.filter { $0 != id }
        let selected =
          old.selectedDocumentID == id
          ? (remaining.isEmpty ? nil : remaining[min(removedIndex, remaining.count - 1)])
          : old.selectedDocumentID
        windows[window.id] = replacingAndInvalidatingGroup(
          window, groupAt: groupIndex,
          with: DocumentGroupSnapshot(
            id: old.id, documentIDs: remaining, selectedDocumentID: selected))
        records[id] = nil
        leases[id] = nil
        // allIDs intentionally retains the retired document UUID for this registry's lifetime.
        if ticket.disposition == .retainCleanHistory {
          var entries = history[window.id] ?? []
          entries.append(record)
          if entries.count > 10 {
            let removed = entries.removeFirst()
            handleIdentities.remove(ObjectIdentifier(removed.handle))
          }
          history[window.id] = entries
        } else {
          handleIdentities.remove(ObjectIdentifier(record.handle))
        }
        completion = .closed
      }
      admissionGenerations[id] = records[id] == nil ? nil : UUID()
      return true
    }
    return completion
  }
  func beginRecoveryRepair(documentID: UUID) throws -> DocumentRecoveryAttempt {
    guard closeServices != nil else { throw DocumentRegistryError.closeUnavailable }
    var result: DocumentRecoveryAttempt!
    try mutate {
      guard case .recovery(let repairID) = leases[documentID], let record = records[documentID]
      else {
        throw DocumentRegistryError.closeBlocked
      }
      let current = try state(of: record, id: documentID)
      // Repair snapshots cannot acknowledge a still-open edit batch, operation or composition.
      guard current.operationID == nil, !current.hasPendingTextEdits, !current.isComposing else {
        throw DocumentRegistryError.closeBlocked
      }
      result = DocumentRecoveryAttempt(
        id: UUID(), repairID: repairID, documentID: documentID,
        assignment: record.assignment, state: current)
      leases[documentID] = .repairing(result)
      admissionGenerations[documentID] = UUID()
      return true
    }
    return result
  }
  func completeRecoveryRepair(
    _ attempt: DocumentRecoveryAttempt, result: Result<DocumentRecoveryReceipt, Error>
  ) throws -> Bool {
    var repaired = false
    try mutate {
      guard case .repairing(let active) = leases[attempt.documentID], active == attempt,
        let record = records[attempt.documentID], record.assignment == attempt.assignment
      else {
        throw DocumentRegistryError.staleClose
      }
      if case .success(let receipt) = result,
        receipt.attemptID == attempt.id, receipt.repairID == attempt.repairID,
        receipt.documentID == attempt.documentID,
        receipt.mutationGeneration == attempt.state.mutationGeneration,
        let current = try? state(of: record, id: attempt.documentID), current == attempt.state
      {
        repaired = true
      }
      leases[attempt.documentID] = repaired ? nil : .recovery(attempt.repairID)
      admissionGenerations[attempt.documentID] = UUID()
      return true
    }
    return repaired
  }

  /// Includes live, group, window and retired/history identities; never grants admission.
  func containsReservedID(_ id: UUID) -> Bool { allIDs.contains(id) }
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
  private func replacingAndInvalidatingGroup(
    _ window: DocumentWindowSnapshot, groupAt index: Int,
    with group: DocumentGroupSnapshot
  ) -> DocumentWindowSnapshot {
    advanceAdmission(in: window.groups[index])
    var groups = window.groups
    groups[index] = group
    return DocumentWindowSnapshot(
      id: window.id, groups: groups,
      focusedGroupID: window.focusedGroupID, axis: window.axis)
  }
  private func advanceAdmission(in group: DocumentGroupSnapshot) {
    for id in group.documentIDs { admissionGenerations[id] = UUID() }
  }
  private func advanceAdmission(in window: DocumentWindowSnapshot) {
    for group in window.groups { advanceAdmission(in: group) }
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
      try ensureGroupOpen(group)
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
      admissionGenerations[id] = UUID()
      windows[window.id] = replacingAndInvalidatingGroup(
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
      try ensureGroupOpen(group)
      guard
        group.documentIDs.isEmpty
          ? documentID == nil : documentID.map(group.documentIDs.contains) == true
      else {
        throw DocumentRegistryError.invalidSelection
      }
      guard group.selectedDocumentID != documentID else { return false }
      windows[window.id] = replacingAndInvalidatingGroup(
        window, groupAt: index,
        with: DocumentGroupSnapshot(
          id: group.id, documentIDs: group.documentIDs, selectedDocumentID: documentID))
      return true
    }
  }
  func focusGroup(_ groupID: UUID, in windowID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      let (window, _) = try group(DocumentAssignment(windowID: windowID, groupID: groupID))
      try ensureWindowOpen(window)
      guard window.focusedGroupID != groupID else { return false }
      advanceAdmission(in: window)
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
      try ensureGroupOpen(group)
      guard group.documentIDs.indices.contains(index) else {
        throw DocumentRegistryError.invalidIndex
      }
      var ids = group.documentIDs.filter { $0 != documentID }
      ids.insert(documentID, at: index)
      ids = pinnedFirst(ids)
      guard ids != group.documentIDs else { return false }
      windows[window.id] = replacingAndInvalidatingGroup(
        window, groupAt: groupIndex,
        with: DocumentGroupSnapshot(
          id: group.id, documentIDs: ids, selectedDocumentID: group.selectedDocumentID))
      return true
    }
  }
  func setPinned(_ pinned: Bool, documentID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      guard var record = records[documentID] else { throw DocumentRegistryError.unknownDocument }
      let (currentWindow, currentIndex) = try group(record.assignment)
      try ensureGroupOpen(currentWindow.groups[currentIndex])
      guard record.metadata.pinned != pinned else { return false }
      let (window, index) = try group(record.assignment)
      let group = window.groups[index]
      try ensureGroupOpen(group)
      record.metadata = WorkspaceDocumentMetadata(pinned: pinned)
      records[documentID] = record
      windows[window.id] = replacingAndInvalidatingGroup(
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
      try ensureWindowOpen(window)
      guard window.groups.count < 2 else { throw DocumentRegistryError.capacity }
      guard !allIDs.contains(id) else { throw DocumentRegistryError.duplicateID }
      advanceAdmission(in: window)
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
      try ensureWindowOpen(window)
      guard window.axis != axis else { return false }
      advanceAdmission(in: window)
      windows[windowID] = DocumentWindowSnapshot(
        id: windowID, groups: window.groups,
        focusedGroupID: window.focusedGroupID, axis: axis)
      return true
    }
  }
  func closeEmptyGroup(_ groupID: UUID, in windowID: UUID, expectedRevision: UUID) throws {
    try mutate(expected: expectedRevision) {
      let (window, index) = try group(DocumentAssignment(windowID: windowID, groupID: groupID))
      try ensureWindowOpen(window)
      guard window.groups[index].documentIDs.isEmpty else { throw DocumentRegistryError.notEmpty }
      guard window.groups.count > 1 else { throw DocumentRegistryError.lastGroup }
      advanceAdmission(in: window)
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
      for entry in history.removeValue(forKey: windowID) ?? [] {
        handleIdentities.remove(ObjectIdentifier(entry.handle))
      }
      windows[windowID] = nil
      windowOrder.removeAll { $0 == windowID }
      allIDs.remove(windowID)
      for group in window.groups { allIDs.remove(group.id) }
      return true
    }
  }
}
