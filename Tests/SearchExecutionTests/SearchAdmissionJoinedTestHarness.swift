import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// A sticky gate: rescue before entry is as effective as rescue after entry.
actor JoinedAdmissionGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var entered: (@Sendable () -> Void)?

  init(entered: (@Sendable () -> Void)? = nil) { self.entered = entered }

  func wait() async {
    guard !opened else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
      let callback = entered
      entered = nil
      callback?()
    }
  }

  func release() {
    opened = true
    entered = nil
    let held = waiters
    waiters.removeAll()
    for waiter in held { waiter.resume() }
  }
}

struct JoinedAdmissionDriverSnapshot: Sendable {
  let joinCalls: Int
  let legacyCalls: Int
  let queryCalls: Int
  let queryReturns: Int
  let discardCalls: Int
  let lastJoinHandle: SearchParentWireHandle?
  let submittedHandles: [SearchParentWireHandle]
  let waitedHandles: [SearchParentWireHandle]
  let cancelledHandles: [SearchParentWireHandle]
  let returnedWaitHandles: [SearchParentWireHandle]
  let returnedCancelHandles: [SearchParentWireHandle]
  let legacyReceipts: [SearchParentWireShutdown]
  let joinEntryCancellation: [Bool]
  let joinReturnCancellation: [Bool]
  let joinCancellationCallbacks: Int
  let inFlightScopes: Int
  let scopeEntriesAfterSeal: Int
  let events: [String]
}

/// Only joining and advisory-query controls are new. Request receipt ownership
/// remains in the unchanged backend, including its independently held cancel.
actor JoinedAdmissionDriver: SearchParentWireJoining {
  let backing: AdmissionScriptedDriver
  private var joinResult = JoinedAdmissionValues.completed()
  private var joinGate: JoinedAdmissionGate?
  private var joinEntered: (@Sendable () -> Void)?
  private var nextQueryGate: JoinedAdmissionGate?
  private var queryOverride: Result<SearchParentWireSettlement, SearchParentWireDriverError>?
  private var queryReturned: (@Sendable () -> Void)?
  private var cancelReturned: (@Sendable () -> Void)?
  private var joinCalls = 0
  private var legacyCalls = 0
  private var queryCalls = 0
  private var queryReturns = 0
  private var discardCalls = 0
  private var lastJoinHandle: SearchParentWireHandle?
  private var submittedHandles: [SearchParentWireHandle] = []
  private var waitedHandles: [SearchParentWireHandle] = []
  private var cancelledHandles: [SearchParentWireHandle] = []
  private var returnedWaitHandles: [SearchParentWireHandle] = []
  private var returnedCancelHandles: [SearchParentWireHandle] = []
  private var legacyReceipts: [SearchParentWireShutdown] = []
  private let cancellationProbe = JoinedAdmissionCancellationProbe()
  private var inFlightScopes = 0
  private var scopesSealed = false
  private var scopeEntriesAfterSeal = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var events: [String] = []
  private var ownedGates: [JoinedAdmissionGate] = []
  private var queryGates: [JoinedAdmissionGate] = []
  private let cleanupWaits = JoinedAdmissionCleanupWaits()

  init(backing: AdmissionScriptedDriver = AdmissionScriptedDriver()) { self.backing = backing }

  func configureJoin(
    _ result: SearchParentJoinedShutdownResult, hold: Bool = false,
    onEntered: (@Sendable () -> Void)? = nil
  ) {
    joinResult = result
    joinEntered = onEntered
    if hold {
      let gate = JoinedAdmissionGate()
      joinGate = gate
      ownedGates.append(gate)
    }
  }

  func releaseJoin() async { await joinGate?.release() }

  func configureQueryHold(onEntered: (@Sendable () -> Void)? = nil) {
    let gate = JoinedAdmissionGate(entered: onEntered)
    nextQueryGate = gate
    ownedGates.append(gate)
    queryGates.append(gate)
  }

  func releaseQuery() async {
    // Includes a consumed gate, so rescue does not depend on a current slot.
    for gate in queryGates { await gate.release() }
  }

  /// Used only for explicit current-observation branches; request methods never
  /// override handles, outcomes, errors, consumption or cancellation.
  func configureCurrentQuery(
    _ result: Result<SearchParentWireSettlement, SearchParentWireDriverError>?
  ) { queryOverride = result }

  func onNextQueryReturn(_ callback: @escaping @Sendable () -> Void) {
    queryReturned = callback
  }

  func onNextCancelReturn(_ callback: @escaping @Sendable () -> Void) {
    cancelReturned = callback
  }

  func settlement(after handle: SearchParentWireHandle?) async throws -> SearchParentWireSettlement
  {
    enterScope()
    defer { leaveScope() }
    queryCalls += 1
    record("query.enter")
    let gate = nextQueryGate
    nextQueryGate = nil
    // Freeze this query's current observation before its held return. A later
    // fixture configuration cannot rewrite a pre-close observation in flight.
    let override = queryOverride
    let forwarded: Result<SearchParentWireSettlement, Error>
    do { forwarded = .success(try await backing.settlement(after: handle)) } catch {
      forwarded = .failure(error)
    }
    await gate?.wait()
    queryReturns += 1
    record("query.return")
    let callback = queryReturned
    queryReturned = nil
    callback?()
    let value = try forwarded.get()
    if let override { return try override.get() }
    return value
  }

  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle {
    enterScope()
    defer { leaveScope() }
    record("submit.enter")
    do {
      let handle = try await backing.submit(job)
      submittedHandles.append(handle)
      record("submit.return")
      return handle
    } catch {
      record("submit.throw")
      throw error
    }
  }

  func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome {
    enterScope()
    waitedHandles.append(handle)
    record("wait.enter")
    defer {
      returnedWaitHandles.append(handle)
      record("wait.return")
      leaveScope()
    }
    return try await backing.wait(for: handle)
  }

  func cancel(_ handle: SearchParentWireHandle) async throws {
    enterScope()
    cancelledHandles.append(handle)
    record("cancel.enter")
    defer {
      record("cancel.return")
      returnedCancelHandles.append(handle)
      let callback = cancelReturned
      cancelReturned = nil
      callback?()
      leaveScope()
    }
    try await backing.cancel(handle)
  }

  func discard(_ handle: SearchParentWireHandle) async throws {
    enterScope()
    defer { leaveScope() }
    discardCalls += 1
    record("discard.enter")
    try await backing.discard(handle)
  }

  func shutdown() async -> SearchParentWireShutdown {
    enterScope()
    defer { leaveScope() }
    legacyCalls += 1
    record("legacy.enter")
    let receipt = await backing.shutdown()
    legacyReceipts.append(receipt)
    record("legacy.return")
    return receipt
  }

  func shutdownJoined(after handle: SearchParentWireHandle?) async
    -> SearchParentJoinedShutdownResult
  {
    enterScope()
    defer { leaveScope() }
    joinCalls += 1
    lastJoinHandle = handle
    record("join.enter")
    let result = joinResult
    let callback = joinEntered
    joinEntered = nil
    callback?()
    let probe = cancellationProbe
    probe.entered(cancelled: Task.isCancelled)
    return await withTaskCancellationHandler {
      await joinGate?.wait()
      probe.returned(cancelled: Task.isCancelled)
      record("join.return")
      return result
    } onCancel: {
      probe.cancelled()
    }
  }

  func snapshot() -> JoinedAdmissionDriverSnapshot {
    let cancellation = cancellationProbe.snapshot()
    return .init(
      joinCalls: joinCalls, legacyCalls: legacyCalls, queryCalls: queryCalls,
      queryReturns: queryReturns, discardCalls: discardCalls, lastJoinHandle: lastJoinHandle,
      submittedHandles: submittedHandles, waitedHandles: waitedHandles,
      cancelledHandles: cancelledHandles, returnedWaitHandles: returnedWaitHandles,
      returnedCancelHandles: returnedCancelHandles, legacyReceipts: legacyReceipts,
      joinEntryCancellation: cancellation.entries, joinReturnCancellation: cancellation.returns,
      joinCancellationCallbacks: cancellation.callbacks, inFlightScopes: inFlightScopes,
      scopeEntriesAfterSeal: scopeEntriesAfterSeal, events: events)
  }

  func beginRescue() async {
    joinEntered = nil
    queryReturned = nil
    cancelReturned = nil
    nextQueryGate = nil
    queryOverride = .success(.settled(admissionClosed: true))
    // Late wait installation after a failed setup also resolves. This callback
    // resumes the real backend waiter rather than manufacturing an outcome here.
    let backing = backing
    let cleanupWaits = cleanupWaits
    await backing.configureAccepted(onWait: { cleanupWaits.resolve(backing) })
    await backing.configureShutdown()
    for gate in ownedGates { await gate.release() }
    await backing.releaseSubmit()
    await backing.releaseCancel()
    await backing.releaseShutdown()
    await backing.completeFailure()
    await backing.setSettlement(.settled(admissionClosed: true))
  }

  /// Called only after every captured request's genuine outer worker return.
  /// Successful synthetic submissions must also have real wait/cancel returns;
  /// an actor idle snapshot alone is not a future-registration boundary.
  func drainForwardedScopes() async {
    guard !forwardedScopesDrained else { return }
    await withCheckedContinuation { drainWaiters.append($0) }
  }

  func sealAndJoinRescueWaits() async -> JoinedAdmissionRescueRegistrationSnapshot {
    await drainForwardedScopes()
    // Worker/request obligations have genuinely returned. Disable the real
    // backend callback before sealing its synchronous registration owner.
    await backing.configureAccepted()
    scopesSealed = true
    return await cleanupWaits.sealAndJoin()
  }

  private var forwardedScopesDrained: Bool {
    inFlightScopes == 0
      && submittedHandles.allSatisfy {
        returnedWaitHandles.contains($0) && returnedCancelHandles.contains($0)
      }
  }

  private func enterScope() {
    if scopesSealed { scopeEntriesAfterSeal += 1 }
    inFlightScopes += 1
  }

  private func leaveScope() {
    precondition(inFlightScopes > 0)
    inFlightScopes -= 1
    guard forwardedScopesDrained else { return }
    let held = drainWaiters
    drainWaiters.removeAll()
    for waiter in held { waiter.resume() }
  }

  private func record(_ event: String) {
    // A mutant that spins remains bounded in memory and exposes a saturated trace.
    if events.count < 64 { events.append(event) }
  }
}

private final class JoinedAdmissionCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [Bool] = []
  private var returns: [Bool] = []
  private var callbacks = 0

  func entered(cancelled: Bool) {
    lock.lock()
    entries.append(cancelled)
    lock.unlock()
  }

  func returned(cancelled: Bool) {
    lock.lock()
    returns.append(cancelled)
    lock.unlock()
  }

  func cancelled() {
    lock.lock()
    callbacks += 1
    lock.unlock()
  }

  func snapshot() -> (entries: [Bool], returns: [Bool], callbacks: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (entries, returns, callbacks)
  }
}

struct JoinedAdmissionRescueRegistrationSnapshot: Sendable {
  let sealed: Bool
  let registered: Int
  let joined: Int
  let registrationsAfterSeal: Int
}

/// Callback-created rescue work is retained synchronously and joined, including
/// waiters installed after rescue began in a failing implementation.
private final class JoinedAdmissionCleanupWaits: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []
  private var sealed = false
  private var registered = 0
  private var joined = 0
  private var registrationsAfterSeal = 0

  func resolve(_ backing: AdmissionScriptedDriver) {
    lock.lock()
    guard !sealed else {
      registrationsAfterSeal += 1
      lock.unlock()
      return
    }
    registered += 1
    tasks.append(Task { await backing.completeFailure() })
    lock.unlock()
  }

  private func seal() -> [Task<Void, Never>] {
    lock.lock()
    defer { lock.unlock() }
    sealed = true
    let held = tasks
    tasks.removeAll()
    return held
  }

  private func recordJoined(_ count: Int) -> JoinedAdmissionRescueRegistrationSnapshot {
    lock.lock()
    defer { lock.unlock() }
    joined += count
    return .init(
      sealed: sealed, registered: registered, joined: joined,
      registrationsAfterSeal: registrationsAfterSeal)
  }

  func sealAndJoin() async -> JoinedAdmissionRescueRegistrationSnapshot {
    let held = seal()
    for task in held { await task.value }
    return recordJoined(held.count)
  }
}

enum JoinedAdmissionValues {
  static let generation = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

  static func completed(
    ownership: SearchParentJoinedOwnership = .admitted,
    lane: SearchParentJoinedLaneStop = .acknowledged,
    settled: Bool = true,
    child: SearchChildShutdown = .init(cleanup: .noChild, channelsClosed: true)
  ) -> SearchParentJoinedShutdownResult {
    .completed(
      .init(
        shutdown: .init(
          child: child, parentLaneSettled: settled, retainedParentLanes: settled ? 0 : 1),
        ownership: ownership, laneStop: lane))
  }

  static func descriptor() throws -> SearchAdmissionDescriptor {
    try .init(
      query: .init(pattern: "x", mode: .literal), operation: .find,
      estimatedInputUTF16: 1, scope: nil,
      limits: .init(maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 8, cooperativeMilliseconds: 0))
  }
}

final class JoinedAdmissionContext {}

struct JoinedAdmissionScopeSnapshot: Sendable {
  let capturedRequests: Int
  let workerReturns: Int
  let preparationEntries: Int
  let preparationReturns: Int
  let outstandingRequests: Int
  let unexpectedWorkerReturns: Int
}

/// Successful fixture captures create a real expected worker scope. Only the
/// unchanged controller's genuine workerExited callback satisfies its return.
@MainActor private final class JoinedAdmissionScopes {
  private var capturedRequests = 0
  private var workerReturns = 0
  private var preparationEntries = 0
  private var preparationReturns = 0
  private var outstandingRequests = 0
  private var unexpectedWorkerReturns = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  func captureReturned() {
    capturedRequests += 1
    outstandingRequests += 1
  }

  func preparationEntered() { preparationEntries += 1 }
  func preparationReturned() { preparationReturns += 1 }

  func workerReturned() {
    workerReturns += 1
    if outstandingRequests > 0 { outstandingRequests -= 1 } else { unexpectedWorkerReturns += 1 }
    guard drained else { return }
    let held = drainWaiters
    drainWaiters.removeAll()
    for waiter in held { waiter.resume() }
  }

  private var drained: Bool {
    outstandingRequests == 0 && preparationEntries == preparationReturns
  }

  func drain() async {
    guard !drained else { return }
    await withCheckedContinuation { drainWaiters.append($0) }
  }

  func snapshot() -> JoinedAdmissionScopeSnapshot {
    .init(
      capturedRequests: capturedRequests, workerReturns: workerReturns,
      preparationEntries: preparationEntries, preparationReturns: preparationReturns,
      outstandingRequests: outstandingRequests, unexpectedWorkerReturns: unexpectedWorkerReturns)
  }
}

struct JoinedAdmissionCleanupSnapshot: Sendable {
  let scopes: JoinedAdmissionScopeSnapshot
  let driver: JoinedAdmissionDriverSnapshot
  let registration: JoinedAdmissionRescueRegistrationSnapshot
  let trackedCallerReturns: Int
}

@MainActor final class JoinedAdmissionFixture {
  let driver: JoinedAdmissionDriver
  let retry = AdmissionManualRetry()
  let owner: SearchAdmissionController<JoinedAdmissionContext>
  var gates: [JoinedAdmissionGate] = []
  private let scopes: JoinedAdmissionScopes
  private var jobs: [SearchJobID] = []
  private var joins: [@MainActor () async -> Void] = []
  private var cleanupTask: Task<JoinedAdmissionCleanupSnapshot, Never>?

  init(
    driver: JoinedAdmissionDriver = JoinedAdmissionDriver(),
    prepare: @escaping SearchAdmissionPreparing = { _, _, _, _ in true },
    observe: (@MainActor (SearchAdmissionEvent) -> Void)? = nil
  ) throws {
    self.driver = driver
    let scopes = JoinedAdmissionScopes()
    self.scopes = scopes
    owner = try .init(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry,
      prepare: {
        await scopes.preparationEntered()
        let result = await prepare($0, $1, $2, $3)
        await scopes.preparationReturned()
        return result
      },
      observe: { event in
        scopes.workerReturned()
        observe?(event)
      })
  }

  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<JoinedAdmissionContext>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    let scopes = scopes
    let id = try owner.submit(
      consumer: consumer, descriptor: descriptor,
      capture: {
        let captured = try capture()
        scopes.captureReturned()
        return captured
      }, completion: completion)
    jobs.append(id)
    return id
  }

  func track<Value>(_ task: Task<Value, Never>) { joins.append { _ = await task.value } }

  func close(entered: XCTestExpectation? = nil) -> Task<SearchAdmissionJoinedShutdownResult, Never>
  {
    let owner = owner
    let task = Task {
      entered?.fulfill()
      return await owner.shutdownJoined()
    }
    track(task)
    return task
  }

  func rescue() async -> JoinedAdmissionCleanupSnapshot {
    if cleanupTask == nil { cleanupTask = Task { await self.performRescue() } }
    return await cleanupTask!.value
  }

  private func performRescue() async -> JoinedAdmissionCleanupSnapshot {
    retry.onSchedule = nil
    // Actual public cancellation fences all known queued captures before the
    // first cleanup suspension. It never impersonates a returned scope.
    for id in jobs { owner.cancel(id) }
    await driver.beginRescue()
    for gate in gates { await gate.release() }
    await scopes.drain()
    var callerReturns = 0
    for join in joins {
      await join()
      callerReturns += 1
    }
    await driver.drainForwardedScopes()
    let registration = await driver.sealAndJoinRescueWaits()
    return .init(
      scopes: scopes.snapshot(), driver: await driver.snapshot(), registration: registration,
      trackedCallerReturns: callerReturns)
  }
}
