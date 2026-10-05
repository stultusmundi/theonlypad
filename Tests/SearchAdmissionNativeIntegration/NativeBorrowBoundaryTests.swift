import AppKit
import CoreFoundation
import Foundation
import PadCore
import XCTest

@testable import SearchExecution

/// Hidden native borrow controls: real modalPanel-mode target/action, no shown modal session.
@MainActor final class NativeBorrowBoundaryTests: XCTestCase {
  func testReplacementAdmissionResolvesInsideNativeBorrowForBothBudgets() async throws {
    for limit in [UInt64(8), UInt64(9)] { try await checkReplacement(retainedLimit: limit) }
  }

  private func checkReplacement(retainedLimit: UInt64) async throws {
    let f = try await fixture(retainedLimit: retainedLimit)
    let owner = f.owner
    let weakA = f.weakA
    let leaseA = f.leaseA
    let leaseB = f.leaseB
    let consumerA = f.consumerA
    let expectedCaptures = retainedLimit == 9 ? 1 : 0
    let expectedFailure: SearchAdmissionFailure =
      retainedLimit == 9 ? .captureRefused : .resultBudget
    let finished = expectation(description: "native outer borrow scope exited")
    var outerLive = false
    var captures = 0
    var completions = 0
    var events: [String] = []
    let record: @MainActor (String) -> Void = {
      precondition(events.count < 16, "bounded native event trace")
      events.append($0)
    }
    let target = NativeBorrowAction {
      XCTAssertTrue(Thread.isMainThread)
      record("outer-action")
      XCTAssertTrue(
        owner.withResult(leaseA) { context, source, _ in
          outerLive = true
          defer { outerLive = false }
          XCTAssertEqual(context.label, "a")
          XCTAssertEqual(source, "x")
          record("borrow-enter")
          let loop = NativeBorrowLoop()
          loop.run {
            XCTAssertTrue(outerLive)
            XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
            record("nested-action")
            owner.release(leaseA)
            XCTAssertFalse(owner.withResult(leaseA) { _, _, _ in XCTFail("invalidated lease") })
            XCTAssertNotNil(weakA.value)
            XCTAssertEqual(owner.accountingSnapshot.retained, 6)
            do {
              _ = try owner.submit(
                consumer: consumerA, descriptor: self.descriptor(),
                capture: {
                  captures += 1
                  record("capture")
                  XCTAssertTrue(outerLive, "capture must execute before native borrow returns")
                  XCTAssertTrue(loop.running)
                  XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
                  XCTAssertNotNil(weakA.value)
                  XCTAssertEqual(owner.accountingSnapshot.active, 6)
                  XCTAssertEqual(owner.accountingSnapshot.retained, 6)
                  XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 3)
                  throw SearchAdmissionFailure.captureRefused
                },
                completion: { delivery in
                  completions += 1
                  record("completion")
                  XCTAssertEqual(delivery, .failed(expectedFailure))
                  XCTAssertTrue(outerLive)
                  XCTAssertTrue(loop.running)
                  XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
                  XCTAssertEqual(owner.accountingSnapshot.active, 2)
                  XCTAssertEqual(owner.accountingSnapshot.retained, 6)
                  XCTAssertEqual(owner.accountingSnapshot.reservedRetained, 0)
                  XCTAssertNotNil(weakA.value)
                  loop.stop()
                })
            } catch {
              XCTFail("metadata submit failed: \(error)")
              loop.stop()
            }
          }
          record("nested-return")
          XCTAssertEqual(
            captures, expectedCaptures, "capture admission must resolve inside native borrow")
          XCTAssertEqual(completions, 1)
          XCTAssertNotNil(weakA.value)
          XCTAssertEqual(owner.accountingSnapshot.retained, 6)
          XCTAssertTrue(
            owner.withResult(leaseB) { other, text, _ in
              XCTAssertEqual(other.label, "b")
              XCTAssertEqual(text, "x")
            })
        })
      record("borrow-return")
      XCTAssertNil(weakA.value)
      XCTAssertEqual(owner.accountingSnapshot.retained, 3)
      finished.fulfill()
    }
    // Enter from a real run-loop timer, after this async test yields the main actor.
    let outer = Timer(fire: Date(), interval: 0, repeats: false) { _ in
      MainActor.assumeIsolated {
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(NativeBorrowAction.invoke(_:)),
            to: target, from: nil))
      }
    }
    RunLoop.main.add(outer, forMode: .default)
    defer { outer.invalidate() }
    await fulfillment(of: [finished], timeout: 8)
    let expectedEvents =
      ["outer-action", "borrow-enter", "nested-action"]
      + (expectedCaptures == 1 ? ["capture"] : [])
      + ["completion", "nested-return", "borrow-return"]
    XCTAssertEqual(events, expectedEvents)
    XCTAssertFalse(outerLive)
    XCTAssertEqual(captures, expectedCaptures)
    XCTAssertEqual(completions, 1)
    XCTAssertNil(weakA.value)
    owner.release(leaseB)
    XCTAssertEqual(owner.accountingSnapshot.retained, 0)
    XCTAssertFalse(NSApplication.shared.windows.contains { $0.isVisible })
  }

  func testNestedNativeUnregisterDefersDestructionThroughBothBorrows() async throws {
    let f = try await fixture()
    let foreignDriver = AdmissionScriptedDriver()
    let foreign = try SearchAdmissionController<NativeBorrowSentinel>(
      driver: foreignDriver,
      accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    addTeardownBlock {
      await foreignDriver.setSettlement(.settled(admissionClosed: true))
      _ = await foreign.shutdown()
    }
    var innerReturned = false
    var actionDelivered = false
    await nativeOuter {
      XCTAssertTrue(
        f.owner.withResult(f.leaseA) { outerContext, _, _ in
          XCTAssertEqual(outerContext.label, "a")
          XCTAssertTrue(
            f.owner.withResult(f.leaseA) { innerContext, _, _ in
              XCTAssertTrue(innerContext === outerContext)
              let loop = NativeBorrowLoop()
              loop.run {
                XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
                actionDelivered = true
                foreign.release(f.leaseA)
                XCTAssertEqual(foreign.accountingSnapshot.retained, 0)
                XCTAssertEqual(f.owner.accountingSnapshot.retained, 6)
                f.owner.unregister(f.consumerA)
                f.owner.release(f.leaseA)
                XCTAssertFalse(
                  f.owner.withResult(f.leaseA) { _, _, _ in XCTFail("invalidated borrow") })
                XCTAssertNotNil(f.weakA.value)
                XCTAssertEqual(f.owner.accountingSnapshot.retained, 6)
                XCTAssertEqual(f.owner.accountingSnapshot.reservedRetained, 0)
                XCTAssertTrue(
                  f.owner.withResult(f.leaseB) { context, source, _ in
                    XCTAssertEqual(context.label, "b")
                    XCTAssertEqual(source, "x")
                  })
                loop.stop()
              }
              XCTAssertTrue(actionDelivered)
              XCTAssertNotNil(f.weakA.value)
              XCTAssertEqual(f.owner.accountingSnapshot.retained, 6)
            })
          innerReturned = true
          XCTAssertNotNil(f.weakA.value)
          XCTAssertEqual(f.owner.accountingSnapshot.retained, 6)
        })
      XCTAssertNil(f.weakA.value)
      XCTAssertEqual(f.owner.accountingSnapshot.retained, 3)
    }
    XCTAssertTrue(innerReturned)
    XCTAssertTrue(actionDelivered)
    XCTAssertNil(f.weakA.value)
    XCTAssertTrue(
      f.owner.withResult(f.leaseB) { context, _, _ in XCTAssertEqual(context.label, "b") })
    f.owner.release(f.leaseB)
    XCTAssertNil(f.weakB.value)
    XCTAssertEqual(f.owner.accountingSnapshot.retained, 0)
  }

  func testRepeatedShutdownCompletesInsideNativeBorrowAndCountsItsRetainedLease() async throws {
    try await checkCleanupBeforeAnyShutdownCommand()
    let f = try await fixture()
    let state = NativeShutdownState()
    await f.driver.setSettlement(.pending)
    await f.driver.configureShutdown(
      hold: true,
      onShutdown: {
        RunLoop.main.perform(inModes: [.modalPanel]) {
          MainActor.assumeIsolated { state.onDriverEntered?() }
        }
      })
    await nativeOuter {
      XCTAssertTrue(
        f.owner.withResult(f.leaseA) { _, _, _ in
          state.outerLive = true
          defer { state.outerLive = false }
          let loop = NativeBorrowLoop()
          state.onDriverEntered = {
            XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
            XCTAssertTrue(state.outerLive)
            XCTAssertTrue(loop.running)
            XCTAssertFalse(f.owner.withResult(f.leaseA) { _, _, _ in XCTFail("shutdown A") })
            XCTAssertFalse(f.owner.withResult(f.leaseB) { _, _, _ in XCTFail("shutdown B") })
            XCTAssertNotNil(f.weakA.value)
            XCTAssertNil(f.weakB.value)
            XCTAssertEqual(f.owner.accountingSnapshot.retained, 3)
            XCTAssertEqual(state.queuedCaptures, 0)
            XCTAssertEqual(state.deliveries, 0)
            do {
              _ = try f.owner.submit(
                consumer: f.consumerA, descriptor: self.descriptor(),
                capture: {
                  XCTFail("terminal capture")
                  throw SearchAdmissionFailure.shutdown
                },
                completion: { _ in XCTFail("terminal delivery") })
              XCTFail("terminal owner accepted metadata")
            } catch {
              XCTAssertEqual(error as? SearchAdmissionFailure, .shutdown)
            }
            state.second = Task {
              // This MainActor task enters the second shutdown before its release task can run.
              state.release = Task {
                await f.driver.setSettlement(.settled(admissionClosed: true))
                await f.driver.releaseShutdown()
              }
              let receipt = await f.owner.shutdown()
              state.accept(receipt, owner: f.owner, weakA: f.weakA, loop: loop)
              return receipt
            }
          }
          loop.run {
            do {
              _ = try f.owner.submit(
                consumer: f.owner.register(), descriptor: self.descriptor(),
                capture: {
                  state.queuedCaptures += 1
                  throw SearchAdmissionFailure.captureRefused
                }, completion: { _ in state.deliveries += 1 })
            } catch { XCTFail("queued metadata: \(error)") }
            state.first = Task {
              let receipt = await f.owner.shutdown()
              state.accept(receipt, owner: f.owner, weakA: f.weakA, loop: loop)
              return receipt
            }
          }
          state.onDriverEntered = nil
          XCTAssertEqual(state.receipts.count, 2)
          XCTAssertNotNil(f.weakA.value)
          XCTAssertEqual(f.owner.accountingSnapshot.retained, 3)
        })
      XCTAssertNil(f.weakA.value)
      XCTAssertEqual(f.owner.accountingSnapshot.retained, 0)
    }
    // Always release and join fixture Tasks, including a host-timeout failure path.
    await Self.prepareShutdownCleanup(f.driver)
    _ = await state.first?.value
    _ = await state.second?.value
    await state.release?.value
    XCTAssertEqual(state.receipts.count, 2)
    if state.receipts.count == 2 { XCTAssertEqual(state.receipts[0], state.receipts[1]) }
    let repeated = await f.owner.shutdown()
    XCTAssertEqual(repeated.retainedLeases, 0)
    XCTAssertEqual(repeated.retainedActiveJobs, 0)
    XCTAssertEqual(repeated.driverSettlement, .settled(admissionClosed: true))
    if let first = state.receipts.first { XCTAssertEqual(repeated.driver, first.driver) }
    let commands = await f.driver.shutdownCalls
    XCTAssertEqual(commands, 1)
    XCTAssertEqual(state.queuedCaptures, 0)
    XCTAssertEqual(state.deliveries, 0)
    XCTAssertNil(f.weakA.value)
    XCTAssertNil(f.weakB.value)
  }

  private static func prepareShutdownCleanup(_ driver: AdmissionScriptedDriver) async {
    await driver.configureShutdown(hold: false, onShutdown: nil)
    await driver.releaseShutdown()
  }

  private func checkCleanupBeforeAnyShutdownCommand() async throws {
    let driver = AdmissionScriptedDriver()
    let owner = try SearchAdmissionController<NativeBorrowSentinel>(
      driver: driver,
      accounting: AdmissionTestAccounting(), retry: AdmissionManualRetry())
    await driver.configureShutdown(hold: true)
    await driver.setSettlement(.settled(admissionClosed: true))
    let completed = expectation(
      description: "cleanup before any command does not create a new hold")
    let cleanup = Task {
      await Self.prepareShutdownCleanup(driver)
      _ = await owner.shutdown()
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 1)
    // Unconditional rescue is independent of the helper under test: failure never strands the task.
    await driver.configureShutdown(hold: false, onShutdown: nil)
    await driver.releaseShutdown()
    await cleanup.value
    let commands = await driver.shutdownCalls
    XCTAssertEqual(commands, 1)
  }

  private func nativeOuter(_ action: @escaping @MainActor () -> Void) async {
    let finished = expectation(description: "outer native action returned")
    var active = true
    let target = NativeBorrowAction {
      guard active else { return }
      action()
      finished.fulfill()
    }
    let timer = Timer(fire: Date(), interval: 0, repeats: false) { _ in
      MainActor.assumeIsolated {
        guard active else { return }
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(NativeBorrowAction.invoke(_:)),
            to: target, from: nil))
      }
    }
    RunLoop.main.add(timer, forMode: .default)
    defer {
      active = false
      timer.invalidate()
    }
    await fulfillment(of: [finished], timeout: 8)
    XCTAssertFalse(NSApplication.shared.windows.contains { $0.isVisible })
  }

  private func fixture(retainedLimit: UInt64 = 20) async throws -> NativeBorrowFixture {
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.prohibited)
    XCTAssertEqual(app.activationPolicy(), .prohibited)
    XCTAssertFalse(app.windows.contains { $0.isVisible })
    let driver = AdmissionScriptedDriver()
    let retry = AdmissionManualRetry()
    let owner = try SearchAdmissionController<NativeBorrowSentinel>(
      driver: driver,
      accounting: AdmissionTestAccounting(retainedLimit: retainedLimit), retry: retry)
    addTeardownBlock {
      await Self.prepareShutdownCleanup(driver)
      await driver.setSettlement(.settled(admissionClosed: true))
      _ = await owner.shutdown()
    }
    let consumerA = owner.register()
    var a: NativeBorrowSentinel? = NativeBorrowSentinel("a")
    var b: NativeBorrowSentinel? = NativeBorrowSentinel("b")
    let weakA = AdmissionWeakBox(a)
    let weakB = AdmissionWeakBox(b)
    let leaseA = try await completeLease(
      owner, driver: driver, retry: retry,
      consumer: consumerA, capture: { [a] in .init(text: "x", inputUTF16: 1, context: a!) })
    let leaseB = try await completeLease(
      owner, driver: driver, retry: retry,
      consumer: owner.register(), capture: { [b] in .init(text: "x", inputUTF16: 1, context: b!) })
    a = nil
    b = nil
    retry.onSchedule = nil
    return NativeBorrowFixture(
      owner: owner, driver: driver, consumerA: consumerA,
      leaseA: leaseA, leaseB: leaseB, weakA: weakA, weakB: weakB)
  }

  private func descriptor() throws -> SearchAdmissionDescriptor {
    try .init(
      query: .init(pattern: "x", mode: .literal), operation: .find,
      estimatedInputUTF16: 1, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 8, maxOutputUTF16: 8,
        maxMatches: 8, cooperativeMilliseconds: 0))
  }

  private func completeLease(
    _ owner: SearchAdmissionController<NativeBorrowSentinel>,
    driver: AdmissionScriptedDriver, retry: AdmissionManualRetry, consumer: SearchConsumerID,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<NativeBorrowSentinel>
  ) async throws -> SearchResultLeaseID {
    await driver.setSettlement(.settled(admissionClosed: false))
    let waiting = expectation(description: "scripted sole wait entered")
    await driver.configureAccepted(onWait: { waiting.fulfill() })
    let pending = expectation(description: "result awaiting settlement")
    retry.onSchedule = { pending.fulfill() }
    let delivered = expectation(description: "lease delivered")
    var lease: SearchResultLeaseID?
    _ = try owner.submit(
      consumer: consumer, descriptor: descriptor(), capture: capture,
      completion: {
        if case .completed(let id) = $0 {
          lease = id
        } else {
          XCTFail("unexpected lease setup failure: \($0)")
        }
        delivered.fulfill()
      })
    await fulfillment(of: [waiting], timeout: 2)
    try await driver.completeSuccess()
    await fulfillment(of: [pending], timeout: 2)
    await driver.setSettlement(.settled(admissionClosed: false))
    retry.fire()
    await fulfillment(of: [delivered], timeout: 2)
    return try XCTUnwrap(lease)
  }
}

private final class NativeBorrowSentinel {
  let label: String
  init(_ label: String) { self.label = label }
}

@MainActor private final class NativeBorrowAction: NSObject {
  let action: @MainActor () -> Void
  init(_ action: @escaping @MainActor () -> Void) { self.action = action }
  @objc func invoke(_ sender: Any?) { action() }
}

@MainActor private final class NativeBorrowLoop {
  private(set) var running = false
  private var stopped = false
  func stop() {
    guard running else { return }
    stopped = true
    CFRunLoopStop(CFRunLoopGetMain())
  }
  func run(_ action: @escaping @MainActor () -> Void) {
    precondition(!running)
    running = true
    let target = NativeBorrowAction(action)
    let event = Timer(fire: Date(), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.running == true else { return }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(
          NSApplication.shared.sendAction(
            #selector(NativeBorrowAction.invoke(_:)),
            to: target, from: nil))
      }
    }
    // A single emergency timer keeps the mode alive after the action source fires.
    // It is a failure deadline, never a scheduling/polling oracle.
    let emergency = Timer(fire: Date().addingTimeInterval(5), interval: 0, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.running == true else { return }
        XCTFail("nested native loop did not observe capture/completion before its deadline")
        CFRunLoopStop(CFRunLoopGetMain())
      }
    }
    RunLoop.main.add(event, forMode: .modalPanel)
    RunLoop.main.add(emergency, forMode: .modalPanel)
    defer {
      running = false
      event.invalidate()
      emergency.invalidate()
    }
    let mode = CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString)
    let result: CFRunLoopRunResult = CFRunLoopRunInMode(mode, 6, false)
    XCTAssertEqual(result, CFRunLoopRunResult.stopped)
    XCTAssertTrue(stopped, "only actual owner completion certifies the native boundary")
  }
}

@MainActor private struct NativeBorrowFixture {
  let owner: SearchAdmissionController<NativeBorrowSentinel>
  let driver: AdmissionScriptedDriver
  let consumerA: SearchConsumerID
  let leaseA: SearchResultLeaseID
  let leaseB: SearchResultLeaseID
  let weakA: AdmissionWeakBox<NativeBorrowSentinel>
  let weakB: AdmissionWeakBox<NativeBorrowSentinel>
}

@MainActor private final class NativeShutdownState {
  var outerLive = false
  var queuedCaptures = 0
  var deliveries = 0
  var receipts: [SearchAdmissionShutdown] = []
  var first: Task<SearchAdmissionShutdown, Never>?
  var second: Task<SearchAdmissionShutdown, Never>?
  var release: Task<Void, Never>?
  var onDriverEntered: (() -> Void)?
  func accept(
    _ receipt: SearchAdmissionShutdown, owner: SearchAdmissionController<NativeBorrowSentinel>,
    weakA: AdmissionWeakBox<NativeBorrowSentinel>, loop: NativeBorrowLoop
  ) {
    XCTAssertTrue(outerLive)
    XCTAssertTrue(loop.running)
    XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
    XCTAssertEqual(receipt.retainedLeases, 1)
    XCTAssertEqual(receipt.retainedActiveJobs, 0)
    XCTAssertEqual(receipt.driverSettlement, .settled(admissionClosed: true))
    XCTAssertEqual(owner.accountingSnapshot.retained, 3)
    XCTAssertNotNil(weakA.value)
    precondition(receipts.count < 2, "exactly two joined shutdown observations")
    receipts.append(receipt)
    if receipts.count == 2 { loop.stop() }
  }
}
