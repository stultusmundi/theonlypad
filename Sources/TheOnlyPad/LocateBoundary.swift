import Foundation
import PadCore

struct DocumentLocateInput {
  let documentID: UUID
  let originalURL: URL
  let candidateURL: URL
  let baselineRevision: UInt64
  let originalBytes: Data
  let pendingPublicationID: UUID?
  init(
    documentID: UUID, originalURL: URL, candidateURL: URL, baselineRevision: UInt64,
    originalBytes: Data, pendingPublicationID: UUID? = nil
  ) {
    self.documentID = documentID
    self.originalURL = originalURL
    self.candidateURL = candidateURL
    self.baselineRevision = baselineRevision
    self.originalBytes = originalBytes
    self.pendingPublicationID = pendingPublicationID
  }
}
@MainActor struct DocumentLocateCallbacks {
  let beginOperation: () -> UUID?
  let isCurrent: (UUID) -> Bool
  // Validate and throw before mutation; then adopt coherently without throwing.
  let apply: (URL, FileTargetIdentity, UUID) throws -> Void
  let finish: (UUID) -> Void
  let reportError: (Error) -> Void
}
enum DocumentLocateError: Error {
  case differentBytes
  case unavailable(DiskLocationProblem?)
  case changedCandidate
}
