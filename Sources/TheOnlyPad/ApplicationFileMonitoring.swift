import Foundation
import PadCore

@MainActor final class ApplicationFileMonitoring {
  struct ActionLease: Equatable {
    let id: UUID
    let documentID: UUID
  }
  let service: FileMonitorService
  lazy var client: any MonitorClient = NativeFileMonitorClient(service: service)
  private(set) var deliveryGeneration = UUID()
  private(set) var isSuspended = false
  private(set) var isStopped = false
  private var action: (lease: ActionLease, cancel: () -> Void)?
  var onStateChange: (() -> Void)?
  init(service: FileMonitorService = FileMonitorService()) { self.service = service }
  func suspend() {
    guard !isSuspended else { return }
    isSuspended = true
    deliveryGeneration = UUID()
    service.suspendDelivery()
    let previous = action
    action = nil
    previous?.cancel()
    onStateChange?()
  }
  func resume() {
    guard isSuspended, !isStopped else { return }
    isSuspended = false
    deliveryGeneration = UUID()
    let resumedGeneration = deliveryGeneration
    // Owners invalidate their prior generation before service callbacks are enabled.
    onStateChange?()
    // A synchronous owner callback may suspend, stop, or enter a newer transition.
    guard !isSuspended, !isStopped, deliveryGeneration == resumedGeneration else { return }
    service.resumeAndReconcile()
  }
  func reconcile() {
    guard !isSuspended, !isStopped else { return }
    service.resumeAndReconcile()
  }
  func stop() {
    guard !isStopped else { return }
    isStopped = true
    suspend()
    service.stop()
  }
  func beginAction(documentID: UUID, cancel: @escaping () -> Void) -> ActionLease? {
    guard !isSuspended, !isStopped, action == nil else { return nil }
    let lease = ActionLease(id: UUID(), documentID: documentID)
    action = (lease, cancel)
    return lease
  }
  @discardableResult func finishAction(_ lease: ActionLease) -> Bool {
    guard action?.lease == lease else { return false }
    action = nil
    return true
  }
  func cancelAction(documentID: UUID) {
    guard let previous = action, previous.lease.documentID == documentID else { return }
    action = nil
    previous.cancel()
  }
}
