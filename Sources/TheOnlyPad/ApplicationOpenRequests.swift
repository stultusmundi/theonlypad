import Foundation
import PadCore

struct ApplicationOpenRequest: Sendable {
  let id: UUID
  let request: LaunchRequest
}
enum ApplicationOpenRequestOutcome {
  case completed
  case refused(Error)
  case retained(Error)
}
struct OpenRequestAdmission: Equatable {
  let acceptedCount: Int
  let rejectedOverflowCount: Int
  let rejectedQuittingCount: Int
}
struct OpenRequestFailure {
  let id: UUID
  let error: Error
}
enum OpenRequestQueueError: Error { case noRetainedRequest, gated, busy }
/// Process-owned FIFO. The callback performs opening; this type never reads a file or executes commands.
@MainActor final class ApplicationOpenRequests {
  static let maximumPending = 128
  private final class Current {
    let value: ApplicationOpenRequest
    var task: Task<Void, Never>?
    var retained = false
    init(_ value: ApplicationOpenRequest) { self.value = value }
  }
  private let process: @MainActor (ApplicationOpenRequest) async -> ApplicationOpenRequestOutcome
  private var queue: [ApplicationOpenRequest] = []
  private var current: Current?
  private var startupReady = false
  private var quitting = false
  private(set) var lastFailure: OpenRequestFailure?
  var onChange: (() -> Void)?
  var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }
  var currentID: UUID? { current?.value.id }
  var currentRequest: ApplicationOpenRequest? { current?.value }
  var isProcessing: Bool { current?.task != nil }
  init(
    process: @escaping @MainActor (ApplicationOpenRequest) async -> ApplicationOpenRequestOutcome
  ) {
    self.process = process
  }
  func enqueue(_ requests: [LaunchRequest]) -> OpenRequestAdmission {
    guard !quitting else {
      return .init(
        acceptedCount: 0, rejectedOverflowCount: 0, rejectedQuittingCount: requests.count)
    }
    let accepted = min(requests.count, Self.maximumPending - pendingCount)
    queue.append(contentsOf: requests.prefix(accepted).map { .init(id: UUID(), request: $0) })
    pump()
    let result = OpenRequestAdmission(
      acceptedCount: accepted,
      rejectedOverflowCount: requests.count - accepted, rejectedQuittingCount: 0)
    if accepted > 0 { onChange?() }
    return result
  }
  func startupFinished() {
    guard !startupReady else { return }
    startupReady = true
    pump()
    onChange?()
  }
  func beginQuit() {
    guard !quitting else { return }
    quitting = true
    onChange?()
  }
  /// Wait only for the task captured at entry, never for a retained failure or queued successor.
  /// Cancellation of this waiter does not transfer cancellation to the process-owned task.
  func drainCurrent() async {
    let task = current?.task
    await task?.value
  }
  func resumeAfterVeto() {
    guard quitting else { return }
    quitting = false
    pump()
    onChange?()
  }
  func retryCurrent() throws {
    guard startupReady, !quitting else { throw OpenRequestQueueError.gated }
    guard let current else { throw OpenRequestQueueError.noRetainedRequest }
    guard current.task == nil else { throw OpenRequestQueueError.busy }
    guard current.retained else { throw OpenRequestQueueError.noRetainedRequest }
    current.retained = false
    launch(current)
    onChange?()
  }
  private func pump() {
    guard startupReady, !quitting, current == nil, !queue.isEmpty else { return }
    let value = Current(queue.removeFirst())
    current = value
    launch(value)
  }
  private func launch(_ value: Current) {
    // The current record and owned task exist before any external callback can run.
    value.task = Task {
      let outcome = await self.process(value.value)
      self.complete(value, outcome: outcome)
    }
  }
  private func complete(_ value: Current, outcome: ApplicationOpenRequestOutcome) {
    guard current === value else { return }
    value.task = nil
    switch outcome {
    case .completed:
      current = nil
    case .refused(let error):
      lastFailure = .init(id: value.value.id, error: error)
      current = nil
    case .retained(let error):
      lastFailure = .init(id: value.value.id, error: error)
      value.retained = true
    }
    pump()
    onChange?()
    // No task/current cleanup after notification: a callback may already have retried or enqueued.
  }
}
