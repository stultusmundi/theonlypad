import Foundation
import PadCore
import XCTest

@testable import SearchExecution

@MainActor final class SearchAdmissionControllerTests: XCTestCase {
  func testInvalidResidentPolicyIsRejectedAtInitialization() {
    XCTAssertThrowsError(
      try SearchAdmissionController<Void>(
        driver: AdmissionScriptedDriver(),
        accounting: AdmissionTestAccounting(activeLimit: 1, resident: 2),
        retry: AdmissionManualRetry())
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .resultBudget)
    }
  }

  func testUnknownConsumerIsRejectedWithoutCapture() throws {
    let owner = try makeOwner()
    let foreign = SearchConsumerID()
    var captured = false
    XCTAssertThrowsError(
      try owner.submit(
        consumer: foreign, descriptor: descriptor(),
        capture: {
          captured = true
          return .init(text: "x", inputUTF16: 1, context: ())
        }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .unknownConsumer)
    }
    XCTAssertFalse(captured)
  }

  func testEightOutstandingMetadataJobsRefuseNinthWithoutCapture() throws {
    let owner = try makeOwner()
    var captured = 0
    for _ in 0..<8 {
      let consumer = owner.register()
      XCTAssertNoThrow(
        try owner.submit(
          consumer: consumer, descriptor: descriptor(),
          capture: {
            captured += 1
            return .init(text: "x", inputUTF16: 1, context: ())
          }, completion: { _ in }))
    }
    let ninth = owner.register()
    XCTAssertThrowsError(
      try owner.submit(
        consumer: ninth, descriptor: descriptor(),
        capture: {
          captured += 1
          return .init(text: "x", inputUTF16: 1, context: ())
        }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .queueFull)
    }
    XCTAssertEqual(captured, 0)
  }

  func testConsumerCannotQueueSecondJob() throws {
    let owner = try makeOwner()
    let consumer = owner.register()
    XCTAssertNoThrow(
      try owner.submit(
        consumer: consumer, descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in }))
    XCTAssertThrowsError(
      try owner.submit(
        consumer: consumer, descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .consumerBusy)
    }
  }

  func testUnregisterQueuedJobReleasesCapturedOwnerWithoutInvocation() throws {
    final class Sentinel {}
    let owner = try makeOwner()
    let consumer = owner.register()
    var sentinel: Sentinel? = Sentinel()
    let weakSentinel = AdmissionWeakBox(sentinel)
    var captured = false
    XCTAssertNoThrow(
      try owner.submit(
        consumer: consumer, descriptor: descriptor(),
        capture: { [sentinel] in
          _ = sentinel
          captured = true
          return .init(text: "x", inputUTF16: 1, context: ())
        }, completion: { _ in }))
    sentinel = nil
    XCTAssertNotNil(weakSentinel.value)
    owner.unregister(consumer)
    XCTAssertNil(weakSentinel.value)
    XCTAssertFalse(captured)
  }

  func testPendingSettlementSchedulesSingleRetryWithoutCapture() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let scheduled = expectation(description: "retry scheduled")
    retry.onSchedule = { scheduled.fulfill() }
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    var captures = 0
    for _ in 0..<3 {
      _ = try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: {
          captures += 1
          return .init(text: "x", inputUTF16: 1, context: ())
        }, completion: { _ in })
    }
    await fulfillment(of: [scheduled], timeout: 1)
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(retry.tokens.count, 1)
    let calls = await driver.settlementCalls
    XCTAssertEqual(calls, 1)
  }

  func testReservationRefusalDoesNotCaptureAndCompletesCompactFailure() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(activeLimit: 3),
      retry: AdmissionManualRetry())
    let finished = expectation(description: "budget refusal")
    var captures = 0
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        captures += 1
        return .init(text: "x", inputUTF16: 1, context: ())
      },
      completion: {
        XCTAssertEqual($0, .failed(.resultBudget))
        finished.fulfill()
      })
    await fulfillment(of: [finished], timeout: 1)
    XCTAssertEqual(captures, 0)
  }

  func testCaptureThrowIsCompactedAndNextFIFOJobRuns() async throws {
    enum SyntheticFailure: Error { case refused }
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let finished = expectation(description: "both captures refused")
    finished.expectedFulfillmentCount = 2
    var order: [Int] = []
    for index in 0..<2 {
      _ = try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: {
          order.append(index)
          throw SyntheticFailure.refused
        },
        completion: {
          XCTAssertEqual($0, .failed(.captureRefused))
          finished.fulfill()
        })
    }
    await fulfillment(of: [finished], timeout: 1)
    XCTAssertEqual(order, [0, 1])
  }

  func testCancellationInsideCaptureFencesDriverAndRetainsConsumerUntilScopeExit() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let consumer = owner.register()
    let captured = expectation(description: "capture unwound")
    var job: SearchJobID?
    job = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: {
        owner.cancel(job!)
        XCTAssertThrowsError(
          try owner.submit(
            consumer: consumer, descriptor: self.descriptor(),
            capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
        ) {
          XCTAssertEqual($0 as? SearchAdmissionFailure, .consumerBusy)
        }
        captured.fulfill()
        return .init(text: "x", inputUTF16: 1, context: ())
      }, completion: { _ in XCTFail("cancelled callback must be fenced") })
    await fulfillment(of: [captured], timeout: 1)
    let submits = await driver.submitCalls
    XCTAssertEqual(submits, 0)
    XCTAssertNoThrow(
      try owner.submit(
        consumer: consumer, descriptor: descriptor(),
        capture: { throw SearchAdmissionFailure.captureRefused }, completion: { _ in }))
  }

  func testRealPreparationValidatesUnicodeReportedCountGrowthAndScope() async {
    let valid = await SearchAdmissionPreparation.validate(
      text: "😀x", estimate: 3, captured: 3, scope: NSRange(location: 2, length: 1))
    XCTAssertTrue(valid)
    let wrongCount = await SearchAdmissionPreparation.validate(
      text: "😀x", estimate: 3, captured: 2, scope: nil)
    XCTAssertFalse(wrongCount)
    let growth = await SearchAdmissionPreparation.validate(
      text: "😀xy", estimate: 3, captured: 3, scope: nil)
    XCTAssertFalse(growth)
    let badScope = await SearchAdmissionPreparation.validate(
      text: "x", estimate: 3, captured: 1, scope: NSRange(location: 2, length: 1))
    XCTAssertFalse(badScope)
    let overflow = await SearchAdmissionPreparation.validate(
      text: "x", estimate: Int.max, captured: 1, scope: nil)
    XCTAssertFalse(overflow)
  }

  func testCaptureCountMismatchNeverSubmitsDriver() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let finished = expectation(description: "mismatch rejected")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "xx", inputUTF16: 1, context: ()) },
      completion: {
        XCTAssertEqual($0, .failed(.sourceChanged))
        finished.fulfill()
      })
    await fulfillment(of: [finished], timeout: 1)
    let calls = await driver.submitCalls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testPreparedCaptureReachesDriverAndCompactsRefusal() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let finished = expectation(description: "driver refusal")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: {
        XCTAssertEqual($0, .failed(.driver(.busy)))
        finished.fulfill()
      })
    await fulfillment(of: [finished], timeout: 1)
    let calls = await driver.submitCalls
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testCancelledHeldPreparationRetainsScopeCreditAndSlotUntilAcknowledged() async throws {
    final class Context {}
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let entered = expectation(description: "preparation held")
    let gate = AdmissionPreparationGate { entered.fulfill() }
    let owner = try SearchAdmissionController<Context>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry(),
      prepare: { await gate.prepare($0, $1, $2, $3) })
    let consumer = owner.register()
    var context: Context? = Context()
    let witness = AdmissionWeakBox(context)
    let job = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { _ in XCTFail("cancelled delivery") })
    context = nil
    await fulfillment(of: [entered], timeout: 1)
    owner.cancel(job)
    XCTAssertNotNil(witness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: consumer, descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: Context()) }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .consumerBusy)
    }
    let advanced = expectation(description: "next job after scope release")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { throw SearchAdmissionFailure.captureRefused },
      completion: { _ in advanced.fulfill() })
    await gate.release(true)
    await fulfillment(of: [advanced], timeout: 1)
    XCTAssertNil(witness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    let calls = await driver.submitCalls
    XCTAssertEqual(calls, 0)
  }

  func testSubmitRefusalRemainsChargedUntilSettlement() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    await driver.configureUnsettledRefusal()
    let retry = AdmissionManualRetry()
    let scheduled = expectation(description: "refusal cleanup pending")
    retry.onSchedule = { scheduled.fulfill() }
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let completed = expectation(description: "refusal settled")
    var delivered = false
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: {
        delivered = true
        XCTAssertEqual($0, .failed(.driver(.busy)))
        completed.fulfill()
      })
    await fulfillment(of: [scheduled], timeout: 1)
    XCTAssertFalse(delivered)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testHandleArrivingAfterCancelStillHasSoleWaitAndExactCancellation() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let submitted = expectation(description: "submit suspended")
    let waiting = expectation(description: "sole wait observed")
    let cancelling = expectation(description: "exact handle cancelled")
    await driver.configureAccepted(
      holdSubmit: true, onSubmit: { submitted.fulfill() }, onWait: { waiting.fulfill() },
      onCancel: { cancelling.fulfill() })
    let retry = AdmissionManualRetry()
    let pending = expectation(description: "post-wait settlement pending")
    retry.onSchedule = { pending.fulfill() }
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let consumer = owner.register()
    let job = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: { _ in XCTFail("cancelled delivery") })
    await fulfillment(of: [submitted], timeout: 1)
    owner.cancel(job)
    owner.cancel(job)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: consumer, descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in }))
    await driver.releaseSubmit()
    await fulfillment(of: [waiting, cancelling], timeout: 1)
    await driver.completeFailure()
    await fulfillment(of: [pending], timeout: 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    let advanced = expectation(description: "next queued consumer")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { throw SearchAdmissionFailure.captureRefused },
      completion: { _ in advanced.fulfill() })
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [advanced], timeout: 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    let waits = await driver.waitCalls
    let cancels = await driver.cancelCalls
    XCTAssertEqual(waits, 1)
    XCTAssertEqual(cancels, 1)
  }

  func testWaitFailureCannotReleaseBeforePendingSettlement() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "driver wait")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let retry = AdmissionManualRetry()
    let pending = expectation(description: "wait consumed but cleanup pending")
    retry.onSchedule = { pending.fulfill() }
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let completed = expectation(description: "settled failure")
    var delivered = false
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: {
        delivered = true
        XCTAssertEqual($0, .failed(.child(.deadline)))
        completed.fulfill()
      })
    await fulfillment(of: [waiting], timeout: 1)
    await driver.completeFailure(.deadline)
    await fulfillment(of: [pending], timeout: 1)
    XCTAssertFalse(delivered)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testSettlementErrorFailsClosedWithoutReleasingActiveCredit() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "driver wait")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let failed = expectation(description: "fail-closed error")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: {
        XCTAssertEqual($0, .failed(.driver(.staleHandle)))
        failed.fulfill()
      })
    await fulfillment(of: [waiting], timeout: 1)
    await driver.setSettlementFailure(.staleHandle)
    await driver.completeFailure()
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .shutdown)
    }
  }

  func testInlineRetryFailsClosedWithoutRecursion() async throws {
    let retry = AdmissionInlineRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: AdmissionScriptedDriver(), accounting: AdmissionTestAccounting(), retry: retry)
    let failed = expectation(description: "invalid scheduler rejected")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        XCTFail("must not capture")
        return .init(text: "x", inputUTF16: 1, context: ())
      },
      completion: {
        XCTAssertEqual($0, .failed(.internalFailure))
        failed.fulfill()
      })
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertEqual(retry.schedules, 1)
    XCTAssertTrue(retry.token.cancelled)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testTerminalSettlementRefusesCaptureAndFutureAdmission() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: true))
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let failed = expectation(description: "terminal driver")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        XCTFail("must not capture")
        return .init(text: "x", inputUTF16: 1, context: ())
      },
      completion: {
        XCTAssertEqual($0, .failed(.shutdown))
        failed.fulfill()
      })
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .shutdown)
    }
  }

  func testSuccessPublishesOneLeaseOnlyAfterSettlementThenBorrowsExactPayload() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<String>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: owner.register(),
        capture: { .init(text: "x", inputUTF16: 1, context: "context") })
    else { return }
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
    XCTAssertTrue(
      owner.withResult(lease) { context, source, output in
        XCTAssertEqual(context, "context")
        XCTAssertEqual(source, "x")
        XCTAssertEqual(output, .init(matches: [NSRange(location: 0, length: 1)], replacement: "y"))
      })
    owner.release(lease)
    owner.release(lease)
    XCTAssertFalse(owner.withResult(lease) { _, _, _ in XCTFail("invalid lease") })
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
  }

  func testBudgetRefusalPreservesExistingLeaseWithoutCapture() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(retainedLimit: 5), retry: retry)
    let consumer = owner.register()
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: consumer,
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    let failed = expectation(description: "old plus future exceeds budget")
    _ = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: {
        XCTFail("must not capture")
        return .init(text: "x", inputUTF16: 1, context: ())
      },
      completion: {
        XCTAssertEqual($0, .failed(.resultBudget))
        failed.fulfill()
      })
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertTrue(owner.withResult(lease) { _, source, _ in XCTAssertEqual(source, "x") })
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
  }

  func testSubmitRefusalPreservesPreviousLease() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let consumer = owner.register()
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: consumer,
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    await driver.configureRefusal()
    let failed = expectation(description: "replacement refused")
    _ = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: {
        XCTAssertEqual($0, .failed(.driver(.busy)))
        failed.fulfill()
      })
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertTrue(owner.withResult(lease) { _, _, _ in })
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
  }

  func testNestedBorrowReleaseInvalidatesImmediatelyButRetainsPayloadAndCharge() async throws {
    final class Context {}
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Context>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    var context: Context? = Context()
    let witness = AdmissionWeakBox(context)
    let lease = try await completeLease(
      owner, driver: driver, retry: retry, consumer: owner.register(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) })
    context = nil
    guard let lease else { return }
    XCTAssertTrue(
      owner.withResult(lease) { _, _, _ in
        XCTAssertTrue(
          owner.withResult(lease) { _, _, _ in
            owner.release(lease)
            XCTAssertFalse(owner.withResult(lease) { _, _, _ in XCTFail("invalidated") })
            XCTAssertEqual(owner.accountingSnapshot.retained, 3)
            XCTAssertNotNil(witness.value)
          })
        XCTAssertEqual(owner.accountingSnapshot.retained, 3)
        XCTAssertNotNil(witness.value)
      })
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    XCTAssertNil(witness.value)
  }

  func testShutdownClosesAdmissionAndReleasesQueuedClosureBeforeFirstAwait() async throws {
    final class Context {}
    let driver = AdmissionScriptedDriver()
    let entered = expectation(description: "shutdown command held")
    await driver.configureShutdown(hold: true, onShutdown: { entered.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    var context: Context? = Context()
    let witness = AdmissionWeakBox(context)
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { [context] in
        _ = context
        XCTFail("queued capture after shutdown")
        return .init(text: "x", inputUTF16: 1, context: ())
      }, completion: { _ in XCTFail("fenced shutdown callback") })
    context = nil
    let closing = Task { await owner.shutdown() }
    await fulfillment(of: [entered], timeout: 1)
    XCTAssertNil(witness.value)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .shutdown)
    }
    await driver.releaseShutdown()
    let snapshot = await closing.value
    XCTAssertEqual(snapshot.retainedActiveJobs, 0)
    XCTAssertEqual(snapshot.driverSettlement, .pending)
  }

  func testRepeatedShutdownJoinsOneCommandAndPreservesHistoricalReceipt() async throws {
    let driver = AdmissionScriptedDriver()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let first = await owner.shutdown()
    XCTAssertFalse(first.driver.child.stopped)
    XCTAssertEqual(first.driverSettlement, .pending)
    await driver.setSettlement(.settled(admissionClosed: true))
    let second = await owner.shutdown()
    XCTAssertEqual(second.driver, first.driver)
    XCTAssertEqual(second.driverSettlement, .settled(admissionClosed: true))
    let count = await driver.shutdownCalls
    XCTAssertEqual(count, 1)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in }))
  }

  func testShutdownDuringPreparationRetainsCreditUntilActualScopeExit() async throws {
    final class Context {}
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let entered = expectation(description: "held preparation")
    let exited = expectation(description: "actual preparation scope exit")
    let gate = AdmissionPreparationGate { entered.fulfill() }
    let owner = try SearchAdmissionController<Context>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry(),
      prepare: { await gate.prepare($0, $1, $2, $3) }, observe: { _ in exited.fulfill() })
    var context: Context? = Context()
    let witness = AdmissionWeakBox(context)
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { _ in XCTFail("shutdown delivery") })
    context = nil
    await fulfillment(of: [entered], timeout: 1)
    await driver.setSettlement(.pending)
    let pending = await owner.shutdown()
    XCTAssertEqual(pending.retainedActiveJobs, 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    XCTAssertNotNil(witness.value)
    await gate.release(true)
    await fulfillment(of: [exited], timeout: 1)
    XCTAssertNil(witness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
    let calls = await driver.submitCalls
    XCTAssertEqual(calls, 0)
  }

  func testShutdownWaitFailureStillCountsJobUntilAdoptedSettlement() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "held wait")
    let exited = expectation(description: "wait source scope exited")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry(),
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      }, observe: { _ in exited.fulfill() })
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: { _ in XCTFail("shutdown callback") })
    await fulfillment(of: [waiting], timeout: 1)
    let pending = await owner.shutdown()
    XCTAssertEqual(pending.retainedActiveJobs, 1)
    await driver.completeFailure()
    await fulfillment(of: [exited], timeout: 1)
    let stillPending = await owner.shutdown()
    XCTAssertEqual(stillPending.retainedActiveJobs, 1)
    XCTAssertEqual(stillPending.driverSettlement, .pending)
    await driver.setSettlement(.settled(admissionClosed: true))
    let settled = await owner.shutdown()
    XCTAssertEqual(settled.retainedActiveJobs, 0)
    XCTAssertEqual(settled.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(settled.driver, pending.driver)
    let calls = await driver.shutdownCalls
    XCTAssertEqual(calls, 1)
  }

  func testShutdownBeforeHandleReturnDoesNotReleaseNewerRequestOnStaleInspection() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let submitted = expectation(description: "late handle")
    let waiting = expectation(description: "late handle still waited")
    let exited = expectation(description: "late request source exit")
    await driver.configureAccepted(
      holdSubmit: true, onSubmit: { submitted.fulfill() }, onWait: { waiting.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry(),
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      }, observe: { _ in exited.fulfill() })
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: { _ in XCTFail("late delivery") })
    await fulfillment(of: [submitted], timeout: 1)
    let pending = await owner.shutdown()
    XCTAssertEqual(pending.retainedActiveJobs, 1)
    XCTAssertEqual(pending.driverSettlement, .pending)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    await driver.releaseSubmit()
    await fulfillment(of: [waiting], timeout: 1)
    await driver.completeFailure()
    await fulfillment(of: [exited], timeout: 1)
    await driver.setSettlement(.settled(admissionClosed: true))
    let settled = await owner.shutdown()
    XCTAssertEqual(settled.retainedActiveJobs, 0)
    let cancels = await driver.cancelCalls
    let shutdowns = await driver.shutdownCalls
    XCTAssertEqual(cancels, 1)
    XCTAssertEqual(shutdowns, 1)
  }

  func testShutdownInvalidatesRetainedLeaseAndCannotResumeAfterVeto() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: owner.register(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    await driver.setSettlement(.settled(admissionClosed: true))
    let snapshot = await owner.shutdown()
    XCTAssertEqual(snapshot.retainedLeases, 0)
    XCTAssertFalse(owner.withResult(lease) { _, _, _ in XCTFail("shutdown lease") })
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .shutdown)
    }
  }

  func testActiveStoppingJobStillOccupiesOneOfEightSlots() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "active wait")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let active = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: { _ in XCTFail("cancelled delivery") })
    await fulfillment(of: [waiting], timeout: 1)
    owner.cancel(active)
    var queuedCaptures = 0
    for _ in 0..<7 {
      _ = try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: {
          queuedCaptures += 1
          return .init(text: "x", inputUTF16: 1, context: ())
        }, completion: { _ in })
    }
    XCTAssertThrowsError(
      try owner.submit(
        consumer: owner.register(), descriptor: descriptor(),
        capture: {
          queuedCaptures += 1
          return .init(text: "x", inputUTF16: 1, context: ())
        }, completion: { _ in })
    ) {
      XCTAssertEqual($0 as? SearchAdmissionFailure, .queueFull)
    }
    XCTAssertEqual(queuedCaptures, 0)
    _ = await owner.shutdown()
    await driver.completeFailure()
  }

  func testRetainedLeaseDoesNotOccupyLogicalJobCapacity() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: owner.register(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    retry.onSchedule = nil
    await driver.setSettlement(.pending)
    for _ in 0..<8 {
      XCTAssertNoThrow(
        try owner.submit(
          consumer: owner.register(), descriptor: descriptor(),
          capture: {
            XCTFail("pending driver")
            return .init(text: "x", inputUTF16: 1, context: ())
          }, completion: { _ in }))
    }
    XCTAssertTrue(owner.withResult(lease) { _, _, _ in })
    _ = await owner.shutdown()
  }

  func testUnregisterInsideCaptureFencesReturnedContextAndNewSubmission() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let consumer = owner.register()
    let captured = expectation(description: "capture unregister")
    _ = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: {
        owner.unregister(consumer)
        XCTAssertThrowsError(
          try owner.submit(
            consumer: consumer, descriptor: self.descriptor(),
            capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
        ) {
          XCTAssertEqual($0 as? SearchAdmissionFailure, .unknownConsumer)
        }
        captured.fulfill()
        return .init(text: "x", inputUTF16: 1, context: ())
      }, completion: { _ in XCTFail("unregistered delivery") })
    await fulfillment(of: [captured], timeout: 1)
    let calls = await driver.submitCalls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testOldLeaseRetiresOnlyAfterReplacementHandleReturns() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let consumer = owner.register()
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: consumer,
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    retry.onSchedule = nil
    let submitted = expectation(description: "replacement submit held")
    let waiting = expectation(description: "replacement handle committed")
    await driver.configureAccepted(
      holdSubmit: true, onSubmit: { submitted.fulfill() }, onWait: { waiting.fulfill() })
    _ = try owner.submit(
      consumer: consumer, descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) }, completion: { _ in })
    await fulfillment(of: [submitted], timeout: 1)
    XCTAssertTrue(owner.withResult(lease) { _, _, _ in })
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
    XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 3)
    await driver.releaseSubmit()
    await fulfillment(of: [waiting], timeout: 1)
    XCTAssertFalse(owner.withResult(lease) { _, _, _ in XCTFail("retired result") })
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    _ = await owner.shutdown()
    await driver.completeFailure()
  }

  func testUnknownLeaseAndOneConsumerUnregisterCannotReleaseAnotherResult() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    let first = owner.register()
    guard
      let firstLease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: first,
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    guard
      let secondLease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: owner.register(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    owner.release(SearchResultLeaseID())
    XCTAssertEqual(owner.accountingSnapshot.retained, 6)
    owner.unregister(first)
    XCTAssertFalse(owner.withResult(firstLease) { _, _, _ in XCTFail("unregistered result") })
    XCTAssertTrue(owner.withResult(secondLease) { _, _, _ in })
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
  }

  func testLateCancelledRetryCallbackCannotRestartClosedOwner() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let scheduled = expectation(description: "initial retry")
    retry.onSchedule = { scheduled.fulfill() }
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        XCTFail("late capture")
        return .init(text: "x", inputUTF16: 1, context: ())
      }, completion: { _ in XCTFail("late completion") })
    await fulfillment(of: [scheduled], timeout: 1)
    let late = retry.tokens.first?.action
    retry.onSchedule = nil
    await driver.setSettlement(.settled(admissionClosed: true))
    _ = await owner.shutdown()
    let before = await driver.settlementCalls
    late?()
    let after = await driver.settlementCalls
    XCTAssertEqual(after, before)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testAccountingCancellationCannotInvokeCaptureAfterReentry() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let accounting = AdmissionReentrantAccounting()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: accounting, retry: AdmissionManualRetry())
    var id: SearchJobID?
    accounting.onCharge = { [weak owner] in owner?.cancel(id!) }
    var captures = 0
    id = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        captures += 1
        return .init(text: "x", inputUTF16: 1, context: ())
      }, completion: { _ in XCTFail("cancelled callback") })
    let advanced = expectation(description: "next metadata job")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { throw SearchAdmissionFailure.captureRefused },
      completion: { _ in advanced.fulfill() })
    await fulfillment(of: [advanced], timeout: 1)
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testHeldCancellationCommandPreventsCreditReleaseAndNextCapture() async throws {
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "wait installed")
    let cancelling = expectation(description: "cancel command held")
    let exited = expectation(description: "wait scope ended")
    await driver.configureAccepted(
      holdCancel: true, onWait: { waiting.fulfill() }, onCancel: { cancelling.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry(),
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      }, observe: { _ in exited.fulfill() })
    let job = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { .init(text: "x", inputUTF16: 1, context: ()) },
      completion: { _ in XCTFail("cancelled callback") })
    await fulfillment(of: [waiting], timeout: 1)
    owner.cancel(job)
    await fulfillment(of: [cancelling], timeout: 1)
    await driver.completeFailure()
    await fulfillment(of: [exited], timeout: 1)
    await driver.setSettlement(.settled(admissionClosed: false))
    let advanced = expectation(description: "next capture after cancel joins")
    var captures = 0
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: {
        captures += 1
        throw SearchAdmissionFailure.captureRefused
      }, completion: { _ in advanced.fulfill() })
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    await driver.releaseCancel()
    await fulfillment(of: [advanced], timeout: 1)
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testCancelAfterSuccessfulWaitDiscardsProvisionalOnlyAfterSettlement() async throws {
    final class Context {}
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "success wait")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let retry = AdmissionManualRetry()
    let pending = expectation(description: "provisional waiting for cleanup")
    retry.onSchedule = { pending.fulfill() }
    let owner = try SearchAdmissionController<Context>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    var context: Context? = Context()
    let witness = AdmissionWeakBox(context)
    let job = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { _ in XCTFail("cancelled provisional delivery") })
    context = nil
    await fulfillment(of: [waiting], timeout: 1)
    try await driver.completeSuccess()
    await fulfillment(of: [pending], timeout: 1)
    owner.cancel(job)
    XCTAssertNotNil(witness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    let advanced = expectation(description: "provisional dropped before next callback")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { throw SearchAdmissionFailure.captureRefused },
      completion: { _ in advanced.fulfill() })
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [advanced], timeout: 1)
    XCTAssertNil(witness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testReentrantDeliveryActionsPreserveUnrelatedConsumer() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry)
    guard
      let unrelated = try await completeLease(
        owner, driver: driver, retry: retry, consumer: owner.register(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    for action in 0..<3 {
      let consumer = owner.register()
      guard
        let lease = try await completeLease(
          owner, driver: driver, retry: retry, consumer: consumer,
          capture: { .init(text: "x", inputUTF16: 1, context: ()) },
          onDelivery: { job, lease in
            switch action {
            case 0: owner.release(lease)
            case 1: owner.unregister(consumer)
            default: owner.cancel(job)
            }
            XCTAssertTrue(owner.withResult(unrelated) { _, _, _ in })
          })
      else { return }
      XCTAssertFalse(owner.withResult(lease) { _, _, _ in XCTFail("invalidated during delivery") })
      XCTAssertEqual(owner.accountingSnapshot.retained, 3)
    }
  }

  func testSimultaneousShutdownCallsJoinHeldCommand() async throws {
    let driver = AdmissionScriptedDriver()
    let entered = expectation(description: "one command")
    await driver.configureShutdown(hold: true, onShutdown: { entered.fulfill() })
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    let first = Task { await owner.shutdown() }
    await fulfillment(of: [entered], timeout: 1)
    let secondStarted = expectation(description: "second caller entered")
    let second = Task {
      secondStarted.fulfill()
      return await owner.shutdown()
    }
    await fulfillment(of: [secondStarted], timeout: 1)
    await driver.setSettlement(.settled(admissionClosed: true))
    await driver.releaseShutdown()
    let firstResult = await first.value
    let secondResult = await second.value
    XCTAssertEqual(firstResult, secondResult)
    let calls = await driver.shutdownCalls
    XCTAssertEqual(calls, 1)
  }

  func testFailedWaitDropsContextAtScopeExitAndCompletionClosureAfterDelivery() async throws {
    final class Sentinel {}
    let driver = AdmissionScriptedDriver()
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "wait")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let exited = expectation(description: "source helper scope ended")
    let retry = AdmissionManualRetry()
    let pending = expectation(description: "cleanup pending")
    retry.onSchedule = { pending.fulfill() }
    let owner = try SearchAdmissionController<Sentinel>(
      driver: driver, accounting: AdmissionTestAccounting(), retry: retry,
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      }, observe: { _ in exited.fulfill() })
    var context: Sentinel? = Sentinel()
    var callbackOwner: Sentinel? = Sentinel()
    let contextWitness = AdmissionWeakBox(context)
    let callbackWitness = AdmissionWeakBox(callbackOwner)
    let completed = expectation(description: "failure delivered")
    _ = try owner.submit(
      consumer: owner.register(), descriptor: descriptor(),
      capture: { [context] in .init(text: "x", inputUTF16: 1, context: context!) },
      completion: { [callbackOwner] _ in
        _ = callbackOwner
        completed.fulfill()
      })
    context = nil
    callbackOwner = nil
    await fulfillment(of: [waiting], timeout: 1)
    await driver.completeFailure(.deadline)
    await fulfillment(of: [exited, pending], timeout: 1)
    XCTAssertNil(contextWitness.value)
    XCTAssertNotNil(callbackWitness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertNil(callbackWitness.value)
    XCTAssertEqual(owner.accountingSnapshot.active, 2)
  }

  func testSubmitInsideBorrowStaysQueuedAndOldChargeSurvivesUntilReturn() async throws {
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<Void>(
      driver: driver, accounting: AdmissionTestAccounting(retainedLimit: 5), retry: retry)
    guard
      let lease = try await completeLease(
        owner, driver: driver, retry: retry, consumer: owner.register(),
        capture: { .init(text: "x", inputUTF16: 1, context: ()) })
    else { return }
    let completed = expectation(description: "queued job after borrow returns")
    var captures = 0
    XCTAssertTrue(
      owner.withResult(lease) { _, _, _ in
        owner.release(lease)
        do {
          _ = try owner.submit(
            consumer: owner.register(), descriptor: descriptor(),
            capture: {
              captures += 1
              throw SearchAdmissionFailure.captureRefused
            }, completion: { _ in completed.fulfill() })
        } catch {
          XCTFail("reentrant metadata admission failed: \(error)")
        }
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(owner.accountingSnapshot.retained, 3)
        XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 0)
      })
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(captures, 1)
  }

  private func completeLease<C>(
    _ owner: SearchAdmissionController<C>, driver: AdmissionScriptedDriver,
    retry: AdmissionManualRetry, consumer: SearchConsumerID,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<C>,
    onDelivery: (@MainActor (SearchJobID, SearchResultLeaseID) -> Void)? = nil
  ) async throws -> SearchResultLeaseID? {
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "successful wait")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let pending = expectation(description: "successful output still active")
    retry.onSchedule = { pending.fulfill() }
    let completed = expectation(description: "lease published")
    var lease: SearchResultLeaseID?
    var job: SearchJobID?
    job = try owner.submit(
      consumer: consumer, descriptor: descriptor(), capture: capture,
      completion: {
        if case .completed(let id) = $0 {
          lease = id
          if let job { onDelivery?(job, id) }
        } else {
          XCTFail("unexpected failure")
        }
        completed.fulfill()
      })
    await fulfillment(of: [waiting], timeout: 1)
    try await driver.completeSuccess()
    await fulfillment(of: [pending], timeout: 1)
    XCTAssertNil(lease)
    XCTAssertEqual(owner.accountingSnapshot.active, 6)
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [completed], timeout: 1)
    return lease
  }

  private func makeOwner() throws -> SearchAdmissionController<Void> {
    try SearchAdmissionController(
      driver: AdmissionScriptedDriver(), accounting: AdmissionTestAccounting(),
      retry: AdmissionManualRetry())
  }
  private func descriptor() throws -> SearchAdmissionDescriptor {
    try .init(
      query: .init(pattern: "x", mode: .literal), operation: .find, estimatedInputUTF16: 1,
      scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 10, maxOutputUTF16: 10, maxMatches: 10, cooperativeMilliseconds: 1))
  }
}
