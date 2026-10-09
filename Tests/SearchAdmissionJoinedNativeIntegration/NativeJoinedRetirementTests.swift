import AppKit
import CoreFoundation
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// A modalPanel Timer target/action observes genuine provisional destruction
/// synchronously, then queues a real terminal caller for after outer return.
@MainActor final class NativeJoinedRetirementTests: XCTestCase {
  private enum FixtureFailure: Error { case missingEvent, missingProvisionalContext }

  func testQueuedJoinedRequestObservesRetirementAfterDestructorReturns() async throws {
    try await checkRetirement(.joined)
  }

  func testQueuedLegacyRequestPreservesOriginalReceiptAfterDestructorReturns() async throws {
    try await checkRetirement(.legacy)
  }

  private func checkRetirement(_ kind: NativeRetirementNestedKind) async throws {
    let state = NativeRetirementState(kind: kind)
    let owner = try SearchAdmissionController<NativeRetirementContext>(
      driver: state.driver, accounting: AdmissionTestAccounting(), retry: state.retry,
      prepare: {
        await state.preparationEntered()
        let valid = await SearchAdmissionPreparation.validate(
          text: $0, estimate: $1, captured: $2, scope: $3)
        await state.preparationReturned()
        return valid
      }, observe: { state.workerReturned($0) })
    state.owner = owner
    // Rescue is registered before application setup, configuration, submission,
    // suspension or native action. It does not trust a joined return for drain.
    addTeardownBlock {
      let cleanup = await state.rescue()
      XCTAssertEqual(cleanup.outstandingRequests, 0)
      XCTAssertEqual(cleanup.preparationEntries, cleanup.preparationReturns)
      XCTAssertEqual(cleanup.unexpectedWorkerReturns, 0)
      XCTAssertEqual(cleanup.callerReturns, cleanup.registeredCallers)
      XCTAssertEqual(cleanup.driver.inFlightScopes, 0)
      XCTAssertEqual(cleanup.driver.scopeEntriesAfterSeal, 0)
      XCTAssertTrue(cleanup.registration.sealed)
      XCTAssertEqual(cleanup.registration.registered, cleanup.registration.joined)
      XCTAssertEqual(cleanup.registration.registrationsAfterSeal, 0)
      XCTAssertFalse(cleanup.nativeLoopRunning)
      XCTAssertFalse(cleanup.actionsEnabled)
    }

    let app = NSApplication.shared
    _ = app.setActivationPolicy(.prohibited)
    XCTAssertEqual(app.activationPolicy(), .prohibited)
    XCTAssertFalse(app.windows.contains { $0.isVisible })

    let waiting = expectation(description: "actual original sole wait installed")
    let worker = expectation(description: "actual request helper returned")
    let pending = expectation(description: "actual pending inspection retains provisional Context")
    state.onWorkerReturn = { worker.fulfill() }
    state.retry.onSchedule = {
      state.record("pending-inspection")
      pending.fulfill()
    }
    await state.driver.configureJoin(state.parent)
    await state.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await state.driver.backing.setSettlement(.settled(admissionClosed: false))
    let witness = try submitContext(state)
    try await requireEvents([waiting])
    // The real success reaches provisional storage, but its actual next
    // inspection must stay pending: no result lease or delivery is published.
    await state.driver.backing.setSettlement(.pending)
    try await state.driver.backing.completeSuccess()
    try await requireEvents([worker, pending])
    state.onWorkerReturn = nil
    state.retry.onSchedule = nil
    XCTAssertEqual(state.captureReturns, 1)
    XCTAssertEqual(state.preparationEntries, 1)
    XCTAssertEqual(state.preparationReturns, 1)
    XCTAssertEqual(state.workerReturnIDs, [try XCTUnwrap(state.job)])
    XCTAssertEqual(state.deliveries, 0)
    XCTAssertEqual(state.retry.tokens.count, 1)
    XCTAssertNotNil(state.retry.tokens.first?.action)
    XCTAssertNotNil(witness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 3)
    XCTAssertEqual(owner.accountingSnapshot.reservationCount, 1)
    XCTAssertEqual(owner.accountingSnapshot.leaseCount, 0)
    XCTAssertEqual(state.destructorEntries, 0)
    guard witness.value != nil else { throw FixtureFailure.missingProvisionalContext }

    await state.driver.backing.setSettlement(.settled(admissionClosed: true))
    let outerReturned = expectation(description: "outer real joined observation returned")
    let nestedReturned = expectation(description: "queued real terminal caller returned")
    state.onNestedReturn = { nestedReturned.fulfill() }
    state.destructorArmed = true
    let closing = Task {
      state.record("outer-request")
      let result = await owner.shutdownJoined()
      state.outerResult = result
      state.record("outer-return")
      outerReturned.fulfill()
    }
    state.track(closing)
    try await requireEvents([outerReturned])
    await closing.value
    // Registration happened synchronously while destruction was live. Join
    // that retained task and its actual API-return event after outer return.
    let nestedTask = try XCTUnwrap(state.nestedTask)
    await nestedTask.value
    try await requireEvents([nestedReturned])
    state.onNestedReturn = nil

    XCTAssertEqual(state.destructorEntries, 1)
    XCTAssertEqual(state.destructorReturns, 1)
    XCTAssertFalse(state.destructorLive)
    XCTAssertEqual(state.nativeActions, 1)
    XCTAssertEqual(state.nestedRegistrations, 1)
    XCTAssertEqual(state.nestedReturns, 1)
    XCTAssertEqual(state.emergencyStops, 0)
    XCTAssertEqual(state.traceOverflow, 0)
    XCTAssertNil(witness.value)
    XCTAssertEqual(state.deliveries, 0)
    XCTAssertEqual(
      state.trace,
      [
        "capture-return", "worker-return", "pending-inspection", "outer-request",
        "deinit-enter", "native-action", "live-ledger", "nested-task-registered",
        "deinit-return", "outer-return", "nested-request", "nested-return",
      ])
    XCTAssertNil(state.retry.tokens.first?.action)

    // This immutable snapshot was read by the synchronous native action while
    // the genuine destructor/clear helper was live, before credit retirement.
    let liveLedger = try XCTUnwrap(state.liveLedger)
    XCTAssertEqual(liveLedger.active, 6)
    XCTAssertEqual(liveLedger.reservedRetained, 3)
    XCTAssertEqual(liveLedger.reservationCount, 1)
    XCTAssertEqual(liveLedger.retained, 0)
    XCTAssertEqual(liveLedger.leaseCount, 0)
    switch kind {
    case .joined:
      let nested = try XCTUnwrap(state.nestedJoined)
      XCTAssertEqual(nested.parent, state.parent)
      XCTAssertEqual(nested.driverSettlement, .settled(admissionClosed: true))
      XCTAssertEqual(nested.retainedActiveJobs, 0)
      XCTAssertEqual(nested.retainedLeases, 0)
      XCTAssertEqual(nested.activeCharge, 2)
      XCTAssertEqual(nested.retainedCharge, 0)
      XCTAssertEqual(nested.reservedRetainedCharge, 0)
    case .legacy:
      let nested = try XCTUnwrap(state.nestedLegacy)
      guard case .completed(let original) = state.parent else {
        return XCTFail("fixture parent must be the original admitted completion")
      }
      XCTAssertEqual(nested.driver, original.shutdown)
      XCTAssertEqual(nested.driverSettlement, .settled(admissionClosed: true))
      XCTAssertEqual(nested.retainedActiveJobs, 0)
      XCTAssertEqual(nested.retainedLeases, 0)
    }

    let outer = try observed(try XCTUnwrap(state.outerResult))
    assertRetired(outer, parent: state.parent)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 0)
    XCTAssertEqual(owner.accountingSnapshot.reservationCount, 0)
    let later = try observed(await owner.shutdownJoined())
    assertRetired(later, parent: state.parent)
    let driver = await state.driver.snapshot()
    XCTAssertEqual(driver.joinCalls, 1)
    XCTAssertEqual(driver.legacyCalls, 0)
    XCTAssertEqual(driver.legacyReceipts.count, 0)
    XCTAssertEqual(driver.submittedHandles.count, 1)
    XCTAssertEqual(driver.waitedHandles, driver.submittedHandles)
    XCTAssertEqual(driver.returnedWaitHandles, driver.submittedHandles)
    XCTAssertEqual(driver.cancelledHandles, driver.submittedHandles)
    XCTAssertEqual(driver.returnedCancelHandles, driver.submittedHandles)
    XCTAssertEqual(driver.lastJoinHandle, driver.submittedHandles.first)
    XCTAssertEqual(driver.discardCalls, 0)
    XCTAssertFalse(app.windows.contains { $0.isVisible })
    let cleanup = await state.rescue()
    XCTAssertEqual(cleanup.callerReturns, 2)
    XCTAssertEqual(cleanup.registeredCallers, 2)
    XCTAssertEqual(cleanup.outstandingRequests, 0)
    XCTAssertEqual(cleanup.preparationEntries, 1)
    XCTAssertEqual(cleanup.preparationReturns, 1)
    XCTAssertEqual(cleanup.registration.registered, 0)
    XCTAssertEqual(cleanup.registration.joined, 0)
    XCTAssertEqual(cleanup.registration.registrationsAfterSeal, 0)
    XCTAssertEqual(cleanup.driver.inFlightScopes, 0)
    XCTAssertEqual(cleanup.driver.scopeEntriesAfterSeal, 0)
  }

  /// This helper's external and capture aliases genuinely leave before async
  /// setup can resume. Only weak evidence escapes; the real provisional tuple
  /// is responsible for the later destructor invocation.
  private func submitContext(_ state: NativeRetirementState) throws
    -> AdmissionWeakBox<NativeRetirementContext>
  {
    let context = NativeRetirementContext { state.contextDestroyed() }
    let witness = AdmissionWeakBox(context)
    let id = try state.owner.submit(
      consumer: state.owner.register(), descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [context] in
        state.captureReturned()
        return .init(text: "x", inputUTF16: 1, context: context)
      },
      completion: { _ in
        state.deliveries += 1
        XCTFail("provisional/closed request must not publish a completion")
      })
    state.job = id
    return witness
  }

  private func requireEvents(
    _ events: [XCTestExpectation], file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let result = await XCTWaiter.fulfillment(of: events, timeout: 8)
    guard result == .completed else {
      XCTFail(
        "required real native fixture event was not reached: \(result)", file: file, line: line)
      throw FixtureFailure.missingEvent
    }
  }

  private func observed(_ result: SearchAdmissionJoinedShutdownResult) throws
    -> SearchAdmissionJoinedShutdownObservation
  {
    guard case .observed(let value) = result else {
      XCTFail("expected real joined observation, got \(result)")
      throw FixtureFailure.missingEvent
    }
    return value
  }

  private func assertRetired(
    _ value: SearchAdmissionJoinedShutdownObservation, parent: SearchParentJoinedShutdownResult
  ) {
    XCTAssertEqual(value.parent, parent)
    XCTAssertEqual(value.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(value.retainedActiveJobs, 0)
    XCTAssertEqual(value.retainedLeases, 0)
    XCTAssertEqual(value.activeCharge, 2)
    XCTAssertEqual(value.retainedCharge, 0)
    XCTAssertEqual(value.reservedRetainedCharge, 0)
  }
}

private enum NativeRetirementNestedKind { case joined, legacy }

/// The callback is invoked solely by ARC's genuine destruction of this Context.
/// Actual controller payload destruction is MainActor-owned in these fixtures.
private final class NativeRetirementContext {
  private let destroyed: @MainActor () -> Void
  init(destroyed: @escaping @MainActor () -> Void) { self.destroyed = destroyed }
  deinit { MainActor.assumeIsolated { self.destroyed() } }
}

@MainActor private final class NativeRetirementAction: NSObject {
  private let action: @MainActor () -> Void
  init(_ action: @escaping @MainActor () -> Void) { self.action = action }
  @objc func invoke(_ sender: Any?) { action() }
}

@MainActor private final class NativeRetirementLoop {
  private(set) var running = false
  private(set) var liveLedgerStopped = false
  private var event: Timer?
  private var emergency: Timer?

  func stopAfterLiveLedgerRegistration() {
    guard running else { return }
    liveLedgerStopped = true
    CFRunLoopStop(CFRunLoopGetMain())
  }

  func rescue() {
    event?.invalidate()
    emergency?.invalidate()
    if running { CFRunLoopStop(CFRunLoopGetMain()) }
  }

  func run(
    _ action: @escaping @MainActor () -> Void,
    emergencyFailure: @escaping @MainActor () -> Void
  ) {
    precondition(!running)
    running = true
    let target = NativeRetirementAction(action)
    let event = Timer(fire: Date(), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.running == true else { return }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(NativeRetirementAction.invoke(_:)), to: target, from: nil))
      }
    }
    let emergency = Timer(fire: Date().addingTimeInterval(5), interval: 0, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.running == true else { return }
        emergencyFailure()
        CFRunLoopStop(CFRunLoopGetMain())
      }
    }
    self.event = event
    self.emergency = emergency
    RunLoop.main.add(event, forMode: .modalPanel)
    RunLoop.main.add(emergency, forMode: .modalPanel)
    defer {
      running = false
      event.invalidate()
      emergency.invalidate()
      self.event = nil
      self.emergency = nil
    }
    let mode = CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString)
    let result = CFRunLoopRunInMode(mode, 6, false)
    XCTAssertEqual(result, CFRunLoopRunResult.stopped)
    XCTAssertTrue(
      liveLedgerStopped, "live ledger observation and task registration must stop success")
  }
}

private struct NativeRetirementCleanup: Sendable {
  let outstandingRequests: Int
  let preparationEntries: Int
  let preparationReturns: Int
  let unexpectedWorkerReturns: Int
  let callerReturns: Int
  let registeredCallers: Int
  let driver: JoinedAdmissionDriverSnapshot
  let registration: JoinedAdmissionRescueRegistrationSnapshot
  let nativeLoopRunning: Bool
  let actionsEnabled: Bool
}

@MainActor private final class NativeRetirementState {
  let kind: NativeRetirementNestedKind
  let driver = JoinedAdmissionDriver()
  let retry = AdmissionManualRetry()
  let parent = JoinedAdmissionValues.completed()
  var owner: SearchAdmissionController<NativeRetirementContext>!
  var job: SearchJobID?
  var destructorArmed = false
  private(set) var destructorLive = false
  private(set) var destructorEntries = 0
  private(set) var destructorReturns = 0
  private(set) var nativeActions = 0
  private(set) var nestedRegistrations = 0
  private(set) var nestedReturns = 0
  private(set) var emergencyStops = 0
  private(set) var captureReturns = 0
  private(set) var preparationEntries = 0
  private(set) var preparationReturns = 0
  private(set) var workerReturnIDs: [SearchJobID] = []
  private var outstandingRequests = 0
  private var unexpectedWorkerReturns = 0
  private var workReturns: [CheckedContinuation<Void, Never>] = []
  var onWorkerReturn: (() -> Void)?
  var onNestedReturn: (() -> Void)?
  var deliveries = 0
  var outerResult: SearchAdmissionJoinedShutdownResult?
  private(set) var nestedJoined: SearchAdmissionJoinedShutdownObservation?
  private(set) var nestedLegacy: SearchAdmissionShutdown?
  private(set) var liveLedger: SearchAdmissionLedgerSnapshot?
  private(set) var nestedTask: Task<Void, Never>?
  private(set) var trace: [String] = []
  private(set) var traceOverflow = 0
  private var actionsEnabled = true
  private var activeLoop: NativeRetirementLoop?
  private var callers: [@MainActor () async -> Void] = []
  private var cleanupTask: Task<NativeRetirementCleanup, Never>?

  init(kind: NativeRetirementNestedKind) { self.kind = kind }

  func record(_ event: String) {
    if trace.count < 32 { trace.append(event) } else { traceOverflow += 1 }
  }

  func captureReturned() {
    captureReturns += 1
    outstandingRequests += 1
    record("capture-return")
  }

  func preparationEntered() { preparationEntries += 1 }
  func preparationReturned() { preparationReturns += 1 }

  func workerReturned(_ event: SearchAdmissionEvent) {
    switch event {
    case .workerExited(let id): workerReturnIDs.append(id)
    }
    if outstandingRequests > 0 { outstandingRequests -= 1 } else { unexpectedWorkerReturns += 1 }
    record("worker-return")
    onWorkerReturn?()
    if workDrained {
      let held = workReturns
      workReturns.removeAll()
      for waiter in held { waiter.resume() }
    }
  }

  private var workDrained: Bool {
    outstandingRequests == 0 && preparationEntries == preparationReturns
  }

  private func drainWork() async {
    guard !workDrained else { return }
    await withCheckedContinuation { workReturns.append($0) }
  }

  func track<Value>(_ task: Task<Value, Never>) { callers.append { _ = await task.value } }

  func contextDestroyed() {
    guard destructorArmed else { return }
    destructorEntries += 1
    destructorLive = true
    record("deinit-enter")
    defer {
      destructorLive = false
      destructorReturns += 1
      record("deinit-return")
    }
    XCTAssertTrue(Thread.isMainThread)
    XCTAssertEqual(destructorEntries, 1)
    let loop = NativeRetirementLoop()
    activeLoop = loop
    defer { activeLoop = nil }
    loop.run(
      { [self] in
        guard self.actionsEnabled else { return }
        self.nativeActions += 1
        self.record("native-action")
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(self.destructorLive)
        XCTAssertEqual(self.destructorReturns, 0)
        XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
        self.liveLedger = self.owner.accountingSnapshot
        XCTAssertEqual(self.liveLedger?.active, 6)
        XCTAssertEqual(self.liveLedger?.reservedRetained, 3)
        XCTAssertEqual(self.liveLedger?.reservationCount, 1)
        XCTAssertEqual(self.liveLedger?.retained, 0)
        XCTAssertEqual(self.liveLedger?.leaseCount, 0)
        self.record("live-ledger")
        let nested = Task { [self] in
          self.record("nested-request")
          XCTAssertFalse(self.destructorLive)
          XCTAssertEqual(self.destructorReturns, 1)
          XCTAssertNotNil(self.outerResult)
          switch self.kind {
          case .joined:
            let result = await self.owner.shutdownJoined()
            self.nestedReturns += 1
            self.record("nested-return")
            self.onNestedReturn?()
            guard case .observed(let value) = result else {
              XCTFail("queued caller must receive a real settled observation: \(result)")
              return
            }
            self.nestedJoined = value
            XCTAssertEqual(value.parent, self.parent)
            XCTAssertEqual(value.driverSettlement, .settled(admissionClosed: true))
            XCTAssertEqual(value.retainedActiveJobs, 0)
            XCTAssertEqual(value.activeCharge, 2)
            XCTAssertEqual(value.reservedRetainedCharge, 0)
          case .legacy:
            let value = await self.owner.shutdown()
            self.nestedReturns += 1
            self.record("nested-return")
            self.onNestedReturn?()
            self.nestedLegacy = value
            guard case .completed(let original) = self.parent else {
              XCTFail("fixture parent completion")
              return
            }
            XCTAssertEqual(value.driver, original.shutdown)
            XCTAssertEqual(value.driverSettlement, .settled(admissionClosed: true))
            XCTAssertEqual(value.retainedActiveJobs, 0)
          }
          // These checks follow an actual API return, outside live destruction.
          XCTAssertFalse(self.destructorLive)
          XCTAssertEqual(self.destructorReturns, 1)
          XCTAssertEqual(self.owner.accountingSnapshot.active, 2)
          XCTAssertEqual(self.owner.accountingSnapshot.reservedRetained, 0)
          XCTAssertEqual(self.owner.accountingSnapshot.reservationCount, 0)
          XCTAssertEqual(self.owner.accountingSnapshot.leaseCount, 0)
        }
        self.track(nested)
        self.nestedTask = nested
        self.nestedRegistrations += 1
        self.record("nested-task-registered")
        // Success is this synchronous public-ledger boundary plus registration;
        // no queued async return is awaited or inferred inside the modal loop.
        loop.stopAfterLiveLedgerRegistration()
      },
      emergencyFailure: { [self] in
        self.emergencyStops += 1
        XCTFail("destructor native loop did not reach the live ledger/action boundary")
      })
    // The Timer observed the ledger and registered a queued task. This actual
    // destructor/clearing scope remains live until its synchronous return.
    XCTAssertTrue(destructorLive)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 3)
    XCTAssertEqual(owner.accountingSnapshot.reservationCount, 1)
    XCTAssertEqual(owner.accountingSnapshot.leaseCount, 0)
  }

  func rescue() async -> NativeRetirementCleanup {
    if cleanupTask == nil { cleanupTask = Task { await self.performRescue() } }
    return await cleanupTask!.value
  }

  private func performRescue() async -> NativeRetirementCleanup {
    // Disarm before releasing any source aliases. Disable/stop native actions
    // before snapshotting callers so no late Timer can create an unjoined Task.
    destructorArmed = false
    actionsEnabled = false
    activeLoop?.rescue()
    onWorkerReturn = nil
    onNestedReturn = nil
    retry.onSchedule = nil
    if let job { owner.cancel(job) }
    await driver.beginRescue()
    await drainWork()
    var returned = 0
    for caller in callers {
      await caller()
      returned += 1
    }
    await driver.drainForwardedScopes()
    let registration = await driver.sealAndJoinRescueWaits()
    let driverSnapshot = await driver.snapshot()
    // The controller's observer retains this state. Remove the reverse owner
    // edge only after genuine work/caller drain, with destruction disarmed.
    owner = nil
    return .init(
      outstandingRequests: outstandingRequests,
      preparationEntries: preparationEntries, preparationReturns: preparationReturns,
      unexpectedWorkerReturns: unexpectedWorkerReturns, callerReturns: returned,
      registeredCallers: callers.count,
      driver: driverSnapshot, registration: registration,
      nativeLoopRunning: activeLoop?.running ?? false, actionsEnabled: actionsEnabled)
  }
}
