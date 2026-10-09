import Foundation
import PadCore
import XCTest

@testable import SearchExecution

@MainActor final class SearchAdmissionJoinedShutdownTests: XCTestCase {
  private enum TestFailure: Error { case notObserved, eventNotReached }

  // Break: unsupported entry selects a mode or removes the original consumer.
  func testUnsupportedDriverRefusesWithoutClosingOrConsumingState() async throws {
    let backing = AdmissionScriptedDriver()
    let owner = try SearchAdmissionController<Void>(
      driver: backing, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    addTeardownBlock {
      await backing.releaseSubmit()
      await backing.releaseCancel()
      await backing.releaseShutdown()
      await backing.completeFailure()
      await backing.setSettlement(.settled(admissionClosed: true))
      _ = await owner.shutdown()
    }
    let consumer = owner.register()
    let refused = await owner.shutdownJoined()
    XCTAssertEqual(refused, .callerRefused(.unsupportedDriver))
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    await backing.setSettlement(.settled(admissionClosed: false))
    let delivered = expectation(description: "original consumer usable")
    var captures = 0
    _ = try owner.submit(
      consumer: consumer, descriptor: JoinedAdmissionValues.descriptor(),
      capture: {
        captures += 1
        throw SearchAdmissionFailure.captureRefused
      },
      completion: {
        XCTAssertEqual($0, .failed(.captureRefused))
        delivered.fulfill()
      })
    try await requireEvents([delivered])
    XCTAssertEqual(captures, 1)
    let legacy = await owner.shutdown()
    XCTAssertEqual(legacy.retainedActiveJobs, 0)
    let calls = await backing.shutdownCalls
    XCTAssertEqual(calls, 1)
  }

  // Break: joined entry converts an already-selected legacy command.
  func testLegacyFirstPermanentlyRefusesJoined() async throws {
    let fixture = try makeFixture()
    let entered = expectation(description: "real legacy call held")
    await fixture.driver.backing.configureShutdown(hold: true, onShutdown: { entered.fulfill() })
    let legacy = Task { await fixture.owner.shutdown() }
    fixture.track(legacy)
    try await requireEvents([entered])
    let first = await fixture.owner.shutdownJoined()
    XCTAssertEqual(first, .callerRefused(.legacyModeSelected))
    await fixture.driver.backing.releaseShutdown()
    _ = await legacy.value
    let second = await fixture.owner.shutdownJoined()
    XCTAssertEqual(second, .callerRefused(.legacyModeSelected))
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 0)
    XCTAssertEqual(snapshot.legacyCalls, 1)
  }

  // Break: no-request close guesses a handle or creates a second parent command.
  func testNeverAdmittedJoinUsesNilAndRepeatedCallsShareParentResult() async throws {
    let fixture = try makeFixture()
    let parent = JoinedAdmissionValues.completed()
    await fixture.driver.configureJoin(parent)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let first = try observed(await fixture.owner.shutdownJoined())
    let second = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, parent)
    XCTAssertEqual(second.parent, parent)
    assertCredit(first, jobs: 0, active: 2, reserved: 0)
    assertCredit(second, jobs: 0, active: 2, reserved: 0)
    XCTAssertEqual(first.driverSettlement, .settled(admissionClosed: true))
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 1)
    XCTAssertEqual(snapshot.legacyCalls, 0)
    XCTAssertNil(snapshot.lastJoinHandle)
  }

  // Break: the compatibility API starts legacy work or caches current settlement.
  func testJoinedFirstLegacyUsesOriginalParentShutdownAndCurrentSettlement() async throws {
    let fixture = try makeFixture()
    let parent = JoinedAdmissionValues.completed()
    await fixture.driver.configureJoin(parent)
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.driverSettlement, .pending)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let legacy = await fixture.owner.shutdown()
    guard case .completed(let completion) = parent else { return XCTFail("fixture") }
    XCTAssertEqual(legacy.driver, completion.shutdown)
    XCTAssertEqual(legacy.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(legacy.retainedActiveJobs, 0)
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 1)
    XCTAssertEqual(snapshot.legacyCalls, 0)
    XCTAssertEqual(fixture.retry.tokens.count, 0)
  }

  // Break: a raw legacy-mode parent refusal becomes admitted, or aliases repeat.
  func testParentCallerRefusalRemainsRawAndLegacyAliasIsRetainedOnce() async throws {
    try await callerRefusalAlias(.legacyModeSelected)
  }

  // This is a distinct raw refusal branch: a foreign joined owner is not legacy.
  func testDifferentParentJoinOwnerRefusalRemainsRawAndLegacyAliasIsRetainedOnce() async throws {
    try await callerRefusalAlias(.differentJoinOwner)
  }

  // Break: caller cancellation propagates to the retained parent owner.
  func testMatchingCancelledCallerCannotCancelRetainedOwner() async throws {
    try await cancelledCallerIsolation(initiating: false)
  }

  func testInitiatingCancelledCallerCannotCancelRetainedOwner() async throws {
    try await cancelledCallerIsolation(initiating: true)
  }

  private func cancelledCallerIsolation(initiating: Bool) async throws {
    let fixture = try makeFixture()
    let parent = JoinedAdmissionValues.completed()
    let entered = expectation(description: "parent join genuinely held")
    await fixture.driver.configureJoin(parent, hold: true, onEntered: { entered.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let first = fixture.close()
    try await requireEvents([entered])
    let matchingEntered = expectation(description: "matching caller entered")
    let matching = fixture.close(entered: matchingEntered)
    try await requireEvents([matchingEntered])
    if initiating { first.cancel() } else { matching.cancel() }
    let held = await fixture.driver.snapshot()
    XCTAssertEqual(held.joinCalls, 1)
    XCTAssertEqual(held.joinEntryCancellation, [false])
    await fixture.driver.releaseJoin()
    let a = try observed(await first.value)
    let b = try observed(await matching.value)
    XCTAssertEqual(a.parent, parent)
    XCTAssertEqual(b.parent, parent)
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.joinCalls, 1)
    XCTAssertEqual(final.joinEntryCancellation, [false])
    XCTAssertEqual(final.joinReturnCancellation, [false])
    XCTAssertEqual(final.joinCancellationCallbacks, 0)
    XCTAssertEqual(final.waitedHandles.count, 0)
    XCTAssertEqual(final.cancelledHandles.count, 0)
  }

  // Cleanup controls deliberately never await the candidate terminal receipt
  // before rescuing: the ignored early-join control must not authenticate drain.
  func testCleanupDrainsHeldPreparationWithoutTrustingJoinedReceipt() async throws {
    let entered = expectation(description: "cleanup preparation genuinely held")
    let gate = JoinedAdmissionGate(entered: { entered.fulfill() })
    let fixture = try makeFixture(prepare: { _, _, _, _ in
      await gate.wait()
      return true
    })
    fixture.gates.append(gate)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    _ = try submitContext(fixture)
    try await requireEvents([entered])
    let callerEntered = expectation(description: "terminal caller before prep rescue")
    _ = fixture.close(entered: callerEntered)
    try await requireEvents([callerEntered])
    let cleanup = await fixture.rescue()
    XCTAssertEqual(cleanup.scopes.capturedRequests, 1)
    XCTAssertEqual(cleanup.scopes.preparationEntries, 1)
    XCTAssertEqual(cleanup.scopes.preparationReturns, 1)
    XCTAssertEqual(cleanup.scopes.workerReturns, 1)
    XCTAssertEqual(cleanup.scopes.outstandingRequests, 0)
    XCTAssertEqual(cleanup.driver.submittedHandles.count, 0)
    XCTAssertEqual(cleanup.driver.inFlightScopes, 0)
    XCTAssertEqual(cleanup.trackedCallerReturns, 1)
    XCTAssertTrue(cleanup.registration.sealed)
    XCTAssertEqual(cleanup.registration.registered, 0)
    XCTAssertEqual(cleanup.registration.joined, 0)
    XCTAssertEqual(cleanup.registration.registrationsAfterSeal, 0)
    let after = await fixture.driver.snapshot()
    XCTAssertEqual(after.scopeEntriesAfterSeal, 0)
  }

  func testCleanupIncludesLateWaiterRescueBeforeRegistrationSeal() async throws {
    let fixture = try makeFixture()
    let submitted = expectation(description: "cleanup late submit genuinely held")
    await fixture.driver.backing.configureAccepted(
      holdSubmit: true, holdCancel: true, onSubmit: { submitted.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    _ = try submitContext(fixture)
    try await requireEvents([submitted])
    let callerEntered = expectation(description: "terminal caller before late waiter rescue")
    _ = fixture.close(entered: callerEntered)
    try await requireEvents([callerEntered])
    let cleanup = await fixture.rescue()
    XCTAssertEqual(cleanup.scopes.capturedRequests, 1)
    XCTAssertEqual(cleanup.scopes.preparationEntries, 1)
    XCTAssertEqual(cleanup.scopes.preparationReturns, 1)
    XCTAssertEqual(cleanup.scopes.workerReturns, 1)
    XCTAssertEqual(cleanup.scopes.outstandingRequests, 0)
    XCTAssertEqual(cleanup.driver.submittedHandles.count, 1)
    XCTAssertEqual(cleanup.driver.returnedWaitHandles, cleanup.driver.submittedHandles)
    XCTAssertEqual(cleanup.driver.returnedCancelHandles, cleanup.driver.submittedHandles)
    XCTAssertEqual(cleanup.driver.inFlightScopes, 0)
    XCTAssertEqual(cleanup.trackedCallerReturns, 1)
    // Exactly one real late waiter registration must be included, then joined,
    // before sealing. An empty task snapshot cannot satisfy this assertion.
    XCTAssertTrue(cleanup.registration.sealed)
    XCTAssertEqual(cleanup.registration.registered, 1)
    XCTAssertEqual(cleanup.registration.joined, 1)
    XCTAssertEqual(cleanup.registration.registrationsAfterSeal, 0)
    let after = await fixture.driver.snapshot()
    XCTAssertEqual(after.scopeEntriesAfterSeal, 0)
    XCTAssertEqual(after.waitedHandles.count, 1)
    XCTAssertEqual(after.cancelledHandles.count, 1)
  }

  // Break: queued closures survive terminal selection or capture starts after it.
  func testCloseFencesQueuedCapturesAndReleasesQueuedWeakOwners() async throws {
    let fixture = try makeFixture()
    var captureOwner: JoinedAdmissionContext? = JoinedAdmissionContext()
    var completionOwner: JoinedAdmissionContext? = JoinedAdmissionContext()
    let weakCapture = AdmissionWeakBox(captureOwner)
    let weakCompletion = AdmissionWeakBox(completionOwner)
    var captures = 0
    var deliveries = 0
    _ = try fixture.submit(
      consumer: fixture.owner.register(), descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [captureOwner] in
        captures += 1
        return .init(text: "x", inputUTF16: 1, context: captureOwner!)
      },
      completion: { [completionOwner] _ in
        withExtendedLifetime(completionOwner) { deliveries += 1 }
      })
    captureOwner = nil
    completionOwner = nil
    XCTAssertNotNil(weakCapture.value)
    XCTAssertNotNil(weakCompletion.value)
    // Direct entry runs close selection before its first suspension; the
    // already-created advisory Task cannot capture while this stack is live.
    _ = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(deliveries, 0)
    XCTAssertNil(weakCapture.value)
    XCTAssertNil(weakCompletion.value)
    assertSubmitClosed(fixture.owner)
  }

  // Break: no-attempt preparation retirement rebates while its real scope lives.
  func testHeldPreparationRetainsCreditUntilItsActualOuterReturn() async throws {
    let entered = expectation(description: "preparation held")
    let exited = expectation(description: "actual worker exited")
    let gate = JoinedAdmissionGate(entered: { entered.fulfill() })
    let fixture = try makeFixture(
      prepare: { _, _, _, _ in
        await gate.wait()
        return true
      },
      observe: { _ in exited.fulfill() })
    fixture.gates.append(gate)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    let witness = try submitContext(fixture)
    try await requireEvents([entered])
    let closingEntered = expectation(description: "joined caller entered")
    let closing = fixture.close(entered: closingEntered)
    try await requireEvents([closingEntered])
    XCTAssertNotNil(witness.value)
    assertReservation(fixture.owner)
    let before = await fixture.driver.snapshot()
    XCTAssertEqual(before.joinCalls, 0)
    assertSubmitClosed(fixture.owner)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    await gate.release()
    try await requireEvents([exited])
    let final = try observed(await closing.value)
    assertCredit(final, jobs: 0, active: 2, reserved: 0)
    XCTAssertNil(witness.value)
    let after = await fixture.driver.snapshot()
    XCTAssertEqual(after.submittedHandles.count, 0)
    XCTAssertEqual(after.joinCalls, 1)
    XCTAssertNil(after.lastJoinHandle)
  }

  // Break: nil/stale join, duplicate wait, or join before exact cancel returns.
  func testLateSubmitHandleDrainsSoleWaitAndExactCancellationBeforeJoin() async throws {
    try await lateHandleDrain(cancelFirst: false)
  }

  // Independently discriminates awaiting only cancellation and abandoning wait.
  func testLateSubmitHandleStillAwaitsSoleWaitAfterExactCancellationReturns() async throws {
    try await lateHandleDrain(cancelFirst: true)
  }

  // Break: an old query publishes a ready result or rebates credit during close.
  func testPrecloseQueryCannotPublishOrRetireAfterJoinedSelection() async throws {
    try await precloseQueryFence(throwing: false)
  }

  // A pre-close thrown advisory query must be drained/fenced too; this is
  // independent of the post-parent current-query failure below.
  func testThrownPrecloseQueryCannotFailClosedOrRetireAfterJoinedSelection() async throws {
    try await precloseQueryFence(throwing: true)
  }

  private func precloseQueryFence(throwing: Bool) async throws {
    let exited = expectation(description: "worker returned into held old query")
    let fixture = try makeFixture(observe: { _ in exited.fulfill() })
    let waiting = expectation(description: "sole wait installed")
    await fixture.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    var deliveries = 0
    var context: JoinedAdmissionContext? = JoinedAdmissionContext()
    let witness = AdmissionWeakBox(context)
    _ = try fixture.submit(
      consumer: fixture.owner.register(), descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { _ in deliveries += 1 })
    context = nil
    try await requireEvents([waiting])
    let queryEntered = expectation(description: "preclose query held")
    await fixture.driver.configureQueryHold(onEntered: { queryEntered.fulfill() })
    if throwing { await fixture.driver.configureCurrentQuery(.failure(.notSettled)) }
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    try await fixture.driver.backing.completeSuccess()
    try await requireEvents([exited, queryEntered])
    let start = expectation(description: "close fences query")
    let closing = fixture.close(entered: start)
    try await requireEvents([start])
    assertReservation(fixture.owner)
    let held = await fixture.driver.snapshot()
    XCTAssertEqual(held.joinCalls, 0)
    XCTAssertEqual(deliveries, 0)
    XCTAssertNotNil(witness.value)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    await fixture.driver.configureCurrentQuery(nil)
    await fixture.driver.releaseQuery()
    let result = try observed(await closing.value)
    assertCredit(result, jobs: 0, active: 2, reserved: 0)
    XCTAssertEqual(deliveries, 0)
    XCTAssertNil(witness.value)
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.lastJoinHandle, final.submittedHandles.first)
    XCTAssertEqual(final.submittedHandles.count, 1)
    // Exactly the two pre-close queries returned before parent entry: initial
    // admission inspection, then the held result inspection. The current query
    // belongs after the parent and cannot impersonate this drain.
    let joinIndex = try XCTUnwrap(final.events.firstIndex(of: "join.enter"))
    XCTAssertEqual(final.events[..<joinIndex].filter { $0 == "query.return" }.count, 2)
  }

  // Break: delayed scheduler callbacks defeat the cancelled token identity fence.
  func testDelayedCancelledRetryCannotRestartJoinedAdmission() async throws {
    let fixture = try makeFixture()
    let scheduled = expectation(description: "real retry scheduled")
    fixture.retry.onSchedule = { scheduled.fulfill() }
    var captures = 0
    var deliveries = 0
    _ = try fixture.submit(
      consumer: fixture.owner.register(), descriptor: JoinedAdmissionValues.descriptor(),
      capture: {
        captures += 1
        return .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext())
      }, completion: { _ in deliveries += 1 })
    try await requireEvents([scheduled])
    let original = try XCTUnwrap(fixture.retry.tokens.first?.action)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    _ = try observed(await fixture.owner.shutdownJoined())
    XCTAssertNil(fixture.retry.tokens.first?.action)
    let before = await fixture.driver.snapshot()
    original()
    // A MainActor rendezvous lets already-enqueued illicit inspection run,
    // without time passing being a success condition.
    let rendezvous = Task { @MainActor in }
    fixture.track(rendezvous)
    await rendezvous.value
    let after = await fixture.driver.snapshot()
    XCTAssertEqual(after.queryCalls, before.queryCalls)
    XCTAssertEqual(after.joinCalls, 1)
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(deliveries, 0)
    XCTAssertEqual(fixture.retry.tokens.count, 1)
  }

  // Break: ownership refusal is upgraded when a later query says closed.
  func testOwnershipRefusalRetainsReservationWithoutUpgrade() async throws {
    try await retainedAfterRequest(
      parent: JoinedAdmissionValues.completed(ownership: .refused(.receiptUnconsumed)))
  }

  // Break: failed lane-stop is hidden by admitted ownership/current closure.
  func testLaneFailureRetainsReservationWithoutUpgrade() async throws {
    try await retainedAfterRequest(parent: JoinedAdmissionValues.completed(lane: .failed))
  }

  // Break: parentLaneSettled false is ignored by the retirement gate.
  func testUnsettledParentLaneRetainsReservationWithoutUpgrade() async throws {
    try await retainedAfterRequest(parent: JoinedAdmissionValues.completed(settled: false))
  }

  // Break: attempted-submit errors take the no-attempt rebate path, or a nil
  // final handle incorrectly authenticates refused request ownership.
  func testAttemptedSubmitErrorRetainsReservationUnderRefusedParentOwnership() async throws {
    let exited = expectation(description: "attempted submit error outer return")
    let fixture = try makeFixture(observe: { _ in exited.fulfill() })
    let pending = expectation(description: "attempted error pending inspection")
    fixture.retry.onSchedule = { pending.fulfill() }
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    await fixture.driver.backing.configureUnsettledRefusal()
    _ = try submitContext(fixture)
    try await requireEvents([exited, pending])
    fixture.retry.onSchedule = nil
    assertReservation(fixture.owner)
    let parent = JoinedAdmissionValues.completed(ownership: .refused(.requestActive))
    await fixture.driver.configureJoin(parent)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, parent)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    let later = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(later.parent, parent)
    assertCredit(later, jobs: 1, active: 6, reserved: 3)
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 1)
    XCTAssertNil(snapshot.lastJoinHandle)
    XCTAssertEqual(snapshot.submittedHandles.count, 0)
    XCTAssertEqual(snapshot.events.filter { $0 == "submit.throw" }.count, 1)
    XCTAssertEqual(snapshot.discardCalls, 0)
    let attempts = await fixture.driver.backing.submitCalls
    XCTAssertEqual(attempts, 1)
  }

  // Break: query error is promoted to closure or triggers ordinary failClosed.
  func testThrownSettlementReportsPendingAndKeepsReservation() async throws {
    let fixture = try await drainedRequestFixture()
    let parent = JoinedAdmissionValues.completed()
    await fixture.driver.configureJoin(parent)
    await fixture.driver.configureCurrentQuery(.failure(.notSettled))
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, parent)
    XCTAssertEqual(first.driverSettlement, .pending)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    await fixture.driver.configureCurrentQuery(.success(.settled(admissionClosed: true)))
    let later = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(later.parent, parent)
    assertCredit(later, jobs: 0, active: 2, reserved: 0)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
  }

  // Break: cancelled no-attempt preparation invokes ordinary finishCapture rebate.
  func testCancelledNeverAttemptedPreparationRetainsReservationOnParentRefusal() async throws {
    let entered = expectation(description: "preparation scope held")
    let exited = expectation(description: "preparation genuinely returned")
    let gate = JoinedAdmissionGate(entered: { entered.fulfill() })
    let fixture = try makeFixture(
      prepare: { _, _, _, _ in
        await gate.wait()
        return false
      },
      observe: { _ in exited.fulfill() })
    fixture.gates.append(gate)
    let parent: SearchParentJoinedShutdownResult = .callerRefused(.differentJoinOwner)
    await fixture.driver.configureJoin(parent)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    let witness = try submitContext(fixture)
    try await requireEvents([entered])
    let start = expectation(description: "joined close selected")
    let closing = fixture.close(entered: start)
    try await requireEvents([start])
    XCTAssertNotNil(witness.value)
    assertReservation(fixture.owner)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    await gate.release()
    try await requireEvents([exited])
    let first = try observed(await closing.value)
    XCTAssertEqual(first.parent, parent)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    let later = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(later.parent, parent)
    assertCredit(later, jobs: 1, active: 6, reserved: 3)
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.submittedHandles.count, 0)
    XCTAssertEqual(snapshot.joinCalls, 1)
    // This witness establishes the live preparation capture; its later lifetime
    // is not falsely used as proof that conservative metadata must own Context.
  }

  // Break: pending current facts rebate now, or completed refreshes never refresh.
  func testPendingSettlementRetainsCreditAndLaterObservationRetiresIt() async throws {
    let fixture = try await drainedRequestFixture()
    let parent = JoinedAdmissionValues.completed()
    await fixture.driver.configureJoin(parent)
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.driverSettlement, .pending)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let later = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(later.parent, parent)
    XCTAssertEqual(later.driverSettlement, .settled(admissionClosed: true))
    assertCredit(later, jobs: 0, active: 2, reserved: 0)
    XCTAssertEqual(first.parent, parent)
    XCTAssertEqual(first.driverSettlement, .pending)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 1)
  }

  // Distinct historical child states must survive a newer current observation.
  func testOriginalStoppingChildIsNotReplacedByLaterCurrentSettlement() async throws {
    try await uncertainChild(.stopping(generation: JoinedAdmissionValues.generation))
  }

  func testOriginalStopUnconfirmedChildIsNotReplacedByLaterCurrentSettlement() async throws {
    try await uncertainChild(.stopUnconfirmed(generation: JoinedAdmissionValues.generation))
  }

  // Break: simultaneous callers issue duplicate current queries, or cache forever.
  func testConcurrentRefreshCoalescesHeldQueryButLaterCallIsFresh() async throws {
    let fixture = try makeFixture()
    let parent = JoinedAdmissionValues.completed()
    await fixture.driver.configureJoin(parent)
    let queryEntered = expectation(description: "post-join current query held")
    await fixture.driver.configureQueryHold(onEntered: { queryEntered.fulfill() })
    let first = fixture.close()
    try await requireEvents([queryEntered])
    let matchingEntered = expectation(description: "second refresh caller entered")
    let second = fixture.close(entered: matchingEntered)
    try await requireEvents([matchingEntered])
    let held = await fixture.driver.snapshot()
    XCTAssertEqual(held.queryCalls, 1)
    XCTAssertEqual(held.queryReturns, 0)
    await fixture.driver.releaseQuery()
    let a = try observed(await first.value)
    let b = try observed(await second.value)
    XCTAssertEqual(a.parent, parent)
    XCTAssertEqual(b.parent, parent)
    XCTAssertEqual(a.driverSettlement, .pending)
    XCTAssertEqual(b.driverSettlement, .pending)
    let after = await fixture.driver.snapshot()
    XCTAssertEqual(after.queryCalls, 1)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let fresh = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(fresh.driverSettlement, .settled(admissionClosed: true))
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.queryCalls, 2)
    XCTAssertEqual(final.joinCalls, 1)
  }

  private func makeFixture(
    prepare: @escaping SearchAdmissionPreparing = { _, _, _, _ in true },
    observe: (@MainActor (SearchAdmissionEvent) -> Void)? = nil
  ) throws -> JoinedAdmissionFixture {
    let fixture = try JoinedAdmissionFixture(prepare: prepare, observe: observe)
    // Registered synchronously, before configuration or any suspending setup.
    addTeardownBlock {
      let cleanup = await fixture.rescue()
      XCTAssertEqual(cleanup.scopes.outstandingRequests, 0)
      XCTAssertEqual(cleanup.scopes.preparationEntries, cleanup.scopes.preparationReturns)
      XCTAssertEqual(cleanup.scopes.unexpectedWorkerReturns, 0)
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
      XCTFail("required real fixture event was not reached: \(result)", file: file, line: line)
      throw TestFailure.eventNotReached
    }
  }

  private func observed(
    _ result: SearchAdmissionJoinedShutdownResult,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> SearchAdmissionJoinedShutdownObservation {
    guard case .observed(let value) = result else {
      XCTFail("expected factual observation, got \(result)", file: file, line: line)
      throw TestFailure.notObserved
    }
    return value
  }

  private func assertCredit(
    _ value: SearchAdmissionJoinedShutdownObservation, jobs: Int, active: UInt64, reserved: UInt64,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(value.retainedActiveJobs, jobs, file: file, line: line)
    XCTAssertEqual(value.retainedLeases, 0, file: file, line: line)
    XCTAssertEqual(value.activeCharge, active, file: file, line: line)
    XCTAssertEqual(value.retainedCharge, 0, file: file, line: line)
    XCTAssertEqual(value.reservedRetainedCharge, reserved, file: file, line: line)
  }

  private func assertReservation(
    _ owner: SearchAdmissionController<JoinedAdmissionContext>,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let snapshot = owner.accountingSnapshot
    XCTAssertEqual(snapshot.active, 6, file: file, line: line)
    XCTAssertEqual(snapshot.reservedRetained, 3, file: file, line: line)
    XCTAssertEqual(snapshot.reservationCount, 1, file: file, line: line)
    XCTAssertEqual(snapshot.retained, 0, file: file, line: line)
  }

  private func assertSubmitClosed(
    _ owner: SearchAdmissionController<JoinedAdmissionContext>,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: JoinedAdmissionValues.descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: JoinedAdmissionContext()) },
        completion: { _ in XCTFail("late delivery", file: file, line: line) }),
      file: file, line: line
    ) { XCTAssertEqual($0 as? SearchAdmissionFailure, .shutdown, file: file, line: line) }
  }

  private func submitContext(_ fixture: JoinedAdmissionFixture) throws
    -> AdmissionWeakBox<JoinedAdmissionContext>
  {
    var context: JoinedAdmissionContext? = JoinedAdmissionContext()
    let witness = AdmissionWeakBox(context)
    _ = try fixture.submit(
      consumer: fixture.owner.register(), descriptor: JoinedAdmissionValues.descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { _ in XCTFail("closed/cancelled job must not deliver") })
    context = nil
    return witness
  }

  private func callerRefusalAlias(_ refusal: SearchParentJoinedCallerRefusal) async throws {
    let fixture = try makeFixture()
    let parent: SearchParentJoinedShutdownResult = .callerRefused(refusal)
    await fixture.driver.configureJoin(parent)
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, parent)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let aliasEntered = expectation(description: "genuine exceptional legacy alias held")
    await fixture.driver.backing.configureShutdown(
      hold: true, onShutdown: { aliasEntered.fulfill() })
    let firstAlias = Task { await fixture.owner.shutdown() }
    fixture.track(firstAlias)
    try await requireEvents([aliasEntered])
    let matchingEntered = expectation(description: "matching legacy alias caller entered")
    let matchingAlias = Task {
      matchingEntered.fulfill()
      return await fixture.owner.shutdown()
    }
    fixture.track(matchingAlias)
    try await requireEvents([matchingEntered])
    let held = await fixture.driver.snapshot()
    XCTAssertEqual(held.legacyCalls, 1)
    await fixture.driver.backing.releaseShutdown()
    let a = await firstAlias.value
    let b = await matchingAlias.value
    let actualReturns = await fixture.driver.snapshot()
    XCTAssertEqual(actualReturns.legacyReceipts.count, 1)
    let genuineReceipt = try XCTUnwrap(actualReturns.legacyReceipts.first)
    XCTAssertEqual(a.driver, genuineReceipt)
    XCTAssertEqual(b.driver, genuineReceipt)
    XCTAssertEqual(b.driverSettlement, .settled(admissionClosed: true))
    let repeated = await fixture.owner.shutdown()
    XCTAssertEqual(repeated.driver, genuineReceipt)
    let final = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(final.parent, parent)
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 1)
    XCTAssertEqual(snapshot.legacyCalls, 1)
    XCTAssertEqual(snapshot.events.filter { $0 == "legacy.return" }.count, 1)
  }

  private func lateHandleDrain(cancelFirst: Bool) async throws {
    let exited = expectation(description: "original request helper truly exited")
    let fixture = try makeFixture(observe: { _ in exited.fulfill() })
    let submitted = expectation(description: "submit return held")
    let waiting = expectation(description: "original sole wait installed")
    let cancelling = expectation(description: "exact cancellation held")
    await fixture.driver.backing.configureAccepted(
      holdSubmit: true, holdCancel: true,
      onSubmit: { submitted.fulfill() }, onWait: { waiting.fulfill() },
      onCancel: { cancelling.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    let witness = try submitContext(fixture)
    try await requireEvents([submitted])
    let start = expectation(description: "joined selection before late handle")
    let closing = fixture.close(entered: start)
    try await requireEvents([start])
    let late = await fixture.driver.snapshot()
    XCTAssertEqual(late.joinCalls, 0)
    XCTAssertEqual(late.submittedHandles.count, 0)
    XCTAssertNotNil(witness.value)
    assertReservation(fixture.owner)
    await fixture.driver.backing.releaseSubmit()
    try await requireEvents([waiting, cancelling])
    let bothHeld = await fixture.driver.snapshot()
    XCTAssertEqual(bothHeld.joinCalls, 0)
    XCTAssertEqual(bothHeld.submittedHandles.count, 1)
    XCTAssertEqual(bothHeld.waitedHandles, bothHeld.submittedHandles)
    XCTAssertEqual(bothHeld.cancelledHandles, bothHeld.submittedHandles)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    if cancelFirst {
      let cancelReturned = expectation(description: "exact cancel really returned")
      await fixture.driver.onNextCancelReturn { cancelReturned.fulfill() }
      await fixture.driver.backing.releaseCancel()
      try await requireEvents([cancelReturned])
      let stillWaiting = await fixture.driver.snapshot()
      XCTAssertEqual(stillWaiting.joinCalls, 0)
      XCTAssertNotNil(witness.value)
      await fixture.driver.backing.completeFailure()
      try await requireEvents([exited])
    } else {
      await fixture.driver.backing.completeFailure()
      try await requireEvents([exited])
      let stillCancelling = await fixture.driver.snapshot()
      XCTAssertEqual(stillCancelling.joinCalls, 0)
      assertReservation(fixture.owner)
      await fixture.driver.backing.releaseCancel()
    }
    let result = try observed(await closing.value)
    assertCredit(result, jobs: 0, active: 2, reserved: 0)
    XCTAssertNil(witness.value)
    let final = await fixture.driver.snapshot()
    XCTAssertEqual(final.joinCalls, 1)
    XCTAssertEqual(final.discardCalls, 0)
    XCTAssertEqual(final.submittedHandles.count, 1)
    XCTAssertEqual(final.lastJoinHandle, final.submittedHandles.first)
    XCTAssertEqual(final.waitedHandles.count, 1)
    XCTAssertEqual(final.cancelledHandles.count, 1)
    let joinIndex = try XCTUnwrap(final.events.firstIndex(of: "join.enter"))
    let waitIndex = try XCTUnwrap(final.events.firstIndex(of: "wait.return"))
    let cancelIndex = try XCTUnwrap(final.events.firstIndex(of: "cancel.return"))
    XCTAssertLessThan(waitIndex, joinIndex)
    XCTAssertLessThan(cancelIndex, joinIndex)
  }

  /// Let the original wait/helper return into a genuinely observed pending
  /// inspection. A retained manual token then prevents ordinary progress until
  /// the caller selects joined mode. No completed value is published.
  private func drainedRequestFixture() async throws -> JoinedAdmissionFixture {
    let exited = expectation(description: "request outer return")
    let fixture = try makeFixture(observe: { _ in exited.fulfill() })
    let waiting = expectation(description: "request sole wait")
    await fixture.driver.backing.configureAccepted(onWait: { waiting.fulfill() })
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: false))
    _ = try submitContext(fixture)
    try await requireEvents([waiting])
    let pending = expectation(description: "actual pending inspection retained retry")
    fixture.retry.onSchedule = { pending.fulfill() }
    await fixture.driver.backing.completeFailure()
    try await requireEvents([exited, pending])
    fixture.retry.onSchedule = nil
    assertReservation(fixture.owner)
    return fixture
  }

  private func retainedAfterRequest(parent: SearchParentJoinedShutdownResult) async throws {
    let fixture = try await drainedRequestFixture()
    await fixture.driver.configureJoin(parent)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, parent)
    XCTAssertEqual(first.driverSettlement, .settled(admissionClosed: true))
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    let later = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(later.parent, parent)
    assertCredit(later, jobs: 1, active: 6, reserved: 3)
    let snapshot = await fixture.driver.snapshot()
    XCTAssertEqual(snapshot.joinCalls, 1)
  }

  private func uncertainChild(_ cleanup: SearchChildCleanup) async throws {
    let fixture = try await drainedRequestFixture()
    let parent = JoinedAdmissionValues.completed(
      child: .init(cleanup: cleanup, channelsClosed: false))
    await fixture.driver.configureJoin(parent)
    let first = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(first.parent, parent)
    assertCredit(first, jobs: 1, active: 6, reserved: 3)
    await fixture.driver.backing.setSettlement(.settled(admissionClosed: true))
    let later = try observed(await fixture.owner.shutdownJoined())
    XCTAssertEqual(later.parent, parent)
    XCTAssertEqual(later.driverSettlement, .settled(admissionClosed: true))
    assertCredit(later, jobs: 0, active: 2, reserved: 0)
    XCTAssertEqual(first.parent, parent)
    XCTAssertEqual(first.driverSettlement, .pending)
  }
}
