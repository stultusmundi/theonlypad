import Foundation
import PadCore

private final class RegistrationAdapter: MonitorHandle, @unchecked Sendable {
  let handle: FileMonitorRegistration
  init(_ handle: FileMonitorRegistration) { self.handle = handle }
  private func map(_ value: FileMonitorSnapshot) -> MonitorSnapshot {
    MonitorSnapshot(
      currentToken: value.currentToken, cancelled: value.cancelled,
      documentID: value.documentID, epoch: value.epoch, baselineRevision: value.baselineRevision,
      boundIdentity: value.boundIdentity)
  }
  var snapshot: MonitorSnapshot { map(handle.snapshot) }
  func cancelAndSnapshot() -> MonitorSnapshot { map(handle.cancelAndSnapshot()) }
  func cancel() { handle.cancel() }
}
private final class ManualAdapter: ManualHandle, @unchecked Sendable {
  let handle: FileCheckToken
  init(_ handle: FileCheckToken) { self.handle = handle }
  func cancel() { handle.cancel() }
}
@MainActor final class NativeFileMonitorClient: MonitorClient {
  let service: FileMonitorService
  init(service: FileMonitorService) { self.service = service }
  func register(
    id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> any MonitorHandle {
    do {
      return RegistrationAdapter(
        try service.register(
          documentID: id, url: url, baseline: baseline,
          baselineRevision: revision, boundIdentity: boundIdentity, receive: receive))
    } catch FileMonitorError.capacity { throw MonitorFailure.capacity } catch {
      throw MonitorFailure.unavailable
    }
  }
  func rebind(id: UUID, url: URL, baseline: Data, revision: UInt64) throws {
    try service.rebind(documentID: id, url: url, baseline: baseline, baselineRevision: revision)
  }
  func requestCheck(id: UUID) { service.requestCheck(documentID: id, forceContents: true) }
  func checkOnce(
    requestID: UUID, id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void
  ) -> any ManualHandle {
    ManualAdapter(
      service.checkOnce(
        requestID: requestID, documentID: id, url: url,
        baseline: baseline, baselineRevision: revision, boundIdentity: boundIdentity
      ) { id, result in
        receive(
          id,
          result.mapError { error in
            switch error {
            case .capacity: return .capacity
            case .cancelled: return .cancelled
            case .failed, .invalidRequest, .stopped: return .unavailable
            }
          })
      })
  }
}
