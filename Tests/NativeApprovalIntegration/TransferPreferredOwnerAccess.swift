// SPDX-License-Identifier: MIT
// Test-only observation after the actual owner prepareQuit has returned.
// checkpoints is already initialized by that real operation; no admission or setter.
struct TransferPreferredEndpointFacts {
  let windowID: UUID
  let endpointID: UUID
  let assignment: DocumentAssignment
  let controller: EditorWindowController?
}
struct TransferPreferredQuitFacts {
  let quitting: Bool
  let phase: ApplicationPublisherPhase
  let acknowledgedGeneration: UInt64
  let checkpointHasError: Bool
  let endpoints: [TransferPreferredEndpointFacts]
}
@MainActor extension NativeApplicationDocuments {
  var transferPreferredTestQuitFacts: TransferPreferredQuitFacts {
    .init(
      quitting: quitting, phase: checkpoints.phase,
      acknowledgedGeneration: checkpoints.lastAcknowledgedGeneration,
      checkpointHasError: checkpoints.lastError != nil,
      endpoints: endpoints.map { key, value in
        .init(
          windowID: key, endpointID: value.id, assignment: value.assignment,
          controller: value.controller)
      })
  }
}

// SPDX-License-Identifier: MIT
// Test-only stored transfer/dictionary values. No lazy service, native getter or admission.
struct TransferPreferredRetirementEndpointFacts {
  let windowID: UUID
  let identity: ObjectIdentifier
  let endpointID: UUID
  let assignment: DocumentAssignment
  let controller: EditorWindowController?
}
struct TransferPreferredRetirementPresentationFacts {
  let identity: ObjectIdentifier
  let transactionID: UUID
  let request: DocumentTransferRequest
  let model: EditorDocument
  let sourceIdentity: ObjectIdentifier
  let sourceEndpointID: UUID
  let targetIdentity: ObjectIdentifier
  let targetEndpointID: UUID
}
struct TransferPreferredRetirementOwnerFacts {
  let moveID: ApplicationDocumentTransferID?
  let presentation: TransferPreferredRetirementPresentationFacts?
  let endpoints: [TransferPreferredRetirementEndpointFacts]
}
@MainActor extension NativeApplicationDocuments {
  var transferPreferredRetirementTestFacts: TransferPreferredRetirementOwnerFacts {
    .init(
      moveID: transferID,
      presentation: transferPresentation.map { value in
        .init(
          identity: ObjectIdentifier(value), transactionID: value.transactionID,
          request: value.request, model: value.model,
          sourceIdentity: ObjectIdentifier(value.source), sourceEndpointID: value.source.id,
          targetIdentity: ObjectIdentifier(value.target), targetEndpointID: value.target.id)
      },
      endpoints: endpoints.map { key, value in
        .init(
          windowID: key, identity: ObjectIdentifier(value), endpointID: value.id,
          assignment: value.assignment, controller: value.controller)
      })
  }
}
