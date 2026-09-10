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
}
