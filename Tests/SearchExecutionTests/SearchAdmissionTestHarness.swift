import Foundation
import PadCore

@testable import SearchExecution

actor AdmissionScriptedDriver: SearchParentWireDriving {
  private(set) var settlementCalls = 0
  private(set) var submitCalls = 0
  private(set) var waitCalls = 0
  private(set) var cancelCalls = 0
  private(set) var shutdownCalls = 0
  private var settlementValue: SearchParentWireSettlement = .pending
  private var settlementFailure: SearchParentWireDriverError?
  private var accepts = false
  private var holdsSubmit = false
  private var refuseUnsettled = false
  private var handle: SearchParentWireHandle?
  private var submitReturn: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<SearchParentWireOutcome, Error>?
  private var onSubmit: (@Sendable () -> Void)?
  private var onWait: (@Sendable () -> Void)?
  private var onCancel: (@Sendable () -> Void)?
  private var onShutdown: (@Sendable () -> Void)?
  private var holdsShutdown = false
  private var shutdownReturns: [CheckedContinuation<Void, Never>] = []
  private var holdsCancel = false
  private var cancelReturns: [CheckedContinuation<Void, Never>] = []
  private let shutdownReceipt = SearchParentWireShutdown(
    child: .init(cleanup: .stopping(generation: UUID()), channelsClosed: false),
    parentLaneSettled: false, retainedParentLanes: 1)

  func configureAccepted(
    holdSubmit: Bool = false, holdCancel: Bool = false, onSubmit: (@Sendable () -> Void)? = nil,
    onWait: (@Sendable () -> Void)? = nil, onCancel: (@Sendable () -> Void)? = nil
  ) {
    accepts = true
    holdsSubmit = holdSubmit
    holdsCancel = holdCancel
    self.onSubmit = onSubmit
    self.onWait = onWait
    self.onCancel = onCancel
  }
  func configureRefusal() { accepts = false }
  func completeSuccess() throws {
    guard let handle else { return }
    let identity = try SearchWireIdentity(
      generation: UUID(), requestID: handle.requestID, ordinal: 1)
    waiter?.resume(
      returning: .completed(
        identity: identity, source: "x",
        output: .init(matches: [NSRange(location: 0, length: 1)], replacement: "y")))
    waiter = nil
  }
  func configureUnsettledRefusal() { refuseUnsettled = true }
  func setSettlementFailure(_ failure: SearchParentWireDriverError) { settlementFailure = failure }
  func setSettlement(_ value: SearchParentWireSettlement) { settlementValue = value }
  func settlement(after handle: SearchParentWireHandle?) async throws -> SearchParentWireSettlement
  {
    settlementCalls += 1
    guard handle == self.handle else { throw SearchParentWireDriverError.staleHandle }
    if let settlementFailure { throw settlementFailure }
    return settlementValue
  }
  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle {
    submitCalls += 1
    if !accepts {
      if refuseUnsettled { settlementValue = .pending }
      throw SearchParentWireDriverError.busy
    }
    let admitted = SearchParentWireHandle(nonce: UUID(), requestID: job.requestID)
    handle = admitted
    settlementValue = .pending
    if holdsSubmit {
      await withCheckedContinuation { continuation in
        submitReturn = continuation
        onSubmit?()
      }
    } else {
      onSubmit?()
    }
    return admitted
  }
  func releaseSubmit() {
    submitReturn?.resume()
    submitReturn = nil
  }
  func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome {
    guard self.handle == handle else { throw SearchParentWireDriverError.staleHandle }
    waitCalls += 1
    return try await withCheckedThrowingContinuation { continuation in
      waiter = continuation
      onWait?()
    }
  }
  func completeFailure(_ failure: SearchChildFailure = .cancelled) {
    waiter?.resume(returning: .failed(identity: nil, failure: failure))
    waiter = nil
  }
  func cancel(_ handle: SearchParentWireHandle) async throws {
    guard self.handle == handle else { throw SearchParentWireDriverError.staleHandle }
    cancelCalls += 1
    if holdsCancel {
      await withCheckedContinuation { continuation in
        cancelReturns.append(continuation)
        onCancel?()
      }
    } else {
      onCancel?()
    }
  }
  func releaseCancel() {
    let held = cancelReturns
    cancelReturns.removeAll()
    for continuation in held { continuation.resume() }
  }
  func discard(_ handle: SearchParentWireHandle) async throws {}
  func configureShutdown(hold: Bool = false, onShutdown: (@Sendable () -> Void)? = nil) {
    holdsShutdown = hold
    self.onShutdown = onShutdown
  }
  func releaseShutdown() {
    let held = shutdownReturns
    shutdownReturns.removeAll()
    for continuation in held { continuation.resume() }
  }
  func shutdown() async -> SearchParentWireShutdown {
    shutdownCalls += 1
    if holdsShutdown {
      await withCheckedContinuation { continuation in
        shutdownReturns.append(continuation)
        onShutdown?()
      }
    } else {
      onShutdown?()
    }
    return shutdownReceipt
  }
}

struct AdmissionTestAccounting: SearchAdmissionAccounting {
  var activeLimit: UInt64 = 20
  var retainedLimit: UInt64 = 20
  var resident: UInt64 = 2
  func charge(for descriptor: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge {
    .init(active: 4, retained: 3)
  }
}

@MainActor final class AdmissionManualRetry: SearchAdmissionRetryScheduler {
  final class Token: SearchAdmissionRetryToken {
    var action: (@MainActor () -> Void)?
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { action = nil }
  }
  private(set) var tokens: [Token] = []
  var onSchedule: (() -> Void)?
  func schedule(_ action: @escaping @MainActor () -> Void) -> any SearchAdmissionRetryToken {
    let token = Token(action)
    tokens.append(token)
    onSchedule?()
    return token
  }
  func fire() {
    guard let token = tokens.first(where: { $0.action != nil }), let action = token.action else {
      return
    }
    token.action = nil
    action()
  }
}

final class AdmissionWeakBox<Value: AnyObject> {
  weak var value: Value?
  init(_ value: Value?) { self.value = value }
}

actor AdmissionPreparationGate {
  private var continuation: CheckedContinuation<Bool, Never>?
  let entered: @Sendable () -> Void
  init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
  func prepare(_ text: String, _ estimate: Int, _ captured: Int, _ scope: NSRange?) async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered()
    }
  }
  func release(_ result: Bool) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

@MainActor final class AdmissionInlineRetry: SearchAdmissionRetryScheduler {
  final class Token: SearchAdmissionRetryToken {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  let token = Token()
  private(set) var schedules = 0
  func schedule(_ action: @escaping @MainActor () -> Void) -> any SearchAdmissionRetryToken {
    schedules += 1
    action()
    return token
  }
}

final class AdmissionReentrantAccounting: SearchAdmissionAccounting {
  let activeLimit: UInt64 = 20
  let retainedLimit: UInt64 = 20
  let resident: UInt64 = 2
  var onCharge: (@MainActor () -> Void)?
  func charge(for descriptor: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge {
    let action = onCharge
    onCharge = nil
    MainActor.assumeIsolated { action?() }
    return .init(active: 4, retained: 3)
  }
}
