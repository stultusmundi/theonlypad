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
}
