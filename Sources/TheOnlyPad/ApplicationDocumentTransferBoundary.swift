import Foundation

struct ApplicationDocumentTransferID: Equatable { let rawValue: UUID }
enum ApplicationDocumentTransferResult {
  case moved
  case restored(Error)
  case retained(Error)
}
enum ApplicationDocumentTransferError: Error, LocalizedError {
  case busy, expired, pendingLayout
  var errorDescription: String? {
    switch self {
    case .busy: return "A document move is still running. Wait for it to finish before retrying."
    case .expired: return "This move is no longer available. Select the document and try again."
    case .pendingLayout:
      return
        "The document layout needs recovery. Use Retry Recovery before moving more documents or quitting."
    }
  }
}

/// Exact process-owned macro quarantine. Object identifiers compare current live
/// objects; this trusted internal value is not registry authority by itself.
struct MacroTransferSuspension: Equatable {
  let lease: DocumentTransferLease
  let documentID: UUID
  let documentObjectID: ObjectIdentifier
  let storageID: ObjectIdentifier
}

/// Strong transaction-owned native receipt; concrete adapters keep endpoint and monitor phases here.
@MainActor protocol ApplicationDocumentTransferReceipt: AnyObject {}
@MainActor struct ApplicationDocumentTransferPublication {
  let requireAdmission: () throws -> Void
  let acquirePause: () throws -> CheckpointPauseToken
  let drainPause: (CheckpointPauseToken) async throws -> Void
  let releasePause: (CheckpointPauseToken) throws -> Void
  let requestCheckpoint: () -> Void
}
@MainActor struct ApplicationDocumentTransferNative {
  /// Required pure quarantine service; no permissive default implementation.
  let suspendMacroBinding: (DocumentTransferSnapshot) throws -> MacroTransferSuspension
  let finishMacroBinding:
    (
      MacroTransferSuspension, ApplicationDocumentTransferTerminalReceipt,
      (any ApplicationDocumentTransferReceipt)?
    ) throws -> Void
  /// Required post-atomic route completion. May callback/throw; the process has
  /// already marked suspension release consumed and retains that fact on retry.
  let completeApprovedViewRouting:
    (
      MacroTransferSuspension, ApplicationDocumentTransferTerminalReceipt,
      (any ApplicationDocumentTransferReceipt)?
    ) throws -> Void
  /// Bounded capture only. No endpoint effects before the receipt is returned to its owner.
  let capture: (DocumentTransferSnapshot) throws -> any ApplicationDocumentTransferReceipt
  let validate: (DocumentTransferSnapshot, any ApplicationDocumentTransferReceipt) throws -> Void
  let suspendMonitor:
    (DocumentTransferSnapshot, any ApplicationDocumentTransferReceipt) throws -> Void
  let projectSource:
    (DocumentTransferSnapshot, any ApplicationDocumentTransferReceipt) throws -> Void
  let projectTarget:
    (DocumentTransferSnapshot, any ApplicationDocumentTransferReceipt) throws -> Void
  let attachMonitor:
    (DocumentTransferSnapshot, any ApplicationDocumentTransferReceipt) throws -> Void
  let refreshAdmission: (any ApplicationDocumentTransferReceipt) throws -> Void
  let finishMonitor:
    (DocumentTransferSnapshot, any ApplicationDocumentTransferReceipt) throws -> Void
}

/// Terminal placement provenance captured before public settlement notifications. It is not
/// authority to project models or to ignore later workspace changes.
struct ApplicationDocumentTransferTerminalReceipt {
  let request: DocumentTransferRequest
  let workspaceRevision: UUID
  let moved: Bool
}
