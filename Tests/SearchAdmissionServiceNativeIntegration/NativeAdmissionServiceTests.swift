import AppKit
import CoreFoundation
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Native facade boundaries in a separately generated macOS 26 / Swift 5 host.
/// Uses the actual facade/controller with unchanged scripted collaborators.
/// No public factory, helper process, shown window or posted input is exercised.
@MainActor final class NativeAdmissionServiceTests: XCTestCase {
  private enum FixtureFailure: Error { case missingEvent, missingObservation, captureEnded }

  func testCaptureRefusalThroughFacadePreservesAdmission() async throws {
    let owned = try fixture()
    let f = owned.fixture
    let consumer = f.register()
    let descriptor = try JoinedAdmissionValues.descriptor()
    let returned = expectation(description: "actual outer capture callback returned")
    returned.assertForOverFulfill = true
    await f.driver.backing.setSettlement(.settled(admissionClosed: false))
    let id = try f.submit(
      consumer: consumer, descriptor: descriptor,
      capture: {
        owned.captureLive = true
        owned.record("capture.enter")
        defer {
          owned.captureLive = false
          owned.captureReturns += 1
          owned.record("capture.return")
          returned.fulfill()
        }
        let before = f.accountingSnapshot
        XCTAssertEqual(before.active, 6)
        XCTAssertEqual(before.reservedRetained, 3)
        XCTAssertEqual(before.reservationCount, 1)
        XCTAssertEqual(before.retained, 0)
        XCTAssertEqual(before.leaseCount, 0)
        let loop = owned.newLoop()
        loop.run {
          XCTAssertTrue(owned.captureLive)
          XCTAssertEqual(owned.captureReturns, 0)
          XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
          owned.record("native.capture.action")
          let slot = owned.reserveTask()
          let task = Task<Void, Never>.immediate { @MainActor in
            // The loop stops on this actual caller return, for every result.
            defer { loop.stop(.callerReturned) }
            let result = await f.service.shutdownJoined()
            owned.captureResults.append(result)
            owned.record("capture.join.return")
            XCTAssertEqual(result, .callerRefused(.synchronousCallbackActive))
            XCTAssertTrue(owned.captureLive)
            XCTAssertTrue(loop.running)
            XCTAssertEqual(owned.captureReturns, 0)
            XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
            XCTAssertEqual(f.accountingSnapshot, before)
          }
          slot.install(task)
          owned.record("capture.handle.installed")
          XCTAssertEqual(
            owned.captureResults.count, 1,
            "the actual synchronous refusal must return during immediate construction")
          // Probe actual public metadata while the original capture is still live.
          do {
            let probe = try f.submit(
              consumer: consumer, descriptor: descriptor,
              capture: {
                XCTFail("live same-consumer probe must never capture")
                throw FixtureFailure.captureEnded
              }, completion: { _ in XCTFail("live same-consumer probe must never deliver") })
            owned.jobs.append(probe)
            f.service.cancel(probe)
            XCTFail("original live consumer must remain busy after scope refusal")
          } catch {
            XCTAssertEqual(error as? SearchAdmissionFailure, .consumerBusy)
          }
          XCTAssertEqual(f.accountingSnapshot, before)
          if owned.captureResults.isEmpty {
            // Reached synchronous nonreturn/admission assertions above are a
            // finite failure boundary. Unwind capture before joining its real
            // retained task; an emergency/deadline never counts as this branch.
            owned.failureBoundaryStops += 1
            loop.stop(.synchronousFailure)
          }
        }
        // Deliberate fixture error only after the genuine native loop returned.
        // No successful capture or nonexistent worker obligation is invented.
        throw FixtureFailure.captureEnded
      }, completion: { owned.captureDeliveries.append($0) })
    owned.jobs.append(id)
    try await reached([returned])
    await owned.joinTasks()
    XCTAssertEqual(owned.captureResults, [.callerRefused(.synchronousCallbackActive)])
    XCTAssertEqual(owned.captureDeliveries, [.failed(.captureRefused)])
    XCTAssertEqual(owned.captureReturns, 1)
    XCTAssertFalse(owned.captureLive)
    XCTAssertEqual(owned.failureBoundaryStops, 0)
    XCTAssertEqual(f.scopeSnapshot.captureEntries, 1)
    XCTAssertEqual(f.scopeSnapshot.captureReturns, 1)
    XCTAssertEqual(f.scopeSnapshot.successfulCaptureReturns, 0)
    XCTAssertEqual(f.scopeSnapshot.preparationEntries, 0)
    XCTAssertEqual(f.scopeSnapshot.preparationReturns, 0)
    XCTAssertTrue(f.scopeSnapshot.workerJobs.isEmpty)
    XCTAssertEqual(f.accountingSnapshot.active, 2)
    XCTAssertEqual(f.accountingSnapshot.reservedRetained, 0)
    let beforeClose = await f.driver.snapshot()
    XCTAssertEqual(beforeClose.joinCalls, 0)
    XCTAssertEqual(beforeClose.legacyCalls, 0)
    XCTAssertTrue(beforeClose.submittedHandles.isEmpty)

    // Same consumer is genuinely usable AFTER the real outer capture return.
    // Cancellation is synchronous before its asynchronous inspection can capture.
    let probe = try f.submit(
      consumer: consumer, descriptor: descriptor,
      capture: {
        XCTFail("cancelled queued post-capture probe must never capture")
        throw FixtureFailure.captureEnded
      }, completion: { _ in XCTFail("cancelled queued post-capture probe must never deliver") })
    owned.jobs.append(probe)
    owned.record("queued.probe.accepted")
    f.service.cancel(probe)
    owned.record("queued.probe.cancelled")
    let outside = try observed(await f.close().value)
    assertObservation(
      outside, parent: owned.parent, leases: 0, retained: 0,
      settlement: .settled(admissionClosed: false))
    await f.driver.backing.setSettlement(.settled(admissionClosed: true))
    let refreshed = try observed(await f.close().value)
    assertObservation(refreshed, parent: owned.parent, leases: 0, retained: 0)
    XCTAssertEqual(refreshed.parent, outside.parent)
    XCTAssertEqual(f.scopeSnapshot.captureEntries, 1)
    XCTAssertEqual(f.scopeSnapshot.successfulCaptureReturns, 0)
    XCTAssertTrue(f.scopeSnapshot.workerJobs.isEmpty)
    XCTAssertEqual(
      owned.trace,
      [
        "capture.enter", "native.capture.action", "capture.join.return",
        "capture.handle.installed", "capture.return", "queued.probe.accepted",
        "queued.probe.cancelled",
      ])
    let cleanup = await owned.cleanup()
    Self.checkCleanup(cleanup)
    XCTAssertEqual(cleanup.fixture.backendSubmitCalls, 0)
    XCTAssertEqual(cleanup.fixture.backendWaitCalls, 0)
    XCTAssertEqual(cleanup.fixture.backendCancelCalls, 0)
    XCTAssertEqual(cleanup.fixture.scopes.successfulCaptureReturns, 0)
    XCTAssertEqual(cleanup.fixture.scopes.preparationEntries, 0)
    XCTAssertTrue(cleanup.fixture.scopes.workerJobs.isEmpty)
    XCTAssertEqual(cleanup.reservedTasks, 1)
  }

  func testJoinedFacadeInsideBorrowPreservesResidualCreditUntilRealReturn() async throws {
    let owned = try fixture()
    let f = owned.fixture
    let waiting = expectation(description: "actual sole backend waiter installed")
    let delivered = expectation(description: "actual facade lease delivered")
    waiting.assertForOverFulfill = true
    delivered.assertForOverFulfill = true
    await f.driver.configureJoin(owned.parent)
    await f.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await f.driver.backing.setSettlement(.settled(admissionClosed: false))
    let witness = try submitLease(owned, delivered: delivered)
    try await reached([waiting])
    await f.driver.backing.setSettlement(.settled(admissionClosed: false))
    // Records actual sole backend completion/handle provenance independently
    // of candidate facade delivery, as required by the accepted cleanup ruling.
    try await f.completeSuccess()
    try await reached([delivered])
    let lease = try XCTUnwrap(owned.lease)
    XCTAssertEqual(f.accountingSnapshot.retained, 3)
    XCTAssertEqual(f.accountingSnapshot.leaseCount, 1)
    XCTAssertNotNil(witness.value)
    await f.driver.backing.setSettlement(.settled(admissionClosed: true))

    let returned = expectation(description: "Timer-owned actual outer borrow returned")
    returned.assertForOverFulfill = true
    owned.postOuter {
      let accepted = f.service.withResult(lease) { context, source, output in
        XCTAssertEqual(context.label, "synthetic")
        XCTAssertEqual(source, "x")
        XCTAssertEqual(output, .init(matches: [NSRange(location: 0, length: 1)], replacement: "y"))
        owned.borrowLive = true
        owned.record("borrow.enter")
        defer { owned.borrowLive = false }
        let loop = owned.newLoop()
        loop.run {
          let slot = owned.reserveTask()
          let task = Task<Void, Never>.immediate { @MainActor in
            // Stop on actual caller return even when either DTO is wrong.
            defer { loop.stop(.callerReturned) }
            let first = await f.service.shutdownJoined()
            owned.borrowResults.append(first)
            owned.checkInsideBorrow(first, witness: witness, loop: loop)
            owned.record("borrow.first.return")
            let second = await f.service.shutdownJoined()
            owned.borrowResults.append(second)
            owned.checkInsideBorrow(second, witness: witness, loop: loop)
            owned.record("borrow.second.return")
          }
          slot.install(task)
        }
        XCTAssertEqual(owned.borrowResults.count, 2)
        XCTAssertNotNil(witness.value)
        XCTAssertEqual(f.accountingSnapshot.retained, 3)
        XCTAssertEqual(f.accountingSnapshot.leaseCount, 1)
        XCTAssertFalse(
          f.service.withResult(lease) { _, _, _ in XCTFail("joined close invalidated lease") })
      }
      XCTAssertTrue(accepted)
      owned.record("borrow.outer.return")
      XCTAssertNil(witness.value)
      XCTAssertEqual(f.accountingSnapshot.retained, 0)
      XCTAssertEqual(f.accountingSnapshot.leaseCount, 0)
      returned.fulfill()
    }
    try await reached([returned])
    await owned.joinTasks()
    XCTAssertEqual(owned.borrowResults.count, 2)
    XCTAssertEqual(owned.failureBoundaryStops, 0)
    if owned.borrowResults.count == 2 {
      XCTAssertEqual(owned.borrowResults[0], owned.borrowResults[1])
    }
    for result in owned.borrowResults {
      assertObservation(try observed(result), parent: owned.parent, leases: 1, retained: 3)
    }
    // Outside the TRUE outer withResult return, only current residuals change.
    let later = try observed(await f.close().value)
    assertObservation(later, parent: owned.parent, leases: 0, retained: 0)
    XCTAssertNil(witness.value)
    XCTAssertEqual(
      owned.trace,
      ["borrow.enter", "borrow.first.return", "borrow.second.return", "borrow.outer.return"])
    let beforeCleanup = await f.driver.snapshot()
    XCTAssertEqual(beforeCleanup.joinCalls, 1)
    XCTAssertEqual(beforeCleanup.legacyCalls, 0)
    XCTAssertEqual(beforeCleanup.lastJoinHandle, beforeCleanup.submittedHandles.first)
    XCTAssertEqual(beforeCleanup.submittedHandles.count, 1)
    XCTAssertEqual(beforeCleanup.waitedHandles, beforeCleanup.submittedHandles)
    XCTAssertEqual(beforeCleanup.returnedWaitHandles, beforeCleanup.submittedHandles)
    XCTAssertTrue(beforeCleanup.cancelledHandles.isEmpty)
    let cleanup = await owned.cleanup()
    Self.checkCleanup(cleanup)
    XCTAssertEqual(cleanup.fixture.scopes.successfulCaptureReturns, 1)
    XCTAssertEqual(cleanup.fixture.scopes.preparationEntries, 1)
    XCTAssertEqual(cleanup.fixture.scopes.preparationReturns, 1)
    XCTAssertEqual(cleanup.fixture.scopes.workerJobs.count, 1)
    XCTAssertEqual(cleanup.fixture.fixtureCompletedCancels, beforeCleanup.submittedHandles)
    XCTAssertEqual(cleanup.reservedTasks, 1)
  }

  private func fixture() throws -> NativeServiceOwner {
    let owned = try NativeServiceOwner()
    // Rescue exists before app setup, first suspension or any native action.
    addTeardownBlock {
      let cleanup = await owned.cleanup()
      await MainActor.run { Self.checkCleanup(cleanup) }
    }
    _ = NSApplication.shared.setActivationPolicy(.prohibited)
    XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
    XCTAssertFalse(NSApplication.shared.windows.contains { $0.isVisible })
    return owned
  }

  private func submitLease(_ owned: NativeServiceOwner, delivered: XCTestExpectation) throws
    -> AdmissionWeakBox<NativeServiceContext>
  {
    let context = NativeServiceContext()
    let witness = AdmissionWeakBox(context)
    let id = try owned.fixture.submit(
      consumer: owned.fixture.register(), descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context) },
      completion: { value in
        if case .completed(let lease) = value { owned.lease = lease }
        delivered.fulfill()
      })
    owned.jobs.append(id)
    // Only a weak witness escapes; source/capture aliases leave this helper.
    return witness
  }

  private func reached(_ events: [XCTestExpectation]) async throws {
    let result = await XCTWaiter.fulfillment(of: events, timeout: 8)
    guard result == .completed else {
      XCTFail("actual native fixture event missing: \(result)")
      throw FixtureFailure.missingEvent
    }
  }

  private func observed(_ result: SearchAdmissionJoinedShutdownResult) throws
    -> SearchAdmissionJoinedShutdownObservation
  {
    guard case .observed(let value) = result else {
      XCTFail("expected actual facade joined observation: \(result)")
      throw FixtureFailure.missingObservation
    }
    return value
  }

  private func assertObservation(
    _ value: SearchAdmissionJoinedShutdownObservation, parent: SearchParentJoinedShutdownResult,
    leases: Int, retained: UInt64,
    settlement: SearchParentWireSettlement = .settled(admissionClosed: true)
  ) {
    XCTAssertEqual(value.parent, parent)
    XCTAssertEqual(value.driverSettlement, settlement)
    XCTAssertEqual(value.retainedActiveJobs, 0)
    XCTAssertEqual(value.retainedLeases, leases)
    XCTAssertEqual(value.activeCharge, 2)
    XCTAssertEqual(value.retainedCharge, retained)
    XCTAssertEqual(value.reservedRetainedCharge, 0)
  }

  private static func checkCleanup(_ value: NativeServiceCleanup) {
    XCTAssertEqual(value.reservedTasks, value.installedTasks)
    XCTAssertEqual(value.installedTasks, value.joinedTasks)
    XCTAssertFalse(value.actionsEnabled)
    XCTAssertFalse(value.loopRunning)
    XCTAssertEqual(value.emergencyStops, 0)
    XCTAssertEqual(value.traceOverflow, 0)
    let f = value.fixture
    XCTAssertEqual(f.scopes.outstandingRequests, 0)
    XCTAssertEqual(f.scopes.unexpectedWorkerReturns, 0)
    XCTAssertEqual(f.scopes.preparationEntries, f.scopes.preparationReturns)
    XCTAssertEqual(f.reservedCallers, f.installedCallers)
    XCTAssertEqual(f.installedCallers, f.joinedCallers)
    XCTAssertTrue(f.terminalFenceReserved)
    XCTAssertTrue(f.terminalFenceInstalled)
    XCTAssertTrue(f.terminalFenceJoined)
    XCTAssertEqual(f.terminalFenceKind, .joined)
    XCTAssertEqual(f.driver.inFlightScopes, 0)
    XCTAssertEqual(f.driver.scopeEntriesAfterSeal, 0)
    XCTAssertEqual(f.driver.cancelledHandles, f.driver.returnedCancelHandles)
    XCTAssertEqual(f.driver.submittedHandles, f.driver.returnedWaitHandles)
    XCTAssertEqual(f.driver.submittedHandles, f.driver.returnedCancelHandles)
    XCTAssertEqual(f.completedHandlesNeedingCleanup, f.fixtureCompletedCancels)
    XCTAssertTrue(f.registration.sealed)
    XCTAssertEqual(f.registration.registered, f.registration.joined)
    XCTAssertEqual(f.registration.registrationsAfterSeal, 0)
    XCTAssertFalse(NSApplication.shared.windows.contains { $0.isVisible })
  }
}

private final class NativeServiceContext { let label = "synthetic" }

@MainActor private final class NativeServiceTaskSlot {
  private(set) var task: Task<Void, Never>?
  private(set) var joined = false
  func install(_ task: Task<Void, Never>) {
    precondition(self.task == nil)
    self.task = task
  }
  func join() async {
    guard let task else { return XCTFail("registered immediate task has no retained handle") }
    await task.value
    joined = true
  }
}

@MainActor private final class NativeServiceAction: NSObject {
  let action: @MainActor () -> Void
  init(_ action: @escaping @MainActor () -> Void) { self.action = action }
  @objc func invoke(_ sender: Any?) { action() }
}

/// Independently owned native timers run one declared action in a real modal loop.
@MainActor private final class NativeServiceLoop {
  enum Stop { case callerReturned, synchronousFailure }
  private(set) var running = false
  private(set) var reason: Stop?
  private var event: Timer?
  private var deadline: Timer?
  let emergency: @MainActor () -> Void
  init(emergency: @escaping @MainActor () -> Void) { self.emergency = emergency }
  func stop(_ reason: Stop) {
    guard running else { return }
    self.reason = reason
    CFRunLoopStop(CFRunLoopGetMain())
  }
  func disable() {
    event?.invalidate()
    deadline?.invalidate()
    if running { CFRunLoopStop(CFRunLoopGetMain()) }
  }
  func run(_ action: @escaping @MainActor () -> Void) {
    precondition(!running)
    running = true
    let target = NativeServiceAction(action)
    let event = Timer(fire: Date(), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.running == true else { return }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(NativeServiceAction.invoke(_:)), to: target, from: nil))
      }
    }
    let deadline = Timer(fire: Date().addingTimeInterval(5), interval: 0, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.running else { return }
        self.emergency()
        CFRunLoopStop(CFRunLoopGetMain())
      }
    }
    self.event = event
    self.deadline = deadline
    RunLoop.main.add(event, forMode: .modalPanel)
    RunLoop.main.add(deadline, forMode: .modalPanel)
    defer {
      running = false
      event.invalidate()
      deadline.invalidate()
      self.event = nil
      self.deadline = nil
    }
    let mode = CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString)
    XCTAssertEqual(CFRunLoopRunInMode(mode, 6, false), .stopped)
    XCTAssertNotNil(reason, "deadline release is never an actual native caller return")
  }
}

private struct NativeServiceCleanup: Sendable {
  let reservedTasks: Int
  let installedTasks: Int
  let joinedTasks: Int
  let actionsEnabled: Bool
  let loopRunning: Bool
  let emergencyStops: Int
  let failureBoundaryStops: Int
  let traceOverflow: Int
  let fixture: ServiceCleanupSnapshot
}

/// Shared fixture dependencies are explicit source-relative inputs. Its real
/// controller cleanup fence is authoritative, independent of facade DTOs.
@MainActor private final class NativeServiceOwner {
  let fixture: ServiceFixture<NativeServiceContext>
  let parent = JoinedAdmissionValues.completed()
  var jobs: [SearchJobID] = []
  var lease: SearchResultLeaseID?
  var captureLive = false
  var captureReturns = 0
  var captureResults: [SearchAdmissionJoinedShutdownResult] = []
  var captureDeliveries: [SearchAdmissionDelivery] = []
  var borrowLive = false
  var borrowResults: [SearchAdmissionJoinedShutdownResult] = []
  var failureBoundaryStops = 0
  private(set) var emergencyStops = 0
  private(set) var trace: [String] = []
  private(set) var traceOverflow = 0
  private var actionsEnabled = true
  private var slots: [NativeServiceTaskSlot] = []
  private var loops: [NativeServiceLoop] = []
  private var outerTimers: [Timer] = []
  private var cleanupTask: Task<NativeServiceCleanup, Never>?

  init() throws { fixture = try ServiceFixture() }
  func record(_ event: String) {
    if trace.count < 32 { trace.append(event) } else { traceOverflow += 1 }
  }
  func reserveTask() -> NativeServiceTaskSlot {
    precondition(actionsEnabled && slots.count < 2)
    let slot = NativeServiceTaskSlot()
    slots.append(slot)
    return slot
  }
  func joinTasks() async { for slot in slots { await slot.join() } }
  func newLoop() -> NativeServiceLoop {
    precondition(actionsEnabled && loops.count < 2)
    let loop = NativeServiceLoop { [weak self] in
      self?.emergencyStops += 1
      XCTFail("native modal loop required emergency release")
    }
    loops.append(loop)
    return loop
  }
  func postOuter(_ action: @escaping @MainActor () -> Void) {
    precondition(actionsEnabled && outerTimers.count < 2)
    let target = NativeServiceAction { [weak self] in
      guard self?.actionsEnabled == true else { return }
      action()
    }
    let timer = Timer(fire: Date(), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.actionsEnabled == true else { return }
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(NativeServiceAction.invoke(_:)), to: target, from: nil))
      }
    }
    outerTimers.append(timer)
    RunLoop.main.add(timer, forMode: .default)
  }
  func checkInsideBorrow(
    _ result: SearchAdmissionJoinedShutdownResult,
    witness: AdmissionWeakBox<NativeServiceContext>, loop: NativeServiceLoop
  ) {
    XCTAssertTrue(borrowLive)
    XCTAssertTrue(loop.running)
    XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
    XCTAssertNotNil(witness.value)
    XCTAssertEqual(fixture.accountingSnapshot.retained, 3)
    XCTAssertEqual(fixture.accountingSnapshot.leaseCount, 1)
    guard case .observed(let value) = result else {
      return XCTFail("actual inside-borrow facade observation missing: \(result)")
    }
    XCTAssertEqual(value.parent, parent)
    XCTAssertEqual(value.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(value.retainedActiveJobs, 0)
    XCTAssertEqual(value.retainedLeases, 1)
    XCTAssertEqual(value.activeCharge, 2)
    XCTAssertEqual(value.retainedCharge, 3)
    XCTAssertEqual(value.reservedRetainedCharge, 0)
  }
  func cleanup() async -> NativeServiceCleanup {
    if cleanupTask == nil {
      // Disable every native producer synchronously, before constructing the
      // cleanup Task or reaching the first await. No later Timer can register
      // another immediate task while the retained existing handles are joined.
      actionsEnabled = false
      for timer in outerTimers { timer.invalidate() }
      for loop in loops { loop.disable() }
      cleanupTask = Task { await self.performCleanup() }
    }
    return await cleanupTask!.value
  }
  private func performCleanup() async -> NativeServiceCleanup {
    for id in jobs { fixture.service.cancel(id) }
    if let lease { fixture.service.release(lease) }
    // Genuine backend rescue releases held submit/cancel/query/wait scopes,
    // including late sole-wait registration. Never cancel a caller as its join.
    await fixture.driver.beginRescue()
    await joinTasks()
    // All native callers have really returned before the accepted fixture
    // cancels/unregisters through its independently retained actual controller,
    // joins helpers/current refresh with its terminal fence, then drains/seals.
    // Completed-handle cancel authority uses backend/wait/worker provenance,
    // independent of candidate facade delivery or this owner's lease field.
    let result = await fixture.cleanup()
    let snapshot = NativeServiceCleanup(
      reservedTasks: slots.count, installedTasks: slots.filter { $0.task != nil }.count,
      joinedTasks: slots.filter { $0.joined }.count, actionsEnabled: actionsEnabled,
      loopRunning: loops.contains { $0.running }, emergencyStops: emergencyStops,
      failureBoundaryStops: failureBoundaryStops, traceOverflow: traceOverflow,
      fixture: result)
    // Release retained native producer/Task closures only AFTER genuine joins.
    outerTimers.removeAll()
    loops.removeAll()
    slots.removeAll()
    jobs.removeAll()
    lease = nil
    return snapshot
  }
}
