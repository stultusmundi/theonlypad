import Foundation

enum WorkspaceDocumentKind: Equatable, Sendable { case editable, streaming }
enum WorkspaceGroupAxis: Equatable, Sendable { case sideBySide, stacked }

@MainActor protocol WorkspaceDocumentHandle: AnyObject {
  var id: UUID { get }
  var ownershipGeneration: UUID { get }
  var workspaceKind: WorkspaceDocumentKind { get }
  func advanceOwnershipGeneration()
}

struct WorkspaceDocumentMetadata: Equatable, Sendable {
  let pinned: Bool
}
struct DocumentAssignment: Equatable, Sendable {
  let windowID: UUID
  let groupID: UUID
}
struct DocumentGroupSnapshot: Equatable, Sendable {
  let id: UUID
  let documentIDs: [UUID]
  let selectedDocumentID: UUID?
}
struct DocumentWindowSnapshot: Equatable, Sendable {
  let id: UUID
  let groups: [DocumentGroupSnapshot]
  let focusedGroupID: UUID?
  let axis: WorkspaceGroupAxis
}
enum DocumentRegistryError: Error, Equatable {
  case busy, staleRevision, duplicateID, unknownWindow, unknownGroup, unknownDocument
  case invalidSelection, invalidIndex, notEmpty, lastGroup, capacity
  case closeUnavailable, closeBlocked, staleClose, invalidDisposition, invalidRecoveryReceipt
  case historyUnavailable, staleHistory
  case adoptionUnavailable, adoptionBlocked, staleAdoption, invalidAdoptionReceipt
}

@MainActor struct DocumentCloseServices {
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentCloseState
}
struct DocumentCloseState: Equatable {
  var kind: WorkspaceDocumentKind
  var ownershipGeneration: UUID
  var mutationGeneration: UUID
  var operationID: UUID?
  var isDirty: Bool
  var hasPendingPublication: Bool
  var hasPendingTextEdits: Bool
  var isComposing: Bool
  var canRetainCleanHistory: Bool
}
enum DocumentCloseDisposition: Equatable { case retainCleanHistory, discardWithoutHistory }
struct DocumentCloseRequest: Equatable {
  let admissionGeneration: UUID
  let id: UUID
  let documentID: UUID
  let assignment: DocumentAssignment
  let state: DocumentCloseState
  let metadata: WorkspaceDocumentMetadata
}
struct DocumentCloseTicket: Equatable {
  let id: UUID
  let request: DocumentCloseRequest
  let disposition: DocumentCloseDisposition
}
enum DocumentAdmission: CaseIterable {
  case edit, select, undoRedo, fileOperation, baselineAdoption, transfer, close, paneInstall
}
enum DocumentCloseStatus: Equatable {
  case open
  case closing(ticketID: UUID)
  case recoveryRequired(repairID: UUID)
  case repairing(repairID: UUID, attemptID: UUID)
}
enum DocumentCleanupResult {
  case removed
  case notRemoved(Error)
  case uncertain(Error)
}
enum DocumentCloseCompletion {
  case closed
  case retained(Error)
  case recoveryRequired(Error?)
}
struct DocumentRecoveryAttempt: Equatable {
  let id: UUID
  let repairID: UUID
  let documentID: UUID
  let assignment: DocumentAssignment
  let state: DocumentCloseState
}
/// Correlation only. A future trusted adapter must obtain actual durable publication authority.
struct DocumentRecoveryReceipt {
  let attemptID: UUID
  let repairID: UUID
  let documentID: UUID
  let mutationGeneration: UUID
  let publicationID: UUID
}
