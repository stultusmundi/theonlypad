import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Task1: real accounting/controller/ledger, scripted driver and manual retry.
/// Maximum estimates charge tiny captures; no large-document or helper execution.
@MainActor final class SearchAdmissionProductionIntegrationTests: XCTestCase {
  func testTwoTinyResultsRetainMaximumCeilingsAndThirdRefusesBeforeCapture() async throws {
    let h = try budgetFixture()
    let first = try await publishTiny(h, context: "first", priorRetained: 0)
    let second = try await publishTiny(h, context: "second", priorRetained: 601_604_096)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(h.scopes.captures, 2)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(
        active: 1_048_576, retained: 1_203_208_192, reservedRetained: 0,
        reservationCount: 0, leaseCount: 2))
    let before = h.owner.accountingSnapshot
    var refusedCaptures = 0
    var deliveries: [SearchAdmissionDelivery] = []
    let refused = expectation(description: "third future retained ceiling exceeds budget")
    _ = try h.owner.submit(
      consumer: h.owner.register(), descriptor: maximumEstimate(),
      capture: {
        refusedCaptures += 1
        XCTFail("Budget refusal must precede capture")
        return .init(text: "x", inputUTF16: 1, context: "must not capture")
      },
      completion: {
        deliveries.append($0)
        refused.fulfill()
      })
    await fulfillment(of: [refused], timeout: 2)
    XCTAssertEqual(deliveries, [.failed(.resultBudget)])
    XCTAssertEqual(refusedCaptures, 0)
    XCTAssertEqual(h.owner.accountingSnapshot, before)
    let submits = await h.driver.submitCalls
    XCTAssertEqual(submits, 2)
    assertTinyLease(first, context: "first", owner: h.owner)
    assertTinyLease(second, context: "second", owner: h.owner)
    XCTAssertEqual(h.owner.accountingSnapshot, before)
    h.owner.release(first)
    h.owner.release(first)
    XCTAssertFalse(h.owner.withResult(first) { _, _, _ in XCTFail("Released first lease") })
    assertTinyLease(second, context: "second", owner: h.owner)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(
        active: 1_048_576, retained: 601_604_096, reservedRetained: 0,
        reservationCount: 0, leaseCount: 1))
    h.owner.release(second)
    h.owner.release(second)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
  }

  func testProductionRetainedCreditSurvivesReentrantReleaseUntilBorrowReturns() async throws {
    let h = try budgetFixture()
    let lease = try await publishTiny(h, context: "borrowed", priorRetained: 0)
    let before = h.owner.accountingSnapshot
    XCTAssertTrue(
      h.owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, "borrowed")
        XCTAssertEqual(source, "x")
        XCTAssertEqual(output, .init(matches: [NSRange(location: 0, length: 1)], replacement: "y"))
        h.owner.release(lease)
        h.owner.release(lease)
        XCTAssertFalse(
          h.owner.withResult(lease) { _, _, _ in XCTFail("Immediately invalidated lease") })
        XCTAssertEqual(h.owner.accountingSnapshot, before)
        XCTAssertEqual(h.owner.accountingSnapshot.retained, 601_604_096)
      })
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
  }

  private func budgetFixture() throws -> ProductionBudgetFixture {
    let h = try ProductionBudgetFixture()
    // Registered immediately, including any later assertion/setup failure path.
    addTeardownBlock { await self.closeBudgetFixture(h) }
    return h
  }

  private func publishTiny(
    _ h: ProductionBudgetFixture, context: String, priorRetained: UInt64
  ) async throws -> SearchResultLeaseID {
    await h.driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "scripted sole wait installed for \(context)")
    await h.driver.configureAccepted(onWait: { waiting.fulfill() })
    let pending = expectation(description: "provisional result waits for adopted settlement")
    h.retry.onSchedule = { pending.fulfill() }
    let completed = expectation(description: "tiny result lease published for \(context)")
    var deliveries: [SearchAdmissionDelivery] = []
    let priorWaits = await h.driver.waitCalls
    _ = try h.owner.submit(
      consumer: h.owner.register(), descriptor: maximumEstimate(),
      capture: {
        h.scopes.captures += 1
        h.scopes.pendingExit = XCTestExpectation(
          description: "actual preparation/wait scope exited")
        return .init(text: "x", inputUTF16: 1, context: context)
      },
      completion: {
        deliveries.append($0)
        completed.fulfill()
      })
    await fulfillment(of: [waiting], timeout: 2)
    let actualWaits = await h.driver.waitCalls
    guard actualWaits == priorWaits + 1 else {
      XCTFail("Cannot complete a scripted result before its real wait is installed")
      throw ProductionBudgetTestFailure.waitNotInstalled
    }
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(
        active: 1_216_814_119, retained: priorRetained, reservedRetained: 601_604_096,
        reservationCount: 1, leaseCount: priorRetained == 0 ? 0 : 1))
    try await h.driver.completeSuccess()
    await fulfillment(of: [pending], timeout: 2)
    XCTAssertTrue(deliveries.isEmpty)
    // Tiny actual output does not rebate the declared ceiling before or after publish.
    XCTAssertEqual(h.owner.accountingSnapshot.active, 1_216_814_119)
    XCTAssertEqual(h.owner.accountingSnapshot.retained, priorRetained)
    XCTAssertEqual(h.owner.accountingSnapshot.reservedRetained, 601_604_096)
    XCTAssertNil(h.scopes.pendingExit)
    await h.driver.setSettlement(.settled(admissionClosed: false))
    h.retry.onSchedule = nil
    h.retry.fire()
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertEqual(deliveries.count, 1)
    guard case .completed(let lease) = try XCTUnwrap(deliveries.first) else {
      XCTFail("Expected a genuine retained result lease")
      throw ProductionBudgetTestFailure.missingLease
    }
    XCTAssertEqual(h.owner.accountingSnapshot.active, 1_048_576)
    XCTAssertEqual(h.owner.accountingSnapshot.reservedRetained, 0)
    XCTAssertEqual(h.owner.accountingSnapshot.reservationCount, 0)
    return lease
  }

  private func assertTinyLease(
    _ lease: SearchResultLeaseID, context expectedContext: String,
    owner: SearchAdmissionController<String>
  ) {
    XCTAssertTrue(
      owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, expectedContext)
        XCTAssertEqual(source, "x")
        XCTAssertEqual(output, .init(matches: [NSRange(location: 0, length: 1)], replacement: "y"))
      })
  }

  private func closeBudgetFixture(_ h: ProductionBudgetFixture) async {
    h.retry.onSchedule = nil
    // Drain any already held continuation and cover a late wait installed after
    // a failed expectation. No sleep, recursive polling or fabricated joined receipt.
    let driver = h.driver
    await driver.configureAccepted(onWait: { Task { await driver.completeFailure() } })
    await driver.releaseSubmit()
    await driver.releaseCancel()
    await driver.releaseShutdown()
    await driver.completeFailure()
    await driver.setSettlement(.settled(admissionClosed: true))
    let first = await h.owner.shutdown()
    if let pending = h.scopes.pendingExit {
      await fulfillment(of: [pending], timeout: 2)
    }
    await driver.releaseCancel()
    let final = await h.owner.shutdown()
    XCTAssertEqual(final.driver, first.driver)
    // The unchanged scripted driver's historical command receipt is deliberately pending.
    XCTAssertFalse(final.driver.child.stopped)
    XCTAssertFalse(final.driver.child.channelsClosed)
    XCTAssertFalse(final.driver.parentLaneSettled)
    XCTAssertEqual(final.driver.retainedParentLanes, 1)
    XCTAssertEqual(final.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(final.retainedActiveJobs, 0)
    XCTAssertEqual(final.retainedLeases, 0)
    XCTAssertNil(h.scopes.pendingExit)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
    let shutdownCalls = await driver.shutdownCalls
    XCTAssertEqual(shutdownCalls, 1)
    XCTAssertTrue(h.retry.tokens.allSatisfy { $0.action == nil })
    // The temporary late-wait drain captures this actor; remove it after settlement.
    await driver.configureAccepted()
  }

  private func maximumEstimate() throws -> SearchAdmissionDescriptor {
    // Q=T=1 here. This active charge differs from the 4096-unit metadata maximum.
    try SearchAdmissionDescriptor(
      query: .init(pattern: "x", mode: .literal), operation: .replace(template: "y"),
      estimatedInputUTF16: 100_000_000, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 100_000_000, maxOutputUTF16: 100_000_000,
        maxMatches: 100_000, cooperativeMilliseconds: 0))
  }
}

private enum ProductionBudgetTestFailure: Error {
  case waitNotInstalled, missingLease
}

@MainActor private final class ProductionBudgetScopes {
  var captures = 0
  var pendingExit: XCTestExpectation?
}

@MainActor private final class ProductionBudgetFixture {
  let driver: AdmissionScriptedDriver
  let retry: AdmissionManualRetry
  let scopes: ProductionBudgetScopes
  let owner: SearchAdmissionController<String>

  init() throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let scopes = ProductionBudgetScopes()
    self.driver = driver
    self.retry = retry
    self.scopes = scopes
    owner = try SearchAdmissionController(
      driver: driver, accounting: SearchAdmissionProductionAccounting(), retry: retry,
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      },
      observe: { _ in
        scopes.pendingExit?.fulfill()
        scopes.pendingExit = nil
      })
  }
}

/// Task2: direct production retry plus real accounting. The small forwarding
/// collaborators observe existing protocol calls; they never replace an outcome.
@MainActor final class SearchAdmissionProductionRetryIntegrationTests: XCTestCase {
  func testDirectRetryAdvancesObservedPendingDriverThenPublishesExactLease() async throws {
    let backing = AdmissionScriptedDriver()
    let pending = expectation(description: "actual scripted settlement returned pending")
    let forwarded = ProductionPendingSettlementDriver(backing: backing, pending: pending)
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    let h = try scriptedFixture(driver: forwarded, backing: backing, scheduler: scheduler)
    let waiting = expectation(description: "real controller installed scripted wait")
    await backing.configureAccepted(onWait: { waiting.fulfill() })
    let completed = expectation(description: "real retry permits lease publication")
    var deliveries: [SearchAdmissionDelivery] = []
    _ = try h.owner.submit(
      consumer: h.owner.register(), descriptor: tinyRetryDescriptor(),
      capture: {
        h.scopes.beginCapture()
        return .init(text: "x", inputUTF16: 1, context: "direct-retry")
      },
      completion: {
        deliveries.append($0)
        completed.fulfill()
      })
    await fulfillment(of: [pending], timeout: 2)
    XCTAssertEqual(h.scopes.captures, 0)
    XCTAssertEqual(h.owner.accountingSnapshot.active, 1_048_576)
    await backing.setSettlement(.settled(admissionClosed: false))
    await fulfillment(of: [waiting], timeout: 2)
    let waitCalls = await backing.waitCalls
    guard waitCalls == 1 else {
      XCTFail("Scripted wait must be installed before completing its result")
      throw ProductionRetryTestFailure.waitNotInstalled
    }
    XCTAssertEqual(h.scopes.captures, 1)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(
        active: 1_114_163, retained: 0, reservedRetained: 4_118,
        reservationCount: 1, leaseCount: 0))
    let exited = try XCTUnwrap(h.scopes.pendingExit)
    try await backing.completeSuccess()
    await fulfillment(of: [exited], timeout: 2)
    XCTAssertTrue(deliveries.isEmpty)
    XCTAssertEqual(h.owner.accountingSnapshot.active, 1_114_163)
    XCTAssertEqual(h.owner.accountingSnapshot.reservedRetained, 4_118)
    await backing.setSettlement(.settled(admissionClosed: false))
    // No manual retry.fire: only the actual Dispatch scheduler can advance a retry.
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertEqual(deliveries.count, 1)
    guard case .completed(let lease) = try XCTUnwrap(deliveries.first) else {
      return XCTFail("Expected retained controller result")
    }
    XCTAssertTrue(
      h.owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, "direct-retry")
        XCTAssertEqual(source, "x")
        XCTAssertEqual(output, .init(matches: [NSRange(location: 0, length: 1)], replacement: "y"))
      })
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(
        active: 1_048_576, retained: 4_118, reservedRetained: 0,
        reservationCount: 0, leaseCount: 1))
    h.owner.release(lease)
    XCTAssertEqual(h.owner.accountingSnapshot.retained, 0)
  }

  func testCancelWhileForwardedProductionRetryIsScheduledPreventsCaptureAfterSentinel() async throws
  {
    try await withdrawPending(unregister: false)
  }

  func testUnregisterWhileForwardedProductionRetryIsScheduledPreventsCaptureAfterSentinel()
    async throws
  {
    try await withdrawPending(unregister: true)
  }

  func testConcreteRetryAndProductionCollectorPreserveUnicodeAndHeldReadShutdownFacts() async throws
  {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let readReturn = DriverTestGate()
    let connection = DriverTestConnection(cancelledReadReturn: readReturn)
    let observed = ProductionRetryDriverObservation()
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: { SearchParentResponseAccumulator(request: $0) },
      maximumWireBytesPerChild: 1_000_000, observe: { observed.receive($0) })
    let owner = try SearchAdmissionController<String>(
      driver: driver, accounting: SearchAdmissionProductionAccounting(),
      retry: SearchAdmissionDispatchRetryScheduler())
    addTeardownBlock {
      readReturn.open()
      connection.releaseAllGates()
      h.prepareCleanup()
      let first = await owner.shutdown()
      if observed.connection != nil {
        await self.fulfillment(of: [observed.cleanupReleased], timeout: 2)
      }
      let final = await owner.shutdown()
      XCTAssertEqual(final.driver, first.driver)
      XCTAssertEqual(final.driverSettlement, .settled(admissionClosed: true))
      XCTAssertEqual(final.retainedActiveJobs, 0)
      XCTAssertEqual(final.retainedLeases, 0)
    }
    let delivered = expectation(description: "real codec produced Unicode replacement lease")
    var captures = 0
    var deliveries: [SearchAdmissionDelivery] = []
    _ = try owner.submit(
      consumer: owner.register(), descriptor: unicodeRetryDescriptor(),
      capture: {
        captures += 1
        return .init(text: "A😀B", inputUTF16: 4, context: "real-codec")
      },
      completion: {
        deliveries.append($0)
        delivered.fulfill()
      })
    await fulfillment(of: [observed.ticketStored], timeout: 2)
    let ticket = try XCTUnwrap(observed.ticket)
    XCTAssertEqual(h.system.generations, [ticket.1.generation])
    h.system.deliver(generation: ticket.1.generation, pid: 7351, connection: connection)
    await fulfillment(of: [observed.connected], timeout: 2)
    let adopted = try XCTUnwrap(observed.connection)
    XCTAssertEqual(adopted.0, ticket.0)
    XCTAssertEqual(adopted.1, ticket.1.generation)
    XCTAssertEqual(ticket.1.ordinal, 1)
    await connection.waitForWriteCalls(2)
    connection.offer(try DriverTestWire.childHello(generation: ticket.1.generation))
    await connection.waitForWriteCalls(7)
    XCTAssertEqual(
      owner.accountingSnapshot,
      .init(
        active: 1_114_261, retained: 0, reservedRetained: 4_164,
        reservationCount: 1, leaseCount: 0))
    connection.offer(
      try DriverTestWire.success(
        identity: ticket.1, matches: [NSRange(location: 1, length: 2)], replacement: "A💡B"))
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(deliveries.count, 1)
    guard case .completed(let lease) = try XCTUnwrap(deliveries.first) else {
      return XCTFail("Expected real driver/codec result lease")
    }
    XCTAssertTrue(
      owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, "real-codec")
        XCTAssertEqual(Array(source.utf16), [0x41, 0xD83D, 0xDE00, 0x42])
        XCTAssertEqual(output.matches, [NSRange(location: 1, length: 2)])
        XCTAssertEqual(output.replacement.map { Array($0.utf16) }, [0x41, 0xD83D, 0xDCA1, 0x42])
      })
    XCTAssertEqual(owner.accountingSnapshot.active, 1_048_576)
    XCTAssertEqual(owner.accountingSnapshot.retained, 4_164)
    owner.release(lease)
    await connection.waitForReadCalls(3)
    XCTAssertEqual(connection.snapshot.activeReads, 1)
    XCTAssertTrue(observed.releasedGenerations.isEmpty)
    let first = await owner.shutdown()
    await connection.cancelledReadReturning.wait(for: 1)
    XCTAssertTrue(first.driver.child.stopped)
    XCTAssertTrue(first.driver.child.channelsClosed)
    XCTAssertFalse(first.driver.parentLaneSettled)
    XCTAssertEqual(first.driver.retainedParentLanes, 1)
    XCTAssertEqual(first.driverSettlement, .pending)
    XCTAssertEqual(first.retainedActiveJobs, 0)
    XCTAssertEqual(first.retainedLeases, 0)
    XCTAssertEqual(connection.snapshot.activeReads, 1)
    XCTAssertFalse(readReturn.isOpen)
    XCTAssertTrue(observed.releasedGenerations.isEmpty)
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    readReturn.open()
    await fulfillment(of: [observed.released], timeout: 2)
    XCTAssertEqual(observed.releasedGenerations, [ticket.1.generation])
    XCTAssertEqual(connection.snapshot.activeReads, 0)
    let final = await owner.shutdown()
    XCTAssertEqual(final.driver, first.driver)
    XCTAssertEqual(final.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(final.retainedActiveJobs, 0)
    XCTAssertEqual(final.retainedLeases, 0)
    XCTAssertEqual(
      owner.accountingSnapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
    XCTAssertEqual(h.system.launchCount.value, 1)
  }

  private func withdrawPending(unregister: Bool) async throws {
    let backing = AdmissionScriptedDriver()
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    let scheduled = expectation(description: "forwarded real schedule returned its token")
    let observed = ProductionRetryScheduleObservation(scheduler: scheduler, scheduled: scheduled)
    let h = try scriptedFixture(driver: backing, backing: backing, scheduler: observed)
    let consumer = h.owner.register()
    var completions = 0
    let job = try h.owner.submit(
      consumer: consumer, descriptor: tinyRetryDescriptor(),
      capture: {
        h.scopes.beginCapture()
        return .init(text: "x", inputUTF16: 1, context: "withdrawn")
      }, completion: { _ in completions += 1 })
    await fulfillment(of: [scheduled], timeout: 2)
    XCTAssertEqual(h.scopes.captures, 0)
    if unregister {
      h.owner.unregister(consumer)
    } else {
      h.owner.cancel(job)
    }
    await backing.setSettlement(.settled(admissionClosed: false))
    let later = expectation(description: "later uncancelled actual retry callback")
    let sentinel = scheduler.schedule { later.fulfill() }
    defer { sentinel.cancel() }
    await fulfillment(of: [later], timeout: 2)
    XCTAssertEqual(h.scopes.captures, 0)
    XCTAssertEqual(completions, 0)
    let submits = await backing.submitCalls
    XCTAssertEqual(submits, 0)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
    if unregister {
      XCTAssertThrowsError(
        try h.owner.submit(
          consumer: consumer, descriptor: tinyRetryDescriptor(),
          capture: { throw SearchAdmissionFailure.captureRefused }, completion: { _ in })
      ) {
        XCTAssertEqual($0 as? SearchAdmissionFailure, .unknownConsumer)
      }
    }
  }

  private func scriptedFixture(
    driver: any SearchParentWireDriving, backing: AdmissionScriptedDriver,
    scheduler: any SearchAdmissionRetryScheduler
  ) throws -> ProductionRetryScriptedFixture {
    let h = try ProductionRetryScriptedFixture(
      driver: driver, backing: backing, scheduler: scheduler)
    addTeardownBlock { await self.closeScripted(h) }
    return h
  }

  private func closeScripted(_ h: ProductionRetryScriptedFixture) async {
    let backing = h.backing
    await backing.configureAccepted(onWait: { Task { await backing.completeFailure() } })
    await backing.releaseSubmit()
    await backing.releaseCancel()
    await backing.releaseShutdown()
    await backing.completeFailure()
    await backing.setSettlement(.settled(admissionClosed: true))
    let first = await h.owner.shutdown()
    if let pending = h.scopes.cleanupExit {
      await fulfillment(of: [pending], timeout: 2)
    }
    await backing.releaseCancel()
    let final = await h.owner.shutdown()
    XCTAssertEqual(final.driver, first.driver)
    XCTAssertFalse(final.driver.child.stopped)
    XCTAssertEqual(final.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(final.retainedActiveJobs, 0)
    XCTAssertEqual(final.retainedLeases, 0)
    XCTAssertNil(h.scopes.pendingExit)
    XCTAssertNil(h.scopes.cleanupExit)
    XCTAssertEqual(
      h.owner.accountingSnapshot,
      .init(active: 1_048_576, retained: 0, reservedRetained: 0, reservationCount: 0, leaseCount: 0)
    )
    await backing.configureAccepted()  // Remove temporary actor-capturing late-wait drain.
  }

  private func tinyRetryDescriptor() throws -> SearchAdmissionDescriptor {
    try .init(
      query: .init(pattern: "x", mode: .literal), operation: .replace(template: "y"),
      estimatedInputUTF16: 1, scope: nil,
      limits: .init(maxTextUTF16: 8, maxOutputUTF16: 1, maxMatches: 1, cooperativeMilliseconds: 0))
  }

  private func unicodeRetryDescriptor() throws -> SearchAdmissionDescriptor {
    try .init(
      query: .init(pattern: "😀", mode: .literal), operation: .replace(template: "💡"),
      estimatedInputUTF16: 4, scope: nil,
      limits: .init(maxTextUTF16: 8, maxOutputUTF16: 8, maxMatches: 2, cooperativeMilliseconds: 0))
  }
}

private enum ProductionRetryTestFailure: Error { case waitNotInstalled }

/// Observation only: all method arguments, returns and errors come from the original actor.
private actor ProductionPendingSettlementDriver: SearchParentWireDriving {
  let backing: AdmissionScriptedDriver
  let pending: XCTestExpectation
  private var reported = false
  init(backing: AdmissionScriptedDriver, pending: XCTestExpectation) {
    self.backing = backing
    self.pending = pending
  }
  func settlement(after handle: SearchParentWireHandle?) async throws -> SearchParentWireSettlement
  {
    let result = try await backing.settlement(after: handle)
    if result == .pending && !reported {
      reported = true
      pending.fulfill()
    }
    return result
  }
  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle {
    try await backing.submit(job)
  }
  func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome {
    try await backing.wait(for: handle)
  }
  func cancel(_ handle: SearchParentWireHandle) async throws { try await backing.cancel(handle) }
  func discard(_ handle: SearchParentWireHandle) async throws { try await backing.discard(handle) }
  func shutdown() async -> SearchParentWireShutdown { await backing.shutdown() }
}

/// Observe after delegation; action, dispatch transport and returned token stay unchanged.
@MainActor private final class ProductionRetryScheduleObservation: SearchAdmissionRetryScheduler {
  let scheduler: SearchAdmissionDispatchRetryScheduler
  let scheduled: XCTestExpectation
  private var reported = false
  init(scheduler: SearchAdmissionDispatchRetryScheduler, scheduled: XCTestExpectation) {
    self.scheduler = scheduler
    self.scheduled = scheduled
  }
  func schedule(_ action: @escaping @MainActor () -> Void) -> any SearchAdmissionRetryToken {
    let token = scheduler.schedule(action)
    if !reported {
      reported = true
      scheduled.fulfill()
    }
    return token
  }
}

@MainActor private final class ProductionRetryScopes {
  var captures = 0
  var pendingExit: XCTestExpectation?
  var cleanupExit: XCTestExpectation?
  func beginCapture() {
    captures += 1
    pendingExit = XCTestExpectation(description: "actual retry integration worker exited")
    cleanupExit = XCTestExpectation(description: "cleanup observed same worker exit")
  }
}

@MainActor private final class ProductionRetryScriptedFixture {
  let backing: AdmissionScriptedDriver
  let scopes: ProductionRetryScopes
  let owner: SearchAdmissionController<String>
  init(
    driver: any SearchParentWireDriving, backing: AdmissionScriptedDriver,
    scheduler: any SearchAdmissionRetryScheduler
  ) throws {
    self.backing = backing
    let scopes = ProductionRetryScopes()
    self.scopes = scopes
    owner = try SearchAdmissionController(
      driver: driver, accounting: SearchAdmissionProductionAccounting(), retry: scheduler,
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      },
      observe: { _ in
        scopes.pendingExit?.fulfill()
        scopes.cleanupExit?.fulfill()
        scopes.pendingExit = nil
        scopes.cleanupExit = nil
      })
  }
}

private final class ProductionRetryDriverObservation: @unchecked Sendable {
  private struct State {
    var ticket: (UUID, SearchWireIdentity)?
    var connection: (UUID, UUID)?
    var released: [UUID] = []
  }
  private let state = DriverTestLocked(State())
  let ticketStored = XCTestExpectation(description: "actual driver ticket stored")
  let connected = XCTestExpectation(description: "actual driver connection associated")
  let released = XCTestExpectation(description: "actual matching generation session released")
  let cleanupReleased = XCTestExpectation(description: "cleanup observed same session release")
  var ticket: (UUID, SearchWireIdentity)? { state.withValue { $0.ticket } }
  var connection: (UUID, UUID)? { state.withValue { $0.connection } }
  var releasedGenerations: [UUID] { state.withValue { $0.released } }
  func receive(_ event: SearchParentDriverEvent) {
    switch event {
    case .ticketStored(let nonce, let identity):
      state.withValue { $0.ticket = (nonce, identity) }
      ticketStored.fulfill()
    case .connectionAvailable(let nonce, let generation):
      state.withValue { $0.connection = (nonce, generation) }
      connected.fulfill()
    case .sessionReleased(let generation):
      let matched = state.withValue { value in
        value.released.append(generation)
        return value.ticket?.1.generation == generation && value.connection?.1 == generation
      }
      if matched {
        released.fulfill()
        cleanupReleased.fulfill()
      }
    default: break
    }
  }
}
