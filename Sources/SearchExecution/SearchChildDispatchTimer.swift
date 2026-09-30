import Dispatch

/// One-shot absolute uptime scheduling. Dispatch sources permit concurrent,
/// idempotent cancellation; an action already running is fenced by its lifecycle
/// generation/token, not synchronously joined by this owner.
final class SearchChildDispatchTimer: SearchChildTimer, @unchecked Sendable {
  private let source: DispatchSourceTimer

  init(deadline: UInt64, queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
    source = DispatchSource.makeTimerSource(queue: queue)
    source.setEventHandler(handler: action)
    source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
    source.activate()
  }

  func cancel() { source.cancel() }

  deinit { source.cancel() }
}
