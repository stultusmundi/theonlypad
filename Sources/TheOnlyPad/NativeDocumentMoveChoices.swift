import Foundation

/// Captured endpoint identities; these values do not authorize a move without owner validation.
struct NativeDocumentMoveDestination: Equatable {
  let windowID: UUID
  let endpointID: UUID
  let title: String
}
struct NativeDocumentMoveChoices: Equatable {
  let documentID: UUID
  let ownershipGeneration: UUID
  let sourceWindowID: UUID
  let sourceEndpointID: UUID
  let destinations: [NativeDocumentMoveDestination]
  let sourceWorkspaceRevision: UUID?
  /// Display hint only. Unknown availability must not enable a new destination.
  var newWindowRefusalReason: String? =
    "Choose Move Document to Window again to check new-window availability."
  init(
    documentID: UUID, ownershipGeneration: UUID, sourceWindowID: UUID, sourceEndpointID: UUID,
    destinations: [NativeDocumentMoveDestination], sourceWorkspaceRevision: UUID? = nil
  ) {
    self.documentID = documentID
    self.ownershipGeneration = ownershipGeneration
    self.sourceWindowID = sourceWindowID
    self.sourceEndpointID = sourceEndpointID
    self.destinations = destinations
    self.sourceWorkspaceRevision = sourceWorkspaceRevision
  }
}
