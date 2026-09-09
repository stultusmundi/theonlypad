import Foundation
import PadCore

enum DocumentDiskAction { case reload, copy }
struct DocumentDiskActionInput {
  let documentID: UUID
  let url: URL
  let observation: DiskObservation
  let savedEncoding: DocumentEncoding
  let action: DocumentDiskAction
  let requiresDiscard: Bool
  let selections: [UUID: NSRange]
  init(
    documentID: UUID, url: URL, observation: DiskObservation, savedEncoding: DocumentEncoding,
    action: DocumentDiskAction, requiresDiscard: Bool, selections: [UUID: NSRange] = [:]
  ) {
    self.documentID = documentID
    self.url = url
    self.observation = observation
    self.savedEncoding = savedEncoding
    self.action = action
    self.requiresDiscard = requiresDiscard
    self.selections = selections
  }
}
@MainActor struct DocumentDiskActionCallbacks {
  let beginOperation: () -> UUID?
  let isCurrent: (UUID) -> Bool
  let confirmDiscard: (ExternalFileActionSnapshot) -> Bool
  let apply: (ExternalFileActionSnapshot, [UUID: NSRange], UUID) throws -> Void
  let finish: (UUID) -> Void
  let reportError: (Error) -> Void
}
protocol DiskActionCancellation: Sendable { func cancel() }
@MainActor protocol DiskActionClient {
  func read(
    requestID: UUID, input: DocumentDiskActionInput,
    receive: @escaping @Sendable (UUID, Result<ExternalFileActionSnapshot, FileActionError>) -> Void
  ) -> any DiskActionCancellation
  func revalidate(
    requestID: UUID, snapshot: ExternalFileActionSnapshot,
    receive: @escaping @Sendable (UUID, Result<Void, FileActionError>) -> Void
  ) -> any DiskActionCancellation
}
private struct NativeDiskActionCancellation: DiskActionCancellation {
  let token: FileActionToken
  func cancel() { token.cancel() }
}
@MainActor struct NativeDiskActionClient: DiskActionClient {
  let service: FileMonitorService
  func read(
    requestID: UUID, input: DocumentDiskActionInput,
    receive: @escaping @Sendable (UUID, Result<ExternalFileActionSnapshot, FileActionError>) -> Void
  ) -> any DiskActionCancellation {
    NativeDiskActionCancellation(
      token: service.readOnce(
        requestID: requestID, url: input.url,
        matching: input.observation, fallbackEncoding: input.savedEncoding, receive: receive))
  }
  func revalidate(
    requestID: UUID, snapshot: ExternalFileActionSnapshot,
    receive: @escaping @Sendable (UUID, Result<Void, FileActionError>) -> Void
  ) -> any DiskActionCancellation {
    NativeDiskActionCancellation(
      token: service.revalidateOnce(requestID: requestID, snapshot: snapshot, receive: receive))
  }
}
