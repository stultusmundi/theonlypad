import AppKit
import CoreFoundation
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Compiled only by the isolated macOS 26 native test host. No shown window,
/// posted input, helper process or production observation hook is involved.
@MainActor final class NativeJoinedAdmissionTests: XCTestCase {
  private enum FixtureFailure: Error { case missingEvent, missingObservation }

  func testJoinedObservationsReturnInsideBorrowWithResidualCredit() async throws {
    let f = try fixture()
    let waiting = expectation(description: "borrow fixture sole waiter installed")
    let delivered = expectation(description: "borrow fixture real lease delivered")
    f.onDelivery = { delivered.fulfill() }
    await f.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await f.driver.backing.setSettlement(.settled(admissionClosed: false))
    let weakContext = try f.submit()
    try await reached([waiting])
    await f.driver.backing.setSettlement(.settled(admissionClosed: false))
    try await f.driver.backing.completeSuccess()
    f.completedOutcomeIssued = true
    try await reached([delivered])
    f.onDelivery = nil
    let lease = try XCTUnwrap(f.lease)
    XCTAssertNotNil(weakContext.value)
    XCTAssertEqual(f.owner.accountingSnapshot.retained, 3)
    await f.driver.backing.setSettlement(.settled(admissionClosed: true))

    let returned = expectation(description: "Timer-owned outer borrow actually returned")
    // Cleanup already exists before scheduling the outer Timer. The outer
    // synchronous Timer stack permits ordinary queued MainActor jobs to run.
    f.postOuter {
      XCTAssertTrue(
        f.owner.withResult(lease) { context, source, _ in
          XCTAssertEqual(context.label, "synthetic")
          XCTAssertEqual(source, "x")
          f.borrowLive = true
          f.record("borrow.enter")
          defer { f.borrowLive = false }
          let loop = f.newLoop()
          loop.run {
            let slot = f.reserveTask()
            let task = Task { @MainActor in
              let first = await f.owner.shutdownJoined()
              f.borrowResults.append(first)
              f.checkBorrow(first, weakContext: weakContext, loop: loop)
              f.record("borrow.first.return")
              let second = await f.owner.shutdownJoined()
              f.borrowResults.append(second)
              f.checkBorrow(second, weakContext: weakContext, loop: loop)
              f.record("borrow.second.return")
              let legacy = await f.owner.shutdown()
              f.borrowLegacy = legacy
              XCTAssertTrue(f.borrowLive)
              XCTAssertTrue(loop.running)
              XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
              XCTAssertEqual(legacy.retainedLeases, 1)
              XCTAssertEqual(legacy.retainedActiveJobs, 0)
              XCTAssertEqual(legacy.driverSettlement, .settled(admissionClosed: true))
              if case .completed(let original) = f.parent {
                XCTAssertEqual(legacy.driver, original.shutdown)
              } else {
                XCTFail("fixture original completed parent required")
              }
              XCTAssertNotNil(weakContext.value)
              XCTAssertEqual(f.owner.accountingSnapshot.retained, 3)
              f.record("borrow.legacy.return")
              loop.stop(.borrowReturns)
            }
            slot.install(task)
          }
          XCTAssertEqual(f.borrowResults.count, 2)
          XCTAssertNotNil(f.borrowLegacy)
          XCTAssertNotNil(weakContext.value)
          XCTAssertEqual(f.owner.accountingSnapshot.retained, 3)
          XCTAssertFalse(f.owner.withResult(lease) { _, _, _ in XCTFail("invalidated lease") })
        })
      f.record("borrow.outer.return")
      XCTAssertNil(weakContext.value)
      XCTAssertEqual(f.owner.accountingSnapshot.retained, 0)
      returned.fulfill()
    }
    try await reached([returned])
    await f.joinRegisteredTasks()
    XCTAssertEqual(f.borrowResults.count, 2)
    if f.borrowResults.count == 2 { XCTAssertEqual(f.borrowResults[0], f.borrowResults[1]) }
    for result in f.borrowResults {
      let value = try observed(result)
      XCTAssertEqual(value.retainedLeases, 1)
      XCTAssertEqual(value.retainedCharge, 3)
    }
    let later = try observed(await f.owner.shutdownJoined())
    assertClosed(later, parent: f.parent)
    XCTAssertNil(weakContext.value)
    XCTAssertEqual(f.owner.accountingSnapshot.leaseCount, 0)
    XCTAssertEqual(f.owner.accountingSnapshot.retained, 0)
    XCTAssertEqual(
      f.trace.filter { $0.hasPrefix("borrow.") },
      [
        "borrow.enter", "borrow.first.return", "borrow.second.return",
        "borrow.legacy.return", "borrow.outer.return",
      ])
    let driver = await f.driver.snapshot()
    XCTAssertEqual(driver.joinCalls, 1)
    XCTAssertEqual(driver.legacyCalls, 0)
    XCTAssertEqual(driver.lastJoinHandle, driver.submittedHandles.first)
    XCTAssertEqual(driver.waitedHandles, driver.submittedHandles)
    XCTAssertEqual(driver.returnedWaitHandles, driver.submittedHandles)
    XCTAssertEqual(driver.cancelledHandles.count, 0)
    XCTAssertEqual(driver.returnedCancelHandles.count, 0)
    assertCleanup(await f.rescue())
  }

  func testCaptureReentryRefusesBeforeModeOrReservationMutation() async throws {
    try await checkRefusal(.capture)
  }

  func testAccountingReentryRefusesBeforeCaptureAndLeavesConsumerUsable() async throws {
    try await checkRefusal(.accounting)
  }

  func testDeliveryReentryRefusesWhileOuterCompletionIsLive() async throws {
    try await checkRefusal(.delivery)
  }

  func testObservationReentryRefusesBeforeWorkerCallbackReturns() async throws {
    try await checkRefusal(.observation)
  }

  func testRetryScheduleReentryRefusesBeforeTokenInstallation() async throws {
    try await checkRefusal(.retrySchedule)
  }

  func testRetryCancelReentryRefusesWhileJoinedCloseSetupIsLive() async throws {
    try await checkRefusal(.retryCancel)
  }

  func testInlineRetryFailureCancelReentryRefusesBeforeFailClosedReturns() async throws {
    try await checkRefusal(.inlineCancel)
  }

  private func checkRefusal(_ boundary: JoinedNativeBoundary) async throws {
    let f = try fixture(boundary: boundary)
    let boundaryReturned = expectation(description: "actual \(boundary.rawValue) callback returned")
    // A capture guard control may cancel before any worker exists. Signals
    // retain real events without creating an unwaited nonexistent obligation.
    let waiting = JoinedNativeSignal()
    let delivered = JoinedNativeSignal()
    let scheduled = JoinedNativeSignal()
    f.onBoundaryReturned = { boundaryReturned.fulfill() }
    f.onDelivery = { delivered.send() }
    f.retry.onReturned = { scheduled.send() }
    await f.driver.backing.configureAccepted(onWait: { waiting.send() })
    let startsPending =
      boundary == .retrySchedule || boundary == .retryCancel || boundary == .inlineCancel
    await f.driver.backing.setSettlement(
      startsPending ? .pending : .settled(admissionClosed: false))
    let weakContext = try f.submit()

    var outerClose: JoinedNativeTaskSlot?
    if boundary == .delivery || boundary == .observation {
      try await reached([waiting.waiter("real request sole waiter installed")])
      await f.driver.backing.setSettlement(.settled(admissionClosed: false))
      try await f.driver.backing.completeSuccess()
      f.completedOutcomeIssued = true
    } else if boundary == .retryCancel {
      try await reached([scheduled.waiter("actual retry schedule returned its token")])
      f.retry.onReturned = nil
      await f.driver.backing.setSettlement(.settled(admissionClosed: true))
      let slot = f.reserveTask()
      let task = Task { @MainActor in
        f.outerClose = await f.owner.shutdownJoined()
        f.record("outer.close.return")
      }
      slot.install(task)
      outerClose = slot
    }
    try await reached([boundaryReturned])
    f.onBoundaryReturned = nil
    f.retry.onReturned = nil

    // A guard-removal capture control may select joined mode and cancel the
    // active Job before captureNext can install any worker. Its witnessed
    // public .shutdown mutation is a reached failure boundary, not a worker.
    if f.unexpectedAdmissionMutation {
      assertCleanup(await f.rescue())
      return
    }
    await f.joinRegisteredTasks()
    XCTAssertEqual(f.refusals, [.callerRefused(.synchronousCallbackActive)])
    XCTAssertEqual(f.boundaryEntries, 1)
    XCTAssertEqual(f.boundaryReturns, 1)
    XCTAssertFalse(f.callbackLive)
    XCTAssertEqual(f.nativeActions, 1)
    XCTAssertEqual(f.immediateReturnedBeforeConstruction, 1)
    XCTAssertEqual(f.traceOverflow, 0)
    XCTAssertEqual(f.emergencyStops, 0)
    XCTAssertEqual(f.failureBoundaryStops, 0)
    if boundary != .retryCancel {
      let beforeOutsideClose = await f.driver.snapshot()
      XCTAssertEqual(beforeOutsideClose.joinCalls, 0)
      XCTAssertEqual(beforeOutsideClose.legacyCalls, 0)
    }

    switch boundary {
    case .capture, .accounting:
      try await reached([waiting.waiter("real request sole waiter installed")])
      await f.driver.backing.setSettlement(.settled(admissionClosed: false))
      try await f.driver.backing.completeSuccess()
      f.completedOutcomeIssued = true
      try await reached([delivered.waiter("actual completed delivery returned")])
      XCTAssertEqual(f.captures, 1)
      XCTAssertEqual(f.deliveries, 1)
      XCTAssertEqual(f.preparationEntries, 1)
      XCTAssertEqual(f.preparationReturns, 1)
      let lease = try XCTUnwrap(f.lease)
      XCTAssertTrue(
        f.owner.withResult(lease) { context, source, _ in
          XCTAssertEqual(context.label, "synthetic")
          XCTAssertEqual(source, "x")
        })
      XCTAssertNotNil(weakContext.value)
    case .delivery, .observation:
      try await reached([delivered.waiter("actual completed delivery returned")])
      XCTAssertEqual(f.captures, 1)
      XCTAssertEqual(f.deliveries, 1)
      XCTAssertEqual(f.workerReturns, 1)
      XCTAssertEqual(f.observerReturns, 1)
      XCTAssertNotNil(f.lease)
      let originalLease = try XCTUnwrap(f.lease)
      XCTAssertTrue(
        f.owner.withResult(originalLease) { context, source, _ in
          XCTAssertEqual(context.label, "synthetic")
          XCTAssertEqual(source, "x")
        })
      XCTAssertNotNil(weakContext.value)
    case .retrySchedule:
      XCTAssertEqual(f.captures, 0)
      XCTAssertEqual(f.deliveries, 0)
      XCTAssertEqual(f.retry.schedules, 1)
      XCTAssertEqual(f.retry.returnedSchedules, 1)
      XCTAssertEqual(f.retry.tokens.count, 1)
      XCTAssertNotNil(f.retry.tokens.first?.action)
      XCTAssertEqual(f.retry.tokens.first?.cancellations, 0)
    case .retryCancel:
      await outerClose?.join()
      let value = try observed(try XCTUnwrap(f.outerClose))
      assertClosed(value, parent: f.parent)
      XCTAssertEqual(f.retry.schedules, 1)
      XCTAssertEqual(f.retry.tokens.first?.cancellations, 1)
      XCTAssertNil(f.retry.tokens.first?.action)
      XCTAssertEqual(f.captures, 0)
      XCTAssertEqual(f.deliveries, 0)
    case .inlineCancel:
      try await reached([delivered.waiter("actual inline-failed delivery returned")])
      XCTAssertEqual(f.deliveryValues, [.failed(.internalFailure)])
      XCTAssertEqual(f.retry.schedules, 1)
      XCTAssertEqual(f.retry.tokens.first?.cancellations, 1)
      XCTAssertNil(f.retry.tokens.first?.action)
      XCTAssertEqual(f.captures, 0)
      XCTAssertEqual(f.preparationEntries, 0)
      XCTAssertEqual(f.workerReturns, 0)
      XCTAssertEqual(f.owner.accountingSnapshot.active, 2)
      XCTAssertEqual(f.owner.accountingSnapshot.reservedRetained, 0)
      f.checkMetadata(expected: .shutdown)
    }
    await f.driver.backing.setSettlement(.settled(admissionClosed: true))
    let outside = try observed(await f.owner.shutdownJoined())
    assertClosed(outside, parent: f.parent)
    XCTAssertNil(weakContext.value)
    if boundary == .retrySchedule {
      XCTAssertEqual(f.retry.tokens.first?.cancellations, 1)
      XCTAssertNil(f.retry.tokens.first?.action)
    }
    let driver = await f.driver.snapshot()
    XCTAssertEqual(driver.joinCalls, 1)
    XCTAssertEqual(driver.legacyCalls, 0)
    XCTAssertEqual(driver.discardCalls, 0)
    XCTAssertEqual(driver.waitedHandles, driver.submittedHandles)
    XCTAssertEqual(driver.returnedWaitHandles, driver.submittedHandles)
    // These requests already delivered their consumed result lease before
    // close, so no active request remains to cancel through the controller.
    XCTAssertEqual(driver.cancelledHandles.count, 0)
    XCTAssertEqual(driver.returnedCancelHandles.count, 0)
    XCTAssertEqual(driver.lastJoinHandle, driver.submittedHandles.first)
    assertCleanup(await f.rescue())
  }

  private func fixture(boundary: JoinedNativeBoundary? = nil) throws -> JoinedNativeFixture {
    let f = try JoinedNativeFixture(boundary: boundary)
    // Registered before setup/configuration/suspension/Timers/actions. This
    // joins true fixture scopes even if a tested terminal command returns early.
    addTeardownBlock {
      let cleanup = await f.rescue()
      await MainActor.run { Self.checkCleanup(cleanup) }
    }
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.prohibited)
    XCTAssertEqual(app.activationPolicy(), .prohibited)
    XCTAssertFalse(app.windows.contains { $0.isVisible })
    return f
  }

  private func reached(_ events: [XCTestExpectation]) async throws {
    let value = await XCTWaiter.fulfillment(of: events, timeout: 8)
    guard value == .completed else {
      XCTFail("required genuine native fixture boundary missing: \(value)")
      throw FixtureFailure.missingEvent
    }
  }

  private func observed(_ result: SearchAdmissionJoinedShutdownResult) throws
    -> SearchAdmissionJoinedShutdownObservation
  {
    guard case .observed(let value) = result else {
      XCTFail("expected actual outside joined observation: \(result)")
      throw FixtureFailure.missingObservation
    }
    return value
  }

  private func assertClosed(
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

  private func assertCleanup(_ value: JoinedNativeCleanup) { Self.checkCleanup(value) }

  private static func checkCleanup(_ value: JoinedNativeCleanup) {
    XCTAssertEqual(value.expectedWorkers, value.workerReturns)
    XCTAssertEqual(value.workerReturns, value.observerReturns)
    XCTAssertEqual(value.preparationEntries, value.preparationReturns)
    XCTAssertEqual(value.reservedTasks, value.installedTasks)
    XCTAssertEqual(value.installedTasks, value.joinedTasks)
    XCTAssertEqual(value.driver.inFlightScopes, 0)
    XCTAssertEqual(value.driver.scopeEntriesAfterSeal, 0)
    XCTAssertEqual(value.driver.cancelledHandles, value.driver.returnedCancelHandles)
    XCTAssertEqual(value.driver.submittedHandles, value.driver.returnedCancelHandles)
    XCTAssertEqual(value.fixtureCompletedCancels.count, value.completedHandlesNeedingCleanup.count)
    XCTAssertEqual(value.fixtureCompletedCancels, value.completedHandlesNeedingCleanup)
    XCTAssertTrue(value.registration.sealed)
    XCTAssertEqual(value.registration.registered, value.registration.joined)
    XCTAssertEqual(value.registration.registrationsAfterSeal, 0)
    XCTAssertFalse(value.actionsEnabled)
    XCTAssertFalse(value.loopRunning)
    XCTAssertEqual(value.traceOverflow, 0)
    XCTAssertFalse(NSApplication.shared.windows.contains { $0.isVisible })
  }
}

private enum JoinedNativeBoundary: String {
  case capture, accounting, delivery, observation, retrySchedule, retryCancel, inlineCancel
}

private final class JoinedNativeContext {
  let label = "synthetic"
}

/// A sticky, single-event latch. Its expectation is created only for an actual
/// body wait, including when the real callback happened before that wait.
private final class JoinedNativeSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var reached = false
  private var expected: XCTestExpectation?
  func send() {
    lock.lock()
    guard !reached else {
      lock.unlock()
      return
    }
    reached = true
    let expectation = expected
    lock.unlock()
    expectation?.fulfill()
  }
  func waiter(_ description: String) -> XCTestExpectation {
    lock.lock()
    precondition(expected == nil, "a genuine event is awaited only once")
    let expectation = XCTestExpectation(description: description)
    expected = expectation
    let alreadyReached = reached
    lock.unlock()
    if alreadyReached { expectation.fulfill() }
    return expectation
  }
}

@MainActor private final class JoinedNativeTaskSlot {
  private(set) var task: Task<Void, Never>?
  private(set) var joined = false
  func install(_ task: Task<Void, Never>) {
    precondition(self.task == nil)
    self.task = task
  }
  func join() async {
    guard let task else {
      XCTFail("reserved task never received its real handle")
      return
    }
    await task.value
    joined = true
  }
}

private final class JoinedNativeAccounting: SearchAdmissionAccounting {
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

@MainActor private final class JoinedNativeRetry: SearchAdmissionRetryScheduler {
  final class Token: SearchAdmissionRetryToken {
    var action: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    private(set) var cancellations = 0
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() {
      cancellations += 1
      let callback = onCancel
      onCancel = nil
      callback?()
      action = nil
    }
  }
  private(set) var schedules = 0
  private(set) var returnedSchedules = 0
  private(set) var tokens: [Token] = []
  var inline = false
  var onSchedule: (@MainActor () -> Void)?
  var onCancel: (@MainActor () -> Void)?
  var onReturned: (@MainActor () -> Void)?
  func schedule(_ action: @escaping @MainActor () -> Void) -> any SearchAdmissionRetryToken {
    schedules += 1
    let token = Token(action)
    token.onCancel = onCancel
    tokens.append(token)
    if inline { action() }
    let callback = onSchedule
    onSchedule = nil
    callback?()
    returnedSchedules += 1
    onReturned?()
    return token
  }
  func disarm() {
    onSchedule = nil
    onCancel = nil
    onReturned = nil
    for token in tokens {
      token.onCancel = nil
      token.action = nil
    }
  }
}

@MainActor private final class JoinedNativeAction: NSObject {
  let action: @MainActor () -> Void
  init(_ action: @escaping @MainActor () -> Void) { self.action = action }
  @objc func invoke(_ sender: Any?) { action() }
}

@MainActor private final class JoinedNativeLoop {
  enum Stop { case refusalReturned, publicFailureBoundary, borrowReturns }
  private(set) var running = false
  private(set) var stopReason: Stop?
  private var event: Timer?
  private var emergency: Timer?
  let emergencyFailure: @MainActor () -> Void
  init(emergencyFailure: @escaping @MainActor () -> Void) {
    self.emergencyFailure = emergencyFailure
  }
  func stop(_ reason: Stop) {
    guard running else { return }
    stopReason = reason
    CFRunLoopStop(CFRunLoopGetMain())
  }
  func rescue() {
    event?.invalidate()
    emergency?.invalidate()
    if running { CFRunLoopStop(CFRunLoopGetMain()) }
  }
  func run(_ action: @escaping @MainActor () -> Void) {
    precondition(!running)
    running = true
    let target = JoinedNativeAction(action)
    let event = Timer(fire: Date(), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.running == true else { return }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(JoinedNativeAction.invoke(_:)), to: target, from: nil))
      }
    }
    let emergency = Timer(fire: Date().addingTimeInterval(5), interval: 0, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.running else { return }
        self.emergencyFailure()
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
    XCTAssertEqual(CFRunLoopRunInMode(mode, 6, false), .stopped)
    XCTAssertNotNil(stopReason, "emergency release never certifies a native boundary")
  }
}

private struct JoinedNativeCleanup: Sendable {
  let expectedWorkers: Int
  let workerReturns: Int
  let observerReturns: Int
  let preparationEntries: Int
  let preparationReturns: Int
  let reservedTasks: Int
  let installedTasks: Int
  let joinedTasks: Int
  let completedHandlesNeedingCleanup: [SearchParentWireHandle]
  let fixtureCompletedCancels: [SearchParentWireHandle]
  let driver: JoinedAdmissionDriverSnapshot
  let registration: JoinedAdmissionRescueRegistrationSnapshot
  let actionsEnabled: Bool
  let loopRunning: Bool
  let traceOverflow: Int
}

@MainActor private final class JoinedNativeFixture {
  let driver = JoinedAdmissionDriver()
  let accounting = JoinedNativeAccounting()
  let retry = JoinedNativeRetry()
  let parent = JoinedAdmissionValues.completed()
  let boundary: JoinedNativeBoundary?
  private(set) var owner: SearchAdmissionController<JoinedNativeContext>!
  private(set) var consumer: SearchConsumerID!
  private(set) var captures = 0
  private(set) var deliveries = 0
  private(set) var deliveryValues: [SearchAdmissionDelivery] = []
  private(set) var lease: SearchResultLeaseID?
  private(set) var preparationEntries = 0
  private(set) var preparationReturns = 0
  private(set) var expectedWorkers = 0
  private(set) var workerReturns = 0
  private(set) var observerReturns = 0
  private(set) var callbackLive = false
  private(set) var boundaryEntries = 0
  private(set) var boundaryReturns = 0
  private(set) var nativeActions = 0
  private(set) var immediateReturnedBeforeConstruction = 0
  private(set) var refusals: [SearchAdmissionJoinedShutdownResult] = []
  private(set) var unexpectedAdmissionMutation = false
  private(set) var failureBoundaryStops = 0
  private(set) var emergencyStops = 0
  private(set) var trace: [String] = []
  private(set) var traceOverflow = 0
  var onBoundaryReturned: (@MainActor () -> Void)?
  var onDelivery: (@MainActor () -> Void)?
  var borrowLive = false
  var borrowResults: [SearchAdmissionJoinedShutdownResult] = []
  var borrowLegacy: SearchAdmissionShutdown?
  var outerClose: SearchAdmissionJoinedShutdownResult?
  var completedOutcomeIssued = false
  private var armed = true
  private var actionsEnabled = true
  private var jobs: [SearchJobID] = []
  private var originalJob: SearchJobID?
  private var taskSlots: [JoinedNativeTaskSlot] = []
  private var loops: [JoinedNativeLoop] = []
  private var outerTimers: [Timer] = []
  private var workWaiters: [CheckedContinuation<Void, Never>] = []
  private var cleanupTask: Task<JoinedNativeCleanup, Never>?

  init(boundary: JoinedNativeBoundary?) throws {
    self.boundary = boundary
    owner = try .init(
      driver: driver, accounting: accounting, retry: retry,
      prepare: { [weak self] text, estimate, captured, scope in
        await self?.preparationEntered()
        let value = await SearchAdmissionPreparation.validate(
          text: text, estimate: estimate, captured: captured, scope: scope)
        await self?.preparationReturned()
        return value
      }, observe: { [weak self] event in self?.observedWorker(event) })
    consumer = owner.register()
    if boundary == .accounting {
      accounting.onCharge = { [weak self] in self?.enterBoundary(.accounting) }
    }
    if boundary == .retrySchedule {
      retry.onSchedule = { [weak self] in self?.enterBoundary(.retrySchedule) }
    }
    if boundary == .retryCancel {
      retry.onCancel = { [weak self] in self?.enterBoundary(.retryCancel) }
    }
    if boundary == .inlineCancel {
      retry.inline = true
      retry.onCancel = { [weak self] in self?.enterBoundary(.inlineCancel) }
    }
  }

  func record(_ event: String) {
    if trace.count < 64 { trace.append(event) } else { traceOverflow += 1 }
  }

  func submit() throws -> AdmissionWeakBox<JoinedNativeContext> {
    let context = JoinedNativeContext()
    let weakContext = AdmissionWeakBox(context)
    let job = try owner.submit(
      consumer: consumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [weak self, context] in
        guard let self else { throw SearchAdmissionFailure.captureRefused }
        self.captures += 1
        if self.boundary == .capture { self.enterBoundary(.capture) }
        // beginShutdown's witnessed public mutation in the whole-capture
        // guard-removal control causes captureNext's cancelled-before-worker
        // branch. Do not invent a workerExited obligation for that branch.
        if !self.unexpectedAdmissionMutation { self.expectedWorkers += 1 }
        self.record("capture.return")
        return .init(text: "x", inputUTF16: 1, context: context)
      },
      completion: { [weak self] value in
        guard let self else { return }
        self.deliveries += 1
        self.deliveryValues.append(value)
        if case .completed(let lease) = value { self.lease = lease }
        if self.boundary == .delivery { self.enterBoundary(.delivery) }
        self.record("delivery.return")
        self.onDelivery?()
      })
    jobs.append(job)
    originalJob = job
    return weakContext
  }

  func reserveTask() -> JoinedNativeTaskSlot {
    let slot = JoinedNativeTaskSlot()
    taskSlots.append(slot)
    return slot
  }

  func joinRegisteredTasks() async {
    for slot in taskSlots { await slot.join() }
  }

  func newLoop() -> JoinedNativeLoop {
    let loop = JoinedNativeLoop { [weak self] in
      self?.emergencyStops += 1
      XCTFail("native action did not reach its declared real boundary")
    }
    loops.append(loop)
    return loop
  }

  func postOuter(_ action: @escaping @MainActor () -> Void) {
    let target = JoinedNativeAction { [weak self] in
      guard self?.actionsEnabled == true else { return }
      action()
    }
    let timer = Timer(fire: Date(), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.actionsEnabled == true else { return }
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(JoinedNativeAction.invoke(_:)), to: target, from: nil))
      }
    }
    outerTimers.append(timer)
    RunLoop.main.add(timer, forMode: .default)
  }

  func enterBoundary(_ reached: JoinedNativeBoundary) {
    guard armed, boundary == reached else { return }
    armed = false
    boundaryEntries += 1
    callbackLive = true
    record("\(reached.rawValue).enter")
    defer {
      callbackLive = false
      boundaryReturns += 1
      record("\(reached.rawValue).return")
      onBoundaryReturned?()
    }
    let loop = newLoop()
    loop.run { [self] in
      guard self.actionsEnabled else { return }
      self.nativeActions += 1
      self.record("native.action")
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
      XCTAssertTrue(self.callbackLive)
      XCTAssertEqual(self.boundaryReturns, 0)
      self.checkLiveLedger(reached)
      let slot = self.reserveTask()
      let before = self.refusals.count
      // Slot ownership exists BEFORE construction: immediate may finish or
      // suspend synchronously. Its actual handle is retained before any await.
      let task = Task<Void, Never>.immediate { @MainActor [self] in
        self.record("immediate.request")
        let result = await self.owner.shutdownJoined()
        self.refusals.append(result)
        self.record("immediate.return")
        XCTAssertEqual(result, .callerRefused(.synchronousCallbackActive))
        XCTAssertTrue(self.callbackLive)
        XCTAssertTrue(loop.running)
        XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
        XCTAssertEqual(self.boundaryReturns, 0)
      }
      slot.install(task)
      self.record("immediate.handle.retained")
      let didReturn = self.refusals.count == before + 1
      if didReturn { self.immediateReturnedBeforeConstruction += 1 }
      XCTAssertTrue(didReturn, "real depth refusal must return during immediate construction")
      let expected: SearchAdmissionFailure? =
        reached == .delivery ? nil : (reached == .retryCancel ? .shutdown : .consumerBusy)
      let actual = self.checkMetadata(expected: expected)
      self.record("public.metadata.boundary")
      if actual == .shutdown && expected != .shutdown {
        self.unexpectedAdmissionMutation = true
      }
      self.checkLiveLedger(reached)
      if didReturn {
        loop.stop(.refusalReturned)
      } else {
        // The public result/mutation probe above is reached synchronously. A
        // wrong terminal task can now be joined after the owning stack returns.
        self.failureBoundaryStops += 1
        self.record("public.failure.stop")
        loop.stop(.publicFailureBoundary)
      }
    }
  }

  @discardableResult
  func checkMetadata(expected: SearchAdmissionFailure?) -> SearchAdmissionFailure? {
    // Delivery needs an open-admission probe. A new isolated consumer avoids
    // cancelling the original published lease through consumerLease ownership.
    let freshConsumer: SearchConsumerID? =
      boundary == .delivery && expected == nil
      ? owner.register() : nil
    let probeConsumer: SearchConsumerID = freshConsumer ?? consumer
    defer {
      if let freshConsumer { owner.unregister(freshConsumer) }
    }
    do {
      let id = try owner.submit(
        consumer: probeConsumer, descriptor: JoinedAdmissionValues.descriptor(),
        capture: {
          XCTFail("synchronous metadata probe must never capture")
          throw SearchAdmissionFailure.captureRefused
        },
        completion: { _ in XCTFail("cancelled metadata probe must never deliver") })
      jobs.append(id)
      owner.cancel(id)
      XCTAssertNil(expected, "scope refusal must preserve open admission for the probe")
      return nil
    } catch {
      let failure = error as? SearchAdmissionFailure
      XCTAssertEqual(failure, expected, "public admission/probe consumer disposition changed")
      return failure
    }
  }

  private func checkLiveLedger(_ reached: JoinedNativeBoundary) {
    let value = owner.accountingSnapshot
    switch reached {
    case .capture, .observation:
      XCTAssertEqual(value.active, 6)
      XCTAssertEqual(value.reservedRetained, 3)
      XCTAssertEqual(value.reservationCount, 1)
      XCTAssertEqual(value.retained, 0)
      XCTAssertEqual(value.leaseCount, 0)
      XCTAssertEqual(captures, 1)
      if reached == .observation {
        XCTAssertEqual(workerReturns, 1)
        XCTAssertEqual(observerReturns, 0)
      }
    case .accounting:
      XCTAssertEqual(value.active, 2)
      XCTAssertEqual(value.reservedRetained, 0)
      XCTAssertEqual(value.reservationCount, 0)
      XCTAssertEqual(captures, 0)
      XCTAssertEqual(preparationEntries, 0)
    case .delivery:
      XCTAssertEqual(value.active, 2)
      XCTAssertEqual(value.retained, 3)
      XCTAssertEqual(value.leaseCount, 1)
      XCTAssertEqual(value.reservationCount, 0)
      XCTAssertEqual(deliveries, 1)
    case .retrySchedule:
      XCTAssertEqual(value.active, 2)
      XCTAssertEqual(value.reservedRetained, 0)
      XCTAssertEqual(captures, 0)
      XCTAssertEqual(retry.schedules, 1)
      XCTAssertEqual(retry.returnedSchedules, 0)
      XCTAssertEqual(retry.tokens.count, 1)
      XCTAssertEqual(retry.tokens.first?.cancellations, 0)
      XCTAssertNotNil(retry.tokens.first?.action)
    case .retryCancel, .inlineCancel:
      XCTAssertEqual(value.active, 2)
      XCTAssertEqual(value.reservedRetained, 0)
      XCTAssertEqual(captures, 0)
      XCTAssertEqual(retry.tokens.first?.cancellations, 1)
      XCTAssertNotNil(retry.tokens.first?.action)
      XCTAssertEqual(deliveries, 0)
    }
  }

  func checkBorrow(
    _ result: SearchAdmissionJoinedShutdownResult,
    weakContext: AdmissionWeakBox<JoinedNativeContext>, loop: JoinedNativeLoop
  ) {
    XCTAssertTrue(borrowLive)
    XCTAssertTrue(loop.running)
    XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
    guard case .observed(let value) = result else {
      return XCTFail("actual borrow observation required")
    }
    XCTAssertEqual(value.parent, parent)
    XCTAssertEqual(value.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(value.retainedLeases, 1)
    XCTAssertEqual(value.retainedActiveJobs, 0)
    XCTAssertEqual(value.activeCharge, 2)
    XCTAssertEqual(value.retainedCharge, 3)
    XCTAssertEqual(value.reservedRetainedCharge, 0)
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
    XCTAssertEqual(owner.accountingSnapshot.leaseCount, 1)
    XCTAssertNotNil(weakContext.value)
  }

  private func preparationEntered() { preparationEntries += 1 }
  private func preparationReturned() {
    preparationReturns += 1
    resumeWorkIfDrained()
  }
  private func observedWorker(_ event: SearchAdmissionEvent) {
    switch event {
    case .workerExited(let id):
      XCTAssertEqual(id, originalJob)
      workerReturns += 1
    }
    if boundary == .observation { enterBoundary(.observation) }
    observerReturns += 1
    resumeWorkIfDrained()
  }
  private var workDrained: Bool {
    expectedWorkers == workerReturns && workerReturns == observerReturns
      && preparationEntries == preparationReturns
  }
  private func resumeWorkIfDrained() {
    guard workDrained else { return }
    let waiters = workWaiters
    workWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
  private func drainWork() async {
    guard !workDrained else { return }
    await withCheckedContinuation { workWaiters.append($0) }
  }

  func rescue() async -> JoinedNativeCleanup {
    if cleanupTask == nil { cleanupTask = Task { await self.performRescue() } }
    return await cleanupTask!.value
  }
  private func performRescue() async -> JoinedNativeCleanup {
    armed = false
    actionsEnabled = false
    onBoundaryReturned = nil
    onDelivery = nil
    accounting.onCharge = nil
    retry.disarm()
    for timer in outerTimers { timer.invalidate() }
    for loop in loops { loop.rescue() }
    for job in jobs { owner.cancel(job) }
    if let lease { owner.release(lease) }
    owner.unregister(consumer)
    await driver.beginRescue()
    await drainWork()
    await joinRegisteredTasks()
    let beforeFixtureCancel = await driver.snapshot()
    var needingCleanup: [SearchParentWireHandle] = []
    var fixtureCancels: [SearchParentWireHandle] = []
    for handle in beforeFixtureCancel.submittedHandles
    where !beforeFixtureCancel.cancelledHandles.contains(handle) {
      // Only the sole genuinely completed/consumed result needs this fixture
      // command. Active request cancellation remains the controller's owner.
      let completedDelivery = deliveryValues.contains { value in
        if case .completed = value { return true }
        return false
      }
      guard completedOutcomeIssued, completedDelivery, captures == 1,
        expectedWorkers == 1, workerReturns == 1, observerReturns == 1,
        beforeFixtureCancel.submittedHandles.count == 1,
        beforeFixtureCancel.waitedHandles == beforeFixtureCancel.submittedHandles,
        beforeFixtureCancel.returnedWaitHandles == beforeFixtureCancel.submittedHandles
      else {
        XCTFail("fixture cancellation requires genuine sole completed-wait provenance")
        continue
      }
      needingCleanup.append(handle)
      do {
        try await driver.cancel(handle)
        fixtureCancels.append(handle)
      } catch { XCTFail("exact completed-handle fixture cancellation failed: \(error)") }
    }
    await driver.drainForwardedScopes()
    let registration = await driver.sealAndJoinRescueWaits()
    let snapshot = await driver.snapshot()
    owner = nil
    return .init(
      expectedWorkers: expectedWorkers, workerReturns: workerReturns,
      observerReturns: observerReturns,
      preparationEntries: preparationEntries, preparationReturns: preparationReturns,
      reservedTasks: taskSlots.count, installedTasks: taskSlots.filter { $0.task != nil }.count,
      joinedTasks: taskSlots.filter { $0.joined }.count,
      completedHandlesNeedingCleanup: needingCleanup, fixtureCompletedCancels: fixtureCancels,
      driver: snapshot, registration: registration,
      actionsEnabled: actionsEnabled, loopRunning: loops.contains { $0.running },
      traceOverflow: traceOverflow)
  }
}
