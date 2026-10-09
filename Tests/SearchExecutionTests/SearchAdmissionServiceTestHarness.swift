import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// These helpers belong only to the facade tests. The old fixtures are read-only.
final class ServiceReferenceContext {
  let label: String
  init(label: String) { self.label = label }
}

struct ServiceScopeSnapshot: Sendable {
  let captureEntries: Int
  let captureReturns: Int
  let successfulCaptureReturns: Int
  let completionReturns: Int
  let preparationEntries: Int
  let preparationReturns: Int
  let workerJobs: [SearchJobID]
  let outstandingRequests: Int
  let unexpectedWorkerReturns: Int
}

@MainActor private final class ServiceScopes {
  private var captureEntries = 0
  private var captureReturns = 0
  private var successfulCaptureReturns = 0
  private var completionReturns = 0
  private var preparationEntries = 0
  private var preparationReturns = 0
  private var workerJobs: [SearchJobID] = []
  private var outstandingRequests = 0
  private var unexpectedWorkerReturns = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func captureEntered() { captureEntries += 1 }

  func captureOuterReturned(successful: Bool) {
    captureReturns += 1
    if successful {
      successfulCaptureReturns += 1
      outstandingRequests += 1
    }
  }

  func completionOuterReturned() { completionReturns += 1 }
  func preparationEntered() { preparationEntries += 1 }
  func preparationReturned() { preparationReturns += 1 }

  func workerReturned(_ id: SearchJobID) {
    workerJobs.append(id)
    if outstandingRequests > 0 {
      outstandingRequests -= 1
    } else {
      unexpectedWorkerReturns += 1
    }
    resumeIfDrained()
  }

  private var drained: Bool {
    outstandingRequests == 0 && preparationEntries == preparationReturns
  }

  private func resumeIfDrained() {
    guard drained else { return }
    let held = waiters
    waiters.removeAll()
    for waiter in held { waiter.resume() }
  }

  func drain() async {
    guard !drained else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func snapshot() -> ServiceScopeSnapshot {
    .init(
      captureEntries: captureEntries, captureReturns: captureReturns,
      successfulCaptureReturns: successfulCaptureReturns, completionReturns: completionReturns,
      preparationEntries: preparationEntries, preparationReturns: preparationReturns,
      workerJobs: workerJobs, outstandingRequests: outstandingRequests,
      unexpectedWorkerReturns: unexpectedWorkerReturns)
  }
}

enum ServiceCleanupFenceKind: Sendable, Equatable {
  case joined, requestlessLegacy
}

struct ServiceCleanupSnapshot: Sendable {
  let scopes: ServiceScopeSnapshot
  let reservedCallers: Int
  let installedCallers: Int
  let joinedCallers: Int
  let terminalFenceKind: ServiceCleanupFenceKind
  let terminalFenceReserved: Bool
  let terminalFenceInstalled: Bool
  let terminalFenceJoined: Bool
  let backendSubmitCalls: Int
  let backendWaitCalls: Int
  let backendCancelCalls: Int
  let completedHandlesNeedingCleanup: [SearchParentWireHandle]
  let fixtureCompletedCancels: [SearchParentWireHandle]
  let driver: JoinedAdmissionDriverSnapshot
  let registration: JoinedAdmissionRescueRegistrationSnapshot
}

/// An actual controller with separately owned rescue authority. All exercise
/// calls use `service`; direct controller calls below are setup or cleanup only.
@MainActor final class ServiceFixture<Context> {
  private enum FixtureFailure: Error { case completedWaitProvenanceMissing }

  private final class CallerSlot {
    var join: (@MainActor () async -> Void)?
    var joined = false
  }

  private final class CleanupFenceSlot {
    let kind: ServiceCleanupFenceKind
    let start = JoinedAdmissionGate()
    var task: Task<Void, Never>?
    var joined = false

    init(kind: ServiceCleanupFenceKind) { self.kind = kind }
  }

  let driver: JoinedAdmissionDriver
  let retry: AdmissionManualRetry
  let accounting: AdmissionTestAccounting
  let service: SearchAdmissionService<Context>
  private let controller: SearchAdmissionController<Context>
  private let scopes: ServiceScopes
  private var consumers: [SearchConsumerID] = []
  private var jobs: [SearchJobID] = []
  private var leases: [SearchResultLeaseID] = []
  private var gates: [JoinedAdmissionGate] = []
  private var callerSlots: [CallerSlot] = []
  private var completedOutcomeHandles: [SearchParentWireHandle] = []
  private var cleanupFenceKind: ServiceCleanupFenceKind
  private var cleanupFence: CleanupFenceSlot?
  private var cleanupTask: Task<ServiceCleanupSnapshot, Never>?

  init(
    joining: Bool = true, preparationGate: JoinedAdmissionGate? = nil,
    observe: (@MainActor (SearchAdmissionEvent) -> Void)? = nil
  ) throws {
    let driver = JoinedAdmissionDriver()
    let retry = AdmissionManualRetry()
    let accounting = AdmissionTestAccounting()
    let scopes = ServiceScopes()
    self.driver = driver
    self.retry = retry
    self.accounting = accounting
    self.scopes = scopes
    cleanupFenceKind = joining ? .joined : .requestlessLegacy
    if let preparationGate { gates.append(preparationGate) }
    let selected: any SearchParentWireDriving
    if joining { selected = driver } else { selected = driver.backing }
    let controller = try SearchAdmissionController<Context>(
      driver: selected, accounting: accounting, retry: retry,
      prepare: { _, _, _, _ in
        await scopes.preparationEntered()
        await preparationGate?.wait()
        await scopes.preparationReturned()
        return true
      },
      observe: { event in
        if case .workerExited(let id) = event { scopes.workerReturned(id) }
        observe?(event)
      })
    self.controller = controller
    service = SearchAdmissionService(controller: controller)
  }

  var scopeSnapshot: ServiceScopeSnapshot { scopes.snapshot() }
  var accountingSnapshot: SearchAdmissionLedgerSnapshot { controller.accountingSnapshot }

  func register() -> SearchConsumerID {
    let consumer = service.register()
    consumers.append(consumer)
    return consumer
  }

  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    let scopes = scopes
    let id = try service.submit(
      consumer: consumer, descriptor: descriptor,
      capture: {
        scopes.captureEntered()
        var successful = false
        defer { scopes.captureOuterReturned(successful: successful) }
        let value = try capture()
        successful = true
        return value
      },
      completion: { [self] value in
        defer { scopes.completionOuterReturned() }
        if case .completed(let lease) = value {
          leases.append(lease)
        }
        completion(value)
      })
    jobs.append(id)
    return id
  }

  /// Reserve ownership before task construction; installation is synchronous
  /// and MainActor contains no suspension until the handle is retained.
  func close(entered: XCTestExpectation? = nil)
    -> Task<SearchAdmissionJoinedShutdownResult, Never>
  {
    let slot = CallerSlot()
    callerSlots.append(slot)
    let service = service
    let task = Task {
      entered?.fulfill()
      return await service.shutdownJoined()
    }
    slot.join = { _ = await task.value }
    return task
  }

  /// Deliberate precondition setup for the one legacy-selected refusal case.
  /// This is not a facade API and is never used as an assertion result.
  func selectLegacyForSetup() -> Task<SearchAdmissionShutdown, Never> {
    cleanupFenceKind = .requestlessLegacy
    let slot = CallerSlot()
    callerSlots.append(slot)
    let controller = controller
    let task = Task { await controller.shutdown() }
    slot.join = { _ = await task.value }
    return task
  }

  /// Complete only the real backend's current sole waiter, recording its exact
  /// handle before completion. No helper rewrites source/output/outcome bytes.
  func completeSuccess() async throws {
    let before = await driver.snapshot()
    let outstanding = before.waitedHandles.filter { !before.returnedWaitHandles.contains($0) }
    guard outstanding.count == 1, let exact = outstanding.first,
      before.submittedHandles.contains(exact), !completedOutcomeHandles.contains(exact)
    else {
      XCTFail("successful fixture completion requires one actual outstanding sole wait")
      throw FixtureFailure.completedWaitProvenanceMissing
    }
    try await driver.backing.completeSuccess()
    completedOutcomeHandles.append(exact)
  }

  func cleanup() async -> ServiceCleanupSnapshot {
    if cleanupTask == nil { cleanupTask = Task { await self.performCleanup() } }
    return await cleanupTask!.value
  }

  /// This actual-owner task is independent of candidate facade forwarding and
  /// its result. Reserve its gate/slot and retain the exact handle before rescue
  /// can suspend. The start gate orders the final owner call after every caller.
  private func reserveCleanupFence() -> CleanupFenceSlot {
    precondition(cleanupFence == nil)
    let slot = CleanupFenceSlot(kind: cleanupFenceKind)
    cleanupFence = slot
    let controller = controller
    slot.task = Task {
      await slot.start.wait()
      switch slot.kind {
      case .joined:
        // Actual joined entry suppresses future ordinary pump/inspection and
        // joins retained request/cancel/inspection helpers plus real refresh.
        _ = await controller.shutdownJoined()
      case .requestlessLegacy:
        // Only the known no-request unsupported/legacy fixtures use this path.
        // shutdown joins the terminal command and its real final inspection;
        // it does not promise to join arbitrary request/cancellation helpers.
        _ = await controller.shutdown()
      }
    }
    return slot
  }

  private func performCleanup() async -> ServiceCleanupSnapshot {
    retry.onSchedule = nil
    for token in retry.tokens { token.cancel() }
    // Fence known work through the actual owner before any rescue suspension.
    // This succeeds even when a facade cancellation forwarding mutant fails.
    for id in jobs { controller.cancel(id) }
    for id in leases { controller.release(id) }
    for consumer in consumers { controller.unregister(consumer) }
    let fence = reserveCleanupFence()
    await driver.beginRescue()
    for gate in gates { await gate.release() }
    // Actual preparation entries/returns and workerExited events are required.
    // These observations do not replace the actual-owner Task fence below.
    await scopes.drain()
    for slot in callerSlots {
      guard let join = slot.join else {
        XCTFail("reserved facade caller was not synchronously installed")
        continue
      }
      await join()
      slot.joined = true
    }
    // Every facade/setup caller has returned before the final actual-owner
    // terminal invocation. No caller can create a later refresh/inspection.
    await fence.start.release()
    if let task = fence.task {
      await task.value
      fence.joined = true
    } else {
      XCTFail("reserved actual-controller cleanup fence was not installed")
    }
    let backendSubmitCalls = await driver.backing.submitCalls
    let backendWaitCalls = await driver.backing.waitCalls
    let backendCancelCalls = await driver.backing.cancelCalls
    if fence.kind == .requestlessLegacy {
      let scope = scopes.snapshot()
      // The legacy endpoint is not a general request drain. Preserve the
      // requestless source premise and witness it against actual collaborators.
      XCTAssertEqual(scope.successfulCaptureReturns, 0)
      XCTAssertEqual(scope.preparationEntries, 0)
      XCTAssertEqual(scope.preparationReturns, 0)
      XCTAssertEqual(scope.workerJobs.count, 0)
      XCTAssertEqual(backendSubmitCalls, 0)
      XCTAssertEqual(backendWaitCalls, 0)
      XCTAssertEqual(backendCancelCalls, 0)
    }
    let beforeFixtureCancel = await driver.snapshot()
    var needingCleanup: [SearchParentWireHandle] = []
    var fixtureCancels: [SearchParentWireHandle] = []
    for handle in beforeFixtureCancel.submittedHandles
    where !beforeFixtureCancel.cancelledHandles.contains(handle) {
      let scope = scopes.snapshot()
      // Genuine sole backend completion/consumption and actual worker/prepare
      // returns authorize this fixture command independently of facade delivery.
      // An in-flight real cancel is never duplicated or called a return.
      guard completedOutcomeHandles == [handle],
        scope.successfulCaptureReturns == 1, scope.workerJobs.count == 1,
        scope.outstandingRequests == 0,
        scope.preparationEntries == 1, scope.preparationReturns == 1,
        beforeFixtureCancel.submittedHandles == [handle],
        beforeFixtureCancel.waitedHandles == [handle],
        beforeFixtureCancel.returnedWaitHandles == [handle]
      else {
        XCTFail("completed-handle fixture cancellation lacks genuine sole-wait provenance")
        continue
      }
      needingCleanup.append(handle)
      do {
        try await driver.cancel(handle)
        fixtureCancels.append(handle)
      } catch {
        XCTFail("exact completed-handle fixture cancellation failed: \(error)")
      }
    }
    await driver.drainForwardedScopes()
    let registration = await driver.sealAndJoinRescueWaits()
    return .init(
      scopes: scopes.snapshot(), reservedCallers: callerSlots.count,
      installedCallers: callerSlots.filter { $0.join != nil }.count,
      joinedCallers: callerSlots.filter { $0.joined }.count,
      terminalFenceKind: fence.kind, terminalFenceReserved: cleanupFence === fence,
      terminalFenceInstalled: fence.task != nil, terminalFenceJoined: fence.joined,
      backendSubmitCalls: backendSubmitCalls, backendWaitCalls: backendWaitCalls,
      backendCancelCalls: backendCancelCalls,
      completedHandlesNeedingCleanup: needingCleanup, fixtureCompletedCancels: fixtureCancels,
      driver: await driver.snapshot(), registration: registration)
  }
}
