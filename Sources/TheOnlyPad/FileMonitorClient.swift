import Foundation
import PadCore

struct MonitorSnapshot: Sendable {
  let currentToken: FileObservationToken?
  let cancelled: Bool
  let documentID: UUID
  let epoch: UInt64
  let baselineRevision: UInt64
  let boundIdentity: FileTargetIdentity?
}
protocol MonitorHandle: AnyObject, Sendable {
  var snapshot: MonitorSnapshot { get }
  func cancel()
  func cancelAndSnapshot() -> MonitorSnapshot
}
protocol ManualHandle: AnyObject, Sendable { func cancel() }
enum MonitorFailure: Error, Sendable { case capacity, unavailable, cancelled }
@MainActor protocol MonitorClient: AnyObject {
  func register(
    id: UUID, url: URL, baseline: Data, revision: UInt64, boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> any MonitorHandle
  func rebind(id: UUID, url: URL, baseline: Data, revision: UInt64) throws
  func requestCheck(id: UUID)
  func checkOnce(
    requestID: UUID, id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void
  ) -> any ManualHandle
}
struct FileStateLiveContext: Equatable {
  let documentID: UUID
  var ownershipGeneration: UUID? = nil
  var bindingID: UUID
  var baselineRevision: UInt64
  var url: URL?
  var editRevision: UInt64 = 0
  var encoding: DocumentEncoding = .utf8
  var hasBOM = false
  var dirty = false
  var pendingPublicationID: UUID?
  var operationID: UUID?
  var composing = false
  var recording = false
  var closed = false
  var quitting = false
  var deliveryGeneration = UUID()
}
struct FileStateActionContext {
  let live: FileStateLiveContext
  let authorityID: UUID
  let token: FileObservationToken
  let action: FileConflictAction
}
