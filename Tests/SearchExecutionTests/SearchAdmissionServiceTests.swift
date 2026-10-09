import Foundation
import PadCore
import XCTest

@testable import SearchExecution

@MainActor final class SearchAdmissionServiceTests: XCTestCase {
  private enum TestFailure: Error { case eventNotReached, observationMissing }

  // Break: the facade uses different controllers for registration/submission,
  // bypasses consumerBusy, changes a job ID, or drops queued cancellation.
  func testConsumersShareControllerAndForwardQueueCancellation() async throws {
    let fixture: ServiceFixture<JoinedAdmissionContext> = try makeFixture()
    let service = fixture.service
    let firstConsumer = fixture.register()
    let otherConsumer = fixture.register()
    let waiting = expectation(description: "first consumer owns actual sole wait")
    await fixture.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    let delivered = expectation(description: "first job really delivered")
    var firstDeliveries = 0
    let first = try fixture.submit(
      consumer: firstConsumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext()) },
      completion: { value in
        firstDeliveries += 1
        defer { delivered.fulfill() }
        guard case .completed = value else {
          return XCTFail("first job must complete: \(value)")
        }
      })
    try await requireEvents([waiting])
    var rejectedCaptures = 0
    XCTAssertThrowsError(
      try fixture.submit(
        consumer: firstConsumer, descriptor: JoinedAdmissionValues.descriptor(),
        capture: {
          rejectedCaptures += 1
          return .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext())
        }, completion: { _ in XCTFail("consumerBusy must not complete") })
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .consumerBusy) }
    var queuedCaptures = 0
    var queuedCompletions = 0
    let queued = try fixture.submit(
      consumer: otherConsumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: {
        queuedCaptures += 1
        return .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext())
      }, completion: { _ in queuedCompletions += 1 })
    XCTAssertNotEqual(first, queued)
    XCTAssertEqual(fixture.scopeSnapshot.successfulCaptureReturns, 1)
    let held = await fixture.driver.snapshot()
    XCTAssertEqual(held.submittedHandles.count, 1)
    XCTAssertEqual(held.waitedHandles, held.submittedHandles)
    service.cancel(queued)
    // Admission through the same other-consumer capability proves its queued
    // job was removed. Its real callback is an eventual positive queue witness.
    let otherUsable = expectation(description: "other consumer usable after queued cancel")
    let sentinel = try fixture.submit(
      consumer: otherConsumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: { throw SearchAdmissionFailure.captureRefused },
      completion: {
        XCTAssertEqual($0, .failed(.captureRefused))
        otherUsable.fulfill()
      })
    XCTAssertNotEqual(sentinel, queued)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    try await fixture.completeSuccess()
    try await requireEvents([delivered, otherUsable])
    XCTAssertEqual(rejectedCaptures, 0)
    XCTAssertEqual(queuedCaptures, 0)
    XCTAssertEqual(queuedCompletions, 0)
    XCTAssertEqual(firstDeliveries, 1)
    XCTAssertEqual(fixture.scopeSnapshot.workerJobs, [first])
    let actual = await fixture.driver.snapshot()
    XCTAssertEqual(actual.submittedHandles, held.submittedHandles)
    XCTAssertEqual(actual.returnedWaitHandles, held.submittedHandles)
    XCTAssertEqual(actual.cancelledHandles, [])
  }

  // Break: the facade copies/replaces Context, rewrites result text/output,
  // invokes a borrow twice, or fails to invalidate the exact released lease.
  func testLeaseBorrowPreservesContextAndReleaseInvalidates() async throws {
    let fixture: ServiceFixture<ServiceReferenceContext> = try makeFixture()
    let service = fixture.service
    let consumer = fixture.register()
    let waiting = expectation(description: "lease source actual sole wait")
    await fixture.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    var context: ServiceReferenceContext? = ServiceReferenceContext(label: "A😀B𝄞")
    let witness = AdmissionWeakBox(context)
    let identity = ObjectIdentifier(try XCTUnwrap(context))
    let delivered = expectation(description: "actual lease delivered")
    var deliveries: [SearchAdmissionDelivery] = []
    var lease: SearchResultLeaseID?
    let job = try fixture.submit(
      consumer: consumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { value in
        deliveries.append(value)
        if case .completed(let id) = value { lease = id }
        delivered.fulfill()
      })
    context = nil
    try await requireEvents([waiting])
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    try await fixture.completeSuccess()
    try await requireEvents([delivered])
    let exact = try XCTUnwrap(lease)
    XCTAssertEqual(deliveries, [.completed(exact)])
    XCTAssertEqual(fixture.scopeSnapshot.workerJobs, [job])
    XCTAssertNotNil(witness.value)
    let before = fixture.accountingSnapshot
    XCTAssertEqual(before.active, 2)
    XCTAssertEqual(before.retained, 3)
    XCTAssertEqual(before.reservedRetained, 0)
    var borrows = 0
    let borrowed = service.withResult(exact) { actualContext, source, output in
      borrows += 1
      XCTAssertEqual(ObjectIdentifier(actualContext), identity)
      XCTAssertEqual(actualContext.label, "A😀B𝄞")
      XCTAssertEqual(source, "x")
      XCTAssertEqual(output.matches, [NSRange(location: 0, length: 1)])
      XCTAssertEqual(output.replacement, "y")
      service.release(exact)
      XCTAssertNotNil(witness.value)
      var nestedCalls = 0
      XCTAssertFalse(service.withResult(exact) { _, _, _ in nestedCalls += 1 })
      XCTAssertEqual(nestedCalls, 0)
      XCTAssertEqual(fixture.accountingSnapshot.retained, 3)
    }
    XCTAssertTrue(borrowed)
    XCTAssertEqual(borrows, 1)
    XCTAssertNil(witness.value)
    var staleCalls = 0
    XCTAssertFalse(service.withResult(exact) { _, _, _ in staleCalls += 1 })
    XCTAssertEqual(staleCalls, 0)
    XCTAssertEqual(fixture.accountingSnapshot.retained, 0)
    XCTAssertEqual(fixture.scopeSnapshot.captureReturns, 1)
    XCTAssertEqual(fixture.scopeSnapshot.completionReturns, 1)
    let actual = await fixture.driver.snapshot()
    XCTAssertEqual(actual.submittedHandles.count, 1)
    XCTAssertEqual(actual.returnedWaitHandles, actual.submittedHandles)
    XCTAssertEqual(actual.cancelledHandles, [])
  }

  // Break: facade cancel targets another ID, unregister cancels all consumers,
  // or duplicate forwarding creates two real cancels for one active handle.
  func testActiveCancelAndUnregisterUseExactConsumerAndHandle() async throws {
    let exited = expectation(description: "actual active worker returned")
    let fixture: ServiceFixture<JoinedAdmissionContext> = try makeFixture(
      observe: { _ in exited.fulfill() })
    let service = fixture.service
    let activeConsumer = fixture.register()
    let survivingConsumer = fixture.register()
    let waiting = expectation(description: "active job actual wait")
    let cancelling = expectation(description: "exact active cancel independently held")
    await fixture.driver.backing.configureAccepted(
      holdCancel: true, onWait: { waiting.fulfill() }, onCancel: { cancelling.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    var cancelledCompletions = 0
    let active = try fixture.submit(
      consumer: activeConsumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext()) },
      completion: { _ in cancelledCompletions += 1 })
    try await requireEvents([waiting])
    service.cancel(active)
    try await requireEvents([cancelling])
    service.unregister(activeConsumer)
    XCTAssertThrowsError(
      try fixture.submit(
        consumer: activeConsumer, descriptor: JoinedAdmissionValues.descriptor(),
        capture: { throw SearchAdmissionFailure.captureRefused },
        completion: { _ in XCTFail("unregistered consumer completed") })
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .unknownConsumer) }
    let survivorDelivered = expectation(description: "different consumer still usable")
    var survivorCaptures = 0
    _ = try fixture.submit(
      consumer: survivingConsumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: {
        survivorCaptures += 1
        throw SearchAdmissionFailure.captureRefused
      },
      completion: {
        XCTAssertEqual($0, .failed(.captureRefused))
        survivorDelivered.fulfill()
      })
    let held = await fixture.driver.snapshot()
    XCTAssertEqual(held.submittedHandles.count, 1)
    XCTAssertEqual(held.waitedHandles, held.submittedHandles)
    XCTAssertEqual(held.cancelledHandles, held.submittedHandles)
    XCTAssertEqual(held.returnedWaitHandles, [])
    XCTAssertEqual(held.returnedCancelHandles, [])
    XCTAssertEqual(survivorCaptures, 0)
    await fixture.driver.backing.completeFailure()
    try await requireEvents([exited])
    let cancelHeld = await fixture.driver.snapshot()
    XCTAssertEqual(cancelHeld.returnedWaitHandles, held.submittedHandles)
    XCTAssertEqual(cancelHeld.returnedCancelHandles, [])
    XCTAssertEqual(survivorCaptures, 0)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    let cancelReturned = expectation(description: "real exact cancel returned")
    await fixture.driver.onNextCancelReturn { cancelReturned.fulfill() }
    await fixture.driver.backing.releaseCancel()
    try await requireEvents([cancelReturned, survivorDelivered])
    XCTAssertEqual(cancelledCompletions, 0)
    XCTAssertEqual(survivorCaptures, 1)
    XCTAssertEqual(fixture.scopeSnapshot.workerJobs, [active])
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.submittedHandles, held.submittedHandles)
    XCTAssertEqual(final.waitedHandles, held.submittedHandles)
    XCTAssertEqual(final.returnedWaitHandles, held.submittedHandles)
    XCTAssertEqual(final.cancelledHandles, held.submittedHandles)
    XCTAssertEqual(final.returnedCancelHandles, held.submittedHandles)
  }

  // Break: facade upgrades raw parent refusal or rewrites pending settlement;
  // caching the first DTO also fails the independently refreshed second value.
  func testRawParentRefusalAndFreshSettlementAreForwarded() async throws {
    let fixture: ServiceFixture<JoinedAdmissionContext> = try makeFixture()
    let service = fixture.service
    let raw: SearchParentJoinedShutdownResult = .callerRefused(.legacyModeSelected)
    await fixture.driver.configureJoin(raw)
    await fixture.driver.configureCurrentQuery(.success(.pending))
    let first = try observed(await service.shutdownJoined())
    XCTAssertEqual(first.parent, raw)
    XCTAssertEqual(first.driverSettlement, .pending)
    assertResidual(first, jobs: 0, leases: 0, active: 2, retained: 0, reserved: 0)
    let initial = await fixture.driver.snapshot()
    XCTAssertEqual(initial.joinCalls, 1)
    XCTAssertEqual(initial.legacyCalls, 0)
    XCTAssertEqual(initial.queryCalls, 1)
    XCTAssertEqual(initial.queryReturns, 1)
    XCTAssertNil(initial.lastJoinHandle)
    await fixture.driver.configureCurrentQuery(.success(.settled(admissionClosed: true)))
    let second = try observed(await service.shutdownJoined())
    XCTAssertEqual(second.parent, raw)
    XCTAssertEqual(second.parent, first.parent)
    XCTAssertEqual(second.driverSettlement, .settled(admissionClosed: true))
    assertResidual(second, jobs: 0, leases: 0, active: 2, retained: 0, reserved: 0)
    XCTAssertEqual(first.parent, raw)
    XCTAssertEqual(first.driverSettlement, .pending)
    assertResidual(first, jobs: 0, leases: 0, active: 2, retained: 0, reserved: 0)
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.joinCalls, 1)
    XCTAssertEqual(final.legacyCalls, 0)
    XCTAssertEqual(final.queryCalls, 2)
    XCTAssertEqual(final.queryReturns, 2)
    XCTAssertEqual(final.submittedHandles, [])
    XCTAssertEqual(fixture.scopeSnapshot.captureEntries, 0)
    XCTAssertEqual(fixture.scopeSnapshot.preparationEntries, 0)
  }

  // Break: facade mutates unsupported/legacy controllers into joined mode,
  // closes admission on unsupported refusal, or starts a new parent join.
  func testUnsupportedAndLegacyControllerRefusalsAreForwarded() async throws {
    let unsupported: ServiceFixture<JoinedAdmissionContext> = try makeFixture(joining: false)
    let consumer = unsupported.register()
    let refused = await unsupported.service.shutdownJoined()
    XCTAssertEqual(refused, .callerRefused(.unsupportedDriver))
    XCTAssertEqual(unsupported.accountingSnapshot.active, 2)
    let before = await unsupported.driver.backing.shutdownCalls
    XCTAssertEqual(before, 0)
    await unsupported.driver.backing.setSettlement(.settled(admissionClosed: false))
    let usable = expectation(description: "ordinary submit usable after unsupported refusal")
    var captures = 0
    _ = try unsupported.submit(
      consumer: consumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: {
        captures += 1
        throw SearchAdmissionFailure.captureRefused
      },
      completion: {
        XCTAssertEqual($0, .failed(.captureRefused))
        usable.fulfill()
      })
    try await requireEvents([usable])
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(unsupported.scopeSnapshot.successfulCaptureReturns, 0)
    let after = await unsupported.driver.backing.shutdownCalls
    XCTAssertEqual(after, 0)
    let unsupportedCalls = await unsupported.driver.snapshot()
    XCTAssertEqual(unsupportedCalls.joinCalls, 0)

    let legacy: ServiceFixture<JoinedAdmissionContext> = try makeFixture()
    let entered = expectation(description: "actual legacy setup command held")
    await legacy.driver.backing.configureShutdown(hold: true, onShutdown: { entered.fulfill() })
    let setup = legacy.selectLegacyForSetup()
    try await requireEvents([entered])
    let first = await legacy.service.shutdownJoined()
    XCTAssertEqual(first, .callerRefused(.legacyModeSelected))
    await legacy.driver.backing.releaseShutdown()
    _ = await setup.value
    let second = await legacy.service.shutdownJoined()
    XCTAssertEqual(second, .callerRefused(.legacyModeSelected))
    let legacyCalls = await legacy.driver.snapshot()
    XCTAssertEqual(legacyCalls.joinCalls, 0)
    XCTAssertEqual(legacyCalls.legacyCalls, 1)
    XCTAssertEqual(legacyCalls.legacyReceipts.count, 1)
    XCTAssertEqual(legacy.scopeSnapshot.captureEntries, 0)
  }

  // Break: facade creates/cancels another owner or returns a fabricated cached
  // receipt before the actual late submit, sole wait and cancel return.
  func testMatchingCancelledFacadeCallersShareActualOwner() async throws {
    let prepared = expectation(description: "real preparation held")
    let gate = JoinedAdmissionGate(entered: { prepared.fulfill() })
    let fixture: ServiceFixture<JoinedAdmissionContext> = try makeFixture(preparationGate: gate)
    let consumer = fixture.register()
    let submitted = expectation(description: "actual late submit held")
    let waiting = expectation(description: "late handle sole wait held")
    let cancelling = expectation(description: "late handle exact cancel held")
    await fixture.driver.backing.configureAccepted(
      holdSubmit: true, holdCancel: true, onSubmit: { submitted.fulfill() },
      onWait: { waiting.fulfill() }, onCancel: { cancelling.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    var completions = 0
    let job = try fixture.submit(
      consumer: consumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext()) },
      completion: { _ in completions += 1 })
    try await requireEvents([prepared])
    XCTAssertEqual(fixture.scopeSnapshot.preparationEntries, 1)
    XCTAssertEqual(fixture.scopeSnapshot.preparationReturns, 0)
    XCTAssertEqual(fixture.scopeSnapshot.outstandingRequests, 1)
    await gate.release()
    try await requireEvents([submitted])
    let parent = JoinedAdmissionValues.completed()
    let joined = expectation(description: "one actual parent owner genuinely held")
    await fixture.driver.configureJoin(parent, hold: true, onEntered: { joined.fulfill() })
    let firstEntered = expectation(description: "first facade caller entered")
    let first = fixture.close(entered: firstEntered)
    try await requireEvents([firstEntered])
    let secondEntered = expectation(description: "matching facade caller entered")
    let second = fixture.close(entered: secondEntered)
    try await requireEvents([secondEntered])
    second.cancel()
    let late = await fixture.driver.snapshot()
    XCTAssertEqual(late.joinCalls, 0)
    XCTAssertEqual(late.submittedHandles, [])
    await fixture.driver.backing.releaseSubmit()
    try await requireEvents([waiting, cancelling])
    let bothHeld = await fixture.driver.snapshot()
    XCTAssertEqual(bothHeld.joinCalls, 0)
    XCTAssertEqual(bothHeld.submittedHandles.count, 1)
    XCTAssertEqual(bothHeld.waitedHandles, bothHeld.submittedHandles)
    XCTAssertEqual(bothHeld.cancelledHandles, bothHeld.submittedHandles)
    XCTAssertEqual(bothHeld.returnedWaitHandles, [])
    XCTAssertEqual(bothHeld.returnedCancelHandles, [])
    let cancelReturned = expectation(description: "actual cancel returned independently")
    await fixture.driver.onNextCancelReturn { cancelReturned.fulfill() }
    await fixture.driver.backing.releaseCancel()
    try await requireEvents([cancelReturned])
    let waitHeld = await fixture.driver.snapshot()
    XCTAssertEqual(waitHeld.joinCalls, 0)
    XCTAssertEqual(waitHeld.returnedCancelHandles, bothHeld.submittedHandles)
    XCTAssertEqual(waitHeld.returnedWaitHandles, [])
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    await fixture.driver.backing.completeFailure()
    try await requireEvents([joined])
    let parentHeld = await fixture.driver.snapshot()
    XCTAssertEqual(parentHeld.joinCalls, 1)
    XCTAssertEqual(parentHeld.lastJoinHandle, bothHeld.submittedHandles.first)
    XCTAssertEqual(parentHeld.returnedWaitHandles, bothHeld.submittedHandles)
    XCTAssertEqual(parentHeld.returnedCancelHandles, bothHeld.submittedHandles)
    XCTAssertEqual(parentHeld.joinEntryCancellation, [false])
    XCTAssertEqual(fixture.scopeSnapshot.workerJobs, [job])
    await fixture.driver.releaseJoin()
    let a = try observed(await first.value)
    let b = try observed(await second.value)
    XCTAssertEqual(a.parent, parent)
    XCTAssertEqual(b.parent, parent)
    XCTAssertEqual(a.parent, b.parent)
    XCTAssertEqual(a.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(b.driverSettlement, .settled(admissionClosed: true))
    assertResidual(a, jobs: 0, leases: 0, active: 2, retained: 0, reserved: 0)
    assertResidual(b, jobs: 0, leases: 0, active: 2, retained: 0, reserved: 0)
    XCTAssertEqual(completions, 0)
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.joinCalls, 1)
    XCTAssertEqual(final.legacyCalls, 0)
    XCTAssertEqual(final.joinEntryCancellation, [false])
    XCTAssertEqual(final.joinReturnCancellation, [false])
    XCTAssertEqual(final.joinCancellationCallbacks, 0)
    let waitReturn = try XCTUnwrap(final.events.firstIndex(of: "wait.return"))
    let cancelReturn = try XCTUnwrap(final.events.firstIndex(of: "cancel.return"))
    let joinEntry = try XCTUnwrap(final.events.firstIndex(of: "join.enter"))
    XCTAssertLessThan(waitReturn, joinEntry)
    XCTAssertLessThan(cancelReturn, joinEntry)
  }

  /// Teardown installation is synchronous immediately after construction and
  /// precedes configuration, caller creation and every suspension in each test.
  private func makeFixture<Context>(
    joining: Bool = true, preparationGate: JoinedAdmissionGate? = nil,
    observe: (@MainActor (SearchAdmissionEvent) -> Void)? = nil
  ) throws -> ServiceFixture<Context> {
    let fixture = try ServiceFixture<Context>(
      joining: joining, preparationGate: preparationGate, observe: observe)
    addTeardownBlock {
      let cleanup = await fixture.cleanup()
      XCTAssertEqual(cleanup.scopes.captureEntries, cleanup.scopes.captureReturns)
      XCTAssertEqual(cleanup.scopes.outstandingRequests, 0)
      XCTAssertEqual(cleanup.scopes.preparationEntries, cleanup.scopes.preparationReturns)
      XCTAssertEqual(cleanup.scopes.workerJobs.count, cleanup.scopes.successfulCaptureReturns)
      XCTAssertEqual(cleanup.scopes.unexpectedWorkerReturns, 0)
      XCTAssertEqual(cleanup.reservedCallers, cleanup.installedCallers)
      XCTAssertEqual(cleanup.installedCallers, cleanup.joinedCallers)
      XCTAssertTrue(cleanup.terminalFenceReserved)
      XCTAssertTrue(cleanup.terminalFenceInstalled)
      XCTAssertTrue(cleanup.terminalFenceJoined)
      if cleanup.terminalFenceKind == .requestlessLegacy {
        XCTAssertEqual(cleanup.scopes.successfulCaptureReturns, 0)
        XCTAssertEqual(cleanup.scopes.preparationEntries, 0)
        XCTAssertEqual(cleanup.scopes.preparationReturns, 0)
        XCTAssertEqual(cleanup.scopes.workerJobs.count, 0)
        XCTAssertEqual(cleanup.backendSubmitCalls, 0)
        XCTAssertEqual(cleanup.backendWaitCalls, 0)
        XCTAssertEqual(cleanup.backendCancelCalls, 0)
      }
      XCTAssertEqual(cleanup.completedHandlesNeedingCleanup, cleanup.fixtureCompletedCancels)
      XCTAssertEqual(cleanup.driver.submittedHandles, cleanup.driver.returnedWaitHandles)
      XCTAssertEqual(cleanup.driver.submittedHandles, cleanup.driver.returnedCancelHandles)
      XCTAssertEqual(cleanup.driver.cancelledHandles, cleanup.driver.returnedCancelHandles)
      XCTAssertEqual(cleanup.driver.inFlightScopes, 0)
      XCTAssertEqual(cleanup.driver.scopeEntriesAfterSeal, 0)
      XCTAssertTrue(cleanup.registration.sealed)
      XCTAssertEqual(cleanup.registration.registered, cleanup.registration.joined)
      XCTAssertEqual(cleanup.registration.registrationsAfterSeal, 0)
    }
    return fixture
  }

  private func requireEvents(
    _ events: [XCTestExpectation], file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let result = await XCTWaiter.fulfillment(of: events, timeout: 2)
    guard result == .completed else {
      XCTFail("required actual fixture event was not reached: \(result)", file: file, line: line)
      throw TestFailure.eventNotReached
    }
  }

  private func observed(
    _ result: SearchAdmissionJoinedShutdownResult,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> SearchAdmissionJoinedShutdownObservation {
    guard case .observed(let value) = result else {
      XCTFail("facade must forward an actual observed value: \(result)", file: file, line: line)
      throw TestFailure.observationMissing
    }
    return value
  }

  private func assertResidual(
    _ value: SearchAdmissionJoinedShutdownObservation,
    jobs: Int, leases: Int, active: UInt64, retained: UInt64, reserved: UInt64,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(value.retainedActiveJobs, jobs, file: file, line: line)
    XCTAssertEqual(value.retainedLeases, leases, file: file, line: line)
    XCTAssertEqual(value.activeCharge, active, file: file, line: line)
    XCTAssertEqual(value.retainedCharge, retained, file: file, line: line)
    XCTAssertEqual(value.reservedRetainedCharge, reserved, file: file, line: line)
  }
}
