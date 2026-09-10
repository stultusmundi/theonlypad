import Foundation
import PadCore

@MainActor struct EditorApplicationRouting {
  let endpointID: UUID
  let assignment: DocumentAssignment
  let registry: ApplicationDocuments
  let requireEndpointCurrent: () throws -> Void
  let requireUserAdmission: () throws -> Void
  let submit: (EditorPreparedSubmission) throws -> DocumentIntakeID
  let wait: (DocumentIntakeID) async throws -> DocumentIntakeResult
  let requestClose: (Set<UUID>) throws -> DocumentClosingID
  let requestReopen: () async throws -> DocumentIntakeID
  let detachDocumentEndpoint: (EditorDocument) throws -> Void
  let reattachDocumentEndpoint:
    (EditorDocument, @escaping () -> FileStateLiveContext?, @escaping () -> Void) throws -> Void
  let endpointClosed: (UUID) -> Void
  let requestCheckpoint: () -> Void
}
enum EditorIntakeSelection {
  case select, preserve
  case selectIfStillSelected(documentID: UUID, ownershipGeneration: UUID)
}
@MainActor struct EditorPreparedSubmission {
  let endpointID: UUID
  let assignment: DocumentAssignment
  let seed: NativeDocumentSeed
  let provenance: DocumentIntakeProvenance
  let selection: EditorIntakeSelection
  let requireDestinationCurrent: () throws -> Void
  var insertionIndex: Int? = nil
}
enum EditorApplicationRoutingError: Error, LocalizedError {
  case staleEndpoint, invalidProjection, preparedSeedRequired, applicationOwned, unsupportedSeed
  var errorDescription: String? {
    switch self {
    case .staleEndpoint: return "The destination window changed. Retry in an open window."
    case .invalidProjection:
      return "The window no longer matches its document ownership. Retry the window update."
    case .preparedSeedRequired:
      return "This document route requires a prepared import before it can open in this window."
    case .applicationOwned:
      return "Application-owned documents must use the shared document operation."
    case .unsupportedSeed:
      return "This prepared document does not match the requested import route."
    }
  }
}
