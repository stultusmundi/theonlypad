import Dispatch
import Foundation

extension SearchParentWireDriver {
  /// Fixed bundled helper; filesystem validation remains on the launch lane.
  package convenience init(applicationBundle: URL) throws {
    let timers = DispatchQueue(label: "TheOnlyPad.search-parent.timers")
    try self.init(
      applicationBundle: applicationBundle, system: SearchChildLauncher(),
      now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { SearchChildDispatchTimer(deadline: $0, queue: timers, action: $1) })
  }

  convenience init(
    applicationBundle: URL, system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> any SearchChildTimer,
    observe: (@Sendable (SearchParentDriverEvent) -> Void)? = nil
  ) throws {
    let candidate = try SearchWorkerBundleResolver.candidate(in: applicationBundle)
    let lifecycle = try SearchChildLifecycle(
      executable: candidate, policy: SearchParentProductionPolicy.childPolicy(),
      system: system, now: now, schedule: schedule)
    try self.init(
      lifecycle: lifecycle,
      accumulatorFactory: { SearchParentResponseAccumulator(request: $0) },
      maximumWireBytesPerChild: SearchParentProductionPolicy.maximumWireBytesPerChild,
      observe: observe)
  }
}

enum SearchParentProductionPolicy {
  static func childPolicy() throws -> SearchChildPolicy {
    try SearchChildPolicy(
      operationNanoseconds: 10_000_000_000,
      reapGraceNanoseconds: 2_000_000_000,
      idleNanoseconds: 10_000_000_000,
      maximumRequestsPerChild: 8)
  }

  /// Completed stream I/O retirement threshold, not a payload or memory cap.
  static let maximumWireBytesPerChild: UInt64 = 268_435_456
}
