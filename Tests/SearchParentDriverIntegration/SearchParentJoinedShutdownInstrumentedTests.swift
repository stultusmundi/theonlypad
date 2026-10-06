import Foundation
import PadCore
import XCTest

@testable import SearchExecution

// Compiled with the ordinary five tests only by the declared frozen driver runner.
extension SearchParentJoinedShutdownTests {
  // Break: selecting only a mode flag leaves submit open before owner execution.
  func testPreOwnerStartClosesActualSubmitAdmission() async throws {
    let h = try DriverHarness()
    let entered = DriverTestGate()
    let release = DriverTestGate()
    defer {
      release.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.ownerStart = {
      entered.open()
      await release.wait()
    }
    let driver = try makeDriver(h)
    let next = try job()
    let owner = Task { await driver.shutdownJoined(after: nil) }
    await entered.wait()
    do {
      _ = try await driver.submit(next)
      XCTFail("Terminal intent must precede owner startup")
    } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .shutDown) }
    let held = await driver.testJoinedSnapshot()
    XCTAssertNil(held.latest)
    XCTAssertFalse(held.committed)
    release.open()
    assertCompletion(await owner.value, ownership: .admitted)
  }

  // Break: a later old API call invokes a second child command or overtakes ownership.
  func testJoinedFirstLegacySecondAliasesOneOriginalCommand() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let entered = DriverTestGate()
    let release = DriverTestGate()
    let aliasEntered = DriverTestGate()
    let commands = DriverTestCount()
    let laneWaits = DriverTestCount()
    defer {
      release.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.ownerStart = {
      entered.open()
      await release.wait()
    }
    SearchParentJoinedTestHooks.childShutdown = {
      if $0 == ObjectIdentifier(h.lifecycle) { commands.increment() }
    }
    SearchParentJoinedTestHooks.laneWait = { laneWaits.increment() }
    SearchParentJoinedTestHooks.legacyEntry = { aliasEntered.open() }
    let driver = try makeDriver(h)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await entered.wait()
    let alias = Task { await driver.shutdown() }
    await aliasEntered.wait()
    XCTAssertEqual(commands.value, 0, "Old alias must not bypass the held original owner")
    release.open()
    let result = await joined.value
    let old = await alias.value
    if case .completed(let completion) = result {
      XCTAssertEqual(old, completion.shutdown)
    } else {
      XCTFail("Original joined owner must complete")
    }
    assertCompletion(result, ownership: .admitted)
    XCTAssertEqual(commands.value, 1)
    XCTAssertEqual(laneWaits.value, 1)
    XCTAssertEqual(h.system.signalCount.value, 1)
  }

  // Break: first returned old receipt is mistaken for first lifecycle invocation.
  func testLegacyGraceHeldRepeatedSnapshotReturnsAndJoinedStaysRefused() async throws {
    let h = try DriverHarness()
    let returned = DriverTestLocked(false)
    defer {
      resetJoinedHooks()
      h.prepareCleanup()
    }
    let driver = try makeDriver(h)
    let (handle, _) = try await start(h, driver: driver)
    let first = Task {
      let value = await driver.shutdown()
      returned.withValue { $0 = true }
      return value
    }
    await h.connection.closeEntered.wait(for: 1)
    let repeated = await driver.shutdown()
    XCTAssertFalse(repeated.child.stopped)
    XCTAssertFalse(returned.withValue { $0 }, "Original grace remains held at monotonic time0")
    let refused = await driver.shutdownJoined(after: handle)
    XCTAssertEqual(refused, .callerRefused(.legacyModeSelected))
    h.prepareCleanup()
    _ = await first.value
    let afterCleanup = await driver.shutdownJoined(after: handle)
    XCTAssertEqual(afterCleanup, refused)
    _ = try await driver.wait(for: handle)
  }

  // Break: caller cancellation propagates into the sole retained terminal task.
  func testCancelledMatchingCallerAndWrongLateKeyPreserveOwner() async throws {
    let h = try DriverHarness()
    let entered = DriverTestGate()
    let release = DriverTestGate()
    let commands = DriverTestCount()
    let laneWaits = DriverTestCount()
    defer {
      release.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.ownerStart = {
      entered.open()
      await release.wait()
    }
    SearchParentJoinedTestHooks.childShutdown = {
      if $0 == ObjectIdentifier(h.lifecycle) { commands.increment() }
    }
    SearchParentJoinedTestHooks.laneWait = { laneWaits.increment() }
    let driver = try makeDriver(h)
    let original = Task { await driver.shutdownJoined(after: nil) }
    await entered.wait()
    let matching = Task { await driver.shutdownJoined(after: nil) }
    matching.cancel()
    let wrong = await driver.shutdownJoined(
      after: SearchParentWireHandle(nonce: UUID(), requestID: UUID()))
    XCTAssertEqual(wrong, .callerRefused(.differentJoinOwner))
    release.open()
    let value = await original.value
    let cancelledValue = await matching.value
    XCTAssertEqual(cancelledValue, value)
    let repeated = await driver.shutdownJoined(after: nil)
    XCTAssertEqual(repeated, value)
    assertCompletion(value, ownership: .admitted)
    XCTAssertEqual(commands.value, 1)
    XCTAssertEqual(laneWaits.value, 1)
  }

  // Break: mechanical joining waits for a payload receipt or admits an active request.
  func testActiveAdmissionRefusalStillJoinsFailedBeginWithoutConsumingReceipt() async throws {
    let h = try DriverHarness()
    let entered = DriverTestGate()
    let release = DriverTestGate()
    defer {
      release.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.ownerStart = {
      entered.open()
      await release.wait()
    }
    let driver = try makeDriver(h)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await entered.wait()
    h.system.failPending()
    release.open()
    let result = await joined.value
    assertCompletion(result, ownership: .refused(.requestActive))
    let snapshot = await driver.testJoinedSnapshot()
    XCTAssertTrue(snapshot.receiptPresent, "Joining must not steal the only payload receipt")
    let outcome = try await driver.wait(for: handle)
    guard case .failed(_, .launchFailed) = outcome else {
      return XCTFail("Actual launch failure expected")
    }
    let repeated = await driver.shutdownJoined(after: handle)
    XCTAssertEqual(repeated, result, "Consumption cannot repair first ownership refusal")
  }

  // Break: result receipt is consumed/discarded or ownership is upgraded by cleanup.
  func testUnconsumedReceiptRefusalRemainsAfterActualConsumption() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let staged = DriverTestGate()
    defer {
      resetJoinedHooks()
      h.releaseAllGates()
    }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000,
      observe: { if case .coordinatorScopeExited = $0 { staged.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await staged.wait()
    let result = await driver.shutdownJoined(after: handle)
    assertCompletion(result, ownership: .refused(.receiptUnconsumed))
    let retained = await driver.testJoinedSnapshot()
    XCTAssertTrue(retained.receiptPresent)
    let outcome = try await driver.wait(for: handle)
    XCTAssertEqual(outcome, expectedSuccess(identity))
    let repeated = await driver.shutdownJoined(after: handle)
    XCTAssertEqual(repeated, result)
  }

  func testObserverPresentRefusalPreservesActualOutcome() async throws {
    try await joinedObserver(abandon: false, cancellation: 0)
  }
  func testJoinedAbandonDeliversExistingObserverBeforeDiscard() async throws {
    try await joinedObserver(abandon: true, cancellation: 0)
  }
  func testJoinedAbandonPreservesCancellationBeforePublication() async throws {
    try await joinedObserver(abandon: true, cancellation: 1)
  }
  func testJoinedAbandonPreservesCancellationAtDeliveryClaim() async throws {
    try await joinedObserver(abandon: true, cancellation: 2)
  }

  // Break: a final predicate transition loses its wake or parent snapshot returns early.
  func testHeldReadOwnerRequiresFinalWakeAndRescuesMutationFinitely() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let readerEntered = DriverTestGate()
    let readerRelease = DriverTestGate()
    let mechanicalWait = DriverTestGate()
    let sessionReleased = DriverTestGate()
    defer {
      readerRelease.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentDriverTestHooks.sessionExit = { _ in
      readerEntered.open()
      await readerRelease.wait()
    }
    SearchParentJoinedTestHooks.mechanicalWaitInstalled = { mechanicalWait.open() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000,
      observe: { if case .sessionReleased = $0 { sessionReleased.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await readerEntered.wait()
    await mechanicalWait.wait()
    let held = await driver.testJoinedSnapshot()
    XCTAssertFalse(held.mechanicalReady)
    XCTAssertFalse(held.committed)
    readerRelease.open()
    await sessionReleased.wait()
    let released = await driver.testJoinedSnapshot()
    XCTAssertTrue(released.mechanicalReady)
    XCTAssertFalse(released.wakeRegistered, "A ready parent must retire the exact terminal wake")
    await driver.testRescueJoinedWake()
    assertCompletion(await joined.value, ownership: .admitted)
  }

  // Break: readiness notification before waiter registration is forgotten.
  func testMechanicalReadinessBeforeRegistrationDoesNotLoseWake() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let childEntered = DriverTestGate()
    let childRelease = DriverTestGate()
    let sessionReleased = DriverTestGate()
    let installations = DriverTestCount()
    defer {
      childRelease.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.originalChild = { _ in
      childEntered.open()
      await childRelease.wait()
    }
    SearchParentJoinedTestHooks.mechanicalWaitInstalled = { installations.increment() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000,
      observe: { if case .sessionReleased = $0 { sessionReleased.open() } })
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await childEntered.wait()
    await sessionReleased.wait()
    let ready = await driver.testJoinedSnapshot()
    XCTAssertTrue(ready.mechanicalReady)
    XCTAssertFalse(ready.committed)
    childRelease.open()
    assertCompletion(await joined.value, ownership: .admitted)
    XCTAssertEqual(
      installations.value, 0, "Already ready predicate must not install a stale waiter")
  }

  // Break: an original pending child is replaced after real reaping/close cleanup.
  func testOriginalPendingChildRemainsPendingAfterRealCleanup() async throws {
    let h = try DriverHarness()
    let readerEntered = DriverTestGate()
    let readerRelease = DriverTestGate()
    let childEntered = DriverTestGate()
    let childRelease = DriverTestGate()
    let adoptedReleased = DriverTestGate()
    let original = DriverTestLocked<SearchChildShutdown?>(nil)
    let commands = DriverTestCount()
    let graceInstalled = DriverTestGate()
    let grace = DriverTestLocked<UInt64>(0)
    defer {
      readerRelease.open()
      childRelease.open()
      resetJoinedHooks()
      h.prepareCleanup()
    }
    SearchParentDriverTestHooks.sessionExit = { _ in
      readerEntered.open()
      await readerRelease.wait()
    }
    SearchParentJoinedTestHooks.originalChild = { value in
      original.withValue { $0 = value }
      childEntered.open()
      await childRelease.wait()
    }
    SearchParentJoinedTestHooks.childShutdown = {
      if $0 == ObjectIdentifier(h.lifecycle) { commands.increment() }
    }
    SearchChildLifecycleTestHooks.afterAdoptedRelease = { _ in adoptedReleased.open() }
    SearchParentJoinedTestHooks.shutdownGraceInstalled = { deadline in
      grace.withValue { $0 = deadline }
      graceInstalled.open()
    }
    let driver = try makeDriver(h)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await readerEntered.wait()
    await graceInstalled.wait()
    XCTAssertEqual(grace.withValue { $0 }, 100_000_000)
    h.timers.fireDue(at: h.clock.advance(by: grace.withValue { $0 } - h.clock.now))
    await childEntered.wait()
    XCTAssertEqual(original.withValue { $0?.stopped }, false)
    h.prepareCleanup()
    await adoptedReleased.wait()
    readerRelease.open()
    childRelease.open()
    let result = await joined.value
    if case .completed(let completion) = result {
      XCTAssertEqual(completion.shutdown.child, original.withValue { $0 })
      XCTAssertFalse(completion.shutdown.child.stopped)
      XCTAssertTrue(completion.shutdown.parentLaneSettled)
      XCTAssertEqual(completion.laneStop, .acknowledged)
      let repeated = await driver.shutdownJoined(after: handle)
      XCTAssertEqual(repeated, result)
    } else {
      XCTFail("Diagnostic joined completion expected")
    }
    XCTAssertEqual(commands.value, 1)
  }

  // Break: parent readiness substitutes for the actual lane loop-stop acknowledgement.
  func testHeldLaneLoopAcknowledgementPreventsCommittedCompletion() async throws {
    let h = try DriverHarness()
    let loop = DriverTestBlockingGate()
    let boundary = DriverTestGate()
    let waits = DriverTestCount()
    defer {
      loop.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.loopStop = { loop.waitOnCodecThread() }
    SearchParentJoinedTestHooks.laneJoinBoundary = { boundary.open() }
    SearchParentJoinedTestHooks.laneWait = { waits.increment() }
    let driver = try makeDriver(h)
    let joined = Task { await driver.shutdownJoined(after: nil) }
    await loop.entered.wait()
    await boundary.wait()
    await waits.wait(for: 1)
    let held = await driver.testJoinedSnapshot()
    XCTAssertTrue(held.mechanicalReady)
    XCTAssertFalse(held.committed, "Held real loop-stop acknowledgement cannot be bypassed")
    XCTAssertEqual(waits.value, 1)
    loop.open()
    assertCompletion(await joined.value, ownership: .admitted)
  }

  // Break: lane join failure is normalized as an acknowledgement/clean parent.
  func testConflictingLaneObserverNormalizesFiniteFailure() async throws {
    let h = try DriverHarness()
    let ownerEntered = DriverTestGate()
    let ownerRelease = DriverTestGate()
    let installed = DriverTestGate()
    let loop = DriverTestBlockingGate()
    defer {
      ownerRelease.open()
      loop.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.ownerStart = {
      ownerEntered.open()
      await ownerRelease.wait()
    }
    SearchParentJoinedTestHooks.laneObserverInstalled = { installed.open() }
    SearchParentJoinedTestHooks.loopStop = { loop.waitOnCodecThread() }
    let driver = try makeDriver(h)
    let joined = Task { await driver.shutdownJoined(after: nil) }
    await ownerEntered.wait()
    let competing = Task { () -> Bool in
      do {
        try await driver.testInstallLaneObserver()
        return true
      } catch { return false }
    }
    await installed.wait()
    ownerRelease.open()
    await loop.entered.wait()
    let result = await joined.value
    if case .completed(let completion) = result {
      XCTAssertEqual(completion.ownership, .admitted)
      XCTAssertEqual(completion.laneStop, .failed)
      XCTAssertFalse(completion.shutdown.parentLaneSettled)
      XCTAssertEqual(completion.shutdown.retainedParentLanes, 1)
      XCTAssertTrue(completion.shutdown.child.stopped)
    } else {
      XCTFail("Finite normalized failure expected")
    }
    loop.open()
    let competingAcknowledged = await competing.value
    XCTAssertTrue(competingAcknowledged)
  }

  // Break: busy codec body is absent from mechanical retirement authority.
  func testHeldCodecBodyCannotBeReportedAsJoined() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let body = DriverTestBlockingGate()
    let childReturned = DriverTestGate()
    defer {
      body.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentJoinedTestHooks.originalChild = { _ in childReturned.open() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle,
      accumulatorFactory: { _ in
        body.waitOnCodecThread()
        return DriverTestAccumulator()
      },
      maximumWireBytesPerChild: 1_000_000)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7291, connection: h.connection)
    await h.connection.waitForWriteCalls(2)
    h.connection.offer(try DriverTestWire.childHello(generation: generation))
    await body.entered.wait()
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await childReturned.wait()
    let held = await driver.testJoinedSnapshot()
    XCTAssertFalse(held.mechanicalReady)
    XCTAssertFalse(held.committed)
    body.open()
    assertCompletion(await joined.value, ownership: .refused(.requestActive))
    let outcome = try await driver.wait(for: handle)
    guard case .failed(_, .shutDown) = outcome else {
      return XCTFail("Actual shutdown failure expected")
    }
  }

  // Break: acknowledged work receipt substitutes for completion-closure scope return.
  func testHeldCodecCompletionScopeRequiresExistingLaneStop() async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let completionScope = DriverTestBlockingGate()
    let boundary = DriverTestGate()
    let discardOwner = DriverTestLocked<UUID?>(nil)
    defer {
      completionScope.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    let driver = try makeDriver(h)
    let (handle, identity) = try await start(h, driver: driver)
    h.connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    SearchParentJoinedTestHooks.discardWorkAdmitted = { owner in
      discardOwner.withValue { $0 = owner }
    }
    SearchParentJoinedTestHooks.completionReturning = { owner in
      if discardOwner.withValue({ $0 == owner }) { completionScope.waitOnCodecThread() }
    }
    SearchParentJoinedTestHooks.laneJoinBoundary = { boundary.open() }
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await completionScope.entered.wait()
    await boundary.wait()
    let held = await driver.testJoinedSnapshot()
    XCTAssertTrue(held.mechanicalReady)
    XCTAssertFalse(held.committed)
    completionScope.open()
    assertCompletion(await joined.value, ownership: .admitted)
  }

  func testHeldRealCloseAcknowledgementPreventsJoinedCompletion() async throws {
    try await joinedChildAcknowledgement(holdClose: true)
  }
  func testHeldConsumingReapPreventsJoinedCompletion() async throws {
    try await joinedChildAcknowledgement(holdClose: false)
  }

  private func joinedChildAcknowledgement(holdClose: Bool) async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = holdClose
    let connection = DriverTestConnection(holdClose: holdClose)
    let released = DriverTestGate()
    let closeAcknowledged = DriverTestGate()
    defer {
      resetJoinedHooks()
      connection.releaseAllGates()
      h.prepareCleanup()
    }
    SearchChildLifecycleTestHooks.afterAdoptedRelease = { _ in released.open() }
    SearchParentJoinedTestHooks.closeAcknowledged = { _ in closeAcknowledged.open() }
    let driver = try makeDriver(h)
    let handle = try await driver.submit(job())
    await h.system.launchCount.wait(for: 1)
    let generation = try XCTUnwrap(h.system.generations.first)
    h.system.deliver(generation: generation, pid: 7292, connection: connection)
    await connection.waitForWriteCalls(2)
    connection.offer(try DriverTestWire.childHello(generation: generation))
    await connection.waitForWriteCalls(7)
    let identity = try SearchWireIdentity(
      generation: generation, requestID: handle.requestID, ordinal: 1)
    connection.offer(try DriverTestWire.success(identity: identity))
    _ = try await driver.wait(for: handle)
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await connection.closeEntered.wait(for: 1)
    let held = await driver.testJoinedSnapshot()
    XCTAssertFalse(held.committed)
    XCTAssertFalse(released.isOpen, "Both adopted acknowledgements are required")
    if holdClose {
      connection.closeRelease.open()
    } else {
      await closeAcknowledged.wait()
      h.system.prepareReap()
      // Actual maintenance was installed before shutdown grace on the same control
      // turn. With real close acknowledged, its consuming reap settles first.
      h.timers.fireDue(at: h.clock.advance(by: 100_000_000))
    }
    await released.wait()
    let result = await joined.value
    assertCompletion(result, ownership: .admitted)
    if case .completed(let completion) = result { XCTAssertTrue(completion.shutdown.child.stopped) }
    XCTAssertEqual(h.system.signalCount.value, 1)
  }

  private func joinedObserver(abandon: Bool, cancellation: Int) async throws {
    let h = try DriverHarness()
    h.system.reapOnSignal = true
    let installed = DriverTestGate()
    let sourceEntered = DriverTestGate()
    let sourceRelease = DriverTestGate()
    let ownerEntered = DriverTestGate()
    let ownerRelease = DriverTestGate()
    let abandoned = DriverTestGate()
    let staged = DriverTestGate()
    let delivered = DriverTestCount()
    defer {
      sourceRelease.open()
      ownerRelease.open()
      resetJoinedHooks()
      h.releaseAllGates()
    }
    SearchParentDriverTestHooks.scopeExit = { _ in
      sourceEntered.open()
      await sourceRelease.wait()
    }
    SearchParentJoinedTestHooks.ownerStart = {
      ownerEntered.open()
      await ownerRelease.wait()
    }
    SearchParentJoinedTestHooks.abandoned = { abandoned.open() }
    let driver = try SearchParentWireDriver(
      lifecycle: h.lifecycle, accumulatorFactory: h.accumulatorFactory,
      maximumWireBytesPerChild: 1_000_000,
      observe: {
        if case .observerInstalled = $0 { installed.open() }
        if case .coordinatorScopeExited = $0 { staged.open() }
        if case .resultDelivered = $0 { delivered.increment() }
      })
    let (handle, identity) = try await start(h, driver: driver)
    let observer = Task { () -> Result<SearchParentWireOutcome, Error> in
      do { return .success(try await driver.wait(for: handle)) } catch { return .failure(error) }
    }
    await installed.wait()
    h.connection.offer(try DriverTestWire.success(identity: identity))
    await sourceEntered.wait()
    let joined = Task { await driver.shutdownJoined(after: handle) }
    await ownerEntered.wait()
    var abandoning: Task<Void, Never>?
    if abandon {
      abandoning = Task { await driver.testJoinedAbandon() }
      await abandoned.wait()
      do {
        _ = try await driver.wait(for: handle)
        XCTFail("New observer after joined abandon must be refused")
      } catch { XCTAssertEqual(error as? SearchParentWireDriverError, .shutDown) }
    }
    if cancellation == 1 { observer.cancel() }
    if cancellation == 2 { SearchParentDriverTestHooks.beforeClaim = { observer.cancel() } }
    sourceRelease.open()
    ownerRelease.open()
    await staged.wait()
    let state = await driver.testJoinedSnapshot()
    XCTAssertFalse(state.observerPresent, "Publication must settle the existing observer claim")
    if abandon { XCTAssertFalse(state.receiptPresent, "Only unclaimed remainder may be discarded") }
    // An exact wrong-publication mutant is rescued only AFTER its explicit assertions.
    await driver.testRescueOrphanedObserver()
    let outcome = await observer.value
    if cancellation == 0 {
      if case .success(let value) = outcome {
        XCTAssertEqual(value, expectedSuccess(identity))
      } else {
        XCTFail("Existing observer must receive its one actual outcome")
      }
      XCTAssertEqual(delivered.value, 1)
    } else {
      if case .failure(let error) = outcome {
        XCTAssertTrue(error is CancellationError)
      } else {
        XCTFail("Original cancellation arbitration must win once")
      }
      XCTAssertEqual(delivered.value, 0)
    }
    let result = await joined.value
    assertCompletion(result, ownership: .refused(.observerPresent))
    if let abandoning { await abandoning.value }
    let repeated = await driver.shutdownJoined(after: handle)
    XCTAssertEqual(repeated, result)
  }

  private func assertCompletion(
    _ result: SearchParentJoinedShutdownResult,
    ownership: SearchParentJoinedOwnership,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .completed(let value) = result else {
      return XCTFail("Joined completion expected", file: file, line: line)
    }
    XCTAssertEqual(value.ownership, ownership, file: file, line: line)
    XCTAssertEqual(value.laneStop, .acknowledged, file: file, line: line)
    XCTAssertTrue(value.shutdown.parentLaneSettled, file: file, line: line)
    XCTAssertEqual(value.shutdown.retainedParentLanes, 0, file: file, line: line)
  }
  private func expectedSuccess(_ identity: SearchWireIdentity) -> SearchParentWireOutcome {
    .completed(
      identity: identity, source: "x",
      output: .init(matches: [NSRange(location: 0, length: 1)], replacement: nil))
  }
  private func resetJoinedHooks() {
    SearchParentJoinedTestHooks.ownerStart = nil
    SearchParentJoinedTestHooks.originalChild = nil
    SearchParentJoinedTestHooks.mechanicalWaitInstalled = nil
    SearchParentJoinedTestHooks.laneJoinBoundary = nil
    SearchParentJoinedTestHooks.legacyEntry = nil
    SearchParentJoinedTestHooks.abandoned = nil
    SearchParentJoinedTestHooks.childShutdown = nil
    SearchParentJoinedTestHooks.closeAcknowledged = nil
    SearchParentJoinedTestHooks.shutdownGraceInstalled = nil
    SearchParentJoinedTestHooks.laneWait = nil
    SearchParentJoinedTestHooks.laneObserverInstalled = nil
    SearchParentJoinedTestHooks.loopStop = nil
    SearchParentJoinedTestHooks.completionReturning = nil
    SearchParentJoinedTestHooks.discardWorkAdmitted = nil
    SearchParentDriverTestHooks.scopeExit = nil
    SearchParentDriverTestHooks.sessionExit = nil
    SearchParentDriverTestHooks.beforeClaim = nil
    SearchChildLifecycleTestHooks.afterAdoptedRelease = nil
  }
}
