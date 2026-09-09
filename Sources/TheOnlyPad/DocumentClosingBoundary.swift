import Foundation
import PadCore

struct DocumentClosingID: Hashable { let rawValue: UUID }
enum DocumentClosingStage {
  case confirming, acquiring, admitting, draining, preflighting, preparing, deleting
  case registrySettlement, retiring, capturingRepair, repairing, installingRepair
  case needsFreshLease, projecting, drainingUnusedPause, failed, settled
}
struct DocumentClosingStatus {
  let id: DocumentClosingID
  let documentID: UUID?
  let stage: DocumentClosingStage
  let recoveryPaused: Bool
  let error: Error?
}
enum DocumentClosingResult {
  case completed(closedIDs: [UUID])
  case cancelled(closedIDs: [UUID])
  case retained(closedIDs: [UUID], documentID: UUID, error: Error)
}
enum DocumentClosingError: Error, Equatable, LocalizedError {
  case busy, invalidRequest, expiredResult, cancellationUnavailable, staleState
  case unsupportedKind, ownershipChanged, pendingRecovery
  var errorDescription: String? {
    switch self {
    case .busy: return "Finish the current close or recovery operation before starting another."
    case .invalidRequest: return "Choose between 1 and 128 distinct documents to close."
    case .expiredResult:
      return "This close operation is no longer available. Check the current document state."
    case .cancellationUnavailable:
      return "Closing has already begun. Finish recovery before making another close decision."
    case .staleState: return "The document changed during closing. Keep it open and retry recovery."
    case .unsupportedKind: return "This document is not available for this close operation."
    case .ownershipChanged:
      return "Document ownership changed during closing. Its content has been retained."
    case .pendingRecovery:
      return
        "A close or recovery operation is unfinished. Finish it before checkpointing or quitting."
    }
  }
}
@MainActor struct DocumentClosingPublication {
  let requireApplicationAdmission: () throws -> Void
  let acquirePause: () throws -> CheckpointPauseToken
  let drainPause: (CheckpointPauseToken) async throws -> Void
  let releasePause: (CheckpointPauseToken) throws -> Void
  let requestCheckpoint: () -> Void
}
struct DocumentClosingCapture {
  let state: DocumentCloseState
  let snapshot: RecoverySnapshot
  let authority: RecoveryWriteAuthority
  let highestIssuedRevision: UInt64
}
/// Immutable native expectation captured before actor repair; distinct from the actor lease epoch.
struct DocumentClosingRepairContext {
  let state: DocumentCloseState
  let modelAuthority: RecoveryWriteAuthority
  let highestIssuedRevision: UInt64
}
@MainActor struct DocumentClosingNative {
  let confirm: (DocumentCloseRequest, UUID) async throws -> DocumentCloseDisposition?
  let applyAdmission: (any WorkspaceDocumentHandle) throws -> Void
  let drainLegacyWrites: (any WorkspaceDocumentHandle) async throws -> Void
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentCloseState
  let capture: (any WorkspaceDocumentHandle) throws -> DocumentClosingCapture
  let installRepair:
    (
      any WorkspaceDocumentHandle, DocumentRecoveryAttempt, RecoveryRepairReceipt,
      DocumentClosingRepairContext
    ) throws -> Void
  let projectRegistry: () throws -> Void
}
