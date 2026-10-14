// SPDX-License-Identifier: MIT
import Foundation
import PadCore
import XCTest

@testable import NativeApplicationSearchesComponent
@testable import SearchExecution

@MainActor final class NativeApplicationSearchesTests: XCTestCase {
  func testLazyFindOwnerIsSharedAcrossTwoActualWindowTickets() async throws {
    try await withTask2Fixture { f in
      XCTAssertEqual(f.factory.calls, 0)
      XCTAssertEqual(f.bridge.phase, .notCreated)
      guard let owner = f.owner() else { return }
      let same = try f.bridge.ownerForFind()
      XCTAssertTrue(owner === same)
      XCTAssertEqual(f.factory.calls, 1)
      let first = try owner.attachWindow(windowID: f.source.window, endpointID: f.source.endpoint)
      let second = try owner.attachWindow(windowID: UUID(), endpointID: UUID())
      f.tickets = [first, second]
      XCTAssertNotEqual(first, second)
      XCTAssertEqual(f.source.inspections, 0)
      XCTAssertEqual(f.source.captures, 0)
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertTrue(f.backend.submissions.isEmpty)
    }
  }

  func testFactoryReservationRefusesReentryAndRetriesOnlyThrownPreCreation() async throws {
    try await withTask2Fixture { f in
      var reentries = 0
      f.factory.onFactory = { [weak f] in
        guard let f else { return }
        reentries += 1
        XCTAssertEqual(f.bridge.phase, .constructing)
        do {
          _ = try f.bridge.ownerForFind()
          XCTFail("Factory reentrant Find must refuse")
        } catch {
          XCTAssertEqual(error as? NativeApplicationSearchRefusal, .constructionInProgress)
        }
        do {
          _ = try f.bridge.prepareQuitIfCreated()
          XCTFail("Factory reentrant Quit must refuse")
        } catch {
          XCTAssertEqual(error as? NativeApplicationSearchRefusal, .constructionInProgress)
        }
        XCTAssertEqual(f.factory.calls, 1)
      }
      guard let owner = f.owner() else { return }
      XCTAssertEqual(reentries, 1)
      XCTAssertTrue(try f.bridge.ownerForFind() === owner)
      XCTAssertEqual(f.factory.calls, 1)
    }
    try await withTask2Fixture { f in
      f.factory.throwNext = true
      var genuineThrow = false
      XCTAssertThrowsError(try f.bridge.ownerForFind()) {
        genuineThrow = ($0 as? Task2Failure) == .factory
        XCTAssertTrue(genuineThrow)
      }
      XCTAssertEqual(f.factory.calls, 1)
      XCTAssertEqual(f.bridge.phase, .notCreated)
      guard genuineThrow, f.factory.calls == 1 else { return }
      let owner = try f.bridge.ownerForFind()
      f.actualOwner = owner
      XCTAssertEqual(f.factory.calls, 2)
      XCTAssertEqual(f.bridge.phase, .open)
      XCTAssertTrue(try f.bridge.ownerForFind() === owner)
      XCTAssertEqual(f.factory.calls, 2)
    }
    try await withTask2Fixture { f in
      var actualPreparedReturn = false
      f.factory.beforeReturn = { [weak f] created in
        guard let f else { return }
        f.actualOwner = created
        do {
          _ = try created.prepareQuit()
          actualPreparedReturn = true
        } catch { XCTFail("Actual factory-owned preparation failed") }
      }
      XCTAssertThrowsError(try f.bridge.ownerForFind()) {
        XCTAssertEqual($0 as? NativeApplicationSearchRefusal, .retainedUnavailable)
      }
      XCTAssertTrue(actualPreparedReturn)
      XCTAssertEqual(f.factory.calls, 1)
      XCTAssertEqual(f.bridge.phase, .unavailable)
      guard actualPreparedReturn, f.factory.calls == 1 else { return }
      XCTAssertThrowsError(try f.bridge.ownerForFind()) {
        XCTAssertEqual($0 as? NativeApplicationSearchRefusal, .retainedUnavailable)
      }
      XCTAssertEqual(f.factory.calls, 1, "A returned unusable owner must never be replaced")
    }
  }

  func testQuitWithoutCreatedOwnerNeverInvokesFactory() async throws {
    try await withTask2Fixture { f in
      guard let prep = f.preparation() else { return }
      XCTAssertEqual(f.bridge.phase, .prepared)
      XCTAssertEqual(f.factory.calls, 0)
      XCTAssertEqual(try f.bridge.prepareQuitIfCreated(), prep)
      XCTAssertThrowsError(try f.bridge.ownerForFind())
      let native = Task2Gate()
      f.gates.append(native)
      let task = f.track(prep, observing: native, operation: { try await native.enter() })
      let event = await native.event.wait()
      XCTAssertEqual(event, .entered)
      guard event == .entered else {
        _ = await task.result
        return
      }
      XCTAssertEqual(f.completions, 0)
      XCTAssertEqual(f.factory.calls, 0)
      XCTAssertEqual(f.backend.joinCalls, 0)
      native.release()
      let completedAbsence = try await task.value
      XCTAssertEqual(completedAbsence, .noSearchOwner)
      // Search absence remains reserved through the caller's outer reply/explicit rollback.
      XCTAssertThrowsError(try f.bridge.ownerForFind())
      XCTAssertEqual(f.factory.calls, 0)
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .resumedNotCreated)
      XCTAssertEqual(f.bridge.phase, .notCreated)
      XCTAssertEqual(f.factory.calls, 0)
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .refused(.stalePreparation))
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertEqual(f.backend.joinCalls, 0)
    }
  }

  func testPreparationConsumesRealRequestResultAndApprovalBeforeCallbacks() async throws {
    try await withTask2Fixture { f in
      guard let owner = f.owner() else { return }
      try f.attach(owner)
      try f.start(replacing: true)
      let lease = try f.complete(0, replacement: "😀yx")
      guard let token = f.approval() else { return }
      var releasedBeforeReturn = false
      f.backend.onRelease = { [weak f] id in
        guard let f else { return }
        releasedBeforeReturn = id == lease && f.backend.released.contains(lease)
        XCTAssertTrue(releasedBeforeReturn)
        XCTAssertEqual(f.bridge.phase, .preparing)
        if case .prepared = owner.phase {
        } else {
          XCTFail("Actual owner must prepare before release callout")
        }
        do {
          _ = try f.bridge.ownerForFind()
          XCTFail("Preparing release callback Find must refuse")
        } catch {}  // Original generic refusal assertion accepts any thrown Swift error.
      }
      guard let prep = f.preparation() else { return }
      XCTAssertTrue(releasedBeforeReturn)
      XCTAssertTrue(f.backend.released.contains(lease))
      XCTAssertEqual(try f.bridge.prepareQuitIfCreated(), prep)
      XCTAssertEqual(f.backend.released.count, 1)
      XCTAssertEqual(f.bridge.phase, .prepared)
      XCTAssertFalse(try XCTUnwrap(f.session).resolveApproval(token, approved: true))
      XCTAssertEqual(f.source.replacements, 0)
      XCTAssertThrowsError(try f.start(replacing: false)) {
        XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .preparingQuit)
      }
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .resumedOwner)
      try f.start(replacing: false)
      let job = try f.backend.submission(1).job
      guard let second = f.preparation() else { return }
      XCTAssertTrue(f.backend.cancelled.contains(job))
      XCTAssertEqual(
        f.backend.pendingTerminalCount, 1, "Cancel alone cannot claim backend completion")
      XCTAssertEqual(f.backend.joinCalls, 0)
      XCTAssertNotEqual(prep, second)
      f.backend.deliver(1, .failed(.cancelled))
      XCTAssertEqual(f.backend.pendingTerminalCount, 0)
    }
  }

  func testVetoResumesOnlyExactPreparationWithoutRestoringOldRights() async throws {
    try await withTask2Fixture { f in
      guard let owner = f.owner() else { return }
      try f.attach(owner)
      try f.start(replacing: true)
      _ = try f.complete(0, replacement: "😀yx")
      guard let token = f.approval(), let prep = f.preparation() else { return }
      try await withTask2Fixture { other in
        guard other.owner() != nil, let foreign = other.preparation() else { return }
        XCTAssertEqual(f.bridge.resumeAfterVeto(foreign), .refused(.stalePreparation))
        XCTAssertEqual(f.bridge.phase, .prepared)
      }
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .resumedOwner)
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .refused(.stalePreparation))
      XCTAssertEqual(f.bridge.phase, .open)
      XCTAssertTrue(try f.bridge.ownerForFind() === owner)
      XCTAssertFalse(try XCTUnwrap(f.session).resolveApproval(token, approved: true))
      XCTAssertEqual(f.source.replacements, 0)
      XCTAssertTrue(f.backend.payloads.isEmpty)
      try f.start(replacing: false)
      _ = try f.complete(1)
      XCTAssertTrue(try XCTUnwrap(f.session).next())
      XCTAssertEqual(f.source.selections, [NSRange(location: 2, length: 1)])
    }
  }

  func testManagedPreparationReturnPrecedesAdmissionAndVetoLeavesExactPreparedState() async throws {
    try await withTask2Fixture { f in
      guard let owner = f.owner(), let prep = f.preparation() else { return }
      let native = Task2Gate()
      f.gates.append(native)
      let task = f.track(prep, observing: native, operation: { try await native.enter() })
      let event = await native.event.wait()
      XCTAssertEqual(event, .entered)
      guard event == .entered else {
        _ = await task.result
        return
      }
      XCTAssertEqual(f.backend.joinCalls, 0)
      XCTAssertEqual(f.completions, 0)
      XCTAssertThrowsError(try f.bridge.prepareQuitIfCreated()) {
        XCTAssertEqual($0 as? NativeApplicationSearchRefusal, .quitInProgress)
      }
      if case .prepared = owner.phase {
      } else {
        XCTFail("Search remains reversible during native wait")
      }
      XCTAssertThrowsError(try f.bridge.ownerForFind())
      native.release()
      let raw = try await task.value
      guard let observed = task2Terminal(raw) else { return }
      XCTAssertEqual(observed.latest, .observed(task2Success()))
      XCTAssertEqual(observed.disposition, .settled)
      XCTAssertEqual(f.backend.joinCalls, 1)
      XCTAssertEqual(f.bridge.phase, .terminal)
    }
    try await withTask2Fixture { f in
      guard f.owner() != nil, let prep = f.preparation() else { return }
      var nativeCalls = 0
      do {
        _ = try await f.bridge.completeQuit(
          prep,
          afterManagedPreparation: {
            nativeCalls += 1
            throw Task2Failure.veto
          })
        XCTFail("Actual native veto must propagate")
      } catch { XCTAssertEqual(error as? Task2Failure, .veto) }
      XCTAssertEqual(nativeCalls, 1)
      XCTAssertEqual(f.backend.joinCalls, 0)
      XCTAssertEqual(f.bridge.phase, .prepared)
      XCTAssertThrowsError(try f.bridge.ownerForFind())
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .resumedOwner)
      XCTAssertEqual(f.bridge.phase, .open)
    }
  }

  func testHeldTerminalObservationCannotReturnOrCancelActualOwnerJoinEarly() async throws {
    try await withTask2Fixture { f in
      guard let owner = f.owner(), let prep = f.preparation() else { return }
      let backendGate = Task2Gate()
      f.backend.joinHold = backendGate
      var nativeCalls = 0
      let task = f.track(prep, observing: backendGate, operation: { nativeCalls += 1 })
      let event = await backendGate.event.wait()
      XCTAssertEqual(event, .entered)
      guard event == .entered else {
        _ = await task.result
        return
      }
      XCTAssertEqual(nativeCalls, 1)
      XCTAssertEqual(f.backend.joinCalls, 1)
      XCTAssertEqual(owner.phase, .terminal)
      XCTAssertEqual(f.bridge.phase, .terminal)
      XCTAssertEqual(f.completions, 0)
      task.cancel()
      XCTAssertEqual(f.completions, 0)
      XCTAssertThrowsError(try f.bridge.ownerForFind())
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .refused(.terminal))
      backendGate.release()
      guard let observed = task2Terminal(try await task.value) else { return }
      XCTAssertEqual(observed.latest, .observed(task2Success()))
      XCTAssertFalse(f.backend.joinedTaskCancelled)
      XCTAssertEqual(f.backend.joinCalls, 1)
      XCTAssertEqual(f.factory.calls, 1)
    }
  }

  func testLaterExplicitQuitReusesOriginalJoinAndCanonicalParentWithFreshNativePreparation()
    async throws
  {
    for variant in ["uncertainParent", "localResidual", "changedParent"] {
      try await withTask2Fixture { f in
        let first =
          variant == "localResidual"
          ? task2Row("jobs") : task2WithLocalResidual(task2Row("parentLane"))
        let second =
          variant == "uncertainParent" ? task2SameParentWithNoResidual(first) : task2Success()
        f.backend.joinValues = [first, second]
        guard f.owner() != nil, let prep = f.preparation() else { return }
        var nativeCalls = 0
        let firstResult = try await f.bridge.completeQuit(
          prep, afterManagedPreparation: { nativeCalls += 1 })
        guard let original = task2Terminal(firstResult) else { return }
        XCTAssertEqual(original.first, .observed(first))
        XCTAssertEqual(original.latest, .observed(first))
        XCTAssertEqual(original.disposition, .unsettled)
        XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .refused(.terminal))
        XCTAssertEqual(f.backend.joinCalls, 1, "No automatic reobservation")
        guard let later = f.preparation() else { return }
        let secondResult = try await f.bridge.completeQuit(
          later, afterManagedPreparation: { nativeCalls += 1 })
        guard let refreshed = task2Terminal(secondResult) else { return }
        XCTAssertEqual(refreshed.join, original.join)
        XCTAssertEqual(refreshed.first, original.first)
        XCTAssertEqual(refreshed.latest, .observed(second))
        XCTAssertEqual(refreshed.disposition, variant == "localResidual" ? .settled : .unsettled)
        XCTAssertEqual(f.bridge.lastTerminalResult, .observed(second))
        XCTAssertEqual(nativeCalls, 2)
        XCTAssertEqual(f.backend.joinCalls, 2)
        XCTAssertEqual(f.factory.calls, 1)
        XCTAssertEqual(f.bridge.phase, .terminal)
      }
    }
  }

  func testCallbackAndStaleRefusalsDoNotAdmitOrReopen() async throws {
    try await withTask2Fixture { f in
      guard let owner = f.owner() else { return }
      try f.attach(owner)
      try f.start(replacing: false)
      var callbackCount = 0
      f.backend.onCancel = { [weak f] _ in
        guard let f else { return }
        callbackCount += 1
        XCTAssertEqual(f.bridge.phase, .preparing)
        do {
          _ = try f.bridge.prepareQuitIfCreated()
          XCTFail("Preparing cancel callback Quit must refuse")
        } catch {}  // Preserve original generic refusal requirement.
        do {
          _ = try f.bridge.ownerForFind()
          XCTFail("Preparing cancel callback Find must refuse")
        } catch {}  // Preserve original generic refusal requirement.
        // Authentic original owner-issued ID from its real prepared phase; no Test constructor.
        guard case .prepared(let actualQuit) = owner.phase else {
          XCTFail("Actual prepared owner missing in cancel callback")
          return
        }
        XCTAssertEqual(
          owner.admitShutdownJoined(after: actualQuit), .callerRefused(.synchronousCallbackActive))
        XCTAssertEqual(f.backend.joinCalls, 0)
      }
      guard let prep = f.preparation() else { return }
      XCTAssertEqual(callbackCount, 1)
      XCTAssertEqual(f.backend.joinCalls, 0)
      try await withTask2Fixture { other in
        guard other.owner() != nil, let foreign = other.preparation() else { return }
        var invalidNativeCalls = 0
        do {
          _ = try await f.bridge.completeQuit(
            foreign, afterManagedPreparation: { invalidNativeCalls += 1 })
          XCTFail("Foreign preparation must refuse")
        } catch { XCTAssertEqual(error as? NativeApplicationSearchRefusal, .stalePreparation) }
        XCTAssertEqual(invalidNativeCalls, 0)
      }
      f.backend.joinValues = [.callerRefused(.synchronousCallbackActive)]
      let value = try await f.bridge.completeQuit(prep, afterManagedPreparation: {})
      guard let result = task2Terminal(value) else { return }
      XCTAssertEqual(result.latest, .observed(.callerRefused(.synchronousCallbackActive)))
      XCTAssertEqual(result.disposition, .unsettled)
      XCTAssertEqual(f.bridge.resumeAfterVeto(prep), .refused(.terminal))
      XCTAssertThrowsError(try f.bridge.ownerForFind())
      XCTAssertEqual(f.factory.calls, 1)
      XCTAssertEqual(f.backend.joinCalls, 1)
    }
  }

  func testFixedNestedSettlementRequiresEveryRealFieldAndProductionResident() async throws {
    let rows = [
      "success", "admissionRefused", "parentRefused", "ownershipStale", "ownershipRequest",
      "ownershipObserver", "ownershipReceipt", "ownershipAbandoned", "laneStop", "parentLane",
      "parentRetained", "childPending", "childStopping", "childUnconfirmed", "channels",
      "driverPending",
      "driverOpen", "jobs", "leases", "activeZero", "activeExtra", "retained", "reserved",
    ]
    XCTAssertLessThanOrEqual(rows.count, 32)
    XCTAssertEqual(SearchAdmissionProductionAccounting().resident, 1_048_576)
    for row in rows {
      try await withTask2Fixture { f in
        let reported = task2Row(row)
        f.backend.joinValues = [reported]
        guard f.owner() != nil, let prep = f.preparation() else { return }
        let value = try await f.bridge.completeQuit(prep, afterManagedPreparation: {})
        guard let result = task2Terminal(value) else { return }
        XCTAssertEqual(result.first, .observed(reported))
        XCTAssertEqual(result.latest, .observed(reported))
        XCTAssertEqual(result.disposition, row == "success" ? .settled : .unsettled, row)
        XCTAssertEqual(f.bridge.phase, .terminal)
        XCTAssertEqual(f.backend.joinCalls, 1)
      }
    }
  }
}
private enum Task2Failure: Error, Equatable { case missing, bound, factory, veto }
private enum Task2Entry: Equatable { case entered, returnedWithoutEntry }

@MainActor private final class Task2Signal<Value> {
  private var value: Value?
  private var waiter: CheckedContinuation<Value, Never>?
  func send(_ incoming: Value) {
    // Sticky first actual event; no repeated notification.
    guard case .none = value else { return }
    value = incoming
    let pending = waiter
    waiter = nil
    pending?.resume(returning: incoming)
  }
  func wait() async -> Value {
    if let value { return value }
    return await withCheckedContinuation { continuation in
      guard waiter == nil else { preconditionFailure("Only one bounded signal waiter") }
      waiter = continuation
    }
  }
}

@MainActor private final class Task2Gate {
  let event = Task2Signal<Task2Entry>()
  private let permission = Task2Signal<Void>()
  var entries = 0, throwsVeto = false
  func enter() async throws {
    guard entries == 0 else {
      XCTFail("One-shot operation entered twice")
      throw Task2Failure.bound
    }
    entries += 1
    event.send(.entered)
    await permission.wait()
    if throwsVeto { throw Task2Failure.veto }
  }
  func release() { permission.send(()) }
  func returned() { event.send(.returnedWithoutEntry) }
}

@MainActor private final class Task2Factory {
  let backend: Task2Backend
  weak var bridge: NativeApplicationSearches?
  var calls = 0, throwNext = false
  var onFactory: (@MainActor () -> Void)?
  var beforeReturn: (@MainActor (ApplicationSearchOwner) -> Void)?
  init(_ backend: Task2Backend) { self.backend = backend }
  func make() throws -> ApplicationSearchOwner {
    guard calls < 2 else {
      XCTFail("Factory invocation bound")
      throw Task2Failure.bound
    }
    calls += 1
    let hook = onFactory
    onFactory = nil
    hook?()
    if throwNext {
      throwNext = false
      throw Task2Failure.factory
    }
    let owner = ApplicationSearchOwner(backend: backend)
    let finalHook = beforeReturn
    beforeReturn = nil
    finalHook?(owner)
    return owner
  }
}

@MainActor private enum Task2UnresolvedCustody {
  private static var fixture: Task2Fixture?
  static func reserve(_ incoming: Task2Fixture) -> Bool {
    guard fixture == nil || fixture === incoming else {
      XCTFail("One unresolved Task2 fixture slot already occupied")
      return false
    }
    fixture = incoming
    return true
  }
  static func joined(_ original: Task2Fixture) {
    guard fixture === original else {
      XCTFail("Exact cleanup custody mismatch")
      return
    }
    fixture = nil
  }
}

@MainActor private final class Task2Fixture {
  let backend = Task2Backend(), source = Task2Source()
  let factory: Task2Factory, bridge: NativeApplicationSearches
  var actualOwner: ApplicationSearchOwner?
  var tickets: [ApplicationSearchWindowID] = []
  var session: DocumentSearchSession?
  var sessionState: DocumentSearchSessionState = .idle
  var gates: [Task2Gate] = []
  var tasks: [Task<NativeApplicationSearchQuitResult, Error>] = []
  var completions = 0
  init() {
    factory = Task2Factory(backend)
    let factory = self.factory
    bridge = NativeApplicationSearches(ownerFactory: { try factory.make() })
    factory.bridge = bridge
  }
  func owner() -> ApplicationSearchOwner? {
    do {
      let result = try bridge.ownerForFind()
      actualOwner = result
      XCTAssertEqual(factory.calls, 1)
      XCTAssertEqual(bridge.phase, .open)
      return result
    } catch {
      XCTAssertEqual(factory.calls, 1, "Explicit Find must invoke actual lazy factory once")
      XCTFail("Actual retained owner missing; later Task2 horizons unentered")
      return nil
    }
  }
  func preparation() -> NativeApplicationSearchQuitPreparation? {
    do { return try bridge.prepareQuitIfCreated() } catch {
      XCTFail("Actual opaque bridge preparation missing; later quit horizons unentered")
      return nil
    }
  }
  func attach(_ owner: ApplicationSearchOwner) throws {
    let ticket = try owner.attachWindow(windowID: source.window, endpointID: source.endpoint)
    tickets.append(ticket)
    session = try DocumentSearchSession(
      owner: owner, window: ticket, source: source,
      onState: { [weak self] in self?.sessionState = $0 })
  }
  func start(replacing: Bool) throws {
    let session = try XCTUnwrap(session)
    try session.start(
      query: SearchQuery(pattern: "x", mode: .literal),
      operation: replacing ? .replace(template: "y") : .find, scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 4, maxOutputUTF16: 4, maxMatches: 4,
        cooperativeMilliseconds: 100))
  }
  func complete(_ index: Int, replacement: String? = nil) throws -> SearchResultLeaseID {
    let capture = try backend.capture(index)
    let lease = backend.install(
      capture, matches: [NSRange(location: 2, length: 1)], replacement: replacement)
    backend.deliver(index, .completed(lease))
    return lease
  }
  func approval() -> DocumentSearchApprovalToken? {
    guard case .awaitingApproval(let token, let count) = sessionState else {
      XCTFail("Actual session approval missing")
      return nil
    }
    XCTAssertEqual(count, 1)
    return token
  }
  func track(
    _ prep: NativeApplicationSearchQuitPreparation, observing eventGate: Task2Gate? = nil,
    operation: @escaping @MainActor () async throws -> Void
  ) -> Task<NativeApplicationSearchQuitResult, Error> {
    precondition(tasks.count < 2)
    let task = Task { @MainActor [self] in
      do {
        let result = try await bridge.completeQuit(prep, afterManagedPreparation: operation)
        completions += 1
        eventGate?.returned()
        return result
      } catch {
        completions += 1
        eventGate?.returned()
        throw error
      }
    }
    tasks.append(task)
    return task
  }
  func finish() async {
    backend.clearHooks()
    factory.onFactory = nil
    factory.beforeReturn = nil
    source.onSelect = nil
    source.onReplace = nil
    for gate in gates { gate.release() }
    backend.joinHold?.release()
    let ownsCleanup = tasks.isEmpty || Task2UnresolvedCustody.reserve(self)
    // Retain earlier exact unresolved fixture; no second accepting cleanup.
    guard ownsCleanup else { return }
    for task in tasks { _ = await task.result }
    if !tasks.isEmpty { Task2UnresolvedCustody.joined(self) }
    session?.close()
    if let actualOwner { for ticket in tickets { actualOwner.detachWindow(ticket) } }
    backend.finishPending()
    XCTAssertEqual(Set(backend.registered), Set(backend.unregistered))
    XCTAssertEqual(backend.registered.count, backend.unregistered.count)
    XCTAssertTrue(backend.payloads.isEmpty)
    XCTAssertEqual(backend.pendingTerminalCount, 0)
    XCTAssertEqual(backend.borrowDepth, 0)
  }
}

@MainActor private func withTask2Fixture(_ body: @MainActor (Task2Fixture) async throws -> Void)
  async throws
{
  let f = Task2Fixture()
  do {
    try await body(f)
    await f.finish()
  } catch {
    await f.finish()
    throw error
  }
}

private func task2Success() -> SearchAdmissionJoinedShutdownResult {
  .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: .completed(
        SearchParentJoinedShutdownCompletion(
          shutdown: SearchParentWireShutdown(
            child: SearchChildShutdown(cleanup: .noChild, channelsClosed: true),
            parentLaneSettled: true, retainedParentLanes: 0), ownership: .admitted,
          laneStop: .acknowledged)),
      driverSettlement: .settled(admissionClosed: true), retainedActiveJobs: 0, retainedLeases: 0,
      activeCharge: SearchAdmissionProductionAccounting().resident, retainedCharge: 0,
      reservedRetainedCharge: 0))
}

private struct Task2TerminalFacts {
  let join: ApplicationSearchJoinID
  let first: ApplicationSearchTerminalResult
  let latest: ApplicationSearchTerminalResult
  let disposition: NativeApplicationSearchSettlement
}
@MainActor private func task2Terminal(_ value: NativeApplicationSearchQuitResult)
  -> Task2TerminalFacts?
{
  guard case .terminal(let join, let first, let latest, let disposition) = value else {
    XCTFail("Actual terminal result horizon missing")
    return nil
  }
  return .init(join: join, first: first, latest: latest, disposition: disposition)
}
@MainActor private final class Task2Source: ApplicationDocumentSearchSource {
  let window = UUID(), endpoint = UUID(), document = UUID(), pane = UUID(), ownership = UUID()
  let text = "😀xx"
  var inspections = 0, captures = 0, replacements = 0
  var selections: [NSRange] = []
  var onReplace: (@MainActor () -> Void)?, onSelect: (@MainActor () -> Void)?
  func credential() throws -> DocumentSearchCredential {
    try DocumentSearchCredential(
      windowID: window, endpointID: endpoint, documentID: document,
      paneID: pane, ownershipGeneration: ownership, editRevision: 7, inputUTF16: 4)
  }
  func inspect() throws -> DocumentSearchCredential {
    guard inspections < 64 else {
      XCTFail("Inspection cap")
      throw Task2Failure.bound
    }
    inspections += 1
    return try credential()
  }
  func capture(expected: DocumentSearchCredential) throws -> SearchAdmissionCapture<
    DocumentSearchCredential
  > {
    guard captures < 16, try credential() == expected else {
      throw ApplicationDocumentSearchFailure.staleSource
    }
    captures += 1
    return SearchAdmissionCapture(text: text, inputUTF16: 4, context: expected)
  }
  func isCurrent(expected: DocumentSearchCredential) -> Bool { (try? credential()) == expected }
  func select(expected: DocumentSearchCredential, source: String, range: NSRange) -> Bool {
    guard selections.count < 16, (try? credential()) == expected, source == text else {
      return false
    }
    let callback = onSelect
    onSelect = nil
    callback?()
    selections.append(range)
    return true
  }
  func replace(expected: DocumentSearchCredential, source: String, replacement: String) -> Bool {
    guard replacements < 8, (try? credential()) == expected, source == text,
      replacement.utf16.count <= 16
    else { return false }
    replacements += 1  // Explicit scripted counter effect only; no native/document text mutation.
    let callback = onReplace
    onReplace = nil
    callback?()
    return true
  }
}

@MainActor private final class Task2Backend: ApplicationSearchBackend {
  final class Submission {
    let consumer: SearchConsumerID, job: SearchJobID
    let descriptor: SearchAdmissionDescriptor
    var capture: (@MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>)?
    var completion: (@MainActor (SearchAdmissionDelivery) -> Void)?
    var delivered = false
    init(
      consumer: SearchConsumerID, job: SearchJobID, descriptor: SearchAdmissionDescriptor,
      capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
      completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
    ) {
      self.consumer = consumer
      self.job = job
      self.descriptor = descriptor
      self.capture = capture
      self.completion = completion
    }
  }
  struct Payload {
    let captured: SearchAdmissionCapture<DocumentSearchCredential>
    let output: SearchExecutionOutput
  }
  var registered: [SearchConsumerID] = [], unregistered: [SearchConsumerID] = []
  var cancelled: [SearchJobID] = [], released: [SearchResultLeaseID] = []
  var submissions: [Submission] = [], payloads: [SearchResultLeaseID: Payload] = [:]
  var onSubmit: (@MainActor (Int) -> Void)?
  var onCancel: (@MainActor (SearchJobID) -> Void)?,
    onRelease: (@MainActor (SearchResultLeaseID) -> Void)?
  var throwAfterSubmit: SearchAdmissionFailure?
  var borrowDepth = 0
  var pendingTerminalCount: Int { submissions.filter { !$0.delivered }.count }
  func registration(_ index: Int) throws -> SearchConsumerID {
    guard registered.indices.contains(index) else {
      XCTFail("Missing real registration")
      throw Task2Failure.missing
    }
    return registered[index]
  }
  func submission(_ index: Int) throws -> Submission {
    guard submissions.indices.contains(index) else {
      XCTFail("Missing real submission")
      throw Task2Failure.missing
    }
    return submissions[index]
  }
  func register() -> SearchConsumerID {
    precondition(registered.count < 4)
    let id = SearchConsumerID()
    registered.append(id)
    return id
  }
  func unregister(_ consumer: SearchConsumerID) {
    XCTAssertTrue(registered.contains(consumer))
    XCTAssertFalse(unregistered.contains(consumer))
    guard unregistered.count < 4 else {
      XCTFail("Unregister cap")
      return
    }
    unregistered.append(consumer)
  }
  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    guard submissions.count < 4 else {
      XCTFail("Submission cap")
      throw Task2Failure.bound
    }
    let job = SearchJobID()
    submissions.append(
      Submission(
        consumer: consumer, job: job, descriptor: descriptor,
        capture: capture, completion: completion))
    let callback = onSubmit
    onSubmit = nil
    callback?(submissions.count - 1)
    if let throwAfterSubmit { throw throwAfterSubmit }
    return job
  }
  func cancel(_ id: SearchJobID) {
    XCTAssertFalse(cancelled.contains(id))
    guard cancelled.count < 16 else {
      XCTFail("Cancel cap")
      return
    }
    cancelled.append(id)
    let callback = onCancel
    onCancel = nil
    callback?(id)
  }
  func release(_ id: SearchResultLeaseID) {
    XCTAssertFalse(released.contains(id))
    guard released.count < 16 else {
      XCTFail("Release cap")
      return
    }
    released.append(id)
    payloads.removeValue(forKey: id)
    let callback = onRelease
    onRelease = nil
    callback?(id)
  }
  func withResult(
    _ id: SearchResultLeaseID,
    _ body: (DocumentSearchCredential, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    guard let payload = payloads[id], borrowDepth == 0 else { return false }
    borrowDepth += 1
    defer { borrowDepth -= 1 }
    body(payload.captured.context, payload.captured.text, payload.output)
    return true
  }
  func capture(_ index: Int) throws -> SearchAdmissionCapture<DocumentSearchCredential> {
    let request = try submission(index)
    let callback = try XCTUnwrap(request.capture)
    return try callback()
  }
  func install(
    _ captured: SearchAdmissionCapture<DocumentSearchCredential>, matches: [NSRange],
    replacement: String?
  ) -> SearchResultLeaseID {
    precondition(matches.count <= 4 && payloads.count < 4)
    let id = SearchResultLeaseID()
    payloads[id] = Payload(
      captured: captured, output: SearchExecutionOutput(matches: matches, replacement: replacement))
    return id
  }
  func deliver(_ index: Int, _ delivery: SearchAdmissionDelivery) {
    guard submissions.indices.contains(index), !submissions[index].delivered else {
      XCTFail("Missing/duplicate actual scripted terminal completion")
      return
    }
    let request = submissions[index]
    request.delivered = true
    let callback = request.completion
    request.completion = nil
    request.capture = nil
    callback?(delivery)
  }
  func finishPending() {
    for index in submissions.indices where !submissions[index].delivered {
      deliver(index, .failed(.cancelled))
    }
  }
  func clearHooks() {
    onSubmit = nil
    onCancel = nil
    onRelease = nil
    throwAfterSubmit = nil
  }
  var joinValues: [SearchAdmissionJoinedShutdownResult] = [task2Success()]
  var joinHold: Task2Gate?
  var joinCalls = 0
  var joinedTaskCancelled = false
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    guard joinCalls < 2, joinValues.indices.contains(joinCalls) else {
      XCTFail("Unexpected joined observation count")
      return .callerRefused(.unsupportedDriver)
    }
    let index = joinCalls
    joinCalls += 1
    if let joinHold {
      do { try await joinHold.enter() } catch { XCTFail("Unexpected backend hold error") }
    }
    joinedTaskCancelled = Task.isCancelled
    return joinValues[index]
  }
}
// Injected protocol observations only; never a concrete child/process completion claim.
private func task2Row(_ row: String) -> SearchAdmissionJoinedShutdownResult {
  if row == "admissionRefused" { return .callerRefused(.synchronousCallbackActive) }
  var ownership: SearchParentJoinedOwnership = .admitted
  switch row {
  case "ownershipStale": ownership = .refused(.staleHandle)
  case "ownershipRequest": ownership = .refused(.requestActive)
  case "ownershipObserver": ownership = .refused(.observerPresent)
  case "ownershipReceipt": ownership = .refused(.receiptUnconsumed)
  case "ownershipAbandoned": ownership = .refused(.abandoned)
  default: break
  }
  let generation = UUID()
  let cleanup: SearchChildCleanup
  switch row {
  case "childPending": cleanup = .pendingLaunch(generation: generation)
  case "childStopping": cleanup = .stopping(generation: generation)
  case "childUnconfirmed": cleanup = .stopUnconfirmed(generation: generation)
  default: cleanup = .noChild
  }
  let parent: SearchParentJoinedShutdownResult =
    row == "parentRefused"
    ? .callerRefused(.differentJoinOwner)
    : .completed(
      SearchParentJoinedShutdownCompletion(
        shutdown: SearchParentWireShutdown(
          child: SearchChildShutdown(cleanup: cleanup, channelsClosed: row != "channels"),
          parentLaneSettled: row != "parentLane",
          retainedParentLanes: row == "parentRetained" ? 1 : 0),
        ownership: ownership, laneStop: row == "laneStop" ? .failed : .acknowledged))
  let settlement: SearchParentWireSettlement =
    row == "driverPending" ? .pending : .settled(admissionClosed: row != "driverOpen")
  let resident = SearchAdmissionProductionAccounting().resident
  let active: UInt64 = row == "activeZero" ? 0 : (row == "activeExtra" ? resident + 1 : resident)
  return .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: parent, driverSettlement: settlement,
      retainedActiveJobs: row == "jobs" ? 1 : 0, retainedLeases: row == "leases" ? 1 : 0,
      activeCharge: active, retainedCharge: row == "retained" ? 1 : 0,
      reservedRetainedCharge: row == "reserved" ? 1 : 0))
}
private func task2SameParentWithNoResidual(_ raw: SearchAdmissionJoinedShutdownResult)
  -> SearchAdmissionJoinedShutdownResult
{
  guard case .observed(let original) = raw else { return raw }
  return .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: original.parent,
      driverSettlement: .settled(admissionClosed: true), retainedActiveJobs: 0, retainedLeases: 0,
      activeCharge: SearchAdmissionProductionAccounting().resident, retainedCharge: 0,
      reservedRetainedCharge: 0))
}
private func task2WithLocalResidual(_ raw: SearchAdmissionJoinedShutdownResult)
  -> SearchAdmissionJoinedShutdownResult
{
  guard case .observed(let original) = raw else { return raw }
  return .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: original.parent,
      driverSettlement: original.driverSettlement, retainedActiveJobs: 1, retainedLeases: 1,
      activeCharge: SearchAdmissionProductionAccounting().resident + 8, retainedCharge: 8,
      reservedRetainedCharge: 8))
}
