import Dispatch

/// Main-queue backoff for a later admission inspection.
@MainActor package final class SearchAdmissionDispatchRetryScheduler: SearchAdmissionRetryScheduler
{
  package init() {}

  package func schedule(
    _ action: @escaping @MainActor () -> Void
  ) -> any SearchAdmissionRetryToken {
    SearchAdmissionDispatchRetryToken(action: action)
  }
}

/// The caller retains delivery authority; the queued work does not retain this token.
@MainActor private final class SearchAdmissionDispatchRetryToken: SearchAdmissionRetryToken {
  private var action: (@MainActor () -> Void)?
  private var item: DispatchWorkItem?

  init(action: @escaping @MainActor () -> Void) {
    self.action = action
    let item = DispatchWorkItem { [weak self] in
      // This item's sole transport is the main queue below.
      MainActor.assumeIsolated {
        self?.fire()
      }
    }
    self.item = item
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(25_000_000), execute: item)
  }

  func cancel() {
    action = nil
    let item = item
    self.item = nil
    item?.cancel()
  }

  private func fire() {
    let action = action
    self.action = nil
    item = nil
    action?()
  }
}
