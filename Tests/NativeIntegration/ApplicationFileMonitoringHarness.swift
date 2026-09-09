import Foundation
import PadCore

private final class DeliveryCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

@main struct ApplicationFileMonitoringHarness {
  @MainActor static func main() async throws {
    let owner = ApplicationFileMonitoring()
    var checks = 0
    var failures = 0
    func check(_ condition: Bool, _ description: String) {
      checks += 1
      if !condition {
        failures += 1
        print("FAIL: \(description)")
      }
    }
    var cancellations = 0
    var notifications = 0
    owner.onStateChange = { notifications += 1 }
    let a = UUID()
    let b = UUID()
    let lease = owner.beginAction(documentID: a) { cancellations += 1 }
    check(lease != nil, "first document action admitted")
    check(owner.beginAction(documentID: b, cancel: {}) == nil, "second document action refused")
    owner.cancelAction(documentID: b)
    check(cancellations == 0, "unrelated close does not cancel action")
    if let lease {
      check(owner.finishAction(lease), "own completion releases lease")
      check(!owner.finishAction(lease), "duplicate completion refused")
    }
    check(cancellations == 0, "normal completion does not cancel work")
    let second = owner.beginAction(documentID: b) { cancellations += 1 }
    check(second != nil, "next document admitted after release")
    if let lease {
      check(!owner.finishAction(lease), "stale completion cannot release newer lease")
    }
    owner.cancelAction(documentID: b)
    check(cancellations == 1, "owner close cancels exactly once")
    owner.cancelAction(documentID: b)
    check(cancellations == 1, "duplicate close is inert")
    let initialGeneration = owner.deliveryGeneration
    var readmission: ApplicationFileMonitoring.ActionLease?
    _ = owner.beginAction(documentID: a) {
      cancellations += 1
      readmission = owner.beginAction(documentID: b, cancel: {})
    }
    owner.suspend()
    check(
      owner.isSuspended && owner.deliveryGeneration != initialGeneration,
      "suspend fences generation")
    check(
      cancellations == 2 && readmission == nil, "suspend prevents reentrant cancellation admission")
    check(owner.beginAction(documentID: a, cancel: {}) == nil, "suspended actions refused")
    let suspendedGeneration = owner.deliveryGeneration
    owner.suspend()
    check(
      owner.deliveryGeneration == suspendedGeneration && notifications == 1,
      "duplicate suspend is inert")
    owner.reconcile()
    check(owner.isSuspended && notifications == 1, "activation does not resume quit")
    owner.resume()
    check(
      !owner.isSuspended && owner.deliveryGeneration != suspendedGeneration,
      "veto resumes with fresh generation")
    check(notifications == 2, "state changes notify owners once")
    let resumedGeneration = owner.deliveryGeneration
    owner.resume()
    check(owner.deliveryGeneration == resumedGeneration, "duplicate resume is inert")
    check(
      owner.beginAction(documentID: b, cancel: { cancellations += 1 }) != nil,
      "resumed action admitted")
    owner.stop()
    check(
      owner.isStopped && owner.isSuspended && cancellations == 3, "stop cancels active transaction")
    owner.resume()
    check(owner.isStopped && owner.isSuspended, "stopped owner cannot resume")
    check(owner.beginAction(documentID: a, cancel: {}) == nil, "stopped owner refuses actions")
    owner.stop()
    check(cancellations == 3, "duplicate stop does not recancel")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theonlypad-monitor-reentrancy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let file = fixture.appendingPathComponent("synthetic.txt")
    let bytes = Data("synthetic reentrant delivery\n".utf8)
    try bytes.write(to: file)
    let reentrantOwner = ApplicationFileMonitoring()
    defer { reentrantOwner.stop() }
    reentrantOwner.suspend()
    let delivered = DeliveryCount()
    let registration = try reentrantOwner.service.register(
      documentID: UUID(), url: file,
      baseline: bytes, baselineRevision: 1
    ) { _, _ in delivered.increment() }
    defer { registration.cancel() }
    reentrantOwner.onStateChange = {
      if !reentrantOwner.isSuspended { reentrantOwner.suspend() }
    }
    reentrantOwner.resume()
    check(reentrantOwner.isSuspended, "reentrant owner notification can suspend resumed owner")
    // A bounded negative interval is paired with positive resumed delivery below.
    try await Task.sleep(for: .seconds(1))
    check(delivered.value == 0, "reentrant suspend must keep real service delivery disabled")
    reentrantOwner.onStateChange = nil
    let beforeResume = delivered.value
    reentrantOwner.resume()
    let deadline = Date().addingTimeInterval(5)
    while delivered.value == beforeResume && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    check(delivered.value > beforeResume, "real delivery resumes after reentrant handler removed")
    registration.cancel()
    reentrantOwner.stop()
    try FileManager.default.removeItem(at: fixture)
    print("Application monitoring: \(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }
}
