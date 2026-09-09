import Foundation
import PadCore

struct DocumentIntakeID: Hashable { let rawValue: UUID }
enum DocumentIntakeStage {
  case validating, acquiring, draining, creating, registering, adopting, installing, activating
  case resolving, projecting, releasing, failed, settled
}
enum DocumentIntakeProvenance {
  case fresh
  case history(DocumentHistoryClaim)
  case session(SessionImportClaim)
  case recovery(SessionRecoveryImportClaim)
}
@MainActor struct DocumentIntakeRequest {
  let documentID: UUID
  let assignment: DocumentAssignment
  let metadata: WorkspaceDocumentMetadata
  let index: Int
  let select: Bool
  let utf16Count: Int
  let originalByteCount: Int
  let provenance: DocumentIntakeProvenance
  let makeHandle: () throws -> any WorkspaceDocumentHandle
  var resolveSelection: (() throws -> Bool)? = nil
}
struct DocumentIntakeStatus {
  let id: DocumentIntakeID
  let documentID: UUID
  let stage: DocumentIntakeStage
  let error: Error?
}
enum DocumentIntakeResult {
  case imported(UUID)
  case refused(Error)
  case retained(UUID, Error)
}
enum DocumentIntakeError: Error, Equatable, LocalizedError {
  case busy, invalidRequest, staleDestination, staleModel, unsettled, expired,
    cancellationUnavailable
  var errorDescription: String? {
    switch self {
    case .busy: return "Finish the current document import before opening another document."
    case .invalidRequest: return "The document import no longer matches its source or destination."
    case .staleDestination:
      return "The destination changed. Refresh the document list and retry."
    case .staleModel:
      return "Document ownership changed during import. Check its current state before retrying."
    case .unsettled: return "Finish the pending document import before checkpointing or quitting."
    case .expired:
      return "This import result is no longer available. Check the current document list."
    case .cancellationUnavailable:
      return "Import ownership has transferred. Finish its recovery before closing."
    }
  }
}
@MainActor struct DocumentIntakePublication {
  let acquirePause: () throws -> CheckpointPauseToken
  let drainPause: (CheckpointPauseToken) async throws -> Void
  let releasePause: (CheckpointPauseToken) throws -> Void
  let requestCheckpoint: () -> Void
}
@MainActor struct DocumentIntakeNative {
  let requireApplicationAdmission: () throws -> Void
  let validateDestination: (DocumentIntakeRequest) throws -> Void
  let preflightResources: (DocumentIntakeRequest) throws -> Void
  let drainLegacyWrites: () async throws -> Void
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentAdoptionState
  let install: (any WorkspaceDocumentHandle, RecoveryAdoptionReceipt, UUID) throws -> Void
  let project: (DocumentAssignment) throws -> Void
}
