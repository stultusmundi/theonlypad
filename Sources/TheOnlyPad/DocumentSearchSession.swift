// SPDX-License-Identifier: MIT
import Foundation
import PadCore
import SearchExecution

struct DocumentSearchApprovalToken: Equatable {
  fileprivate let nonce: UUID
}

enum DocumentSearchSessionState: Equatable {
  case idle
  case searching
  case results(matchCount: Int, selectedIndex: Int?)
  case awaitingApproval(token: DocumentSearchApprovalToken, matchCount: Int)
  case replaced(matchCount: Int)
  case failed(ApplicationDocumentSearchFailure)
  case closed
}

@MainActor
final class DocumentSearchSession {
  private final class Invocation {
    let epoch: UUID
    let maximumMatches: Int
    let replacing: Bool
    var submitting = true
    var request: ApplicationDocumentSearchRequestID?
    var buffered: ApplicationDocumentSearchDelivery?

    init(epoch: UUID, maximumMatches: Int, replacing: Bool) {
      self.epoch = epoch
      self.maximumMatches = maximumMatches
      self.replacing = replacing
    }
  }

  private final class Result {
    let epoch: UUID
    let id: ApplicationDocumentSearchResultID
    let count: Int
    let maximumMatches: Int
    let hasReplacement: Bool
    var selectedIndex: Int?
    var approval: DocumentSearchApprovalToken?

    init(
      epoch: UUID, id: ApplicationDocumentSearchResultID, summary: DocumentSearchSummary,
      maximumMatches: Int
    ) {
      self.epoch = epoch
      self.id = id
      count = summary.matchCount
      self.maximumMatches = maximumMatches
      hasReplacement = summary.hasReplacement
    }
  }

  private let onState: @MainActor (DocumentSearchSessionState) -> Void
  private var consumer: ApplicationDocumentSearchConsumer?
  private var epoch = UUID()
  private var invocation: Invocation?
  private var result: Result?
  private(set) var state: DocumentSearchSessionState = .idle

  init(
    owner: ApplicationSearchOwner, window: ApplicationSearchWindowID,
    source: any ApplicationDocumentSearchSource,
    onState: @escaping @MainActor (DocumentSearchSessionState) -> Void
  ) throws {
    self.onState = onState
    consumer = try owner.attachDocument(
      window: window, source: source,
      onDelivery: { [weak self] delivery in self?.receive(delivery) })
  }

  func start(
    query: SearchQuery, operation: SearchExecutionOperation,
    scope: NSRange?, limits: SearchWireLimits
  ) throws {
    guard let consumer else { throw ApplicationDocumentSearchFailure.closed }
    let intent = invalidate()
    let replacing: Bool
    switch operation {
    case .find: replacing = false
    case .replace: replacing = true
    }
    let pending = Invocation(
      epoch: intent, maximumMatches: limits.maxMatches, replacing: replacing)
    invocation = pending
    guard publish(.searching, expected: intent), isCurrent(pending) else {
      throw refusalAfterReentry()
    }

    let request: ApplicationDocumentSearchRequestID
    do {
      request = try consumer.start(query: query, operation: operation, scope: scope, limits: limits)
    } catch {
      let failure =
        (error as? ApplicationDocumentSearchFailure) ?? .admission(.internalFailure)
      // A thrown submit wins over any synchronous delivery buffered by this invocation.
      guard isCurrent(pending) else { throw refusalAfterReentry() }
      fail(failure, expected: intent, consumer: consumer)
      guard isCurrent(intent) else { throw refusalAfterReentry() }
      throw failure
    }
    guard isCurrent(pending) else { throw refusalAfterReentry() }
    pending.request = request
    pending.submitting = false
    let buffered = pending.buffered
    pending.buffered = nil
    if let buffered {
      receive(buffered)
      guard isCurrent(intent) else { throw refusalAfterReentry() }
    }
  }

  func cancel() {
    guard let consumer else { return }
    let intent = invalidate()
    consumer.cancel()
    // Backend cancellation/release may have synchronously started a newer intent.
    _ = publish(.idle, expected: intent)
  }

  func close() {
    guard let consumer else { return }
    let intent = invalidate()
    self.consumer = nil
    state = .closed
    consumer.close()
    guard epoch == intent else { return }
    onState(.closed)
    // No further old-intent state is published after the presentation callback.
  }

  @discardableResult
  func next() -> Bool { navigate(forward: true) }

  @discardableResult
  func previous() -> Bool { navigate(forward: false) }

  @discardableResult
  func resolveApproval(_ token: DocumentSearchApprovalToken, approved: Bool) -> Bool {
    guard let consumer, let held = result, isCurrent(held), held.approval == token else {
      return false
    }
    let intent = held.epoch
    // Consume presentation authority before any owner callback can reenter.
    held.approval = nil
    result = nil
    if !approved {
      consumer.cancel()
      _ = publish(.idle, expected: intent)
      return false
    }
    let replaced = consumer.replaceAll(result: held.id)
    guard isCurrent(intent) else { return false }
    if replaced { return publish(.replaced(matchCount: held.count), expected: intent) }
    fail(.staleSource, expected: intent, consumer: consumer)
    return false
  }

  private func receive(_ delivery: ApplicationDocumentSearchDelivery) {
    guard let consumer, let pending = invocation, isCurrent(pending) else { return }
    if pending.submitting {
      if pending.buffered == nil {
        pending.buffered = delivery
      } else {
        fail(.admission(.internalFailure), expected: pending.epoch, consumer: consumer)
      }
      return
    }
    let request: ApplicationDocumentSearchRequestID
    switch delivery {
    case .completed(let id, _, _): request = id
    case .failed(let id, _): request = id
    }
    guard pending.request == request else { return }
    invocation = nil
    switch delivery {
    case .failed(_, let failure):
      fail(failure, expected: pending.epoch, consumer: consumer)
    case .completed(_, let id, let summary):
      guard summary.matchCount >= 0, summary.matchCount <= pending.maximumMatches else {
        fail(.admission(.semantic(.matchLimit)), expected: pending.epoch, consumer: consumer)
        return
      }
      guard summary.hasReplacement == pending.replacing else {
        fail(.admission(.internalFailure), expected: pending.epoch, consumer: consumer)
        return
      }
      let held = Result(
        epoch: pending.epoch, id: id, summary: summary,
        maximumMatches: pending.maximumMatches)
      result = held
      if pending.replacing && held.count > 0 {
        let token = DocumentSearchApprovalToken(nonce: UUID())
        held.approval = token
        _ = publish(.awaitingApproval(token: token, matchCount: held.count), expected: held.epoch)
      } else {
        _ = publish(.results(matchCount: held.count, selectedIndex: nil), expected: held.epoch)
      }
    }
  }

  private func navigate(forward: Bool) -> Bool {
    guard let consumer, let held = result, isCurrent(held), held.approval == nil,
      held.count > 0
    else { return false }
    let intent = held.epoch
    let summary = consumer.summary(for: held.id)
    guard isCurrent(held) else { return false }
    guard let summary, summary.matchCount == held.count,
      summary.matchCount <= held.maximumMatches, summary.hasReplacement == held.hasReplacement
    else {
      fail(.staleSource, expected: intent, consumer: consumer)
      return false
    }
    let index: Int
    if let selected = held.selectedIndex {
      if forward {
        index = selected == held.count - 1 ? 0 : selected + 1
      } else {
        index = selected == 0 ? held.count - 1 : selected - 1
      }
    } else {
      index = forward ? 0 : held.count - 1
    }
    let navigated = consumer.navigate(result: held.id, matchIndex: index)
    guard isCurrent(held) else { return false }
    guard navigated else {
      fail(.staleSource, expected: intent, consumer: consumer)
      return false
    }
    held.selectedIndex = index
    return publish(.results(matchCount: held.count, selectedIndex: index), expected: intent)
  }

  private func fail(
    _ failure: ApplicationDocumentSearchFailure, expected intent: UUID,
    consumer: ApplicationDocumentSearchConsumer
  ) {
    guard isCurrent(intent) else { return }
    invocation = nil
    result = nil
    consumer.cancel()
    _ = publish(.failed(failure), expected: intent)
  }

  private func invalidate() -> UUID {
    epoch = UUID()
    invocation = nil
    result = nil
    return epoch
  }

  private func isCurrent(_ intent: UUID) -> Bool { consumer != nil && epoch == intent }

  private func isCurrent(_ pending: Invocation) -> Bool {
    isCurrent(pending.epoch) && invocation === pending
  }

  private func isCurrent(_ held: Result) -> Bool {
    isCurrent(held.epoch) && result === held
  }

  @discardableResult
  private func publish(_ value: DocumentSearchSessionState, expected intent: UUID) -> Bool {
    guard isCurrent(intent) else { return false }
    state = value
    onState(value)
    return isCurrent(intent)
  }

  private func refusalAfterReentry() -> ApplicationDocumentSearchFailure {
    consumer == nil ? .closed : .cancelled
  }
}
