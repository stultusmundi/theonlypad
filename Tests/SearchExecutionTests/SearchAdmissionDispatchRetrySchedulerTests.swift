import Dispatch
import Foundation
import SearchExecution
import XCTest

@MainActor final class SearchAdmissionDispatchRetrySchedulerTests: XCTestCase {
  func testDeliveryOccursAfterReturnOnMainActorNoEarlierThanTwentyFiveMilliseconds() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    let delivered = expectation(description: "real delayed delivery")
    var returned = false
    var calls = 0
    let started = DispatchTime.now().uptimeNanoseconds
    let token = scheduler.schedule {
      XCTAssertTrue(returned)
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - started, 25_000_000)
      calls += 1
      delivered.fulfill()
    }
    defer { token.cancel() }
    returned = true
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(calls, 1)
    await laterTurn(scheduler)
    XCTAssertEqual(calls, 1)
  }

  func testRepeatedCancelSuppressesDeliveryPastALaterRealCallback() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    var calls = 0
    let token = scheduler.schedule { calls += 1 }
    defer { token.cancel() }
    token.cancel()
    token.cancel()
    await laterTurn(scheduler)
    XCTAssertEqual(calls, 0)
  }

  func testCancellingOneTokenDoesNotCancelIndependentToken() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    var cancelledCalls = 0
    var survivingCalls = 0
    let delivered = expectation(description: "independent token delivered")
    let first = scheduler.schedule { cancelledCalls += 1 }
    let second = scheduler.schedule {
      survivingCalls += 1
      delivered.fulfill()
    }
    defer {
      first.cancel()
      second.cancel()
    }
    first.cancel()
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(cancelledCalls, 0)
    XCTAssertEqual(survivingCalls, 1)
    await laterTurn(scheduler)
    XCTAssertEqual(cancelledCalls, 0)
    XCTAssertEqual(survivingCalls, 1)
  }

  func testCallbackLocalCancelIsSafeAndCannotDeliverAgain() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    let delivered = expectation(description: "callback may cancel its own token")
    var token: (any SearchAdmissionRetryToken)?
    var calls = 0
    token = scheduler.schedule {
      XCTAssertNotNil(token)
      calls += 1
      token?.cancel()
      token?.cancel()
      delivered.fulfill()
    }
    defer { token?.cancel() }
    await fulfillment(of: [delivered], timeout: 2)
    await laterTurn(scheduler)
    XCTAssertEqual(calls, 1)
    token = nil
  }

  func testCancelReleasesCapturedContextWhileCallerStillRetainsToken() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    var context: RetryLifetimeContext? = RetryLifetimeContext(marker: 7)
    #if compiler(>=6.3)
      weak let witness = context
    #else
      weak var witness = context
    #endif
    var calls = 0
    let token = scheduler.schedule { [context] in
      XCTAssertEqual(context?.marker, 7)
      calls += 1
    }
    defer { token.cancel() }
    context = nil
    XCTAssertNotNil(witness)
    token.cancel()
    XCTAssertNil(witness)
    await laterTurn(scheduler)
    XCTAssertEqual(calls, 0)
    XCTAssertNil(witness)
  }

  func testFiredActionReleasesContextWithoutRequiringTokenCancellation() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    var context: RetryLifetimeContext? = RetryLifetimeContext(marker: 11)
    #if compiler(>=6.3)
      weak let witness = context
    #else
      weak var witness = context
    #endif
    let delivered = expectation(description: "context used by actual fire")
    var calls = 0
    let token = scheduler.schedule { [context] in
      XCTAssertEqual(context?.marker, 11)
      calls += 1
      delivered.fulfill()
    }
    defer { token.cancel() }
    context = nil
    XCTAssertNotNil(witness)
    await fulfillment(of: [delivered], timeout: 2)
    await laterTurn(scheduler)
    XCTAssertEqual(calls, 1)
    XCTAssertNil(witness)
    // token is retained through these assertions; cancel runs only in defer.
  }

  func testDroppingTokenReleasesContextAndQueuedEntryCannotCallAction() async {
    let scheduler = SearchAdmissionDispatchRetryScheduler()
    var context: RetryLifetimeContext? = RetryLifetimeContext(marker: 19)
    #if compiler(>=6.3)
      weak let witness = context
    #else
      weak var witness = context
    #endif
    var calls = 0
    var token: (any SearchAdmissionRetryToken)? = scheduler.schedule { [context] in
      XCTAssertEqual(context?.marker, 19)
      calls += 1
    }
    defer { token?.cancel() }
    context = nil
    XCTAssertNotNil(token)
    XCTAssertNotNil(witness)
    token = nil
    XCTAssertNil(witness)
    await laterTurn(scheduler)
    XCTAssertNil(token)
    XCTAssertNil(witness)
    XCTAssertEqual(calls, 0)
  }

  private func laterTurn(_ scheduler: SearchAdmissionDispatchRetryScheduler) async {
    let later = expectation(description: "later uncancelled real main-queue callback")
    let sentinel = scheduler.schedule {
      XCTAssertTrue(Thread.isMainThread)
      later.fulfill()
    }
    defer { sentinel.cancel() }
    await fulfillment(of: [later], timeout: 2)
  }
}

private final class RetryLifetimeContext {
  let marker: Int
  init(marker: Int) { self.marker = marker }
}
