import Foundation
import PadCore

struct DocumentTransferRequest: Equatable {
  let documentID: UUID
  let source: DocumentAssignment
  let target: DocumentAssignment
  let targetIndex: Int
  let workspaceRevision: UUID
  let ownershipGeneration: UUID
}
/// Scalar-only callback result. Native callers must fold pending preparation/undo/pane-install work into isBusy.
struct DocumentTransferState: Equatable {
  let documentID: UUID
  let kind: WorkspaceDocumentKind
  let ownershipGeneration: UUID
  let mutationGeneration: UUID
  let editRevision: UInt64
  let baselineRevision: UInt64
  let operationID: UUID?
  let pendingPublicationID: UUID?
  let isBusy: Bool
  let hasPendingTextEdits: Bool
  let isComposing: Bool
  let recoveryAuthority: RecoveryWriteAuthority?
  let highestIssuedRevision: UInt64
}
struct DocumentTransferOwnership: Equatable {
  let ownershipGeneration: UUID
  let mutationGeneration: UUID
}
@MainActor struct DocumentTransferServices {
  /// Mint and assign both tokens without external callbacks; return the exact minted pair.
  let rotateOwnership: (any WorkspaceDocumentHandle) -> DocumentTransferOwnership
  let readState: (any WorkspaceDocumentHandle) throws -> DocumentTransferState
}
enum DocumentTransferPhase { case reserved, rotated, staged, restored }
enum DocumentTransferError: Error {
  case unavailable, invalidRequest, stale, invalidPhase, unsafeState
}
/// Diagnostic exact-lease snapshot. Call validateTransferSnapshot for projection authorization.
@MainActor struct DocumentTransferSnapshot {
  let lease: DocumentTransferLease
  let request: DocumentTransferRequest
  let handle: any WorkspaceDocumentHandle
  let originalSource: DocumentWindowSnapshot
  let originalTarget: DocumentWindowSnapshot
  let source: DocumentWindowSnapshot
  let target: DocumentWindowSnapshot
  let expectedState: DocumentTransferState
  let phase: DocumentTransferPhase
  let effectsStarted: Bool
  let requiresReconciliation: Bool
  let failure: Error?
}
