import Foundation
import PadCore

enum DocumentDiskAction { case reload, copy }
enum PreparedDiskAction {
  case reload(snapshot: ExternalFileActionSnapshot, selections: [UUID: NSRange])
  case copy(snapshot: ExternalFileActionSnapshot, seed: NativeDocumentSeed)
}
struct DocumentDiskActionInput {
  let documentID: UUID
  let url: URL
  let observation: DiskObservation
  let savedEncoding: DocumentEncoding
  let action: DocumentDiskAction
  let requiresDiscard: Bool
  let selections: [UUID: NSRange]
  let copySourceName: String?
  init(
    documentID: UUID, url: URL, observation: DiskObservation, savedEncoding: DocumentEncoding,
    action: DocumentDiskAction, requiresDiscard: Bool, selections: [UUID: NSRange] = [:],
    copySourceName: String? = nil
  ) {
    self.documentID = documentID
    self.url = url
    self.observation = observation
    self.savedEncoding = savedEncoding
    self.action = action
    self.requiresDiscard = requiresDiscard
    self.selections = selections
    self.copySourceName = copySourceName
  }
}
@MainActor struct DocumentDiskActionCallbacks {
  let beginOperation: () -> UUID?
  let isCurrent: (UUID) -> Bool
  let confirmDiscard: (ExternalFileActionSnapshot) -> Bool
  let apply: (PreparedDiskAction, UUID) throws -> Void
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
