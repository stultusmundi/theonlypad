// SPDX-License-Identifier: MIT
// Test-first candidate; no productive owner implementation is part of this packet.
import Foundation
import XCTest

@testable import NativeLanguageCatalogComponent
@testable import PadCore

@MainActor final class NativeLanguageCatalogOwnerTests: XCTestCase {
  // Catches eager constructor I/O or a fabricated initial publication. Inert baseline may pass.
  func testConstructionIsLazyAndInitiallyUnconfirmed() async throws {
    try await withCapsule { capsule in
      let script = CatalogReadScript(store: capsule.store, steps: [])
      let owner = NativeLanguageCatalogOwner(read: { try script.read() })
      try await withOwner(owner, script: script) { owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        XCTAssertEqual(script.facts.count, 0)
        XCTAssertTrue(probe.states.isEmpty)
        if case .active = owner.state.lifetime {} else { XCTFail("New owner must be active") }
        XCTAssertNil(owner.state.activeRequestID)
        XCTAssertNil(owner.state.lastSettledRequestID)
        XCTAssertNil(owner.state.current)
        XCTAssertNil(owner.state.failure)
      }
    }
  }

  // Catches fake empty fallback or accidental store/directory creation on a missing catalog.
  func testDefaultStoreMissingCatalogPublishesGenuineEmptyReadWithoutCreatingDirectory()
    async throws
  {
    try await withCapsule { capsule in
      try await withOwner(NativeLanguageCatalogOwner(store: capsule.store)) { owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        guard let id = startedID(owner.requestLoad()) else { return }
        XCTAssertEqual(owner.state.activeRequestID, id)
        XCTAssertEqual(probe.states.count, 1)
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertNotNil(owner.state.current)
        XCTAssertNil(owner.state.failure)
        XCTAssertNil(owner.state.activeRequestID)
        XCTAssertEqual(owner.state.lastSettledRequestID, id)
        XCTAssertEqual(owner.state.current?.requestID, id)
        XCTAssertEqual(owner.state.current?.catalog.generation, 0)
        XCTAssertEqual(owner.state.current?.catalog.definitions.count, 0)
        XCTAssertEqual(owner.state.current?.catalog.overrides.count, 0)
        XCTAssertEqual(probe.states.count, 2)
        XCTAssertEqual(probe.deliveryOnMain, [true, true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: capsule.store.directory.path))
      }
    }
  }

  // Catches bypassing actual default store, dropping Unicode/revisions, or executing read on main.
  func testDefaultStoreReadsPopulatedCatalogAndReadClosureRunsOffMain() async throws {
    try await withCapsule(populated: true) { capsule in
      let before = try Data(contentsOf: capsule.file)
      // Independent genuine read, not an expected value reconstructed by the owner.
      let expectedCatalog = try await Task.detached(priority: .utility) {
        try capsule.store.load().snapshot
      }.value
      let expectedCanonicalBytes = try LanguageCatalogCodec.encode(expectedCatalog)
      try await withOwner(NativeLanguageCatalogOwner(store: capsule.store)) { owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        guard let id = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertEqual(owner.state.current?.requestID, id)
        XCTAssertNotNil(owner.state.current)
        guard let current = owner.state.current else { return }
        assertPopulated(current.catalog)
        XCTAssertEqual(try LanguageCatalogCodec.encode(current.catalog), expectedCanonicalBytes)
        XCTAssertEqual(probe.deliveryOnMain, [true, true])
      }
      let step = CatalogReadStep("actual store off-main")
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        guard let id = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertEqual(step.facts.onMain, false)
        XCTAssertTrue(step.facts.finished)
        XCTAssertEqual(script.facts.count, 1)
        XCTAssertEqual(owner.state.current?.requestID, id)
        XCTAssertNotNil(owner.state.current)
        guard let current = owner.state.current else { return }
        assertPopulated(current.catalog)
        XCTAssertEqual(try LanguageCatalogCodec.encode(current.catalog), expectedCanonicalBytes)
        XCTAssertEqual(probe.deliveryOnMain, [true, true])
      }
      XCTAssertEqual(try Data(contentsOf: capsule.file), before)
    }
  }

  // Catches a swallowed real decode failure, fabricated confirmed empty catalog, or storage repair.
  func testInitialLoadFailurePublishesFailureWithoutCatalogOrDiskMutation() async throws {
    try await withCapsule(corrupt: true) { capsule in
      let before = try Data(contentsOf: capsule.file)
      let entries = try FileManager.default.contentsOfDirectory(
        atPath: capsule.store.directory.path
      ).sorted()
      try await withOwner(NativeLanguageCatalogOwner(store: capsule.store)) { owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        guard let id = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertNil(owner.state.current)
        XCTAssertNil(owner.state.activeRequestID)
        XCTAssertEqual(owner.state.lastSettledRequestID, id)
        XCTAssertEqual(owner.state.failure?.requestID, id)
        XCTAssertNotNil(owner.state.failure)
        if let failure = owner.state.failure {
          XCTAssertEqual(failure.underlyingError as? BoundedProfileJSON.Failure, .invalid)
        }
        XCTAssertEqual(probe.states.count, 2)
      }
      XCTAssertEqual(try Data(contentsOf: capsule.file), before)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: capsule.store.directory.path).sorted(),
        entries)
    }
  }

  // Catches clearing last-good state on reload failure or treating equal bytes as same publication.
  func testFailedReloadKeepsLastConfirmedPublicationAndRetryClearsOnlyOnSuccess() async throws {
    try await withCapsule(populated: true) { capsule in
      let first = CatalogReadStep("first confirmed")
      let failed = CatalogReadStep("selected reload failure", outcome: .failure)
      let retry = CatalogReadStep("held retry", held: true)
      let script = CatalogReadScript(store: capsule.store, steps: [first, failed, retry])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe(terminals: 3)
        owner.onChange = { probe.receive($0) }
        guard let firstID = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertNotNil(owner.state.current)
        guard let previous = owner.state.current else { return }
        XCTAssertEqual(previous.requestID, firstID)
        guard let failedID = startedID(owner.requestLoad()) else { return }
        XCTAssertNotEqual(failedID, firstID)
        await fulfillment(of: [probe.terminals[1]], timeout: 3)
        try assertSameCurrent(owner.state.current, previous)
        XCTAssertEqual(owner.state.failure?.requestID, failedID)
        XCTAssertEqual(
          owner.state.failure?.underlyingError as? CatalogFixtureFailure, .selectedFailure)
        XCTAssertEqual(owner.state.lastSettledRequestID, failedID)
        guard let retryID = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [retry.entered], timeout: 3)
        try assertSameCurrent(owner.state.current, previous)
        XCTAssertEqual(owner.state.activeRequestID, retryID)
        XCTAssertEqual(owner.state.failure?.requestID, failedID)
        XCTAssertFalse(retry.facts.finished)
        retry.release()
        await fulfillment(of: [probe.terminals[2]], timeout: 3)
        XCTAssertNotNil(owner.state.current)
        XCTAssertNotEqual(owner.state.current?.id, previous.id)
        XCTAssertEqual(owner.state.current?.requestID, retryID)
        XCTAssertEqual(owner.state.lastSettledRequestID, retryID)
        XCTAssertNil(owner.state.failure)
        XCTAssertEqual(owner.state.current?.catalog.generation, 1)
        XCTAssertEqual(script.facts.count, 3)
        XCTAssertEqual(script.facts.maximum, 1)
        XCTAssertEqual(probe.states.count, 6)
      }
    }
  }

  // Catches parallel or silently queued reloads and busy-refusal notifications.
  func testBusyRequestsDoNotLaunchQueueOrNotify() async throws {
    try await withCapsule { capsule in
      let step = CatalogReadStep("held first", held: true)
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        guard let id = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [step.entered], timeout: 3)
        for _ in 0..<3 { assertBusy(owner.requestLoad(), matching: id) }
        XCTAssertEqual(owner.state.activeRequestID, id)
        XCTAssertEqual(script.facts.count, 1)
        XCTAssertEqual(script.facts.active, 1)
        XCTAssertEqual(probe.states.count, 1)
        step.release()
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertNil(owner.state.activeRequestID)
        XCTAssertEqual(script.facts.count, 1)
        // This finite observation checks the current settlement, not every future schedule.
        // Source review must also prohibit a queued reload or deferred successor launch.
        await owner.invalidateAndWait()
        XCTAssertEqual(script.facts.count, 1)
        XCTAssertEqual(script.facts.maximum, 1)
        XCTAssertEqual(probe.states.count, 2)
      }
    }
  }

  // Catches notifying loading before reserving admission.
  func testLoadingObserverReentryIsBusy() async throws {
    try await withCapsule { capsule in
      let step = CatalogReadStep("loading reentry")
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe()
        var nested: NativeLanguageCatalogAdmission?
        owner.onChange = { state in
          probe.receive(state)
          if state.activeRequestID != nil, nested == nil {
            nested = owner.requestLoad()
          }
        }
        guard let id = startedID(owner.requestLoad()) else { return }
        XCTAssertNotNil(nested)
        if let nested { assertBusy(nested, matching: id) }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertEqual(script.facts.count, 1)
        XCTAssertEqual(probe.states.count, 2)
        XCTAssertEqual(owner.state.current?.requestID, id)
      }
    }
  }

  // Catches launching from the reservation captured before a reentrant invalidation callback.
  func testLoadingObserverInvalidationPreventsActualReadLaunch() async throws {
    try await withCapsule { capsule in
      let script = CatalogReadScript(store: capsule.store, steps: [])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        var notifications = 0
        owner.onChange = { state in
          notifications += 1
          XCTAssertNotNil(state.activeRequestID)
          owner.invalidate()
        }
        let result = owner.requestLoad()
        XCTAssertEqual(notifications, 1, "Loading observer must actually run before withdrawal")
        assertRefused(result)
        XCTAssertEqual(script.facts.count, 0)
        assertInvalidated(owner.state)
        XCTAssertNil(owner.onChange)
        await owner.invalidateAndWait()
        await owner.invalidateAndWait()
        XCTAssertEqual(script.facts.count, 0)
        XCTAssertEqual(notifications, 1)
      }
    }
  }

  // Catches a retired producer/defer clearing a successor started on the actual callback stack.
  func testTerminalObserverSuccessorRetainsItsWorkerAndState() async throws {
    try await withCapsule { capsule in
      let first = CatalogReadStep("A")
      let second = CatalogReadStep("B", held: true)
      let script = CatalogReadScript(store: capsule.store, steps: [first, second])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe(terminals: 2)
        var successor: NativeLanguageCatalogAdmission?
        var firstPublication: NativeLanguageCatalogPublication?
        probe.terminalAction = { state in
          if successor == nil {
            firstPublication = state.current
            successor = owner.requestLoad()
          }
        }
        owner.onChange = { probe.receive($0) }
        guard let firstID = startedID(owner.requestLoad()) else { return }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        XCTAssertNotNil(successor)
        guard let successor, let secondID = startedID(successor) else { return }
        await fulfillment(of: [second.entered], timeout: 3)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(owner.state.activeRequestID, secondID)
        XCTAssertEqual(owner.state.current?.requestID, firstID)
        assertBusy(owner.requestLoad(), matching: secondID)
        XCTAssertEqual(script.facts.count, 2)
        XCTAssertEqual(script.facts.maximum, 1)
        XCTAssertFalse(second.facts.finished)
        second.release()
        await fulfillment(of: [probe.terminals[1]], timeout: 3)
        XCTAssertEqual(owner.state.current?.requestID, secondID)
        XCTAssertNotEqual(owner.state.current?.id, firstPublication?.id)
        XCTAssertNil(owner.state.activeRequestID)
        XCTAssertEqual(probe.states.count, 4)
      }
    }
  }

  // Catches a successful old frame reviving state after its own terminal observer invalidates.
  func testTerminalObserverInvalidationCannotPublishAgain() async throws {
    try await withCapsule { capsule in
      let step = CatalogReadStep("terminal withdrawal")
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe()
        probe.terminalAction = { state in
          XCTAssertNotNil(state.current)
          owner.invalidate()
        }
        owner.onChange = { probe.receive($0) }
        guard startedID(owner.requestLoad()) != nil else { return }
        await fulfillment(of: [probe.terminals[0]], timeout: 3)
        assertInvalidated(owner.state)
        XCTAssertNil(owner.onChange)
        assertRefused(owner.requestLoad())
        await owner.invalidateAndWait()
        assertInvalidated(owner.state)
        XCTAssertEqual(probe.states.count, 2)
        XCTAssertEqual(script.facts.count, 1)
      }
    }
  }

  // Catches accepting either successful or failed late results after authority withdrawal.
  func testInvalidationSuppressesLateSuccessAndFailure() async throws {
    for outcome in [CatalogReadStep.Outcome.actualStore, .failure] {
      try await withCapsule { capsule in
        let step = CatalogReadStep("late result", held: true, outcome: outcome)
        let script = CatalogReadScript(store: capsule.store, steps: [step])
        try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script)
        { owner in
          let probe = CatalogStateProbe()
          owner.onChange = { probe.receive($0) }
          guard startedID(owner.requestLoad()) != nil else { return }
          await fulfillment(of: [step.entered], timeout: 3)
          XCTAssertFalse(step.facts.finished)
          owner.invalidate()
          assertInvalidated(owner.state)
          assertRefused(owner.requestLoad())
          step.release()
          await owner.invalidateAndWait()
          XCTAssertTrue(step.facts.finished)
          XCTAssertEqual(script.facts.active, 0)
          assertInvalidated(owner.state)
          XCTAssertEqual(probe.states.count, 1)
          XCTAssertNil(owner.onChange)
        }
      }
    }
  }

  // Catches synchronous joining on main or declaring cleanup before actual read completion.
  func testInvalidateAndWaitYieldsMainActorUntilActualWorkerCompletion() async throws {
    try await withCapsule { capsule in
      let step = CatalogReadStep("joined held read", held: true)
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        let probe = CatalogStateProbe()
        owner.onChange = { probe.receive($0) }
        guard startedID(owner.requestLoad()) != nil else { return }
        await fulfillment(of: [step.entered], timeout: 3)
        let joining = XCTestExpectation(description: "join task entered on MainActor")
        var joined = false
        let join = Task { @MainActor in
          joining.fulfill()
          await owner.invalidateAndWait()
          joined = true
        }
        await fulfillment(of: [joining], timeout: 3)
        // This main-actor continuation is the heartbeat while the worker is still held.
        XCTAssertTrue(Thread.isMainThread)
        assertInvalidated(owner.state)
        XCTAssertFalse(joined)
        XCTAssertFalse(step.facts.finished)
        step.release()
        await join.value
        XCTAssertTrue(joined)
        XCTAssertTrue(step.facts.finished)
        XCTAssertEqual(script.facts.active, 0)
        XCTAssertEqual(probe.states.count, 1)
        assertInvalidated(owner.state)
      }
    }
  }

  // Catches equating joining-task cancellation with cancellation/completion of synchronous read.
  func testCancelledJoinStillWaitsForActualWorkerCompletion() async throws {
    try await withCapsule { capsule in
      let step = CatalogReadStep("cancelled join read", held: true)
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        var notifications = 0
        owner.onChange = { _ in notifications += 1 }
        guard startedID(owner.requestLoad()) != nil else { return }
        await fulfillment(of: [step.entered], timeout: 3)
        let joining = XCTestExpectation(description: "cancellable join entered")
        var joined = false
        let join = Task { @MainActor in
          joining.fulfill()
          await owner.invalidateAndWait()
          joined = true
        }
        await fulfillment(of: [joining], timeout: 3)
        join.cancel()
        XCTAssertTrue(join.isCancelled)
        let heartbeat = Task { @MainActor in
          XCTAssertFalse(joined, "Cancelled join must remain pending while the read is held")
          XCTAssertFalse(step.facts.finished)
        }
        await heartbeat.value
        assertInvalidated(owner.state)
        XCTAssertFalse(joined)
        XCTAssertFalse(step.facts.finished)
        assertRefused(owner.requestLoad())
        step.release()
        await join.value
        XCTAssertTrue(joined)
        XCTAssertTrue(step.facts.finished)
        XCTAssertEqual(script.facts.count, 1)
        XCTAssertEqual(notifications, 1)
        assertInvalidated(owner.state)
      }
    }
  }

  // Catches losing a shared join or retaining/replaying a new observer after terminal invalidation.
  func testRepeatedInvalidationJoinsAndObserverReplacementCannotReviveOwner() async throws {
    try await withCapsule { capsule in
      let step = CatalogReadStep("shared join read", held: true)
      let script = CatalogReadScript(store: capsule.store, steps: [step])
      try await withOwner(NativeLanguageCatalogOwner(read: { try script.read() }), script: script) {
        owner in
        var oldCount = 0
        var replacementCount = 0
        owner.onChange = { _ in oldCount += 1 }
        owner.onChange = { _ in replacementCount += 1 }
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(replacementCount, 0)
        guard startedID(owner.requestLoad()) != nil else { return }
        await fulfillment(of: [step.entered], timeout: 3)
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(replacementCount, 1)
        let firstStarted = XCTestExpectation(description: "first join entered")
        let secondStarted = XCTestExpectation(description: "second join entered")
        var finishedJoins = 0
        let first = Task { @MainActor in
          firstStarted.fulfill()
          await owner.invalidateAndWait()
          finishedJoins += 1
        }
        let second = Task { @MainActor in
          secondStarted.fulfill()
          await owner.invalidateAndWait()
          finishedJoins += 1
        }
        await fulfillment(of: [firstStarted, secondStarted], timeout: 3)
        owner.invalidate()
        owner.invalidate()
        assertInvalidated(owner.state)
        XCTAssertEqual(finishedJoins, 0)
        XCTAssertFalse(step.facts.finished)
        weak var observerSentinel: CatalogObserverSentinel?
        do {
          let sentinel = CatalogObserverSentinel()
          observerSentinel = sentinel
          owner.onChange = { [sentinel] _ in _ = sentinel }
        }
        XCTAssertNil(observerSentinel, "Rejected post-invalidation observer must not be retained")
        XCTAssertNil(owner.onChange)
        assertRefused(owner.requestLoad())
        step.release()
        await first.value
        await second.value
        XCTAssertEqual(finishedJoins, 2)
        XCTAssertTrue(step.facts.finished)
        XCTAssertEqual(script.facts.count, 1)
        XCTAssertEqual(replacementCount, 1)
        assertInvalidated(owner.state)
      }
    }
  }
}
