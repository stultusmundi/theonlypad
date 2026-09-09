import Foundation
import PadCore
import XCTest

@testable import OpenRequests

private enum QueueFailure: Error { case endpointMissing, refused }
@MainActor private final class OpenGate {
  var entered = false
  var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func open() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
@MainActor final class ApplicationOpenRequestsTests: XCTestCase {
  private func requests(_ count: Int, prefix: String = "synthetic") -> [LaunchRequest] {
    (0..<count).map {
      LaunchRequest(url: URL(fileURLWithPath: "/\(prefix)/\($0).txt"), line: $0 + 1, column: 2)
    }
  }
  private func eventually(_ predicate: () -> Bool) async {
    for _ in 0..<2000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("Expected queue transition")
  }
  private func refuses(_ operation: () throws -> Void) {
    do {
      try operation()
      XCTFail("Expected refusal")
    } catch {}
  }
  func testStartupGateAndAcceptedPrefixFIFOOverflow() async {
    var seen: [LaunchRequest] = []
    let queue = ApplicationOpenRequests { item in
      seen.append(item.request)
      return .completed
    }
    let values = requests(130)
    let admission = queue.enqueue(values)
    XCTAssertEqual(
      admission, .init(acceptedCount: 128, rejectedOverflowCount: 2, rejectedQuittingCount: 0))
    XCTAssertEqual(queue.pendingCount, 128)
    XCTAssertTrue(seen.isEmpty)
    queue.startupFinished()
    await eventually { queue.pendingCount == 0 }
    XCTAssertEqual(seen, Array(values.prefix(128)))
  }
  func testActiveAndRetainedCurrentBothCountTowardBound() async throws {
    let gate = OpenGate()
    let queue = ApplicationOpenRequests { _ in
      await gate.wait()
      return .retained(QueueFailure.endpointMissing)
    }
    queue.startupFinished()
    _ = queue.enqueue(requests(1))
    await eventually { gate.entered }
    XCTAssertEqual(
      queue.enqueue(requests(128)),
      .init(acceptedCount: 127, rejectedOverflowCount: 1, rejectedQuittingCount: 0))
    gate.open()
    await queue.drainCurrent()
    XCTAssertFalse(queue.isProcessing)
    XCTAssertEqual(queue.pendingCount, 128)
    XCTAssertNotNil(queue.currentRequest)
    XCTAssertNotNil(queue.lastFailure)
    XCTAssertEqual(queue.enqueue(requests(2)).rejectedOverflowCount, 2)
  }
  func testQuitRetainsActiveAndQueuedWhileRejectingNewArrivals() async {
    let gate = OpenGate()
    var seen: [LaunchRequest] = []
    let queue = ApplicationOpenRequests { item in
      seen.append(item.request)
      if seen.count == 1 { await gate.wait() }
      return .completed
    }
    let initial = requests(3)
    queue.startupFinished()
    _ = queue.enqueue(initial)
    await eventually { gate.entered }
    let current = queue.currentID
    queue.beginQuit()
    XCTAssertEqual(queue.currentID, current)
    XCTAssertEqual(
      queue.enqueue(requests(4)),
      .init(acceptedCount: 0, rejectedOverflowCount: 0, rejectedQuittingCount: 4))
    gate.open()
    await queue.drainCurrent()
    XCTAssertEqual(seen, [initial[0]])
    XCTAssertEqual(queue.pendingCount, 2)
    queue.resumeAfterVeto()
    await eventually { queue.pendingCount == 0 }
    XCTAssertEqual(seen, initial)
  }
  func testVetoDoesNotBypassStartupOrRetryRetainedAutomatically() async throws {
    var calls = 0
    let queue = ApplicationOpenRequests { _ in
      calls += 1
      return .retained(QueueFailure.endpointMissing)
    }
    _ = queue.enqueue(requests(1))
    queue.beginQuit()
    queue.resumeAfterVeto()
    await Task.yield()
    XCTAssertEqual(calls, 0)
    queue.startupFinished()
    await eventually { calls == 1 && !queue.isProcessing }
    queue.beginQuit()
    queue.resumeAfterVeto()
    await Task.yield()
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(queue.pendingCount, 1)
  }
  func testRetryUsesSameEnvelopeBeforeNextFIFORequest() async throws {
    var ids: [UUID] = []
    var values: [LaunchRequest] = []
    let queue = ApplicationOpenRequests { item in
      ids.append(item.id)
      values.append(item.request)
      return ids.count == 1 ? .retained(QueueFailure.endpointMissing) : .completed
    }
    let initial = requests(2)
    _ = queue.enqueue(initial)
    queue.startupFinished()
    await eventually { ids.count == 1 && !queue.isProcessing }
    try queue.retryCurrent()
    await eventually { queue.pendingCount == 0 }
    XCTAssertEqual(ids.count, 3)
    if ids.count == 3 {
      XCTAssertEqual(ids[0], ids[1])
      XCTAssertNotEqual(ids[1], ids[2])
    }
    XCTAssertEqual(values, [initial[0], initial[0], initial[1]])
  }
  func testCancelledDrainWaiterDoesNotCancelOwnedProcessing() async {
    let gate = OpenGate()
    var cancelledInside = false
    let queue = ApplicationOpenRequests { _ in
      await gate.wait()
      cancelledInside = Task.isCancelled
      return .completed
    }
    queue.startupFinished()
    _ = queue.enqueue(requests(1))
    await eventually { gate.entered }
    let waiter = Task { await queue.drainCurrent() }
    waiter.cancel()
    gate.open()
    await waiter.value
    await eventually { queue.pendingCount == 0 }
    XCTAssertFalse(cancelledInside)
  }
  func testNotificationReentryCannotDuplicateProcessorAndExplicitRefusalContinues() async {
    var ids: [UUID] = []
    var active = 0
    var maxActive = 0
    let queue = ApplicationOpenRequests { item in
      active += 1
      maxActive = max(maxActive, active)
      ids.append(item.id)
      await Task.yield()
      active -= 1
      return ids.count == 1 ? .refused(QueueFailure.refused) : .completed
    }
    var added = false
    queue.onChange = {
      if queue.isProcessing {
        self.refuses { try queue.retryCurrent() }
        if !added {
          added = true
          _ = queue.enqueue(self.requests(1, prefix: "reentrant"))
        }
      }
    }
    queue.startupFinished()
    _ = queue.enqueue(requests(1))
    await eventually { queue.pendingCount == 0 }
    XCTAssertEqual(ids.count, 2)
    XCTAssertEqual(Set(ids).count, 2)
    XCTAssertEqual(maxActive, 1)
    XCTAssertEqual(queue.lastFailure?.id, ids.first)
  }
  func testRetainedNotificationRetryCannotBeClearedByOldCompletion() async {
    let second = OpenGate()
    var ids: [UUID] = []
    var retried = false
    let queue = ApplicationOpenRequests { item in
      ids.append(item.id)
      if ids.count == 1 { return .retained(QueueFailure.endpointMissing) }
      await second.wait()
      return .completed
    }
    queue.onChange = {
      if queue.currentID != nil, !queue.isProcessing, !retried {
        retried = true
        do { try queue.retryCurrent() } catch { XCTFail("Live retained retry must be admitted") }
      }
    }
    queue.startupFinished()
    _ = queue.enqueue(requests(1))
    await eventually { second.entered }
    XCTAssertTrue(queue.isProcessing)
    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertEqual(ids.count, 2)
    if ids.count == 2 { XCTAssertEqual(ids[0], ids[1]) }
    second.open()
    await queue.drainCurrent()
    XCTAssertEqual(queue.pendingCount, 0)
  }
  func testOwnedTaskRetainsQueueUntilEndpointFailureSettles() async {
    let gate = OpenGate()
    var received: LaunchRequest?
    var queue: ApplicationOpenRequests? = ApplicationOpenRequests { item in
      await gate.wait()
      received = item.request
      return .completed
    }
    weak var weakQueue = queue
    let request = requests(1)[0]
    queue!.startupFinished()
    _ = queue!.enqueue([request])
    await eventually { gate.entered }
    queue = nil
    XCTAssertNotNil(weakQueue)
    gate.open()
    await eventually { received != nil && weakQueue == nil }
    XCTAssertEqual(received, request)
  }
  func testQuitRetainedDrainReturnsWithoutAutomaticRetry() async {
    let gate = OpenGate()
    var calls = 0
    let queue = ApplicationOpenRequests { _ in
      calls += 1
      await gate.wait()
      return .retained(QueueFailure.endpointMissing)
    }
    queue.startupFinished()
    _ = queue.enqueue(requests(2))
    await eventually { gate.entered }
    queue.beginQuit()
    gate.open()
    await queue.drainCurrent()
    XCTAssertFalse(queue.isProcessing)
    XCTAssertEqual(queue.pendingCount, 2)
    self.refuses { try queue.retryCurrent() }
    queue.resumeAfterVeto()
    await Task.yield()
    XCTAssertEqual(calls, 1)
    XCTAssertNotNil(queue.currentID)
  }

}
